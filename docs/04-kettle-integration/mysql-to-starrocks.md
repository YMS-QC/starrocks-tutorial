---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](oracle-to-starrocks.md) | [➡️ 下一页](stream-load-integration.md)
---

# MySQL 到 StarRocks 数据迁移

本章节详细介绍如何使用 Kettle/PDI 实现 MySQL 数据库到 StarRocks 的数据迁移，包括数据类型映射、存储引擎差异处理和性能优化策略。

## 1. 迁移准备工作

### 1.1 环境检查清单

```bash
# MySQL 环境检查
mysql -h mysql_host -P 3306 -u user -p <<EOF
SELECT VERSION();
SHOW VARIABLES LIKE 'innodb%';
SHOW VARIABLES LIKE 'max_connections';
SHOW VARIABLES LIKE 'sql_mode';
EXIT;
EOF

# StarRocks 环境检查
mysql -h starrocks_host -P 9030 -u root <<EOF
SHOW VARIABLES LIKE 'version%';
SHOW VARIABLES LIKE 'max_connections';
EXIT;
EOF
```

### 1.2 MySQL 存储引擎分析

```sql
-- 检查表存储引擎
SELECT 
    TABLE_SCHEMA,
    TABLE_NAME,
    ENGINE,
    TABLE_ROWS,
    DATA_LENGTH,
    INDEX_LENGTH,
    ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS size_mb
FROM INFORMATION_SCHEMA.TABLES 
WHERE TABLE_SCHEMA NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
ORDER BY size_mb DESC;

-- 检查字符集和排序规则
SELECT 
    TABLE_SCHEMA,
    TABLE_NAME,
    TABLE_COLLATION,
    CHARACTER_SET_NAME
FROM INFORMATION_SCHEMA.TABLES t
JOIN INFORMATION_SCHEMA.CHARACTER_SETS c 
ON t.TABLE_COLLATION LIKE CONCAT(c.CHARACTER_SET_NAME, '%')
WHERE TABLE_SCHEMA = 'your_database';
```

### 1.3 数据分布分析

```sql
-- 时间分布分析（用于分区设计）
SELECT 
    DATE_FORMAT(created_time, '%Y-%m') AS month,
    COUNT(*) AS row_count,
    MIN(created_time) AS min_time,
    MAX(created_time) AS max_time
FROM your_table 
GROUP BY DATE_FORMAT(created_time, '%Y-%m')
ORDER BY month;

-- 数据倾斜检查
SELECT 
    category_id,
    COUNT(*) AS row_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM your_table), 2) AS percentage
FROM your_table
GROUP BY category_id
ORDER BY row_count DESC
LIMIT 20;
```

## 2. 数据类型映射策略

### 2.1 核心类型映射表

| MySQL 类型 | StarRocks 类型 | 注意事项 | 示例 |
|-----------|---------------|----------|------|
| TINYINT | TINYINT | 范围一致 | TINYINT → TINYINT |
| SMALLINT | SMALLINT | 范围一致 | SMALLINT → SMALLINT |
| MEDIUMINT | INT | MySQL 特有类型 | MEDIUMINT → INT |
| INT | INT | 范围一致 | INT → INT |
| BIGINT | BIGINT | 范围一致 | BIGINT → BIGINT |
| DECIMAL(p,s) | DECIMAL(p,s) | 精度范围 1-38 | DECIMAL(10,2) → DECIMAL(10,2) |
| FLOAT | FLOAT | 精度可能损失 | FLOAT → FLOAT |
| DOUBLE | DOUBLE | 精度一致 | DOUBLE → DOUBLE |
| BIT(n) | BOOLEAN/INT | n=1用BOOLEAN | BIT(1) → BOOLEAN |
| CHAR(n) | CHAR(n) | 最大255字节 | CHAR(100) → CHAR(100) |
| VARCHAR(n) | VARCHAR(n) | 最大65533字节 | VARCHAR(255) → VARCHAR(255) |
| TEXT | STRING | 大文本处理 | TEXT → STRING |
| JSON | JSON | 5.7+版本支持 | JSON → JSON |
| DATETIME | DATETIME | 范围差异 | DATETIME → DATETIME |
| TIMESTAMP | DATETIME | 时区处理 | TIMESTAMP → DATETIME |
| DATE | DATE | 范围一致 | DATE → DATE |
| TIME | TIME | 格式一致 | TIME → TIME |
| YEAR | SMALLINT | 特殊处理 | YEAR → SMALLINT |

