---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](bucket-design.md) | [➡️ 下一页](data-types-mapping.md)
---

# StarRocks索引设计详解

> **版本要求**：本章节涵盖StarRocks 1.19到3.3+的所有索引特性，建议使用3.2+版本以获得完整功能

## 学习目标

- 深入理解StarRocks各类索引的内部原理和数据结构
- 掌握不同表模型下的索引创建限制和最佳实践
- 学会根据查询模式和数据特征设计索引策略
- 了解索引的存储成本和性能影响

## 一、StarRocks索引体系架构

### 1.1 索引层次结构

StarRocks采用多层次索引体系，从粗粒度到细粒度逐层过滤数据：

```
查询请求
    ↓
[分区裁剪] → 根据分区条件过滤分区
    ↓
[分桶路由] → 根据分桶键定位数据节点
    ↓
[前缀索引] → 利用排序键快速定位数据块
    ↓
[Zone Map] → 根据min/max值过滤数据块
    ↓
[二级索引] → Bitmap/Bloom Filter/倒排索引精确过滤
    ↓
[数据扫描] → 读取实际数据
```

### 1.2 索引分类

#### 自动索引（系统自动创建）
- **前缀索引（Prefix Index）**：基于排序键自动构建
- **Zone Map索引**：每个数据块的min/max统计信息
- **稀疏索引（Sparse Index）**：数据文件的块级索引

#### 手动索引（用户显式创建）
- **Bitmap索引**：低基数列的位图索引
- **Bloom Filter索引**：高基数列的布隆过滤器
- **倒排索引（Inverted Index）**：全文检索索引
- **N-gram Bloom Filter索引**：模糊匹配专用索引

## 二、前缀索引深度解析

### 2.1 前缀索引原理

前缀索引是StarRocks最重要的索引，基于表的排序键（Sort Key）自动构建：

```sql
-- 前缀索引的数据结构示例
CREATE TABLE prefix_index_demo (
    date_col DATE,           -- 排序键1：前缀索引第1列
    user_id BIGINT,         -- 排序键2：前缀索引第2列
    product_id BIGINT,      -- 排序键3：前缀索引第3列
    amount DECIMAL(10,2),
    status VARCHAR(20)
)
DUPLICATE KEY(date_col, user_id, product_id)  -- 定义排序键
DISTRIBUTED BY HASH(user_id) BUCKETS 10;

-- 数据存储布局（按排序键排序）
-- Block 1: [2024-01-01, 1001, 100] ~ [2024-01-01, 1005, 200]
-- Block 2: [2024-01-01, 1005, 201] ~ [2024-01-01, 1010, 150]
-- Block 3: [2024-01-02, 1001, 100] ~ [2024-01-02, 1003, 300]

-- 前缀索引结构（Short Key Index）
-- 索引项1: [2024-01-01, 1001, 100] → Block 1
-- 索引项2: [2024-01-01, 1005, 201] → Block 2
-- 索引项3: [2024-01-02, 1001, 100] → Block 3
```

### 2.2 前缀索引优化技巧

```sql
-- ✅ 优秀的前缀索引设计
CREATE TABLE orders_optimized (
    order_date DATE,         -- 高频过滤条件，放第1位
    region VARCHAR(20),      -- 中等基数，常用过滤，放第2位
    order_id BIGINT,        -- 唯一标识，放第3位
    customer_id BIGINT,
    amount DECIMAL(10,2)
)
DUPLICATE KEY(order_date, region, order_id)
PARTITION BY RANGE(order_date) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 32;

-- 查询1：完美利用前缀索引
SELECT * FROM orders_optimized 
WHERE order_date = '2024-01-15' AND region = 'North';
-- 索引效率：★★★★★

-- 查询2：部分利用前缀索引
SELECT * FROM orders_optimized WHERE order_date = '2024-01-15';
-- 索引效率：★★★★☆

-- 查询3：无法利用前缀索引
SELECT * FROM orders_optimized WHERE region = 'North';
-- 索引效率：☆☆☆☆☆（全表扫描）
```

### 2.3 前缀索引长度限制

