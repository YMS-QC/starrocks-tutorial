# StarRocks Docker快速部署

---

## 📖 导航

[🏠 返回主页](../../README.md) | [⬅️ 上一页](../01-introduction/what-is-starrocks.md) | [➡️ 下一页](connect-tools.md)

---

## 学习目标

- 掌握使用Docker快速部署StarRocks开发环境
- 了解StarRocks集群的基本组件和配置
- 学会验证部署是否成功
- 掌握基础的运维操作

## 环境要求

### 系统要求

| 组件 | 最低要求 | 推荐配置 |
|------|---------|---------|
| **操作系统** | Linux/macOS/Windows | Linux CentOS 7+ |
| **Docker** | 20.10+ | 最新版本 |
| **Docker Compose** | 2.0+ | 最新版本 |
| **内存** | 8GB | 16GB+ |
| **CPU** | 4核 | 8核+ |
| **磁盘** | 20GB | 100GB+ SSD |

### 端口规划

| 组件 | 端口 | 用途 |
|------|------|------|
| **FE** | 8030 | Web管理界面 |
| **FE** | 9030 | MySQL协议端口 |
| **FE** | 9010 | RPC通信端口 |
| **BE** | 8040 | Web管理界面 |
| **BE** | 9060 | 心跳端口 |
| **BE** | 8060 | 数据传输端口 |

## 快速部署

### 1. 创建Docker Compose文件

```yaml
# docker-compose.yml
version: '3.8'

services:
  starrocks-fe:
    image: starrocks/fe-ubuntu:3.3-latest
    hostname: starrocks-fe
    container_name: starrocks-fe
    ports:
      - "8030:8030"  # Web UI
      - "9030:9030"  # MySQL协议
      - "9010:9010"  # RPC端口
    environment:
      - JAVA_OPTS=-Xmx4g -XX:+UseG1GC
    volumes:
      - fe-meta:/opt/starrocks/fe/meta
      - fe-log:/opt/starrocks/fe/log
      - ./fe.conf:/opt/starrocks/fe/conf/fe.conf:ro
    networks:
      - starrocks-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8030/api/bootstrap"]
      interval: 30s
      timeout: 10s
      retries: 3

  starrocks-be:
    image: starrocks/be-ubuntu:3.3-latest
    hostname: starrocks-be
    container_name: starrocks-be
    ports:
      - "8040:8040"  # Web UI  
      - "9060:9060"  # 心跳端口
      - "8060:8060"  # 数据传输端口
    environment:
      - JAVA_OPTS=-Xmx8g -XX:+UseG1GC
    volumes:
      - be-storage:/opt/starrocks/be/storage
      - be-log:/opt/starrocks/be/log
      - ./be.conf:/opt/starrocks/be/conf/be.conf:ro
    networks:
      - starrocks-network
    depends_on:
      starrocks-fe:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8040/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  fe-meta:
    driver: local
  fe-log:
    driver: local
  be-storage:
    driver: local
  be-log:
    driver: local

networks:
  starrocks-network:
    driver: bridge
```

### 2. 创建配置文件

#### FE配置文件 (fe.conf)
```bash
# fe.conf - Frontend配置
# 元数据目录
meta_dir = /opt/starrocks/fe/meta

# 日志配置
LOG_DIR = /opt/starrocks/fe/log
DATE = "$(date +%Y%m%d-%H%M%S)"
LOG_CONSOLE = false
LOG_LEVEL = INFO

# 网络配置
priority_networks = 172.0.0.0/8
frontend_address = starrocks-fe
query_port = 9030
rpc_port = 9010
http_port = 8030

# 内存配置
JAVA_OPTS="-Xmx4g -XX:+UseG1GC -Xloggc:/opt/starrocks/fe/log/fe.gc.log"

# 集群配置
cluster_name = starrocks_cluster
cluster_id = 12345

# 导入配置
max_broker_load_job_concurrency = 10
max_routine_load_job_concurrency = 20
stream_load_default_timeout_second = 600

# 查询配置
qe_max_connection = 1024
max_query_retry_time = 3
```

#### BE配置文件 (be.conf)
```bash
# be.conf - Backend配置
# 存储配置
storage_root_path = /opt/starrocks/be/storage

# 网络配置
priority_networks = 172.0.0.0/8
be_host = starrocks-be
be_port = 9060
webserver_port = 8040
heartbeat_service_port = 9050
brpc_port = 8060

# 内存配置
mem_limit = 80%
chunk_reserved_bytes_limit = 20%

# CPU配置
num_threads_per_core = 3
max_consumer_num_per_group = 3

# 存储配置
default_num_rows_per_column_file_write = 1024000
pending_data_expire_time_sec = 1800
inc_rowset_expired_sec = 1800

# 压缩配置
compress_rowbatches = true
storage_compression_codec = LZ4_FRAME

# 日志配置
LOG_DIR = /opt/starrocks/be/log
LOG_LEVEL = INFO
```