### 2.2 特殊类型处理

```sql
-- MySQL 枚举类型处理
-- 源表结构
CREATE TABLE mysql_table (
    id INT PRIMARY KEY AUTO_INCREMENT,
    status ENUM('active', 'inactive', 'pending', 'deleted'),
    priority ENUM('low', 'medium', 'high'),
    created_time DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- StarRocks 目标表
CREATE TABLE starrocks_table (
    id BIGINT NOT NULL,
    status VARCHAR(20),  -- ENUM 转为 VARCHAR
    priority VARCHAR(20), -- ENUM 转为 VARCHAR
    created_time DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;

-- 数据转换规则
ALTER TABLE starrocks_table 
ADD CONSTRAINT status_check 
CHECK (status IN ('active', 'inactive', 'pending', 'deleted'));
```

### 2.3 AUTO_INCREMENT 处理

```sql
-- MySQL AUTO_INCREMENT 分析
SELECT 
    TABLE_SCHEMA,
    TABLE_NAME,
    COLUMN_NAME,
    AUTO_INCREMENT,
    COLUMN_DEFAULT
FROM INFORMATION_SCHEMA.TABLES t
JOIN INFORMATION_SCHEMA.COLUMNS c 
ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
WHERE c.EXTRA = 'auto_increment';

-- StarRocks 替代方案
CREATE TABLE orders (
    order_id BIGINT NOT NULL,  -- 不支持 AUTO_INCREMENT
    customer_id BIGINT NOT NULL,
    order_date DATE NOT NULL,
    total_amount DECIMAL(10,2)
) ENGINE=OLAP
UNIQUE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 32;

-- 使用序列生成器（Kettle 中处理）
-- 或使用 UUID/时间戳组合生成唯一ID
```

## 3. 表结构迁移优化

### 3.1 InnoDB 到 StarRocks 转换

```sql
-- MySQL InnoDB 表
CREATE TABLE user_orders (
    id INT PRIMARY KEY AUTO_INCREMENT,
    user_id INT NOT NULL,
    product_id INT NOT NULL,
    order_date DATETIME NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status ENUM('pending', 'paid', 'shipped', 'delivered', 'cancelled'),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_user_date (user_id, order_date),
    INDEX idx_product (product_id),
    INDEX idx_status (status),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (product_id) REFERENCES products(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- StarRocks 优化表设计
CREATE TABLE user_orders (
    id BIGINT NOT NULL,                    -- 预先生成ID或使用hash
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    order_date DATE NOT NULL,              -- 分区字段
    order_datetime DATETIME NOT NULL,      -- 完整时间信息
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) NOT NULL,           -- ENUM转VARCHAR
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(id)                          -- 允许重复，适合分析
PARTITION BY RANGE(order_date) (
    PARTITION p202301 VALUES [('2023-01-01'), ('2023-02-01')),
    PARTITION p202302 VALUES [('2023-02-01'), ('2023-03-01')),
    PARTITION p202303 VALUES [('2023-03-01'), ('2023-04-01'))
)
DISTRIBUTED BY HASH(user_id) BUCKETS 32   -- 按用户分布
PROPERTIES (
    "replication_num" = "3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "MONTH",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "32"
);

-- 索引策略
CREATE INDEX idx_user_orders_product ON user_orders (product_id) USING BITMAP;
ALTER TABLE user_orders SET ("bloom_filter_columns" = "user_id,product_id");
```

### 3.2 MyISAM 到 StarRocks 转换

