# 第一个ETL任务

---

## 📖 导航

[🏠 返回主页](../../README.md) | [⬅️ 上一页](connect-tools.md) | [➡️ 下一页](../03-table-design/table-models.md)

---

## 学习目标

- 掌握StarRocks数据导入的基本方法
- 学会使用Stream Load进行批量数据导入
- 了解INSERT语句的使用场景和限制
- 掌握基础的数据转换和清洗技巧

## 数据导入方式概览

| 导入方式 | 适用场景 | 数据量 | 实时性 | 复杂度 |
|---------|---------|--------|--------|--------|
| **INSERT** | 小批量、实时写入 | < 10万行 | 实时 | 简单 |
| **Stream Load** | 文件批量导入 | < 1000万行 | 准实时 | 中等 |
| **Broker Load** | 大文件、HDFS导入 | > 1000万行 | 离线 | 复杂 |
| **Routine Load** | Kafka实时流 | 连续流数据 | 实时 | 中等 |

## 准备示例数据

### 1. 创建示例数据库和表

```sql
-- 连接StarRocks
mysql -h localhost -P 9030 -u root

-- 创建示例数据库
CREATE DATABASE IF NOT EXISTS demo_etl;
USE demo_etl;

-- 创建用户表（Unique模型，支持更新）
CREATE TABLE users (
    user_id BIGINT NOT NULL,
    username VARCHAR(50) NOT NULL,
    email VARCHAR(100),
    age INT,
    gender VARCHAR(10),
    city VARCHAR(50),
    register_date DATE,
    last_login DATETIME,
    status VARCHAR(20) DEFAULT 'ACTIVE',
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP
)
UNIQUE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 10
PROPERTIES (
    "replication_num" = "1",
    "enable_unique_key_merge_on_write" = "false"
);

-- 创建订单表（Duplicate模型，保留明细）
CREATE TABLE orders (
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    product_name VARCHAR(200),
    category VARCHAR(50),
    price DECIMAL(10,2),
    quantity INT,
    amount DECIMAL(10,2),
    order_date DATE,
    order_time DATETIME,
    status VARCHAR(20),
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP
)
DUPLICATE KEY(order_id, user_id, order_time)
PARTITION BY RANGE(order_date) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01')),
    PARTITION p202403 VALUES [('2024-03-01'), ('2024-04-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 10;

-- 创建销售汇总表（Aggregate模型，预聚合）
CREATE TABLE sales_summary (
    stat_date DATE NOT NULL,
    category VARCHAR(50) NOT NULL,
    total_amount DECIMAL(15,2) SUM DEFAULT "0",
    order_count BIGINT SUM DEFAULT "0",
    avg_price DECIMAL(10,2) REPLACE DEFAULT "0",
    max_price DECIMAL(10,2) MAX DEFAULT "0",
    min_price DECIMAL(10,2) MIN DEFAULT "999999",
    unique_users HLL HLL_UNION,
    update_time DATETIME REPLACE DEFAULT CURRENT_TIMESTAMP
)
AGGREGATE KEY(stat_date, category)
PARTITION BY RANGE(stat_date) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01')),
    PARTITION p202403 VALUES [('2024-03-01'), ('2024-04-01'))
)
DISTRIBUTED BY HASH(category) BUCKETS 10;

-- 查看表结构
SHOW CREATE TABLE users;
SHOW CREATE TABLE orders;
SHOW CREATE TABLE sales_summary;
```

### 2. 生成示例数据文件

