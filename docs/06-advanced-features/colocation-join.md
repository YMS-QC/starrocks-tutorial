---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](dynamic-partitioning.md) | [➡️ 下一页](cloud-native-architecture.md)
---

# Colocation Join

Colocation Join 是 StarRocks 提供的高性能 Join 优化技术，通过将具有相同分布键的表数据存储在相同节点上，实现本地 Join，大幅提升多表关联查询的性能。本章节详细介绍 Colocation Join 的原理、配置方法和最佳实践。

## 1. Colocation Join 概述

### 1.1 工作原理

**传统 Join 流程**
```
表A数据 (Node1, Node2, Node3)
    ↓ 网络传输 (Shuffle)
Join操作节点
    ↑ 网络传输 (Shuffle)  
表B数据 (Node1, Node2, Node3)
```

**Colocation Join 流程**
```
Node1: 表A分片1 + 表B分片1 → 本地Join
Node2: 表A分片2 + 表B分片2 → 本地Join  
Node3: 表A分片3 + 表B分片3 → 本地Join
```

### 1.2 核心优势

**性能提升**
- 消除网络传输开销，Join 速度提升 5-10 倍
- 减少内存使用，避免大表 Shuffle
- 降低 CPU 使用率，提升整体吞吐量

**资源节约**
- 减少网络带宽消耗
- 降低内存峰值使用
- 减少磁盘 I/O 操作

**扩展性增强**
- 支持更大规模的表 Join
- 线性扩展能力
- 更高的并发查询支持

### 1.3 适用场景

| 场景 | 描述 | 性能提升 |
|------|------|----------|
| 事实表与维度表Join | 订单表 Join 用户表、商品表 | 5-10倍 |
| 大表与大表Join | 历史订单表 Join 用户行为表 | 3-8倍 |
| 多表复杂Join | 涉及3个以上表的复杂关联 | 2-5倍 |
| 高频Join查询 | 实时报表、Dashboard查询 | 显著提升 |

## 2. Colocation Group 配置

### 2.1 创建 Colocation Group

```sql
-- 创建 Colocation Group
CREATE RESOURCE GROUP colocation_group_orders
PROPERTIES (
    "type" = "colocation"
);

-- 查看 Colocation Group 信息
SHOW PROC '/colocation_group';
```

### 2.2 表的 Colocation 配置

**主表配置**
```sql
-- 创建用户表（主表）
CREATE TABLE users (
    user_id BIGINT NOT NULL,
    user_name VARCHAR(100),
    email VARCHAR(200),
    register_date DATE,
    user_level INT,
    region_id INT
) ENGINE=OLAP
DUPLICATE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "replication_num" = "3",
    "colocate_with" = "user_order_group"  -- 指定Colocation Group
);
```

**关联表配置**
```sql
-- 创建订单表（关联表，使用相同的分布键和桶数）
CREATE TABLE orders (
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,     -- 与users表的分布键相同
    product_id BIGINT,
    order_date DATE,
    amount DECIMAL(10,2),
    status VARCHAR(20)
) ENGINE=OLAP
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32  -- 桶数必须相同
PROPERTIES (
    "replication_num" = "3",
    "colocate_with" = "user_order_group"   -- 相同的Colocation Group
);

-- 创建订单详情表  
CREATE TABLE order_details (
    detail_id BIGINT NOT NULL,
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,     -- 关键：包含相同的分布键
    product_id BIGINT,
    quantity INT,
    unit_price DECIMAL(8,2)
) ENGINE=OLAP
DUPLICATE KEY(detail_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32  -- 相同的分布键和桶数
PROPERTIES (
    "replication_num" = "3",
    "colocate_with" = "user_order_group"
);
```

### 2.3 分区表的 Colocation

```sql
-- 创建分区表的Colocation配置
CREATE TABLE user_monthly_stats (
    user_id BIGINT NOT NULL,
    stat_month DATE NOT NULL,
    order_count INT,
    total_amount DECIMAL(15,2)
) ENGINE=OLAP
DUPLICATE KEY(user_id, stat_month)
PARTITION BY RANGE(stat_month) (
    PARTITION p202301 VALUES [('2023-01-01'), ('2023-02-01')),
    PARTITION p202302 VALUES [('2023-02-01'), ('2023-03-01')),
    PARTITION p202303 VALUES [('2023-03-01'), ('2023-04-01'))
)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "replication_num" = "3",
    "colocate_with" = "user_order_group"
);
```

### 2.4 配置验证

```sql
-- 验证表是否正确配置Colocation
SHOW PROC '/colocation_group/user_order_group';

-- 查看表的Colocation状态
SELECT 
    table_name,
    colocate_group,
    distribution_key,
    bucket_num
FROM information_schema.tables_config 
WHERE colocate_group = 'user_order_group';

-- 验证数据分布是否一致
SHOW PROC '/backends';
```

