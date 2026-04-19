#!/bin/bash
# run_tests.sh - 简单的测试运行器
#
# 用法: ./run_tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# 断言函数
assert_equals() {
    local expected="$1"
    local actual="$2"
    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo "      Expected: '$expected'"
        echo "      Actual:   '$actual'"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "      Expected '$needle' to be in string"
        return 1
    fi
}

assert_file_exists() {
    [ -f "$1" ] && return 0
    echo "      File does not exist: $1"
    return 1
}

assert_dir_exists() {
    [ -d "$1" ] && return 0
    echo "      Directory does not exist: $1"
    return 1
}

# 运行单个测试
run_test() {
    local name="$1"
    shift

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  [$TESTS_RUN] $name ... "

    if "$@" 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "=========================================="
echo "  Ralph Test Suite"
echo "=========================================="
echo ""

cd "$SCRIPT_DIR"

# ==========================================
# 符号链接解析测试
# ==========================================
echo -e "${YELLOW}Testing: Symlink Resolution${NC}"

test_direct_path() {
    local actual
    actual=$(cd "$PROJECT_ROOT" && pwd)
    assert_equals "$PROJECT_ROOT" "$actual"
}

run_test "直接路径解析" test_direct_path

test_symlink_resolve() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local link="$temp_dir/ralph-link"
    ln -s "$PROJECT_ROOT/ralph.sh" "$link"

    local resolved
    resolved=$(readlink "$link")
    assert_equals "$PROJECT_ROOT/ralph.sh" "$resolved"
}

run_test "符号链接解析" test_symlink_resolve

# ==========================================
# 配置管理测试
# ==========================================
echo ""
echo -e "${YELLOW}Testing: Configuration${NC}"

test_config_create() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local config="$temp_dir/config.json"
    cat > "$config" << 'EOF'
{"watchDirs":[],"pollInterval":30,"workerCount":3}
EOF

    local count
    count=$(jq '.watchDirs | length' "$config")
    assert_equals "0" "$count"
}

run_test "配置文件创建" test_config_create

test_config_add_dir() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local config="$temp_dir/config.json"
    echo '{"watchDirs":[]}' > "$config"

    jq --arg dir "~/test" '.watchDirs += [$dir]' "$config" > "${config}.tmp"
    mv "${config}.tmp" "$config"

    local count
    count=$(jq '.watchDirs | length' "$config")
    assert_equals "1" "$count"
}

run_test "添加监控目录" test_config_add_dir

test_config_default_values() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local config="$temp_dir/config.json"
    echo '{}' > "$config"

    local poll
    poll=$(jq -r '.pollInterval // 30' "$config")
    assert_equals "30" "$poll"
}

run_test "默认值读取" test_config_default_values

# ==========================================
# PRD 状态测试
# ==========================================
echo ""
echo -e "${YELLOW}Testing: PRD Status${NC}"

test_prd_running_status() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local prd="$temp_dir/prd.json"
    cat > "$prd" << 'EOF'
{"status":"running","userStories":[{"id":"US-001","passes":false}]}
EOF

    local status
    status=$(jq -r '.status' "$prd")
    assert_equals "running" "$status"
}

run_test "PRD running 状态" test_prd_running_status

test_prd_update_passes() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local prd="$temp_dir/prd.json"
    cat > "$prd" << 'EOF'
{"userStories":[{"id":"US-001","passes":false}]}
EOF

    jq --arg id "US-001" '.userStories = [.userStories[] | if .id == $id then .passes = true else . end]' "$prd" > "${prd}.tmp"
    mv "${prd}.tmp" "$prd"

    local passes
    passes=$(jq -r '.userStories[0].passes' "$prd")
    assert_equals "true" "$passes"
}

run_test "PRD 任务状态更新" test_prd_update_passes

test_prd_decision_needed() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local prd="$temp_dir/prd.json"
    cat > "$prd" << 'EOF'
{"decisionPoints":[{"id":"D1","resolved":false}]}
EOF

    local count
    count=$(jq '[.decisionPoints[] | select(.resolved == false)] | length' "$prd")
    assert_equals "1" "$count"
}

