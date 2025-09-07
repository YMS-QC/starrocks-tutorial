---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](aggregate-optimization.md) | [➡️ 下一页](../06-advanced-features/materialized-views.md)
---

# StarRocks索引优化

> **版本要求**：本章节内容适用于StarRocks 1.19+，建议使用3.1+版本以获得完整的索引优化特性

## 学习目标

- 理解StarRocks中不同类型索引的原理和适用场景
- 掌握Bitmap索引、Bloom Filter索引的创建和使用
- 学会通过索引优化点查询和范围查询性能
- 了解索引的维护成本和选择策略

## StarRocks索引类型概览

### 1. 索引类型对比

> **版本支持**：不同索引类型的版本要求
> - 前缀索引：StarRocks 1.19+（自动创建）
> - Bloom Filter索引：StarRocks 1.19+
> - Bitmap索引：StarRocks 2.0+
> - 倒排索引：StarRocks 3.1+
> - N-gram Bloom Filter索引：StarRocks 3.2+
> - 持久化索引（Primary Key表）：StarRocks 3.0+

| 索引类型 | 适用场景 | 查询类型 | 基数要求 | 存储开销 | 写入影响 | 最低版本 |
|---------|---------|---------|---------|---------|---------|----------|
| **前缀索引** | 排序键查询 | 点查询、范围查询 | 任意 | 无额外 | 无 | 1.19+ |
| **Bitmap索引** | 低基数列过滤 | 等值查询、IN查询 | 低(<1000) | 中等 | 中等 | 2.0+ |
| **Bloom Filter** | 高基数列过滤 | 等值查询 | 高(>1000) | 低(1-2%) | 低 | 1.19+ |
| **倒排索引** | 全文检索 | LIKE、全文搜索 | 任意 | 高(10-30%) | 高 | 3.1+ |
| **N-gram Bloom Filter** | 模糊匹配 | LIKE '%keyword%'、ngram_search | 任意 | 中等(3-5%) | 中等 | 3.2+ |
| **持久化索引** | Primary Key表主键查询 | 点查询、更新 | 任意 | 高(内存/磁盘) | 低 | 3.0+ |

### 2. 索引支持的表模型

| 索引类型 | Duplicate Key | Aggregate Key | Unique Key | Primary Key |
|---------|--------------|---------------|------------|-------------|
| **前缀索引** | ✅ 自动 | ✅ 自动 | ✅ 自动 | ✅ 自动 |
| **Bitmap索引** | ✅ 所有列 | ✅ 仅Key列 | ✅ 仅Key列 | ✅ 所有列 |
| **Bloom Filter** | ✅ 所有列 | ✅ 仅Key列 | ✅ 仅Key列 | ✅ 所有列 |
| **倒排索引** | ✅ 字符串列 | ✅ 仅Key列 | ✅ 仅Key列 | ✅ 字符串列 |
| **N-gram Bloom Filter** | ✅ 字符串列 | ✅ 仅Key列 | ✅ 仅Key列 | ✅ 字符串列 |

## 前缀索引优化

### 1. 前缀索引原理

StarRocks会自动为排序键（DUPLICATE KEY、AGGREGATE KEY、UNIQUE KEY）创建前缀索引。

```sql
-- 创建测试表
CREATE TABLE user_profiles (
    user_id BIGINT NOT NULL,           -- 前缀索引第1列
    email VARCHAR(100) NOT NULL,       -- 前缀索引第2列  
    username VARCHAR(50),              -- 前缀索引第3列
    age INT,
    city VARCHAR(50),
    register_time DATETIME,
    last_login DATETIME,
    status VARCHAR(20)
)
DUPLICATE KEY(user_id, email, username)  -- 前缀索引列
DISTRIBUTED BY HASH(user_id) BUCKETS 10;
```

### 2. 前缀索引使用优化

```sql
-- ✅ 高效查询：使用前缀索引
-- 查询1：使用第1个前缀列
EXPLAIN SELECT * FROM user_profiles WHERE user_id = 12345;
/*
前缀索引生效，快速定位数据
*/

-- 查询2：使用前2个前缀列
EXPLAIN SELECT * FROM user_profiles 
WHERE user_id = 12345 AND email = 'user@example.com';
/*
前缀索引完全生效，性能最优
*/

-- 查询3：使用前缀的范围查询
EXPLAIN SELECT * FROM user_profiles 
WHERE user_id BETWEEN 10000 AND 20000;
/*
前缀索引支持范围查询
*/

-- ❌ 低效查询：无法使用前缀索引
-- 查询4：跳过第1个前缀列
EXPLAIN SELECT * FROM user_profiles WHERE email = 'user@example.com';
/*
无法使用前缀索引，需要全表扫描
*/

-- 查询5：使用函数破坏前缀索引
EXPLAIN SELECT * FROM user_profiles WHERE UPPER(user_id) = '12345';
/*
函数导致无法使用索引
*/
```

### 3. 前缀索引设计最佳实践