## 3. Colocation Join 查询优化

### 3.1 查询自动优化

```sql
-- 自动使用Colocation Join的查询
SELECT 
    u.user_name,
    u.user_level,
    COUNT(o.order_id) as order_count,
    SUM(o.amount) as total_amount
FROM users u
JOIN orders o ON u.user_id = o.user_id  -- 基于分布键的等值Join
WHERE u.register_date >= '2023-01-01'
GROUP BY u.user_name, u.user_level;

-- 检查是否使用了Colocation Join
EXPLAIN SELECT 
    u.user_name,
    SUM(o.amount) as total_amount
FROM users u
JOIN orders o ON u.user_id = o.user_id
GROUP BY u.user_name;

-- 执行计划中会显示 "COLOCATE" 标识
```

### 3.2 复杂多表 Join

```sql
-- 三表Colocation Join
SELECT 
    u.user_name,
    o.order_date,
    p.product_name,
    od.quantity,
    od.unit_price
FROM users u
JOIN orders o ON u.user_id = o.user_id
JOIN order_details od ON o.order_id = od.order_id AND o.user_id = od.user_id
JOIN products p ON od.product_id = p.product_id
WHERE u.user_level >= 3
  AND o.order_date >= '2023-01-01';

-- 查看执行计划
EXPLAIN VERBOSE SELECT ...;
```

### 3.3 分区表 Colocation Join

```sql
-- 分区表之间的Colocation Join
SELECT 
    u.user_id,
    u.user_name,
    ums.stat_month,
    ums.order_count,
    ums.total_amount
FROM users u
JOIN user_monthly_stats ums ON u.user_id = ums.user_id
WHERE ums.stat_month >= '2023-01-01'
  AND u.user_level >= 2;
```

## 4. 性能监控和调优

### 4.1 性能对比测试

```sql
-- 创建测试数据
INSERT INTO users SELECT 
    number as user_id,
    CONCAT('user_', number) as user_name,
    CONCAT('user_', number, '@test.com') as email,
    DATE_ADD('2020-01-01', INTERVAL (number % 1000) DAY) as register_date,
    (number % 5) + 1 as user_level,
    (number % 10) + 1 as region_id
FROM numbers(1000000);  -- 100万用户

INSERT INTO orders SELECT
    number as order_id,
    (number % 1000000) + 1 as user_id,
    (number % 10000) + 1 as product_id,
    DATE_ADD('2023-01-01', INTERVAL (number % 365) DAY) as order_date,
    (number % 1000) + 1 as amount,
    CASE (number % 4) 
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'paid'
        WHEN 2 THEN 'shipped'
        ELSE 'delivered'
    END as status
FROM numbers(10000000);  -- 1000万订单

-- 性能测试SQL
SELECT 
    COUNT(*) as join_count,
    AVG(o.amount) as avg_amount
FROM users u
JOIN orders o ON u.user_id = o.user_id
WHERE u.user_level >= 3;
```

**性能对比结果示例**
```
常规Join:      执行时间 45.2秒，网络传输 2.1GB
Colocation Join: 执行时间 8.7秒，网络传输 0MB
性能提升:       5.2倍，网络传输减少100%
```

### 4.2 监控指标

```sql
-- 创建Colocation Join性能监控视图
CREATE VIEW colocation_join_monitor AS
SELECT 
    query_id,
    query_start_time,
    query_time_ms,
    scan_bytes,
    scan_rows,
    cpu_time_ms,
    query_type,
    CASE 
        WHEN explain_info LIKE '%COLOCATE%' THEN 'COLOCATION_JOIN'
        ELSE 'REGULAR_JOIN'
    END as join_type
FROM information_schema.query_log
WHERE query_type = 'Query'
  AND query_sql LIKE '%JOIN%'
  AND query_start_time >= CURRENT_DATE - INTERVAL 1 DAY;

-- 分析Colocation Join效果
SELECT 
    join_type,
    COUNT(*) as query_count,
    AVG(query_time_ms) as avg_query_time,
    AVG(scan_bytes) as avg_scan_bytes,
    AVG(cpu_time_ms) as avg_cpu_time
FROM colocation_join_monitor
GROUP BY join_type;
```

### 4.3 故障诊断

**常见问题检查**
```sql
-- 检查Colocation Group状态
SHOW PROC '/colocation_group';

-- 检查表的Colocation配置一致性
SELECT 
    table_name,
    distribution_key,
    bucket_num,
    colocate_group
FROM information_schema.tables_config
WHERE colocate_group IS NOT NULL
ORDER BY colocate_group, table_name;

-- 检查数据倾斜情况
SELECT 
    backend_id,
    table_name,
    partition_name,
    bucket_id,
    num_rows,
    data_size
FROM information_schema.be_tablets
WHERE table_name IN ('users', 'orders')
ORDER BY table_name, bucket_id;
```

