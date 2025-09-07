---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](join-optimization.md) | [➡️ 下一页](index-optimization.md)
---

# StarRocks聚合查询优化

> **版本要求**：本章节内容适用于StarRocks 1.19+，建议使用3.0+版本以获得完整的聚合优化特性

## 学习目标

- 掌握StarRocks聚合查询的优化策略
- 理解物化视图在聚合查询中的加速作用
- 学会使用Rollup表优化聚合性能
- 了解预聚合表和Aggregate模型的最佳实践

## 聚合查询优化概览

### 1. 聚合优化方法对比

> **版本支持**：不同聚合优化方法的版本要求
> - Aggregate模型：StarRocks 1.19+
> - 同步物化视图：StarRocks 2.0+
> - 异步物化视图：StarRocks 2.5+
> - HLL/BITMAP函数：StarRocks 1.19+（在3.0+版本中优化）

| 优化方法 | 适用场景 | 性能提升 | 存储成本 | 维护成本 | 实时性 | 最低版本 |
|---------|---------|---------|---------|---------|--------|----------|
| **Aggregate模型** | 预定义聚合 | 10-100倍 | 低 | 低 | 实时 | 1.19+ |
| **同步物化视图** | 灵活聚合 | 5-50倍 | 中等 | 中等 | 实时 | 2.0+ |
| **异步物化视图** | 复杂聚合 | 10-1000倍 | 高 | 高 | 准实时 | 2.5+ |
| **预聚合表** | 固定维度 | 20-200倍 | 中等 | 中等 | 离线 | 1.19+ |
| **查询优化** | 实时计算 | 2-10倍 | 无 | 低 | 实时 | 1.19+ |
| **Aggregate模型** | 预定义聚合 | 10-100倍 | 低 | 低 | 实时 |
| **同步物化视图** | 灵活聚合 | 5-50倍 | 中等 | 中等 | 实时 |
| **异步物化视图** | 复杂聚合 | 10-1000倍 | 高 | 高 | 准实时 |
| **预聚合表** | 固定维度 | 20-200倍 | 中等 | 中等 | 离线 |
| **查询优化** | 实时计算 | 2-10倍 | 无 | 低 | 实时 |

## Aggregate模型优化

### 1. 基础Aggregate模型设计

```sql
-- 创建销售汇总Aggregate表
CREATE TABLE sales_agg (
    stat_date DATE NOT NULL,
    region VARCHAR(50) NOT NULL,
    category VARCHAR(50) NOT NULL,
    
    -- 聚合指标列
    total_sales SUM DECIMAL(15,2) DEFAULT "0",
    order_count SUM BIGINT DEFAULT "0",
    avg_price REPLACE DECIMAL(10,2) DEFAULT "0",
    max_price MAX DECIMAL(10,2) DEFAULT "0",
    min_price MIN DECIMAL(10,2) DEFAULT "999999",
    unique_customers HLL HLL_UNION,
    customer_bitmap BITMAP BITMAP_UNION
)
AGGREGATE KEY(stat_date, region, category)
PARTITION BY RANGE(stat_date) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01')),
    PARTITION p202403 VALUES [('2024-03-01'), ('2024-04-01'))
)
DISTRIBUTED BY HASH(region) BUCKETS 10;

-- 插入聚合数据
INSERT INTO sales_agg 
SELECT 
    order_date as stat_date,
    u.region,
    p.category,
    SUM(o.amount) as total_sales,
    COUNT(*) as order_count,
    AVG(o.price) as avg_price,
    MAX(o.price) as max_price,
    MIN(o.price) as min_price,
    HLL_HASH(o.user_id) as unique_customers,
    TO_BITMAP(o.user_id) as customer_bitmap
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN products p ON o.product_id = p.product_id
WHERE o.status = 'PAID'
GROUP BY order_date, u.region, p.category;
```

### 2. Aggregate模型查询优化

