---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../05-sql-optimization/index-optimization.md) | [➡️ 下一页](dynamic-partitioning.md)
---

# 物化视图应用

物化视图是 StarRocks 提供的强大查询加速功能，通过预计算和存储查询结果来显著提升复杂查询的性能。本章节详细介绍物化视图的原理、创建方法、管理策略和最佳实践。

## 版本支持总览

### 物化视图类型版本支持

| 物化视图类型 | 最低版本 | 稳定版本 | 生产推荐 | 说明 |
|------------|---------|---------|---------|------|
| **同步物化视图** | v1.0+ | v1.0+ | ✅ 全版本 | 最早支持，生产成熟 |
| **异步物化视图** | v2.5+ | v2.5.13+ | ✅ v2.5.13+ | 支持复杂查询和外部表 |
| **多表JOIN物化视图** | v2.4+ | v2.4+ | ✅ v2.4+ | 支持跨表查询加速 |

### 外部表物化视图支持

| 数据源 | 最低版本 | 稳定版本 | 生产状态 | 特殊说明 |
|-------|---------|---------|---------|---------|
| **Hive** | v2.5.4+ | v2.5.13+, v3.0.6+, v3.1.5+, v3.2+ | ✅ 生产可用 | 支持分区表，推荐使用 |
| **Iceberg** | v3.0+ | v3.1.5+, v3.2+ | ✅ 生产可用 | 支持分区级刷新(v3.1.7+, v3.2.3+) |
| **Hudi** | v3.2+ | 预览版 | ⚠️ 测试环境 | 不稳定，谨慎使用 |
| **Paimon** | v2.5.4+, v3.0+ | 预览版 | ⚠️ 测试环境 | 不稳定，谨慎使用 |
| **DeltaLake** | v3.2+ | 预览版 | ⚠️ 测试环境 | 不稳定，谨慎使用 |
| **JDBC(MySQL)** | v3.0+ | v3.1.4+ | ⚠️ 有限支持 | 仅支持RangeColumn分区 |
| **Oracle JDBC** | v3.3+ | v3.3+ | ⚠️ 有限支持 | 新功能，需要验证 |

### 高级特性版本要求

| 特性 | 支持版本 | 说明 |
|------|---------|------|
| **分区级增量刷新** | v3.1.7+, v3.2.3+ | Iceberg表支持 |
| **多分区列支持** | v3.5+ | 支持多个分区列的物化视图 |
| **强制查询改写** | v3.5+ | `query_rewrite_consistency=force_mv` |
| **时序维度表支持** | v3.3+ | 支持历史版本数据的维度表 |
| **List分区表支持** | v3.3.4+ | 支持List分区表的物化视图 |
| **多事实表支持** | v3.3+ | 支持多个事实表JOIN的物化视图 |
| **VIEW上创建MV** | v3.1+ | 支持基于逻辑视图创建物化视图 |
| **MV Swap功能** | v3.1+ | 支持原子替换物化视图 |
| **自动激活** | v3.1.4+, v3.2+ | 自动重新激活失效的物化视图 |
| **备份恢复** | v3.2+ | 支持物化视图的备份和恢复 |

### 版本选择建议

| 使用场景 | 推荐版本 | 主要原因 |
|---------|---------|---------|
| **基础OLAP查询加速** | v2.5 LTS | 异步物化视图稳定，长期支持 |
| **数据湖分析(Hive)** | v2.5.13+, v3.0.6+ | Hive物化视图成熟稳定 |
| **数据湖分析(Iceberg)** | v3.1.5+, v3.2+ | Iceberg支持成熟，分区级刷新 |
| **实时数仓** | v3.2+ | 功能最完整，稳定性最好 |
| **多数据源整合** | v3.3+ | 多事实表、Oracle支持 |
| **极致查询性能** | v3.5+ | 强制改写、多分区列支持 |

### 注意事项

⚠️ **外部表物化视图生产使用建议**：
- **Hive**: v2.5.13+版本生产可用，推荐使用
- **Iceberg**: v3.1.5+版本生产可用，v3.2+更稳定
- **Hudi/Paimon/DeltaLake**: 目前处于预览状态，不建议生产使用

🔥 **新特性使用提醒**：
- **多事实表物化视图**: v3.3+新功能，建议充分测试后使用
- **强制查询改写**: v3.5+实验性功能，可能影响查询灵活性
- **多分区列**: v3.5+新功能，建议评估性能影响

## 1. 物化视图概述

### 1.1 物化视图原理

物化视图本质上是将查询结果预先计算并持久化存储的表，具有以下特点：