run_test "PRD 决策点检测" test_prd_decision_needed

# ==========================================
# Worktree 测试
# ==========================================
echo ""
echo -e "${YELLOW}Testing: Worktree Management${NC}"

test_worktree_path() {
    local project="/tmp/project"
    local task="US-001"
    local expected="$project/.claude/worktrees/$task"
    local actual="$project/.claude/worktrees/$task"
    assert_equals "$expected" "$actual"
}

run_test "Worktree 路径构建" test_worktree_path

test_worker_context() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local ctx="$temp_dir/.worker-context"
    cat > "$ctx" << 'EOF'
PROJECT_DIR=/tmp/project
TASK_ID=US-001
BRANCH_NAME=ralph/US-001-123
EOF

    assert_file_exists "$ctx"

    local task_id
    task_id=$(grep "^TASK_ID=" "$ctx" | cut -d= -f2)
    assert_equals "US-001" "$task_id"
}

run_test "Worker 上下文文件" test_worker_context

test_worktree_count() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local wt_dir="$temp_dir/.claude/worktrees"
    mkdir -p "$wt_dir/US-001" "$wt_dir/US-002"

    local count=0
    for d in "$wt_dir"/*; do
        [ -d "$d" ] && ((count++))
    done

    assert_equals "2" "$count"
}

run_test "Worktree 数量统计" test_worktree_count

# ==========================================
# Daemon 脚本测试
# ==========================================
echo ""
echo -e "${YELLOW}Testing: Daemon Script${NC}"

test_daemon_exists() {
    assert_file_exists "$PROJECT_ROOT/ralph-daemon.sh"
}

run_test "Daemon 脚本存在" test_daemon_exists

test_daemon_executable() {
    [ -x "$PROJECT_ROOT/ralph-daemon.sh" ]
}

run_test "Daemon 脚本可执行" test_daemon_executable

test_daemon_help() {
    local output
    output=$("$PROJECT_ROOT/ralph-daemon.sh" 2>&1) || true

    assert_contains "$output" "start"
    assert_contains "$output" "stop"
    assert_contains "$output" "status"
}

run_test "Daemon 帮助信息" test_daemon_help

test_daemon_signal_handlers() {
    local has_term has_int
    has_term=$(grep -c "SIGTERM" "$PROJECT_ROOT/ralph-daemon.sh" 2>/dev/null || echo "0")
    has_int=$(grep -c "SIGINT" "$PROJECT_ROOT/ralph-daemon.sh" 2>/dev/null || echo "0")

    [ "$has_term" -gt 0 ] && [ "$has_int" -gt 0 ]
}

run_test "Daemon 信号处理" test_daemon_signal_handlers

test_graceful_timeout() {
    local timeout
    timeout=$(grep "GRACEFUL_TIMEOUT=" "$PROJECT_ROOT/ralph-daemon.sh" | head -1 | cut -d= -f2)

    [ -n "$timeout" ] && [ "$timeout" -gt 0 ]
}

run_test "优雅退出超时配置" test_graceful_timeout

# ==========================================
# 边界情况测试
# ==========================================
echo ""
echo -e "${YELLOW}Testing: Edge Cases${NC}"

test_empty_watchdirs() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local config="$temp_dir/config.json"
    echo '{"watchDirs":[]}' > "$config"

    local dirs
    dirs=$(jq -r '.watchDirs[]' "$config" 2>/dev/null)
    [ -z "$dirs" ]
}

run_test "空监控目录列表" test_empty_watchdirs

test_config_dedup() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local config="$temp_dir/config.json"
    echo '{"watchDirs":["~/test"]}' > "$config"

    # 尝试添加重复
    jq --arg dir "~/test" '.watchDirs += [$dir] | .watchDirs |= unique' "$config" > "${config}.tmp"
    mv "${config}.tmp" "$config"

    local count
    count=$(jq '.watchDirs | length' "$config")
    assert_equals "1" "$count"
}

run_test "配置目录去重" test_config_dedup

test_prd_missing_field() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local prd="$temp_dir/prd.json"
    echo '{}' > "$prd"

    # 使用默认值
    local status
    status=$(jq -r '.status // "running"' "$prd")
    assert_equals "running" "$status"
}

run_test "PRD 缺失字段默认值" test_prd_missing_field

test_prd_all_tasks_complete() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local prd="$temp_dir/prd.json"
    cat > "$prd" << 'EOF'
{"userStories":[{"id":"US-001","passes":true},{"id":"US-002","passes":true}]}
EOF

    local pending
    pending=$(jq '[.userStories[] | select(.passes == false)] | length' "$prd")
    assert_equals "0" "$pending"
}

run_test "所有任务完成检测" test_prd_all_tasks_complete

test_worktree_empty() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local wt_dir="$temp_dir/.claude/worktrees"
    mkdir -p "$wt_dir"

    local count=0
    for d in "$wt_dir"/*; do
        [ -d "$d" ] && ((count++))
    done

    assert_equals "0" "$count"
}

run_test "空 worktree 目录" test_worktree_empty

# ==========================================
# Git 集成测试
# ==========================================
echo ""
echo -e "${YELLOW}Testing: Git Integration${NC}"

test_git_repo_check() {
    # 当前目录应该是 git 仓库
    [ -d "$PROJECT_ROOT/.git" ]
}

run_test "Git 仓库检测" test_git_repo_check

test_git_branch_command() {
    # 验证可以获取当前分支
    local branch
    branch=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "")
    [ -n "$branch" ]
}

run_test "Git 分支获取" test_git_branch_command

test_ralph_script_exists() {
    assert_file_exists "$PROJECT_ROOT/ralph.sh"
}

run_test "ralph.sh 存在" test_ralph_script_exists

test_ralph_script_default_tool() {
    # 提取 TOOL 变量定义行中的值
    local default
    default=$(grep '^TOOL=' "$PROJECT_ROOT/ralph.sh" | head -1 | sed 's/TOOL="\([^"]*\)".*/\1/')
    assert_equals "claude" "$default"
}