```sql
-- 高效的聚合查询（直接读取预聚合结果）
-- 查询1：区域销售汇总
SELECT 
    region,
    SUM(total_sales) as region_sales,
    SUM(order_count) as region_orders,
    HLL_UNION_AGG(unique_customers) as unique_customers
FROM sales_agg 
WHERE stat_date BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY region
ORDER BY region_sales DESC;

-- 查询2：类目趋势分析  
SELECT 
    category,
    stat_date,
    total_sales,
    order_count,
    BITMAP_UNION_COUNT(customer_bitmap) as exact_customers
FROM sales_agg
WHERE category = 'Electronics'
  AND stat_date >= '2024-01-01'
ORDER BY stat_date;

-- 查询3：复合维度分析
SELECT 
    region,
    category, 
    AVG(avg_price) as avg_price_trend,  -- REPLACE类型取最新值
    MAX(max_price) as peak_price,       -- MAX类型自动聚合
    MIN(min_price) as lowest_price      -- MIN类型自动聚合
FROM sales_agg
WHERE stat_date >= '2024-01-01'
GROUP BY region, category;
```

### 3. 增量更新优化

```sql
-- Aggregate表增量更新策略
-- 方式1：DELETE + INSERT（推荐）
DELETE FROM sales_agg 
WHERE stat_date = '2024-01-15';

INSERT INTO sales_agg 
SELECT 
    '2024-01-15' as stat_date,
    u.region,
    p.category,
    SUM(o.amount),
    COUNT(*),
    AVG(o.price),
    MAX(o.price),
    MIN(o.price),
    HLL_HASH(o.user_id),
    TO_BITMAP(o.user_id)
FROM orders o
JOIN users u ON o.user_id = u.user_id  
JOIN products p ON o.product_id = p.product_id
WHERE o.order_date = '2024-01-15'
  AND o.status = 'PAID'
GROUP BY u.region, p.category;

-- 方式2：使用Stream Load覆盖更新
-- curl命令示例
/*
curl --location-trusted -u root: \
    -H "label:update_sales_agg_$(date +%Y%m%d_%H%M%S)" \
    -H "format:csv" \
    -H "columns:stat_date,region,category,total_sales,order_count,avg_price,max_price,min_price,unique_customers,customer_bitmap" \
    -H "merge_type:DELETE" \
    -H "delete:stat_date='2024-01-15'" \
    -T /dev/null \
    http://localhost:8030/api/demo_etl/sales_agg/_stream_load
*/
```

## 物化视图优化

### 1. 同步物化视图

同步物化视图会自动维护，查询时自动改写使用物化视图。

```sql
-- 创建基础事实表
CREATE TABLE order_details (
    order_id BIGINT,
    user_id BIGINT,
    product_id BIGINT,
    category_id INT,
    region_id INT,
    price DECIMAL(10,2),
    quantity INT,
    amount DECIMAL(10,2),
    order_time DATETIME
)
DUPLICATE KEY(order_id)
PARTITION BY RANGE(order_time) (
    PARTITION p202401 VALUES [('2024-01-01 00:00:00'), ('2024-02-01 00:00:00')),
    PARTITION p202402 VALUES [('2024-02-01 00:00:00'), ('2024-03-01 00:00:00'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 32;

-- 创建同步物化视图：按日期和类目聚合
CREATE MATERIALIZED VIEW daily_category_mv AS
SELECT 
    DATE_TRUNC('day', order_time) as order_date,
    category_id,
    SUM(amount) as total_amount,
    COUNT(*) as order_count,
    COUNT(DISTINCT user_id) as unique_users,
    AVG(price) as avg_price
FROM order_details
GROUP BY DATE_TRUNC('day', order_time), category_id;

-- 查看物化视图状态
SHOW ALTER TABLE MATERIALIZED VIEW FROM order_details;

-- 查询会自动改写使用物化视图
SELECT 
    order_date,
    SUM(total_amount) as daily_sales
FROM (
    SELECT 
        DATE_TRUNC('day', order_time) as order_date,
        category_id,
        SUM(amount) as total_amount  -- 这个查询会自动使用daily_category_mv
    FROM order_details
    WHERE order_time >= '2024-01-01'
    GROUP BY DATE_TRUNC('day', order_time), category_id
) t
GROUP BY order_date
ORDER BY order_date;
```

### 2. 异步物化视图