```sql
-- ✅ 好的前缀索引设计
CREATE TABLE orders_optimized (
    order_date DATE NOT NULL,          -- 高频查询条件，第1位
    status VARCHAR(20) NOT NULL,       -- 高选择性，第2位
    order_id BIGINT NOT NULL,          -- 唯一标识，第3位
    user_id BIGINT,
    amount DECIMAL(10,2),
    create_time DATETIME
)
DUPLICATE KEY(order_date, status, order_id)  -- 按查询频率排序
PARTITION BY RANGE(order_date) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 32;

-- ❌ 差的前缀索引设计  
CREATE TABLE orders_bad (
    order_id BIGINT NOT NULL,          -- 随机分布，选择性过高
    create_time DATETIME NOT NULL,     -- 查询频率低
    status VARCHAR(20) NOT NULL,       -- 应该放在更前面
    order_date DATE,
    user_id BIGINT,
    amount DECIMAL(10,2)
)
DUPLICATE KEY(order_id, create_time, status);  -- 顺序不合理
```

## Bitmap索引优化

### 1. Bitmap索引创建

Bitmap索引适合**低基数**（唯一值数量少）的列，如状态、类型、性别等。

```sql
-- 方法1：在建表时创建Bitmap索引
CREATE TABLE product_catalog (
    product_id BIGINT,
    product_name VARCHAR(200),
    category VARCHAR(50),      -- 低基数，适合Bitmap索引
    brand VARCHAR(50),         -- 低基数，适合Bitmap索引
    status VARCHAR(20),        -- 低基数，适合Bitmap索引
    price DECIMAL(10,2),
    INDEX idx_category (category) USING BITMAP,
    INDEX idx_brand (brand) USING BITMAP,
    INDEX idx_status (status) USING BITMAP
)
DUPLICATE KEY(product_id)
DISTRIBUTED BY HASH(product_id) BUCKETS 10;

-- 方法2：使用ALTER TABLE添加Bitmap索引
ALTER TABLE product_catalog 
ADD INDEX idx_category (category) USING BITMAP;

-- 方法3：批量添加多个Bitmap索引
ALTER TABLE product_catalog 
ADD INDEX idx_brand (brand) USING BITMAP,
ADD INDEX idx_status (status) USING BITMAP;

-- 查看索引信息
SHOW INDEX FROM product_catalog;
```

### 2. Bitmap索引查询优化

```sql
-- 创建包含低基数列的测试数据
INSERT INTO product_catalog VALUES
(1, 'iPhone 15', 'Phone', 'Apple', 'Active', 7999.00),
(2, 'Samsung S24', 'Phone', 'Samsung', 'Active', 6999.00),
(3, 'MacBook Pro', 'Laptop', 'Apple', 'Active', 16999.00),
(4, 'ThinkPad X1', 'Laptop', 'Lenovo', 'Inactive', 12999.00);

-- ✅ 高效的Bitmap索引查询
-- 查询1：单个低基数列过滤
EXPLAIN SELECT * FROM product_catalog WHERE category = 'Phone';
/*
Bitmap索引生效，快速过滤
*/

-- 查询2：多个低基数列组合
EXPLAIN SELECT * FROM product_catalog 
WHERE category = 'Phone' AND brand = 'Apple' AND status = 'Active';
/*
多个Bitmap索引组合，过滤效果更好
*/

-- 查询3：IN查询优化
EXPLAIN SELECT * FROM product_catalog 
WHERE category IN ('Phone', 'Laptop') AND status = 'Active';
/*
Bitmap索引对IN查询优化效果显著
*/

-- ❌ 不适合Bitmap索引的查询
-- 查询4：高基数列（如product_id）
EXPLAIN SELECT * FROM product_catalog WHERE product_id = 1;
/*
高基数列不适合Bitmap索引，建议使用Bloom Filter
*/

-- 查询5：范围查询
EXPLAIN SELECT * FROM product_catalog WHERE price BETWEEN 5000 AND 10000;
/*
Bitmap索引不支持范围查询
*/
```

### 3. Bitmap索引配置优化

```sql
-- Bitmap索引相关配置参数
-- BE配置文件（be.conf）中的重要参数：

-- bitmap_max_filter_ratio: 控制Bitmap索引使用的阈值
-- 默认值：1000，表示当过滤后的行数/总行数 < 1/1000时才使用Bitmap索引
-- 建议值：根据实际场景调整，低基数列可设置更大值
bitmap_max_filter_ratio=1000

-- bitmap_filter_enable: 是否启用Bitmap索引过滤
-- 默认值：true
bitmmap_filter_enable=true

-- 查询时强制使用Bitmap索引
SET enable_bitmap_index_filter = true;
SET bitmap_max_filter_ratio = 10000;  -- 放宽使用条件

-- 分析Bitmap索引效果
EXPLAIN ANALYZE
SELECT COUNT(*) FROM product_catalog 
WHERE category = 'Phone' AND status = 'Active';
-- 查看Profile中的BitmapIndexFilter相关指标
```

### 4. Bitmap索引性能测试

