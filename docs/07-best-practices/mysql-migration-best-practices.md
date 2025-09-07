---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](oracle-migration-best-practices.md) | [➡️ 下一页](../version-comparison.md)
---

# MySQL 迁移最佳实践

MySQL 到 StarRocks 的迁移相对 Oracle 来说复杂度较低，但仍需要注意存储引擎差异、字符集处理、自增字段转换等关键问题。本章节提供完整的 MySQL 迁移最佳实践指南。

## 1. MySQL 迁移特点分析

### 1.1 MySQL vs Oracle 迁移差异

| 对比维度 | MySQL 迁移 | Oracle 迁移 | 复杂度 |
|---------|------------|-------------|--------|
| **数据类型兼容性** | 95% 兼容 | 80% 兼容 | MySQL 更简单 |
| **SQL 语法** | 90% 兼容 | 70% 兼容 | MySQL 更简单 |
| **存储过程** | 较少使用 | 大量使用 | MySQL 更简单 |
| **字符集处理** | 需要注意 | 相对简单 | 相当 |
| **自增字段** | 需要处理 | 序列转换 | Oracle 更复杂 |
| **分区表** | 语法相似 | 差异较大 | MySQL 更简单 |

### 1.2 MySQL 特有挑战

**存储引擎多样性**
```sql
-- 检查MySQL存储引擎分布
SELECT 
    ENGINE,
    COUNT(*) as table_count,
    ROUND(SUM(data_length + index_length)/1024/1024/1024, 2) as total_size_gb
FROM information_schema.tables 
WHERE table_schema NOT IN ('information_schema','mysql','performance_schema','sys')
GROUP BY ENGINE
ORDER BY total_size_gb DESC;

-- 不同存储引擎的特点
-- InnoDB: 事务支持，行锁，外键，适合OLTP
-- MyISAM: 表锁，全文索引，适合读多写少
-- Memory: 内存存储，重启丢失
-- Archive: 压缩存储，只支持INSERT和SELECT
```

**字符集和排序规则**
```sql
-- 检查字符集使用情况
SELECT 
    character_set_name,
    COUNT(*) as table_count
FROM information_schema.tables t
JOIN information_schema.collation_character_set_applicability c
ON t.table_collation = c.collation_name
WHERE t.table_schema NOT IN ('information_schema','mysql','performance_schema','sys')
GROUP BY character_set_name;

-- 检查排序规则
SELECT 
    table_schema,
    table_name,
    table_collation,
    column_name,
    character_set_name,
    collation_name
FROM information_schema.columns
WHERE table_schema = 'your_database'
  AND data_type IN ('varchar', 'char', 'text')
ORDER BY table_name, ordinal_position;
```

**AUTO_INCREMENT 字段分析**
```sql
-- 统计自增字段使用情况
SELECT 
    table_schema,
    table_name,
    column_name,
    data_type,
    auto_increment as current_value
FROM information_schema.columns c
JOIN information_schema.tables t 
ON c.table_schema = t.table_schema AND c.table_name = t.table_name
WHERE c.extra = 'auto_increment'
  AND c.table_schema NOT IN ('information_schema','mysql','performance_schema','sys')
ORDER BY t.auto_increment DESC;
```

## 2. 迁移前评估

### 2.1 数据库规模和复杂度评估

**容量评估脚本**
```bash
#!/bin/bash
# mysql_assessment.sh - MySQL评估脚本

MYSQL_HOST="mysql.company.com"
MYSQL_USER="assessment_user"
MYSQL_PASSWORD="assessment_password"
DATABASE_NAME="your_database"

echo "=== MySQL 数据库评估报告 ==="
echo "评估时间: $(date)"
echo "数据库: $DATABASE_NAME"
echo ""

# 数据库总大小
echo "=== 数据库容量 ==="
mysql -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASSWORD -e "
SELECT 
    table_schema as 'Database',
    ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) as 'Size (GB)',
    COUNT(*) as 'Table Count'
FROM information_schema.tables
WHERE table_schema = '$DATABASE_NAME'
GROUP BY table_schema;
"

# 大表识别
echo ""
echo "=== 大表清单 (>1GB) ==="
mysql -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASSWORD -e "
SELECT 
    table_name as 'Table',
    ROUND((data_length + index_length) / 1024 / 1024 / 1024, 2) as 'Size (GB)',
    table_rows as 'Estimated Rows',
    engine as 'Storage Engine',
    table_collation as 'Collation'
FROM information_schema.tables
WHERE table_schema = '$DATABASE_NAME'
  AND (data_length + index_length) > 1024*1024*1024
ORDER BY (data_length + index_length) DESC;
"

# 数据类型统计
echo ""
echo "=== 数据类型分布 ==="
mysql -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASSWORD -e "
SELECT 
    data_type as 'Data Type',
    COUNT(*) as 'Column Count'
FROM information_schema.columns
WHERE table_schema = '$DATABASE_NAME'
GROUP BY data_type
ORDER BY COUNT(*) DESC;
"

# 索引统计
echo ""
echo "=== 索引统计 ==="
mysql -h $MYSQL_HOST -u $MYSQL_USER -p$MYSQL_PASSWORD -e "
SELECT 
    index_type as 'Index Type',
    COUNT(*) as 'Index Count',
    COUNT(DISTINCT table_name) as 'Table Count'
FROM information_schema.statistics
WHERE table_schema = '$DATABASE_NAME'
GROUP BY index_type
ORDER BY COUNT(*) DESC;
"
```

### 2.2 应用连接分析

**连接模式分析**
```sql
-- 当前连接分析
SELECT 
    user,
    host,
    db,
    command,
    time,
    state,
    info
FROM information_schema.processlist
WHERE user NOT IN ('root', 'system user', 'event_scheduler')
ORDER BY time DESC;

-- 历史连接统计（需要启用performance_schema）
SELECT 
    user,
    host,
    COUNT(*) as connection_count,
    AVG(current_connections) as avg_concurrent_connections
FROM performance_schema.accounts
WHERE user IS NOT NULL
GROUP BY user, host
ORDER BY connection_count DESC;
```

**查询模式分析**
```sql
-- 慢查询分析
SELECT 
    digest_text,
    count_star as exec_count,
    avg_timer_wait / 1000000000 as avg_duration_seconds,
    sum_timer_wait / 1000000000 as total_duration_seconds,
    sum_rows_examined / count_star as avg_rows_examined,
    sum_rows_sent / count_star as avg_rows_sent
FROM performance_schema.events_statements_summary_by_digest
WHERE digest_text IS NOT NULL
  AND count_star > 10
ORDER BY avg_timer_wait DESC
LIMIT 20;

-- JOIN 查询识别
SELECT 
    digest_text,
    count_star,
    avg_timer_wait / 1000000000 as avg_seconds
FROM performance_schema.events_statements_summary_by_digest
WHERE digest_text LIKE '%JOIN%'
  AND count_star > 5
ORDER BY avg_timer_wait DESC;
```

## 3. 迁移工具选择

### 3.1 工具对比分析

**实时同步工具对比**

| 工具 | 优点 | 缺点 | 适用场景 |
|------|------|------|----------|
| **Flink CDC** | 低延迟，支持schema变更 | 配置复杂，资源消耗高 | 大规模实时同步 |
| **Canal + Kafka** | 成熟稳定，生态丰富 | 部署复杂，维护成本高 | 企业级实时同步 |
| **Debezium** | 开源，社区活跃 | 学习成本高 | 微服务架构 |
| **DataX** | 简单易用，性能不错 | 批量同步，延迟高 | 批量数据迁移 |