```sql
-- 前缀索引的长度限制
-- 默认前缀索引长度：36字节
-- 可通过short_key_column_count参数调整

CREATE TABLE custom_prefix_index (
    col1 VARCHAR(20),    -- 20字节
    col2 VARCHAR(20),    -- 20字节
    col3 BIGINT,        -- 8字节
    col4 INT,           -- 4字节
    col5 VARCHAR(100)
)
DUPLICATE KEY(col1, col2, col3, col4, col5)
DISTRIBUTED BY HASH(col3) BUCKETS 10
PROPERTIES (
    "short_key_column_count" = "3"  -- 只对前3列建立前缀索引
);
```

## 三、Bitmap索引完整指南

### 3.1 Bitmap索引数据结构

Bitmap索引使用位图来表示数据的存在性：

```sql
-- Bitmap索引示例
CREATE TABLE bitmap_demo (
    id BIGINT,
    gender VARCHAR(10),      -- 只有'M'和'F'两个值
    age_group VARCHAR(20),   -- '0-18', '19-30', '31-50', '50+'
    city VARCHAR(50),        -- 约100个城市
    INDEX idx_gender (gender) USING BITMAP,
    INDEX idx_age_group (age_group) USING BITMAP,
    INDEX idx_city (city) USING BITMAP
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;

-- Bitmap索引内部结构
-- gender='M': [1,0,1,1,0,1,0,1,1,1,...]  -- 1表示该行gender='M'
-- gender='F': [0,1,0,0,1,0,1,0,0,0,...]  -- 1表示该行gender='F'

-- 查询时的位运算
-- WHERE gender='M' AND age_group='19-30'
-- Result = Bitmap(gender='M') AND Bitmap(age_group='19-30')
```

### 3.2 Bitmap索引适用场景分析

```sql
-- 场景1：低基数列（推荐）
CREATE TABLE user_profile (
    user_id BIGINT,
    gender VARCHAR(10),           -- 2个值：适合Bitmap
    user_level VARCHAR(20),       -- 5个等级：适合Bitmap
    province VARCHAR(50),         -- 34个省份：适合Bitmap
    is_vip BOOLEAN,              -- 2个值：适合Bitmap
    age INT,                     -- 100+个值：考虑其他索引
    email VARCHAR(100),          -- 高基数：不适合Bitmap
    INDEX idx_gender (gender) USING BITMAP,
    INDEX idx_level (user_level) USING BITMAP,
    INDEX idx_province (province) USING BITMAP,
    INDEX idx_vip (is_vip) USING BITMAP
)
DUPLICATE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 32;

-- 场景2：组合查询优化
-- Bitmap索引特别适合多个低基数列的组合查询
SELECT COUNT(*) FROM user_profile 
WHERE gender = 'F' 
  AND user_level = 'Gold' 
  AND province = '北京'
  AND is_vip = true;
-- 4个Bitmap索引位运算，性能极佳
```

### 3.3 Bitmap索引限制和注意事项

```sql
-- 表模型限制
-- Duplicate Key表：所有列都可创建Bitmap索引
-- Aggregate Key表：只能对Key列创建Bitmap索引
-- Unique Key表：只能对Key列创建Bitmap索引
-- Primary Key表：所有列都可创建Bitmap索引

-- Aggregate表示例（有限制）
CREATE TABLE sales_agg (
    date_key DATE,
    product_id BIGINT,
    store_id INT,
    sales_amount DECIMAL(10,2) SUM,    -- Value列，不能创建Bitmap索引
    quantity INT SUM,                   -- Value列，不能创建Bitmap索引
    INDEX idx_store (store_id) USING BITMAP  -- Key列，可以创建
)
AGGREGATE KEY(date_key, product_id, store_id)
DISTRIBUTED BY HASH(product_id) BUCKETS 10;
```

## 四、Bloom Filter索引深入理解

### 4.1 Bloom Filter原理和特性

Bloom Filter是一种概率型数据结构，用于快速判断元素是否**可能存在**：

```sql
-- Bloom Filter索引创建
CREATE TABLE bloom_filter_demo (
    order_id VARCHAR(64),        -- 高基数，适合Bloom Filter
    user_id BIGINT,             -- 高基数，适合Bloom Filter
    product_sku VARCHAR(50),    -- 中高基数，适合Bloom Filter
    order_time DATETIME,
    amount DECIMAL(10,2)
)
DUPLICATE KEY(order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 32
PROPERTIES (
    "bloom_filter_columns" = "order_id,user_id,product_sku",
    "bloom_filter_fpp" = "0.01"  -- False Positive Probability 1%
);

-- FPP（假阳性率）与存储开销关系
-- FPP = 0.001 (0.1%)：每个值约需要14.4 bits，高精度，存储开销大
-- FPP = 0.01  (1%)：每个值约需要9.6 bits，平衡选择
-- FPP = 0.05  (5%)：每个值约需要6.2 bits，低精度，存储开销小
```