> **版本要求**：异步物化视图需要StarRocks 2.5+
> - 基础异步物化视图：StarRocks 2.5+
> - 外部表物化视图：StarRocks 3.0+
> - 数据湖物化视图：StarRocks 3.1+
> - 自动刷新优化：StarRocks 3.2+

异步物化视图支持更复杂的查询，包括Join操作。

```sql
-- 创建异步物化视图：多表Join聚合（StarRocks 2.5+）
CREATE MATERIALIZED VIEW sales_dashboard_mv
REFRESH ASYNC
AS 
SELECT 
    DATE_TRUNC('day', o.order_time) as stat_date,
    u.region,
    p.category,
    SUM(o.amount) as total_sales,
    COUNT(*) as order_count,
    COUNT(DISTINCT o.user_id) as unique_customers,
    AVG(o.price) as avg_price,
    MAX(o.price) as max_price,
    MIN(o.price) as min_price
FROM order_details o
JOIN dim_users u ON o.user_id = u.user_id
JOIN dim_products p ON o.product_id = p.product_id  
WHERE o.order_time >= DATE_SUB(CURRENT_DATE, INTERVAL 90 DAY)
GROUP BY 
    DATE_TRUNC('day', o.order_time),
    u.region,
    p.category;

-- 设置刷新计划（每小时刷新）（StarRocks 2.5+）
ALTER MATERIALIZED VIEW sales_dashboard_mv 
REFRESH ASYNC START('2024-01-01 00:00:00') EVERY(INTERVAL 1 HOUR);

-- 手动刷新物化视图
REFRESH MATERIALIZED VIEW sales_dashboard_mv;

-- 查看物化视图状态
SHOW MATERIALIZED VIEWS;

-- 查询会自动使用异步物化视图
SELECT 
    region,
    SUM(total_sales) as region_sales,
    SUM(order_count) as region_orders
FROM sales_dashboard_mv
WHERE stat_date >= '2024-01-01'
GROUP BY region
ORDER BY region_sales DESC;
```

### 3. 物化视图最佳实践

```sql
-- 最佳实践1：创建多层次物化视图
-- 基础聚合视图（按小时）
CREATE MATERIALIZED VIEW hourly_sales_mv AS
SELECT 
    DATE_TRUNC('hour', order_time) as stat_hour,
    category_id,
    region_id,
    SUM(amount) as total_sales,
    COUNT(*) as order_count
FROM order_details
GROUP BY DATE_TRUNC('hour', order_time), category_id, region_id;

-- 基于基础视图的高层聚合（按日）
CREATE MATERIALIZED VIEW daily_sales_mv AS  
SELECT 
    DATE_TRUNC('day', stat_hour) as stat_date,
    category_id,
    region_id,
    SUM(total_sales) as daily_sales,
    SUM(order_count) as daily_orders
FROM hourly_sales_mv
GROUP BY DATE_TRUNC('day', stat_hour), category_id, region_id;

-- 最佳实践2：选择性创建物化视图
-- 分析查询模式，找出高频聚合维度
WITH query_patterns AS (
    SELECT 
        sql_text,
        COUNT(*) as query_count,
        AVG(total_time_ms) as avg_time_ms
    FROM information_schema.query_log
    WHERE sql_text LIKE '%GROUP BY%'
      AND query_start_time >= DATE_SUB(NOW(), INTERVAL 7 DAY)
    GROUP BY sql_text
)
SELECT 
    sql_text,
    query_count,
    avg_time_ms,
    CASE 
        WHEN avg_time_ms > 5000 AND query_count > 10 THEN '建议创建物化视图'
        WHEN avg_time_ms > 10000 THEN '考虑创建物化视图'
        ELSE '暂不需要'
    END as recommendation
FROM query_patterns
ORDER BY query_count * avg_time_ms DESC;
```

## Count Distinct优化

> **版本说明**：Count Distinct优化功能的版本支持
> - HLL函数：StarRocks 1.19+
> - BITMAP函数：StarRocks 2.0+
> - HLL精度优化：StarRocks 2.5+
> - BITMAP操作优化：StarRocks 3.0+
> - 自动Count Distinct优化：StarRocks 3.1+