```sql
-- MySQL MyISAM 表（通常用于读多写少场景）
CREATE TABLE product_stats (
    product_id INT PRIMARY KEY,
    view_count BIGINT DEFAULT 0,
    sale_count INT DEFAULT 0,
    rating_sum DECIMAL(10,2) DEFAULT 0,
    rating_count INT DEFAULT 0,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FULLTEXT KEY ft_description (description)
) ENGINE=MyISAM;

-- StarRocks 聚合表设计（适合统计场景）
CREATE TABLE product_stats (
    product_id BIGINT NOT NULL,
    view_count BIGINT SUM DEFAULT 0,        -- 聚合函数
    sale_count BIGINT SUM DEFAULT 0,        -- 聚合函数
    rating_sum DECIMAL(15,2) SUM DEFAULT 0, -- 聚合函数
    rating_count BIGINT SUM DEFAULT 0,      -- 聚合函数
    last_updated DATETIME REPLACE           -- 替换函数
) ENGINE=OLAP
AGGREGATE KEY(product_id)                   -- 聚合键
DISTRIBUTED BY HASH(product_id) BUCKETS 16
PROPERTIES (
    "replication_num" = "3"
);
```

## 4. Kettle 转换设计

### 4.1 完整迁移转换流程

```
Table Input (MySQL)
    ↓
Data Type Conversion
    ↓
Auto Increment Processing  -- 处理自增ID
    ↓
Enum Value Mapping         -- 枚举值转换
    ↓
Character Set Conversion   -- 字符集处理
    ↓
Null Value Handling
    ↓
Data Validation
    ↓
Table Output (StarRocks)
```

### 4.2 MySQL Table Input 优化配置

```sql
-- 分页查询优化（避免内存溢出）
SELECT 
    id, user_id, product_id, order_date, amount, status,
    created_at, updated_at
FROM user_orders
WHERE id BETWEEN ${MIN_ID} AND ${MAX_ID}
ORDER BY id;

-- 增量数据查询
SELECT * FROM user_orders
WHERE updated_at >= '${LAST_UPDATE_TIME}'
   OR created_at >= '${LAST_UPDATE_TIME}'
ORDER BY COALESCE(updated_at, created_at);

-- 大表分片查询
SELECT * FROM user_orders
WHERE id % ${TOTAL_SHARDS} = ${CURRENT_SHARD}
ORDER BY id;
```

### 4.3 数据转换处理

```javascript
// JavaScript 步骤：处理 AUTO_INCREMENT
if (mysql_auto_id == null) {
    // 生成新ID（时间戳 + 随机数）
    sr_id = Math.floor(Date.now() / 1000) * 1000000 + Math.floor(Math.random() * 1000000);
} else {
    sr_id = mysql_auto_id;
}

// ENUM 值处理
var statusMapping = {
    'pending': 'pending',
    'paid': 'paid', 
    'shipped': 'shipped',
    'delivered': 'delivered',
    'cancelled': 'cancelled'
};
sr_status = statusMapping[mysql_status] || 'unknown';

// TIMESTAMP 时区处理
if (mysql_timestamp != null) {
    // MySQL TIMESTAMP 转换为 UTC
    var utcTime = new Date(mysql_timestamp.getTime() + (mysql_timestamp.getTimezoneOffset() * 60000));
    sr_datetime = utcTime;
} else {
    sr_datetime = null;
}

// 字符编码处理
if (mysql_varchar != null) {
    // 确保 UTF-8 编码
    sr_varchar = new String(mysql_varchar.getBytes("UTF-8"), "UTF-8");
} else {
    sr_varchar = null;
}
```

### 4.4 批量优化处理

```xml
<!-- MySQL 连接优化 -->
<connection>
    <name>MySQL_Source</name>
    <server>mysql_host</server>
    <type>MYSQL</type>
    <access>Native</access>
    <database>source_db</database>
    <port>3306</port>
    <username>user</username>
    <password>password</password>
    <attributes>
        <attribute><code>EXTRA_OPTION_MYSQL.zeroDateTimeBehavior</code><value>convertToNull</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.useUnicode</code><value>true</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.characterEncoding</code><value>UTF-8</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.useCursorFetch</code><value>true</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.defaultFetchSize</code><value>10000</value></attribute>
    </attributes>
</connection>

<!-- StarRocks 连接优化 -->
<connection>
    <name>StarRocks_Target</name>
    <server>starrocks_host</server>
    <type>MYSQL</type>
    <access>Native</access>
    <database>target_db</database>
    <port>9030</port>
    <username>root</username>
    <password></password>
    <attributes>
        <attribute><code>EXTRA_OPTION_MYSQL.rewriteBatchedStatements</code><value>true</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.useServerPrepStmts</code><value>false</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.cachePrepStmts</code><value>false</value></attribute>
    </attributes>
</connection>
```

