---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](big-data-ecosystem.md) | [➡️ 下一页](../07-best-practices/oracle-migration-best-practices.md)
---

# StarRocks执行引擎深度解析

> **版本要求**：本章节深入剖析StarRocks 3.0+的执行引擎，建议使用3.1+版本以获得完整的Pipeline执行特性

## 学习目标

- 通过一个复杂SQL实例，深入理解StarRocks的查询执行全流程
- 掌握Fragment划分、并行执行、数据交换的核心原理
- 理解Pipeline执行模型和向量化执行的技术细节
- 了解执行优化技术和性能调优方法

## 一、复杂SQL示例设计

让我们通过一个真实的电商分析场景，设计一个涵盖多种执行特性的复杂SQL：

```sql
-- 业务场景：分析2024年1月各城市VIP用户的购买行为和商品偏好
-- 涉及特性：多表Join、聚合、窗口函数、子查询、CTE

WITH user_city_stats AS (
    -- CTE1: 计算各城市VIP用户数量
    SELECT 
        city,
        COUNT(DISTINCT user_id) as vip_user_count,
        AVG(user_level) as avg_user_level
    FROM users
    WHERE is_vip = true 
      AND status = 'ACTIVE'
    GROUP BY city
),
order_metrics AS (
    -- CTE2: 计算订单指标
    SELECT 
        o.user_id,
        o.product_id,
        p.category,
        p.brand,
        o.order_date,
        o.amount,
        o.quantity,
        ROW_NUMBER() OVER (PARTITION BY o.user_id ORDER BY o.amount DESC) as order_rank
    FROM orders o
    INNER JOIN products p ON o.product_id = p.product_id
    WHERE o.order_date BETWEEN '2024-01-01' AND '2024-01-31'
      AND o.status = 'COMPLETED'
)
SELECT 
    u.city,
    ucs.vip_user_count,
    p.category as top_category,
    p.brand as top_brand,
    COUNT(DISTINCT om.user_id) as active_users,
    COUNT(om.order_id) as total_orders,
    SUM(om.amount) as total_revenue,
    AVG(om.amount) as avg_order_value,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY om.amount) as median_order_value,
    SUM(CASE WHEN om.order_rank = 1 THEN om.amount ELSE 0 END) as top_order_revenue
FROM order_metrics om
INNER JOIN users u ON om.user_id = u.user_id
INNER JOIN user_city_stats ucs ON u.city = ucs.city
LEFT JOIN product_reviews pr ON om.product_id = pr.product_id AND om.user_id = pr.user_id
WHERE u.is_vip = true
GROUP BY u.city, ucs.vip_user_count, p.category, p.brand
HAVING COUNT(DISTINCT om.user_id) >= 10
ORDER BY total_revenue DESC
LIMIT 100;
```

## 二、查询解析和优化阶段

### 2.1 SQL解析（Parse）

```
SQL文本
   ↓
[词法分析器 Lexer]
   ↓
Token流：WITH, user_city_stats, AS, (, SELECT, ...
   ↓
[语法分析器 Parser]
   ↓
抽象语法树（AST）
```

StarRocks使用ANTLR生成的Parser解析SQL，构建AST：

```
QueryStatement
├── CTEClause
│   ├── CTE: user_city_stats
│   │   └── SelectStatement
│   └── CTE: order_metrics
│       └── SelectStatement
└── SelectStatement (主查询)
    ├── SelectList
    ├── FromClause
    ├── WhereClause
    ├── GroupByClause
    ├── HavingClause
    ├── OrderByClause
    └── LimitClause
```

### 2.2 语义分析（Analyze）

语义分析阶段验证SQL的正确性并绑定元数据：

```java
// 伪代码展示语义分析过程
class Analyzer {
    void analyze(QueryStatement stmt) {
        // 1. 解析CTE
        analyzeCTEs(stmt.getCTEs());
        
        // 2. 解析FROM子句，构建表引用
        analyzeFrom(stmt.getFromClause());
        
        // 3. 解析JOIN条件
        analyzeJoins(stmt.getJoins());
        
        // 4. 解析WHERE条件
        analyzeWhere(stmt.getWhereClause());
        
        // 5. 解析GROUP BY
        analyzeGroupBy(stmt.getGroupByClause());
        
        // 6. 解析聚合函数
        analyzeAggregates(stmt.getSelectList());
        
        // 7. 解析窗口函数
        analyzeWindowFunctions(stmt.getWindowFunctions());
        
        // 8. 类型推导和检查
        inferAndCheckTypes(stmt);
    }
}
```