```bash
# 创建示例数据目录
mkdir -p sample-data

# 生成用户数据文件
cat > sample-data/users.csv << 'EOF'
user_id,username,email,age,gender,city,register_date,last_login,status
1001,alice,alice@example.com,25,F,北京,2024-01-01,2024-01-15 10:30:00,ACTIVE
1002,bob,bob@example.com,30,M,上海,2024-01-02,2024-01-16 09:15:00,ACTIVE
1003,charlie,charlie@example.com,35,M,深圳,2024-01-03,2024-01-17 14:20:00,ACTIVE
1004,diana,diana@example.com,28,F,广州,2024-01-04,2024-01-18 16:45:00,ACTIVE
1005,eve,eve@example.com,32,F,杭州,2024-01-05,2024-01-19 11:10:00,INACTIVE
1006,frank,frank@example.com,27,M,南京,2024-01-06,2024-01-20 13:25:00,ACTIVE
1007,grace,grace@example.com,29,F,成都,2024-01-07,2024-01-21 15:35:00,ACTIVE
1008,henry,henry@example.com,31,M,武汉,2024-01-08,2024-01-22 08:50:00,ACTIVE
1009,ivy,ivy@example.com,26,F,西安,2024-01-09,2024-01-23 12:15:00,ACTIVE
1010,jack,jack@example.com,33,M,长沙,2024-01-10,2024-01-24 17:40:00,ACTIVE
EOF

# 生成订单数据文件
cat > sample-data/orders.csv << 'EOF'
order_id,user_id,product_id,product_name,category,price,quantity,amount,order_date,order_time,status
2001,1001,3001,iPhone 15,手机,7999.00,1,7999.00,2024-01-15,2024-01-15 10:30:00,PAID
2002,1002,3002,MacBook Pro,电脑,16999.00,1,16999.00,2024-01-16,2024-01-16 09:15:00,PAID
2003,1003,3003,AirPods Pro,耳机,1599.00,2,3198.00,2024-01-17,2024-01-17 14:20:00,PAID
2004,1001,3004,iPad Air,平板,4599.00,1,4599.00,2024-01-18,2024-01-18 11:45:00,PAID
2005,1004,3001,iPhone 15,手机,7999.00,1,7999.00,2024-01-19,2024-01-19 16:45:00,PENDING
2006,1005,3005,Apple Watch,手表,2999.00,1,2999.00,2024-01-20,2024-01-20 11:10:00,PAID
2007,1002,3003,AirPods Pro,耳机,1599.00,1,1599.00,2024-01-21,2024-01-21 13:25:00,PAID
2008,1006,3002,MacBook Pro,电脑,16999.00,1,16999.00,2024-01-22,2024-01-22 15:35:00,CANCELLED
2009,1007,3004,iPad Air,平板,4599.00,2,9198.00,2024-01-23,2024-01-23 08:50:00,PAID
2010,1003,3001,iPhone 15,手机,7999.00,1,7999.00,2024-01-24,2024-01-24 12:15:00,PAID
EOF

# 生成更多订单数据（用于性能测试）
python3 << 'EOF'
import csv
import random
from datetime import datetime, timedelta

# 生成大批量订单数据
products = [
    (3001, 'iPhone 15', '手机', 7999.00),
    (3002, 'MacBook Pro', '电脑', 16999.00),
    (3003, 'AirPods Pro', '耳机', 1599.00),
    (3004, 'iPad Air', '平板', 4599.00),
    (3005, 'Apple Watch', '手表', 2999.00),
    (3006, 'iMac', '电脑', 12999.00),
    (3007, 'Apple TV', '电视', 1299.00),
    (3008, 'Magic Keyboard', '配件', 799.00),
    (3009, 'AirTag', '配件', 229.00),
    (3010, 'HomePod', '音响', 2299.00)
]

statuses = ['PAID', 'PENDING', 'CANCELLED', 'REFUNDED']
start_date = datetime(2024, 1, 1)

with open('sample-data/orders_bulk.csv', 'w', newline='', encoding='utf-8') as f:
    writer = csv.writer(f)
    writer.writerow(['order_id', 'user_id', 'product_id', 'product_name', 'category', 'price', 'quantity', 'amount', 'order_date', 'order_time', 'status'])
    
    for i in range(10000):  # 生成10000条订单
        order_id = 10000 + i
        user_id = random.randint(1001, 1100)  # 100个用户
        product = random.choice(products)
        product_id, product_name, category, price = product
        quantity = random.randint(1, 3)
        amount = price * quantity
        
        # 随机日期时间
        days_offset = random.randint(0, 89)  # 90天内
        order_datetime = start_date + timedelta(days=days_offset, 
                                               hours=random.randint(0, 23), 
                                               minutes=random.randint(0, 59))
        order_date = order_datetime.date()
        status = random.choice(statuses)
        
        writer.writerow([order_id, user_id, product_id, product_name, category, 
                        price, quantity, amount, order_date, 
                        order_datetime.strftime('%Y-%m-%d %H:%M:%S'), status])

print("生成了10000条订单数据到 sample-data/orders_bulk.csv")
EOF
```

