#!/bin/bash
# StarRocks 连接测试脚本
# 版本要求：支持StarRocks 2.5+ 版本，推荐使用3.0+
# 依赖工具：Docker, curl, netcat(可选), mysql-client(可选)

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# 测试计数器
total_tests=0
passed_tests=0

# 测试函数
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    ((total_tests++))
    log_info "测试: $test_name"
    
    if eval "$test_command" &>/dev/null; then
        log_success "$test_name"
        ((passed_tests++))
        return 0
    else
        log_error "$test_name"
        return 1
    fi
}

# 详细测试函数
run_detailed_test() {
    local test_name="$1"
    local test_command="$2"
    
    ((total_tests++))
    log_info "测试: $test_name"
    
    local output
    if output=$(eval "$test_command" 2>&1); then
        log_success "$test_name"
        if [ ! -z "$output" ]; then
            echo "  输出: $output"
        fi
        ((passed_tests++))
        return 0
    else
        log_error "$test_name"
        echo "  错误: $output"
        return 1
    fi
}

echo "StarRocks 连接测试"
echo "=================="
echo

# 1. 测试Docker容器状态
log_info "1. 检查Docker容器状态"
echo
run_test "FE容器运行状态" "docker-compose ps starrocks-fe | grep -q 'Up'"
run_test "BE容器运行状态" "docker-compose ps starrocks-be | grep -q 'Up'"

# 2. 测试端口连通性
echo
log_info "2. 测试端口连通性"
echo
if command -v nc >/dev/null 2>&1; then
    run_test "FE MySQL协议端口(9030)" "nc -z localhost 9030"
    run_test "FE Web端口(8030)" "nc -z localhost 8030"
    run_test "BE Web端口(8040)" "nc -z localhost 8040"
else
    log_warn "nc命令不可用，跳过端口测试"
fi

# 3. 测试HTTP接口
echo
log_info "3. 测试HTTP接口"
echo
if command -v curl >/dev/null 2>&1; then
    run_test "FE HTTP接口" "curl -f -s http://localhost:8030/api/bootstrap"
    run_test "BE HTTP接口" "curl -f -s http://localhost:8040/api/health"
else
    log_warn "curl命令不可用，跳过HTTP测试"
fi

# 4. 测试MySQL连接
echo
log_info "4. 测试MySQL协议连接"
echo

# 测试基本连接
run_detailed_test "MySQL协议连接" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT 1 as test;'"

# 测试数据库操作
run_detailed_test "查看数据库列表" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW DATABASES;' | grep -v 'Database'"

# 测试版本信息
run_detailed_test "获取版本信息" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT VERSION();'"

# 5. 测试集群状态
echo
log_info "5. 测试集群状态"
echo

# 检查FE状态
run_test "FE节点状态" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW FRONTENDS;' | grep -q 'true'"

# 检查BE状态
if docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS;' | grep -q 'starrocks-be'; then
    run_test "BE节点已添加" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS;' | grep -q 'starrocks-be'"
    run_test "BE节点状态正常" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS;' | grep 'starrocks-be' | grep -q 'true'"
else
    log_warn "BE节点未添加到集群"
    echo "  执行以下命令添加BE节点:"
    echo "  docker exec -it starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e \"ALTER SYSTEM ADD BACKEND 'starrocks-be:9050';\""
fi

# 6. 测试基础功能
echo
log_info "6. 测试基础功能"
echo

# 创建测试数据库
run_test "创建测试数据库" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'CREATE DATABASE IF NOT EXISTS test_connection;'"

# 创建测试表
run_test "创建测试表" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'USE test_connection; CREATE TABLE IF NOT EXISTS test_table (id INT, name VARCHAR(50)) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1;'"

# 插入测试数据
run_test "插入测试数据" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'USE test_connection; INSERT INTO test_table VALUES (1, \"test\");'"

# 查询测试数据
run_detailed_test "查询测试数据" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'USE test_connection; SELECT * FROM test_table;' | tail -n +2"

# 清理测试数据
run_test "清理测试数据" "docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'DROP DATABASE IF EXISTS test_connection;'"

# 7. 测试外部连接（如果mysql客户端可用）
echo
log_info "7. 测试外部MySQL客户端连接"
echo

if command -v mysql >/dev/null 2>&1; then
    run_test "外部MySQL客户端连接" "mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT 1;'"
else
    log_warn "系统未安装mysql客户端，跳过外部连接测试"
    echo "  可使用容器内客户端: docker exec -it mysql-client mysql -h starrocks-fe -P 9030 -u root"
fi

# 8. 性能测试（可选）
echo
log_info "8. 简单性能测试"
echo

# 测试查询性能
if run_test "查询性能测试" "timeout 30 docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT COUNT(*) FROM information_schema.tables;'"; then
    echo "  查询响应正常"
else
    log_warn "查询超时或失败，可能需要检查性能配置"
fi

# 显示测试结果
echo
echo "================="
echo "测试结果汇总"
echo "================="
echo -e "总测试数: $total_tests"
echo -e "通过测试: ${GREEN}$passed_tests${NC}"
echo -e "失败测试: ${RED}$((total_tests - passed_tests))${NC}"

if [ $passed_tests -eq $total_tests ]; then
    echo
    log_success "所有测试通过! StarRocks运行正常"
    echo
    echo "常用连接命令:"
    echo "  docker exec -it mysql-client mysql -h starrocks-fe -P 9030 -u root"
    echo "  mysql -h localhost -P 9030 -u root  # 需要本地安装mysql客户端"
    echo
    echo "Web管理界面:"
    echo "  FE管理: http://localhost:8030"
    echo "  BE管理: http://localhost:8040"
    if docker-compose ps adminer 2>/dev/null | grep -q 'Up'; then
        echo "  Adminer: http://localhost:8080"
    fi
    echo
else
    echo
    log_error "部分测试失败，请检查日志："
    echo "  docker-compose logs starrocks-fe"
    echo "  docker-compose logs starrocks-be"
    echo
    exit 1
fi