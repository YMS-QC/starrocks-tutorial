---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../06-advanced-features/big-data-ecosystem.md) | [➡️ 下一页](oracle-migration-best-practices.md)
---

# 生产环境部署建议

在生产环境中部署 StarRocks 需要考虑硬件规划、集群规模、安全配置、监控告警、备份恢复等多个方面。本章节提供完整的生产环境最佳实践指南。

## 1. 硬件规划和配置

### 1.1 FE (Frontend) 节点配置

**推荐配置**

| 集群规模 | CPU | 内存 | 磁盘 | 网络 | 节点数 |
|---------|-----|------|------|------|-------|
| **小规模** (< 10TB) | 8核+ | 32GB+ | SSD 500GB+ | 1Gbps | 3个 |
| **中规模** (10TB-100TB) | 16核+ | 64GB+ | SSD 1TB+ | 10Gbps | 3个 |
| **大规模** (100TB+) | 32核+ | 128GB+ | SSD 2TB+ | 10Gbps | 3个 |

**详细配置说明**
```bash
# FE 节点硬件检查脚本
#!/bin/bash
# fe_hardware_check.sh

echo "=== FE 节点硬件检查 ==="

# CPU 检查
cpu_cores=$(nproc)
echo "CPU 核心数: $cpu_cores"
if [ $cpu_cores -lt 8 ]; then
    echo "⚠️  警告: CPU 核心数低于推荐值(8核)"
fi

# 内存检查
memory_gb=$(free -g | grep '^Mem:' | awk '{print $2}')
echo "内存大小: ${memory_gb}GB"
if [ $memory_gb -lt 32 ]; then
    echo "⚠️  警告: 内存大小低于推荐值(32GB)"
fi

# 磁盘检查
disk_size=$(df -h /opt/starrocks | tail -1 | awk '{print $2}')
echo "磁盘空间: $disk_size"

# 网络检查
network_speed=$(ethtool eth0 | grep Speed | awk '{print $2}')
echo "网络速度: $network_speed"

# JVM 配置建议
echo ""
echo "=== FE JVM 配置建议 ==="
echo "JAVA_OPTS=\"-Xmx$((memory_gb * 3 / 4))g -XX:+UseG1GC -XX:G1HeapRegionSize=32m\""
```

**FE 配置文件优化**
```bash
# fe.conf 生产环境配置
priority_networks = 192.168.1.0/24
edit_log_port = 9010
http_port = 8030
rpc_port = 9020
query_port = 9030

# 元数据存储
meta_dir = /opt/starrocks/fe/meta

# 日志配置
log_roll_size_mb = 1024
sys_log_delete_age = 7d
audit_log_delete_age = 30d

# 查询配置
qe_max_connection = 4096
max_conn_per_user = 1000

# 内存配置
query_timeout = 300
max_query_retry_time = 3

# 集群配置
heartbeat_timeout_second = 30
bdbje_heartbeat_timeout_second = 30
```

### 1.2 BE (Backend) 节点配置

**推荐配置**

| 数据类型 | CPU | 内存 | 数据盘 | 日志盘 | 网络 | 建议数量 |
|----------|-----|------|--------|--------|------|----------|
| **热数据** | 32核+ | 128GB+ | NVMe SSD 2TB+ × 12 | SSD 500GB | 25Gbps | 按需扩展 |
| **温数据** | 16核+ | 64GB+ | SSD 4TB+ × 6 | SSD 500GB | 10Gbps | 按需扩展 |
| **冷数据** | 8核+ | 32GB+ | SATA 8TB+ × 4 | SSD 500GB | 1Gbps | 按需扩展 |

**BE 配置优化**
```bash
# be.conf 生产环境配置
priority_networks = 192.168.1.0/24
be_port = 9060
webserver_port = 8040
heartbeat_service_port = 9050
brpc_port = 8060

# 存储配置
storage_root_path = /data1/starrocks,medium:SSD;/data2/starrocks,medium:SSD;/data3/starrocks,medium:HDD

# 内存配置
mem_limit = 90%  # 使用90%系统内存
chunk_reserved_bytes_limit = 20%
load_process_max_memory_limit_bytes = 107374182400  # 100GB

# 查询配置
scanner_thread_pool_thread_num = 48
scan_range_max_bytes = 268435456  # 256MB
max_scan_key_num = 1024
max_pushdown_conditions_per_column = 1024

# 压缩配置
default_rowset_type = beta
compression_type = LZ4_FRAME

# 并发配置  
pipeline_dop = 0  # 0表示自动
max_fragment_instances_per_be = 64

# 磁盘配置
disable_storage_page_cache = false
index_stream_cache_capacity = 10737418240  # 10GB
```

### 1.3 存储规划

**分层存储策略**
```sql
-- 配置存储介质
ALTER SYSTEM ADD BACKEND "be1:9050" 
PROPERTIES ("tag.location" = "rack1", "tag.medium" = "SSD");

ALTER SYSTEM ADD BACKEND "be2:9050"
PROPERTIES ("tag.location" = "rack2", "tag.medium" = "HDD");

-- 表级别存储配置
CREATE TABLE hot_data (
    id BIGINT,
    data_time DATETIME,
    content STRING
) ENGINE=OLAP
DUPLICATE KEY(id)
PARTITION BY RANGE(data_time) ()
DISTRIBUTED BY HASH(id) BUCKETS 32
PROPERTIES (
    "replication_num" = "3",
    "storage_medium" = "SSD",
    "storage_cooldown_time" = "7d"  -- 7天后转为HDD
);
```