### 4.2 Bloom Filter查询优化原理

```sql
-- Bloom Filter工作流程
-- 1. 构建阶段：对每个唯一值计算多个哈希函数，设置对应位
-- 2. 查询阶段：计算查询值的哈希，检查对应位是否都为1

-- 查询示例
SELECT * FROM bloom_filter_demo WHERE user_id = 123456789;

-- 执行流程：
-- Step 1: 计算user_id=123456789的哈希值
-- Step 2: 检查Bloom Filter对应位
-- Step 3: 如果任一位为0 → 数据肯定不存在，跳过该数据块
-- Step 4: 如果所有位都为1 → 数据可能存在，扫描数据块
```

### 4.3 Bloom Filter与其他索引对比

```sql
-- 创建测试表对比不同索引效果
CREATE TABLE index_comparison (
    id BIGINT,
    low_card_col VARCHAR(20),    -- 低基数：10个不同值
    high_card_col VARCHAR(100),  -- 高基数：100万个不同值
    INDEX idx_bitmap (low_card_col) USING BITMAP,
    INDEX idx_bloom (high_card_col) USING BLOOM  -- 注：实际语法使用PROPERTIES
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 32
PROPERTIES (
    "bloom_filter_columns" = "high_card_col"
);

-- 查询性能对比
-- 低基数列查询
EXPLAIN SELECT * FROM index_comparison WHERE low_card_col = 'value1';
-- Bitmap索引：精确过滤，无假阳性

-- 高基数列查询
EXPLAIN SELECT * FROM index_comparison WHERE high_card_col = 'unique_value_12345';
-- Bloom Filter：快速过滤，可能有1%假阳性
```

## 五、倒排索引（GIN）全面解析

### 5.1 倒排索引结构和原理

倒排索引（Generalized Inverted Index）将文本拆分为词项并建立词项到文档的映射：

```sql
-- 创建支持中文分词的倒排索引
CREATE TABLE document_search (
    doc_id BIGINT,
    title VARCHAR(500),
    content TEXT,
    tags VARCHAR(200),
    author VARCHAR(100),
    publish_date DATE,
    -- 创建倒排索引
    INDEX idx_title_gin (title) USING GIN 
    PROPERTIES(
        "parser" = "chinese",           -- 中文分词器
        "parser_mode" = "fine_grained", -- 细粒度分词
        "support_phrase" = "true"       -- 支持短语搜索
    ),
    INDEX idx_content_gin (content) USING GIN 
    PROPERTIES(
        "parser" = "chinese",
        "parser_mode" = "coarse_grained", -- 粗粒度分词
        "char_filter" = "html_strip"      -- 过滤HTML标签
    )
)
DUPLICATE KEY(doc_id)
DISTRIBUTED BY HASH(doc_id) BUCKETS 10;

-- 倒排索引内部结构示例
-- 文档内容："StarRocks是高性能分析数据库"
-- 分词结果：["StarRocks", "高性能", "分析", "数据库"]
-- 倒排索引：
-- "StarRocks" → [doc1, doc5, doc9, ...]
-- "高性能"    → [doc1, doc3, doc7, ...]
-- "分析"      → [doc1, doc2, doc4, ...]
-- "数据库"    → [doc1, doc6, doc8, ...]
```

### 5.2 倒排索引查询语法

```sql
-- 1. 基础全文搜索
SELECT * FROM document_search 
WHERE match(content, 'StarRocks 性能优化');

-- 2. 短语匹配（精确顺序）
SELECT * FROM document_search 
WHERE match_phrase(content, 'StarRocks 数据库');

-- 3. 布尔查询
SELECT * FROM document_search 
WHERE match(content, 'StarRocks AND 优化 NOT MySQL');

-- 4. 通配符查询
SELECT * FROM document_search 
WHERE match(title, 'Star*');

-- 5. 正则表达式查询
SELECT * FROM document_search 
WHERE regexp_match(content, '(分析|处理).*数据库');

-- 6. 相关性评分
SELECT doc_id, 
       title,
       match_score(content, 'StarRocks OLAP') as relevance_score
FROM document_search 
WHERE match(content, 'StarRocks OLAP')
ORDER BY relevance_score DESC
LIMIT 10;
```