**批量迁移工具对比**

| 工具 | 性能 | 易用性 | 监控 | 错误处理 | 推荐度 |
|------|------|--------|-------|----------|--------|
| **Kettle/PDI** | ★★★★☆ | ★★★★★ | ★★★★☆ | ★★★★★ | 推荐 |
| **DataX** | ★★★★★ | ★★★★☆ | ★★★☆☆ | ★★★☆☆ | 推荐 |
| **Sqoop** | ★★★☆☆ | ★★★☆☆ | ★★☆☆☆ | ★★☆☆☆ | 不推荐 |
| **自定义脚本** | ★★★☆☆ | ★★☆☆☆ | ★★☆☆☆ | ★★★☆☆ | 小规模可用 |

### 3.2 推荐迁移架构

**实时同步架构（推荐）**
```
MySQL (主库)
    ↓ Binlog
Flink CDC / Canal
    ↓ Kafka (可选)
StarRocks Stream Load
    ↓
StarRocks (目标库)
```

**批量同步架构（稳妥）**
```
MySQL (源库)
    ↓ JDBC
Kettle / DataX
    ↓ Stream Load
StarRocks (目标库)
```

## 4. 数据类型映射和转换

### 4.1 详细数据类型映射表

| MySQL 类型 | StarRocks 类型 | 转换说明 | 注意事项 |
|------------|---------------|----------|----------|
| **整数类型** | | | |
| TINYINT | TINYINT | 直接映射 | 范围一致：-128~127 |
| SMALLINT | SMALLINT | 直接映射 | 范围一致：-32768~32767 |
| MEDIUMINT | INT | 类型提升 | MySQL特有，需要提升 |
| INT | INT | 直接映射 | 范围一致 |
| BIGINT | BIGINT | 直接映射 | 范围一致 |
| **浮点类型** | | | |
| FLOAT | FLOAT | 直接映射 | 精度可能有差异 |
| DOUBLE | DOUBLE | 直接映射 | 精度基本一致 |
| DECIMAL(M,D) | DECIMAL(M,D) | 直接映射 | 注意M的最大值限制 |
| **字符类型** | | | |
| CHAR(N) | CHAR(N) | 直接映射 | 注意字符集处理 |
| VARCHAR(N) | VARCHAR(N) | 直接映射 | 注意长度限制 |
| TEXT | STRING | 类型映射 | 大文本处理 |
| LONGTEXT | STRING | 类型映射 | 超大文本处理 |
| **二进制类型** | | | |
| BINARY(N) | VARBINARY | 类型映射 | 固定长度->可变长度 |
| VARBINARY(N) | VARBINARY | 直接映射 | 长度注意 |
| BLOB | VARBINARY | 类型映射 | 二进制大对象 |
| **时间类型** | | | |
| DATE | DATE | 直接映射 | 范围基本一致 |
| TIME | TIME | 直接映射 | 格式一致 |
| DATETIME | DATETIME | 直接映射 | 注意时区处理 |
| TIMESTAMP | DATETIME | 类型映射 | 时区自动转换 |
| YEAR | SMALLINT | 类型映射 | 特殊处理 |
| **JSON类型** | | | |
| JSON | JSON | 直接映射 | MySQL 5.7+ |
| **特殊类型** | | | |
| ENUM | VARCHAR | 类型映射 | 枚举值转字符串 |
| SET | VARCHAR | 类型映射 | 集合转字符串 |
| BIT | BOOLEAN/INT | 类型选择 | 根据长度决定 |

### 4.2 数据类型转换实现

**Kettle 数据类型转换**
```xml
<!-- Select values 步骤配置 -->
<step>
    <name>MySQL_To_StarRocks_Type_Convert</name>
    <type>SelectValues</type>
    <fields>
        <!-- MEDIUMINT 转 INT -->
        <field>
            <name>mysql_mediumint_field</name>
            <rename>sr_int_field</rename>
            <type>Integer</type>
            <length>11</length>
        </field>
        
        <!-- ENUM 转 VARCHAR -->
        <field>
            <name>mysql_enum_field</name>
            <rename>sr_varchar_field</rename>
            <type>String</type>
            <length>50</length>
        </field>
        
        <!-- TIMESTAMP 转 DATETIME -->
        <field>
            <name>mysql_timestamp_field</name>
            <rename>sr_datetime_field</rename>
            <type>Date</type>
            <format>yyyy-MM-dd HH:mm:ss</format>
        </field>
        
        <!-- YEAR 转 SMALLINT -->
        <field>
            <name>mysql_year_field</name>
            <rename>sr_year_field</rename>
            <type>Integer</type>
            <length>4</length>
        </field>
    </fields>
</step>
```

**JavaScript 自定义转换**
```javascript
// 处理特殊数据类型转换
// ENUM 值映射
var enum_mapping = {
    'active': 'active',
    'inactive': 'inactive', 
    'pending': 'pending',
    'deleted': 'deleted'
};
sr_status = enum_mapping[mysql_status] || mysql_status;

// SET 类型处理（MySQL中的SET类型包含多个值）
if (mysql_set_field) {
    sr_set_field = mysql_set_field.split(',').join('|');  // 改为管道符分隔
} else {
    sr_set_field = null;
}

// BIT 类型处理
if (mysql_bit_field !== null) {
    if (mysql_bit_length == 1) {
        sr_boolean_field = mysql_bit_field == 1;  // 转为 BOOLEAN
    } else {
        sr_int_field = mysql_bit_field;  // 转为 INT
    }
}

// YEAR 类型处理
if (mysql_year_field) {
    if (mysql_year_field >= 70 && mysql_year_field <= 99) {
        sr_year_field = mysql_year_field + 1900;  // 70-99 映射到 1970-1999
    } else if (mysql_year_field >= 0 && mysql_year_field <= 69) {
        sr_year_field = mysql_year_field + 2000;  // 0-69 映射到 2000-2069
    } else {
        sr_year_field = mysql_year_field;  // 4位年份直接使用
    }
}

// 字符集转换处理
if (mysql_utf8_field) {
    try {
        sr_utf8_field = new String(mysql_utf8_field.getBytes("UTF-8"), "UTF-8");
    } catch (e) {
        writeToLog("e", "字符集转换失败: " + e.message);
        sr_utf8_field = mysql_utf8_field;  // 保持原值
    }
}
```

## 5. AUTO_INCREMENT 处理策略

### 5.1 自增字段识别和分析

```sql
-- 分析自增字段的当前值和增长模式
SELECT 
    t.table_name,
    c.column_name,
    t.auto_increment as current_value,
    c.data_type,
    CASE 
        WHEN t.auto_increment > 4294967295 THEN 'BIGINT_REQUIRED'
        WHEN t.auto_increment > 2147483647 THEN 'INT_SUFFICIENT_BUT_CLOSE'
        ELSE 'INT_SUFFICIENT'
    END as size_recommendation,
    -- 估算增长速度
    COALESCE(
        (SELECT (MAX(id) - MIN(id)) / DATEDIFF(NOW(), MIN(created_time))
         FROM information_schema.tables t2 
         WHERE t2.table_name = t.table_name LIMIT 1), 0
    ) as estimated_daily_growth
FROM information_schema.tables t
JOIN information_schema.columns c 
ON t.table_name = c.table_name AND t.table_schema = c.table_schema
WHERE c.extra = 'auto_increment'
  AND t.table_schema = 'your_database'
ORDER BY t.auto_increment DESC;
```