### 1. 使用HLL函数优化

```sql
-- 传统Count Distinct（性能差）
SELECT 
    category,
    COUNT(DISTINCT user_id) as unique_users  -- 精确但慢
FROM order_details
WHERE order_time >= '2024-01-01'
GROUP BY category;

-- 使用HLL优化（性能好，略有误差）
SELECT 
    category,
    HLL_UNION_AGG(HLL_HASH(user_id)) as approx_unique_users  -- 近似但快
FROM order_details  
WHERE order_time >= '2024-01-01'
GROUP BY category;

-- 在Aggregate表中使用HLL
CREATE TABLE category_stats (
    stat_date DATE,
    category VARCHAR(50),
    user_count HLL HLL_UNION,
    order_count SUM BIGINT
)
AGGREGATE KEY(stat_date, category);

-- 插入HLL数据
INSERT INTO category_stats
SELECT 
    DATE(order_time) as stat_date,
    category,
    HLL_HASH(user_id) as user_count,
    1 as order_count
FROM order_details o
JOIN dim_products p ON o.product_id = p.product_id;

-- 查询HLL聚合结果
SELECT 
    category,
    HLL_UNION_AGG(user_count) as total_unique_users,
    SUM(order_count) as total_orders
FROM category_stats
WHERE stat_date >= '2024-01-01'
GROUP BY category;
```

### 2. 使用BITMAP精确去重

```sql
-- 使用BITMAP精确去重（适合ID范围不大的场景）
CREATE TABLE user_activity_bitmap (
    stat_date DATE,
    activity_type VARCHAR(50),
    user_bitmap BITMAP BITMAP_UNION
)
AGGREGATE KEY(stat_date, activity_type);

-- 插入BITMAP数据
INSERT INTO user_activity_bitmap
SELECT 
    DATE(order_time) as stat_date,
    'purchase' as activity_type,
    TO_BITMAP(user_id) as user_bitmap
FROM order_details;

-- 精确计算活跃用户数
SELECT 
    stat_date,
    BITMAP_UNION_COUNT(user_bitmap) as exact_active_users
FROM user_activity_bitmap
WHERE stat_date >= '2024-01-01'
GROUP BY stat_date
ORDER BY stat_date;

-- BITMAP交集：计算用户重叠
SELECT 
    BITMAP_INTERSECT_COUNT(
        CASE WHEN activity_type = 'purchase' THEN user_bitmap END,
        CASE WHEN activity_type = 'login' THEN user_bitmap END
    ) as purchase_and_login_users
FROM user_activity_bitmap
WHERE stat_date = '2024-01-15';
```

## 窗口函数优化

### 1. 窗口函数基础优化

> **版本要求**：窗口函数在不同版本中的支持
> - 基础窗口函数：StarRocks 2.0+
> - 高级窗口函数：StarRocks 2.5+
> - 窗口函数优化：StarRocks 3.0+
> - Pipeline窗口执行：StarRocks 3.1+

```sql
-- 低效的窗口函数使用
SELECT 
    order_id,
    user_id,
    amount,
    -- 每行都计算全表排名（低效）
    ROW_NUMBER() OVER (ORDER BY amount DESC) as global_rank,
    -- 没有分区的窗口函数（低效）
    AVG(amount) OVER () as overall_avg
FROM order_details
WHERE order_time >= '2024-01-01';

-- 优化后的窗口函数
SELECT 
    order_id,
    user_id, 
    amount,
    -- 按分区计算排名（高效）
    ROW_NUMBER() OVER (PARTITION BY DATE(order_time) ORDER BY amount DESC) as daily_rank,
    -- 在分区内计算平均值（高效）
    AVG(amount) OVER (PARTITION BY DATE(order_time)) as daily_avg,
    -- 计算累计值（高效）
    SUM(amount) OVER (PARTITION BY user_id ORDER BY order_time ROWS UNBOUNDED PRECEDING) as cumulative_spending
FROM order_details
WHERE order_time >= '2024-01-01'
  AND user_id IN (SELECT user_id FROM top_users);  -- 预过滤减少计算量
```

### 2. 窗口函数物化视图

