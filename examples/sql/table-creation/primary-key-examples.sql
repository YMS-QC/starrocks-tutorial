-- ============================================
-- StarRocks Primary Key 表模型示例
-- 版本要求：StarRocks 3.0+
-- ============================================

-- 1. 基础 Primary Key 表
CREATE TABLE users_pk (
    user_id BIGINT NOT NULL COMMENT "用户ID",
    username VARCHAR(50) NOT NULL COMMENT "用户名",
    email VARCHAR(100) COMMENT "邮箱",
    phone VARCHAR(20) COMMENT "手机号",
    age INT COMMENT "年龄",
    city VARCHAR(50) COMMENT "城市",
    register_time DATETIME NOT NULL COMMENT "注册时间",
    last_login_time DATETIME COMMENT "最后登录时间",
    status TINYINT DEFAULT 1 COMMENT "状态：1-活跃，0-禁用"
)
PRIMARY KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 10
PROPERTIES (
    "replication_num" = "3",
    "enable_persistent_index" = "true"  -- 启用持久化索引
);

-- 2. Primary Key 表 + 表达式分区 + 自动分桶
CREATE TABLE orders_pk (
    order_id BIGINT NOT NULL COMMENT "订单ID",
    user_id BIGINT NOT NULL COMMENT "用户ID",
    merchant_id INT NOT NULL COMMENT "商家ID",
    order_time DATETIME NOT NULL COMMENT "下单时间",
    product_id INT NOT NULL COMMENT "产品ID",
    amount DECIMAL(10,2) NOT NULL COMMENT "金额",
    status TINYINT NOT NULL COMMENT "订单状态"
)
PRIMARY KEY(order_id)
PARTITION BY date_trunc('day', order_time)  -- 表达式分区
DISTRIBUTED BY RANDOM  -- 自动分桶
PROPERTIES (
    "replication_num" = "3",
    "enable_persistent_index" = "true"
);

-- 3. 主键与排序键分离
CREATE TABLE events_pk (
    event_id BIGINT NOT NULL,
    event_time DATETIME NOT NULL,
    user_id BIGINT NOT NULL,
    event_type VARCHAR(50) NOT NULL,
    session_id VARCHAR(64),
    properties JSON COMMENT "事件属性"
)
PRIMARY KEY(event_id)  -- 主键：保证唯一性
PARTITION BY date_trunc('hour', event_time)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
ORDER BY(event_time, user_id)  -- 排序键：优化查询
PROPERTIES (
    "replication_num" = "3",
    "enable_persistent_index" = "true"
);

-- 4. 云原生环境的 Primary Key 表（v3.3.2+）
CREATE TABLE metrics_cloud_pk (
    metric_id BIGINT NOT NULL,
    metric_time DATETIME NOT NULL,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DOUBLE,
    tags JSON
)
PRIMARY KEY(metric_id)
PARTITION BY date_trunc('day', metric_time)
DISTRIBUTED BY HASH(metric_name) BUCKETS 16
PROPERTIES (
    "replication_num" = "1",  -- 云环境通常使用1副本
    "enable_persistent_index" = "true",
    "persistent_index_type" = "CLOUD_NATIVE"  -- 对象存储持久化
);

-- 5. 复合主键示例
CREATE TABLE order_items_pk (
    order_id BIGINT NOT NULL,
    item_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    quantity INT NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    discount_amount DECIMAL(10,2) DEFAULT 0.00,
    create_time DATETIME NOT NULL
)
PRIMARY KEY(order_id, item_id)  -- 复合主键
DISTRIBUTED BY HASH(order_id) BUCKETS 20
PROPERTIES (
    "replication_num" = "3",
    "enable_persistent_index" = "true"
);

-- ============================================
-- 数据操作示例
-- ============================================

-- 插入数据（自动UPSERT）
INSERT INTO users_pk VALUES
(1001, 'alice', 'alice@email.com', '13800138001', 25, '北京', '2024-01-01 10:00:00', NOW(), 1),
(1002, 'bob', 'bob@email.com', '13800138002', 30, '上海', '2024-01-02 10:00:00', NOW(), 1);

-- 更新数据（相同主键会自动更新）
INSERT INTO users_pk VALUES
(1001, 'alice_new', 'alice_new@email.com', '13900139001', 26, '深圳', '2024-01-01 10:00:00', NOW(), 1);

-- 批量UPSERT（v3.2+）
INSERT INTO users_pk 
SELECT user_id, username, email, phone, age, city, register_time, NOW(), 1
FROM source_users
ON DUPLICATE KEY UPDATE 
    username = VALUES(username),
    email = VALUES(email),
    last_login_time = VALUES(last_login_time);

-- 条件更新
UPDATE users_pk 
SET status = 0, 
    last_login_time = NOW()
WHERE user_id = 1002;

-- 删除数据
DELETE FROM users_pk 
WHERE user_id = 1002;

-- 批量删除
DELETE FROM users_pk 
WHERE status = 0 AND last_login_time < DATE_SUB(NOW(), INTERVAL 30 DAY);

-- ============================================
-- 部分更新示例（Partial Update）
-- ============================================

-- 创建支持部分更新的表
CREATE TABLE products_pk (
    product_id BIGINT NOT NULL,
    name VARCHAR(200) NOT NULL,
    price DECIMAL(10,2),
    stock INT,
    description TEXT,
    update_time DATETIME
)
PRIMARY KEY(product_id)
DISTRIBUTED BY HASH(product_id) BUCKETS 16
PROPERTIES (
    "replication_num" = "3",
    "enable_persistent_index" = "true"
);

-- 插入初始数据
INSERT INTO products_pk VALUES
(2001, 'iPhone 15', 5999.00, 100, 'Apple iPhone 15 128GB', NOW()),
(2002, 'MacBook Pro', 12999.00, 50, 'Apple MacBook Pro M3', NOW());

-- 仅更新部分列（价格和库存）
INSERT INTO products_pk (product_id, price, stock, update_time) 
VALUES (2001, 5799.00, 95, NOW())
ON DUPLICATE KEY UPDATE
    price = VALUES(price),
    stock = VALUES(stock),
    update_time = VALUES(update_time);

-- ============================================
-- 性能对比查询示例
-- ============================================

-- 点查询（Primary Key表性能最优）
SELECT * FROM users_pk WHERE user_id = 1001;

-- 范围查询
SELECT user_id, username, city 
FROM users_pk 
WHERE user_id BETWEEN 1000 AND 2000
ORDER BY register_time DESC;

-- 复杂查询
SELECT 
    city,
    COUNT(*) as user_count,
    AVG(age) as avg_age,
    COUNT(CASE WHEN status = 1 THEN 1 END) as active_users
FROM users_pk 
WHERE register_time >= '2024-01-01'
GROUP BY city
HAVING user_count > 10
ORDER BY user_count DESC;

-- Join查询示例
SELECT 
    u.username,
    u.city,
    COUNT(o.order_id) as order_count,
    SUM(o.amount) as total_amount
FROM users_pk u
LEFT JOIN orders_pk o ON u.user_id = o.user_id
WHERE o.order_time >= '2024-01-01'
GROUP BY u.user_id, u.username, u.city
ORDER BY total_amount DESC
LIMIT 100;