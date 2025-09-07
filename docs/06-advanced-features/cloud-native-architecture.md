---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](colocation-join.md) | [➡️ 下一页](big-data-ecosystem.md)
---

# 云原生架构：Shared-data模式

## 概述

StarRocks 3.0+引入了**Shared-data架构**（存算分离），这是面向云原生环境设计的新一代架构模式。相比传统的Shared-nothing架构，Shared-data模式提供了更好的弹性扩展能力和成本效益。

## 架构对比

### Shared-nothing架构（传统模式）

```
FE节点 (Frontend)
├── 元数据管理
├── SQL解析优化  
└── 查询协调

BE节点 (Backend)
├── 数据存储 (本地磁盘)
├── 计算执行
└── 数据副本管理
```

**特点**：
- ✅ 查询性能高（数据本地化）
- ✅ 架构简单
- ❌ 存储计算耦合
- ❌ 扩容复杂（数据迁移）
- ❌ 资源利用率低

### Shared-data架构（云原生模式）

```
FE节点 (Frontend)
├── 元数据管理
├── SQL解析优化
└── 查询协调

CN节点 (Compute Node)
├── 无状态计算
├── 本地缓存
└── 弹性扩缩容

对象存储 (Object Storage)
├── 数据持久化 (S3/OSS/COS)
├── 多副本保证可靠性
└── 无限扩展容量
```

**核心优势**：
- 🚀 **弹性扩缩容**：CN节点可以秒级扩缩容
- 💰 **成本优化**：按需使用计算资源
- 🔄 **存算分离**：独立扩展存储和计算
- ☁️ **云原生**：天然适配云环境
- 📈 **高可用**：对象存储保证数据可靠性

## 部署架构

### 云环境部署

```yaml
# Kubernetes部署示例
apiVersion: apps/v1
kind: Deployment
metadata:
  name: starrocks-fe
spec:
  replicas: 1
  selector:
    matchLabels:
      app: starrocks-fe
  template:
    metadata:
      labels:
        app: starrocks-fe
    spec:
      containers:
      - name: fe
        image: starrocks/fe-ubuntu:3.3-latest
        env:
        - name: MODE
          value: "shared_data"
        - name: CLOUD_PROVIDER
          value: "aws"  # 或 aliyun, tencent
        - name: AWS_S3_BUCKET
          value: "starrocks-data"
        - name: AWS_S3_REGION
          value: "us-west-2"
        ports:
        - containerPort: 8030
        - containerPort: 9030

---
apiVersion: apps/v1
kind: Deployment  
metadata:
  name: starrocks-cn
spec:
  replicas: 3  # 可以动态调整
  selector:
    matchLabels:
      app: starrocks-cn
  template:
    metadata:
      labels:
        app: starrocks-cn
    spec:
      containers:
      - name: cn
        image: starrocks/cn-ubuntu:3.3-latest
        env:
        - name: MODE
          value: "shared_data"
        - name: FE_ENDPOINTS
          value: "starrocks-fe:9010"
        resources:
          requests:
            cpu: "2"
            memory: "4Gi"
          limits:
            cpu: "8" 
            memory: "16Gi"
```

### 对象存储配置

#### AWS S3配置

```sql
-- 创建存储卷
CREATE STORAGE VOLUME s3_storage
TYPE = S3
LOCATIONS = ("s3://starrocks-bucket/data")
PROPERTIES (
    "aws.s3.region" = "us-west-2",
    "aws.s3.endpoint" = "s3.us-west-2.amazonaws.com",
    "aws.s3.use_aws_sdk_default_behavior" = "true",
    "aws.s3.enable_ssl" = "true"
);

-- 设为默认存储
SET starrocks_default_storage_volume = s3_storage;
```

#### 阿里云OSS配置

```sql
CREATE STORAGE VOLUME oss_storage  
TYPE = S3
LOCATIONS = ("oss://starrocks-bucket/data")
PROPERTIES (
    "aws.s3.region" = "oss-cn-hangzhou",
    "aws.s3.endpoint" = "oss-cn-hangzhou.aliyuncs.com",
    "aws.s3.access_key" = "your_access_key",
    "aws.s3.secret_key" = "your_secret_key",
    "aws.s3.enable_ssl" = "true"
);
```

#### 腾讯云COS配置

