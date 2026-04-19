#!/bin/bash
# ralph-daemon.sh - Ralph 任务调度守护进程
#
# 功能：
#   - 监听配置目录的 prd.json
#   - 检测状态变化
#   - 识别决策点
#   - 使用 git worktree 实现并发任务执行
#
# 配置：~/.ralph-daemon/config.json
#

DAEMON_DIR="$HOME/.ralph-daemon"
CONFIG_FILE="$DAEMON_DIR/config.json"
PID_FILE="$DAEMON_DIR/daemon.pid"
LOG_FILE="$DAEMON_DIR/daemon.log"
STATE_DIR="$DAEMON_DIR/state"
SHUTDOWN_FLAG="$DAEMON_DIR/.shutdown"
GRACEFUL_TIMEOUT=60

mkdir -p "$DAEMON_DIR" "$STATE_DIR"

# 创建默认配置
init_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'EOF'
{
  "watchDirs": [],
  "pollInterval": 30,
  "workerCount": 3,
  "workerTimeout": 3600,
  "logLevel": "info"
}
EOF
    echo "Created config: $CONFIG_FILE"
    echo "Use 'ralph-daemon.sh add <dir>' to add projects"
  fi
}

# 日志函数
# 用法: log [项目目录] 消息
# 如果第一个参数是项目路径，加 [project] 前缀
log() {
  local msg timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  if [[ "$1" == /* ]] && [ -d "$1" ] 2>/dev/null; then
    local project_dir="$1"
    shift
    msg="$*"
    local project_name=$(basename "$project_dir")
    echo "[$timestamp] [$project_name] $msg" >> "$LOG_FILE"
  else
    msg="$*"
    echo "[$timestamp] $msg" >> "$LOG_FILE"
  fi
}

# 获取 prd 状态
get_status() {
  local prd_file="$1"
  [ ! -f "$prd_file" ] && { echo "not_found"; return; }

  local prd_status
  prd_status=$(jq -r '.status // "running"' "$prd_file" 2>/dev/null)

  # 检查未解决的决策点
  local unresolved
  unresolved=$(jq '[.decisionPoints[]? | select(.resolved == false)] | length' "$prd_file" 2>/dev/null)

  if [ "$unresolved" -gt 0 ] 2>/dev/null; then
    echo "decision_needed"
  elif [ "$prd_status" = "completed" ]; then
    echo "completed"
  elif [ "$prd_status" = "paused" ]; then
    echo "paused"
  else
    echo "running"
  fi
}

# 获取未解决的决策点
get_pending_decisions() {
  local prd_file="$1"
  jq -c '.decisionPoints[] | select(.resolved == false)' "$prd_file" 2>/dev/null
}

# 获取依赖已满足的可执行任务
# 返回: JSON 数组，每个元素包含 id, title
get_ready_tasks() {
  local prd_file="$1"
  jq -c '
    # 获取所有未完成的任务
    [.userStories[] | select(.passes == false)] |
    # 过滤出依赖已满足的任务
    map(select(
      # depends 为空或所有依赖都已 passes=true
      (.depends // []) | all(
        . as $dep |
        # 在 userStories 中查找依赖任务
        ($prd.userStories[] | select(.id == $dep) | .passes) == true
      )
    )) |
    # 按优先级排序
    sort_by(.priority) |
    # 只返回必要字段
    map({id, title, priority})
  ' --argjson prd "$(cat "$prd_file")" "$prd_file" 2>/dev/null
}

# 获取活跃 worktree 数量
get_active_worktrees() {
  local project_dir="$1"
  local worktree_dir="$project_dir/.claude/worktrees"
  [ ! -d "$worktree_dir" ] && { echo 0; return; }

  local count=0
  for wt in "$worktree_dir"/*; do
    [ -d "$wt" ] && ((count++))
  done
  echo $count
}

# 创建 worktree 并启动 worker
spawn_worker() {
  local project_dir="$1"
  local task_id="$2"
  local task_title="$3"
  local prd_file="$project_dir/prd.json"

  local worktree_dir="$project_dir/.claude/worktrees"
  local worktree_path="$worktree_dir/$task_id"
  local branch_name="ralph/$task_id-$(date +%s)"
  local main_branch=$(git -C "$project_dir" branch --show-current 2>/dev/null || echo "main")

  log "$project_dir" "SPAWN $task_id: $task_title"

  # 确保 worktree 目录存在
  mkdir -p "$worktree_dir"

  # 创建 worktree（如果已存在则跳过）
  if [ -d "$worktree_path" ]; then
    log "$project_dir" "  SKIP: worktree already exists"
    return 1
  fi

  # 创建 worktree
  git -C "$project_dir" worktree add -b "$branch_name" "$worktree_path" HEAD 2>/dev/null || {
    log "$project_dir" "  ERROR: Failed to create worktree"
    return 1
  }

  # 复制完整 prd.json，添加 currentTask 标识
  jq --arg id "$task_id" '. + {currentTask: $id}' "$prd_file" > "$worktree_path/prd.json"

  # 创建 progress.txt
  echo "# Progress for $task_id" > "$worktree_path/progress.txt"
  echo "Started: $(date)" >> "$worktree_path/progress.txt"

  # 写入 worker 上下文（worker 完成后用于自合并）
  cat > "$worktree_path/.worker-context" << EOF
PROJECT_DIR=$project_dir
TASK_ID=$task_id
BRANCH_NAME=$branch_name
MAIN_BRANCH=$main_branch
WORKTREE_PATH=$worktree_path
EOF

  # 创建自合并脚本
  cat > "$worktree_path/self-merge.sh" << 'MERGE_SCRIPT'
#!/bin/bash
# Worker 完成后自合并脚本
# 用法: ./self-merge.sh [success|fail]
# 改进：merge 前备份主 prd.json，merge 后恢复并更新状态

set -e
cd "$(dirname "$0")"

[ ! -f ".worker-context" ] && { echo "No .worker-context found"; exit 1; }
source .worker-context

RESULT="${1:-success}"

if [ "$RESULT" = "success" ]; then
  echo "[$(date)] Self-merging $TASK_ID..."

  # 1. 提交当前改动（如果有）
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "feat: $TASK_ID completed" || true
  fi

  # 2. 备份主仓库的 prd.json（关键：防止被 git merge 覆盖）
  cd "$PROJECT_DIR"
  MAIN_PRD="$PROJECT_DIR/prd.json"
  BACKUP_PRD="/tmp/prd-$TASK_ID-backup.json"

  if [ -f "$MAIN_PRD" ]; then
    cp "$MAIN_PRD" "$BACKUP_PRD"
    echo "[$(date)] Backed up main prd.json"
  fi

  # 3. 合并代码（允许失败，冲突需要手动解决）
  git merge "$BRANCH_NAME" --no-edit -m "feat: $TASK_ID completed" 2>/dev/null || {
    echo "[$(date)] MERGE_FAILED: conflicts detected"
    echo "  Resolve conflicts manually in $PROJECT_DIR"
    # 恢复备份
    [ -f "$BACKUP_PRD" ] && mv "$BACKUP_PRD" "$MAIN_PRD"
    exit 1
  }

  # 4. 恢复主 prd.json 并更新任务状态
  if [ -f "$BACKUP_PRD" ]; then
    mv "$BACKUP_PRD" "$MAIN_PRD"
    echo "[$(date)] Restored main prd.json"
  fi

  # 5. 从 worktree 的 prd.json 读取任务状态并更新主 prd.json
  WORKTREE_PRD="$WORKTREE_PATH/prd.json"

  if [ -f "$WORKTREE_PRD" ]; then
    TASK_PASSES=$(jq -r '.userStories[] | select(.id == "'$TASK_ID'") | .passes // false' "$WORKTREE_PRD" 2>/dev/null)

    if [ "$TASK_PASSES" = "true" ]; then
      jq --arg id "$TASK_ID" '
        .userStories = [.userStories[] | if .id == $id then .passes = true else . end]
      ' "$MAIN_PRD" > "${MAIN_PRD}.tmp"
      mv "${MAIN_PRD}.tmp" "$MAIN_PRD"
      echo "[$(date)] Updated prd.json: $TASK_ID marked as passed"
    fi
  fi

  # 6. 提交 prd.json 更新
  if [ -n "$(git status --porcelain "$MAIN_PRD")" ]; then
    git add "$MAIN_PRD"
    git commit -m "chore: update prd.json for $TASK_ID" || true
  fi

  # 7. 清理 worktree 和分支
  git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || {
    rm -rf "$WORKTREE_PATH"
  }
  git branch -D "$BRANCH_NAME" 2>/dev/null || true

  echo "[$(date)] $TASK_ID completed and merged successfully"
else
  echo "[$(date)] $TASK_ID marked as failed, keeping worktree for debugging"
fi
MERGE_SCRIPT
  chmod +x "$worktree_path/self-merge.sh"

  # 创建 worker 执行指令（变量需要在创建时展开）
  cat > "$worktree_path/worker-prompt.txt" << PROMPT
你是一个自动执行任务的 agent。

请执行以下任务：

**任务 ID**: $task_id
**任务标题**: $task_title

执行步骤：
1. 读取当前目录的 prd.json 获取任务详情
2. 读取 progress.txt 了解项目上下文
3. 按任务描述执行工作
4. 完成后更新 progress.txt
5. 如果任务完成，运行 ./self-merge.sh success
PROMPT

  # 后台启动 Claude（使用文件输入）
  (
    cd "$worktree_path"
    claude --dangerously-skip-permissions < worker-prompt.txt 2>&1 | tee -a "$worktree_path/worker.log"
    echo "Exit code: $?" >> "$worktree_path/worker.log"
  ) &

  local worker_pid=$!
  echo "$worker_pid" > "$worktree_path/.worker.pid"
  echo "$branch_name" > "$worktree_path/.worker.branch"

  log "$project_dir" "  WORKER_PID: $worker_pid"
  log "$project_dir" "  WORKTREE: $worktree_path"
  log "$project_dir" "  BRANCH: $branch_name"
}

# 检查超时 worker（不处理合并，worker 自己 merge）
check_timeout_workers() {
  local project_dir="$1"
  local worktree_dir="$project_dir/.claude/worktrees"

  [ ! -d "$worktree_dir" ] && return

  for worktree_path in "$worktree_dir"/*; do
    [ -d "$worktree_path" ] || continue

    local task_id=$(basename "$worktree_path")
    local pid_file="$worktree_path/.worker.pid"

    [ ! -f "$pid_file" ] && continue

    local worker_pid=$(cat "$pid_file")

    # 检查进程是否仍在运行
    if kill -0 "$worker_pid" 2>/dev/null; then
      # 检查是否超时
      local timeout=$(jq -r '.workerTimeout // 3600' "$CONFIG_FILE")
      local elapsed=$(($(date +%s) - $(stat -f %m "$pid_file" 2>/dev/null || stat -c %Y "$pid_file" 2>/dev/null)))

      if [ "$elapsed" -gt "$timeout" ]; then
        log "$project_dir" "TIMEOUT $task_id: killing worker $worker_pid"
        kill "$worker_pid" 2>/dev/null || true
        rm -f "$pid_file"
      fi
    else
      # Worker 已结束，清理 pid 文件
      rm -f "$pid_file"
      log "$project_dir" "WORKER_ENDED $task_id: pid file cleaned"
    fi
  done
}

# 清理 worktree
cleanup_worktree() {
  local project_dir="$1"
  local worktree_path="$2"
  local branch_name="${3:-}"

  log "$project_dir" "  CLEANUP: $worktree_path"

  # 移除 worktree
  git -C "$project_dir" worktree remove "$worktree_path" --force 2>/dev/null || {
    rm -rf "$worktree_path"
  }

  # 删除分支
  if [ -n "$branch_name" ]; then
    git -C "$project_dir" branch -D "$branch_name" 2>/dev/null || true
  fi
}

# 恢复已完成的任务：扫描残留 worktree，合并已完成的状态
recover_completed_tasks() {
  local project_dir="$1"
  local worktree_dir="$project_dir/.claude/worktrees"
  local prd_file="$project_dir/prd.json"

  [ ! -d "$worktree_dir" ] && return

  log "$project_dir" "RECOVER: Scanning for interrupted worktrees..."

  for worktree_path in "$worktree_dir"/*; do
    [ -d "$worktree_path" ] || continue

    local task_id=$(basename "$worktree_path")
    local worktree_prd="$worktree_path/prd.json"
    local pid_file="$worktree_path/.worker.pid"
    local branch_file="$worktree_path/.worker.branch"

    # 检查进程是否存在
    if [ -f "$pid_file" ] && kill -0 $(cat "$pid_file") 2>/dev/null; then
      log "$project_dir" "  SKIP $task_id: worker still running"
      continue
    fi

    # 检查任务是否完成
    if [ -f "$worktree_prd" ]; then
      local passes=$(jq -r '.userStories[] | select(.id == "'$task_id'") | .passes // false' "$worktree_prd" 2>/dev/null)

      if [ "$passes" = "true" ]; then
        log "$project_dir" "  RECOVER $task_id: completed, merging to main prd.json"

        # 合并到主 prd.json
        jq --arg id "$task_id" '
          .userStories = [.userStories[] | if .id == $id then .passes = true else . end]
        ' "$prd_file" > "${prd_file}.tmp"
        mv "${prd_file}.tmp" "$prd_file"
      else
        log "$project_dir" "  RECOVER $task_id: not completed, will be re-spawned"
      fi
    fi

    # 清理 worktree 和分支
    local branch_name=""
    [ -f "$branch_file" ] && branch_name=$(cat "$branch_file")
    cleanup_worktree "$project_dir" "$worktree_path" "$branch_name"
  done
}

# 优雅退出：等待 worker 完成或超时
graceful_shutdown() {
  log "INFO Graceful shutdown initiated"
  log "INFO Waiting for active workers to complete (timeout: ${GRACEFUL_TIMEOUT}s)"

  local start_time=$(date +%s)
  local all_done=false

  while true; do
    local elapsed=$(($(date +%s) - start_time))
    [ "$elapsed" -ge "$GRACEFUL_TIMEOUT" ] && break

    # 检查所有项目的活跃 worker
    local total_active=0
    local watch_dirs
    watch_dirs=$(jq -r '.watchDirs[]' "$CONFIG_FILE" 2>/dev/null)

    while IFS= read -r dir; do
      [ -z "$dir" ] && continue
      local expanded="${dir/#\\~/$HOME}"
      local active=$(get_active_worktrees "$expanded")
      total_active=$((total_active + active))

      # 检查超时 worker
      check_timeout_workers "$expanded"
    done <<< "$watch_dirs"

    if [ "$total_active" -eq 0 ]; then
      all_done=true
      break
    fi

    log "SHUTDOWN: $total_active workers still running, waiting... (${elapsed}s/${GRACEFUL_TIMEOUT}s)"
    sleep 5
  done

  if [ "$all_done" = true ]; then
    log "INFO All workers completed gracefully"
  else
    log "WARN Timeout reached, forcing shutdown"

    # 强制停止所有 worker
    watch_dirs=$(jq -r '.watchDirs[]' "$CONFIG_FILE" 2>/dev/null)
    while IFS= read -r dir; do
      [ -z "$dir" ] && continue
      local expanded="${dir/#\\~/$HOME}"
      local worktree_dir="$expanded/.claude/worktrees"

      [ ! -d "$worktree_dir" ] && continue

      for worktree_path in "$worktree_dir"/*; do
        [ -d "$worktree_path" ] || continue
        local pid_file="$worktree_path/.worker.pid"
        [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null
      done
    done <<< "$watch_dirs"
  fi

  log "INFO Daemon stopped"
  rm -f "$SHUTDOWN_FLAG"
  exit 0
}

# 主守护进程
run_daemon() {
  init_config

  # 检测是否在 Claude session 内运行（会触发嵌套限制）
  if [ "$CLAUDECODE" = "1" ]; then
    echo "⚠️  检测到在 Claude session 内运行 daemon"
    echo "   Claude 不允许嵌套 session，worker 无法启动"
    echo ""
    echo "   请在终端手动执行："
    echo "     ralph-daemon.sh start"
    echo ""
    echo "   或使用后台模式："
    echo "     nohup ralph-daemon.sh start > /dev/null 2>&1 &"
    exit 1
  fi

  # 单实例检查：使用目录锁确保只有一个 daemon 运行（兼容 macOS）
  local LOCK_DIR="$DAEMON_DIR/daemon.lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    # 锁成功，设置退出时清理
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
  else
    echo "ERROR: Another daemon instance is already running"
    echo "       Check: $PID_FILE"
    echo "       Remove lock: rm -rf $LOCK_DIR"
    exit 1
  fi

  # Handle shutdown signals - 优雅退出
  trap 'log "INFO Received SIGTERM"; graceful_shutdown' SIGTERM
  trap 'log "INFO Received SIGINT"; graceful_shutdown' SIGINT

  log "INFO Daemon started"
  log "INFO Config: $CONFIG_FILE"

  local poll_interval worker_count
  poll_interval=$(jq -r '.pollInterval // 30' "$CONFIG_FILE")
  worker_count=$(jq -r '.workerCount // 3' "$CONFIG_FILE")

  # 恢复已完成的任务：扫描残留 worktree
  local watch_dirs
  watch_dirs=$(jq -r '.watchDirs[]' "$CONFIG_FILE" 2>/dev/null)
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    local expanded="${dir/#\\~/$HOME}"
    [ -f "$expanded/prd.json" ] && recover_completed_tasks "$expanded"
  done <<< "$watch_dirs"

  while true; do
    # 检查是否收到关闭信号
    [ -f "$SHUTDOWN_FLAG" ] && graceful_shutdown

    local watch_dirs
    watch_dirs=$(jq -r '.watchDirs[]' "$CONFIG_FILE" 2>/dev/null)

    while IFS= read -r dir; do
      [ -z "$dir" ] && continue

      local expanded="${dir/#\\~/$HOME}"
      local prd_file="$expanded/prd.json"

      [ ! -f "$prd_file" ] && continue

      local prd_status
      prd_status=$(get_status "$prd_file")

      log "$expanded" "STATUS: $prd_status"

      case "$prd_status" in
        "decision_needed")
          local decisions
          decisions=$(get_pending_decisions "$prd_file")
          if [ -n "$decisions" ]; then
            log "$expanded" "DECISION_NEEDED"
            echo "$decisions" | while IFS= read -r d; do
              local d_id=$(echo "$d" | jq -r '.id')
              local d_question=$(echo "$d" | jq -r '.question')
              log "$expanded" "  D:$d_id - $d_question"
            done
          fi
          ;;

        "running")
          # 先检查超时 worker
          check_timeout_workers "$expanded"

          # 获取当前活跃 worker 数量
          local active=$(get_active_worktrees "$expanded")
          local available=$((worker_count - active))

          log "$expanded" "ACTIVE_WORKERS: $active / $worker_count"

          if [ "$available" -gt 0 ]; then
            # 获取可执行任务
            local ready_tasks
            ready_tasks=$(get_ready_tasks "$prd_file")

            if [ -n "$ready_tasks" ] && [ "$ready_tasks" != "[]" ]; then
              local task_count=$(echo "$ready_tasks" | jq 'length')
              log "$expanded" "READY_TASKS: $task_count tasks (slots: $available)"

              # 启动最多 available 个 worker
              echo "$ready_tasks" | jq -c ".[:$available][]" | while IFS= read -r task; do
                local t_id=$(echo "$task" | jq -r '.id')
                local t_title=$(echo "$task" | jq -r '.title')
                spawn_worker "$expanded" "$t_id" "$t_title"
              done
            fi
          fi

          # 检查是否全部完成
          local pending
          pending=$(jq '[.userStories[] | select(.passes == false)] | length' "$prd_file" 2>/dev/null)
          if [ "$pending" -eq 0 ] 2>/dev/null; then
            log "$expanded" "ALL_COMPLETE"
            # 更新 prd 状态
            jq '.status = "completed"' "$prd_file" > "${prd_file}.tmp"
            mv "${prd_file}.tmp" "$prd_file"
          fi
          ;;

        "completed")
          log "$expanded" "COMPLETED"
          ;;

        "paused")
          log "$expanded" "PAUSED"
          ;;
      esac

    done <<< "$watch_dirs"

    log "DEBUG Sleeping ${poll_interval}s"
    sleep "$poll_interval"
  done
}

# 手动清理命令
cleanup_all() {
  local project_dir="$1"
  local worktree_dir="$project_dir/.claude/worktrees"

  [ ! -d "$worktree_dir" ] && { echo "No worktrees found"; return; }

  echo "Cleaning up all worktrees in $project_dir..."

  for worktree_path in "$worktree_dir"/*; do
    [ -d "$worktree_path" ] || continue

    local task_id=$(basename "$worktree_path")
    local branch_name=$(cat "$worktree_path/.worker.branch" 2>/dev/null)

    echo "  Removing: $task_id"
    cleanup_worktree "$project_dir" "$worktree_path" "$branch_name"
  done

  echo "Done."
}

# CLI
case "${1:-}" in
  start)
    if [ -f "$PID_FILE" ]; then
      old_pid=$(cat "$PID_FILE" 2>/dev/null)
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        echo "Daemon already running (PID: $old_pid)"
        exit 1
      fi
    fi
    init_config
    rm -f "$LOG_FILE"
    echo "Starting ralph daemon..."
    nohup "$0" _run_daemon >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "Daemon started (PID: $(cat $PID_FILE))"
    ;;

  stop)
    if [ ! -f "$PID_FILE" ]; then
      echo "Daemon not running"
      exit 1
    fi

    daemon_pid=$(cat "$PID_FILE")
    if ! kill -0 "$daemon_pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      echo "Daemon not running (stale PID file removed)"
      exit 1
    fi

    # 检查是否强制停止
    force_mode=false
    wait_mode=true
    case "${2:-}" in
      --force|-f)
        force_mode=true
        ;;
      --nowait|-n)
        wait_mode=false
        ;;
    esac

    if [ "$force_mode" = true ]; then
      echo "Force stopping daemon (PID: $daemon_pid)..."
      kill -9 "$daemon_pid" 2>/dev/null || true

      # 终止所有 worker
      watch_dirs=$(jq -r '.watchDirs[]' "$CONFIG_FILE" 2>/dev/null)
      while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        local expanded="${dir/#\\~/$HOME}"
        local worktree_dir="$expanded/.claude/worktrees"
        [ ! -d "$worktree_dir" ] && continue

        for worktree_path in "$worktree_dir"/*; do
          [ -d "$worktree_path" ] || continue
          local pid_file="$worktree_path/.worker.pid"
          if [ -f "$pid_file" ]; then
            local wpid=$(cat "$pid_file")
            kill -9 "$wpid" 2>/dev/null || true
            echo "  Killed worker: $wpid"
          fi
        done
      done <<< "$watch_dirs"

      rm -f "$PID_FILE" "$SHUTDOWN_FLAG"
      echo "Daemon stopped (forced)"
    else
      # 优雅退出
      echo "Stopping daemon gracefully (PID: $daemon_pid)..."
      touch "$SHUTDOWN_FLAG"
      kill -TERM "$daemon_pid" 2>/dev/null

      if [ "$wait_mode" = true ]; then
        echo "Waiting for workers to complete (timeout: ${GRACEFUL_TIMEOUT}s)..."
        waited=0
        while [ $waited -lt $GRACEFUL_TIMEOUT ]; do
          if ! kill -0 "$daemon_pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            echo "Daemon stopped gracefully"
            exit 0
          fi
          sleep 1
          waited=$((waited + 1))
          printf "\r  Waiting... %ds/%ds" "$waited" "$GRACEFUL_TIMEOUT"
        done
        echo ""
        echo "Timeout reached. Use 'stop --force' to force stop."
      else
        echo "Signal sent. Daemon will exit after workers complete."
      fi
    fi
    ;;

  restart)
    # 停止（如果运行中）
    if [ -f "$PID_FILE" ]; then
      echo "Stopping daemon..."
      "$0" stop --force 2>/dev/null
      sleep 1
    fi
    # 清理残留
    rm -rf "$DAEMON_DIR/daemon.lock" "$PID_FILE" 2>/dev/null
    # 启动
    echo "Starting daemon..."
    "$0" start
    ;;

  status)
    init_config
    echo "Config: $CONFIG_FILE"
    echo ""
    if [ -f "$PID_FILE" ]; then
      pid=$(cat "$PID_FILE")
      if kill -0 "$pid" 2>/dev/null; then
        if [ -f "$SHUTDOWN_FLAG" ]; then
          echo "Daemon: shutting down (PID: $pid)"
        else
          echo "Daemon: running (PID: $pid)"
        fi
      else
        echo "Daemon: not running (stale PID)"
        rm -f "$PID_FILE"
      fi
    else
      echo "Daemon: not running"
    fi
    echo ""
    echo "Watched directories:"
    watch_dirs=$(jq -r '.watchDirs[]' "$CONFIG_FILE" 2>/dev/null)
    while IFS= read -r dir; do
      [ -z "$dir" ] && continue
      expanded="${dir/#\\~/$HOME}"
      st="not_found"
      [ -f "$expanded/prd.json" ] && st=$(get_status "$expanded/prd.json")
      active=0
      [ -d "$expanded/.claude/worktrees" ] && active=$(get_active_worktrees "$expanded")
      printf "  %-40s %s (workers: %d)\n" "$dir" "$st" "$active"
    done <<< "$watch_dirs"
    ;;

  logs)
    # 查看日志，可选过滤项目
    if [ -n "${2:-}" ]; then
      project_name=$(basename "${2/#\\~/$HOME}")
      echo "Filtering logs for [$project_name] (Ctrl+C to stop)"
      tail -f "$LOG_FILE" | grep --line-buffered "\[$project_name\]"
    else
      tail -f "$LOG_FILE"
    fi
    ;;

  add)
    [ -z "${2:-}" ] && { echo "Usage: $0 add <directory>"; exit 1; }
    new_dir="$2"
    new_dir="${new_dir/#$HOME/\~}"
    jq --arg dir "$new_dir" '.watchDirs += [$dir] | .watchDirs |= unique' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo "Added $new_dir"
    ;;

  remove)
    [ -z "${2:-}" ] && { echo "Usage: $0 remove <directory>"; exit 1; }
    rm_dir="${2/#$HOME/\~}"
    jq --arg dir "$rm_dir" '.watchDirs = [.watchDirs[] | select(. != $dir)]' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo "Removed $rm_dir"
    ;;

  cleanup)
    [ -z "${2:-}" ] && { echo "Usage: $0 cleanup <directory>"; exit 1; }
    cleanup_all "${2/#\\~/$HOME}"
    ;;

  recover)
    [ -z "${2:-}" ] && { echo "Usage: $0 recover <directory>"; exit 1; }
    recover_completed_tasks "${2/#\\~/$HOME}"
    ;;

  _run_daemon)
    run_daemon
    ;;

  *)
    echo "Ralph Daemon - 任务调度守护进程（支持并发 worktree）"
    echo ""
    echo "Usage: $0 <command>"
    echo "  start              启动守护进程"
    echo "  stop               停止守护进程（等待 worker 完成）"
    echo "  stop --force       强制停止（终止所有 worker）"
    echo "  stop --nowait      发送信号后立即返回"
    echo "  restart            重启守护进程（stop --force + start）"
    echo "  status             查看状态"
    echo "  add <dir>          添加监听目录"
    echo "  remove <dir>       移除监听目录"
    echo "  cleanup <dir>      清理该目录的所有 worktree"
    echo "  recover <dir>      从中断的 worktree 恢复已完成任务"
    echo "  logs               查看主日志"
    echo "  logs <dir>         过滤指定项目日志"
    echo ""
    echo "日志："
    echo "  主日志:    $LOG_FILE"
    echo "  Worker日志: <project>/.claude/worktrees/<task>/worker.log"
    echo ""
    echo "安全退出："
    echo "  默认 stop 会等待所有 worker 完成后再退出"
    echo "  超时 ${GRACEFUL_TIMEOUT}s 后需使用 --force 强制停止"
    ;;
esac