## INSERT语句导入

### 1. 单行插入

```sql
-- 单行插入用户数据
INSERT INTO users (user_id, username, email, age, gender, city, register_date) 
VALUES (2001, 'test_user', 'test@example.com', 25, 'M', '北京', '2024-01-01');

-- 查询验证
SELECT * FROM users WHERE user_id = 2001;
```

### 2. 批量插入

```sql
-- 批量插入多行数据
INSERT INTO users (user_id, username, email, age, gender, city, register_date, status) VALUES
(2002, 'user2', 'user2@example.com', 28, 'F', '上海', '2024-01-02', 'ACTIVE'),
(2003, 'user3', 'user3@example.com', 30, 'M', '深圳', '2024-01-03', 'ACTIVE'),
(2004, 'user4', 'user4@example.com', 32, 'F', '广州', '2024-01-04', 'ACTIVE');

-- 查询验证
SELECT COUNT(*) FROM users WHERE user_id >= 2002;
```

### 3. INSERT INTO SELECT

```sql
-- 从其他表或查询结果插入
-- 创建用户统计表
CREATE TABLE user_stats (
    city VARCHAR(50),
    user_count BIGINT,
    avg_age DECIMAL(5,2),
    stat_date DATE
) DISTRIBUTED BY HASH(city) BUCKETS 10;

-- 使用INSERT INTO SELECT插入统计数据
INSERT INTO user_stats (city, user_count, avg_age, stat_date)
SELECT 
    city,
    COUNT(*) as user_count,
    AVG(age) as avg_age,
    CURRENT_DATE as stat_date
FROM users 
WHERE status = 'ACTIVE'
GROUP BY city;

-- 查询验证
SELECT * FROM user_stats;
```

## Stream Load导入

Stream Load是StarRocks推荐的批量导入方式，适合中等规模的数据导入。

### 1. 基础Stream Load

```bash
# 导入用户数据
curl --location-trusted -u root: \
    -H "label:load_users_$(date +%Y%m%d_%H%M%S)" \
    -H "format:csv" \
    -H "column_separator:," \
    -H "skip_header:1" \
    -T sample-data/users.csv \
    http://localhost:8030/api/demo_etl/users/_stream_load

# 检查导入结果
mysql -h localhost -P 9030 -u root -e "SELECT COUNT(*) FROM demo_etl.users;"
```

### 2. 带数据转换的Stream Load

```bash
# 导入订单数据，带字段映射和转换
curl --location-trusted -u root: \
    -H "label:load_orders_$(date +%Y%m%d_%H%M%S)" \
    -H "format:csv" \
    -H "column_separator:," \
    -H "skip_header:1" \
    -H "columns:order_id,user_id,product_id,product_name,category,price,quantity,amount,order_date,order_time,status" \
    -H "where:status IN ('PAID', 'PENDING')" \
    -T sample-data/orders.csv \
    http://localhost:8030/api/demo_etl/orders/_stream_load

# 验证导入结果
mysql -h localhost -P 9030 -u root -e "
USE demo_etl;
SELECT status, COUNT(*) FROM orders GROUP BY status;
"
```

### 3. 大批量数据导入