```sql
-- 创建大量测试数据
CREATE TABLE sales_records (
    record_id BIGINT,
    sale_date DATE,
    region VARCHAR(50),        -- 50个不同地区
    channel VARCHAR(20),       -- 10个销售渠道
    product_category VARCHAR(30), -- 20个产品类别
    sales_amount DECIMAL(15,2)
)
DUPLICATE KEY(record_id)
DISTRIBUTED BY HASH(record_id) BUCKETS 32
PROPERTIES (
    "bloom_filter_columns" = "region,channel,product_category"
);

-- 插入100万条测试数据
-- Python脚本生成数据...

-- 性能对比测试
-- 测试1：无索引查询
ALTER TABLE sales_records SET ("bloom_filter_columns" = "");

SELECT COUNT(*) FROM sales_records 
WHERE region = '北京' AND channel = '线上' AND product_category = '电子产品';
-- 执行时间：约2-3秒

-- 测试2：有Bitmap索引查询
ALTER TABLE sales_records SET ("bloom_filter_columns" = "region,channel,product_category");

SELECT COUNT(*) FROM sales_records 
WHERE region = '北京' AND channel = '线上' AND product_category = '电子产品';
-- 执行时间：约0.1-0.2秒，性能提升10-20倍
```

## Bloom Filter索引优化

> **版本说明**：Bloom Filter索引的版本演进
> - 基础Bloom Filter：StarRocks 1.19+
> - 增强Bloom Filter：StarRocks 2.0+
> - 动态FPP调整：StarRocks 2.5+
> - 自适应Bloom Filter：StarRocks 3.0+
> - 持久化Bloom Filter（Primary Key表）：StarRocks 3.3+

### 1. Bloom Filter索引创建

Bloom Filter索引适合**高基数**列的等值查询，如用户ID、订单ID、邮箱等。它通过概率数据结构快速判断数据是否**可能存在**。

```sql
-- 创建包含高基数列的表
CREATE TABLE user_behaviors (
    behavior_id BIGINT,
    user_id BIGINT,           -- 高基数，适合Bloom Filter
    session_id VARCHAR(64),   -- 高基数，适合Bloom Filter
    event_type VARCHAR(50),   -- 中等基数
    page_url VARCHAR(500),    -- 高基数，适合Bloom Filter
    behavior_time DATETIME,
    ip_address VARCHAR(15)    -- 高基数，适合Bloom Filter
)
DUPLICATE KEY(behavior_id)
PARTITION BY RANGE(behavior_time) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01'))
)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "bloom_filter_columns" = "user_id,session_id,page_url,ip_address",
    "bloom_filter_fpp" = "0.01"  -- 假阳性率1%
);
```

### 2. Bloom Filter参数调优

```sql
-- 查看Bloom Filter相关参数
SHOW VARIABLES LIKE '%bloom%';

-- 关键参数说明：
-- bloom_filter_fpp: 假阳性率，越小越精确，但存储开销越大
-- bloom_filter_columns: 指定创建Bloom Filter的列

-- 不同FPP值的对比
CREATE TABLE bloom_test_001 (
    id BIGINT,
    user_id BIGINT,
    data VARCHAR(100)
)
DISTRIBUTED BY HASH(id) BUCKETS 10
PROPERTIES (
    "bloom_filter_columns" = "user_id",
    "bloom_filter_fpp" = "0.001"  -- 0.1%假阳性率，高精度
);

CREATE TABLE bloom_test_01 (
    id BIGINT,
    user_id BIGINT, 
    data VARCHAR(100)
)
DISTRIBUTED BY HASH(id) BUCKETS 10
PROPERTIES (
    "bloom_filter_columns" = "user_id",
    "bloom_filter_fpp" = "0.01"   -- 1%假阳性率，平衡选择
);

CREATE TABLE bloom_test_05 (
    id BIGINT,
    user_id BIGINT,
    data VARCHAR(100)
)
DISTRIBUTED BY HASH(id) BUCKETS 10
PROPERTIES (
    "bloom_filter_columns" = "user_id", 
    "bloom_filter_fpp" = "0.05"   -- 5%假阳性率，低存储开销
);
```

### 3. Bloom Filter查询优化

```sql
-- ✅ 适合Bloom Filter的查询
-- 查询1：高基数列等值查询
EXPLAIN SELECT * FROM user_behaviors WHERE user_id = 123456;
/*
Bloom Filter快速判断数据是否可能存在
*/

-- 查询2：字符串等值查询  
EXPLAIN SELECT * FROM user_behaviors WHERE session_id = 'sess_abc123def456';
/*
对于高基数字符串列效果很好
*/

-- 查询3：多个高基数列组合
EXPLAIN SELECT * FROM user_behaviors 
WHERE user_id = 123456 AND session_id = 'sess_abc123def456';
/*
多个Bloom Filter组合使用
*/

-- ❌ 不适合Bloom Filter的查询
-- 查询4：范围查询
EXPLAIN SELECT * FROM user_behaviors WHERE user_id > 100000;
/*
Bloom Filter不支持范围查询
*/

-- 查询5：模糊查询
EXPLAIN SELECT * FROM user_behaviors WHERE page_url LIKE '%product%';
/*
Bloom Filter不支持模糊匹配
*/
```

### 4. Bloom Filter效果验证

```sql
-- 验证Bloom Filter效果
-- 开启Profile查看过滤统计
SET enable_profile = true;

SELECT COUNT(*) FROM user_behaviors WHERE user_id = 999999;  -- 不存在的用户

-- 在Profile中查看：
-- BloomFilterFiltered: 被Bloom Filter过滤的数据块数量
-- 如果Bloom Filter工作正常，大部分数据块会被直接过滤掉

-- 对比测试：关闭Bloom Filter
ALTER TABLE user_behaviors SET ("bloom_filter_columns" = "");

SELECT COUNT(*) FROM user_behaviors WHERE user_id = 999999;
-- 查看扫描的数据量差异
```