### 5.2 自增字段替代方案

**方案1：保留现有ID值**
```sql
-- StarRocks 目标表设计
CREATE TABLE orders (
    order_id BIGINT NOT NULL,  -- 不使用 AUTO_INCREMENT
    customer_id BIGINT,
    order_date DATE,
    amount DECIMAL(10,2),
    created_time DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(order_id)
PARTITION BY RANGE(order_date) (
    -- 分区配置
)
DISTRIBUTED BY HASH(order_id) BUCKETS 32;

-- 数据迁移时保持原有ID值
INSERT INTO orders 
SELECT 
    order_id,
    customer_id, 
    order_date,
    amount,
    created_time
FROM mysql_source.orders;
```

**方案2：雪花算法生成ID**
```java
// 雪花算法ID生成器
public class SnowflakeIdGenerator {
    private final long twepoch = 1609459200000L; // 2021-01-01 00:00:00
    private final long datacenterIdBits = 5L;
    private final long machineIdBits = 5L;
    private final long sequenceBits = 12L;
    
    private final long maxDatacenterId = -1L ^ (-1L << datacenterIdBits);
    private final long maxMachineId = -1L ^ (-1L << machineIdBits);
    private final long sequenceMask = -1L ^ (-1L << sequenceBits);
    
    private final long machineIdShift = sequenceBits;
    private final long datacenterIdShift = sequenceBits + machineIdBits;
    private final long timestampLeftShift = sequenceBits + machineIdBits + datacenterIdBits;
    
    private long datacenterId;
    private long machineId;
    private long sequence = 0L;
    private long lastTimestamp = -1L;
    
    public SnowflakeIdGenerator(long datacenterId, long machineId) {
        if (datacenterId > maxDatacenterId || datacenterId < 0) {
            throw new IllegalArgumentException("datacenter Id can't be greater than " + maxDatacenterId + " or less than 0");
        }
        if (machineId > maxMachineId || machineId < 0) {
            throw new IllegalArgumentException("machine Id can't be greater than " + maxMachineId + " or less than 0");
        }
        this.datacenterId = datacenterId;
        this.machineId = machineId;
    }
    
    public synchronized long nextId() {
        long timestamp = timeGen();
        
        if (timestamp < lastTimestamp) {
            throw new RuntimeException("Clock moved backwards. Refusing to generate id");
        }
        
        if (lastTimestamp == timestamp) {
            sequence = (sequence + 1) & sequenceMask;
            if (sequence == 0) {
                timestamp = tilNextMillis(lastTimestamp);
            }
        } else {
            sequence = 0L;
        }
        
        lastTimestamp = timestamp;
        
        return ((timestamp - twepoch) << timestampLeftShift) |
               (datacenterId << datacenterIdShift) |
               (machineId << machineIdShift) |
               sequence;
    }
    
    protected long tilNextMillis(long lastTimestamp) {
        long timestamp = timeGen();
        while (timestamp <= lastTimestamp) {
            timestamp = timeGen();
        }
        return timestamp;
    }
    
    protected long timeGen() {
        return System.currentTimeMillis();
    }
}
```

**方案3：UUID方案**
```javascript
// Kettle JavaScript 步骤生成UUID
if (mysql_auto_id == null || mysql_auto_id == 0) {
    // 生成UUID并转换为数字ID
    var uuid = java.util.UUID.randomUUID();
    var uuidString = uuid.toString().replace(/-/g, '');
    // 取UUID的前16位作为BIGINT ID
    sr_id = java.lang.Long.parseUnsignedLong(uuidString.substring(0, 16), 16);
} else {
    sr_id = mysql_auto_id;
}
```

## 6. 存储引擎迁移策略

### 6.1 InnoDB 迁移处理

**InnoDB 特性映射**
```sql
-- MySQL InnoDB 表结构
CREATE TABLE user_orders (
    order_id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    product_id INT NOT NULL,
    order_date DATETIME NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status ENUM('pending','paid','shipped','completed','cancelled') DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    INDEX idx_user_date (user_id, order_date),
    INDEX idx_status_date (status, order_date),
    INDEX idx_amount (amount),
    
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- StarRocks 对应表设计
CREATE TABLE user_orders (
    order_id BIGINT NOT NULL,  -- 不使用自增，应用层生成
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    order_date DATE NOT NULL,   -- 用作分区键
    order_time DATETIME NOT NULL,  -- 完整时间信息
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',  -- ENUM转VARCHAR
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
DUPLICATE KEY(order_id)  -- 允许重复，适合分析场景
PARTITION BY RANGE(order_date) (
    -- 动态分区配置，替代传统索引
    PARTITION p202301 VALUES [('2023-01-01'), ('2023-02-01')),
    PARTITION p202302 VALUES [('2023-02-01'), ('2023-03-01')),
    PARTITION p202303 VALUES [('2023-03-01'), ('2023-04-01'))
)
DISTRIBUTED BY HASH(user_id) BUCKETS 32  -- 根据查询模式选择分布键
ORDER BY (order_date, user_id, order_id)  -- 排序键替代索引
PROPERTIES (
    "replication_num" = "3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "MONTH",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "32"
);

-- 创建索引替代策略
CREATE INDEX idx_user_bitmap ON user_orders (user_id) USING BITMAP;
CREATE INDEX idx_status_bitmap ON user_orders (status) USING BITMAP;
ALTER TABLE user_orders SET ("bloom_filter_columns" = "user_id,product_id");
```

### 6.2 MyISAM 迁移处理

**MyISAM 特性分析和迁移**
```sql
-- MySQL MyISAM 表（通常用于统计和报表）
CREATE TABLE daily_statistics (
    stat_date DATE PRIMARY KEY,
    total_orders INT DEFAULT 0,
    total_revenue DECIMAL(15,2) DEFAULT 0.00,
    total_customers INT DEFAULT 0,
    avg_order_value DECIMAL(8,2) DEFAULT 0.00,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    INDEX idx_revenue (total_revenue),
    FULLTEXT KEY ft_description (description)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

-- StarRocks 聚合表设计（更适合统计场景）
CREATE TABLE daily_statistics (
    stat_date DATE NOT NULL,
    total_orders BIGINT SUM DEFAULT 0,        -- 聚合函数
    total_revenue DECIMAL(15,2) SUM DEFAULT 0.00,  -- 聚合函数
    total_customers BIGINT SUM DEFAULT 0,     -- 去重聚合需要特殊处理
    avg_order_value DECIMAL(8,2) REPLACE,     -- 替换函数
    last_updated DATETIME REPLACE DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
AGGREGATE KEY(stat_date)  -- 聚合键
DISTRIBUTED BY HASH(stat_date) BUCKETS 8
PROPERTIES (
    "replication_num" = "3"
);

-- 全文检索替代方案（如果需要）
-- StarRocks 目前不直接支持全文检索，可以考虑：
-- 1. 使用 Elasticsearch 作为搜索引擎
-- 2. 应用层实现模糊匹配
-- 3. 预处理关键词到单独字段
```