```bash
# 导入大批量订单数据
curl --location-trusted -u root: \
    -H "label:load_orders_bulk_$(date +%Y%m%d_%H%M%S)" \
    -H "format:csv" \
    -H "column_separator:," \
    -H "skip_header:1" \
    -H "timeout:3600" \
    -H "max_filter_ratio:0.1" \
    -T sample-data/orders_bulk.csv \
    http://localhost:8030/api/demo_etl/orders/_stream_load

# 检查导入状态
mysql -h localhost -P 9030 -u root -e "
USE demo_etl;
SELECT COUNT(*) as total_orders FROM orders;
SELECT status, COUNT(*) FROM orders GROUP BY status;
"
```

### 4. JSON数据导入

```bash
# 创建JSON格式的用户数据
cat > sample-data/users.json << 'EOF'
{"user_id": 3001, "username": "json_user1", "email": "json1@example.com", "age": 25, "gender": "M", "city": "北京"}
{"user_id": 3002, "username": "json_user2", "email": "json2@example.com", "age": 28, "gender": "F", "city": "上海"}
{"user_id": 3003, "username": "json_user3", "email": "json3@example.com", "age": 30, "gender": "M", "city": "深圳"}
EOF

# 导入JSON数据
curl --location-trusted -u root: \
    -H "label:load_users_json_$(date +%Y%m%d_%H%M%S)" \
    -H "format:json" \
    -H "strip_outer_array:false" \
    -H "jsonpaths:[\"$.user_id\", \"$.username\", \"$.email\", \"$.age\", \"$.gender\", \"$.city\"]" \
    -H "columns:user_id,username,email,age,gender,city,register_date,last_login,status,create_time" \
    -H "set:register_date=current_date(),last_login=now(),status='ACTIVE',create_time=now()" \
    -T sample-data/users.json \
    http://localhost:8030/api/demo_etl/users/_stream_load
```

## 数据转换和清洗

### 1. 数据类型转换

```sql
-- 创建原始数据表（所有字段为字符串）
CREATE TABLE raw_data (
    user_id_str VARCHAR(50),
    age_str VARCHAR(10),
    amount_str VARCHAR(20),
    date_str VARCHAR(20)
) DISTRIBUTED BY HASH(user_id_str) BUCKETS 10;

-- 插入原始数据
INSERT INTO raw_data VALUES
('1001', '25', '1999.50', '2024-01-15'),
('1002', '30', '2500.00', '2024-01-16'),
('1003', 'unknown', '3200.75', '2024-01-17');

-- 数据转换插入到目标表
INSERT INTO users (user_id, username, age, register_date, status, create_time)
SELECT 
    CAST(user_id_str AS BIGINT) as user_id,
    CONCAT('user_', user_id_str) as username,
    CASE 
        WHEN age_str = 'unknown' THEN NULL
        ELSE CAST(age_str AS INT)
    END as age,
    CAST(date_str AS DATE) as register_date,
    'ACTIVE' as status,
    NOW() as create_time
FROM raw_data
WHERE user_id_str REGEXP '^[0-9]+$';  -- 只处理数字ID

-- 查询验证
SELECT * FROM users WHERE user_id >= 1001 AND user_id <= 1003;
```

### 2. 数据清洗和验证

```sql
-- 创建数据质量检查函数
-- 检查邮箱格式
SELECT 
    user_id,
    email,
    CASE 
        WHEN email REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$' 
        THEN 'VALID' 
        ELSE 'INVALID' 
    END as email_status
FROM users 
WHERE email IS NOT NULL;

-- 检查年龄合理性
SELECT 
    user_id,
    age,
    CASE 
        WHEN age IS NULL THEN 'NULL'
        WHEN age < 0 OR age > 120 THEN 'INVALID'
        ELSE 'VALID'
    END as age_status
FROM users;

-- 修复数据问题
UPDATE users 
SET age = NULL 
WHERE age < 0 OR age > 120;

-- 删除无效数据
DELETE FROM users 
WHERE email IS NOT NULL 
  AND email NOT REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$';
```

### 3. 数据聚合和汇总