**修复Colocation不一致**
```sql
-- 重新平衡Colocation Group
ADMIN SET FRONTEND CONFIG ("disable_colocate_relocate" = "false");

-- 强制重新分布数据
ALTER COLOCATE GROUP user_order_group SET (
    "rebalance" = "true"
);
```

## 5. 高级应用场景

### 5.1 星型模型优化

```sql
-- 创建事实表（销售记录）
CREATE TABLE fact_sales (
    sale_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,       -- 用户维度键
    product_id BIGINT NOT NULL,    -- 商品维度键
    store_id INT NOT NULL,         -- 门店维度键  
    sale_date DATE NOT NULL,
    quantity INT,
    unit_price DECIMAL(8,2),
    total_amount DECIMAL(10,2)
) ENGINE=OLAP
DUPLICATE KEY(sale_id)
PARTITION BY RANGE(sale_date) (
    -- 分区定义
)
DISTRIBUTED BY HASH(user_id) BUCKETS 64
PROPERTIES (
    "colocate_with" = "sales_star_schema"
);

-- 创建用户维度表
CREATE TABLE dim_users (
    user_id BIGINT NOT NULL,
    user_name VARCHAR(100),
    user_level VARCHAR(20),
    region_name VARCHAR(50)
) ENGINE=OLAP
DUPLICATE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 64
PROPERTIES (
    "colocate_with" = "sales_star_schema"
);

-- 创建商品维度表（如果基数不高可以考虑broadcast join）
CREATE TABLE dim_products (
    product_id BIGINT NOT NULL,
    product_name VARCHAR(200),
    category_name VARCHAR(100),
    brand_name VARCHAR(100)
) ENGINE=OLAP
DUPLICATE KEY(product_id)
DISTRIBUTED BY HASH(product_id) BUCKETS 16  -- 较少的桶数
PROPERTIES (
    "colocate_with" = "product_dimension_group"
);
```

### 5.2 数据血缘关系优化

```sql
-- 原始订单表
CREATE TABLE raw_orders (
    order_id BIGINT,
    user_id BIGINT,
    create_time DATETIME,
    raw_data JSON
) ENGINE=OLAP
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "colocate_with" = "order_pipeline_group"
);

-- 清洗后订单表
CREATE TABLE clean_orders (
    order_id BIGINT,
    user_id BIGINT,
    order_date DATE,
    amount DECIMAL(10,2),
    status VARCHAR(20)
) ENGINE=OLAP
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "colocate_with" = "order_pipeline_group"
);

-- 聚合订单表
CREATE TABLE agg_orders (
    user_id BIGINT,
    order_date DATE,
    order_count INT,
    total_amount DECIMAL(15,2)
) ENGINE=OLAP
AGGREGATE KEY(user_id, order_date)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "colocate_with" = "order_pipeline_group"
);

-- 数据流水线处理可以利用Colocation优化
INSERT INTO clean_orders 
SELECT 
    r.order_id,
    r.user_id,
    DATE(r.create_time) as order_date,
    JSON_EXTRACT(r.raw_data, '$.amount') as amount,
    JSON_EXTRACT(r.raw_data, '$.status') as status
FROM raw_orders r
WHERE r.create_time >= CURRENT_DATE;
```

### 5.3 实时OLAP场景

```sql
-- 实时用户画像更新
CREATE TABLE user_realtime_features (
    user_id BIGINT NOT NULL,
    feature_name VARCHAR(100),
    feature_value DOUBLE,
    update_time DATETIME
) ENGINE=OLAP
DUPLICATE KEY(user_id, feature_name)
DISTRIBUTED BY HASH(user_id) BUCKETS 128
PROPERTIES (
    "colocate_with" = "realtime_features_group"
);

-- 实时行为事件表
CREATE TABLE user_realtime_events (
    event_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    event_type VARCHAR(50),
    event_time DATETIME,
    event_properties JSON
) ENGINE=OLAP
DUPLICATE KEY(event_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 128  
PROPERTIES (
    "colocate_with" = "realtime_features_group"
);

-- 实时特征计算查询（利用Colocation优化）
SELECT 
    f.user_id,
    f.feature_value as current_score,
    COUNT(e.event_id) as recent_events,
    MAX(e.event_time) as last_active_time
FROM user_realtime_features f
LEFT JOIN user_realtime_events e ON f.user_id = e.user_id 
    AND e.event_time >= NOW() - INTERVAL 1 HOUR
WHERE f.feature_name = 'user_score'
GROUP BY f.user_id, f.feature_value;
```

## 6. 最佳实践和限制

### 6.1 设计最佳实践