### 5.3 分词器配置详解

```sql
-- 不同语言的分词器配置
CREATE TABLE multilingual_search (
    id BIGINT,
    chinese_text TEXT,
    english_text TEXT,
    mixed_text TEXT,
    
    -- 中文分词器
    INDEX idx_cn (chinese_text) USING GIN 
    PROPERTIES(
        "parser" = "chinese",
        "parser_mode" = "fine_grained",  -- 细粒度：更多分词结果
        "support_phrase" = "true"
    ),
    
    -- 英文分词器
    INDEX idx_en (english_text) USING GIN 
    PROPERTIES(
        "parser" = "english",
        "lower_case" = "true",          -- 转换为小写
        "remove_stopwords" = "true",    -- 移除停用词(the, a, an等)
        "stem" = "true"                 -- 词干提取(running→run)
    ),
    
    -- Unicode分词器（混合内容）
    INDEX idx_mixed (mixed_text) USING GIN 
    PROPERTIES(
        "parser" = "unicode",
        "min_gram" = "2",               -- 最小gram长度
        "max_gram" = "4"                -- 最大gram长度
    )
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;
```

## 六、N-gram Bloom Filter索引专题

### 6.1 N-gram索引原理

N-gram Bloom Filter是专门优化LIKE '%keyword%'查询的索引：

```sql
-- N-gram索引创建和配置
CREATE TABLE ngram_search (
    id BIGINT,
    product_name VARCHAR(200),
    description TEXT,
    search_keywords VARCHAR(500),
    
    -- 创建不同gram_num的N-gram索引
    INDEX idx_name_ngram3 (product_name) USING NGRAMBF (
        "gram_num" = "3",              -- 3-gram，适合短关键词
        "bloom_filter_fpp" = "0.01"
    ),
    INDEX idx_desc_ngram4 (description) USING NGRAMBF (
        "gram_num" = "4",              -- 4-gram，默认值
        "bloom_filter_fpp" = "0.05"
    ),
    INDEX idx_keywords_ngram5 (search_keywords) USING NGRAMBF (
        "gram_num" = "5",              -- 5-gram，适合长关键词
        "bloom_filter_fpp" = "0.01"
    )
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;

-- N-gram工作原理
-- 文本："StarRocks"，gram_num=3
-- 生成的3-grams：["Sta", "tar", "arR", "rRo", "Roc", "ock", "cks"]
-- 查询LIKE '%Rock%'时，生成["Roc", "ock"]，检查Bloom Filter
```

### 6.2 gram_num参数选择策略

```sql
-- gram_num选择指南测试
CREATE TABLE ngram_test (
    id BIGINT,
    short_text VARCHAR(50),     -- 平均长度10-20字符
    medium_text VARCHAR(200),   -- 平均长度50-100字符
    long_text TEXT,             -- 平均长度200+字符
    
    -- 根据文本长度选择合适的gram_num
    INDEX idx_short (short_text) USING NGRAMBF ("gram_num" = "2"),
    INDEX idx_medium (medium_text) USING NGRAMBF ("gram_num" = "3"),
    INDEX idx_long (long_text) USING NGRAMBF ("gram_num" = "4")
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;

-- gram_num影响分析
-- gram_num = 2：索引大，精度高，适合短文本和短关键词搜索
-- gram_num = 3：平衡选择，适合中等长度文本
-- gram_num = 4：默认值，适合大多数场景
-- gram_num = 5+：索引小，可能漏检，适合长文本和长关键词
```

### 6.3 N-gram与倒排索引选择

```sql
-- 场景对比：何时使用N-gram vs 倒排索引
CREATE TABLE search_comparison (
    id BIGINT,
    sku_code VARCHAR(50),       -- 产品编码，适合N-gram
    product_desc TEXT,          -- 产品描述，适合倒排索引
    user_comment TEXT,          -- 用户评论，适合倒排索引
    
    -- N-gram索引：适合编码、ID等非自然语言文本
    INDEX idx_sku_ngram (sku_code) USING NGRAMBF ("gram_num" = "3"),
    
    -- 倒排索引：适合自然语言文本
    INDEX idx_desc_gin (product_desc) USING GIN,
    INDEX idx_comment_gin (user_comment) USING GIN
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 10;

-- 查询示例
-- N-gram索引优势场景
SELECT * FROM search_comparison WHERE sku_code LIKE '%ABC123%';

-- 倒排索引优势场景
SELECT * FROM search_comparison WHERE match(product_desc, '高性能 数据库');
```