**磁盘监控脚本**
```bash
#!/bin/bash
# disk_monitor.sh

check_disk_usage() {
    local path=$1
    local threshold=${2:-85}  # 默认85%阈值
    
    usage=$(df -h "$path" | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [ "$usage" -gt "$threshold" ]; then
        echo "⚠️  警告: $path 磁盘使用率 ${usage}% 超过阈值 ${threshold}%"
        return 1
    else
        echo "✅ $path 磁盘使用率正常: ${usage}%"
        return 0
    fi
}

# 检查所有数据目录
data_dirs="/data1/starrocks /data2/starrocks /data3/starrocks /data4/starrocks"
for dir in $data_dirs; do
    if [ -d "$dir" ]; then
        check_disk_usage "$dir" 85
    fi
done

# 检查日志目录
check_disk_usage "/opt/starrocks/fe/log" 80
check_disk_usage "/opt/starrocks/be/log" 80
```

## 2. 网络和安全配置

### 2.1 网络规划

**网络拓扑建议**
```
                    应用层
                      |
               Load Balancer
                      |
            +--------+--------+
            |                 |
         FE Cluster      BE Cluster
      (Management VIP)   (Data Network)
            |                 |
    +-------+-------+   +----+----+
    |       |       |   |    |    |
   FE1     FE2     FE3  BE1  BE2  BE3...
```

**网络配置脚本**
```bash
#!/bin/bash
# network_setup.sh

# 设置网络参数优化
echo "net.core.rmem_max = 134217728" >> /etc/sysctl.conf
echo "net.core.wmem_max = 134217728" >> /etc/sysctl.conf  
echo "net.ipv4.tcp_rmem = 4096 65536 134217728" >> /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 65536 134217728" >> /etc/sysctl.conf
echo "net.core.netdev_max_backlog = 30000" >> /etc/sysctl.conf
echo "net.ipv4.tcp_max_syn_backlog = 30000" >> /etc/sysctl.conf
echo "net.ipv4.tcp_timestamps = 1" >> /etc/sysctl.conf
echo "net.ipv4.tcp_tw_recycle = 1" >> /etc/sysctl.conf

# 应用配置
sysctl -p

# 防火墙配置
systemctl stop firewalld
systemctl disable firewalld

# 或者配置必要端口
# firewall-cmd --permanent --add-port=8030/tcp  # FE HTTP
# firewall-cmd --permanent --add-port=9010/tcp  # FE Edit Log  
# firewall-cmd --permanent --add-port=9020/tcp  # FE RPC
# firewall-cmd --permanent --add-port=9030/tcp  # FE Query
# firewall-cmd --permanent --add-port=8040/tcp  # BE HTTP
# firewall-cmd --permanent --add-port=8060/tcp  # BE BRPC
# firewall-cmd --permanent --add-port=9050/tcp  # BE Heartbeat
# firewall-cmd --permanent --add-port=9060/tcp  # BE Thrift
# firewall-cmd --reload
```

### 2.2 安全配置

**用户权限管理**
```sql
-- 创建业务用户
CREATE USER 'app_user'@'%' IDENTIFIED BY 'strong_password';
CREATE USER 'readonly_user'@'%' IDENTIFIED BY 'readonly_password';
CREATE USER 'etl_user'@'%' IDENTIFIED BY 'etl_password';

-- 权限分配
-- 应用用户：读写权限
GRANT SELECT, INSERT, UPDATE, DELETE ON warehouse.* TO 'app_user'@'%';

-- 只读用户：查询权限
GRANT SELECT ON warehouse.* TO 'readonly_user'@'%';

-- ETL用户：数据导入权限
GRANT SELECT, INSERT, ALTER, CREATE ON warehouse.* TO 'etl_user'@'%';
GRANT LOAD_PRIV ON *.* TO 'etl_user'@'%';

-- 查看用户权限
SHOW GRANTS FOR 'app_user'@'%';
```

**SSL/TLS 配置**
```bash
# 生成SSL证书
openssl genrsa -out server-key.pem 2048
openssl req -new -key server-key.pem -out server-req.pem -subj "/CN=starrocks"
openssl x509 -req -in server-req.pem -signkey server-key.pem -out server-cert.pem -days 365

# FE SSL配置
echo "enable_ssl = true" >> /opt/starrocks/fe/conf/fe.conf
echo "ssl_certificate = /opt/starrocks/ssl/server-cert.pem" >> /opt/starrocks/fe/conf/fe.conf  
echo "ssl_private_key = /opt/starrocks/ssl/server-key.pem" >> /opt/starrocks/fe/conf/fe.conf

# 客户端连接
mysql -h starrocks-fe -P 9030 -u root --ssl-ca=/path/to/ca.pem --ssl-cert=/path/to/client-cert.pem --ssl-key=/path/to/client-key.pem
```

**审计日志配置**
```sql
-- 启用审计日志
SET GLOBAL audit_log_policy = 'ALL';
SET GLOBAL slow_query_log_file = '/opt/starrocks/fe/log/slow_query.log';

-- 查看审计日志
SELECT 
    timestamp,
    client_ip,
    user,
    db,
    state,
    query_time,
    scan_bytes,
    scan_rows,
    stmt
FROM information_schema.audit_log
WHERE timestamp >= DATE_SUB(NOW(), INTERVAL 1 DAY)
  AND query_time > 10  -- 查询时间超过10秒
ORDER BY timestamp DESC;
```

## 3. 集群规模评估

### 3.1 容量规划

**数据量估算公式**
```
原始数据大小 = 表记录数 × 平均记录大小
存储空间需求 = 原始数据大小 × 压缩比 × 副本数 × (1 + 索引开销)

其中：
- 压缩比: LZ4 约 3:1, ZSTD 约 4:1
- 副本数: 通常为 3
- 索引开销: 约 10-20%
```