### 2.3 查询优化（Optimize）

#### 2.3.1 逻辑优化

StarRocks的逻辑优化器应用各种规则（Rule）优化查询：

```
原始逻辑计划
    ↓
[规则优化器 RBO]
├── 谓词下推（Predicate Pushdown）
├── 列裁剪（Column Pruning）
├── 常量折叠（Constant Folding）
├── 子查询展开（Subquery Unnesting）
├── 外连接消除（Outer Join Elimination）
└── 公共表达式消除（Common Expression Elimination）
    ↓
优化后的逻辑计划
```

具体优化示例：

```sql
-- 谓词下推前
Filter (u.is_vip = true)
  └── Join (om.user_id = u.user_id)
      ├── Scan orders
      └── Scan users

-- 谓词下推后
Join (om.user_id = u.user_id)
  ├── Scan orders
  └── Filter (is_vip = true)
      └── Scan users  -- 过滤条件下推到Scan
```

#### 2.3.2 物理优化（CBO）

基于成本的优化器选择最优的物理执行计划：

```java
// CBO核心流程
class CostBasedOptimizer {
    PhysicalPlan optimize(LogicalPlan logical) {
        // 1. 收集统计信息
        Statistics stats = collectStatistics(logical);
        
        // 2. 枚举可能的Join顺序
        List<JoinOrder> joinOrders = enumerateJoinOrders(logical);
        
        // 3. 选择Join算法
        for (JoinOrder order : joinOrders) {
            // 评估Broadcast Join成本
            double broadcastCost = estimateBroadcastCost(order, stats);
            
            // 评估Shuffle Join成本
            double shuffleCost = estimateShuffleCost(order, stats);
            
            // 评估Colocation Join成本
            double colocationCost = estimateColocationCost(order, stats);
            
            // 选择成本最低的方案
            selectBestJoinMethod(order, broadcastCost, shuffleCost, colocationCost);
        }
        
        // 4. 生成最优物理计划
        return generatePhysicalPlan(bestJoinOrder);
    }
}
```

## 三、物理执行计划生成

### 3.1 Fragment划分

StarRocks将物理计划划分为多个Fragment，每个Fragment可以独立并行执行：

```
完整物理计划
    ↓
Fragment划分规则：
1. 遇到Exchange算子时划分新Fragment
2. 每个Fragment内部的算子在同一个Pipeline中执行
3. Fragment之间通过网络交换数据
    ↓
多个Fragment
```

我们的复杂SQL会被划分为以下Fragment：

```
Fragment 0 (Coordinator Fragment)
├── Limit 100
├── Sort (total_revenue DESC)
└── Exchange (GATHER)

Fragment 1 (Aggregation Fragment)
├── Aggregate (GROUP BY city, category, brand)
├── Having (active_users >= 10)
├── Hash Join (om.user_id = u.user_id)
│   ├── Exchange (SHUFFLE by user_id)
│   └── Exchange (SHUFFLE by user_id)

Fragment 2 (Order Metrics Fragment)
├── Project
├── Window Function (ROW_NUMBER)
├── Hash Join (o.product_id = p.product_id)
│   ├── Exchange (BROADCAST)
│   └── Scan orders (with predicates)

Fragment 3 (User Stats Fragment)
├── Aggregate (GROUP BY city)
├── Filter (is_vip = true AND status = 'ACTIVE')
└── Scan users

Fragment 4 (Product Fragment)
├── Project
└── Scan products

Fragment 5 (Review Fragment)
├── Project
└── Scan product_reviews
```

### 3.2 Fragment实例化

每个Fragment会在多个BE节点上创建多个实例并行执行：