## 七、持久化索引（Primary Key表专属）

### 7.1 持久化索引架构

Primary Key表的持久化索引是StarRocks 3.0+的重要特性：

```sql
-- 创建带持久化索引的Primary Key表
CREATE TABLE realtime_user_profile (
    user_id BIGINT NOT NULL,
    username VARCHAR(50),
    email VARCHAR(100),
    phone VARCHAR(20),
    last_login DATETIME,
    account_balance DECIMAL(15,2),
    PRIMARY KEY(user_id)
)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    "enable_persistent_index" = "true",        -- 启用持久化索引
    "persistent_index_type" = "LOCAL",         -- 本地磁盘存储
    "compression_type" = "LZ4",                -- 索引压缩
    "replicated_storage" = "true",             -- 多副本存储
    "replication_num" = "3"                    -- 3副本
);

-- 持久化索引的优势
-- 1. 内存占用降低90%+
-- 2. 重启恢复快速
-- 3. 支持更大数据量的Primary Key表
-- 4. 点查询性能稳定
```

### 7.2 持久化索引性能调优

```sql
-- BE节点配置优化（be.conf）
-- 持久化索引缓存配置
persistent_index_page_cache_capacity = 10GB      -- 页缓存大小
persistent_index_meta_cache_capacity = 2GB       -- 元数据缓存
persistent_index_bloom_filter_fpp = 0.05        -- Bloom Filter精度

-- 监控持久化索引性能
SELECT 
    BE_ID,
    TABLE_NAME,
    INDEX_MEM_USAGE_MB,
    INDEX_DISK_USAGE_MB,
    CACHE_HIT_RATIO,
    AVG_LOOKUP_TIME_US
FROM system.persistent_index_stats
WHERE TABLE_NAME = 'realtime_user_profile';

-- 查询计划验证
EXPLAIN ANALYZE
SELECT * FROM realtime_user_profile WHERE user_id = 12345;
-- 检查是否使用PersistentIndexLookup
```

## 八、索引设计最佳实践

### 8.1 综合索引策略模板

```sql
-- 企业级OLAP表索引设计模板
CREATE TABLE enterprise_fact_table (
    -- 时间维度（分区键+前缀索引）
    date_key DATE NOT NULL,
    hour_key TINYINT,
    
    -- 高频过滤维度（前缀索引）
    region_code VARCHAR(10),
    channel_id INT,
    
    -- 业务主键（高基数）
    order_id VARCHAR(64),
    user_id BIGINT,
    product_id BIGINT,
    
    -- 低基数维度
    order_status VARCHAR(20),
    payment_method VARCHAR(30),
    user_level VARCHAR(10),
    
    -- 文本搜索字段
    product_name VARCHAR(200),
    search_keywords TEXT,
    
    -- 度量值
    order_amount DECIMAL(15,2),
    quantity INT,
    
    -- Bitmap索引（低基数）
    INDEX idx_status (order_status) USING BITMAP,
    INDEX idx_payment (payment_method) USING BITMAP,
    INDEX idx_level (user_level) USING BITMAP,
    
    -- N-gram索引（模糊搜索）
    INDEX idx_product_ngram (product_name) USING NGRAMBF ("gram_num" = "3"),
    
    -- 倒排索引（全文搜索，3.1+）
    INDEX idx_keywords_gin (search_keywords) USING GIN
)
DUPLICATE KEY(date_key, hour_key, region_code, channel_id)
PARTITION BY RANGE(date_key) (
    PARTITION p202401 VALUES [('2024-01-01'), ('2024-02-01')),
    PARTITION p202402 VALUES [('2024-02-01'), ('2024-03-01'))
)
DISTRIBUTED BY HASH(order_id) BUCKETS 64
PROPERTIES (
    -- Bloom Filter索引（高基数）
    "bloom_filter_columns" = "order_id,user_id,product_id",
    "bloom_filter_fpp" = "0.01",
    
    -- 压缩算法
    "compression" = "LZ4",
    
    -- 副本数
    "replication_num" = "3"
);
```