### 6.3 Memory 引擎处理

```sql
-- MySQL Memory 表（临时数据，重启丢失）
CREATE TABLE session_cache (
    session_id VARCHAR(64) PRIMARY KEY,
    user_id INT NOT NULL,
    login_time TIMESTAMP,
    last_activity TIMESTAMP,
    data TEXT
) ENGINE=MEMORY;

-- StarRocks 替代方案1：普通表（数据持久化）
CREATE TABLE session_cache (
    session_id VARCHAR(64) NOT NULL,
    user_id BIGINT NOT NULL,
    login_time DATETIME,
    last_activity DATETIME,
    data STRING
) ENGINE=OLAP
DUPLICATE KEY(session_id)
DISTRIBUTED BY HASH(session_id) BUCKETS 16
PROPERTIES (
    "replication_num" = "1",  -- 临时数据可以只保留1个副本
    "storage_cooldown_time" = "1d"  -- 1天后转冷存储
);

-- 替代方案2：使用 Redis 等内存数据库
-- 对于真正的临时缓存数据，建议使用专门的缓存系统
```

## 7. 字符集和排序规则处理

### 7.1 字符集兼容性检查

```sql
-- 检查MySQL字符集使用情况
SELECT 
    character_set_name,
    default_collate_name,
    description,
    COUNT(*) as table_count
FROM information_schema.character_sets cs
JOIN information_schema.collation_character_set_applicability ccsa
ON cs.character_set_name = ccsa.character_set_name
JOIN information_schema.tables t
ON ccsa.collation_name = t.table_collation
WHERE t.table_schema = 'your_database'
GROUP BY character_set_name, default_collate_name, description
ORDER BY table_count DESC;

-- 检查可能存在问题的字符集
SELECT 
    table_name,
    column_name,
    character_set_name,
    collation_name,
    data_type
FROM information_schema.columns
WHERE table_schema = 'your_database'
  AND character_set_name IN ('latin1', 'gb2312', 'gbk', 'big5')  -- 可能有问题的字符集
ORDER BY table_name, ordinal_position;
```

### 7.2 字符集转换处理

**Kettle 字符集转换配置**
```xml
<!-- MySQL 连接配置 -->
<connection>
    <name>MySQL_Source_UTF8</name>
    <server>mysql_host</server>
    <type>MYSQL</type>
    <access>Native</access>
    <database>source_db</database>
    <port>3306</port>
    <username>user</username>
    <password>password</password>
    <attributes>
        <!-- 关键字符集配置 -->
        <attribute><code>EXTRA_OPTION_MYSQL.characterEncoding</code><value>UTF-8</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.useUnicode</code><value>true</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.connectionCollation</code><value>utf8mb4_unicode_ci</value></attribute>
        
        <!-- 处理零日期 -->
        <attribute><code>EXTRA_OPTION_MYSQL.zeroDateTimeBehavior</code><value>convertToNull</value></attribute>
        
        <!-- 处理SSL -->
        <attribute><code>EXTRA_OPTION_MYSQL.useSSL</code><value>false</value></attribute>
        <attribute><code>EXTRA_OPTION_MYSQL.allowPublicKeyRetrieval</code><value>true</value></attribute>
    </attributes>
</connection>
```

**JavaScript 字符集处理**
```javascript
// 处理特殊字符和编码问题
function cleanString(inputStr) {
    if (inputStr == null || inputStr == undefined) {
        return null;
    }
    
    var str = inputStr.toString();
    
    // 移除控制字符
    str = str.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, '');
    
    // 处理常见的编码问题字符
    str = str.replace(/[""]/g, '"');  // 智能引号
    str = str.replace(/['']/g, "'");  // 智能单引号
    str = str.replace(/…/g, "...");   // 省略号
    str = str.replace(/—/g, "-");     // 长横线
    
    // 确保UTF-8编码
    try {
        str = new java.lang.String(str.getBytes("UTF-8"), "UTF-8");
    } catch (e) {
        writeToLog("w", "字符编码处理警告: " + e.message);
    }
    
    return str;
}

// 应用字符清洗
if (mysql_text_field != null) {
    sr_text_field = cleanString(mysql_text_field);
} else {
    sr_text_field = null;
}
```

## 8. 事务模型差异与业务改造

### ⚠️ 重要架构原则

**MySQL到StarRocks迁移的核心理念：角色分离，各司其职**

- **MySQL**：继续承担OLTP业务，处理事务和实时写入
- **StarRocks**：专注OLAP分析，处理查询和报表

#### 📋 迁移适用性评估

| MySQL应用场景 | StarRocks适用性 | 迁移建议 |
|-------------|----------------|---------|
| **Web应用后台数据库** | ❌ 不适合 | MySQL继续承担OLTP |
| **数据仓库/BI查询** | ✅ 强烈推荐 | 完全迁移到StarRocks |
| **日志分析系统** | ✅ 推荐 | 迁移，性能大幅提升 |
| **电商订单系统** | ❌ 核心业务保留MySQL | 分析查询迁移StarRocks |
| **用户行为分析** | ✅ 强烈推荐 | 完全迁移 |
| **报表生成系统** | ✅ 强烈推荐 | 查询速度显著提升 |

#### 🏗️ MySQL + StarRocks 协同架构

```
推荐的协同架构：
[Web应用] -> [MySQL(主库)] -> [Binlog CDC] -> [StarRocks] -> [BI系统]
              ↓                              ↓
        [OLTP事务处理]                  [OLAP分析查询]
        [用户数据CRUD]                  [报表数据查询]
```

**协同优势**：
- **MySQL**：保持其在OLTP领域的优势
- **StarRocks**：发挥其在OLAP领域的优势
- **CDC同步**：实现数据的实时或准实时同步
- **读写分离**：写入压力在MySQL，查询压力在StarRocks

### 8.1 MySQL vs StarRocks 事务对比

理解两者差异的目的不是为了在StarRocks中实现MySQL式的事务，而是设计更好的架构。

#### 8.1.1 事务特性对比表

| 特性 | MySQL (InnoDB) | StarRocks | 迁移复杂度 |
|------|---------------|-----------|------------|
| **事务类型** | 完整ACID事务 | SQL事务(v3.5+)<br>Stream Load事务(v2.4+) | 高 |
| **隔离级别** | RU/RC/RR/SI | 有限READ COMMITTED | 高 |
| **事务内可见性** | ✅ 支持 | ❌ 不支持 | 高 |
| **跨会话一致性** | ✅ 立即一致 | ❌ 需要SYNC | 中 |
| **自动提交模式** | ✅ 支持 | ✅ 支持 | 低 |
| **显式事务** | ✅ START/COMMIT/ROLLBACK | ✅ BEGIN WORK/COMMIT/ROLLBACK | 低 |
| **死锁检测** | ✅ 自动检测回滚 | ❌ 无冲突检测 | 中 |
| **锁机制** | 行锁/表锁/意向锁 | 无传统锁概念 | 高 |
| **SAVEPOINT** | ✅ 支持嵌套事务 | ❌ 不支持 | 中 |
| **XA事务** | ✅ 支持分布式事务 | ✅ Stream Load 2PC | 低 |

#### 8.1.2 关键差异分析

**1. 事务内数据可见性差异**