```java
// Fragment实例化过程
class FragmentExecutor {
    void executeFragment(Fragment fragment, int parallelism) {
        // 1. 计算并行度
        int dop = calculateDOP(fragment, parallelism);
        
        // 2. 分配执行节点
        List<Backend> backends = selectBackends(fragment, dop);
        
        // 3. 创建Fragment实例
        for (int i = 0; i < dop; i++) {
            Backend backend = backends.get(i % backends.size());
            FragmentInstance instance = new FragmentInstance(
                fragment, 
                i,           // instance_id
                backend,     // 执行节点
                dop          // 总并行度
            );
            
            // 4. 发送到BE执行
            backend.executeInstance(instance);
        }
    }
    
    int calculateDOP(Fragment fragment, int requestedParallelism) {
        // 基于数据量、表的Tablet数量、系统资源等计算
        int dataSize = fragment.estimateDataSize();
        int tabletCount = fragment.getTabletCount();
        int availableCores = getAvailableCores();
        
        return Math.min(
            requestedParallelism,
            Math.min(tabletCount, availableCores)
        );
    }
}
```

## 四、Pipeline执行模型

### 4.1 Pipeline概念

StarRocks 2.5+引入了Pipeline执行模型，将算子组织成Pipeline：

```
传统火山模型 vs Pipeline模型

火山模型（拉取模式）：
┌─────────┐
│  Limit  │ ← next()
└────┬────┘
     │
┌────┴────┐
│  Sort   │ ← next()
└────┬────┘
     │
┌────┴────┐
│Aggregate│ ← next()
└────┬────┘
     │
┌────┴────┐
│  Join   │ ← next()
└────┬────┘

Pipeline模型（推送模式）：
Pipeline 1: Scan → Filter → Build HashTable
Pipeline 2: Scan → Probe HashTable → Aggregate → Sort → Limit
```

### 4.2 Pipeline构建

```java
// Pipeline构建算法
class PipelineBuilder {
    List<Pipeline> buildPipelines(Fragment fragment) {
        List<Pipeline> pipelines = new ArrayList<>();
        
        // 1. 识别Pipeline breaker（阻塞算子）
        List<Operator> breakers = findPipelineBreakers(fragment);
        // Breakers: HashJoinBuild, Sort, Aggregate(需要全量数据)
        
        // 2. 根据breaker划分Pipeline
        Pipeline currentPipeline = new Pipeline();
        for (Operator op : fragment.getOperators()) {
            if (breakers.contains(op)) {
                // 遇到breaker，结束当前Pipeline
                pipelines.add(currentPipeline);
                currentPipeline = new Pipeline();
            }
            currentPipeline.addOperator(op);
        }
        pipelines.add(currentPipeline);
        
        // 3. 设置Pipeline依赖关系
        setPipelineDependencies(pipelines);
        
        return pipelines;
    }
}
```

### 4.3 Pipeline执行

```java
// Pipeline执行器
class PipelineExecutor {
    void executePipeline(Pipeline pipeline) {
        // 1. 初始化Pipeline驱动器
        List<PipelineDriver> drivers = createDrivers(pipeline);
        
        // 2. 并发执行drivers
        ThreadPool executor = getThreadPool();
        for (PipelineDriver driver : drivers) {
            executor.submit(() -> {
                while (!driver.isFinished()) {
                    // 3. 执行一个chunk的数据
                    Chunk chunk = driver.pullChunk();
                    
                    // 4. 逐个算子处理
                    for (Operator op : pipeline.getOperators()) {
                        chunk = op.process(chunk);
                        if (chunk == null) break; // 被过滤掉
                    }
                    
                    // 5. 输出到下一个Pipeline或结果集
                    if (chunk != null) {
                        driver.pushChunk(chunk);
                    }
                }
            });
        }
    }
}
```

## 五、向量化执行

### 5.1 向量化原理

StarRocks采用列式存储和向量化执行，一次处理一批数据（Chunk）：

```cpp
// 传统行式执行 vs 向量化执行

// 行式执行（逐行处理）
for (int i = 0; i < rows.size(); i++) {
    Row row = rows[i];
    if (row.age > 25) {  // 分支预测开销
        result.add(row);
    }
}

// 向量化执行（批量处理）
class VectorizedFilter {
    Chunk process(Chunk input) {
        // 1. 获取列向量
        ColumnVector ageColumn = input.getColumn("age");
        
        // 2. SIMD批量比较
        BitmapVector selection = SIMD::greater_than(
            ageColumn.getData(),  // int32_t数组
            25,                   // 常量
            ageColumn.size()      // 向量长度
        );
        
        // 3. 根据selection过滤
        return input.filter(selection);
    }
}
```