```sql
CREATE STORAGE VOLUME cos_storage
TYPE = S3  
LOCATIONS = ("cosn://starrocks-bucket/data")
PROPERTIES (
    "aws.s3.region" = "ap-beijing", 
    "aws.s3.endpoint" = "cos.ap-beijing.myqcloud.com",
    "aws.s3.access_key" = "your_access_key",
    "aws.s3.secret_key" = "your_secret_key"
);
```

## 建表示例

### Shared-data模式建表

```sql
-- 1. 基础表（使用默认存储卷）
CREATE TABLE orders_cloud (
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    order_time DATETIME NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) NOT NULL
)
PRIMARY KEY(order_id)
PARTITION BY date_trunc('day', order_time)
DISTRIBUTED BY HASH(order_id) BUCKETS 32
PROPERTIES (
    "replication_num" = "1",  -- Shared-data模式通常使用1副本
    "storage_volume" = "s3_storage"  -- 指定存储卷
);

-- 2. 指定存储卷的表
CREATE TABLE user_behavior_cloud (
    event_time DATETIME NOT NULL,
    user_id BIGINT NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    page_url VARCHAR(500),
    properties JSON
)
DUPLICATE KEY(event_time, user_id)
PARTITION BY date_trunc('day', event_time)
DISTRIBUTED BY RANDOM
STORAGE VOLUME s3_storage  -- 表级别指定存储卷
PROPERTIES (
    "replication_num" = "1"
);

-- 3. 冷热数据分层存储
CREATE TABLE metrics_tiered (
    metric_time DATETIME NOT NULL,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DOUBLE,
    tags JSON
)
DUPLICATE KEY(metric_time, metric_name)
PARTITION BY date_trunc('day', metric_time)
DISTRIBUTED BY HASH(metric_name) BUCKETS 16
PROPERTIES (
    "replication_num" = "1",
    "storage_volume" = "s3_hot_storage",
    -- 冷数据迁移策略
    "storage_cooldown_time" = "7d",
    "storage_cooldown_volume" = "s3_cold_storage"
);
```

## 弹性扩缩容

### 自动扩缩容配置

```yaml
# HPA配置（水平Pod自动伸缩）
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: starrocks-cn-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: starrocks-cn
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # 5分钟稳定窗口
      selectPolicy: Min
      policies:
      - type: Percent
        value: 50      # 每次最多缩容50%
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60   # 1分钟稳定窗口
      selectPolicy: Max
      policies:
      - type: Percent
        value: 100     # 每次最多扩容100%
        periodSeconds: 60
```

### 手动扩缩容

```sql
-- 查看当前CN节点状态
SHOW COMPUTE NODES;

-- 动态添加CN节点（Kubernetes环境）
kubectl scale deployment starrocks-cn --replicas=10

-- 查看扩容效果
SHOW COMPUTE NODES;
```

## 性能优化

### 缓存优化

```sql
-- 配置CN节点本地缓存
SET GLOBAL enable_load_volume_from_conf = true;

-- 查看缓存命中率
SELECT 
    node_id,
    cache_hit_rate,
    cache_size_bytes,
    cache_used_bytes
FROM information_schema.cn_cache_stats;

-- 优化高频查询表的缓存
ALTER TABLE hot_queries_table 
SET ("datacache.enable" = "true", "datacache.partition_duration" = "1d");
```

### 数据预加载

```sql
-- 预热关键数据到缓存
CACHE SELECT * FROM important_table 
WHERE date >= CURRENT_DATE() - INTERVAL 7 DAY;

-- 批量预热分区
ALTER TABLE sales_data 
CACHE PARTITION (p20240101, p20240102, p20240103);
```

## 成本优化

### 存储分层策略

```sql
-- 创建不同性能级别的存储卷
-- 热数据存储（高性能）
CREATE STORAGE VOLUME hot_storage
TYPE = S3
LOCATIONS = ("s3://starrocks-hot/data")  
PROPERTIES (
    "aws.s3.region" = "us-west-2",
    "aws.s3.endpoint" = "s3.us-west-2.amazonaws.com",
    "storage_class" = "STANDARD"  -- 标准存储
);

-- 冷数据存储（低成本）
CREATE STORAGE VOLUME cold_storage
TYPE = S3
LOCATIONS = ("s3://starrocks-cold/data")
PROPERTIES (
    "aws.s3.region" = "us-west-2", 
    "aws.s3.endpoint" = "s3.us-west-2.amazonaws.com",
    "storage_class" = "GLACIER"  -- 冷存储
);

-- 自动分层策略
CREATE TABLE sales_history (
    sale_date DATE NOT NULL,
    product_id BIGINT,
    amount DECIMAL(10,2)
)
PARTITION BY RANGE(sale_date) (
    PARTITION p_current VALUES [('2024-01-01'), ('2024-02-01'))
)
DISTRIBUTED BY HASH(product_id)
PROPERTIES (
    "storage_volume" = "hot_storage",
    -- 30天后迁移到冷存储
    "storage_cooldown_time" = "30d", 
    "storage_cooldown_volume" = "cold_storage"
);
```