```sql
-- 为复杂窗口函数创建物化视图
CREATE MATERIALIZED VIEW user_spending_trend_mv
REFRESH ASYNC  
AS
SELECT 
    user_id,
    DATE(order_time) as order_date,
    SUM(amount) as daily_spending,
    -- 7日移动平均
    AVG(SUM(amount)) OVER (
        PARTITION BY user_id 
        ORDER BY DATE(order_time) 
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) as spending_7d_avg,
    -- 累计消费
    SUM(SUM(amount)) OVER (
        PARTITION BY user_id 
        ORDER BY DATE(order_time)
        ROWS UNBOUNDED PRECEDING  
    ) as cumulative_spending
FROM order_details
WHERE order_time >= DATE_SUB(CURRENT_DATE, INTERVAL 180 DAY)
GROUP BY user_id, DATE(order_time);

-- 使用物化视图查询趋势
SELECT 
    user_id,
    order_date,
    daily_spending,
    spending_7d_avg,
    cumulative_spending
FROM user_spending_trend_mv
WHERE order_date >= '2024-01-01'
  AND user_id = 12345
ORDER BY order_date;
```

## 聚合查询调优实战案例

### 1. 大数据量聚合优化

```sql
-- 场景：10亿行订单数据的聚合分析
-- 优化前：直接聚合（很慢）
SELECT 
    DATE(order_time) as order_date,
    category,
    SUM(amount) as daily_sales,
    COUNT(DISTINCT user_id) as unique_users,
    AVG(amount) as avg_order_value
FROM order_details o
JOIN dim_products p ON o.product_id = p.product_id
WHERE o.order_time >= '2024-01-01'
GROUP BY DATE(order_time), category;

-- 优化步骤1：创建预聚合表
CREATE TABLE daily_category_summary (
    order_date DATE,
    category VARCHAR(50),
    total_sales DECIMAL(15,2),
    order_count BIGINT,
    unique_users_hll HLL,
    total_amount_for_avg DECIMAL(15,2)
)
DUPLICATE KEY(order_date, category)
PARTITION BY RANGE(order_date) (
    START ("2024-01-01") END ("2024-12-31") EVERY (INTERVAL 1 MONTH)
)
DISTRIBUTED BY HASH(category) BUCKETS 10;

-- 优化步骤2：增量ETL更新预聚合表
INSERT INTO daily_category_summary
SELECT 
    DATE(o.order_time) as order_date,
    p.category,
    SUM(o.amount) as total_sales,
    COUNT(*) as order_count,
    HLL_UNION_AGG(HLL_HASH(o.user_id)) as unique_users_hll,
    SUM(o.amount) as total_amount_for_avg
FROM order_details o
JOIN dim_products p ON o.product_id = p.product_id
WHERE DATE(o.order_time) = '2024-01-15'  -- 增量处理
GROUP BY DATE(o.order_time), p.category;

-- 优化步骤3：快速聚合查询
SELECT 
    order_date,
    category,
    total_sales,
    HLL_CARDINALITY(unique_users_hll) as unique_users,
    total_amount_for_avg / order_count as avg_order_value
FROM daily_category_summary
WHERE order_date >= '2024-01-01'
ORDER BY order_date, category;
```

### 2. 实时聚合仪表板优化

```sql
-- 实时仪表板需求：秒级响应的多维度聚合
-- 解决方案：多层次预聚合 + 物化视图

-- Level 1: 分钟级预聚合
CREATE TABLE minute_stats (
    stat_minute DATETIME,
    region VARCHAR(50),
    category VARCHAR(50),
    sales SUM DECIMAL(15,2),
    orders SUM BIGINT,
    users HLL HLL_UNION
)
AGGREGATE KEY(stat_minute, region, category);

-- Level 2: 小时级物化视图
CREATE MATERIALIZED VIEW hourly_dashboard_mv AS
SELECT 
    DATE_TRUNC('hour', stat_minute) as stat_hour,
    region,
    category,
    SUM(sales) as hourly_sales,
    SUM(orders) as hourly_orders,
    HLL_UNION_AGG(users) as hourly_users
FROM minute_stats
GROUP BY DATE_TRUNC('hour', stat_minute), region, category;

-- Level 3: 实时查询（毫秒级响应）
SELECT 
    region,
    SUM(hourly_sales) as today_sales,
    SUM(hourly_orders) as today_orders,
    HLL_UNION_AGG(hourly_users) as today_users
FROM hourly_dashboard_mv
WHERE stat_hour >= DATE_TRUNC('day', NOW())
GROUP BY region;
```