## 倒排索引优化

> **版本要求**：倒排索引需要StarRocks 3.1+
> - 基础倒排索引：StarRocks 3.1+
> - 中文分词支持：StarRocks 3.2+
> - 全文搜索优化：StarRocks 3.3+

### 1. 倒排索引创建

倒排索引（Full-text inverted index）支持全文检索和复杂的字符串匹配，通过将文本拆分为词项（terms）并建立词项到文档的映射关系。

```sql
-- 创建支持倒排索引的表（StarRocks 3.1+）
CREATE TABLE article_content (
    article_id BIGINT,
    title VARCHAR(500),
    content TEXT,
    author VARCHAR(100),
    publish_time DATETIME,
    tags VARCHAR(200),
    -- 在建表时创建倒排索引
    INDEX idx_title_gin (title) USING GIN,       -- GIN索引（通用倒排索引）
    INDEX idx_content_gin (content) USING GIN,
    INDEX idx_tags_gin (tags) USING GIN
)
DUPLICATE KEY(article_id)
DISTRIBUTED BY HASH(article_id) BUCKETS 10;

-- 或者在现有表上添加倒排索引
ALTER TABLE article_content 
ADD INDEX idx_title_gin (title) USING GIN COMMENT '标题全文索引';

ALTER TABLE article_content 
ADD INDEX idx_content_gin (content) USING GIN 
PROPERTIES(
    "parser" = "chinese",           -- 使用中文分词器（3.2+）
    "parser_mode" = "fine_grained", -- 细粒度分词
    "support_phrase" = "true"       -- 支持短语搜索
);
```

### 2. 倒排索引查询

```sql
-- ✅ 利用倒排索引的查询
-- 查询1：全文检索（使用match或match_all函数）
SELECT article_id, title FROM article_content 
WHERE match(content, 'StarRocks 数据库');

-- 查询2：短语搜索（精确匹配短语）
SELECT article_id, title FROM article_content
WHERE match_phrase(content, 'StarRocks 优化');

-- 查询3：布尔查询（AND、OR、NOT组合）
SELECT article_id, title FROM article_content
WHERE match(content, 'StarRocks AND 优化 NOT MySQL');

-- 查询4：通配符查询
SELECT article_id, title FROM article_content
WHERE match(title, 'Star*');

-- 查询5：正则表达式查询
SELECT article_id, title FROM article_content
WHERE regexp_match(content, '数据[库|仓]');

-- 查询6：相关性评分排序
SELECT article_id, 
       title,
       match_score(content, 'StarRocks 优化') as relevance
FROM article_content
WHERE match(content, 'StarRocks 优化')
ORDER BY relevance DESC
LIMIT 10;
```

### 3. 倒排索引配置优化

```sql
-- 倒排索引分词器配置
CREATE TABLE text_search (
    id BIGINT,
    chinese_text TEXT,
    english_text TEXT,
    mixed_text TEXT,
    -- 中文分词器
    INDEX idx_chinese (chinese_text) USING GIN 
    PROPERTIES(
        "parser" = "chinese",
        "parser_mode" = "fine_grained"  -- 细粒度分词
    ),
    -- 英文分词器
    INDEX idx_english (english_text) USING GIN 
    PROPERTIES(
        "parser" = "english",
        "lower_case" = "true",         -- 转小写
        "remove_stopwords" = "true"    -- 移除停用词
    ),
    -- 混合内容分词器
    INDEX idx_mixed (mixed_text) USING GIN 
    PROPERTIES(
        "parser" = "unicode",           -- Unicode分词器
        "min_gram" = "2",              -- 最小gram长度
        "max_gram" = "4"               -- 最大gram长度
    )
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;
```

### 4. 倒排索引维护

```sql
-- 查看倒排索引状态
SHOW INDEX FROM article_content;

-- 查看索引创建进度（异步创建）
SHOW ALTER TABLE COLUMN WHERE TableName = 'article_content';

-- 重建倒排索引
ALTER TABLE article_content DROP INDEX idx_content_gin;
ALTER TABLE article_content ADD INDEX idx_content_gin (content) USING GIN;

-- 监控倒排索引大小和性能
SELECT 
    TABLE_NAME,
    INDEX_NAME,
    INDEX_TYPE,
    INDEX_SIZE_MB,
    CARDINALITY,      -- 索引基数
    AVG_ROW_LENGTH    -- 平均行长度
FROM information_schema.statistics
WHERE TABLE_SCHEMA = 'demo_etl'
  AND INDEX_TYPE = 'GIN';
  
-- 分析倒排索引使用情况
EXPLAIN ANALYZE
SELECT * FROM article_content 
WHERE match(content, 'StarRocks');
-- 查看是否使用了GIN索引
```

## N-gram Bloom Filter索引优化

> **版本要求**：N-gram Bloom Filter索引需要StarRocks 3.2+
> - 基础支持：StarRocks 3.2+
> - 性能优化：StarRocks 3.3+