### 5.2 SIMD优化

利用CPU的SIMD指令集加速计算：

```cpp
// AVX2指令集示例：批量计算 amount * quantity
void vectorizedMultiply(
    const double* amount,    // 金额数组
    const int32_t* quantity, // 数量数组
    double* result,          // 结果数组
    size_t size
) {
    size_t simd_size = size - (size % 4);  // AVX2一次处理4个double
    
    for (size_t i = 0; i < simd_size; i += 4) {
        // 加载数据到256位寄存器
        __m256d amt = _mm256_loadu_pd(&amount[i]);
        __m256i qty = _mm256_loadu_si256((__m256i*)&quantity[i]);
        
        // 转换int到double
        __m256d qty_d = _mm256_cvtepi32_pd(qty);
        
        // SIMD乘法
        __m256d res = _mm256_mul_pd(amt, qty_d);
        
        // 存储结果
        _mm256_storeu_pd(&result[i], res);
    }
    
    // 处理剩余元素
    for (size_t i = simd_size; i < size; i++) {
        result[i] = amount[i] * quantity[i];
    }
}
```

### 5.3 向量化聚合

```cpp
// 向量化GROUP BY聚合
class VectorizedAggregator {
    void aggregate(Chunk input, AggregationState* state) {
        // 1. 计算分组键的Hash
        std::vector<uint32_t> hashes(input.numRows());
        for (auto& key_column : group_by_columns) {
            key_column->updateHash(hashes);
        }
        
        // 2. 查找或创建聚合状态
        for (size_t i = 0; i < input.numRows(); i++) {
            AggState* agg = state->findOrCreate(hashes[i]);
            
            // 3. 批量更新聚合函数
            for (auto& agg_func : agg_functions) {
                agg_func->addBatch(agg, input, i);
            }
        }
    }
    
    // COUNT(DISTINCT)的向量化实现
    void countDistinct(ColumnVector values) {
        // 使用HyperLogLog进行近似计算
        HyperLogLog hll;
        
        // 批量添加
        for (size_t i = 0; i < values.size(); i += BATCH_SIZE) {
            size_t batch_end = std::min(i + BATCH_SIZE, values.size());
            hll.addBatch(values.getData() + i, batch_end - i);
        }
        
        return hll.estimate();
    }
}
```

## 六、数据交换（Exchange）

### 6.1 Exchange类型

```cpp
enum ExchangeType {
    GATHER,      // 汇集到Coordinator
    BROADCAST,   // 广播到所有节点
    HASH_SHUFFLE,// 按Hash分区
    RANDOM,      // 随机分发
    BUCKET       // 按桶分发
};

class ExchangeNode {
    void execute() {
        switch (type) {
            case BROADCAST:
                broadcastData();
                break;
            case HASH_SHUFFLE:
                hashPartition();
                break;
            case GATHER:
                gatherToCoordinator();
                break;
        }
    }
    
    void hashPartition() {
        // 1. 对每行数据计算Hash
        for (Chunk chunk : input_chunks) {
            for (int row = 0; row < chunk.numRows(); row++) {
                uint32_t hash = computeHash(chunk, row, partition_exprs);
                int target_instance = hash % num_instances;
                
                // 2. 发送到目标实例
                sendRow(chunk, row, target_instance);
            }
        }
    }
}
```

### 6.2 网络传输优化

```cpp
// 批量发送和压缩
class DataStreamSender {
private:
    // 每个目标实例的缓冲区
    std::vector<ChunkBuffer> buffers;
    
public:
    void sendChunk(Chunk chunk) {
        // 1. 序列化Chunk
        std::string serialized = serialize(chunk);
        
        // 2. 压缩（LZ4/Snappy）
        std::string compressed = compress(serialized);
        
        // 3. 批量发送
        for (int i = 0; i < num_receivers; i++) {
            buffers[i].add(compressed);
            
            if (buffers[i].size() >= BATCH_SIZE) {
                // 达到批量大小，发送
                sendBatch(i, buffers[i]);
                buffers[i].clear();
            }
        }
    }
    
    // RPC发送
    void sendBatch(int receiver_id, ChunkBuffer& buffer) {
        TransmitDataRequest request;
        request.set_compressed_data(buffer.getData());
        request.set_compression_type(LZ4);
        
        // 异步RPC
        stub->transmitData(request, [](Response resp) {
            // 处理响应
        });
    }
}
```