**分布键选择**
```sql
-- ✅ 好的分布键选择
-- 1. 高基数列（如user_id, order_id）
-- 2. 经常用于Join的列
-- 3. 数据分布均匀的列

-- ❌ 避免的分布键
-- 1. 低基数列（如status, type）
-- 2. 数据倾斜严重的列
-- 3. 不参与Join的列
```

**桶数配置**
```sql
-- 桶数计算公式
-- 理想桶数 = (表数据量GB) / (1-2GB)
-- 实际桶数 = 2的幂次，便于扩展

-- 小表（< 10GB）：16-32桶
-- 中表（10GB-100GB）：32-64桶  
-- 大表（> 100GB）：64-128桶
```

### 6.2 系统限制

**硬性限制**
- 同一个Colocation Group中的表必须有相同的分布键列
- 必须有相同的桶数
- 副本数必须相同
- 分区表的分区策略必须兼容

**性能限制**
- 不适用于数据倾斜严重的场景
- 增加了数据分布的复杂性
- 扩容时需要重新平衡数据

### 6.3 运维注意事项

**监控要点**
```bash
#!/bin/bash
# colocation_monitor.sh

# 检查Colocation Group健康状态
mysql -h starrocks_host -P 9030 -u root -e "
SELECT 
    group_name,
    table_count,
    is_stable,
    unstable_reason
FROM information_schema.colocate_groups
WHERE is_stable = false;
"

# 检查数据倾斜
mysql -h starrocks_host -P 9030 -u root -e "
SELECT 
    table_name,
    bucket_id,
    COUNT(*) as tablet_count,
    MIN(num_rows) as min_rows,
    MAX(num_rows) as max_rows,
    MAX(num_rows) - MIN(num_rows) as row_diff
FROM information_schema.be_tablets
WHERE table_name IN ('users', 'orders')
GROUP BY table_name, bucket_id
HAVING row_diff > 10000
ORDER BY row_diff DESC;
"
```

**容量规划**
- 新增表时确认Colocation兼容性
- 定期检查数据分布均匀性
- 扩容时制定数据重平衡计划

## 7. 故障排查指南

### 7.1 常见问题

**问题1：Colocation Join未生效**
```sql
-- 诊断步骤
-- 1. 检查表配置
SHOW CREATE TABLE users;
SHOW CREATE TABLE orders;

-- 2. 检查Join条件是否基于分布键
EXPLAIN SELECT * FROM users u JOIN orders o ON u.user_id = o.user_id;

-- 3. 检查Colocation Group状态
SHOW PROC '/colocation_group/user_order_group';
```

**问题2：数据分布不均匀**
```sql
-- 诊断数据倾斜
SELECT 
    backend_id,
    bucket_id,
    COUNT(*) as tablet_count,
    AVG(num_rows) as avg_rows
FROM information_schema.be_tablets
WHERE table_name = 'orders'
GROUP BY backend_id, bucket_id
ORDER BY avg_rows DESC;

-- 解决方案：重新选择分布键或调整桶数
```

**问题3：Colocation Group不稳定**
```sql
-- 检查不稳定原因
SELECT 
    group_name,
    is_stable,
    unstable_reason
FROM information_schema.colocate_groups;

-- 手动触发重平衡
ALTER COLOCATE GROUP user_order_group SET ("rebalance" = "true");
```

### 7.2 性能回归处理

```sql
-- 性能基线记录
CREATE TABLE colocation_performance_baseline (
    test_date DATE,
    query_type VARCHAR(100),
    avg_duration_ms INT,
    p95_duration_ms INT,
    data_volume_gb DOUBLE
);

-- 定期性能测试
INSERT INTO colocation_performance_baseline
SELECT 
    CURRENT_DATE,
    'user_order_join',
    AVG(query_time_ms),
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY query_time_ms),
    (SELECT SUM(data_size)/1024/1024/1024 FROM information_schema.tables_config 
     WHERE table_name IN ('users', 'orders'))
FROM information_schema.query_log
WHERE query_sql LIKE '%users%JOIN%orders%'
  AND query_start_time >= CURRENT_DATE - INTERVAL 1 DAY;
```

## 8. 总结

Colocation Join 是 StarRocks 提供的强大 Join 优化功能，通过合理配置可以显著提升多表关联查询性能。关键成功因素包括：

**设计原则**
- 选择合适的分布键（高基数、均匀分布、频繁Join）
- 配置一致的分布策略（相同分布键、相同桶数）
- 考虑业务查询模式和数据特征

**运维要点**
- 建立完善的监控体系
- 定期检查数据分布和性能指标
- 制定扩容和故障处理预案

**性能收益**
- Join查询性能提升3-10倍
- 网络传输开销降低90%以上
- 系统整体吞吐能力显著提升

正确使用 Colocation Join 可以让 StarRocks 在复杂多表查询场景下发挥最大性能优势。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](dynamic-partitioning.md) | [➡️ 下一页](cloud-native-architecture.md)
---