### 1. N-gram Bloom Filter索引创建

N-gram Bloom Filter是专门用于加速`LIKE`查询和`ngram_search`函数的特殊Bloom Filter索引。

```sql
-- 创建N-gram Bloom Filter索引
CREATE TABLE search_logs (
    log_id BIGINT,
    user_query VARCHAR(500),
    search_keyword VARCHAR(200),
    result_count INT,
    search_time DATETIME,
    -- 创建N-gram Bloom Filter索引
    INDEX idx_query_ngram (user_query) USING NGRAMBF (
        "gram_num" = "4",              -- N-gram的N值，默认为4
        "bloom_filter_fpp" = "0.05"    -- 假阳性率，默认0.05
    ) COMMENT 'N-gram索引用于模糊搜索',
    INDEX idx_keyword_ngram (search_keyword) USING NGRAMBF (
        "gram_num" = "3",              -- 对于较短文本可以使用3
        "bloom_filter_fpp" = "0.01"    -- 更低的假阳性率
    )
)
DUPLICATE KEY(log_id)
DISTRIBUTED BY HASH(log_id) BUCKETS 10;

-- 在现有表上添加N-gram Bloom Filter索引
ALTER TABLE search_logs 
ADD INDEX idx_new_ngram(user_query) USING NGRAMBF (
    "gram_num" = "4",
    "bloom_filter_fpp" = "0.05"
) COMMENT 'N-gram索引';

-- 查看N-gram索引信息
SHOW CREATE TABLE search_logs;
SHOW INDEX FROM search_logs;
```

### 2. N-gram索引查询优化

```sql
-- ✅ N-gram Bloom Filter加速的查询
-- 查询1：LIKE模糊查询（中间匹配）
SELECT * FROM search_logs 
WHERE user_query LIKE '%StarRocks%';
-- N-gram索引可以加速包含中间匹配的LIKE查询

-- 查询2：ngram_search函数
SELECT * FROM search_logs 
WHERE ngram_search(user_query, 'rocks', 4);
-- 使用ngram_search函数进行N-gram匹配

-- 查询3：不区分大小写的N-gram搜索
SELECT * FROM search_logs 
WHERE ngram_search_case_insensitive(user_query, 'STARROCKS', 4);

-- 查询4：多个模糊条件组合
SELECT * FROM search_logs 
WHERE user_query LIKE '%database%' 
  AND search_keyword LIKE '%optimization%';
-- 多个N-gram索引协同工作

-- ❌ N-gram索引无法优化的查询
-- 查询5：前缀匹配（使用前缀索引更好）
SELECT * FROM search_logs WHERE user_query LIKE 'StarRocks%';

-- 查询6：正则表达式（需要倒排索引）
SELECT * FROM search_logs WHERE user_query REGEXP 'Star.*Rocks';
```

### 3. N-gram索引参数调优

```sql
-- gram_num参数选择指南
-- gram_num = 2: 适合短文本，索引较大，精度高
-- gram_num = 3: 平衡选择，适合中等长度文本
-- gram_num = 4: 默认值，适合大多数场景
-- gram_num = 5+: 适合长文本，索引较小，可能漏检

-- 创建不同gram_num的对比测试
CREATE TABLE ngram_test_2 (
    id BIGINT,
    text VARCHAR(500),
    INDEX idx_ngram_2 (text) USING NGRAMBF ("gram_num" = "2")
) DISTRIBUTED BY HASH(id) BUCKETS 1;

CREATE TABLE ngram_test_4 (
    id BIGINT,
    text VARCHAR(500),
    INDEX idx_ngram_4 (text) USING NGRAMBF ("gram_num" = "4")
) DISTRIBUTED BY HASH(id) BUCKETS 1;

-- 插入测试数据
INSERT INTO ngram_test_2 VALUES (1, 'StarRocks is a fast analytical database');
INSERT INTO ngram_test_4 VALUES (1, 'StarRocks is a fast analytical database');

-- 测试查询效果
EXPLAIN SELECT * FROM ngram_test_2 WHERE text LIKE '%Rock%';  -- gram_num=2
EXPLAIN SELECT * FROM ngram_test_4 WHERE text LIKE '%Rock%';  -- gram_num=4
```

### 4. N-gram与其他索引对比

| 查询模式 | N-gram Bloom Filter | 倒排索引 | 普通Bloom Filter |
|---------|-------------------|---------|-----------------|
| LIKE '%keyword%' | ✅ 最优 | ✅ 支持 | ❌ 不支持 |
| LIKE 'keyword%' | ⚠️ 可用 | ✅ 最优 | ❌ 不支持 |
| = 'exact_match' | ⚠️ 可用 | ✅ 支持 | ✅ 最优 |
| 全文搜索 | ❌ 不支持 | ✅ 最优 | ❌ 不支持 |
| 存储开销 | 中等 | 高 | 低 |
| 创建速度 | 快 | 慢 | 快 |
| 假阳性率 | 有(可配置) | 无 | 有(可配置) |

## 持久化索引优化（Primary Key表）

> **版本要求**：持久化索引需要StarRocks 3.0+
> - 内存持久化索引：StarRocks 3.0+
> - 磁盘持久化索引：StarRocks 3.1+
> - 索引压缩优化：StarRocks 3.2+
> - Page级别读取优化：StarRocks 3.3+