**容量评估脚本**
```python
#!/usr/bin/env python3
# capacity_planning.py

def calculate_storage_requirement(
    row_count, 
    avg_row_size_bytes, 
    compression_ratio=3.0, 
    replication_factor=3, 
    index_overhead=0.15,
    growth_factor=1.5  # 50%增长预留
):
    """计算存储需求"""
    raw_size_gb = (row_count * avg_row_size_bytes) / (1024**3)
    compressed_size_gb = raw_size_gb / compression_ratio
    replicated_size_gb = compressed_size_gb * replication_factor
    total_size_gb = replicated_size_gb * (1 + index_overhead)
    final_size_gb = total_size_gb * growth_factor
    
    return {
        'raw_size_gb': round(raw_size_gb, 2),
        'compressed_size_gb': round(compressed_size_gb, 2),
        'replicated_size_gb': round(replicated_size_gb, 2),
        'total_size_gb': round(total_size_gb, 2),
        'final_size_gb': round(final_size_gb, 2)
    }

def recommend_cluster_size(total_storage_gb, storage_per_node_gb=20000):
    """推荐集群规模"""
    min_nodes = max(3, int(total_storage_gb / storage_per_node_gb) + 1)
    
    if total_storage_gb < 100:
        return {
            'be_nodes': 3,
            'fe_nodes': 3, 
            'node_type': 'small',
            'cpu_per_be': 16,
            'memory_per_be_gb': 64
        }
    elif total_storage_gb < 1000:
        return {
            'be_nodes': max(6, min_nodes),
            'fe_nodes': 3,
            'node_type': 'medium', 
            'cpu_per_be': 32,
            'memory_per_be_gb': 128
        }
    else:
        return {
            'be_nodes': max(10, min_nodes),
            'fe_nodes': 3,
            'node_type': 'large',
            'cpu_per_be': 64, 
            'memory_per_be_gb': 256
        }

# 使用示例
tables = [
    {'name': 'orders', 'rows': 100000000, 'avg_size': 200},
    {'name': 'order_details', 'rows': 500000000, 'avg_size': 150},
    {'name': 'customers', 'rows': 10000000, 'avg_size': 300},
    {'name': 'products', 'rows': 1000000, 'avg_size': 500}
]

total_storage = 0
print("=== 表存储需求分析 ===")
for table in tables:
    storage_req = calculate_storage_requirement(table['rows'], table['avg_size'])
    total_storage += storage_req['final_size_gb']
    print(f"{table['name']:15} {storage_req['final_size_gb']:8.1f} GB")

print(f"\n总存储需求: {total_storage:.1f} GB")

cluster_rec = recommend_cluster_size(total_storage)
print(f"\n=== 集群规模推荐 ===")
print(f"BE 节点数: {cluster_rec['be_nodes']}")
print(f"FE 节点数: {cluster_rec['fe_nodes']}")
print(f"节点类型: {cluster_rec['node_type']}")
print(f"BE CPU: {cluster_rec['cpu_per_be']} 核")
print(f"BE 内存: {cluster_rec['memory_per_be_gb']} GB")
```

### 3.2 性能基准测试

**TPC-H 基准测试脚本**
```bash
#!/bin/bash
# tpch_benchmark.sh

SCALE_FACTOR=${1:-10}  # 默认10GB
STARROCKS_HOST="starrocks-fe"
STARROCKS_PORT="9030"

echo "执行 TPC-H SF$SCALE_FACTOR 基准测试"

# 生成测试数据
echo "生成测试数据..."
cd /opt/tpch-tools
./dbgen -s $SCALE_FACTOR

# 创建表结构
echo "创建 TPC-H 表结构..."
mysql -h $STARROCKS_HOST -P $STARROCKS_PORT -u root < create_tpch_tables.sql

# 导入数据
echo "导入测试数据..."
for table in customer lineitem nation orders part partsupp region supplier; do
    echo "导入表: $table"
    curl --location-trusted -u root: \
        -H "column_separator:|" \
        -H "timeout:3600" \
        -T $table.tbl \
        http://$STARROCKS_HOST:8030/api/tpch/$table/_stream_load
done

# 执行查询测试
echo "执行 TPC-H 查询测试..."
results_file="tpch_sf${SCALE_FACTOR}_results_$(date +%Y%m%d_%H%M%S).txt"

for i in {1..22}; do
    echo "执行查询 Q$i" | tee -a $results_file
    start_time=$(date +%s.%N)
    
    timeout 600 mysql -h $STARROCKS_HOST -P $STARROCKS_PORT -u root \
        -e "$(cat queries/q$i.sql)" > /dev/null 2>&1
    
    exit_code=$?
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)
    
    if [ $exit_code -eq 0 ]; then
        echo "Q$i: ${duration}s" | tee -a $results_file
    elif [ $exit_code -eq 124 ]; then
        echo "Q$i: TIMEOUT (>600s)" | tee -a $results_file
    else
        echo "Q$i: ERROR" | tee -a $results_file
    fi
done

echo "基准测试完成，结果保存在: $results_file"

# 计算总体统计
python3 -c "
import re
import sys

results = []
with open('$results_file', 'r') as f:
    for line in f:
        match = re.search(r'Q(\d+): ([\d.]+)s', line)
        if match:
            results.append(float(match.group(2)))

if results:
    print(f'成功查询数: {len(results)}/22')
    print(f'总执行时间: {sum(results):.2f}s')
    print(f'平均查询时间: {sum(results)/len(results):.2f}s')
    print(f'最快查询时间: {min(results):.2f}s')
    print(f'最慢查询时间: {max(results):.2f}s')
"
```

## 4. 监控和告警

### 4.1 监控体系架构

**监控组件选择**
```
Prometheus + Grafana + AlertManager
    ↓
StarRocks Exporter
    ↓  
StarRocks Metrics API (/metrics)
    ↓
FE/BE 集群
```