```sql
-- MySQL InnoDB 行为（事务内变更立即可见）
START TRANSACTION;
    INSERT INTO user_balance VALUES (1001, 5000.00, NOW());
    
    -- ✅ MySQL中可以立即查询到插入的数据
    SELECT balance FROM user_balance WHERE user_id = 1001;  -- 返回: 5000.00
    
    UPDATE user_balance SET balance = 4500.00 WHERE user_id = 1001;
    
    -- ✅ 可以查询到更新后的数据
    SELECT balance FROM user_balance WHERE user_id = 1001;  -- 返回: 4500.00
COMMIT;

-- StarRocks 行为（事务内变更不可见）
BEGIN WORK;
    INSERT INTO user_balance VALUES (1001, 5000.00, NOW());
    
    -- ❌ StarRocks中读不到刚插入的数据
    SELECT balance FROM user_balance WHERE user_id = 1001;  -- 空结果集
    
    UPDATE user_balance SET balance = 4500.00 WHERE user_id = 1001;
    
    -- ❌ 仍然读不到更新的数据
    SELECT balance FROM user_balance WHERE user_id = 1001;  -- 空结果集
COMMIT WORK;

-- ✅ 事务提交后才可见
SYNC;  -- 确保跨会话一致性
SELECT balance FROM user_balance WHERE user_id = 1001;  -- 返回: 4500.00
```

**2. 隔离级别差异**

```sql
-- MySQL 支持多种隔离级别
SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;  -- MySQL默认
SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- MySQL 可重复读示例
-- Session A
START TRANSACTION;
SELECT balance FROM accounts WHERE account_id = 1;  -- 返回: 1000

-- Session B
START TRANSACTION;
UPDATE accounts SET balance = 1500 WHERE account_id = 1;
COMMIT;

-- Session A (仍在事务中)
SELECT balance FROM accounts WHERE account_id = 1;  -- 仍返回: 1000 (可重复读)
COMMIT;

-- StarRocks 只支持有限的READ COMMITTED
-- 无法设置其他隔离级别，且跨会话数据可见性需要SYNC保证
```

**3. 锁机制差异**

```sql
-- MySQL 行级锁和死锁检测
-- Session A
START TRANSACTION;
UPDATE accounts SET balance = balance - 100 WHERE account_id = 1;  -- 获得行锁

-- Session B（会被阻塞）
START TRANSACTION;
UPDATE accounts SET balance = balance + 50 WHERE account_id = 1;   -- 等待行锁释放

-- 如果发生死锁，MySQL会自动检测并回滚其中一个事务

-- StarRocks 无传统锁机制
-- 并发写入同一行不会阻塞，但可能导致数据不一致
-- 需要应用层实现并发控制
```

#### 8.1.3 业务代码改造指南

**MySQL事务模式重构**

```java
// MySQL 原有事务处理模式
@Service
@Transactional(isolation = Isolation.REPEATABLE_READ)
public class MySQLOrderService {
    
    // MySQL支持复杂的事务内逻辑
    public void processOrderPayment(Long orderId, BigDecimal amount) {
        
        // 1. 查询订单（事务内可见）
        Order order = orderDAO.findById(orderId);
        validateOrder(order);
        
        // 2. 扣减库存（加锁防止超卖）
        inventoryDAO.decreaseStock(order.getProductId(), order.getQuantity());
        
        // 3. 检查库存（事务内立即可见）
        Integer remainingStock = inventoryDAO.getStock(order.getProductId());
        if (remainingStock < 0) {
            throw new InsufficientStockException("库存不足");
        }
        
        // 4. 扣减账户余额（加锁防止并发）
        accountDAO.decreaseBalance(order.getCustomerId(), amount);
        
        // 5. 检查余额（事务内立即可见）
        BigDecimal remainingBalance = accountDAO.getBalance(order.getCustomerId());
        if (remainingBalance.compareTo(BigDecimal.ZERO) < 0) {
            throw new InsufficientBalanceException("余额不足");
        }
        
        // 6. 更新订单状态
        orderDAO.updateStatus(orderId, OrderStatus.PAID);
        
        // 7. 创建支付记录（依赖事务内数据）
        Payment payment = new Payment(orderId, amount, PaymentStatus.SUCCESS);
        paymentDAO.create(payment);
        
        // MySQL 事务自动保证一致性
    }
}

// StarRocks 适配的事务处理模式
@Service
public class StarRocksOrderService {
    
    @Autowired private DistributedLockService lockService;
    @Autowired private JdbcTemplate jdbcTemplate;
    
    public void processOrderPayment(Long orderId, BigDecimal amount) {
        
        // 1. 预检查阶段（事务外获取数据）
        Order order = orderDAO.findById(orderId);
        validateOrder(order);
        
        Integer currentStock = inventoryDAO.getStock(order.getProductId());
        BigDecimal currentBalance = accountDAO.getBalance(order.getCustomerId());
        
        // 2. 业务逻辑验证
        if (currentStock < order.getQuantity()) {
            throw new InsufficientStockException("库存不足");
        }
        
        if (currentBalance.compareTo(amount) < 0) {
            throw new InsufficientBalanceException("余额不足");
        }
        
        // 3. 分布式锁防止并发冲突
        String lockKey = "order_payment_" + orderId;
        if (!lockService.tryLock(lockKey, 30, TimeUnit.SECONDS)) {
            throw new OrderProcessingException("订单处理中，请稍后重试");
        }
        
        try {
            // 4. 分阶段事务执行
            processInventoryTransaction(order);
            processAccountTransaction(order.getCustomerId(), amount);
            processOrderTransaction(orderId, amount);
            
            // 5. 数据一致性验证
            verifyOrderProcessingResult(orderId);
            
        } finally {
            lockService.unlock(lockKey);
        }
    }
    
    @Transactional
    private void processInventoryTransaction(Order order) {
        // 单一事务：扣减库存
        inventoryDAO.decreaseStock(order.getProductId(), order.getQuantity());
    }
    
    @Transactional
    private void processAccountTransaction(Long customerId, BigDecimal amount) {
        // 单一事务：扣减余额
        accountDAO.decreaseBalance(customerId, amount);
    }
    
    @Transactional
    private void processOrderTransaction(Long orderId, BigDecimal amount) {
        // 单一事务：更新订单和创建支付记录
        orderDAO.updateStatus(orderId, OrderStatus.PAID);
        
        Payment payment = new Payment(orderId, amount, PaymentStatus.SUCCESS);
        paymentDAO.create(payment);
    }
    
    private void verifyOrderProcessingResult(Long orderId) {
        // 使用SYNC确保数据一致性
        jdbcTemplate.execute("SYNC");
        
        // 验证处理结果
        Order processedOrder = orderDAO.findById(orderId);
        if (!OrderStatus.PAID.equals(processedOrder.getStatus())) {
            // 触发补偿逻辑
            handleOrderProcessingFailure(orderId);
        }
    }
}
```

**读取模式重构**