- **预计算**：在数据写入时自动维护聚合结果
- **透明加速**：查询优化器自动选择使用物化视图
- **增量更新**：支持基表数据变更时的增量维护
- **存储优化**：占用额外存储空间但大幅提升查询性能

### 1.2 物化视图类型

StarRocks 支持多种类型的物化视图：

| 类型 | 描述 | 适用场景 | 更新方式 |
|------|------|----------|----------|
| 同步物化视图 | 基表数据更新时同步更新 | 实时性要求高的聚合查询 | 自动同步 |
| 异步物化视图 | 通过刷新任务定期更新 | 复杂 ETL、跨库查询 | 手动/定时刷新 |

### 1.3 性能提升效果

典型场景下的性能提升：

```sql
-- 原始复杂查询（耗时：30秒）
SELECT 
    user_region,
    order_date,
    COUNT(*) as order_count,
    SUM(amount) as total_amount,
    AVG(amount) as avg_amount
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= '2023-01-01'
GROUP BY user_region, order_date;

-- 使用物化视图后（耗时：0.1秒）
-- 查询优化器自动使用物化视图，性能提升 300 倍
```

## 2. 同步物化视图

### 2.1 创建同步物化视图

```sql
-- 基础聚合物化视图
CREATE MATERIALIZED VIEW order_daily_summary AS
SELECT 
    order_date,
    user_id,
    COUNT(*) as order_count,
    SUM(amount) as total_amount,
    MAX(amount) as max_amount,
    MIN(amount) as min_amount
FROM orders
GROUP BY order_date, user_id;

-- 复杂多表 Join 物化视图
CREATE MATERIALIZED VIEW user_order_stats AS
SELECT 
    u.user_id,
    u.user_name,
    u.register_date,
    COUNT(o.order_id) as total_orders,
    SUM(o.amount) as total_spent,
    AVG(o.amount) as avg_order_value,
    MAX(o.order_date) as last_order_date
FROM users u
LEFT JOIN orders o ON u.user_id = o.user_id
GROUP BY u.user_id, u.user_name, u.register_date;
```

### 2.2 支持的聚合函数

```sql
-- 数值聚合函数
CREATE MATERIALIZED VIEW numeric_stats AS
SELECT 
    category_id,
    COUNT(*) as count_val,           -- 计数
    SUM(amount) as sum_val,          -- 求和
    AVG(amount) as avg_val,          -- 平均值
    MAX(amount) as max_val,          -- 最大值
    MIN(amount) as min_val,          -- 最小值
    COUNT(DISTINCT user_id) as uv    -- 去重计数
FROM orders
GROUP BY category_id;

-- 字符串聚合函数
CREATE MATERIALIZED VIEW string_agg AS
SELECT 
    order_date,
    MAX(status) as latest_status,    -- 字符串最大值
    MIN(create_time) as earliest_time -- 时间最小值
FROM orders
GROUP BY order_date;

-- 位图精确去重（推荐）
CREATE MATERIALIZED VIEW bitmap_uv AS
SELECT 
    order_date,
    BITMAP_UNION(TO_BITMAP(user_id)) as user_bitmap
FROM orders
GROUP BY order_date;
```

### 2.3 物化视图使用

```sql
-- 查询会自动使用物化视图
SELECT 
    order_date,
    SUM(total_amount) as daily_revenue
FROM order_daily_summary
GROUP BY order_date;

-- 检查是否使用了物化视图
EXPLAIN SELECT 
    order_date,
    COUNT(*) as order_count
FROM orders
GROUP BY order_date;
-- 执行计划中会显示使用了物化视图

-- 查看物化视图使用情况
SELECT 
    table_name,
    materialized_view_name,
    hit_count,
    query_rewrite_count
FROM information_schema.materialized_views_usage;
```

### 2.4 物化视图管理

```sql
-- 查看物化视图信息
SHOW MATERIALIZED VIEWS FROM database_name;

-- 查看物化视图详情
DESC MATERIALIZED VIEW order_daily_summary;

-- 禁用物化视图
ALTER MATERIALIZED VIEW order_daily_summary SET ("active" = "false");

-- 启用物化视图
ALTER MATERIALIZED VIEW order_daily_summary SET ("active" = "true");

-- 删除物化视图
DROP MATERIALIZED VIEW order_daily_summary;
```

## 3. 异步物化视图

### 3.1 异步物化视图特点

- **跨库支持**：可以基于多个数据库的表创建
- **复杂 SQL**：支持更复杂的 SQL 语句
- **灵活刷新**：支持手动刷新和定时刷新
- **外部数据源**：可以基于外部表创建

### 3.2 创建异步物化视图