### 8.2 索引选择决策树

```sql
-- 索引选择决策流程
/*
1. 判断列的查询模式
   ├─ 等值查询（=, IN）
   │   ├─ 基数 < 1000 → Bitmap索引
   │   └─ 基数 > 1000 → Bloom Filter索引
   ├─ 范围查询（>, <, BETWEEN）
   │   └─ 考虑作为前缀索引列
   ├─ 模糊查询（LIKE '%x%'）
   │   ├─ 自然语言文本 → 倒排索引(GIN)
   │   └─ 编码/ID类文本 → N-gram Bloom Filter
   └─ 全文搜索（match, match_phrase）
       └─ 倒排索引(GIN)

2. 判断表模型限制
   ├─ Duplicate Key表 → 所有列都可建索引
   ├─ Aggregate/Unique Key表 → 只能对Key列建索引
   └─ Primary Key表 → 所有列可建索引 + 持久化索引

3. 评估成本收益
   ├─ 查询频率：高频查询列优先建索引
   ├─ 过滤效果：选择性高的列优先
   └─ 存储成本：控制索引总大小 < 原始数据的30%
*/

-- 实际案例：电商订单表索引设计
CREATE TABLE ecommerce_orders (
    -- 前缀索引设计（按查询频率排序）
    order_date DATE,            -- 查询频率：90%
    seller_id INT,             -- 查询频率：70%
    order_id BIGINT,           -- 查询频率：50%
    
    -- 其他列
    buyer_id BIGINT,           -- 高基数：Bloom Filter
    order_status VARCHAR(20),  -- 低基数：Bitmap
    category VARCHAR(50),      -- 低基数：Bitmap
    product_title VARCHAR(200),-- 文本搜索：N-gram
    
    -- 创建索引
    INDEX idx_status (order_status) USING BITMAP,
    INDEX idx_category (category) USING BITMAP,
    INDEX idx_title_ngram (product_title) USING NGRAMBF ("gram_num" = "3")
)
DUPLICATE KEY(order_date, seller_id, order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 32
PROPERTIES (
    "bloom_filter_columns" = "buyer_id"
);
```

### 8.3 索引维护和监控

```sql
-- 1. 索引使用率监控
CREATE VIEW index_usage_stats AS
SELECT 
    table_name,
    index_name,
    index_type,
    used_count,
    last_used_time,
    CASE 
        WHEN used_count = 0 THEN '未使用'
        WHEN used_count < 10 THEN '低频使用'
        WHEN used_count < 100 THEN '中频使用'
        ELSE '高频使用'
    END as usage_level
FROM information_schema.index_stats
WHERE table_schema = DATABASE()
ORDER BY used_count DESC;

-- 2. 索引存储成本分析
SELECT 
    table_name,
    SUM(CASE WHEN index_type = 'BITMAP' THEN size_mb ELSE 0 END) as bitmap_mb,
    SUM(CASE WHEN index_type = 'BLOOM' THEN size_mb ELSE 0 END) as bloom_mb,
    SUM(CASE WHEN index_type = 'GIN' THEN size_mb ELSE 0 END) as gin_mb,
    SUM(CASE WHEN index_type = 'NGRAM' THEN size_mb ELSE 0 END) as ngram_mb,
    SUM(size_mb) as total_index_mb,
    data_size_mb,
    SUM(size_mb) * 100.0 / data_size_mb as index_ratio
FROM information_schema.table_stats
GROUP BY table_name, data_size_mb
HAVING index_ratio > 30;  -- 索引占比超过30%需要优化

-- 3. 定期清理无效索引
-- 删除30天未使用的索引
SELECT CONCAT('ALTER TABLE ', table_name, ' DROP INDEX ', index_name, ';') as drop_sql
FROM information_schema.index_stats
WHERE DATEDIFF(NOW(), last_used_time) > 30
  AND index_type != 'PRIMARY';
```

## 九、版本升级指南

### 9.1 索引功能版本兼容性