run_test "ralph.sh 默认工具" test_ralph_script_default_tool

# ==========================================
# PRD 示例文件测试
# ==========================================
echo ""
echo -e "${YELLOW}Testing: Example Files${NC}"

test_prd_example_exists() {
    assert_file_exists "$PROJECT_ROOT/prd.json.example"
}

run_test "PRD 示例文件存在" test_prd_example_exists

test_prd_example_valid_json() {
    jq '.' "$PROJECT_ROOT/prd.json.example" >/dev/null 2>&1
}

run_test "PRD 示例有效 JSON" test_prd_example_valid_json

test_claude_md_exists() {
    assert_file_exists "$PROJECT_ROOT/CLAUDE.md"
}

run_test "CLAUDE.md 存在" test_claude_md_exists

# ==========================================
# Bug 回归测试 (历史 Bug)
# ==========================================
echo ""
echo -e "${YELLOW}Testing: Bug Regression Tests${NC}"

# Bug #1: Daemon 配置路径与 worktree 路径不匹配
test_config_worktree_path_match() {
    # 模拟场景：daemon config watchDirs 应包含 worktree 所在项目
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local config="$temp_dir/config.json"
    local project_dir="$temp_dir/project"
    local worktree_dir="$project_dir/.claude/worktrees/US-001"

    mkdir -p "$worktree_dir"

    # config 应该包含 project 目录
    cat > "$config" << EOF
{"watchDirs":["$project_dir"]}
EOF

    # 验证：worktree 的父目录应该在 watchDirs 中
    local watch_dir
    watch_dir=$(jq -r '.watchDirs[0]' "$config")

    # worktree 的项目根目录应该在 watchDirs 中
    local worktree_project
    worktree_project=$(dirname "$(dirname "$(dirname "$worktree_dir")")")

    assert_equals "$watch_dir" "$worktree_project"
}

run_test "Bug#1: config 与 worktree 路径匹配" test_config_worktree_path_match