```java
// MySQL 事务内读取模式
@Transactional
public OrderSummary generateOrderSummary(Long customerId) {
    
    // MySQL 支持事务内复杂读取逻辑
    Customer customer = customerDAO.findById(customerId);
    
    // 动态更新客户积分
    customerDAO.updatePoints(customerId, calculateNewPoints(customer));
    
    // 立即读取更新后的积分（事务内可见）
    Customer updatedCustomer = customerDAO.findById(customerId);
    
    // 基于更新后的数据生成报告
    List<Order> orders = orderDAO.findByCustomerId(customerId);
    
    return new OrderSummary(updatedCustomer, orders);
}

// StarRocks 适配的读取模式
public OrderSummary generateOrderSummary(Long customerId) {
    
    // 1. 预先读取基础数据
    Customer customer = customerDAO.findById(customerId);
    List<Order> orders = orderDAO.findByCustomerId(customerId);
    
    // 2. 计算新积分（业务逻辑）
    Integer newPoints = calculateNewPoints(customer);
    
    // 3. 更新积分（独立事务）
    updateCustomerPoints(customerId, newPoints);
    
    // 4. 等待数据同步后重新读取
    waitForDataConsistency();
    Customer updatedCustomer = customerDAO.findById(customerId);
    
    // 5. 基于最终数据生成报告
    return new OrderSummary(updatedCustomer, orders);
}

@Transactional
private void updateCustomerPoints(Long customerId, Integer points) {
    customerDAO.updatePoints(customerId, points);
}

private void waitForDataConsistency() {
    jdbcTemplate.execute("SYNC");
    
    // 可选：添加重试机制
    int maxRetries = 5;
    int retryCount = 0;
    
    while (retryCount < maxRetries) {
        try {
            Thread.sleep(100);  // 短暂等待
            break;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            break;
        }
    }
}
```

#### 8.1.4 分布式锁实现

```java
// 基于Redis的分布式锁实现
@Component
public class RedisDistributedLockService {
    
    @Autowired private StringRedisTemplate redisTemplate;
    
    public boolean tryLock(String lockKey, long timeout, TimeUnit timeUnit) {
        String lockValue = UUID.randomUUID().toString();
        long expireTime = timeUnit.toMillis(timeout);
        
        Boolean result = redisTemplate.opsForValue()
            .setIfAbsent("lock:" + lockKey, lockValue, expireTime, TimeUnit.MILLISECONDS);
            
        return Boolean.TRUE.equals(result);
    }
    
    public void unlock(String lockKey) {
        String script = "if redis.call('get', KEYS[1]) == ARGV[1] then " +
                       "return redis.call('del', KEYS[1]) else return 0 end";
        
        redisTemplate.execute(new DefaultRedisScript<>(script, Long.class),
                            Arrays.asList("lock:" + lockKey), 
                            UUID.randomUUID().toString());
    }
}

// 基于数据库的分布式锁实现
@Component
public class DatabaseDistributedLockService {
    
    @Autowired private JdbcTemplate jdbcTemplate;
    
    public boolean tryLock(String lockKey, long timeout, TimeUnit timeUnit) {
        try {
            String sql = """
                INSERT INTO distributed_locks (lock_key, holder, expire_time) 
                VALUES (?, ?, ?)
                ON DUPLICATE KEY UPDATE
                    holder = CASE 
                        WHEN expire_time < NOW() THEN VALUES(holder)
                        ELSE holder 
                    END,
                    expire_time = CASE
                        WHEN expire_time < NOW() THEN VALUES(expire_time)
                        ELSE expire_time
                    END
                """;
            
            String holder = Thread.currentThread().getName() + "_" + System.currentTimeMillis();
            Timestamp expireTime = new Timestamp(System.currentTimeMillis() + timeUnit.toMillis(timeout));
            
            int affectedRows = jdbcTemplate.update(sql, lockKey, holder, expireTime);
            
            // 验证是否获得锁
            String currentHolder = jdbcTemplate.queryForObject(
                "SELECT holder FROM distributed_locks WHERE lock_key = ? AND expire_time > NOW()",
                String.class, lockKey
            );
            
            return holder.equals(currentHolder);
            
        } catch (Exception e) {
            return false;
        }
    }
    
    public void unlock(String lockKey) {
        jdbcTemplate.update(
            "DELETE FROM distributed_locks WHERE lock_key = ? AND expire_time > NOW()",
            lockKey
        );
    }
}
```

#### 8.1.5 数据一致性保证策略

```java
@Component
public class StarRocksConsistencyManager {
    
    @Autowired private JdbcTemplate jdbcTemplate;
    
    // 强制数据同步
    public void forceSync() {
        jdbcTemplate.execute("SYNC");
    }
    
    // 等待特定数据变更可见
    public boolean waitForDataChange(String table, String condition, int maxWaitSeconds) {
        int waitCount = 0;
        int maxWaitCount = maxWaitSeconds * 10; // 每100ms检查一次
        
        while (waitCount < maxWaitCount) {
            forceSync();
            
            Integer count = jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM " + table + " WHERE " + condition,
                Integer.class
            );
            
            if (count != null && count > 0) {
                return true;
            }
            
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
            
            waitCount++;
        }
        
        return false;
    }
    
    // 验证关键业务数据一致性
    public ConsistencyCheckResult checkBusinessConsistency(Long orderId) {
        forceSync();
        
        // 检查订单、支付、库存数据的一致性
        Map<String, Object> orderData = jdbcTemplate.queryForMap(
            "SELECT * FROM orders WHERE order_id = ?", orderId
        );
        
        List<Map<String, Object>> payments = jdbcTemplate.queryForList(
            "SELECT * FROM payments WHERE order_id = ?", orderId
        );
        
        Map<String, Object> inventory = jdbcTemplate.queryForMap(
            "SELECT * FROM inventory WHERE product_id = ?", 
            orderData.get("product_id")
        );
        
        return validateDataConsistency(orderData, payments, inventory);
    }
    
    private ConsistencyCheckResult validateDataConsistency(
            Map<String, Object> order,
            List<Map<String, Object>> payments,
            Map<String, Object> inventory) {
        
        ConsistencyCheckResult result = new ConsistencyCheckResult();
        
        // 检查订单状态与支付记录是否一致
        String orderStatus = (String) order.get("status");
        boolean hasSuccessfulPayment = payments.stream()
            .anyMatch(p -> "SUCCESS".equals(p.get("status")));
        
        if ("PAID".equals(orderStatus) && !hasSuccessfulPayment) {
            result.addError("订单状态为PAID但无成功支付记录");
        }
        
        // 检查库存扣减是否正确
        Integer orderedQuantity = (Integer) order.get("quantity");
        Integer currentStock = (Integer) inventory.get("stock_quantity");
        
        // 这里需要业务逻辑来验证库存扣减的正确性
        // 具体实现取决于业务规则
        
        return result;
    }
}
```

## 9. 性能优化迁移

### 9.1 MySQL 索引策略迁移

**MySQL 复合索引分析**
```sql
-- 分析MySQL复合索引
SELECT 
    table_name,
    index_name,
    GROUP_CONCAT(column_name ORDER BY seq_in_index) as index_columns,
    index_type,
    cardinality
FROM information_schema.statistics
WHERE table_schema = 'your_database'
  AND index_name != 'PRIMARY'
GROUP BY table_name, index_name, index_type, cardinality
ORDER BY table_name, cardinality DESC;

-- 分析索引使用情况（MySQL 5.7+）
SELECT 
    object_schema,
    object_name,
    index_name,
    count_read,
    count_write,
    count_fetch,
    count_insert,
    count_update,
    count_delete
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE object_schema = 'your_database'
  AND count_read > 0
ORDER BY count_read DESC;
```

