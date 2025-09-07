---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](kettle-setup.md) | [➡️ 下一页](mysql-to-starrocks.md)
---

# Oracle 到 StarRocks 数据迁移

本章节详细介绍如何使用 Kettle/PDI 实现 Oracle 数据库到 StarRocks 的数据迁移，包括数据类型映射、性能优化和常见问题处理。

## 1. 迁移准备工作

### 1.1 环境检查清单

```bash
# Oracle 环境检查
sqlplus user/password@host:port/service_name <<EOF
SELECT * FROM v\$version;
SELECT name, value FROM v\$parameter WHERE name IN ('db_block_size', 'processes');
EXIT;
EOF

# StarRocks 环境检查
mysql -h starrocks_host -P 9030 -u root <<EOF
SHOW VARIABLES LIKE 'version%';
SHOW VARIABLES LIKE 'max_connections';
EXIT;
EOF
```

### 1.2 数据量评估

```sql
-- Oracle 数据量统计
SELECT 
    table_name,
    num_rows,
    avg_row_len,
    ROUND(num_rows * avg_row_len / 1024 / 1024, 2) AS size_mb
FROM user_tables 
WHERE table_name IN ('YOUR_TABLE_LIST')
ORDER BY size_mb DESC;

-- 检查数据分布
SELECT 
    TO_CHAR(create_time, 'YYYY-MM') AS month,
    COUNT(*) AS row_count
FROM your_table 
GROUP BY TO_CHAR(create_time, 'YYYY-MM')
ORDER BY month;
```

## 2. 数据类型映射策略

### 2.1 核心类型映射表

| Oracle 类型 | StarRocks 类型 | 注意事项 | 示例 |
|------------|---------------|----------|------|
| NUMBER(p,s) | DECIMAL(p,s) | 精度范围 1-38 | NUMBER(10,2) → DECIMAL(10,2) |
| NUMBER(p) | BIGINT/INT | p≤9用INT，p>9用BIGINT | NUMBER(18) → BIGINT |
| NUMBER | DECIMAL(27,9) | 默认映射 | NUMBER → DECIMAL(27,9) |
| VARCHAR2(n) | VARCHAR(n) | 最大65533字节 | VARCHAR2(4000) → VARCHAR(4000) |
| CHAR(n) | CHAR(n) | 最大255字节 | CHAR(100) → CHAR(100) |
| CLOB | STRING/TEXT | 大文本处理 | CLOB → STRING |
| BLOB | VARBINARY | 二进制数据 | BLOB → VARBINARY |
| DATE | DATETIME | 时间精度差异 | DATE → DATETIME |
| TIMESTAMP | DATETIME | 时区处理 | TIMESTAMP → DATETIME |

### 2.2 特殊类型处理

```sql
-- Oracle RAW 类型处理
-- 源表结构
CREATE TABLE oracle_table (
    id NUMBER(10),
    raw_data RAW(16),
    created_date DATE
);

-- StarRocks 目标表
CREATE TABLE starrocks_table (
    id BIGINT,
    raw_data VARCHAR(32),  -- RAW转为HEX字符串
    created_date DATETIME
) ENGINE=OLAP
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;
```

### 2.3 数据类型转换 Kettle 配置

在 Kettle 中配置数据类型转换：

```xml
<!-- Select values 步骤配置 -->
<step>
    <name>Data Type Conversion</name>
    <type>SelectValues</type>
    <fields>
        <field>
            <name>oracle_number</name>
            <rename>sr_decimal</rename>
            <type>BigNumber</type>
            <length>10</length>
            <precision>2</precision>
        </field>
        <field>
            <name>oracle_date</name>
            <rename>sr_datetime</rename>
            <type>Date</type>
            <format>yyyy-MM-dd HH:mm:ss</format>
        </field>
    </fields>
</step>
```

## 3. 表设计迁移

### 3.1 表结构转换示例