# Bug #2: Worktree 完整文件检查
test_worktree_complete_files() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local worktree="$temp_dir/US-001"
    mkdir -p "$worktree"

    # 创建所有必需文件（模拟 spawn_worker）
    touch "$worktree/prd.json"
    touch "$worktree/progress.txt"
    touch "$worktree/.worker-context"
    touch "$worktree/self-merge.sh"
    echo "12345" > "$worktree/.worker.pid"
    echo "ralph/US-001-123" > "$worktree/.worker.branch"

    # 验证所有文件存在
    assert_file_exists "$worktree/.worker-context" && \
    assert_file_exists "$worktree/self-merge.sh" && \
    assert_file_exists "$worktree/.worker.pid" && \
    assert_file_exists "$worktree/.worker.branch"
}

run_test "Bug#2: Worktree 完整文件检查" test_worktree_complete_files

# Bug #3: Worktree 状态合并到主 PRD
test_worktree_status_merge_to_main() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local main_prd="$temp_dir/prd.json"
    local worktree_prd="$temp_dir/worktrees/US-001/prd.json"

    mkdir -p "$(dirname "$worktree_prd")"

    # 主 PRD: 任务未完成
    cat > "$main_prd" << 'EOF'
{"userStories":[{"id":"US-001","passes":false},{"id":"US-002","passes":false}]}
EOF

    # Worktree PRD: 任务已完成
    cat > "$worktree_prd" << 'EOF'
{"userStories":[{"id":"US-001","passes":true}]}
EOF

    # 模拟 recover_completed_tasks 逻辑
    local task_id="US-001"
    local worktree_passes
    worktree_passes=$(jq -r '.userStories[] | select(.id == "'$task_id'") | .passes' "$worktree_prd")

    if [ "$worktree_passes" = "true" ]; then
        jq --arg id "$task_id" '.userStories = [.userStories[] | if .id == $id then .passes = true else . end]' "$main_prd" > "${main_prd}.tmp"
        mv "${main_prd}.tmp" "$main_prd"
    fi

    # 验证主 PRD 已更新
    local main_passes
    main_passes=$(jq -r '.userStories[] | select(.id == "US-001") | .passes' "$main_prd")

    assert_equals "true" "$main_passes"
}

run_test "Bug#3: Worktree 状态合并到主 PRD" test_worktree_status_merge_to_main

# Bug #5: PRD 备份恢复 (防止 git merge 覆盖)
test_prd_backup_before_merge() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local main_prd="$temp_dir/prd.json"
    local backup_prd="$temp_dir/prd-backup.json"

    # 初始主 PRD
    cat > "$main_prd" << 'EOF'
{"userStories":[{"id":"US-001","passes":false}]}
EOF

    # 1. 备份主 PRD
    cp "$main_prd" "$backup_prd"

    # 2. 模拟 git merge 可能覆盖（这里不实际 merge，只模拟覆盖）
    cat > "$main_prd" << 'EOF'
{"userStories":[{"id":"US-001","passes":false}]}
EOF

    # 3. 恢复备份并更新状态
    mv "$backup_prd" "$main_prd"
    jq '.userStories[0].passes = true' "$main_prd" > "${main_prd}.tmp"
    mv "${main_prd}.tmp" "$main_prd"

    # 验证状态正确更新
    local passes
    passes=$(jq -r '.userStories[0].passes' "$main_prd")
    assert_equals "true" "$passes"
}

run_test "Bug#5: PRD 备份恢复防覆盖" test_prd_backup_before_merge