**Prometheus 配置**
```yaml
# prometheus.yml
global:
  scrape_interval: 30s
  evaluation_interval: 30s

rule_files:
  - "starrocks_rules.yml"

scrape_configs:
  - job_name: 'starrocks-fe'
    static_configs:
      - targets: ['fe1:8030', 'fe2:8030', 'fe3:8030']
    metrics_path: '/metrics'
    scrape_interval: 30s
    
  - job_name: 'starrocks-be'
    static_configs:
      - targets: ['be1:8040', 'be2:8040', 'be3:8040', 'be4:8040']
    metrics_path: '/metrics'
    scrape_interval: 30s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093
```

**告警规则配置**
```yaml
# starrocks_rules.yml
groups:
  - name: starrocks_cluster
    rules:
    # FE 节点状态告警
    - alert: StarRocksFEDown
      expr: up{job="starrocks-fe"} == 0
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "StarRocks FE 节点离线"
        description: "FE 节点 {{ $labels.instance }} 已离线超过1分钟"
    
    # BE 节点状态告警
    - alert: StarRocksBEDown
      expr: up{job="starrocks-be"} == 0
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "StarRocks BE 节点离线"
        description: "BE 节点 {{ $labels.instance }} 已离线超过1分钟"
    
    # 查询延迟告警
    - alert: HighQueryLatency
      expr: starrocks_fe_query_latency_ms{quantile="0.95"} > 10000
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "查询延迟过高"
        description: "95分位查询延迟 {{ $value }}ms 超过10秒"
    
    # 磁盘使用率告警
    - alert: HighDiskUsage
      expr: starrocks_be_disk_usage_percent > 85
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "磁盘使用率过高"
        description: "BE节点 {{ $labels.instance }} 磁盘使用率 {{ $value }}% 超过85%"
    
    # 内存使用率告警
    - alert: HighMemoryUsage
      expr: starrocks_be_memory_usage_percent > 90
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "内存使用率过高"
        description: "BE节点 {{ $labels.instance }} 内存使用率 {{ $value }}% 超过90%"
```

### 4.2 Grafana 仪表板

**关键监控指标**
```json
{
  "dashboard": {
    "title": "StarRocks 集群监控",
    "panels": [
      {
        "title": "集群状态",
        "type": "stat",
        "targets": [{
          "expr": "count(up{job=~\"starrocks-.*\"} == 1)",
          "legendFormat": "在线节点数"
        }]
      },
      {
        "title": "查询 QPS",
        "type": "graph",
        "targets": [{
          "expr": "rate(starrocks_fe_query_total[5m])",
          "legendFormat": "{{instance}}"
        }]
      },
      {
        "title": "查询延迟分布",
        "type": "graph", 
        "targets": [
          {
            "expr": "starrocks_fe_query_latency_ms{quantile=\"0.50\"}",
            "legendFormat": "P50"
          },
          {
            "expr": "starrocks_fe_query_latency_ms{quantile=\"0.95\"}", 
            "legendFormat": "P95"
          },
          {
            "expr": "starrocks_fe_query_latency_ms{quantile=\"0.99\"}",
            "legendFormat": "P99"
          }
        ]
      },
      {
        "title": "磁盘使用率",
        "type": "graph",
        "targets": [{
          "expr": "starrocks_be_disk_usage_percent",
          "legendFormat": "{{instance}}"
        }]
      },
      {
        "title": "内存使用率",
        "type": "graph", 
        "targets": [{
          "expr": "starrocks_be_memory_usage_percent",
          "legendFormat": "{{instance}}"
        }]
      }
    ]
  }
}
```

### 4.3 自定义监控脚本