## 七、Runtime Filter

### 7.1 Runtime Filter原理

Runtime Filter在Join执行时动态生成过滤器，提前过滤数据：

```
Hash Join执行流程：
1. Build阶段：构建Hash表 + 生成Runtime Filter
2. 将Filter下推到Probe端的Scan
3. Probe阶段：使用Filter减少扫描数据
```

### 7.2 Runtime Filter实现

```cpp
class RuntimeFilterGenerator {
    // Join Build阶段生成Filter
    RuntimeFilter* generateFilter(HashTable& hash_table) {
        if (hash_table.size() < MIN_FILTER_SIZE) {
            // 小表使用IN List Filter
            return new InListFilter(hash_table.getKeys());
        } else if (hash_table.size() < MAX_BLOOM_FILTER_SIZE) {
            // 中等大小使用Bloom Filter
            BloomFilter* bf = new BloomFilter(hash_table.size());
            for (auto& key : hash_table) {
                bf->add(key);
            }
            return bf;
        } else {
            // 大表使用Min-Max Filter
            return new MinMaxFilter(
                hash_table.getMin(),
                hash_table.getMax()
            );
        }
    }
    
    // 应用Runtime Filter
    bool applyFilter(RuntimeFilter* filter, Value value) {
        switch (filter->type()) {
            case IN_LIST:
                return static_cast<InListFilter*>(filter)->contains(value);
            case BLOOM_FILTER:
                return static_cast<BloomFilter*>(filter)->mayContain(value);
            case MIN_MAX:
                MinMaxFilter* mmf = static_cast<MinMaxFilter*>(filter);
                return value >= mmf->min && value <= mmf->max;
        }
    }
}
```

## 八、内存管理

### 8.1 内存池管理

```cpp
// Chunk内存池
class ChunkMemoryPool {
private:
    struct ChunkBlock {
        char* data;
        size_t size;
        std::atomic<bool> in_use;
    };
    
    std::vector<ChunkBlock> blocks;
    std::mutex mutex;
    
public:
    Chunk* allocateChunk(size_t num_rows, Schema schema) {
        size_t required_size = calculateSize(num_rows, schema);
        
        // 1. 尝试复用已有块
        for (auto& block : blocks) {
            if (!block.in_use && block.size >= required_size) {
                block.in_use = true;
                return new Chunk(block.data, num_rows, schema);
            }
        }
        
        // 2. 分配新块
        ChunkBlock new_block;
        new_block.data = static_cast<char*>(aligned_alloc(64, required_size));
        new_block.size = required_size;
        new_block.in_use = true;
        
        std::lock_guard<std::mutex> lock(mutex);
        blocks.push_back(new_block);
        
        return new Chunk(new_block.data, num_rows, schema);
    }
    
    void releaseChunk(Chunk* chunk) {
        // 标记为可复用
        for (auto& block : blocks) {
            if (block.data == chunk->getData()) {
                block.in_use = false;
                break;
            }
        }
    }
}
```

### 8.2 内存溢出处理

```cpp
// 大数据量排序的溢出处理
class ExternalSort {
    void sort(std::vector<Chunk>& chunks) {
        size_t total_memory = getTotalMemory(chunks);
        
        if (total_memory <= memory_limit) {
            // 内存足够，直接排序
            inMemorySort(chunks);
        } else {
            // 外部排序
            externalSort(chunks);
        }
    }
    
    void externalSort(std::vector<Chunk>& chunks) {
        // 1. 分批排序并写入磁盘
        std::vector<std::string> sorted_files;
        for (auto& batch : splitIntoBatches(chunks)) {
            inMemorySort(batch);
            std::string file = spillToDisk(batch);
            sorted_files.push_back(file);
        }
        
        // 2. 多路归并
        multiWayMerge(sorted_files);
    }
}
```

## 九、执行监控和调试

### 9.1 执行指标收集