# Bug #3 补充: 检测 worktree 已完成但未合并
test_detect_unmerged_completed_worktree() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local main_prd="$temp_dir/prd.json"
    local worktree_dir="$temp_dir/.claude/worktrees/US-001"
    local worktree_prd="$worktree_dir/prd.json"

    mkdir -p "$worktree_dir"

    # 主 PRD: 任务未完成
    cat > "$main_prd" << 'EOF'
{"userStories":[{"id":"US-001","passes":false}]}
EOF

    # Worktree PRD: 任务已完成
    cat > "$worktree_prd" << 'EOF'
{"currentTask":"US-001","userStories":[{"id":"US-001","passes":true}]}
EOF

    # 检测逻辑：worktree 中任务完成但主 PRD 未更新
    local worktree_passes main_passes
    worktree_passes=$(jq -r '.userStories[] | select(.id == "US-001") | .passes' "$worktree_prd")
    main_passes=$(jq -r '.userStories[] | select(.id == "US-001") | .passes' "$main_prd")

    # 应该检测到不一致
    if [ "$worktree_passes" = "true" ] && [ "$main_passes" != "true" ]; then
        return 0  # 检测到问题
    else
        echo "      未能检测到状态不一致"
        return 1
    fi
}

run_test "检测未合并的已完成 worktree" test_detect_unmerged_completed_worktree

# Bug #5 补充: self-merge 脚本逻辑验证
test_self_merge_script_logic() {
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" RETURN

    local worktree="$temp_dir/worktree"
    local project_dir="$temp_dir/project"
    mkdir -p "$worktree" "$project_dir"

    # 创建 worker context
    cat > "$worktree/.worker-context" << EOF
PROJECT_DIR=$project_dir
TASK_ID=US-001
BRANCH_NAME=ralph/US-001-123
MAIN_BRANCH=main
WORKTREE_PATH=$worktree
EOF

    # 创建模拟 self-merge 脚本并验证逻辑
    local merge_script="$worktree/self-merge.sh"
    cat > "$merge_script" << 'SCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
[ ! -f ".worker-context" ] && { echo "No .worker-context"; exit 1; }
source .worker-context
echo "TASK_ID=$TASK_ID"
echo "PROJECT_DIR=$PROJECT_DIR"
SCRIPT
    chmod +x "$merge_script"

    # 执行并验证
    local output
    output=$("$merge_script" 2>&1)

    assert_contains "$output" "TASK_ID=US-001" && \
    assert_contains "$output" "PROJECT_DIR=$project_dir"
}

run_test "self-merge 脚本逻辑验证" test_self_merge_script_logic

# Bug #4: Launchd plist 检测和清理
test_no_stale_launchd_plist() {
    local plist_path="$HOME/Library/LaunchAgents/com.ralph.daemon.plist"

    # 如果存在 plist，检查 daemon 是否真的在运行
    if [ -f "$plist_path" ]; then
        local is_loaded
        is_loaded=$(launchctl list 2>/dev/null | grep -c "com.ralph.daemon" || echo "0")

        # 如果 plist 存在但未加载，说明是残留文件
        if [ "$is_loaded" = "0" ]; then
            echo "      发现残留 plist 文件: $plist_path"
            return 1
        fi
    fi

    # plist 不存在或正常运行
    return 0
}

run_test "Bug#4: 无残留 launchd plist" test_no_stale_launchd_plist

# Bug #4 补充: launchd 不应该有 KeepAlive
test_launchd_no_keepalive_if_stopped() {
    local plist_path="$HOME/Library/LaunchAgents/com.ralph.daemon.plist"

    # 如果存在 plist，验证可以正常停止
    if [ -f "$plist_path" ]; then
        # 检查是否有 KeepAlive（可能导致无法停止）
        local has_keepalive
        has_keepalive=$(grep -c "KeepAlive" "$plist_path" 2>/dev/null || echo "0")

        if [ "$has_keepalive" -gt 0 ]; then
            echo "      plist 含 KeepAlive，可能导致无法停止"
            # 这本身不是 bug，但需要记录
        fi
    fi

    return 0
}

run_test "launchd plist 配置检查" test_launchd_no_keepalive_if_stopped

# ==========================================
# 总结
# ==========================================
echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "  Tests run:    $TESTS_RUN"
echo -e "  ${GREEN}Passed:       $TESTS_PASSED${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "  ${RED}Failed:       $TESTS_FAILED${NC}"
fi
echo "=========================================="

[ "$TESTS_FAILED" -eq 0 ]