**StarRocks 索引策略**
```sql
-- 将MySQL复合索引转换为StarRocks排序键
-- MySQL: KEY idx_user_date_status (user_id, order_date, status)
-- StarRocks: ORDER BY (user_id, order_date, status)

CREATE TABLE orders_optimized (
    order_id BIGINT,
    user_id BIGINT,
    order_date DATE,
    status VARCHAR(20),
    amount DECIMAL(10,2)
) ENGINE=OLAP
DUPLICATE KEY(order_id)
PARTITION BY RANGE(order_date) (...)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
ORDER BY (user_id, order_date, status);  -- 对应MySQL复合索引

-- 针对不同查询模式创建Bitmap索引
CREATE INDEX idx_status_bitmap ON orders_optimized (status) USING BITMAP;
CREATE INDEX idx_amount_range ON orders_optimized (amount) USING BITMAP;

-- 使用Bloom Filter优化等值查询
ALTER TABLE orders_optimized SET ("bloom_filter_columns" = "user_id,order_id");
```

### 8.2 查询模式优化

**MySQL 分页查询优化迁移**
```sql
-- MySQL 深度分页优化
-- 原始慢查询
SELECT * FROM orders 
WHERE user_id = 12345 
ORDER BY order_date DESC 
LIMIT 50000, 20;  -- 深度分页，性能差

-- MySQL 优化方案
SELECT o.* FROM orders o
JOIN (
    SELECT order_id FROM orders 
    WHERE user_id = 12345 
    ORDER BY order_date DESC 
    LIMIT 50000, 20
) t ON o.order_id = t.order_id
ORDER BY o.order_date DESC;

-- StarRocks 优化方案
-- 方案1：使用窗口函数
SELECT * FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY order_date DESC) as rn
    FROM orders
    WHERE user_id = 12345
) t 
WHERE rn BETWEEN 50001 AND 50020;

-- 方案2：游标分页（推荐）
SELECT * FROM orders
WHERE user_id = 12345
  AND order_date <= '2023-06-15 10:30:00'  -- 使用上一页最后记录的时间作为游标
ORDER BY order_date DESC, order_id DESC
LIMIT 20;
```

**复杂聚合查询优化**
```sql
-- MySQL 复杂统计查询
SELECT 
    DATE_FORMAT(order_date, '%Y-%m') as month,
    user_level,
    COUNT(*) as order_count,
    SUM(amount) as total_amount,
    AVG(amount) as avg_amount,
    COUNT(DISTINCT user_id) as unique_users
FROM orders o
JOIN users u ON o.user_id = u.user_id
WHERE o.order_date >= '2023-01-01'
GROUP BY DATE_FORMAT(order_date, '%Y-%m'), user_level
ORDER BY month, user_level;

-- StarRocks 物化视图优化
CREATE MATERIALIZED VIEW monthly_user_stats AS
SELECT 
    DATE_TRUNC('month', order_date) as stat_month,
    user_level,
    COUNT(*) as order_count,
    SUM(amount) as total_amount,
    AVG(amount) as avg_amount,
    COUNT(DISTINCT user_id) as unique_users
FROM orders o
JOIN users u ON o.user_id = u.user_id
GROUP BY DATE_TRUNC('month', order_date), user_level;

-- 查询自动使用物化视图
SELECT 
    DATE_FORMAT(stat_month, '%Y-%m') as month,
    user_level,
    order_count,
    total_amount,
    avg_amount,
    unique_users
FROM monthly_user_stats
WHERE stat_month >= '2023-01-01'
ORDER BY stat_month, user_level;
```

## 9. 数据一致性验证

### 9.1 自动化验证脚本

