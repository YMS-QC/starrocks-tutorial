-- ============================================
-- StarRocks 自动分桶示例
-- 版本要求：StarRocks 3.1+
-- ============================================

-- 1. 基础自动分桶表
CREATE TABLE orders_auto_bucket (
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    order_time DATETIME NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) NOT NULL
)
DUPLICATE KEY(order_id)
PARTITION BY RANGE(order_time) (
    PARTITION p20240101 VALUES [('2024-01-01'), ('2024-01-02')),
    PARTITION p20240102 VALUES [('2024-01-02'), ('2024-01-03')),
    PARTITION p20240103 VALUES [('2024-01-03'), ('2024-01-04'))
)
DISTRIBUTED BY RANDOM;  -- 使用自动分桶，无需指定BUCKETS

-- 2. Primary Key表 + 自动分桶
CREATE TABLE users_auto_bucket (
    user_id BIGINT NOT NULL,
    username VARCHAR(50) NOT NULL,
    email VARCHAR(100),
    phone VARCHAR(20),
    register_time DATETIME NOT NULL,
    last_update_time DATETIME
)
PRIMARY KEY(user_id)
DISTRIBUTED BY RANDOM  -- Primary Key表推荐使用自动分桶
PROPERTIES (
    "replication_num" = "3",
    "enable_persistent_index" = "true"
);

-- 3. Aggregate表 + 自动分桶
CREATE TABLE sales_summary_auto (
    sale_date DATE NOT NULL,
    product_category VARCHAR(50) NOT NULL,
    store_id BIGINT NOT NULL,
    total_amount SUM DECIMAL(15,2) DEFAULT "0" COMMENT "销售总额",
    order_count SUM BIGINT DEFAULT "0" COMMENT "订单数",
    avg_amount REPLACE DECIMAL(10,2) DEFAULT "0" COMMENT "平均金额"
)
AGGREGATE KEY(sale_date, product_category, store_id)
PARTITION BY RANGE(sale_date) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01'))
)
DISTRIBUTED BY RANDOM;  -- 聚合表也可以使用自动分桶

-- 4. 表达式分区 + 自动分桶组合
CREATE TABLE events_auto_bucket (
    event_time DATETIME NOT NULL,
    user_id BIGINT NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    event_data JSON,
    session_id VARCHAR(64)
)
DUPLICATE KEY(event_time, user_id)
PARTITION BY date_trunc('hour', event_time)  -- 按小时表达式分区
DISTRIBUTED BY RANDOM;  -- 自动分桶

-- 5. 大表自动分桶示例
CREATE TABLE large_table_auto (
    id BIGINT NOT NULL,
    created_time DATETIME NOT NULL,
    data_field1 VARCHAR(200),
    data_field2 TEXT,
    data_field3 JSON,
    numeric_field DECIMAL(20,6),
    status_field TINYINT
)
DUPLICATE KEY(id, created_time)
PARTITION BY date_trunc('day', created_time)
DISTRIBUTED BY RANDOM;  -- 系统自动选择最优分桶数

-- ============================================
-- 对比：传统Hash分桶 vs 自动分桶
-- ============================================