### 3. 复杂指标计算优化

```sql
-- 复杂业务指标：留存率计算
-- 传统方法（很慢）
WITH user_first_order AS (
    SELECT user_id, MIN(DATE(order_time)) as first_order_date
    FROM order_details
    GROUP BY user_id
),
retention_analysis AS (
    SELECT 
        u.first_order_date,
        COUNT(DISTINCT u.user_id) as new_users,
        COUNT(DISTINCT CASE 
            WHEN o.order_time >= u.first_order_date + INTERVAL 1 DAY
            AND o.order_time < u.first_order_date + INTERVAL 2 DAY 
            THEN o.user_id END) as day1_retained,
        COUNT(DISTINCT CASE 
            WHEN o.order_time >= u.first_order_date + INTERVAL 7 DAY
            AND o.order_time < u.first_order_date + INTERVAL 8 DAY
            THEN o.user_id END) as day7_retained
    FROM user_first_order u
    LEFT JOIN order_details o ON u.user_id = o.user_id
    GROUP BY u.first_order_date
)
SELECT 
    first_order_date,
    new_users,
    day1_retained,
    day7_retained,
    ROUND(day1_retained * 100.0 / new_users, 2) as day1_retention_rate,
    ROUND(day7_retained * 100.0 / new_users, 2) as day7_retention_rate
FROM retention_analysis;

-- 优化方法：使用BITMAP预计算
CREATE TABLE user_retention_bitmap (
    cohort_date DATE,
    day_offset INT,
    user_bitmap BITMAP BITMAP_UNION
)
AGGREGATE KEY(cohort_date, day_offset);

-- 预计算用户留存bitmap
INSERT INTO user_retention_bitmap
SELECT 
    first_order_date as cohort_date,
    DATEDIFF(DATE(order_time), first_order_date) as day_offset,
    TO_BITMAP(user_id) as user_bitmap
FROM order_details o
JOIN (
    SELECT user_id, MIN(DATE(order_time)) as first_order_date
    FROM order_details GROUP BY user_id
) u ON o.user_id = u.user_id;

-- 快速留存率计算
SELECT 
    cohort_date,
    BITMAP_UNION_COUNT(CASE WHEN day_offset = 0 THEN user_bitmap END) as new_users,
    BITMAP_UNION_COUNT(CASE WHEN day_offset = 1 THEN user_bitmap END) as day1_retained,
    BITMAP_UNION_COUNT(CASE WHEN day_offset = 7 THEN user_bitmap END) as day7_retained,
    ROUND(BITMAP_UNION_COUNT(CASE WHEN day_offset = 1 THEN user_bitmap END) * 100.0 / 
          BITMAP_UNION_COUNT(CASE WHEN day_offset = 0 THEN user_bitmap END), 2) as day1_retention_rate
FROM user_retention_bitmap  
WHERE cohort_date >= '2024-01-01'
GROUP BY cohort_date
ORDER BY cohort_date;
```

## 聚合性能监控

### 1. 聚合查询性能监控