```sql
-- 计算销售汇总数据
INSERT INTO sales_summary (stat_date, category, total_amount, order_count, avg_price, max_price, min_price, unique_users, update_time)
SELECT 
    order_date as stat_date,
    category,
    SUM(amount) as total_amount,
    COUNT(*) as order_count,
    AVG(price) as avg_price,
    MAX(price) as max_price,
    MIN(price) as min_price,
    HLL_HASH(user_id) as unique_users,
    NOW() as update_time
FROM orders 
WHERE status = 'PAID'
  AND order_date >= '2024-01-01'
GROUP BY order_date, category;

-- 查询汇总结果
SELECT 
    stat_date,
    category,
    total_amount,
    order_count,
    ROUND(avg_price, 2) as avg_price,
    HLL_CARDINALITY(unique_users) as unique_user_count
FROM sales_summary 
ORDER BY stat_date, category;
```

## 导入监控和优化

### 1. 查看导入历史

```sql
-- 查看Stream Load导入历史
SHOW LOAD\G

-- 查看具体导入任务详情
SHOW LOAD WHERE LABEL = 'your_label_name'\G

-- 查看最近的导入任务
SHOW LOAD ORDER BY CreateTime DESC LIMIT 5\G
```

### 2. 导入性能监控

```sql
-- 查看表的数据分布
SHOW DATA FROM orders;

-- 查看分区数据分布
SHOW PARTITIONS FROM orders\G

-- 查看导入任务统计
SELECT 
    `Database`,
    `Table`,
    COUNT(*) as load_count,
    SUM(LoadedRows) as total_rows,
    SUM(LoadBytes) as total_bytes
FROM information_schema.loads 
WHERE CreateTime >= DATE_SUB(NOW(), INTERVAL 1 DAY)
GROUP BY `Database`, `Table`;
```

### 3. 性能优化建议

```bash
# Stream Load性能优化参数
curl --location-trusted -u root: \
    -H "label:optimized_load_$(date +%Y%m%d_%H%M%S)" \
    -H "format:csv" \
    -H "column_separator:," \
    -H "skip_header:1" \
    -H "timeout:7200" \
    -H "max_filter_ratio:0.05" \
    -H "load_mem_limit:2147483648" \
    -H "exec_mem_limit:2147483648" \
    -H "strict_mode:false" \
    -H "partial_update:false" \
    -T sample-data/orders_bulk.csv \
    http://localhost:8030/api/demo_etl/orders/_stream_load
```

## 错误处理和故障排查

### 1. 常见错误处理

```sql
-- 查看导入错误
SHOW LOAD WHERE State = 'CANCELLED' ORDER BY CreateTime DESC LIMIT 5\G

-- 处理数据格式错误
-- 创建错误处理表
CREATE TABLE error_log (
    error_time DATETIME,
    table_name VARCHAR(100),
    error_msg TEXT,
    data_sample TEXT
) DISTRIBUTED BY HASH(table_name) BUCKETS 10;
```

### 2. 数据一致性检查

```sql
-- 检查主键重复
SELECT user_id, COUNT(*) as cnt
FROM users 
GROUP BY user_id 
HAVING COUNT(*) > 1;

-- 检查外键约束（应用层）
SELECT o.user_id
FROM orders o
LEFT JOIN users u ON o.user_id = u.user_id
WHERE u.user_id IS NULL;

-- 检查数据完整性
SELECT 
    'users' as table_name,
    COUNT(*) as total_rows,
    COUNT(DISTINCT user_id) as unique_keys,
    COUNT(*) - COUNT(DISTINCT user_id) as duplicates
FROM users
UNION ALL
SELECT 
    'orders' as table_name,
    COUNT(*) as total_rows,
    COUNT(DISTINCT order_id) as unique_keys,
    COUNT(*) - COUNT(DISTINCT order_id) as duplicates
FROM orders;
```

## ETL自动化脚本

### 1. 创建ETL脚本

