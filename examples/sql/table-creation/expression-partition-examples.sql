-- ============================================
-- StarRocks 表达式分区示例
-- 版本要求：StarRocks 3.0+
-- ============================================

-- 1. 基础表达式分区：按天自动分区
CREATE TABLE user_behavior_daily (
    event_time DATETIME NOT NULL COMMENT "事件时间",
    user_id BIGINT NOT NULL COMMENT "用户ID", 
    event_type VARCHAR(50) NOT NULL COMMENT "事件类型",
    page_url VARCHAR(500) COMMENT "页面URL",
    user_agent TEXT COMMENT "用户代理",
    ip_address VARCHAR(50) COMMENT "IP地址"
)
DUPLICATE KEY(event_time, user_id)
PARTITION BY date_trunc('day', event_time)  -- 按天自动分区
DISTRIBUTED BY HASH(user_id) BUCKETS 32;

-- 2. 按周分区（7天一个分区）
CREATE TABLE sales_weekly (
    sale_time DATETIME NOT NULL,
    store_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    quantity INT NOT NULL
)
DUPLICATE KEY(sale_time, store_id)
PARTITION BY time_slice(sale_time, INTERVAL 7 day)  -- 按周分区
DISTRIBUTED BY HASH(store_id) BUCKETS 24;

-- 3. 按月分区
CREATE TABLE financial_monthly (
    record_time DATETIME NOT NULL,
    account_id BIGINT NOT NULL,
    transaction_type VARCHAR(50) NOT NULL,
    amount DECIMAL(15,2) NOT NULL,
    description TEXT
)
DUPLICATE KEY(record_time, account_id)
PARTITION BY date_trunc('month', record_time)  -- 按月分区
DISTRIBUTED BY HASH(account_id) BUCKETS 16;

-- 4. Unix时间戳分区（秒级）
CREATE TABLE sensor_data (
    sensor_id BIGINT NOT NULL,
    timestamp_sec BIGINT NOT NULL COMMENT "Unix时间戳(秒)",
    temperature DECIMAL(5,2) COMMENT "温度",
    humidity DECIMAL(5,2) COMMENT "湿度", 
    location VARCHAR(100) COMMENT "位置",
    readings JSON COMMENT "其他读数"
)
DUPLICATE KEY(sensor_id, timestamp_sec)
PARTITION BY from_unixtime(timestamp_sec, '%Y%m%d')  -- Unix时间戳转日期分区
DISTRIBUTED BY HASH(sensor_id) BUCKETS 16;

-- 5. 毫秒时间戳分区（13位）
CREATE TABLE realtime_events (
    event_id BIGINT NOT NULL,
    timestamp_ms BIGINT NOT NULL COMMENT "毫秒时间戳",
    event_name VARCHAR(100) NOT NULL,
    user_id BIGINT,
    session_id VARCHAR(64),
    properties JSON COMMENT "事件属性"
)
DUPLICATE KEY(event_id)
PARTITION BY from_unixtime_ms(timestamp_ms, '%Y%m%d')  -- 毫秒时间戳转日期
DISTRIBUTED BY HASH(user_id) BUCKETS 64;

-- 6. 字符串日期转分区
CREATE TABLE app_logs (
    log_date_str VARCHAR(20) NOT NULL COMMENT "日期字符串",
    log_level VARCHAR(10) NOT NULL COMMENT "日志级别",
    service_name VARCHAR(50) NOT NULL COMMENT "服务名",
    message TEXT COMMENT "日志消息",
    trace_id VARCHAR(64) COMMENT "链路ID",
    request_id VARCHAR(64) COMMENT "请求ID"
)
DUPLICATE KEY(log_date_str, service_name)
PARTITION BY str2date(log_date_str, '%Y-%m-%d')  -- 字符串转日期分区
DISTRIBUTED BY HASH(service_name) BUCKETS 24;

-- 7. 复杂格式字符串分区
CREATE TABLE custom_logs (
    datetime_str VARCHAR(30) NOT NULL COMMENT "自定义日期时间格式",
    application VARCHAR(50) NOT NULL,
    log_content TEXT,
    severity INT
)
DUPLICATE KEY(datetime_str, application)
PARTITION BY str_to_date(datetime_str, '%Y/%m/%d %H:%i:%s')  -- 自定义格式转换
DISTRIBUTED BY HASH(application) BUCKETS 16;

-- 8. 多列组合分区：时间 + 地区
CREATE TABLE orders_by_region (
    order_id BIGINT NOT NULL,
    order_time DATETIME NOT NULL,
    user_id BIGINT NOT NULL,
    region VARCHAR(50) NOT NULL COMMENT "地区",
    city VARCHAR(50) COMMENT "城市",
    amount DECIMAL(10,2) NOT NULL
)
DUPLICATE KEY(order_id)
PARTITION BY date_trunc('day', order_time), region  -- 多列组合分区
DISTRIBUTED BY HASH(order_id) BUCKETS 20;

-- 9. 多列组合分区：日期字符串 + 业务类型
CREATE TABLE business_metrics (
    date_str VARCHAR(20) NOT NULL,
    business_type VARCHAR(50) NOT NULL,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DOUBLE,
    additional_info JSON
)
DUPLICATE KEY(date_str, business_type, metric_name)  
PARTITION BY str2date(date_str, '%Y-%m-%d'), business_type  -- 日期转换 + 业务类型
DISTRIBUTED BY HASH(metric_name) BUCKETS 32;