## 5. 性能优化策略

### 5.1 MySQL 源端优化

```sql
-- 创建迁移专用索引
CREATE INDEX idx_migration_time ON user_orders(created_at, updated_at);

-- 查询优化配置
SET SESSION read_buffer_size = 2097152;        -- 2MB
SET SESSION read_rnd_buffer_size = 8388608;    -- 8MB
SET SESSION sort_buffer_size = 16777216;       -- 16MB

-- 避免锁表的查询方式
SELECT * FROM user_orders 
WHERE id BETWEEN 1000000 AND 1100000
ORDER BY id;
```

### 5.2 网络传输优化

```bash
# Kettle JVM 优化
export PENTAHO_DI_JAVA_OPTIONS="
-Xms4g -Xmx8g
-XX:+UseG1GC 
-XX:G1HeapRegionSize=16m
-XX:+UnlockExperimentalVMOptions
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
"

# 网络缓冲区优化
export MYSQL_CONNECTOR_OPTIONS="
useCompression=true&
socketTimeout=300000&
connectTimeout=60000&
autoReconnect=true&
maxReconnects=3
"
```

### 5.3 StarRocks 目标端优化

```sql
-- 批量导入优化
SET SESSION parallel_fragment_exec_instance_num = 16;
SET SESSION pipeline_dop = 16;
SET SESSION enable_pipeline_engine = true;

-- 临时关闭一些检查以提升性能
SET SESSION enable_insert_strict = false;
SET SESSION batch_size = 100000;

-- 使用 Stream Load 替代 INSERT（大批量场景）
curl --location-trusted -u root: \
    -H "column_separator:," \
    -H "skip_header:1" \
    -H "timeout:3600" \
    -T data.csv \
    http://starrocks_host:8030/api/target_db/user_orders/_stream_load
```

## 6. 增量同步策略

### 6.1 基于时间戳的增量同步

```sql
-- 创建变更跟踪表
CREATE TABLE sync_status (
    table_name VARCHAR(64) PRIMARY KEY,
    last_sync_time DATETIME,
    sync_status VARCHAR(20),
    record_count BIGINT,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 增量查询逻辑
SELECT * FROM user_orders 
WHERE (updated_at > '${LAST_SYNC_TIME}' OR created_at > '${LAST_SYNC_TIME}')
  AND (updated_at <= NOW() OR created_at <= NOW())
ORDER BY COALESCE(updated_at, created_at);
```

### 6.2 基于 Binlog 的 CDC 方案

```bash
# 启用 MySQL Binlog
# my.cnf 配置
[mysqld]
log-bin=mysql-bin
binlog-format=ROW
server-id=1
binlog-do-db=your_database

# 使用 Canal 或 Maxwell 解析 Binlog
# 再通过 Kettle 转换后写入 StarRocks
```

### 6.3 Kettle 增量作业设计

```xml
<job>
    <name>MySQL_StarRocks_Incremental_Sync</name>
    
    <!-- 步骤1：获取上次同步时间 -->
    <entry>
        <name>Get Last Sync Time</name>
        <type>SQL</type>
        <sql>SELECT COALESCE(MAX(last_sync_time), '1970-01-01') as last_sync_time 
             FROM sync_status WHERE table_name = 'user_orders'</sql>
    </entry>
    
    <!-- 步骤2：执行增量数据转换 -->
    <entry>
        <name>Incremental Data Transform</name>
        <type>TRANS</type>
        <filename>incremental_transform.ktr</filename>
    </entry>
    
    <!-- 步骤3：更新同步状态 -->
    <entry>
        <name>Update Sync Status</name>
        <type>SQL</type>
        <sql>INSERT INTO sync_status (table_name, last_sync_time, sync_status, record_count)
             VALUES ('user_orders', NOW(), 'completed', ${PROCESSED_ROWS})
             ON DUPLICATE KEY UPDATE 
             last_sync_time = NOW(), 
             sync_status = 'completed',
             record_count = ${PROCESSED_ROWS}</sql>
    </entry>
</job>
```

