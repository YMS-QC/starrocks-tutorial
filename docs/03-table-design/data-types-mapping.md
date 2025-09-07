---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](bucket-design.md) | [➡️ 下一页](../04-kettle-integration/kettle-setup.md)
---

# 数据类型映射与字段设计规范

## 学习目标

- 掌握StarRocks支持的数据类型及其限制
- 理解Oracle/MySQL到StarRocks的类型映射
- 了解不同版本的字段长度边界差异
- 学会根据业务场景选择合适的数据类型

## StarRocks数据类型概览

### 数值类型

| 类型 | 字节数 | 范围 | 适用场景 | 版本支持 |
|------|--------|------|---------|----------|
| **BOOLEAN** | 1 | true/false | 布尔标识 | v1.0+ |
| **TINYINT** | 1 | -128 ~ 127 | 小整数、状态码 | v1.0+ |
| **SMALLINT** | 2 | -32,768 ~ 32,767 | 中等整数 | v1.0+ |
| **INT** | 4 | -2^31 ~ 2^31-1 | 常规整数 | v1.0+ |
| **BIGINT** | 8 | -2^63 ~ 2^63-1 | 大整数、ID | v1.0+ |
| **LARGEINT** | 16 | -2^127 ~ 2^127-1 | 超大整数 | v1.0+ |
| **FLOAT** | 4 | -3.4E+38 ~ 3.4E+38 | 单精度浮点 | v1.0+ |
| **DOUBLE** | 8 | -1.7E+308 ~ 1.7E+308 | 双精度浮点 | v1.0+ |
| **DECIMAL(P,S)** | 变长 | P:1-38, S:0-P | 精确小数 | v1.0+ |
| **DECIMAL32(P,S)** | 4 | P:1-9 | 高性能小数 | v3.0+ |
| **DECIMAL64(P,S)** | 8 | P:1-18 | 高性能小数 | v3.0+ |
| **DECIMAL128(P,S)** | 16 | P:1-38 | 高性能小数 | v3.0+ |

### 字符串类型

| 类型 | 最大长度 | 存储方式 | 适用场景 | 版本限制 |
|------|---------|---------|---------|----------|
| **CHAR(n)** | 1-255 (v2.x)<br>1-1024 (v3.0+) | 定长 | 固定长度字符 | 见下表 |
| **VARCHAR(n)** | 1-65533 (v2.x)<br>1-1048576 (v3.0+) | 变长 | 可变长度字符 | 见下表 |
| **STRING** | 1048576 (v2.x)<br>2147483643 (v3.0+) | 变长 | 大文本 | 见下表 |
| **BINARY** | 1048576 (v2.5+) | 二进制 | 二进制数据 | v2.5+ |
| **VARBINARY** | 1048576 (v2.5+) | 二进制 | 可变二进制 | v2.5+ |

### 时间类型

| 类型 | 格式 | 范围 | 精度 | 版本支持 |
|------|------|------|------|----------|
| **DATE** | YYYY-MM-DD | 0001-01-01 ~ 9999-12-31 | 天 | v1.0+ |
| **DATETIME** | YYYY-MM-DD HH:MM:SS | 0001-01-01 ~ 9999-12-31 | 秒 | v1.0+ |
| **TIMESTAMP** | YYYY-MM-DD HH:MM:SS | 1970-01-01 ~ 2038-01-19 | 秒 | v2.5+ |

### 半结构化类型

| 类型 | 说明 | 最大大小 | 版本支持 |
|------|------|---------|----------|
| **JSON** | JSON对象 | 1048576 bytes (v2.x)<br>2GB (v3.0+) | v2.2+ |
| **ARRAY<T>** | 数组类型 | 元素数量无限制 | v2.1+ |
| **MAP<K,V>** | 键值对 | 元素数量无限制 | v3.0+ |
| **STRUCT** | 结构体 | 字段数量无限制 | v3.1+ |

### 特殊类型