```bash
#!/bin/bash
# etl_pipeline.sh - ETL自动化脚本

set -e

LOG_FILE="logs/etl_$(date +%Y%m%d_%H%M%S).log"
mkdir -p logs

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# 1. 数据准备阶段
log "开始ETL流程..."

# 2. 数据导入
log "导入用户数据..."
curl --location-trusted -u root: \
    -H "label:users_$(date +%Y%m%d_%H%M%S)" \
    -H "format:csv" \
    -H "column_separator:," \
    -H "skip_header:1" \
    -T sample-data/users.csv \
    http://localhost:8030/api/demo_etl/users/_stream_load

log "导入订单数据..."
curl --location-trusted -u root: \
    -H "label:orders_$(date +%Y%m%d_%H%M%S)" \
    -H "format:csv" \
    -H "column_separator:," \
    -H "skip_header:1" \
    -T sample-data/orders.csv \
    http://localhost:8030/api/demo_etl/orders/_stream_load

# 3. 数据验证
log "验证数据..."
mysql -h localhost -P 9030 -u root -e "
USE demo_etl;
SELECT 'users' as table_name, COUNT(*) as row_count FROM users
UNION ALL
SELECT 'orders' as table_name, COUNT(*) as row_count FROM orders;
" >> $LOG_FILE

# 4. 生成汇总数据
log "生成汇总数据..."
mysql -h localhost -P 9030 -u root -e "
USE demo_etl;
INSERT INTO sales_summary (stat_date, category, total_amount, order_count, avg_price, max_price, min_price, unique_users, update_time)
SELECT 
    order_date,
    category,
    SUM(amount),
    COUNT(*),
    AVG(price),
    MAX(price),
    MIN(price),
    HLL_HASH(user_id),
    NOW()
FROM orders 
WHERE status = 'PAID'
GROUP BY order_date, category
ON DUPLICATE KEY UPDATE
    total_amount = VALUES(total_amount),
    order_count = VALUES(order_count),
    avg_price = VALUES(avg_price),
    max_price = VALUES(max_price),
    min_price = VALUES(min_price),
    unique_users = VALUES(unique_users),
    update_time = VALUES(update_time);
"

log "ETL流程完成"
```

### 2. 创建数据监控脚本

```bash
#!/bin/bash
# monitor_etl.sh - ETL监控脚本

# 检查数据量变化
mysql -h localhost -P 9030 -u root -e "
USE demo_etl;
SELECT 
    table_name,
    table_rows,
    data_length,
    update_time
FROM information_schema.tables 
WHERE table_schema = 'demo_etl'
  AND table_type = 'BASE TABLE';
"

# 检查最近的导入任务
mysql -h localhost -P 9030 -u root -e "
SHOW LOAD ORDER BY CreateTime DESC LIMIT 10;
"
```

## 最佳实践总结

### 1. 数据导入选择
- **小批量实时**: 使用INSERT语句
- **中等批量**: 使用Stream Load
- **大批量离线**: 使用Broker Load
- **实时流数据**: 使用Routine Load

### 2. 性能优化
- 合理设置分区和分桶
- 控制导入批次大小
- 并行导入不同分区
- 监控系统资源使用

### 3. 数据质量
- 导入前进行数据验证
- 设置合理的错误容忍率
- 建立数据一致性检查
- 记录和分析错误日志

### 4. 运维管理
- 自动化ETL流程
- 监控导入性能
- 建立告警机制
- 定期清理历史数据

## 小结

这个第一个ETL任务演示了：

1. **基础导入**: INSERT和Stream Load的使用
2. **数据转换**: 类型转换和数据清洗
3. **批量处理**: 大数据量导入技巧
4. **监控调优**: 性能监控和优化方法
5. **自动化**: ETL流程自动化脚本

通过这个实践，你已经掌握了StarRocks数据导入的基本技能，可以开始处理真实的业务数据了。

---

## 📖 导航

[🏠 返回主页](../../README.md) | [⬅️ 上一页](connect-tools.md) | [➡️ 下一页](../03-table-design/table-models.md)

---