```python
#!/usr/bin/env python3
# starrocks_monitor.py

import requests
import json
import time
import logging
from datetime import datetime

class StarRocksMonitor:
    def __init__(self, fe_hosts, be_hosts):
        self.fe_hosts = fe_hosts
        self.be_hosts = be_hosts
        self.logger = self._setup_logger()
    
    def _setup_logger(self):
        logger = logging.getLogger('starrocks_monitor')
        handler = logging.FileHandler('/var/log/starrocks_monitor.log')
        formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
        handler.setFormatter(formatter)
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        return logger
    
    def check_fe_health(self):
        """检查FE节点健康状态"""
        healthy_count = 0
        for host in self.fe_hosts:
            try:
                response = requests.get(f'http://{host}:8030/api/health', timeout=10)
                if response.status_code == 200:
                    healthy_count += 1
                    self.logger.info(f"FE {host} 健康检查通过")
                else:
                    self.logger.error(f"FE {host} 健康检查失败: HTTP {response.status_code}")
            except Exception as e:
                self.logger.error(f"FE {host} 连接失败: {str(e)}")
        
        return {
            'total': len(self.fe_hosts),
            'healthy': healthy_count,
            'unhealthy': len(self.fe_hosts) - healthy_count
        }
    
    def check_be_health(self):
        """检查BE节点健康状态"""
        healthy_count = 0
        for host in self.be_hosts:
            try:
                response = requests.get(f'http://{host}:8040/api/health', timeout=10)
                if response.status_code == 200:
                    healthy_count += 1
                    self.logger.info(f"BE {host} 健康检查通过")
                else:
                    self.logger.error(f"BE {host} 健康检查失败: HTTP {response.status_code}")
            except Exception as e:
                self.logger.error(f"BE {host} 连接失败: {str(e)}")
        
        return {
            'total': len(self.be_hosts),
            'healthy': healthy_count,
            'unhealthy': len(self.be_hosts) - healthy_count
        }
    
    def get_cluster_metrics(self):
        """获取集群指标"""
        try:
            # 从主FE获取集群状态
            fe_host = self.fe_hosts[0]
            response = requests.get(f'http://{fe_host}:8030/metrics', timeout=10)
            
            if response.status_code == 200:
                metrics = self._parse_metrics(response.text)
                return metrics
            else:
                self.logger.error(f"获取集群指标失败: HTTP {response.status_code}")
                return None
                
        except Exception as e:
            self.logger.error(f"获取集群指标异常: {str(e)}")
            return None
    
    def _parse_metrics(self, metrics_text):
        """解析Prometheus格式指标"""
        metrics = {}
        for line in metrics_text.split('\n'):
            if line.startswith('#') or not line.strip():
                continue
            
            parts = line.split(' ')
            if len(parts) == 2:
                metric_name = parts[0]
                metric_value = parts[1]
                metrics[metric_name] = float(metric_value)
        
        return metrics
    
    def send_alert(self, message, level='warning'):
        """发送告警"""
        alert_data = {
            'timestamp': datetime.now().isoformat(),
            'level': level,
            'message': message,
            'service': 'starrocks'
        }
        
        # 发送到AlertManager或其他告警系统
        try:
            # 示例：发送到webhook
            webhook_url = "http://alertmanager:9093/api/v1/alerts"
            requests.post(webhook_url, json=[alert_data], timeout=10)
            self.logger.info(f"告警已发送: {message}")
        except Exception as e:
            self.logger.error(f"告警发送失败: {str(e)}")
    
    def run_health_check(self):
        """执行健康检查"""
        self.logger.info("开始执行集群健康检查")
        
        # FE健康检查
        fe_status = self.check_fe_health()
        if fe_status['unhealthy'] > 0:
            self.send_alert(f"FE节点异常: {fe_status['unhealthy']}/{fe_status['total']} 节点不健康", 'critical')
        
        # BE健康检查  
        be_status = self.check_be_health()
        if be_status['unhealthy'] > 0:
            self.send_alert(f"BE节点异常: {be_status['unhealthy']}/{be_status['total']} 节点不健康", 'critical')
        
        # 集群指标检查
        metrics = self.get_cluster_metrics()
        if metrics:
            # 检查查询延迟
            if 'starrocks_fe_query_latency_ms_p95' in metrics:
                p95_latency = metrics['starrocks_fe_query_latency_ms_p95']
                if p95_latency > 10000:  # 超过10秒
                    self.send_alert(f"查询延迟过高: P95={p95_latency:.2f}ms", 'warning')
            
            # 检查错误率
            if 'starrocks_fe_query_err_rate' in metrics:
                error_rate = metrics['starrocks_fe_query_err_rate']
                if error_rate > 0.05:  # 超过5%
                    self.send_alert(f"查询错误率过高: {error_rate:.2%}", 'warning')
        
        self.logger.info("集群健康检查完成")

# 使用示例
if __name__ == "__main__":
    fe_hosts = ["fe1.company.com", "fe2.company.com", "fe3.company.com"]
    be_hosts = ["be1.company.com", "be2.company.com", "be3.company.com", "be4.company.com"]
    
    monitor = StarRocksMonitor(fe_hosts, be_hosts)
    
    # 单次检查
    monitor.run_health_check()
    
    # 或者定期检查
    # while True:
    #     monitor.run_health_check()
    #     time.sleep(300)  # 5分钟检查一次
```

## 5. 备份和恢复策略

### 5.1 备份策略设计

**分层备份策略**
```
全量备份: 每周执行一次，保留4周
增量备份: 每天执行一次，保留7天  
快照备份: 每小时执行一次，保留24小时
```

**自动化备份脚本**
```bash
#!/bin/bash
# backup_manager.sh

BACKUP_BASE_DIR="/backup/starrocks"
BACKUP_RETENTION_DAYS=30
MYSQL_HOST="starrocks-fe"
MYSQL_PORT="9030"

# 全量备份
full_backup() {
    local backup_name="full_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_BASE_DIR/$backup_name"
    
    echo "开始全量备份: $backup_name"
    
    mysql -h $MYSQL_HOST -P $MYSQL_PORT -u root -e "
        BACKUP SNAPSHOT warehouse.${backup_name}
        TO '${backup_path}'
        PROPERTIES (
            'type' = 'full',
            'timeout' = '3600'
        )
    "
    
    if [ $? -eq 0 ]; then
        echo "✅ 全量备份成功: $backup_name"
        
        # 验证备份
        if verify_backup "$backup_path"; then
            echo "✅ 备份验证通过"
        else
            echo "❌ 备份验证失败"
            return 1
        fi
        
        # 清理旧备份
        cleanup_old_backups "full"
        
    else
        echo "❌ 全量备份失败"
        return 1
    fi
}

# 增量备份
incremental_backup() {
    local backup_name="incr_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_BASE_DIR/$backup_name"
    
    # 获取最新的全量备份
    local base_backup=$(find $BACKUP_BASE_DIR -name "full_*" -type d | sort -r | head -1)
    if [ -z "$base_backup" ]; then
        echo "❌ 未找到基础全量备份，执行全量备份"
        full_backup
        return $?
    fi
    
    local base_backup_name=$(basename "$base_backup")
    echo "开始增量备份: $backup_name (基于 $base_backup_name)"
    
    mysql -h $MYSQL_HOST -P $MYSQL_PORT -u root -e "
        BACKUP SNAPSHOT warehouse.${backup_name}
        TO '${backup_path}' 
        PROPERTIES (
            'type' = 'incremental',
            'base_snapshot' = '${base_backup_name}',
            'timeout' = '1800'
        )
    "
    
    if [ $? -eq 0 ]; then
        echo "✅ 增量备份成功: $backup_name"
        cleanup_old_backups "incr"
    else
        echo "❌ 增量备份失败"
        return 1
    fi
}

# 备份验证
verify_backup() {
    local backup_path=$1
    
    # 检查备份文件完整性
    if [ ! -f "$backup_path/meta" ]; then
        echo "❌ 备份元数据文件缺失"
        return 1
    fi
    
    # 检查备份大小
    local backup_size=$(du -s "$backup_path" | awk '{print $1}')
    if [ $backup_size -lt 1000 ]; then  # 小于1MB认为异常
        echo "❌ 备份文件异常小: ${backup_size}KB"
        return 1
    fi
    
    echo "✅ 备份验证通过: ${backup_size}KB"
    return 0
}

# 清理旧备份
cleanup_old_backups() {
    local backup_type=$1
    local pattern="${backup_type}_*"
    
    echo "清理旧备份: $pattern"
    find $BACKUP_BASE_DIR -name "$pattern" -type d -mtime +$BACKUP_RETENTION_DAYS -exec rm -rf {} \;
}

# 恢复功能
restore_backup() {
    local backup_name=$1
    local restore_database=${2:-warehouse_restored}
    
    if [ -z "$backup_name" ]; then
        echo "用法: restore_backup <backup_name> [target_database]"
        return 1
    fi
    
    local backup_path="$BACKUP_BASE_DIR/$backup_name"
    if [ ! -d "$backup_path" ]; then
        echo "❌ 备份不存在: $backup_path"
        return 1
    fi
    
    echo "开始恢复备份: $backup_name -> $restore_database"
    
    mysql -h $MYSQL_HOST -P $MYSQL_PORT -u root -e "
        RESTORE SNAPSHOT ${restore_database}.${backup_name}
        FROM '${backup_path}'
        PROPERTIES (
            'backup_timestamp' = '$(date +%Y-%m-%d-%H-%M-%S)',
            'timeout' = '3600'
        )
    "
    
    if [ $? -eq 0 ]; then
        echo "✅ 备份恢复成功"
    else
        echo "❌ 备份恢复失败"
        return 1
    fi
}

# 主函数
main() {
    case "$1" in
        "full")
            full_backup
            ;;
        "incremental"|"incr")
            incremental_backup
            ;;
        "restore")
            restore_backup "$2" "$3"
            ;;
        "cleanup")
            cleanup_old_backups "full"
            cleanup_old_backups "incr"
            ;;
        *)
            echo "用法: $0 {full|incremental|restore|cleanup}"
            echo "恢复用法: $0 restore <backup_name> [target_database]"
            exit 1
            ;;
    esac
}

main "$@"
```