### 3. 启动集群

```bash
# 1. 创建项目目录
mkdir -p starrocks-docker
cd starrocks-docker

# 2. 创建配置文件
# 将上述fe.conf和be.conf内容保存到对应文件

# 3. 创建docker-compose.yml
# 将上述docker-compose.yml内容保存

# 4. 启动集群
docker-compose up -d

# 5. 查看容器状态
docker-compose ps

# 6. 查看启动日志
docker-compose logs -f starrocks-fe
docker-compose logs -f starrocks-be
```

### 4. 集群初始化

```bash
# 连接到FE容器
docker exec -it starrocks-fe bash

# 连接到StarRocks
mysql -h 127.0.0.1 -P 9030 -u root

# 添加BE节点到集群
ALTER SYSTEM ADD BACKEND "starrocks-be:9050";

# 查看集群状态
SHOW BACKENDS\G
```

## 验证部署

### 1. 检查服务状态

```bash
# 检查容器运行状态
docker-compose ps

# 应该显示：
# Name              Command               State                    Ports
# starrocks-be      /opt/starrocks/be/bin/st ...   Up      0.0.0.0:8040->8040/tcp, ...
# starrocks-fe      /opt/starrocks/fe/bin/st ...   Up      0.0.0.0:8030->8030/tcp, ...

# 检查端口监听
docker-compose exec starrocks-fe netstat -tlnp | grep -E "(8030|9030|9010)"
docker-compose exec starrocks-be netstat -tlnp | grep -E "(8040|9060|8060)"
```

### 2. Web界面验证

```bash
# 访问FE Web界面
http://localhost:8030

# 访问BE Web界面  
http://localhost:8040
```

### 3. SQL连接验证

```sql
-- 使用MySQL客户端连接
mysql -h 127.0.0.1 -P 9030 -u root

-- 验证基础功能
SHOW BACKENDS;
SHOW DATABASES;
CREATE DATABASE test_db;
USE test_db;

-- 创建测试表
CREATE TABLE test_table (
    id INT,
    name VARCHAR(100),
    age INT,
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP
) 
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 1;

-- 插入测试数据
INSERT INTO test_table (id, name, age) VALUES
(1, 'Alice', 25),
(2, 'Bob', 30),
(3, 'Charlie', 35);

-- 查询验证
SELECT * FROM test_table;
SELECT COUNT(*) FROM test_table;
```

## 高级配置

### 1. 多BE节点部署

```yaml
# docker-compose-cluster.yml - 多节点配置
version: '3.8'

services:
  starrocks-fe:
    # FE配置同上...

  starrocks-be1:
    image: starrocks/be-ubuntu:3.2-latest
    hostname: starrocks-be1
    container_name: starrocks-be1
    ports:
      - "8041:8040"
      - "9061:9060"
      - "8061:8060"
    # 其他配置...

  starrocks-be2:
    image: starrocks/be-ubuntu:3.2-latest
    hostname: starrocks-be2
    container_name: starrocks-be2
    ports:
      - "8042:8040"
      - "9062:9060"
      - "8062:8060"
    # 其他配置...

  starrocks-be3:
    image: starrocks/be-ubuntu:3.2-latest
    hostname: starrocks-be3
    container_name: starrocks-be3
    ports:
      - "8043:8040"
      - "9063:9060"
      - "8063:8060"
    # 其他配置...
```

```sql
-- 添加多个BE节点
ALTER SYSTEM ADD BACKEND "starrocks-be1:9050";
ALTER SYSTEM ADD BACKEND "starrocks-be2:9050";
ALTER SYSTEM ADD BACKEND "starrocks-be3:9050";

-- 验证集群状态
SHOW BACKENDS;
```

### 2. 持久化存储配置

```yaml
# 使用本地目录持久化
volumes:
  - ./data/fe-meta:/opt/starrocks/fe/meta
  - ./data/fe-log:/opt/starrocks/fe/log
  - ./data/be-storage:/opt/starrocks/be/storage
  - ./data/be-log:/opt/starrocks/be/log

# 创建本地目录
mkdir -p data/{fe-meta,fe-log,be-storage,be-log}
chmod -R 777 data/
```