| 类型 | 说明 | 用途 | 版本支持 |
|------|------|------|----------|
| **HLL** | HyperLogLog | 基数统计 | v1.0+ |
| **BITMAP** | 位图 | 精确去重 | v1.0+ |
| **PERCENTILE** | 百分位 | 分位数计算 | v2.0+ |

## 版本特性对照表

### 字符串长度限制变化

| 版本 | CHAR最大长度 | VARCHAR最大长度 | STRING最大长度 | 重要变化 |
|------|-------------|----------------|---------------|----------|
| v1.x | 255 | 65533 | 65533 | 基础支持 |
| v2.0 | 255 | 65533 | 65533 | 性能优化 |
| v2.5 | 255 | 65533 | 1048576 | STRING扩展到1MB |
| v3.0 | 1024 | 1048576 | 2147483643 | 大幅提升长度限制 |
| v3.1+ | 1024 | 1048576 | 2147483643 | 增加STRUCT类型 |

### 数值类型精度变化

| 版本 | DECIMAL精度 | 新增类型 | 性能提升 |
|------|------------|---------|----------|
| v1.x | P:1-27 | - | 基础DECIMAL |
| v2.0 | P:1-38 | - | 扩展精度 |
| v3.0 | P:1-38 | DECIMAL32/64/128 | 原生定长，性能提升50% |

### JSON类型限制

| 版本 | 最大大小 | 嵌套深度 | 索引支持 | 函数支持 |
|------|---------|---------|---------|----------|
| v2.2 | 64KB | 100 | 无 | 基础函数 |
| v2.5 | 1MB | 100 | 部分 | 扩展函数 |
| v3.0 | 2GB | 1000 | 全文索引 | 完整函数 |

## Oracle到StarRocks映射

### 数值类型映射

| Oracle类型 | StarRocks类型 | 转换说明 | 注意事项 |
|-----------|--------------|---------|----------|
| NUMBER(1) | TINYINT | 单字节整数 | 检查范围 |
| NUMBER(3) | SMALLINT | 2字节整数 | 检查范围 |
| NUMBER(5) | INT | 4字节整数 | 常用映射 |
| NUMBER(10) | BIGINT | 8字节整数 | 常用映射 |
| NUMBER(20) | LARGEINT | 16字节整数 | 超大数值 |
| NUMBER(p,s) | DECIMAL(p,s) | 保持精度 | p<=38 |
| NUMBER | DECIMAL(38,9) | 默认映射 | 需指定精度 |
| FLOAT | DOUBLE | 浮点数 | 精度可能损失 |
| BINARY_FLOAT | FLOAT | 单精度 | v1.0+ |
| BINARY_DOUBLE | DOUBLE | 双精度 | v1.0+ |

### 字符类型映射

| Oracle类型 | StarRocks类型 | 版本要求 | 注意事项 |
|-----------|--------------|---------|----------|
| CHAR(n) | CHAR(n) | n<=255(v2.x)<br>n<=1024(v3.0+) | 超长需转VARCHAR |
| VARCHAR2(n) | VARCHAR(n) | n<=65533(v2.x)<br>n<=1048576(v3.0+) | 检查长度限制 |
| NCHAR(n) | CHAR(n*3) | 需计算UTF-8长度 | Unicode字符 |
| NVARCHAR2(n) | VARCHAR(n*3) | 需计算UTF-8长度 | Unicode字符 |
| CLOB | STRING | v2.5建议用STRING | 大文本 |
| NCLOB | STRING | v2.5建议用STRING | Unicode大文本 |
| LONG | STRING | 已废弃类型 | 转STRING |
| RAW(n) | VARBINARY(n) | v2.5+ | 二进制数据 |
| BLOB | STRING/VARBINARY | 需base64编码 | 二进制大对象 |

### 时间类型映射

| Oracle类型 | StarRocks类型 | 精度损失 | 注意事项 |
|-----------|--------------|---------|----------|
| DATE | DATETIME | 无 | Oracle DATE含时间 |
| TIMESTAMP | DATETIME | 毫秒丢失 | StarRocks精度到秒 |
| TIMESTAMP WITH TZ | DATETIME | 时区丢失 | 需应用层处理时区 |
| TIMESTAMP WITH LOCAL TZ | DATETIME | 时区丢失 | 转换为UTC |
| INTERVAL YEAR TO MONTH | INT | 存储月数 | 应用层计算 |
| INTERVAL DAY TO SECOND | BIGINT | 存储秒数 | 应用层计算 |