**定时任务配置**
```bash
# crontab -e
# 每周日 2:00 执行全量备份
0 2 * * 0 /opt/scripts/backup_manager.sh full >> /var/log/backup.log 2>&1

# 每天 3:00 执行增量备份（除周日）
0 3 * * 1-6 /opt/scripts/backup_manager.sh incr >> /var/log/backup.log 2>&1

# 每月1号 4:00 清理旧备份
0 4 1 * * /opt/scripts/backup_manager.sh cleanup >> /var/log/backup.log 2>&1
```

### 5.2 灾备方案

**跨机房灾备架构**
```
主机房 (主集群)
    ↓ 异步复制
备机房 (备集群)
    ↓ 冷备份  
对象存储 (云备份)
```

**跨机房同步脚本**
```bash
#!/bin/bash  
# disaster_recovery.sh

PRIMARY_CLUSTER="primary-starrocks"
BACKUP_CLUSTER="backup-starrocks"
SYNC_INTERVAL=3600  # 1小时同步一次

sync_to_backup_cluster() {
    echo "开始同步数据到备集群"
    
    # 1. 在主集群创建快照
    local snapshot_name="dr_sync_$(date +%Y%m%d_%H%M%S)"
    
    mysql -h $PRIMARY_CLUSTER -P 9030 -u root -e "
        BACKUP SNAPSHOT warehouse.${snapshot_name}
        TO 's3://disaster-recovery-bucket/${snapshot_name}'
        PROPERTIES (
            'type' = 'full',
            'timeout' = '7200'
        )
    "
    
    # 2. 在备集群恢复快照
    sleep 300  # 等待备份完成传输
    
    mysql -h $BACKUP_CLUSTER -P 9030 -u root -e "
        RESTORE SNAPSHOT warehouse_backup.${snapshot_name}
        FROM 's3://disaster-recovery-bucket/${snapshot_name}'
        PROPERTIES (
            'timeout' = '7200'
        )
    "
    
    echo "数据同步完成: $snapshot_name"
}

# 故障切换
failover_to_backup() {
    echo "开始故障切换到备集群"
    
    # 1. 停止主集群访问
    # 2. 激活备集群
    # 3. 更新DNS或负载均衡配置
    # 4. 通知业务方切换连接
    
    echo "故障切换完成"
}

# 主集群恢复
restore_primary() {
    echo "开始恢复主集群"
    
    # 1. 从备集群同步最新数据到主集群
    # 2. 验证数据一致性
    # 3. 切换回主集群
    # 4. 恢复正常同步
    
    echo "主集群恢复完成"
}

case "$1" in
    "sync")
        sync_to_backup_cluster
        ;;
    "failover")
        failover_to_backup
        ;;  
    "restore")
        restore_primary
        ;;
    *)
        echo "用法: $0 {sync|failover|restore}"
        exit 1
        ;;
esac
```

## 6. 升级和维护

### 6.1 版本升级策略