```sql
-- Oracle 原始表
CREATE TABLE sales_data (
    sale_id NUMBER(10) PRIMARY KEY,
    customer_id NUMBER(10) NOT NULL,
    product_id NUMBER(10) NOT NULL,
    sale_date DATE NOT NULL,
    amount NUMBER(12,2),
    status VARCHAR2(20),
    region_code CHAR(3),
    created_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_time TIMESTAMP
);

-- StarRocks 目标表（优化设计）
CREATE TABLE sales_data (
    sale_id BIGINT NOT NULL,
    customer_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    sale_date DATE NOT NULL,
    amount DECIMAL(12,2),
    status VARCHAR(20),
    region_code CHAR(3),
    created_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_time DATETIME
) ENGINE=OLAP
DUPLICATE KEY(sale_id)
PARTITION BY RANGE(sale_date) (
    PARTITION p202301 VALUES [('2023-01-01'), ('2023-02-01')),
    PARTITION p202302 VALUES [('2023-02-01'), ('2023-03-01')),
    PARTITION p202303 VALUES [('2023-03-01'), ('2023-04-01'))
)
DISTRIBUTED BY HASH(customer_id) BUCKETS 32
PROPERTIES (
    "replication_num" = "3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "MONTH",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "32"
);
```

### 3.2 索引策略迁移

```sql
-- Oracle 索引分析
SELECT 
    i.index_name,
    i.table_name,
    i.uniqueness,
    ic.column_name,
    ic.column_position
FROM user_indexes i
JOIN user_ind_columns ic ON i.index_name = ic.index_name
WHERE i.table_name = 'SALES_DATA'
ORDER BY i.index_name, ic.column_position;

-- StarRocks 对应策略
-- 1. 使用合适的排序键
ALTER TABLE sales_data ORDER BY (sale_date, customer_id, sale_id);

-- 2. 创建 Bitmap 索引（高基数列）
CREATE INDEX idx_customer_id ON sales_data (customer_id) USING BITMAP;

-- 3. 创建 Bloom Filter 索引（等值查询优化）
ALTER TABLE sales_data SET ("bloom_filter_columns" = "customer_id,product_id");
```

## 4. Kettle 转换设计

### 4.1 基础迁移转换流程

```
Table Input (Oracle) 
    ↓
Data Type Conversion
    ↓
Null Value Handling
    ↓
Data Validation
    ↓
Table Output (StarRocks)
```

### 4.2 Table Input 配置

```sql
-- Oracle 查询优化
SELECT /*+ FIRST_ROWS(10000) */
    sale_id,
    customer_id,
    product_id,
    sale_date,
    amount,
    status,
    region_code,
    created_time,
    updated_time
FROM sales_data
WHERE sale_date >= TO_DATE('2023-01-01', 'YYYY-MM-DD')
    AND sale_date < TO_DATE('2023-02-01', 'YYYY-MM-DD')
ORDER BY sale_id;
```

### 4.3 数据清洗和转换

```javascript
// JavaScript 步骤：处理特殊值
if (oracle_number == null || oracle_number.toString() == 'NaN') {
    sr_decimal = null;
} else {
    sr_decimal = oracle_number;
}

// 日期格式转换
if (oracle_date != null) {
    sr_datetime = new Date(oracle_date.getTime());
} else {
    sr_datetime = null;
}

// RAW 数据转换为 HEX
if (oracle_raw != null) {
    sr_hex_string = oracle_raw.toString('hex').toUpperCase();
} else {
    sr_hex_string = null;
}
```

### 4.4 Table Output 配置

```xml
<step>
    <name>StarRocks Output</name>
    <type>TableOutput</type>
    <connection>StarRocks_Connection</connection>
    <schema/>
    <table>sales_data</table>
    <commit_size>10000</commit_size>
    <truncate>false</truncate>
    <ignore_errors>false</ignore_errors>
    <use_batch>true</use_batch>
    <specify_fields>true</specify_fields>
    <partitioning_enabled>false</partitioning_enabled>
    <partitioning_field/>
    <table_name_defined_in_field>false</table_name_defined_in_field>
    <table_name_field/>
    <sql_file_name/>
    <return_keys>false</return_keys>
    <return_field/>
    <fields>
        <field>
            <column_name>sale_id</column_name>
            <stream_name>sale_id</stream_name>
        </field>
        <!-- 其他字段配置 -->
    </fields>
</step>
```

## 5. 性能优化策略

### 5.1 批量提交优化

```xml
<!-- Kettle 批量配置 -->
<commit_size>50000</commit_size>
<use_batch>true</use_batch>

<!-- 并行处理配置 -->
<step_performance_capturing_enabled>Y</step_performance_capturing_enabled>
<step_performance_capturing_size_limit>100</step_performance_capturing_size_limit>
```