### 3. 资源限制配置

```yaml
# 限制容器资源使用
services:
  starrocks-fe:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 4G
        reservations:
          cpus: '1'
          memory: 2G
    
  starrocks-be:
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 8G
        reservations:
          cpus: '2'
          memory: 4G
```

## 常用运维操作

### 1. 集群管理

```bash
# 启动集群
docker-compose up -d

# 停止集群
docker-compose down

# 重启集群
docker-compose restart

# 查看日志
docker-compose logs -f starrocks-fe
docker-compose logs -f starrocks-be

# 查看容器资源使用
docker stats starrocks-fe starrocks-be
```

### 2. 数据备份

```bash
# 创建备份脚本
#!/bin/bash
# backup.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="./backup/$DATE"

# 创建备份目录
mkdir -p $BACKUP_DIR

# 备份FE元数据
docker-compose exec starrocks-fe tar czf /tmp/fe-meta-backup.tar.gz -C /opt/starrocks/fe meta
docker cp starrocks-fe:/tmp/fe-meta-backup.tar.gz $BACKUP_DIR/

# 导出数据
docker-compose exec starrocks-fe mysql -h127.0.0.1 -P9030 -uroot -e "
SELECT * FROM test_db.test_table 
INTO OUTFILE '/tmp/test_table.csv'
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n';"

docker cp starrocks-fe:/tmp/test_table.csv $BACKUP_DIR/

echo "Backup completed: $BACKUP_DIR"
```

### 3. 监控和诊断

```sql
-- 系统状态检查
SHOW BACKENDS;
SHOW FRONTENDS;

-- 性能监控
SHOW VARIABLES LIKE '%memory%';
SHOW VARIABLES LIKE '%thread%';

-- 查询统计
SHOW QUERY PROFILE;
SHOW PROCESSLIST;

-- 存储信息
SHOW DATA;
SHOW PARTITIONS FROM test_table;
```

### 4. 性能调优

```bash
# 调整BE配置
# be.conf 关键参数
mem_limit = 80%                    # 内存使用限制
num_threads_per_core = 3           # CPU线程数
max_tablet_num_per_shard = 1024    # Tablet分片数
```

```sql
-- 调整FE配置
-- 查询超时设置
SET query_timeout = 300;

-- 并行度设置  
SET parallel_exchange_instance_num = 8;
SET parallel_fragment_exec_instance_num = 8;

-- 内存限制
SET exec_mem_limit = 2147483648;  -- 2GB
```

## 常见问题

### Q1: FE启动失败，提示元数据损坏
```bash
# 解决方案：重置元数据
docker-compose down
docker volume rm starrocks-docker_fe-meta
docker-compose up -d
```

### Q2: BE无法加入集群
```bash
# 检查网络连接
docker-compose exec starrocks-fe ping starrocks-be

# 检查BE状态
docker-compose logs starrocks-be

# 手动添加BE
mysql -h127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND 'starrocks-be:9050';"
```

### Q3: 查询性能差
```sql
-- 检查表结构
SHOW CREATE TABLE your_table;

-- 检查数据分布
SHOW DATA FROM your_table;

-- 查看查询计划
EXPLAIN SELECT * FROM your_table WHERE xxx;
```

### Q4: 内存不足错误
```bash
# 调整内存配置
# 修改be.conf
mem_limit = 60%  # 降低内存使用

# 重启BE
docker-compose restart starrocks-be
```

## 生产环境部署建议

### 1. 硬件配置
- **FE**: 8核16GB内存，100GB SSD
- **BE**: 16核64GB内存，1TB SSD（每个BE）
- **网络**: 万兆网络

### 2. 高可用配置
- 部署3个FE节点（1 Leader + 2 Follower）
- BE节点至少3个，设置副本数为3
- 使用外部负载均衡器

### 3. 监控配置
- 使用Prometheus + Grafana监控
- 设置关键指标告警
- 日志集中收集和分析

## 小结

通过Docker可以快速搭建StarRocks开发环境：

1. **简单部署**：一键启动完整集群
2. **配置灵活**：支持多种部署模式
3. **易于管理**：标准化运维操作
4. **快速验证**：适合开发测试使用

Docker环境适合学习、开发和测试，生产环境建议使用物理机或虚拟机部署。

---

## 📖 导航

[🏠 返回主页](../../README.md) | [⬅️ 上一页](../01-introduction/what-is-starrocks.md) | [➡️ 下一页](connect-tools.md)

---