**滚动升级流程**
```bash
#!/bin/bash
# rolling_upgrade.sh

OLD_VERSION="2.5.4"
NEW_VERSION="3.0.1"
CLUSTER_NODES="fe1 fe2 fe3 be1 be2 be3 be4"

# 升级前检查
pre_upgrade_check() {
    echo "执行升级前检查..."
    
    # 检查集群健康状态
    for node in $CLUSTER_NODES; do
        if ! ping -c 1 $node > /dev/null 2>&1; then
            echo "❌ 节点 $node 不可达"
            return 1
        fi
    done
    
    # 检查正在运行的查询
    active_queries=$(mysql -h fe1 -P 9030 -u root -se "
        SELECT COUNT(*) FROM information_schema.processlist 
        WHERE command != 'Sleep'
    ")
    
    if [ $active_queries -gt 10 ]; then
        echo "⚠️  警告: 当前有 $active_queries 个活跃查询"
        read -p "是否继续升级? (y/N) " -n 1 -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # 创建升级前备份
    echo "创建升级前备份..."
    /opt/scripts/backup_manager.sh full
    
    echo "✅ 升级前检查通过"
    return 0
}

# 升级单个节点
upgrade_node() {
    local node=$1
    local node_type=$2  # fe 或 be
    
    echo "升级节点: $node ($node_type)"
    
    # 1. 停止服务
    ssh $node "systemctl stop starrocks-$node_type"
    
    # 2. 备份配置
    ssh $node "cp -r /opt/starrocks/$node_type/conf /opt/starrocks/${node_type}_conf_backup_$(date +%Y%m%d)"
    
    # 3. 升级软件包
    scp starrocks-$NEW_VERSION-$node_type.tar.gz $node:/tmp/
    ssh $node "
        cd /opt/starrocks
        tar -xzf /tmp/starrocks-$NEW_VERSION-$node_type.tar.gz
        mv $node_type ${node_type}_$OLD_VERSION
        mv starrocks-$NEW_VERSION-$node_type $node_type
    "
    
    # 4. 恢复配置
    ssh $node "cp -r ${node_type}_conf_backup_$(date +%Y%m%d)/* /opt/starrocks/$node_type/conf/"
    
    # 5. 启动服务
    ssh $node "systemctl start starrocks-$node_type"
    
    # 6. 健康检查
    sleep 30
    if ssh $node "systemctl is-active starrocks-$node_type" | grep -q "active"; then
        echo "✅ 节点 $node 升级成功"
        return 0
    else
        echo "❌ 节点 $node 升级失败"
        # 回滚
        ssh $node "
            systemctl stop starrocks-$node_type
            mv /opt/starrocks/$node_type /opt/starrocks/${node_type}_failed_$NEW_VERSION
            mv /opt/starrocks/${node_type}_$OLD_VERSION /opt/starrocks/$node_type
            systemctl start starrocks-$node_type
        "
        return 1
    fi
}

# 执行滚动升级
rolling_upgrade() {
    echo "开始滚动升级: $OLD_VERSION -> $NEW_VERSION"
    
    # 1. 升级前检查
    if ! pre_upgrade_check; then
        echo "❌ 升级前检查失败，取消升级"
        return 1
    fi
    
    # 2. 升级BE节点（逐个升级）
    for be in be1 be2 be3 be4; do
        if ! upgrade_node $be "be"; then
            echo "❌ BE节点 $be 升级失败，停止升级"
            return 1
        fi
        
        # 等待集群稳定
        sleep 60
        
        # 检查集群状态
        if ! check_cluster_health; then
            echo "❌ 集群健康检查失败，停止升级"
            return 1
        fi
    done
    
    # 3. 升级FE节点（逐个升级，先升级follower）
    # 确定master节点
    master_fe=$(mysql -h fe1 -P 9030 -u root -se "SHOW PROC '/frontends'" | grep "true" | awk '{print $2}')
    
    for fe in fe1 fe2 fe3; do
        if [ "$fe" != "$master_fe" ]; then
            if ! upgrade_node $fe "fe"; then
                echo "❌ FE节点 $fe 升级失败，停止升级"
                return 1
            fi
            sleep 60
        fi
    done
    
    # 4. 最后升级master FE节点
    if ! upgrade_node $master_fe "fe"; then
        echo "❌ Master FE节点 $master_fe 升级失败"
        return 1
    fi
    
    echo "✅ 滚动升级完成"
    return 0
}

# 检查集群健康状态
check_cluster_health() {
    local fe_count=$(mysql -h fe1 -P 9030 -u root -se "SHOW PROC '/frontends'" | grep -c "true\|false")
    local be_count=$(mysql -h fe1 -P 9030 -u root -se "SHOW PROC '/backends'" | grep -c "true")
    
    if [ $fe_count -ge 3 ] && [ $be_count -ge 4 ]; then
        echo "✅ 集群健康检查通过: FE=$fe_count, BE=$be_count"
        return 0
    else
        echo "❌ 集群健康检查失败: FE=$fe_count, BE=$be_count"
        return 1
    fi
}

# 主函数
case "$1" in
    "check")
        pre_upgrade_check
        ;;
    "upgrade")
        rolling_upgrade
        ;;
    "health")
        check_cluster_health
        ;;
    *)
        echo "用法: $0 {check|upgrade|health}"
        exit 1
        ;;
esac
```

### 6.2 日常维护任务