## 7. 数据一致性检查

### 7.1 记录数对比

```sql
-- MySQL 源表统计
SELECT 
    COUNT(*) as mysql_total,
    COUNT(DISTINCT user_id) as unique_users,
    SUM(amount) as total_amount,
    MAX(created_at) as max_created,
    MIN(created_at) as min_created
FROM user_orders
WHERE created_at >= '2023-01-01';

-- StarRocks 目标表统计  
SELECT 
    COUNT(*) as sr_total,
    COUNT(DISTINCT user_id) as unique_users,
    SUM(amount) as total_amount,
    MAX(created_at) as max_created,
    MIN(created_at) as min_created
FROM user_orders
WHERE created_at >= '2023-01-01';
```

### 7.2 数据抽样对比

```sql
-- 随机抽样对比（MySQL）
SELECT * FROM user_orders 
WHERE id IN (
    SELECT id FROM user_orders 
    ORDER BY RAND() 
    LIMIT 1000
) ORDER BY id;

-- 对应记录查询（StarRocks）
SELECT * FROM user_orders 
WHERE id IN (${SAMPLE_IDS})
ORDER BY id;
```

### 7.3 校验脚本

```bash
#!/bin/bash
# data_verification.sh

MYSQL_HOST="mysql_host"
MYSQL_USER="user"
MYSQL_PASS="password"
MYSQL_DB="source_db"

SR_HOST="starrocks_host"
SR_USER="root"
SR_PASS=""
SR_DB="target_db"

# 记录数对比
mysql_count=$(mysql -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASS -D $MYSQL_DB -se "SELECT COUNT(*) FROM user_orders")
sr_count=$(mysql -h $SR_HOST -P 9030 -u $SR_USER -D $SR_DB -se "SELECT COUNT(*) FROM user_orders")

echo "MySQL 记录数: $mysql_count"
echo "StarRocks 记录数: $sr_count"

if [ "$mysql_count" -eq "$sr_count" ]; then
    echo "✓ 记录数一致"
else
    echo "✗ 记录数不一致，差异: $((mysql_count - sr_count))"
    exit 1
fi

# 金额汇总对比
mysql_sum=$(mysql -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASS -D $MYSQL_DB -se "SELECT ROUND(SUM(amount), 2) FROM user_orders")
sr_sum=$(mysql -h $SR_HOST -P 9030 -u $SR_USER -D $SR_DB -se "SELECT ROUND(SUM(amount), 2) FROM user_orders")

echo "MySQL 金额汇总: $mysql_sum"
echo "StarRocks 金额汇总: $sr_sum"

if [ "$mysql_sum" = "$sr_sum" ]; then
    echo "✓ 金额汇总一致"
else
    echo "✗ 金额汇总不一致"
    exit 1
fi

echo "数据一致性检查通过！"
```

## 8. 最佳实践总结

### 8.1 迁移规划要点
- 分析 MySQL 存储引擎特性，制定对应的 StarRocks 表模型
- 合理设计分区和分桶策略，避免数据倾斜
- 预估迁移时间，制定分批次迁移计划
- 准备数据回滚和一致性检查方案

### 8.2 性能优化要点
- MySQL 端避免全表扫描，使用索引覆盖查询
- 网络传输使用压缩，合理设置超时时间
- StarRocks 端批量写入，适当并行度设置
- 监控系统资源，及时调整 JVM 参数

### 8.3 数据质量保证
- 严格的数据类型映射和转换规则
- 完善的错误处理和重试机制
- 多层次的数据一致性检查
- 详细的迁移日志和监控告警

### 8.4 运维管理建议
- 建立标准化的迁移流程和文档
- 设置自动化的监控和告警机制
- 定期进行迁移演练和性能调优
- 保持与业务方的及时沟通和反馈

这个 MySQL 迁移指南重点关注了 MySQL 特有的存储引擎、字符集、自增字段等特性的处理，为从 MySQL 迁移到 StarRocks 提供了完整的解决方案。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](oracle-to-starrocks.md) | [➡️ 下一页](stream-load-integration.md)
---