## MySQL到StarRocks映射

### 数值类型映射

| MySQL类型 | StarRocks类型 | 完全兼容 | 注意事项 |
|----------|--------------|---------|----------|
| BIT(1) | BOOLEAN | 是 | 布尔值 |
| TINYINT | TINYINT | 是 | 1字节 |
| SMALLINT | SMALLINT | 是 | 2字节 |
| MEDIUMINT | INT | 否 | 3→4字节 |
| INT | INT | 是 | 4字节 |
| BIGINT | BIGINT | 是 | 8字节 |
| DECIMAL(M,D) | DECIMAL(M,D) | 是 | M<=38 |
| FLOAT | FLOAT | 是 | 单精度 |
| DOUBLE | DOUBLE | 是 | 双精度 |

### 字符类型映射

| MySQL类型 | StarRocks类型 | 版本要求 | 注意事项 |
|----------|--------------|---------|----------|
| CHAR(n) | CHAR(n) | n<=255(v2.x)<br>n<=1024(v3.0+) | 定长字符 |
| VARCHAR(n) | VARCHAR(n) | n<=65533(v2.x)<br>n<=1048576(v3.0+) | 可变长度 |
| TINYTEXT | VARCHAR(255) | v1.0+ | 小文本 |
| TEXT | STRING | v2.5+ | 64KB文本 |
| MEDIUMTEXT | STRING | v2.5+ | 16MB文本 |
| LONGTEXT | STRING | v3.0+ | 4GB文本 |
| BINARY(n) | BINARY(n) | v2.5+ | 定长二进制 |
| VARBINARY(n) | VARBINARY(n) | v2.5+ | 变长二进制 |
| TINYBLOB | VARBINARY(255) | v2.5+ | 小二进制 |
| BLOB | STRING | 需编码 | 64KB二进制 |
| MEDIUMBLOB | STRING | 需编码 | 16MB二进制 |
| LONGBLOB | STRING | 需编码 | 4GB二进制 |

### 时间类型映射

| MySQL类型 | StarRocks类型 | 精度/范围 | 注意事项 |
|----------|--------------|----------|----------|
| DATE | DATE | 完全兼容 | YYYY-MM-DD |
| DATETIME | DATETIME | 秒级精度 | 毫秒丢失 |
| TIMESTAMP | DATETIME | 秒级精度 | 时区转换 |
| TIME | VARCHAR(8) | 转字符串 | HH:MM:SS |
| YEAR | SMALLINT | 转整数 | 年份值 |

### 特殊类型映射

| MySQL类型 | StarRocks类型 | 处理方式 | 注意事项 |
|----------|--------------|---------|----------|
| ENUM | VARCHAR | 转字符串 | 枚举值 |
| SET | VARCHAR | 逗号分隔 | 集合值 |
| JSON | JSON(v2.2+)<br>STRING(v2.0) | 版本依赖 | JSON对象 |
| GEOMETRY | STRING | WKT格式 | 空间数据 |

## 字段设计最佳实践

### 1. 整数类型选择

```sql
-- ✅ 根据实际范围选择合适的类型
CREATE TABLE good_int_design (
    -- 状态码：0-9，使用TINYINT
    status TINYINT NOT NULL DEFAULT 0,
    
    -- 年龄：0-150，使用TINYINT
    age TINYINT,
    
    -- 商品数量：一般不超过10000
    quantity SMALLINT DEFAULT 0,
    
    -- 用户ID：可能很大
    user_id BIGINT NOT NULL,
    
    -- 金额：使用DECIMAL避免精度问题
    amount DECIMAL(15,2) NOT NULL
);

-- ❌ 过度使用大类型，浪费存储
CREATE TABLE bad_int_design (
    status BIGINT,  -- 浪费7字节
    age BIGINT,     -- 浪费7字节
    quantity BIGINT -- 浪费6字节
);
```