### 1. 持久化索引配置

```sql
-- 创建Primary Key表时配置持久化索引
CREATE TABLE user_profile_pk (
    user_id BIGINT NOT NULL,
    username VARCHAR(50),
    email VARCHAR(100),
    last_login DATETIME,
    status INT,
    PRIMARY KEY(user_id)
)
DISTRIBUTED BY HASH(user_id) BUCKETS 10
PROPERTIES (
    "enable_persistent_index" = "true",           -- 启用持久化索引
    "persistent_index_type" = "LOCAL",            -- LOCAL: 本地磁盘, CLOUD: 对象存储
    "compression_type" = "LZ4"                    -- 索引压缩算法
);

-- 修改现有Primary Key表的持久化索引配置
ALTER TABLE user_profile_pk SET (
    "enable_persistent_index" = "true",
    "persistent_index_type" = "LOCAL"
);

-- 查看持久化索引状态
SHOW CREATE TABLE user_profile_pk;
```

### 2. 持久化索引性能优化

```sql
-- BE配置优化（be.conf）
-- persistent_index_page_cache_capacity: 持久化索引页缓存大小
-- 默认值：10% of mem_limit，建议根据实际情况调整
persistent_index_page_cache_capacity = 8GB

-- persistent_index_meta_cache_capacity: 持久化索引元数据缓存
-- 默认值：2GB
persistent_index_meta_cache_capacity = 2GB

-- 查询时强制使用持久化索引
SET enable_persistent_index_scan = true;

-- 分析持久化索引效果
EXPLAIN ANALYZE
SELECT * FROM user_profile_pk WHERE user_id = 12345;
-- 查看是否使用PersistentIndex
```

### 3. 持久化索引监控

```sql
-- 监控持久化索引内存使用
SELECT 
    BE_ID,
    INDEX_DISK_USAGE_BYTES / 1024 / 1024 as INDEX_DISK_MB,
    INDEX_MEMORY_USAGE_BYTES / 1024 / 1024 as INDEX_MEMORY_MB,
    INDEX_ROW_COUNT
FROM information_schema.be_persistent_index_status;

-- 持久化索引缓存命中率
SELECT 
    BE_ID,
    CACHE_HIT_COUNT,
    CACHE_MISS_COUNT,
    CACHE_HIT_COUNT * 100.0 / (CACHE_HIT_COUNT + CACHE_MISS_COUNT) as HIT_RATIO
FROM information_schema.be_index_cache_stats
WHERE INDEX_TYPE = 'PERSISTENT';
```

## 索引选择策略

### 1. 基于数据特征选择

```sql
-- 分析列的基数分布
WITH column_stats AS (
    SELECT 
        'user_id' as column_name,
        COUNT(DISTINCT user_id) as cardinality,
        COUNT(*) as total_rows,
        COUNT(DISTINCT user_id) * 1.0 / COUNT(*) as selectivity
    FROM user_behaviors
    UNION ALL
    SELECT 
        'event_type' as column_name,
        COUNT(DISTINCT event_type) as cardinality,
        COUNT(*) as total_rows,
        COUNT(DISTINCT event_type) * 1.0 / COUNT(*) as selectivity
    FROM user_behaviors
    UNION ALL
    SELECT 
        'ip_address' as column_name,
        COUNT(DISTINCT ip_address) as cardinality,
        COUNT(*) as total_rows,
        COUNT(DISTINCT ip_address) * 1.0 / COUNT(*) as selectivity
    FROM user_behaviors
)
SELECT 
    column_name,
    cardinality,
    selectivity,
    CASE 
        WHEN cardinality < 100 THEN 'Bitmap索引'
        WHEN cardinality > 10000 THEN 'Bloom Filter索引'
        WHEN selectivity > 0.1 THEN 'Bloom Filter索引'
        ELSE 'Bitmap索引'
    END as recommended_index
FROM column_stats;
```

### 2. 基于查询模式选择

```sql
-- 分析查询模式
WITH query_patterns AS (
    SELECT 
        sql_text,
        COUNT(*) as query_count,
        AVG(total_time_ms) as avg_time
    FROM information_schema.query_log
    WHERE sql_text LIKE '%WHERE%'
      AND query_start_time >= DATE_SUB(NOW(), INTERVAL 7 DAY)
    GROUP BY sql_text
)
SELECT 
    sql_text,
    query_count,
    avg_time,
    CASE 
        WHEN sql_text LIKE '%user_id =%' THEN '建议：user_id创建Bloom Filter'
        WHEN sql_text LIKE '%status =%' THEN '建议：status创建Bitmap索引'
        WHEN sql_text LIKE '%LIKE%' THEN '建议：创建倒排索引'
        WHEN sql_text LIKE '%IN (%' THEN '建议：创建Bitmap索引'
        ELSE '分析查询条件'
    END as index_recommendation
FROM query_patterns
WHERE query_count > 5 AND avg_time > 1000  -- 频繁且慢的查询
ORDER BY query_count * avg_time DESC;
```

### 3. 索引组合策略