**维护任务清单**
```bash
#!/bin/bash
# maintenance_tasks.sh

# 日志清理
cleanup_logs() {
    echo "清理过期日志文件..."
    
    # FE日志清理
    find /opt/starrocks/fe/log -name "*.log.*" -mtime +7 -delete
    find /opt/starrocks/fe/log -name "*.out.*" -mtime +7 -delete
    
    # BE日志清理  
    find /opt/starrocks/be/log -name "*.log.*" -mtime +7 -delete
    find /opt/starrocks/be/log -name "*.out.*" -mtime +7 -delete
    
    echo "✅ 日志清理完成"
}

# 统计信息更新
update_statistics() {
    echo "更新表统计信息..."
    
    # 获取所有表列表
    tables=$(mysql -h fe1 -P 9030 -u root -se "
        SELECT CONCAT(table_schema, '.', table_name) 
        FROM information_schema.tables 
        WHERE table_schema NOT IN ('information_schema', '_statistics_')
    ")
    
    for table in $tables; do
        echo "更新统计信息: $table"
        mysql -h fe1 -P 9030 -u root -e "ANALYZE TABLE $table"
    done
    
    echo "✅ 统计信息更新完成"
}

# 压缩优化
optimize_compaction() {
    echo "触发压缩优化..."
    
    # 获取BE列表
    be_hosts=$(mysql -h fe1 -P 9030 -u root -se "
        SELECT Host FROM information_schema.be_tablets 
        GROUP BY Host
    ")
    
    for be_host in $be_hosts; do
        echo "触发BE压缩: $be_host"
        curl -X POST "http://$be_host:8040/api/compaction/run?tablet_id=-1&compact_type=cumulative"
    done
    
    echo "✅ 压缩优化完成"  
}

# 孤立文件清理
cleanup_orphan_files() {
    echo "清理孤立文件..."
    
    # 通过API触发垃圾清理
    be_hosts=$(mysql -h fe1 -P 9030 -u root -se "
        SELECT Host FROM information_schema.be_tablets 
        GROUP BY Host  
    ")
    
    for be_host in $be_hosts; do
        echo "清理孤立文件: $be_host"
        curl -X POST "http://$be_host:8040/api/trash/clean"
    done
    
    echo "✅ 孤立文件清理完成"
}

# 性能基准测试
run_performance_test() {
    echo "执行性能基准测试..."
    
    # 执行简单查询测试
    start_time=$(date +%s)
    
    mysql -h fe1 -P 9030 -u root -e "
        SELECT 
            COUNT(*) as total_records,
            COUNT(DISTINCT table_name) as table_count
        FROM information_schema.be_tablets
    " > /dev/null
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    echo "基准查询耗时: ${duration}秒"
    
    # 记录性能指标
    echo "$(date): 基准查询耗时 ${duration}秒" >> /var/log/performance_baseline.log
    
    echo "✅ 性能测试完成"
}

# 健康检查
health_check() {
    echo "执行集群健康检查..."
    
    # 检查FE状态
    fe_count=$(mysql -h fe1 -P 9030 -u root -se "
        SELECT COUNT(*) FROM information_schema.frontends WHERE alive = 'true'
    ")
    
    # 检查BE状态
    be_count=$(mysql -h fe1 -P 9030 -u root -se "
        SELECT COUNT(*) FROM information_schema.backends WHERE alive = 'true' 
    ")
    
    # 检查副本健康状态
    unhealthy_tablets=$(mysql -h fe1 -P 9030 -u root -se "
        SELECT COUNT(*) FROM information_schema.tablet_health 
        WHERE state != 'NORMAL'
    ")
    
    echo "集群状态: FE=$fe_count, BE=$be_count, 异常tablet=$unhealthy_tablets"
    
    if [ $unhealthy_tablets -gt 0 ]; then
        echo "⚠️  发现异常tablet，需要关注"
        mysql -h fe1 -P 9030 -u root -e "
            SELECT * FROM information_schema.tablet_health 
            WHERE state != 'NORMAL'
            LIMIT 10
        "
    fi
    
    echo "✅ 健康检查完成"
}

# 主函数
case "$1" in
    "logs")
        cleanup_logs
        ;;
    "stats")
        update_statistics
        ;;
    "compact")
        optimize_compaction
        ;;
    "cleanup")
        cleanup_orphan_files
        ;;
    "performance")
        run_performance_test
        ;;
    "health")
        health_check
        ;;
    "all")
        cleanup_logs
        update_statistics
        optimize_compaction  
        cleanup_orphan_files
        run_performance_test
        health_check
        ;;
    *)
        echo "用法: $0 {logs|stats|compact|cleanup|performance|health|all}"
        exit 1
        ;;
esac
```

**定时维护任务**
```bash
# crontab -e

# 每天凌晨1点清理日志
0 1 * * * /opt/scripts/maintenance_tasks.sh logs

# 每周日凌晨2点更新统计信息
0 2 * * 0 /opt/scripts/maintenance_tasks.sh stats

# 每天凌晨3点触发压缩优化
0 3 * * * /opt/scripts/maintenance_tasks.sh compact

# 每周六凌晨4点清理孤立文件
0 4 * * 6 /opt/scripts/maintenance_tasks.sh cleanup

# 每小时执行健康检查
0 * * * * /opt/scripts/maintenance_tasks.sh health

# 每天早上8点执行性能基准测试
0 8 * * * /opt/scripts/maintenance_tasks.sh performance
```

## 7. 最佳实践总结

### 7.1 部署成功关键因素

**硬件规划**
- 根据数据量和查询负载合理规划硬件配置
- 采用分层存储策略优化成本
- 预留足够的扩展空间

**网络设计**
- 使用高带宽网络，推荐万兆网络
- 合理规划网络拓扑，避免单点故障
- 配置网络优化参数

**安全配置**
- 实施最小权限原则
- 启用SSL/TLS加密
- 配置审计日志和监控

### 7.2 运维管理要点

**监控告警**
- 建立全面的监控指标体系
- 设置合理的告警阈值
- 实现自动化故障处理

**备份恢复**
- 制定完善的备份策略
- 定期验证备份可用性
- 建立跨机房灾备方案

**升级维护**
- 采用滚动升级策略
- 做好升级前测试验证
- 建立回滚应急预案

### 7.3 性能优化建议

**表设计优化**
- 合理选择表模型和分区策略
- 优化分布键和排序键设置
- 使用物化视图加速查询

**集群调优**
- 根据硬件资源调整配置参数
- 定期分析和优化慢查询
- 监控系统资源使用情况

生产环境的成功部署需要在技术、流程、团队等多个维度做好充分准备。通过遵循最佳实践，可以构建一个高性能、高可用、易维护的 StarRocks 数据平台。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../06-advanced-features/big-data-ecosystem.md) | [➡️ 下一页](oracle-migration-best-practices.md)
---