### 5.2 内存管理

```bash
# Kettle JVM 参数优化
export PENTAHO_DI_JAVA_OPTIONS="-Xms2g -Xmx8g -XX:+UseG1GC -XX:G1HeapRegionSize=16m"

# StarRocks 写入优化
SET SESSION parallel_fragment_exec_instance_num = 8;
SET SESSION pipeline_dop = 8;
```

### 5.3 分区迁移策略

```sql
-- 按分区迁移数据
-- Step 1: 创建临时表接收数据
CREATE TABLE sales_data_temp LIKE sales_data;

-- Step 2: Kettle 按日期范围迁移
SELECT * FROM sales_data 
WHERE sale_date >= DATE '2023-01-01' 
  AND sale_date < DATE '2023-02-01';

-- Step 3: 数据校验后切换分区
ALTER TABLE sales_data 
REPLACE PARTITION p202301 
WITH TEMPORARY PARTITION tp202301;
```

## 6. 错误处理和监控

### 6.1 常见错误处理

```javascript
// Kettle 错误处理脚本
try {
    // 数据转换逻辑
    if (source_field.length > target_max_length) {
        error_message = "字段长度超限: " + source_field.length;
        writeToLog("e", error_message);
        target_field = source_field.substring(0, target_max_length);
    } else {
        target_field = source_field;
    }
} catch (e) {
    error_message = "数据转换错误: " + e.message;
    writeToLog("e", error_message);
    setVariable("ERROR_COUNT", getVariable("ERROR_COUNT", "0") + 1);
}
```

### 6.2 数据质量检查

```sql
-- 源表记录数
SELECT COUNT(*) as oracle_count FROM oracle_table
WHERE sale_date >= DATE '2023-01-01';

-- 目标表记录数
SELECT COUNT(*) as starrocks_count FROM starrocks_table
WHERE sale_date >= DATE '2023-01-01';

-- 数据一致性检查
SELECT 
    SUM(amount) as total_amount,
    COUNT(DISTINCT customer_id) as unique_customers,
    MAX(sale_date) as max_date,
    MIN(sale_date) as min_date
FROM sales_data
WHERE sale_date >= '2023-01-01';
```

### 6.3 监控脚本

```bash
#!/bin/bash
# migration_monitor.sh

LOG_FILE="/path/to/migration.log"
KETTLE_JOB="/path/to/oracle_to_starrocks.kjb"

# 执行迁移任务
kitchen.sh -file="$KETTLE_JOB" -level=Basic >> "$LOG_FILE" 2>&1

# 检查执行结果
if [ $? -eq 0 ]; then
    echo "$(date): 迁移任务执行成功" >> "$LOG_FILE"
    
    # 数据质量检查
    mysql -h starrocks_host -P 9030 -u root -e "
        SELECT 
            '数据检查' as check_type,
            COUNT(*) as record_count,
            NOW() as check_time
        FROM sales_data 
        WHERE DATE(created_time) = CURDATE();
    " >> "$LOG_FILE"
else
    echo "$(date): 迁移任务执行失败" >> "$LOG_FILE"
    # 发送告警邮件
    mail -s "Oracle到StarRocks迁移失败" admin@company.com < "$LOG_FILE"
fi
```

## 7. 最佳实践总结

### 7.1 迁移前准备
- 完成数据类型映射分析
- 评估数据量和迁移时间
- 准备回滚方案
- 建立监控和告警机制

### 7.2 迁移执行
- 采用增量迁移策略
- 设置合理的批量大小
- 实时监控迁移进度
- 及时处理数据质量问题

### 7.3 迁移后验证
- 数据完整性检查
- 业务逻辑验证
- 性能基准测试
- 用户接受度测试

### 7.4 性能调优建议
- Oracle 查询使用合适的 HINT
- StarRocks 表设计考虑查询模式
- Kettle 参数根据硬件资源调整
- 监控系统资源使用情况

这个迁移指南涵盖了从 Oracle 到 StarRocks 的完整迁移流程，包括数据类型映射、表结构转换、ETL 设计和性能优化等关键环节。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](kettle-setup.md) | [➡️ 下一页](mysql-to-starrocks.md)
---