### 2. 字符串类型选择

```sql
-- StarRocks v3.0+ 版本
CREATE TABLE string_design_v3 (
    -- 固定长度：使用CHAR
    country_code CHAR(2),      -- 国家代码
    phone_area CHAR(4),        -- 区号
    
    -- 有长度限制的变长：使用VARCHAR
    username VARCHAR(50),       -- 用户名
    email VARCHAR(100),         -- 邮箱
    address VARCHAR(500),       -- 地址
    
    -- 大文本：使用STRING
    description STRING,         -- 描述
    content STRING,            -- 文章内容
    log_detail STRING          -- 日志详情
);

-- StarRocks v2.x 版本（长度限制更严格）
CREATE TABLE string_design_v2 (
    -- CHAR最大255
    country_code CHAR(2),
    
    -- VARCHAR最大65533
    username VARCHAR(50),
    email VARCHAR(100),
    -- 超长文本必须用STRING
    content STRING  -- v2.5最大1MB
);
```

### 3. 时间类型选择

```sql
CREATE TABLE time_design (
    -- 只需要日期：使用DATE
    birth_date DATE,
    
    -- 需要时间：使用DATETIME  
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    update_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    
    -- 时间范围计算：存储为数值
    duration_seconds INT,  -- 持续时间（秒）
    
    -- 年月：可以用INT存储YYYYMM
    year_month INT  -- 如：202401
);
```

### 4. JSON类型使用（v2.2+）

```sql
-- v3.0+ JSON类型使用
CREATE TABLE json_design_v3 (
    id BIGINT,
    -- 结构化的配置信息
    config JSON,
    -- 动态扩展字段
    extra_info JSON,
    -- 日志详情
    log_data JSON
);

-- 插入JSON数据
INSERT INTO json_design_v3 VALUES
(1, '{"name":"Alice","age":25}', '{"city":"Beijing"}', '{"level":"INFO","message":"test"}');

-- 查询JSON字段
SELECT 
    id,
    get_json_string(config, '$.name') as name,
    get_json_int(config, '$.age') as age
FROM json_design_v3;

-- v2.2-v2.5 JSON使用限制
CREATE TABLE json_design_v2 (
    id BIGINT,
    -- JSON大小限制：最大1MB
    config JSON,  
    -- 复杂JSON可能需要用STRING
    large_json STRING
);
```

### 5. 边界场景处理

```sql
-- 处理超长字符串（根据版本选择）
CREATE TABLE handle_long_string (
    id BIGINT,
    
    -- v2.x: VARCHAR最大65533
    -- 超过限制需要分割或用STRING
    long_text_v2 STRING,
    
    -- v3.0+: VARCHAR最大1048576 (1MB)
    -- 可以存储更长的文本
    long_text_v3 VARCHAR(1000000)
);

-- 处理高精度数值
CREATE TABLE handle_precision (
    id BIGINT,
    
    -- 金额：最多2位小数
    amount DECIMAL(15,2),
    
    -- 科学计算：需要高精度
    scientific_value DECIMAL(38,10),
    
    -- v3.0+ 使用定长DECIMAL性能更好
    price DECIMAL64(15,2)  -- 最多18位，性能好
);

-- 处理NULL值
CREATE TABLE handle_null (
    id BIGINT NOT NULL,
    
    -- 必填字段：NOT NULL + DEFAULT
    status TINYINT NOT NULL DEFAULT 0,
    
    -- 可选字段：允许NULL
    description VARCHAR(200),
    
    -- 聚合表的指标列：设置默认值
    total_amount DECIMAL(15,2) DEFAULT 0.00
);
```

## 类型转换注意事项

### 1. 精度损失风险

```sql
-- Oracle TIMESTAMP(6) → StarRocks DATETIME
-- 损失：微秒精度
-- 解决：存储为BIGINT（时间戳毫秒）

CREATE TABLE time_precision (
    -- 原始：TIMESTAMP(6)
    -- 方案1：损失微秒
    event_time DATETIME,
    
    -- 方案2：保留毫秒精度
    event_time_ms BIGINT,
    
    -- 方案3：分开存储
    event_date DATE,
    event_time_micro BIGINT
);
```