```sql
-- 复合索引策略示例
CREATE TABLE user_orders_optimized (
    order_id BIGINT,           -- 高基数，主查询字段
    user_id BIGINT,            -- 高基数，频繁查询
    order_status VARCHAR(20),  -- 低基数，频繁过滤
    payment_method VARCHAR(50), -- 中等基数，分析查询
    order_amount DECIMAL(10,2), -- 数值，范围查询
    order_time DATETIME        -- 时间，范围查询
)
DUPLICATE KEY(order_id, user_id, order_time)  -- 前缀索引
PARTITION BY RANGE(order_time) (              -- 分区裁剪
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 32
PROPERTIES (
    -- 组合索引策略
    "bloom_filter_columns" = "order_id,user_id",        -- 高基数等值查询
    "bloom_filter_fpp" = "0.01"
);

-- 为低基数列单独创建Bitmap索引
ALTER TABLE user_orders_optimized SET (
    "bitmap_index_columns" = "order_status,payment_method"
);
```

## 索引性能监控

### 1. 索引使用情况监控

```sql
-- 监控索引效果
CREATE VIEW index_performance AS
SELECT 
    table_name,
    index_name,
    index_type,
    create_time,
    last_analyze_time,
    index_size_mb,
    hit_count,
    miss_count,
    hit_ratio
FROM information_schema.table_indexes 
WHERE table_schema = DATABASE();

-- 分析索引使用效果
SELECT 
    index_type,
    COUNT(*) as index_count,
    AVG(hit_ratio) as avg_hit_ratio,
    SUM(index_size_mb) as total_size_mb
FROM index_performance
GROUP BY index_type;
```

### 2. 查询性能对比

```sql
-- 创建索引性能测试脚本
DELIMITER //
CREATE PROCEDURE test_index_performance()
BEGIN
    DECLARE start_time DATETIME;
    DECLARE end_time DATETIME;
    DECLARE duration_ms INT;
    
    -- 测试无索引性能
    ALTER TABLE test_table SET ("bloom_filter_columns" = "");
    
    SET start_time = NOW(3);
    SELECT COUNT(*) FROM test_table WHERE user_id = 12345;
    SET end_time = NOW(3);
    SET duration_ms = TIMESTAMPDIFF(MICROSECOND, start_time, end_time) / 1000;
    
    INSERT INTO performance_log VALUES ('NO_INDEX', duration_ms, NOW());
    
    -- 测试有索引性能
    ALTER TABLE test_table SET ("bloom_filter_columns" = "user_id");
    WAIT FOR 10;  -- 等待索引生效
    
    SET start_time = NOW(3);  
    SELECT COUNT(*) FROM test_table WHERE user_id = 12345;
    SET end_time = NOW(3);
    SET duration_ms = TIMESTAMPDIFF(MICROSECOND, start_time, end_time) / 1000;
    
    INSERT INTO performance_log VALUES ('WITH_INDEX', duration_ms, NOW());
END //
DELIMITER ;
```

### 3. 索引维护成本分析

```sql
-- 分析索引存储成本
SELECT 
    table_name,
    SUM(CASE WHEN index_type = 'PRIMARY' THEN index_size_mb ELSE 0 END) as primary_index_mb,
    SUM(CASE WHEN index_type = 'BITMAP' THEN index_size_mb ELSE 0 END) as bitmap_index_mb,
    SUM(CASE WHEN index_type = 'BLOOM_FILTER' THEN index_size_mb ELSE 0 END) as bloom_index_mb,
    SUM(CASE WHEN index_type = 'INVERTED' THEN index_size_mb ELSE 0 END) as inverted_index_mb,
    SUM(index_size_mb) as total_index_mb
FROM information_schema.table_indexes
WHERE table_schema = DATABASE()
GROUP BY table_name;

-- 分析索引对写入性能的影响  
SELECT 
    table_name,
    load_count,
    avg_load_time_ms,
    index_count,
    index_count * 100 / avg_load_time_ms as index_overhead_ratio
FROM (
    SELECT 
        table_name,
        COUNT(*) as load_count,
        AVG(duration_ms) as avg_load_time_ms
    FROM load_performance_log 
    GROUP BY table_name
) l
JOIN (
    SELECT 
        table_name,
        COUNT(*) as index_count
    FROM information_schema.table_indexes
    WHERE index_type != 'PRIMARY'
    GROUP BY table_name  
) i USING(table_name);
```

## 索引优化最佳实践

### 1. 索引设计原则

- **高频查询优先**：为经常查询的列创建索引
- **选择合适类型**：根据数据基数选择索引类型
- **避免过度索引**：索引会增加存储和写入成本
- **定期评估效果**：监控索引使用情况，删除无效索引

### 2. 索引维护策略

```sql
-- 定期索引健康检查
CREATE PROCEDURE index_health_check()
BEGIN
    -- 检查未使用的索引
    SELECT 
        table_name,
        index_name,
        index_type,
        create_time,
        last_access_time,
        DATEDIFF(NOW(), last_access_time) as days_since_access
    FROM information_schema.table_indexes
    WHERE last_access_time < DATE_SUB(NOW(), INTERVAL 30 DAY)
      AND index_type != 'PRIMARY';
    
    -- 检查低效索引
    SELECT 
        table_name,
        index_name,
        hit_ratio,
        index_size_mb
    FROM information_schema.table_indexes
    WHERE hit_ratio < 0.1 AND index_size_mb > 100;
END;
```