```cpp
// 算子执行统计
class OperatorMetrics {
    std::atomic<uint64_t> input_rows{0};
    std::atomic<uint64_t> output_rows{0};
    std::atomic<uint64_t> filtered_rows{0};
    std::atomic<uint64_t> execution_time_ns{0};
    std::atomic<uint64_t> memory_bytes{0};
    
    void recordExecution(uint64_t start_time, Chunk& input, Chunk& output) {
        input_rows += input.numRows();
        output_rows += output.numRows();
        filtered_rows += input.numRows() - output.numRows();
        execution_time_ns += getCurrentTime() - start_time;
        memory_bytes = getCurrentMemoryUsage();
    }
    
    std::string toString() {
        return fmt::format(
            "InputRows: {}, OutputRows: {}, FilteredRows: {}, "
            "Time: {}ms, Memory: {}MB, FilterRatio: {:.2f}%",
            input_rows.load(),
            output_rows.load(),
            filtered_rows.load(),
            execution_time_ns.load() / 1000000,
            memory_bytes.load() / 1048576,
            filtered_rows * 100.0 / input_rows
        );
    }
}
```

### 9.2 Profile输出示例

```
Query Profile: query_id=20240116_123456_00001
Total Time: 523ms

Fragment 0 (Coordinator)
  └─ RESULT_SINK (id=14)
      │ output: 100 rows
      │ time: 2ms
      └─ TOP-N (id=13)
          │ limit: 100
          │ sort keys: total_revenue DESC
          │ input: 1,250 rows, output: 100 rows
          │ time: 15ms, memory: 2MB
          └─ EXCHANGE (id=12) [GATHER]
              │ hosts: 3
              │ input: 1,250 rows
              │ network: 145KB, time: 8ms

Fragment 1 (Aggregation)
  Pipeline 1:
    └─ AGGREGATE (id=11)
        │ group by: city, category, brand
        │ aggregations: COUNT(DISTINCT user_id), SUM(amount)
        │ input: 45,230 rows, output: 1,250 rows
        │ time: 85ms, memory: 32MB
        │ hash table size: 1,250, load factor: 0.75
        └─ HASH_JOIN (id=10) [INNER]
            │ join keys: om.user_id = u.user_id
            │ runtime filter: RF001 (bloom filter)
            │ input: 125,450 rows, output: 45,230 rows
            │ time: 125ms, memory: 128MB
            │ build rows: 15,230, probe rows: 125,450
            ├─ EXCHANGE (id=9) [SHUFFLE by user_id]
            │   │ input: 125,450 rows
            │   │ partitions: 32
            │   └─ [Fragment 2]
            └─ EXCHANGE (id=8) [SHUFFLE by user_id]
                │ input: 15,230 rows
                └─ [Fragment 3]

Fragment 2 (Order Processing)
  Pipeline 1:
    └─ WINDOW_FUNCTION (id=7)
        │ function: ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY amount DESC)
        │ input: 235,680 rows, output: 235,680 rows
        │ time: 178ms, memory: 256MB
        └─ HASH_JOIN (id=6) [INNER]
            │ join keys: o.product_id = p.product_id
            │ type: BROADCAST
            │ input: 458,230 rows, output: 235,680 rows
            │ time: 95ms, memory: 45MB
            ├─ OLAP_SCAN (id=5) [orders]
            │   │ tablets: 32/32
            │   │ predicates: order_date BETWEEN '2024-01-01' AND '2024-01-31'
            │   │              AND status = 'COMPLETED'
            │   │ runtime filters: RF001, RF002
            │   │ rows: 458,230/1,250,000 (36.66%)
            │   │ time: 125ms
            └─ EXCHANGE (id=4) [BROADCAST]
                │ input: 10,000 rows
                └─ [Fragment 4]

Performance Analysis:
- Bottleneck: Window Function in Fragment 2 (178ms, 34% of total)
- High Memory Usage: Fragment 2 Window Function (256MB)
- Good Filter Effectiveness: Runtime Filter reduced 63.34% rows
- Network Transfer: Total 2.3MB across fragments
- Parallelism: DOP=32 for scan, DOP=16 for join
```

## 十、性能优化技巧

### 10.1 执行计划优化