```python
#!/usr/bin/env python3
# mysql_starrocks_validator.py - 数据一致性验证

import pymysql
import json
import hashlib
from datetime import datetime, timedelta
import logging

class MySQLStarRocksValidator:
    def __init__(self, mysql_config, starrocks_config):
        self.mysql_conn = pymysql.connect(**mysql_config)
        self.sr_conn = pymysql.connect(**starrocks_config)
        self.logger = self._setup_logger()
    
    def _setup_logger(self):
        logger = logging.getLogger('validator')
        handler = logging.FileHandler('validation.log')
        formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
        handler.setFormatter(formatter)
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        return logger
    
    def validate_record_count(self, table_name, date_column=None, date_range=None):
        """验证记录数一致性"""
        where_clause = ""
        if date_column and date_range:
            where_clause = f"WHERE {date_column} >= '{date_range[0]}' AND {date_column} < '{date_range[1]}'"
        
        # MySQL 记录数
        mysql_cursor = self.mysql_conn.cursor()
        mysql_cursor.execute(f"SELECT COUNT(*) FROM {table_name} {where_clause}")
        mysql_count = mysql_cursor.fetchone()[0]
        
        # StarRocks 记录数
        sr_cursor = self.sr_conn.cursor()
        sr_cursor.execute(f"SELECT COUNT(*) FROM {table_name} {where_clause}")
        sr_count = sr_cursor.fetchone()[0]
        
        result = {
            'table': table_name,
            'mysql_count': mysql_count,
            'starrocks_count': sr_count,
            'diff': mysql_count - sr_count,
            'match': mysql_count == sr_count
        }
        
        if result['match']:
            self.logger.info(f"✓ {table_name} 记录数一致: {mysql_count}")
        else:
            self.logger.error(f"✗ {table_name} 记录数不一致: MySQL={mysql_count}, StarRocks={sr_count}, 差异={result['diff']}")
        
        return result
    
    def validate_sum_checksum(self, table_name, numeric_columns, date_column=None, date_range=None):
        """验证数值字段求和一致性"""
        where_clause = ""
        if date_column and date_range:
            where_clause = f"WHERE {date_column} >= '{date_range[0]}' AND {date_column} < '{date_range[1]}'"
        
        results = {}
        
        for column in numeric_columns:
            # MySQL 求和
            mysql_cursor = self.mysql_conn.cursor()
            mysql_cursor.execute(f"SELECT COALESCE(SUM({column}), 0) FROM {table_name} {where_clause}")
            mysql_sum = float(mysql_cursor.fetchone()[0])
            
            # StarRocks 求和
            sr_cursor = self.sr_conn.cursor()
            sr_cursor.execute(f"SELECT IFNULL(SUM({column}), 0) FROM {table_name} {where_clause}")
            sr_sum = float(sr_cursor.fetchone()[0])
            
            diff = abs(mysql_sum - sr_sum)
            tolerance = max(0.01, mysql_sum * 0.0001)  # 0.01% 容差
            
            results[column] = {
                'mysql_sum': mysql_sum,
                'starrocks_sum': sr_sum,
                'diff': diff,
                'match': diff <= tolerance
            }
            
            if results[column]['match']:
                self.logger.info(f"✓ {table_name}.{column} 求和一致: {mysql_sum:.2f}")
            else:
                self.logger.error(f"✗ {table_name}.{column} 求和不一致: MySQL={mysql_sum:.2f}, StarRocks={sr_sum:.2f}, 差异={diff:.2f}")
        
        return results
    
    def validate_sample_records(self, table_name, sample_size=1000, primary_key='id'):
        """抽样验证记录内容一致性"""
        # 随机抽样
        mysql_cursor = self.mysql_conn.cursor()
        mysql_cursor.execute(f"""
            SELECT * FROM {table_name} 
            ORDER BY RAND() 
            LIMIT {sample_size}
        """)
        mysql_records = mysql_cursor.fetchall()
        mysql_columns = [desc[0] for desc in mysql_cursor.description]
        
        # 构建主键条件
        pk_values = [str(record[mysql_columns.index(primary_key)]) for record in mysql_records]
        pk_condition = f"{primary_key} IN ({','.join(pk_values)})"
        
        # StarRocks 对应记录
        sr_cursor = self.sr_conn.cursor()
        sr_cursor.execute(f"SELECT * FROM {table_name} WHERE {pk_condition} ORDER BY {primary_key}")
        sr_records = sr_cursor.fetchall()
        sr_columns = [desc[0] for desc in sr_cursor.description]
        
        # 对比记录
        mysql_dict = {record[mysql_columns.index(primary_key)]: record for record in mysql_records}
        sr_dict = {record[sr_columns.index(primary_key)]: record for record in sr_records}
        
        mismatched_records = []
        for pk in mysql_dict:
            if pk not in sr_dict:
                mismatched_records.append(f"Missing in StarRocks: {pk}")
            else:
                # 简单的记录哈希对比
                mysql_hash = hashlib.md5(str(mysql_dict[pk]).encode()).hexdigest()
                sr_hash = hashlib.md5(str(sr_dict[pk]).encode()).hexdigest()
                if mysql_hash != sr_hash:
                    mismatched_records.append(f"Content mismatch: {pk}")
        
        result = {
            'table': table_name,
            'sample_size': len(mysql_records),
            'found_in_starrocks': len(sr_records),
            'mismatched_count': len(mismatched_records),
            'mismatched_records': mismatched_records[:10],  # 只记录前10个
            'match_rate': (sample_size - len(mismatched_records)) / sample_size if sample_size > 0 else 0
        }
        
        if result['match_rate'] >= 0.99:  # 99% 匹配率认为正常
            self.logger.info(f"✓ {table_name} 抽样验证通过: 匹配率 {result['match_rate']:.2%}")
        else:
            self.logger.error(f"✗ {table_name} 抽样验证失败: 匹配率 {result['match_rate']:.2%}")
        
        return result
    
    def run_full_validation(self, tables_config):
        """执行完整验证"""
        validation_report = {
            'validation_time': datetime.now().isoformat(),
            'results': {}
        }
        
        for table_config in tables_config:
            table_name = table_config['name']
            self.logger.info(f"开始验证表: {table_name}")
            
            table_results = {}
            
            # 记录数验证
            table_results['count'] = self.validate_record_count(
                table_name, 
                table_config.get('date_column'),
                table_config.get('date_range')
            )
            
            # 数值求和验证
            if table_config.get('numeric_columns'):
                table_results['sum'] = self.validate_sum_checksum(
                    table_name,
                    table_config['numeric_columns'],
                    table_config.get('date_column'),
                    table_config.get('date_range')
                )
            
            # 抽样验证
            if table_config.get('primary_key'):
                table_results['sample'] = self.validate_sample_records(
                    table_name,
                    table_config.get('sample_size', 1000),
                    table_config['primary_key']
                )
            
            validation_report['results'][table_name] = table_results
        
        return validation_report

# 使用示例
if __name__ == "__main__":
    mysql_config = {
        'host': 'mysql.company.com',
        'port': 3306,
        'user': 'validator',
        'password': 'password',
        'database': 'warehouse',
        'charset': 'utf8mb4'
    }
    
    starrocks_config = {
        'host': 'starrocks.company.com',
        'port': 9030,
        'user': 'root',
        'password': '',
        'database': 'warehouse',
        'charset': 'utf8mb4'
    }
    
    tables_config = [
        {
            'name': 'orders',
            'primary_key': 'order_id',
            'numeric_columns': ['amount'],
            'date_column': 'order_date',
            'date_range': ['2023-01-01', '2023-12-31'],
            'sample_size': 5000
        },
        {
            'name': 'customers',
            'primary_key': 'customer_id',
            'numeric_columns': ['credit_limit'],
            'sample_size': 2000
        }
    ]
    
    validator = MySQLStarRocksValidator(mysql_config, starrocks_config)
    report = validator.run_full_validation(tables_config)
    
    # 输出报告
    with open('validation_report.json', 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2, ensure_ascii=False)
    
    print("验证完成，详细报告已保存到 validation_report.json")
```

## 10. 最佳实践总结

### 10.1 迁移成功关键因素

**技术层面**
- **工具选择**：根据数据量和实时性要求选择合适工具
- **类型映射**：制定完整的数据类型映射表和转换规则
- **性能优化**：合理设计分区分桶和索引策略
- **监控验证**：建立完善的数据一致性验证机制

**流程层面**
- **分阶段实施**：小表→大表，非核心→核心业务
- **并行验证**：充分的并行运行和验证期
- **回滚预案**：完善的数据回滚和故障恢复机制
- **团队协作**：DBA、开发、运维团队紧密配合

### 10.2 避免常见陷阱

**数据类型陷阱**
- ❌ 忽视 ENUM 和 SET 类型的处理
- ❌ AUTO_INCREMENT 字段处理不当
- ❌ 字符集转换问题
- ❌ 时间类型精度损失

**性能期望陷阱**
- ❌ 直接迁移 MySQL 索引策略
- ❌ 忽视 StarRocks 列存储特性
- ❌ 分区设计不合理
- ❌ 过度依赖单一优化手段

**运维管理陷阱**
- ❌ 缺乏完善的监控体系
- ❌ 数据一致性验证不充分
- ❌ 故障处理预案不足
- ❌ 团队技能准备不到位

### 10.3 性能优化建议

**查询优化**
```sql
-- 利用 StarRocks 特性重写查询
-- MySQL 风格 → StarRocks 优化风格

-- 时间范围查询优化
-- 利用分区裁剪
SELECT * FROM orders 
WHERE order_date >= '2023-01-01' 
  AND order_date < '2023-02-01';  -- 精确匹配分区范围

-- 聚合查询优化
-- 利用物化视图
CREATE MATERIALIZED VIEW daily_summary AS
SELECT 
    order_date,
    COUNT(*) as order_count,
    SUM(amount) as total_amount
FROM orders 
GROUP BY order_date;

-- 查询自动使用物化视图
SELECT order_date, order_count, total_amount 
FROM daily_summary 
WHERE order_date >= '2023-01-01';
```

**存储优化**
```sql
-- 合理设计表结构
CREATE TABLE orders_optimized (
    -- 选择合适的分布键
    order_id BIGINT,
    customer_id BIGINT,  -- 高基数，均匀分布
    order_date DATE,     -- 分区键
    amount DECIMAL(10,2)
) ENGINE=OLAP
DUPLICATE KEY(order_id)
PARTITION BY RANGE(order_date) ()  -- 动态分区
DISTRIBUTED BY HASH(customer_id) BUCKETS 32  -- 合理桶数
ORDER BY (order_date, customer_id, order_id)  -- 查询友好的排序
PROPERTIES (
    "replication_num" = "3",
    "compression" = "LZ4"  -- 压缩算法选择
);
```

MySQL 到 StarRocks 的迁移虽然相对简单，但仍需要细致的规划和执行。通过遵循最佳实践，可以确保迁移的成功和系统的高性能运行。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](oracle-migration-best-practices.md) | [➡️ 下一页](../version-comparison.md)
---