### 3. 索引优化检查清单

- [ ] 分析表的查询模式和数据分布
- [ ] 为高频查询的等值条件创建索引  
- [ ] 低基数列(<1000)使用Bitmap索引
- [ ] 高基数列(>1000)使用Bloom Filter索引
- [ ] 全文检索需求使用倒排索引
- [ ] 监控索引使用效果和存储成本
- [ ] 定期清理无效索引

## 版本特性对比

### 索引功能演进对照表

| 索引优化特性 | v2.0 | v2.5 | v3.0 | v3.1 | v3.2 | v3.3+ |
|-------------|------|------|------|------|------|-------|
| **前缀索引（自动）** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Bitmap索引** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Bloom Filter索引** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **动态FPP调整** | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **自适应Bloom Filter** | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| **持久化索引（PK表）** | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| **磁盘持久化索引** | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| **倒排索引（GIN）** | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |
| **N-gram Bloom Filter** | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| **中文分词支持** | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| **索引压缩优化** | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ |
| **Page级别索引读取** | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| **索引异步创建** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **索引在线重建** | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |

### 各版本索引限制

| 限制项 | v2.0-2.5 | v3.0 | v3.1 | v3.2+ |
|--------|----------|------|------|-------|
| **Bitmap索引基数限制** | <10000 | <10000 | <100000 | <100000 |
| **Bloom Filter最大列数** | 64 | 64 | 128 | 无限制 |
| **倒排索引字符串长度** | - | - | 32KB | 64KB |
| **N-gram最大gram_num** | - | - | - | 255 |
| **单表最大索引数** | 50 | 100 | 200 | 无限制 |

## 版本选择建议

- **StarRocks 2.0**：支持Bitmap索引和增强Bloom Filter
- **StarRocks 2.5+**：推荐版本，支持动态FPP调整
- **StarRocks 3.0+**：企业级选择，自适应Bloom Filter
- **StarRocks 3.1+**：全文检索需求，支持倒排索引
- **StarRocks 3.2+**：最优选择，完整中文分词和N-gram索引

## 小结

StarRocks索引优化的关键要点：

### 1. 索引类型选择指南

| 数据特征 | 推荐索引 | 版本要求 | 性能提升 |
|---------|---------|----------|----------|
| **排序键查询** | 前缀索引（自动） | 1.19+ | 10-100x |
| **低基数列（<1000）** | Bitmap索引 | 2.0+ | 10-50x |
| **高基数列（>10000）** | Bloom Filter | 1.19+ | 5-20x |
| **模糊查询LIKE '%x%'** | N-gram Bloom Filter | 3.2+ | 10-30x |
| **全文检索** | 倒排索引（GIN） | 3.1+ | 20-100x |
| **Primary Key点查询** | 持久化索引 | 3.0+ | 50-200x |

### 2. 索引组合最佳实践

```sql
-- 综合索引策略示例
CREATE TABLE optimal_table (
    -- 前缀索引（自动）
    date_key DATE,
    user_id BIGINT,
    
    -- 低基数列
    status VARCHAR(20),
    category VARCHAR(50),
    
    -- 高基数列
    order_id VARCHAR(64),
    email VARCHAR(100),
    
    -- 文本列
    description TEXT,
    search_keywords VARCHAR(500),
    
    -- Bitmap索引（低基数）
    INDEX idx_status (status) USING BITMAP,
    INDEX idx_category (category) USING BITMAP,
    
    -- Bloom Filter索引（高基数，在PROPERTIES中配置）
    -- N-gram索引（模糊搜索）
    INDEX idx_keywords_ngram (search_keywords) USING NGRAMBF ("gram_num" = "4"),
    
    -- 倒排索引（全文检索，3.1+）
    INDEX idx_description_gin (description) USING GIN
)
DUPLICATE KEY(date_key, user_id)
PARTITION BY RANGE(date_key) (...)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "bloom_filter_columns" = "order_id,email",
    "bloom_filter_fpp" = "0.01"
);
```

### 3. 性能优化核心原则

1. **层次化索引策略**
   - 分区裁剪 > 前缀索引 > 二级索引 > 全表扫描
   - 优先使用低成本索引

2. **索引成本权衡**
   - 存储成本：倒排索引 > N-gram > Bitmap > Bloom Filter > 前缀索引
   - 写入影响：倒排索引 > N-gram > Bitmap > Bloom Filter > 前缀索引
   - 查询收益：需结合实际场景测试

3. **监控与调优**
   - 定期分析慢查询日志
   - 监控索引命中率和存储开销
   - 根据业务变化动态调整索引策略

4. **版本选择建议**
   - 基础需求：StarRocks 2.5 LTS
   - 全文检索：StarRocks 3.1+
   - 完整特性：StarRocks 3.2+
   - 最新优化：StarRocks 3.3+

正确使用索引组合可以将StarRocks的查询性能提升10-100倍，是OLAP场景下SQL优化的核心手段。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](aggregate-optimization.md) | [➡️ 下一页](../06-advanced-features/materialized-views.md)
---