```sql
-- 1. 使用适当的Hint控制执行策略
SELECT /*+ SET_VAR(pipeline_dop=64) */  -- 增加并行度
       /*+ BROADCAST(small_table) */     -- 强制广播小表
       /*+ LEADING(large_table, medium_table, small_table) */ -- 控制Join顺序
    *
FROM large_table
JOIN medium_table ON ...
JOIN small_table ON ...;

-- 2. 利用Runtime Filter优化
SET runtime_filter_type = 'IN,BLOOM_FILTER,MIN_MAX';
SET runtime_filter_wait_time_ms = 200;  -- 等待Runtime Filter的时间

-- 3. 内存优化
SET exec_mem_limit = 8GB;  -- 单查询内存限制
SET chunk_size = 4096;      -- Chunk大小（影响向量化效率）
```

### 10.2 Pipeline优化

```sql
-- Pipeline相关配置
SET pipeline_dop = 0;  -- 0表示自动，>0表示固定并行度
SET enable_pipeline_engine = true;
SET pipeline_profile_level = 2;  -- Profile详细程度

-- 查看Pipeline执行详情
EXPLAIN PIPELINE
SELECT ...;

-- 监控Pipeline执行
SELECT * FROM information_schema.pipeline_metrics
WHERE query_id = 'xxx';
```

### 10.3 向量化优化

```sql
-- 确保向量化执行
SET enable_vectorized_engine = true;
SET batch_size = 4096;  -- 向量化批次大小

-- 检查向量化是否生效
EXPLAIN VERBOSE
SELECT ...;
-- 查看是否有"vectorized: true"标记
```

## 十一、执行引擎演进

### 11.1 版本演进历程

| 版本 | 执行引擎特性 | 主要改进 |
|------|------------|---------|
| 1.x | 火山模型 | 基础的pull模型执行 |
| 2.0 | 向量化执行 | 批量处理，SIMD优化 |
| 2.5 | Pipeline引擎 | 推模型，更好的并行性 |
| 3.0 | 自适应执行 | 动态调整并行度和内存 |
| 3.1 | Morsel-driven | 细粒度的任务调度 |
| 3.2+ | Async Pipeline | 异步I/O，协程调度 |

### 11.2 未来发展方向

```
1. GPU加速
   - GPU执行算子
   - GPU内存管理
   
2. 自适应查询执行(AQE)
   - 动态分区裁剪
   - 动态Join策略调整
   - 自动倾斜处理
   
3. 向量化2.0
   - 更激进的向量化
   - 自定义SIMD代码生成
   
4. 智能调度
   - 机器学习驱动的优化
   - 历史查询pattern学习
```

## 十二、实战案例分析

### 12.1 案例1：大表Join优化

```sql
-- 问题：两个10亿行表Join，执行超时
-- 原始SQL
SELECT a.*, b.*
FROM billion_table_a a
JOIN billion_table_b b ON a.key = b.key
WHERE a.date = '2024-01-15';

-- 优化方案1：利用分区裁剪 + Runtime Filter
ALTER TABLE billion_table_a 
PARTITION BY RANGE(date) (
    PARTITION p20240115 VALUES [('2024-01-15'), ('2024-01-16'))
);

-- 优化方案2：使用Colocation Join
ALTER TABLE billion_table_a 
SET ("colocate_with" = "group1");
ALTER TABLE billion_table_b 
SET ("colocate_with" = "group1");

-- 优化方案3：物化中间结果
CREATE MATERIALIZED VIEW mv_daily_join AS
SELECT a.key, a.col1, b.col2, a.date
FROM billion_table_a a
JOIN billion_table_b b ON a.key = b.key;

-- 优化后查询
SELECT * FROM mv_daily_join WHERE date = '2024-01-15';
```

### 12.2 案例2：窗口函数性能优化