```sql
-- 基础异步物化视图
CREATE MATERIALIZED VIEW async_order_summary
REFRESH ASYNC
AS 
SELECT 
    DATE_TRUNC('month', order_date) as order_month,
    COUNT(*) as monthly_orders,
    SUM(amount) as monthly_revenue,
    COUNT(DISTINCT user_id) as monthly_users
FROM orders
GROUP BY DATE_TRUNC('month', order_date);

-- 跨库异步物化视图
CREATE MATERIALIZED VIEW cross_db_summary
REFRESH ASYNC
AS
SELECT 
    o.order_date,
    p.category_name,
    SUM(o.amount) as category_revenue
FROM order_db.orders o
JOIN product_db.products p ON o.product_id = p.product_id
GROUP BY o.order_date, p.category_name;

-- 基于外部表的物化视图
CREATE MATERIALIZED VIEW hive_summary
REFRESH ASYNC
AS
SELECT 
    event_date,
    event_type,
    COUNT(*) as event_count
FROM hive_catalog.hive_db.user_events
WHERE event_date >= CURRENT_DATE - INTERVAL 30 DAY
GROUP BY event_date, event_type;
```

### 3.3 刷新策略配置

```sql
-- 手动刷新
REFRESH MATERIALIZED VIEW async_order_summary;

-- 定时刷新（每小时）
CREATE MATERIALIZED VIEW hourly_stats
REFRESH ASYNC START('2023-01-01 00:00:00') EVERY(INTERVAL 1 HOUR)
AS
SELECT 
    DATE_TRUNC('hour', order_time) as hour,
    COUNT(*) as hourly_orders
FROM orders
GROUP BY DATE_TRUNC('hour', order_time);

-- 定时刷新（每天凌晨2点）
CREATE MATERIALIZED VIEW daily_report
REFRESH ASYNC START('2023-01-01 02:00:00') EVERY(INTERVAL 1 DAY)
AS
SELECT 
    order_date,
    COUNT(*) as daily_orders,
    SUM(amount) as daily_revenue
FROM orders
GROUP BY order_date;

-- 查看刷新状态
SELECT 
    mv_name,
    last_refresh_start_time,
    last_refresh_finished_time,
    refresh_state,
    refresh_error_message
FROM information_schema.materialized_views
WHERE mv_name = 'async_order_summary';
```

### 3.4 分区物化视图

```sql
-- 创建分区物化视图
CREATE MATERIALIZED VIEW partitioned_summary
PARTITION BY order_date
REFRESH ASYNC
AS
SELECT 
    order_date,
    user_region,
    COUNT(*) as order_count,
    SUM(amount) as total_amount
FROM orders
GROUP BY order_date, user_region;

-- 手动刷新特定分区
REFRESH MATERIALIZED VIEW partitioned_summary 
PARTITION START ('2023-01-01') END ('2023-01-31');

-- 查看分区信息
SHOW PARTITIONS FROM partitioned_summary;
```

## 4. 物化视图设计最佳实践

### 4.1 设计原则

**1. 高频查询优先**
```sql
-- 分析查询频率，优先为高频查询创建物化视图
SELECT 
    query_text,
    count(*) as frequency,
    avg(total_time_ms) as avg_time
FROM information_schema.query_log
WHERE query_time >= CURRENT_DATE - INTERVAL 7 DAY
GROUP BY query_text
ORDER BY frequency DESC, avg_time DESC;
```

**2. 合适的聚合粒度**
```sql
-- ❌ 错误：粒度过细，物化视图过大
CREATE MATERIALIZED VIEW wrong_mv AS
SELECT 
    user_id, product_id, order_time, -- 包含高基数列
    SUM(amount) as total_amount
FROM orders
GROUP BY user_id, product_id, order_time;

-- ✅ 正确：合适的聚合粒度
CREATE MATERIALIZED VIEW correct_mv AS
SELECT 
    DATE(order_time) as order_date,  -- 降低时间粒度
    category_id,                     -- 使用分类而非具体商品
    SUM(amount) as total_amount,
    COUNT(*) as order_count
FROM orders o
JOIN products p ON o.product_id = p.product_id
GROUP BY DATE(order_time), p.category_id;
```

**3. 选择合适的维度**
```sql
-- 业务分析维度物化视图
CREATE MATERIALIZED VIEW business_metrics AS
SELECT 
    -- 时间维度（必需）
    DATE_TRUNC('day', order_time) as order_day,
    -- 地域维度
    user_region,
    -- 渠道维度  
    order_channel,
    -- 商品分类维度
    product_category,
    
    -- 业务指标
    COUNT(*) as order_count,
    SUM(amount) as revenue,
    COUNT(DISTINCT user_id) as user_count,
    AVG(amount) as avg_order_value
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN products p ON o.product_id = p.product_id
GROUP BY 
    DATE_TRUNC('day', order_time),
    user_region,
    order_channel,
    product_category;
```