### 计算资源优化

```yaml
# 基于时间的自动扩缩容
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: starrocks-cn-scheduled
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: starrocks-cn
  minReplicas: 2    # 凌晨最小节点数
  maxReplicas: 50   # 白天最大节点数
  # 结合Cron Job实现定时扩缩容
```

## 监控和运维

### 关键监控指标

```sql
-- 存储使用情况
SELECT 
    storage_volume_name,
    total_size_bytes / 1024 / 1024 / 1024 as total_size_gb,
    used_size_bytes / 1024 / 1024 / 1024 as used_size_gb,
    used_size_bytes * 100.0 / total_size_bytes as usage_percent
FROM information_schema.storage_volumes;

-- CN节点性能
SELECT 
    node_id,
    cpu_usage_percent,
    memory_usage_percent, 
    disk_usage_percent,
    query_count_per_second
FROM information_schema.cn_nodes;

-- 缓存性能
SELECT
    table_name,
    cache_hit_rate,
    avg_query_time_ms,
    cache_size_mb
FROM information_schema.table_cache_stats
WHERE cache_hit_rate < 0.8;  -- 命中率低于80%的表
```

### 告警配置

```yaml
# Prometheus告警规则
groups:
- name: starrocks.shared_data
  rules:
  - alert: HighCNNodeUsage
    expr: starrocks_cn_cpu_usage > 90
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "CN节点CPU使用率过高"
      
  - alert: LowCacheHitRate  
    expr: starrocks_cache_hit_rate < 0.5
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "缓存命中率过低"
      
  - alert: StorageUsageHigh
    expr: starrocks_storage_usage_percent > 85
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "存储使用率过高"
```

## 迁移指南

### 从Shared-nothing迁移到Shared-data

```sql
-- 1. 备份现有数据
BACKUP SNAPSHOT example_db.snapshot_20240101
TO `s3://backup-bucket/snapshots/`
PROPERTIES (
    "aws.s3.access_key" = "your_key",
    "aws.s3.secret_key" = "your_secret"
);

-- 2. 在Shared-data环境恢复
RESTORE SNAPSHOT example_db.snapshot_20240101
FROM `s3://backup-bucket/snapshots/`
PROPERTIES (
    "backup_timestamp" = "2024-01-01-10-00-00",
    "target_storage_volume" = "s3_storage"
);

-- 3. 验证数据一致性
SELECT COUNT(*) FROM old_table;
SELECT COUNT(*) FROM new_table;
```

## 最佳实践

### 1. 架构选择建议

| 场景 | 推荐架构 | 原因 |
|------|---------|------|
| **云上新建** | Shared-data | 天然云原生，弹性扩容 |
| **资源弹性需求** | Shared-data | 按需扩缩容，成本优化 |
| **极致查询性能** | Shared-nothing | 数据本地化，延迟更低 |
| **混合云部署** | Shared-data | 跨云数据共享 |

### 2. 性能调优建议

- **合理配置缓存**：热数据保持高缓存命中率
- **数据预热**：关键查询数据提前加载到缓存
- **分区策略**：按查询模式合理分区，提高裁剪效率
- **计算节点配置**：根据查询复杂度调整CN节点规格

### 3. 成本控制策略

- **自动扩缩容**：根据业务峰谷配置弹性策略
- **存储分层**：热数据用高性能存储，冷数据用低成本存储
- **资源监控**：建立完整的监控和告警体系

## 小结

Shared-data架构是StarRocks面向云原生时代的核心特性：

- 🚀 **弹性扩缩容**：秒级调整计算资源
- 💰 **成本优化**：按需使用，存储计算分离计费
- ☁️ **云原生**：完美适配Kubernetes和云服务
- 🔄 **高可用**：对象存储天然多副本保证可靠性

对于云上部署，特别是有弹性需求的场景，强烈推荐使用Shared-data架构。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](colocation-join.md) | [➡️ 下一页](big-data-ecosystem.md)
---