```sql
-- 问题：窗口函数导致内存溢出
-- 原始SQL
SELECT 
    user_id,
    order_time,
    amount,
    SUM(amount) OVER (PARTITION BY user_id ORDER BY order_time 
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) as cumsum
FROM orders;

-- 优化方案1：分批处理
WITH user_batches AS (
    SELECT DISTINCT user_id, MOD(HASH(user_id), 100) as batch_id
    FROM orders
)
SELECT /*+ SET_VAR(exec_mem_limit=2GB) */
    o.user_id,
    o.order_time,
    o.amount,
    SUM(o.amount) OVER (PARTITION BY o.user_id ORDER BY o.order_time) as cumsum
FROM orders o
JOIN user_batches ub ON o.user_id = ub.user_id
WHERE ub.batch_id = ?;  -- 分100批执行

-- 优化方案2：使用segment tree物化视图
CREATE MATERIALIZED VIEW mv_cumsum AS
SELECT 
    user_id,
    DATE_TRUNC('day', order_time) as day,
    SUM(amount) as daily_amount,
    SUM(SUM(amount)) OVER (PARTITION BY user_id ORDER BY DATE_TRUNC('day', order_time)) as cumsum
FROM orders
GROUP BY user_id, DATE_TRUNC('day', order_time);
```

## 十三、故障诊断指南

### 13.1 常见执行问题

```sql
-- 1. 查询hang住
-- 检查是否在等待Runtime Filter
SHOW PROCESSLIST;
-- 查看是否有 "Wait for runtime filter" 状态

-- 解决：减少等待时间
SET runtime_filter_wait_time_ms = 100;

-- 2. 内存溢出
-- 查看内存使用
SELECT * FROM information_schema.mem_tracker
WHERE query_id = 'xxx';

-- 解决：增加内存或优化查询
SET exec_mem_limit = 16GB;
SET spill_enable = true;  -- 启用溢出到磁盘

-- 3. 数据倾斜
-- 检测倾斜
SELECT 
    fragment_instance_id,
    rows_processed,
    execution_time_ms
FROM information_schema.fragment_instances
WHERE query_id = 'xxx'
ORDER BY rows_processed DESC;

-- 解决：使用随机前缀打散
SELECT ...
FROM table
JOIN (
    SELECT *, RAND() % 10 as salt
    FROM skewed_table
) t ON ...
```

### 13.2 Profile分析技巧

```python
# 分析Profile的Python脚本
import json
import pandas as pd

def analyze_profile(profile_json):
    """分析StarRocks查询Profile"""
    profile = json.loads(profile_json)
    
    # 1. 找出最耗时的算子
    operators = []
    for fragment in profile['fragments']:
        for operator in fragment['operators']:
            operators.append({
                'fragment_id': fragment['id'],
                'operator': operator['name'],
                'time_ms': operator['time_ms'],
                'rows': operator['output_rows'],
                'memory_mb': operator['memory_bytes'] / 1048576
            })
    
    df = pd.DataFrame(operators)
    print("Top 5 耗时算子:")
    print(df.nlargest(5, 'time_ms'))
    
    # 2. 分析数据过滤效果
    scan_rows = df[df['operator'].str.contains('SCAN')]['rows'].sum()
    final_rows = df.iloc[-1]['rows']
    filter_rate = (scan_rows - final_rows) / scan_rows * 100
    print(f"\n数据过滤率: {filter_rate:.2f}%")
    
    # 3. 检查是否有数据倾斜
    if 'instances' in profile:
        instance_rows = [inst['rows'] for inst in profile['instances']]
        cv = np.std(instance_rows) / np.mean(instance_rows)
        if cv > 0.5:
            print(f"\n警告：检测到数据倾斜，CV={cv:.2f}")
    
    return df
```

## 总结

通过这个复杂SQL的执行过程，我们深入了解了StarRocks执行引擎的核心组件：

1. **查询优化**：逻辑优化和基于成本的物理优化
2. **Fragment划分**：将查询划分为可并行执行的片段
3. **Pipeline模型**：推式执行，提高CPU利用率
4. **向量化执行**：批量处理和SIMD优化
5. **Runtime Filter**：动态过滤，减少数据传输
6. **内存管理**：内存池和溢出处理
7. **执行监控**：详细的性能指标和Profile

理解这些底层原理，有助于：
- 编写高效的SQL查询
- 正确解读执行计划
- 快速定位性能瓶颈
- 进行针对性的优化

StarRocks的执行引擎还在持续演进，向着更智能、更高效的方向发展。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](big-data-ecosystem.md) | [➡️ 下一页](../07-best-practices/oracle-migration-best-practices.md)
---