### 4.2 性能优化

**1. 排序键优化**
```sql
-- 根据查询模式设置排序键
CREATE MATERIALIZED VIEW optimized_mv 
ORDER BY (order_date, user_region)  -- 最频繁的过滤条件
AS
SELECT 
    order_date,
    user_region,
    product_category,
    SUM(amount) as revenue
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN products p ON o.product_id = p.product_id
GROUP BY order_date, user_region, product_category;
```

**2. 分区策略**
```sql
-- 大数据量场景使用分区物化视图
CREATE MATERIALIZED VIEW large_mv
PARTITION BY order_date
DISTRIBUTED BY HASH(user_region) BUCKETS 32
REFRESH ASYNC
AS
SELECT 
    order_date,
    user_region,
    COUNT(*) as order_count,
    SUM(amount) as revenue
FROM orders
WHERE order_date >= '2023-01-01'  -- 避免历史全量数据
GROUP BY order_date, user_region;
```

### 4.3 监控和维护

**1. 存储监控**
```sql
-- 监控物化视图存储使用
SELECT 
    table_name as mv_name,
    data_size,
    row_count,
    data_size / row_count as avg_row_size
FROM information_schema.tables_config
WHERE table_type = 'MATERIALIZED_VIEW'
ORDER BY data_size DESC;
```

**2. 性能监控**
```sql
-- 监控物化视图命中率
SELECT 
    mv_name,
    query_count,
    hit_count,
    hit_count * 100.0 / query_count as hit_rate
FROM information_schema.materialized_views_usage
WHERE query_count > 0
ORDER BY hit_rate DESC;
```

**3. 刷新监控**
```sql
-- 监控异步物化视图刷新
SELECT 
    mv_name,
    refresh_state,
    last_refresh_start_time,
    last_refresh_finished_time,
    TIMESTAMPDIFF(SECOND, last_refresh_start_time, last_refresh_finished_time) as refresh_duration_seconds
FROM information_schema.materialized_views
WHERE refresh_state IN ('RUNNING', 'FAILED')
ORDER BY last_refresh_start_time DESC;
```

## 5. 高级应用场景

### 5.1 实时数仓分层

```sql
-- ODS 层：原始数据
-- (基础表，无需物化视图)

-- DWD 层：数据明细层物化视图
CREATE MATERIALIZED VIEW dwd_order_detail AS
SELECT 
    o.order_id,
    o.user_id,
    o.product_id,
    o.order_time,
    o.amount,
    u.user_region,
    u.user_level,
    p.product_category,
    p.product_brand
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN products p ON o.product_id = p.product_id;

-- DWS 层：数据服务层物化视图
CREATE MATERIALIZED VIEW dws_user_daily_summary AS
SELECT 
    DATE(order_time) as stat_date,
    user_id,
    user_region,
    user_level,
    COUNT(*) as order_count,
    SUM(amount) as order_amount,
    COUNT(DISTINCT product_category) as category_count
FROM dwd_order_detail
GROUP BY DATE(order_time), user_id, user_region, user_level;

-- ADS 层：应用数据服务层物化视图  
CREATE MATERIALIZED VIEW ads_daily_report AS
SELECT 
    stat_date,
    user_region,
    SUM(order_count) as total_orders,
    SUM(order_amount) as total_revenue,
    COUNT(DISTINCT user_id) as active_users,
    SUM(order_amount) / COUNT(DISTINCT user_id) as arpu
FROM dws_user_daily_summary
GROUP BY stat_date, user_region;
```

### 5.2 多维分析 OLAP

