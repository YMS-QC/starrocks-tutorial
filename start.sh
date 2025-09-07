#!/bin/bash
# StarRocks 快速启动脚本
# 版本要求：支持StarRocks 2.5+ 版本，推荐使用3.0+
# Docker要求：Docker 20.10+ 和 Docker Compose 2.0+

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
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查Docker环境
check_docker() {
    log_info "检查Docker环境..."
    
    if ! command -v docker &> /dev/null; then
        log_error "Docker未安装，请先安装Docker"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        log_error "Docker Compose未安装，请先安装Docker Compose"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker服务未启动，请启动Docker服务"
        exit 1
    fi
    
    log_success "Docker环境检查通过"
}

# 检查端口占用
check_ports() {
    log_info "检查端口占用..."
    
    local ports=(8030 9030 9010 8040 9060 8060 8080)
    local occupied_ports=()
    
    for port in "${ports[@]}"; do
        if lsof -i :$port &> /dev/null || netstat -tlnp 2>/dev/null | grep ":$port " &> /dev/null; then
            occupied_ports+=($port)
        fi
    done
    
    if [ ${#occupied_ports[@]} -gt 0 ]; then
        log_warn "以下端口被占用: ${occupied_ports[*]}"
        read -p "是否继续启动？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log_success "端口检查通过"
    fi
}

# 创建必要的目录
create_directories() {
    log_info "创建必要的目录..."
    
    mkdir -p data/{fe-meta,fe-log,be-storage,be-log}
    mkdir -p logs
    
    # 设置权限
    chmod -R 777 data/
    chmod -R 777 logs/
    
    log_success "目录创建完成"
}

# 启动StarRocks集群
start_starrocks() {
    log_info "启动StarRocks集群..."
    
    # 启动核心服务
    docker-compose up -d starrocks-fe starrocks-be
    
    log_info "等待服务启动..."
    sleep 30
    
    # 检查服务状态
    check_services
    
    # 初始化集群
    initialize_cluster
}

# 检查服务状态
check_services() {
    log_info "检查服务状态..."
    
    local retry_count=0
    local max_retries=10
    
    while [ $retry_count -lt $max_retries ]; do
        if curl -f http://localhost:8030/api/bootstrap &> /dev/null && \
           curl -f http://localhost:8040/api/health &> /dev/null; then
            log_success "服务启动成功"
            return 0
        fi
        
        log_info "等待服务启动... ($((retry_count+1))/$max_retries)"
        sleep 10
        ((retry_count++))
    done
    
    log_error "服务启动超时"
    docker-compose logs starrocks-fe
    docker-compose logs starrocks-be
    exit 1
}

# 初始化集群
initialize_cluster() {
    log_info "初始化StarRocks集群..."
    
    # 等待FE完全启动
    sleep 20
    
    # 添加BE到集群
    local retry_count=0
    local max_retries=5
    
    while [ $retry_count -lt $max_retries ]; do
        if docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND 'starrocks-be:9050';" &> /dev/null; then
            log_success "BE节点添加成功"
            break
        fi
        
        log_info "尝试添加BE节点... ($((retry_count+1))/$max_retries)"
        sleep 10
        ((retry_count++))
    done
    
    if [ $retry_count -eq $max_retries ]; then
        log_warn "自动添加BE节点失败，请手动执行："
        echo "docker exec -it starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e \"ALTER SYSTEM ADD BACKEND 'starrocks-be:9050';\""
    fi
    
    # 验证集群状态
    verify_cluster
}

# 验证集群状态
verify_cluster() {
    log_info "验证集群状态..."
    
    sleep 5
    
    if docker-compose exec -T starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e "SHOW BACKENDS\G" | grep -q "Alive: true"; then
        log_success "集群验证成功"
    else
        log_warn "集群状态异常，请检查日志"
    fi
}

# 启动管理工具
start_tools() {
    log_info "启动管理工具..."
    
    # 启动mysql-client和adminer
    docker-compose --profile tools up -d
    
    log_success "管理工具启动完成"
}

# 显示连接信息
show_connection_info() {
    echo
    echo "========================================"
    log_success "StarRocks 启动完成！"
    echo "========================================"
    echo
    echo -e "${BLUE}连接信息:${NC}"
    echo "  MySQL协议: mysql -h localhost -P 9030 -u root"
    echo "  FE Web界面: http://localhost:8030"
    echo "  BE Web界面: http://localhost:8040"
    echo
    echo -e "${BLUE}管理工具:${NC}"
    echo "  Adminer: http://localhost:8080"
    echo "  MySQL客户端: docker exec -it mysql-client mysql -h starrocks-fe -P 9030 -u root"
    echo
    echo -e "${BLUE}测试连接:${NC}"
    echo "  ./test-connection.sh"
    echo
    echo -e "${BLUE}停止服务:${NC}"
    echo "  docker-compose down"
    echo
    echo "========================================"
}

# 主函数
main() {
    echo "StarRocks Docker 快速启动脚本"
    echo "=============================="
    
    # 检查环境
    check_docker
    check_ports
    
    # 准备环境
    create_directories
    
    # 启动服务
    start_starrocks
    
    # 启动管理工具
    read -p "是否启动管理工具 (mysql-client, adminer)? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_info "跳过管理工具启动"
    else
        start_tools
    fi
    
    # 显示连接信息
    show_connection_info
}

# 错误处理
trap 'log_error "脚本执行失败，正在清理..."; docker-compose down; exit 1' ERR

# 执行主函数
main "$@"