```sql
-- 监控聚合查询性能
CREATE VIEW agg_query_performance AS
SELECT 
    query_id,
    user,
    SUBSTR(sql_text, 1, 100) as sql_preview,
    total_time_ms,
    scan_rows,
    scan_bytes,
    CASE 
        WHEN UPPER(sql_text) LIKE '%GROUP BY%' THEN 'AGGREGATION'
        WHEN UPPER(sql_text) LIKE '%COUNT(DISTINCT%' THEN 'COUNT_DISTINCT'
        WHEN UPPER(sql_text) LIKE '%SUM(%' OR UPPER(sql_text) LIKE '%AVG(%' THEN 'BASIC_AGG'
        ELSE 'OTHER'
    END as query_type
FROM information_schema.query_log
WHERE query_start_time >= DATE_SUB(NOW(), INTERVAL 1 HOUR)
  AND (UPPER(sql_text) LIKE '%GROUP BY%' 
       OR UPPER(sql_text) LIKE '%COUNT(%'
       OR UPPER(sql_text) LIKE '%SUM(%');

-- 分析聚合查询性能分布
SELECT 
    query_type,
    COUNT(*) as query_count,
    AVG(total_time_ms) as avg_time_ms,
    MAX(total_time_ms) as max_time_ms,
    AVG(scan_rows) as avg_scan_rows
FROM agg_query_performance
GROUP BY query_type
ORDER BY avg_time_ms DESC;
```

### 2. 物化视图使用监控

```sql
-- 监控物化视图使用情况
SELECT 
    mv.TABLE_NAME as mv_name,
    mv.REFRESH_TYPE,
    mv.IS_ACTIVE,
    mv.LAST_REFRESH_START_TIME,
    mv.LAST_REFRESH_FINISHED_TIME,
    mv.LAST_REFRESH_DURATION,
    mv.LAST_REFRESH_STATE
FROM information_schema.materialized_views mv
WHERE mv.TABLE_SCHEMA = 'demo_etl';

-- 分析物化视图查询改写情况
-- 这需要开启查询日志详细模式
SELECT 
    query_id,
    sql_text,
    total_time_ms,
    CASE 
        WHEN sql_text LIKE '%_mv%' THEN 'USED_MV'
        ELSE 'NO_MV'
    END as mv_usage
FROM information_schema.query_log
WHERE query_start_time >= DATE_SUB(NOW(), INTERVAL 1 HOUR)
  AND UPPER(sql_text) LIKE '%GROUP BY%';
```

## 版本特性对比

| 聚合优化特性 | v2.0 | v2.5 | v3.0 | v3.1 | v3.2+ |
|-------------|------|------|------|------|-------|
| **同步物化视图** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **异步物化视图** | ❌ | ✅ | ✅ | ✅ | ✅ |
| **外部表物化视图** | ❌ | ❌ | ✅ | ✅ | ✅ |
| **HLL精度优化** | ❌ | ✅ | ✅ | ✅ | ✅ |
| **BITMAP操作优化** | 基础 | 基础 | ✅ | ✅ | ✅ |
| **窗口函数优化** | 基础 | ✅ | ✅ | ✅ | ✅ |
| **自动Count Distinct优化** | ❌ | ❌ | ❌ | ✅ | ✅ |
| **自动刷新优化** | ❌ | ❌ | ❌ | ❌ | ✅ |

## 版本选择建议

- **StarRocks 2.0**：支持同步物化视图和基础聚合优化
- **StarRocks 2.5+**：推荐版本，支持异步物化视图和HLL优化
- **StarRocks 3.0+**：企业级选择，完整外部表支持和BITMAP优化
- **StarRocks 3.1+**：最新特性，自动Count Distinct优化
- **StarRocks 3.2+**：最优选择，自动刷新优化

## 小结

StarRocks聚合查询优化的核心策略：

### 1. 预聚合策略
- **Aggregate模型**：适合固定聚合维度（1.19+）
- **物化视图**：支持复杂聚合和多表Join（2.5+）
- **预聚合表**：手动维护的高性能方案

### 2. 特殊函数优化
- **HLL函数**：高效的Count Distinct近似计算（2.5+优化）
- **BITMAP函数**：精确的去重和集合运算（3.0+优化）
- **窗口函数**：合理分区提升性能（3.0+优化）

### 3. 查询优化技巧
- **分区裁剪**：减少扫描数据量
- **预过滤**：在聚合前过滤数据
- **多层聚合**：分层计算复杂指标

### 4. 监控和调优
- **性能监控**：识别慢聚合查询
- **使用分析**：优化物化视图策略
- **成本评估**：平衡性能与存储成本

掌握这些聚合优化技巧，可以让StarRocks在处理复杂分析查询时达到秒级甚至毫秒级响应。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](join-optimization.md) | [➡️ 下一页](index-optimization.md)
---