```sql
-- 创建多维度分析物化视图
CREATE MATERIALIZED VIEW olap_sales_cube AS
SELECT 
    -- 时间维度
    DATE_TRUNC('day', order_time) as order_day,
    DATE_TRUNC('week', order_time) as order_week, 
    DATE_TRUNC('month', order_time) as order_month,
    
    -- 地域维度
    user_region,
    user_city,
    
    -- 商品维度
    product_category,
    product_brand,
    
    -- 用户维度
    user_level,
    user_age_group,
    
    -- 渠道维度
    order_channel,
    
    -- 度量指标
    COUNT(*) as order_count,
    SUM(amount) as revenue,
    SUM(quantity) as quantity,
    COUNT(DISTINCT user_id) as user_count,
    COUNT(DISTINCT product_id) as product_count
FROM orders o
JOIN users u ON o.user_id = u.user_id  
JOIN products p ON o.product_id = p.product_id
GROUP BY 
    DATE_TRUNC('day', order_time),
    DATE_TRUNC('week', order_time),
    DATE_TRUNC('month', order_time),
    user_region, user_city,
    product_category, product_brand,
    user_level, user_age_group,
    order_channel;

-- 支持灵活的多维查询
SELECT 
    order_month,
    product_category,
    SUM(revenue) as monthly_revenue
FROM olap_sales_cube
WHERE order_month >= '2023-01-01'
  AND user_region = 'East'
GROUP BY order_month, product_category
ORDER BY order_month, monthly_revenue DESC;
```

### 5.3 实时大屏看板

```sql
-- 实时大屏数据物化视图
CREATE MATERIALIZED VIEW realtime_dashboard
REFRESH ASYNC EVERY(INTERVAL 5 MINUTE)
AS
SELECT 
    -- 实时指标（最近1小时）
    'realtime' as metric_type,
    COUNT(*) as current_orders,
    SUM(amount) as current_revenue,
    COUNT(DISTINCT user_id) as current_users,
    AVG(amount) as current_avg_order_value
FROM orders
WHERE order_time >= NOW() - INTERVAL 1 HOUR

UNION ALL

SELECT 
    -- 今日指标
    'today' as metric_type,
    COUNT(*) as current_orders,
    SUM(amount) as current_revenue, 
    COUNT(DISTINCT user_id) as current_users,
    AVG(amount) as current_avg_order_value
FROM orders
WHERE DATE(order_time) = CURRENT_DATE

UNION ALL

SELECT 
    -- 昨日同比指标
    'yesterday' as metric_type,
    COUNT(*) as current_orders,
    SUM(amount) as current_revenue,
    COUNT(DISTINCT user_id) as current_users,
    AVG(amount) as current_avg_order_value
FROM orders
WHERE DATE(order_time) = CURRENT_DATE - INTERVAL 1 DAY;
```

## 6. 故障排查和优化

### 6.1 常见问题

**1. 物化视图未命中**
```sql
-- 检查查询是否使用物化视图
EXPLAIN SELECT 
    order_date, 
    COUNT(*) 
FROM orders 
GROUP BY order_date;

-- 常见原因：
-- a. 查询条件不匹配物化视图定义
-- b. 物化视图被禁用
-- c. 查询优化器选择了其他执行路径
```

**2. 物化视图刷新失败**
```sql
-- 查看刷新错误信息
SELECT 
    mv_name,
    refresh_error_message,
    last_refresh_start_time
FROM information_schema.materialized_views
WHERE refresh_state = 'FAILED';

-- 常见解决方案：
-- a. 检查基表数据完整性
-- b. 调整刷新任务调度
-- c. 增加系统资源配置
```

### 6.2 性能调优

```sql
-- 物化视图性能分析
SELECT 
    mv_name,
    build_time_seconds,
    rows_inserted,
    rows_inserted / build_time_seconds as insertion_rate
FROM (
    SELECT 
        mv_name,
        TIMESTAMPDIFF(SECOND, last_refresh_start_time, last_refresh_finished_time) as build_time_seconds,
        row_count as rows_inserted
    FROM information_schema.materialized_views
    WHERE refresh_state = 'SUCCESS'
) t
ORDER BY build_time_seconds DESC;
```

## 7. 最佳实践总结

### 7.1 设计建议
- **业务导向**：基于实际查询模式设计物化视图
- **适度聚合**：选择合适的聚合粒度，避免过细或过粗
- **维度选择**：包含高频查询的过滤和分组字段
- **存储平衡**：在查询性能和存储成本之间找到平衡

### 7.2 运维建议
- **监控告警**：建立物化视图刷新和使用情况监控
- **定期评估**：定期评估物化视图的价值和必要性
- **版本管理**：建立物化视图变更的版本管理流程
- **容量规划**：合理规划物化视图的存储容量需求

### 7.3 性能要点
- **查询重写**：确保查询能够正确重写到物化视图
- **刷新效率**：优化异步物化视图的刷新效率
- **并发控制**：避免大量物化视图同时刷新造成系统负载过高
- **资源隔离**：为物化视图刷新预留专门的计算资源

物化视图是 StarRocks 查询加速的核心功能，合理使用可以显著提升复杂分析查询的性能，是构建高性能数据仓库的重要工具。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../05-sql-optimization/index-optimization.md) | [➡️ 下一页](dynamic-partitioning.md)
---