-- 传统Hash分桶方式（需要手动设计）
CREATE TABLE orders_hash_bucket (
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    amount DECIMAL(10,2) NOT NULL
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32;  -- 需要指定分桶键和分桶数

-- 现代自动分桶方式（零配置）
CREATE TABLE orders_random_bucket (
    order_id BIGINT NOT NULL, 
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    amount DECIMAL(10,2) NOT NULL
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY RANDOM;  -- 零配置，自动优化

-- ============================================
-- 数据倾斜场景对比
-- ============================================

-- 场景：用户ID分布极不均匀（少数大客户占大部分订单）

-- Hash分桶可能导致数据倾斜
CREATE TABLE orders_skewed_hash (
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,  -- 假设用户1001有100万订单，其他用户各有几十个
    amount DECIMAL(10,2) NOT NULL
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32;  -- 可能导致某个桶数据过多

-- 自动分桶避免数据倾斜
CREATE TABLE orders_balanced_random (
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,  -- 不管用户分布如何，数据都会均匀分布
    amount DECIMAL(10,2) NOT NULL
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY RANDOM;  -- 自动保证数据均衡

-- ============================================
-- 插入测试数据
-- ============================================

-- 向自动分桶表插入数据
INSERT INTO orders_auto_bucket VALUES
(1001, 10001, 2001, '2024-01-01 10:00:00', 299.00, 'PAID'),
(1002, 10002, 2002, '2024-01-01 11:00:00', 458.50, 'PAID'),
(1003, 10003, 2003, '2024-01-02 09:00:00', 199.90, 'PENDING'),
(1004, 10001, 2004, '2024-01-02 14:00:00', 699.00, 'PAID'),
(1005, 10004, 2001, '2024-01-03 16:00:00', 299.00, 'CANCELLED');

-- 向用户表插入数据
INSERT INTO users_auto_bucket VALUES
(10001, 'alice', 'alice@email.com', '13800138001', '2024-01-01 09:00:00', NOW()),
(10002, 'bob', 'bob@email.com', '13800138002', '2024-01-01 10:00:00', NOW()),
(10003, 'charlie', 'charlie@email.com', '13800138003', '2024-01-02 11:00:00', NOW()),
(10004, 'diana', 'diana@email.com', '13800138004', '2024-01-03 12:00:00', NOW());

-- 模拟数据倾斜场景
-- 用户10001有大量订单，其他用户订单较少
INSERT INTO orders_balanced_random VALUES
-- 用户10001的1000个订单
(2001, 10001, 3001, 100.00), (2002, 10001, 3002, 150.00), (2003, 10001, 3003, 200.00),
-- ... 这里省略997个订单
-- 其他用户的少量订单
(3001, 10002, 3001, 99.00),
(3002, 10003, 3002, 88.00),
(3003, 10004, 3003, 77.00);

-- ============================================
-- 查询性能对比
-- ============================================

-- 1. 点查询性能对比
-- Hash分桶：可以直接定位到具体桶
SELECT * FROM orders_hash_bucket WHERE user_id = 10001;

-- 自动分桶：需要扫描所有桶，但数据均衡
SELECT * FROM orders_random_bucket WHERE user_id = 10001;

-- 2. 聚合查询性能对比
-- Hash分桶：如果数据倾斜，某些节点负载重
SELECT user_id, COUNT(*), SUM(amount) 
FROM orders_skewed_hash 
GROUP BY user_id;

-- 自动分桶：数据均衡，各节点负载均匀
SELECT user_id, COUNT(*), SUM(amount) 
FROM orders_balanced_random 
GROUP BY user_id;

-- 3. 全表扫描性能对比
-- Hash分桶：可能存在热点桶，并行度不均
SELECT COUNT(*), AVG(amount) FROM orders_hash_bucket;

-- 自动分桶：数据均匀分布，并行度最优
SELECT COUNT(*), AVG(amount) FROM orders_random_bucket;

-- ============================================
-- 适用场景分析
-- ============================================

-- 场景1：新建表，不确定数据分布 → 推荐自动分桶
CREATE TABLE new_business_table (
    id BIGINT NOT NULL,
    business_data JSON,
    created_time DATETIME NOT NULL
)
DUPLICATE KEY(id)
DISTRIBUTED BY RANDOM;  -- 避免错误的分桶设计

-- 场景2：已知会有高频Join，且数据分布均匀 → 考虑Hash分桶
CREATE TABLE dimension_table (
    product_id BIGINT NOT NULL,
    product_name VARCHAR(200),
    category VARCHAR(100)
)
DUPLICATE KEY(product_id)  
DISTRIBUTED BY HASH(product_id) BUCKETS 16;  -- 为了优化Join性能

CREATE TABLE fact_table (
    order_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,  -- 与维度表Join
    sale_amount DECIMAL(10,2)
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(product_id) BUCKETS 16;  -- 相同分桶，优化Join

-- 场景3：数据探索和分析 → 强烈推荐自动分桶
CREATE TABLE analysis_table (
    event_time DATETIME,
    user_attributes JSON,
    metrics JSON
)
DUPLICATE KEY(event_time)
DISTRIBUTED BY RANDOM;  -- 快速建表，无需预先分析数据

-- 场景4：已知存在严重数据倾斜 → 强烈推荐自动分桶
CREATE TABLE user_generated_content (
    content_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,  -- 头部用户内容多，长尾用户内容少
    content TEXT,
    created_time DATETIME
)
DUPLICATE KEY(content_id)
DISTRIBUTED BY RANDOM;  -- 避免热点用户导致的数据倾斜

-- ============================================
-- 监控和验证
-- ============================================

-- 查看表的分桶信息
SELECT 
    TABLE_NAME,
    BUCKET_NUM,
    DISTRIBUTION_KEY,
    DISTRIBUTION_TYPE
FROM information_schema.tables_config 
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('orders_auto_bucket', 'orders_hash_bucket');

-- 查看数据分布情况（检查是否均衡）
SELECT 
    TABLET_ID,
    REPLICA_COUNT,
    VERSION_COUNT,
    DATA_SIZE,
    ROW_COUNT
FROM information_schema.tablets 
WHERE TABLE_NAME = 'orders_auto_bucket'
ORDER BY DATA_SIZE DESC;

-- 分析查询性能
EXPLAIN COSTS
SELECT user_id, COUNT(*), SUM(amount) 
FROM orders_auto_bucket 
GROUP BY user_id;

-- ============================================
-- 迁移建议
-- ============================================

-- 从Hash分桶迁移到自动分桶
-- 1. 创建新的自动分桶表
CREATE TABLE orders_new_random LIKE orders_hash_bucket;
ALTER TABLE orders_new_random SET DISTRIBUTED BY RANDOM;

-- 2. 数据迁移
INSERT INTO orders_new_random SELECT * FROM orders_hash_bucket;

-- 3. 验证数据一致性
SELECT COUNT(*), SUM(amount) FROM orders_hash_bucket;
SELECT COUNT(*), SUM(amount) FROM orders_new_random;

-- 4. 切换表名（在维护窗口执行）
-- RENAME TABLE orders_hash_bucket TO orders_hash_bucket_backup;
-- RENAME TABLE orders_new_random TO orders_hash_bucket;

-- ============================================
-- 最佳实践总结
-- ============================================

/*
自动分桶使用建议：

✅ 强烈推荐场景：
- 新建表，不确定数据分布
- 存在或可能存在数据倾斜
- 数据探索和临时分析
- 大部分业务表

⚠️ 谨慎使用场景：
- 高频Join且确认数据分布均匀
- 需要Colocation Join优化
- 对Join性能要求极高

✅ 使用要点：
- 版本要求：StarRocks 3.1+
- 语法：DISTRIBUTED BY RANDOM
- 无需指定BUCKETS参数
- 系统自动优化分桶数和分布策略

💡 迁移建议：
- 新项目优先使用自动分桶
- 现有项目可以逐步迁移
- 先在测试环境验证性能
- 关注查询模式的变化
*/