```sql
-- 版本升级时的索引迁移策略

-- StarRocks 2.x → 3.x 升级
-- 1. Bitmap和Bloom Filter索引自动兼容
-- 2. 需要重新创建倒排索引（3.1+新增）
-- 3. 需要重新创建N-gram索引（3.2+新增）

-- 升级前备份索引定义
SELECT 
    CONCAT('-- Table: ', table_name) as comment,
    GROUP_CONCAT(
        CASE 
            WHEN index_type = 'BITMAP' THEN 
                CONCAT('INDEX ', index_name, ' (', column_name, ') USING BITMAP')
            WHEN index_type = 'BLOOM' THEN 
                CONCAT('"bloom_filter_columns" = "', column_name, '"')
        END SEPARATOR ',\n'
    ) as index_definitions
FROM information_schema.statistics
WHERE table_schema = DATABASE()
GROUP BY table_name;

-- 升级后重建高级索引
-- 3.1+版本：添加倒排索引
ALTER TABLE your_table ADD INDEX idx_text_gin (text_column) USING GIN;

-- 3.2+版本：添加N-gram索引
ALTER TABLE your_table ADD INDEX idx_ngram (varchar_column) USING NGRAMBF ("gram_num" = "4");
```

### 9.2 性能基准测试

```sql
-- 索引性能基准测试框架
CREATE TABLE index_benchmark (
    id BIGINT,
    low_card VARCHAR(20),     -- 10个不同值
    medium_card VARCHAR(100), -- 1000个不同值
    high_card VARCHAR(200),   -- 100万个不同值
    text_field TEXT,          -- 长文本
    INDEX idx_bitmap (low_card) USING BITMAP,
    INDEX idx_ngram (medium_card) USING NGRAMBF ("gram_num" = "3")
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 32
PROPERTIES (
    "bloom_filter_columns" = "high_card"
);

-- 插入测试数据（1000万行）
-- ...

-- 性能测试查询
-- Test 1: Bitmap索引
SELECT COUNT(*) FROM index_benchmark WHERE low_card = 'value1';

-- Test 2: Bloom Filter索引
SELECT COUNT(*) FROM index_benchmark WHERE high_card = 'unique_123456';

-- Test 3: N-gram索引
SELECT COUNT(*) FROM index_benchmark WHERE medium_card LIKE '%keyword%';

-- Test 4: 组合索引
SELECT COUNT(*) FROM index_benchmark 
WHERE low_card = 'value1' 
  AND high_card = 'unique_123456'
  AND medium_card LIKE '%keyword%';
```

## 十、常见问题和解决方案

### 10.1 索引创建失败

```sql
-- 问题1：Aggregate表无法对Value列创建索引
-- 错误信息：Cannot create bitmap index on value column
-- 解决方案：只对Key列创建索引，或改用Duplicate Key模型

-- 问题2：索引创建超时
-- 解决方案：增加超时时间
SET query_timeout = 3600;  -- 设置为1小时
ALTER TABLE large_table ADD INDEX idx_col (column) USING BITMAP;

-- 问题3：索引占用过多内存
-- 解决方案：调整索引缓存配置
-- be.conf配置
bitmap_index_cache_capacity = 2GB
bloom_filter_index_cache_capacity = 1GB
```

### 10.2 查询未使用索引

```sql
-- 诊断查询是否使用索引
SET enable_profile = true;
SELECT * FROM your_table WHERE your_column = 'value';

-- 查看Profile中的索引使用情况
SHOW PROFILE;

-- 常见原因和解决方案
-- 1. 数据分布不均：重新分析表统计信息
ANALYZE TABLE your_table;

-- 2. 索引选择性太低：检查索引列的基数
SELECT COUNT(DISTINCT your_column) FROM your_table;

-- 3. 查询条件不匹配：确保查询条件与索引类型匹配
-- Bitmap索引：使用 = 或 IN
-- Bloom Filter：使用 = 
-- N-gram：使用 LIKE '%keyword%'
```

## 小结

StarRocks索引设计的核心原则：

1. **层次化过滤**：分区 → 分桶 → 前缀索引 → 二级索引
2. **索引类型匹配**：根据数据基数和查询模式选择合适的索引
3. **成本效益平衡**：索引带来的查询提升要大于存储和维护成本
4. **版本特性利用**：充分利用新版本的索引特性
5. **持续优化**：定期监控和调整索引策略

正确的索引设计可以将查询性能提升10-100倍，是StarRocks性能优化的关键。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](bucket-design.md) | [➡️ 下一页](data-types-mapping.md)
---