-- 10. 整数时间戳转月份分区
CREATE TABLE monthly_reports (
    report_date_int INT NOT NULL COMMENT "格式：20240101",
    department_id BIGINT NOT NULL,
    report_type VARCHAR(50) NOT NULL,
    metrics JSON COMMENT "报表指标"
)
DUPLICATE KEY(report_date_int, department_id)
PARTITION BY date_trunc('month', str_to_date(CAST(report_date_int as STRING), '%Y%m%d'))  -- 复杂转换
DISTRIBUTED BY HASH(department_id) BUCKETS 12;

-- ============================================
-- 插入测试数据
-- ============================================

-- 测试数据1：用户行为数据（自动创建日分区）
INSERT INTO user_behavior_daily VALUES
('2024-01-15 10:30:00', 1001, 'page_view', '/home', 'Chrome/120.0', '192.168.1.1'),
('2024-01-15 11:20:00', 1002, 'click', '/product/123', 'Safari/17.0', '192.168.1.2'),
('2024-01-16 09:15:00', 1003, 'purchase', '/checkout', 'Firefox/121.0', '192.168.1.3'),
('2024-01-16 14:45:00', 1001, 'page_view', '/profile', 'Chrome/120.0', '192.168.1.1');

-- 测试数据2：Unix时间戳数据
INSERT INTO sensor_data VALUES
(1001, 1705286400, 25.5, 60.2, '车间A', '{"pressure": 1013.25}'),  -- 2024-01-15
(1002, 1705372800, 26.1, 58.9, '车间B', '{"pressure": 1012.80}'),  -- 2024-01-16  
(1003, 1705459200, 24.8, 62.1, '车间C', '{"pressure": 1014.10}');  -- 2024-01-17

-- 测试数据3：字符串日期数据
INSERT INTO app_logs VALUES
('2024-01-15', 'INFO', 'user-service', 'User 1001 login success', 'trace-001', 'req-001'),
('2024-01-15', 'ERROR', 'order-service', 'Database timeout', 'trace-002', 'req-002'),
('2024-01-16', 'WARN', 'payment-service', 'High latency detected', 'trace-003', 'req-003');

-- 测试数据4：多列组合分区
INSERT INTO orders_by_region VALUES
(1001, '2024-01-15 10:00:00', 10001, '华北', '北京', 299.00),
(1002, '2024-01-15 11:00:00', 10002, '华东', '上海', 458.50),
(1003, '2024-01-16 09:00:00', 10003, '华北', '天津', 199.90),
(1004, '2024-01-16 15:00:00', 10004, '华南', '深圳', 699.00);

-- ============================================
-- 查看分区创建情况
-- ============================================

-- 查看用户行为表的分区
SHOW PARTITIONS FROM user_behavior_daily;

-- 查看传感器数据表的分区  
SHOW PARTITIONS FROM sensor_data;

-- 查看应用日志表的分区
SHOW PARTITIONS FROM app_logs;

-- 查看多列组合分区表的分区（会看到类似 p20240115_华北, p20240115_华东 等）
SHOW PARTITIONS FROM orders_by_region;

-- ============================================
-- 分区裁剪查询示例
-- ============================================

-- 1. 时间范围查询（能够进行分区裁剪）
SELECT COUNT(*) 
FROM user_behavior_daily 
WHERE event_time >= '2024-01-15' 
  AND event_time < '2024-01-16';

-- 2. 直接匹配分区表达式（最高效的分区裁剪）
SELECT event_type, COUNT(*) as event_count
FROM user_behavior_daily 
WHERE date_trunc('day', event_time) = '2024-01-15'
GROUP BY event_type;

-- 3. Unix时间戳范围查询
SELECT sensor_id, AVG(temperature) as avg_temp
FROM sensor_data 
WHERE timestamp_sec BETWEEN 1705286400 AND 1705372800  -- 2024-01-15 到 2024-01-16
GROUP BY sensor_id;

-- 4. 字符串日期查询
SELECT service_name, COUNT(*) as log_count
FROM app_logs 
WHERE log_date_str = '2024-01-15'
GROUP BY service_name;

-- 5. 多列组合分区查询
SELECT COUNT(*) as order_count, SUM(amount) as total_amount
FROM orders_by_region 
WHERE date_trunc('day', order_time) = '2024-01-15'
  AND region = '华北';

-- ============================================
-- 分区管理操作
-- ============================================

-- 删除历史分区（注意：会永久删除数据）
-- ALTER TABLE user_behavior_daily DROP PARTITION p20231201;

-- 查看分区统计信息
SELECT 
    TABLE_NAME,
    PARTITION_NAME,
    PARTITION_DESCRIPTION,
    DATA_LENGTH / 1024 / 1024 as DATA_SIZE_MB,
    ROWS
FROM information_schema.partitions 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'user_behavior_daily'
ORDER BY PARTITION_NAME;

-- 分区裁剪验证（查看执行计划）
EXPLAIN 
SELECT * FROM user_behavior_daily 
WHERE event_time >= '2024-01-15' AND event_time < '2024-01-16';

-- ============================================
-- 性能优化建议
-- ============================================

-- 1. 确保查询条件能匹配分区表达式
-- ✅ 推荐：直接使用分区表达式
SELECT * FROM user_behavior_daily 
WHERE date_trunc('day', event_time) = '2024-01-15';

-- ✅ 推荐：使用范围查询
SELECT * FROM user_behavior_daily 
WHERE event_time >= '2024-01-15' AND event_time < '2024-01-16';

-- ❌ 避免：使用不匹配的函数
-- SELECT * FROM user_behavior_daily 
-- WHERE DATE_FORMAT(event_time, '%w') = '1';  -- 无法分区裁剪

-- 2. 监控分区数量，避免过多小分区
SELECT COUNT(DISTINCT PARTITION_NAME) as partition_count
FROM information_schema.partitions 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'user_behavior_daily';