### 2. 字符集处理

```sql
-- MySQL utf8mb4 → StarRocks UTF-8
-- 注意：emoji和特殊字符

CREATE TABLE charset_handling (
    id BIGINT,
    -- 确保长度足够存储UTF-8字符
    -- 中文字符可能占3字节
    chinese_name VARCHAR(30),  -- 最多10个中文字符
    
    -- emoji可能占4字节
    nickname VARCHAR(100),  -- 考虑emoji
    
    -- 二进制数据避免字符集问题
    binary_data VARBINARY(1000)  -- v2.5+
);
```

### 3. 大对象处理

```sql
-- Oracle BLOB/CLOB → StarRocks
CREATE TABLE large_object_handling (
    id BIGINT,
    
    -- 文本大对象：直接用STRING
    text_content STRING,
    
    -- 二进制大对象：需要编码
    -- 方案1：Base64编码存储
    binary_content_base64 STRING,
    
    -- 方案2：存储文件路径
    file_path VARCHAR(500),
    
    -- 方案3：v2.5+使用VARBINARY
    binary_content VARBINARY(1048576)
);
```

## 版本升级建议

### 从v2.x升级到v3.0

1. **字符串长度扩展**
   - CHAR: 255 → 1024
   - VARCHAR: 65533 → 1048576
   - STRING: 1MB → 2GB

2. **性能优化类型**
   - DECIMAL → DECIMAL32/64/128
   - 性能提升30-50%

3. **新增类型支持**
   - MAP类型
   - STRUCT类型
   - 更好的JSON支持

### 升级检查清单

```sql
-- 检查需要调整的表
-- 1. 检查VARCHAR长度超过旧版本限制的表
SELECT 
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH
FROM INFORMATION_SCHEMA.COLUMNS
WHERE DATA_TYPE = 'VARCHAR' 
  AND CHARACTER_MAXIMUM_LENGTH > 65533;

-- 2. 检查可以优化为新类型的DECIMAL字段
SELECT 
    TABLE_NAME,
    COLUMN_NAME,
    NUMERIC_PRECISION,
    NUMERIC_SCALE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE DATA_TYPE = 'DECIMAL'
  AND NUMERIC_PRECISION <= 18;  -- 可以用DECIMAL64

-- 3. 评估JSON字段的大小
SELECT 
    MAX(LENGTH(json_column)) as max_json_size,
    AVG(LENGTH(json_column)) as avg_json_size
FROM your_table;
```

## 常见问题

### Q1: VARCHAR和STRING如何选择？
**A**: 
- 已知最大长度且不超过1MB：用VARCHAR
- 长度不确定或超过1MB：用STRING
- v2.x版本VARCHAR限制65533，注意版本

### Q2: DECIMAL和FLOAT/DOUBLE如何选择？
**A**: 
- 金额、财务数据：必须用DECIMAL
- 科学计算、不要求精确：可用FLOAT/DOUBLE
- v3.0+考虑DECIMAL32/64/128性能更好

### Q3: 如何处理Oracle的NUMBER类型？
**A**: 
- NUMBER(p) → 根据p选择INT/BIGINT/LARGEINT
- NUMBER(p,s) → DECIMAL(p,s)
- 无精度NUMBER → DECIMAL(38,9)或BIGINT

### Q4: 字符串长度该如何设置？
**A**: 
- 预留20-30%的冗余空间
- 考虑UTF-8编码，中文占3字节
- 参考历史数据的最大长度

## 小结

- 根据实际数据范围选择最小够用的类型
- 注意不同版本的长度限制差异
- 金融数据使用DECIMAL确保精度
- 大文本和二进制数据选择合适的存储方式
- 升级版本时检查类型兼容性

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](bucket-design.md) | [➡️ 下一页](../04-kettle-integration/kettle-setup.md)
---