---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](modern-etl-tools.md) | [➡️ 下一页](kettle-scripting.md)
---

# 批量处理策略

本章节介绍在 Kettle/PDI 中实现 StarRocks 批量数据处理的策略和最佳实践，包括分片策略、并行处理、资源管理和性能调优等关键技术。

## 1. 批量处理架构设计

### 1.1 处理架构概览

```
数据源 (Source Database)
    ↓
数据分片 (Data Sharding)
    ↓
并行处理 (Parallel Processing)
    ├── Worker 1 → StarRocks Partition 1
    ├── Worker 2 → StarRocks Partition 2  
    ├── Worker 3 → StarRocks Partition 3
    └── Worker N → StarRocks Partition N
    ↓
结果汇总 (Result Aggregation)
    ↓
状态更新 (Status Update)
```

### 1.2 核心设计原则

- **分而治之**：将大数据集分割成小块，并行处理
- **负载均衡**：确保各个处理节点负载相对均匀
- **故障隔离**：单个分片失败不影响其他分片处理
- **资源控制**：合理控制并发数和内存使用
- **进度跟踪**：实时监控处理进度和状态

## 2. 数据分片策略

### 2.1 基于时间范围的分片

```sql
-- 时间范围分片示例
-- 分片 1: 2023-01-01 to 2023-01-31
SELECT * FROM orders 
WHERE order_date >= '2023-01-01' AND order_date < '2023-02-01';

-- 分片 2: 2023-02-01 to 2023-02-28  
SELECT * FROM orders
WHERE order_date >= '2023-02-01' AND order_date < '2023-03-01';

-- 分片 3: 2023-03-01 to 2023-03-31
SELECT * FROM orders
WHERE order_date >= '2023-03-01' AND order_date < '2023-04-01';
```

**Kettle 实现**：

```xml
<!-- 生成时间分片参数 -->
<step>
    <name>Generate Date Ranges</name>
    <type>DataGrid</type>
    <data>
        <line><item>2023-01-01</item><item>2023-02-01</item><item>1</item></line>
        <line><item>2023-02-01</item><item>2023-03-01</item><item>2</item></line>
        <line><item>2023-03-01</item><item>2023-04-01</item><item>3</item></line>
        <line><item>2023-04-01</item><item>2023-05-01</item><item>4</item></line>
    </data>
    <fields>
        <field><name>start_date</name><type>String</type></field>
        <field><name>end_date</name><type>String</type></field>
        <field><name>shard_id</name><type>Integer</type></field>
    </fields>
</step>
```

### 2.2 基于主键范围的分片

```sql
-- 主键范围分片
-- 先获取数据范围
SELECT MIN(id) as min_id, MAX(id) as max_id, COUNT(*) as total_count
FROM orders;

-- 计算分片大小
-- 假设 min_id=1, max_id=10000000, total_count=10000000, 分成 10 片
-- 每片处理 1000000 条记录

-- 分片 1: ID 1 到 1000000
SELECT * FROM orders WHERE id BETWEEN 1 AND 1000000;

-- 分片 2: ID 1000001 到 2000000  
SELECT * FROM orders WHERE id BETWEEN 1000001 AND 2000000;
```

**Kettle 动态分片生成**：

```javascript
// JavaScript 步骤：计算分片范围
var total_records = parseInt(getVariable("TOTAL_RECORDS"));
var shard_count = parseInt(getVariable("SHARD_COUNT", "8"));
var records_per_shard = Math.ceil(total_records / shard_count);

var min_id = parseInt(getVariable("MIN_ID"));
var max_id = parseInt(getVariable("MAX_ID"));
var id_range = max_id - min_id + 1;
var ids_per_shard = Math.ceil(id_range / shard_count);

// 生成当前分片的范围
var current_shard = parseInt(getVariable("CURRENT_SHARD", "1"));
var shard_start_id = min_id + (current_shard - 1) * ids_per_shard;
var shard_end_id = Math.min(shard_start_id + ids_per_shard - 1, max_id);

setVariable("SHARD_START_ID", shard_start_id.toString());
setVariable("SHARD_END_ID", shard_end_id.toString());

start_id = shard_start_id;
end_id = shard_end_id;
```

### 2.3 基于 Hash 的分片

```sql
-- Hash 分片（适合无序数据）
-- 分片 1: Hash 值 0-1
SELECT * FROM orders WHERE CRC32(customer_id) % 8 = 0;

-- 分片 2: Hash 值 1-2
SELECT * FROM orders WHERE CRC32(customer_id) % 8 = 1;

-- 分片 3: Hash 值 2-3  
SELECT * FROM orders WHERE CRC32(customer_id) % 8 = 2;
```

**优缺点对比**：

| 分片策略 | 优点 | 缺点 | 适用场景 |
|---------|------|------|----------|
| 时间范围 | 符合业务逻辑，便于分区对应 | 可能数据倾斜 | 有明确时间字段的历史数据 |
| 主键范围 | 数据分布相对均匀 | 需要连续主键 | 有自增主键的表 |
| Hash 分片 | 数据分布最均匀 | 无业务含义 | 数据分布随机的大表 |

## 3. 并行处理实现

### 3.1 Kettle Job 级别并行

```xml
<job>
    <name>Parallel Batch Processing</name>
    
    <!-- 初始化参数 -->
    <entry>
        <name>Initialize Parameters</name>
        <type>EVAL</type>
        <script>
            parent_job.setVariable("PARALLEL_COUNT", "4");
            parent_job.setVariable("BATCH_SIZE", "50000");
            parent_job.setVariable("START_TIME", new Date().toISOString());
        </script>
    </entry>
    
    <!-- 并行执行多个转换 -->
    <entry>
        <name>Process Shard 1</name>
        <type>TRANS</type>
        <filename>shard_processor.ktr</filename>
        <parameters>
            <parameter><name>SHARD_ID</name><value>1</value></parameter>
            <parameter><name>SHARD_START</name><value>1</value></parameter>
            <parameter><name>SHARD_END</name><value>2500000</value></parameter>
        </parameters>
        <parallel>Y</parallel>
    </entry>
    
    <entry>
        <name>Process Shard 2</name>
        <type>TRANS</type>
        <filename>shard_processor.ktr</filename>
        <parameters>
            <parameter><name>SHARD_ID</name><value>2</value></parameter>
            <parameter><name>SHARD_START</name><value>2500001</value></parameter>
            <parameter><name>SHARD_END</name><value>5000000</value></parameter>
        </parameters>
        <parallel>Y</parallel>
    </entry>
    
    <!-- 等待所有分片完成 -->
    <entry>
        <name>Wait for All Shards</name>
        <type>DUMMY</type>
    </entry>
    
    <!-- 汇总结果 -->
    <entry>
        <name>Summarize Results</name>
        <type>SQL</type>
        <sql>
            INSERT INTO batch_process_log (
                batch_id, start_time, end_time, 
                total_processed, total_errors, status
            ) VALUES (
                '${BATCH_ID}', '${START_TIME}', NOW(),
                ${TOTAL_PROCESSED}, ${TOTAL_ERRORS}, 'completed'
            )
        </sql>
    </entry>
</job>
```

### 3.2 转换级别并行

```xml
<!-- 在转换中使用多个并行的步骤 -->
<transformation>
    <name>shard_processor</name>
    
    <!-- 读取数据 -->
    <step>
        <name>Read Shard Data</name>
        <type>TableInput</type>
        <sql>
            SELECT * FROM orders 
            WHERE id BETWEEN ${SHARD_START} AND ${SHARD_END}
            ORDER BY id
        </sql>
        <copies>1</copies>
    </step>
    
    <!-- 数据分流到多个处理管道 -->
    <step>
        <name>Distribute Data</name>
        <type>Calculator</type>
        <calculation>
            <field_name>pipeline_id</field_name>
            <calc_type>MOD</calc_type>
            <field_a>id</field_a>
            <field_b>4</field_b>
            <value_type>Integer</value_type>
        </calculation>
        <copies>1</copies>
    </step>
    
    <!-- 多个并行处理管道 -->
    <step>
        <name>Process Pipeline 1</name>
        <type>FilterRows</type>
        <condition>
            <field>pipeline_id</field>
            <function>=</function>
            <value>0</value>
        </condition>
        <copies>2</copies>  <!-- 每个管道 2 个并行副本 -->
    </step>
    
    <step>
        <name>Process Pipeline 2</name>
        <type>FilterRows</type>
        <condition>
            <field>pipeline_id</field>
            <function>=</function>
            <value>1</value>
        </condition>
        <copies>2</copies>
    </step>
    
    <!-- 数据写入 StarRocks -->
    <step>
        <name>Write to StarRocks</name>
        <type>TableOutput</type>
        <table>orders_target</table>
        <commit_size>10000</commit_size>
        <copies>1</copies>  <!-- 写入统一串行 -->
    </step>
</transformation>
```

## 4. 资源管理和负载控制

### 4.1 内存管理策略

```bash
# JVM 内存配置
export PENTAHO_DI_JAVA_OPTIONS="
-Xms4g -Xmx16g                          # 堆内存
-XX:NewRatio=1                           # 新生代比例
-XX:+UseG1GC                            # G1 垃圾收集器
-XX:G1HeapRegionSize=16m                 # G1 区域大小
-XX:MaxGCPauseMillis=200                 # 最大 GC 暂停时间
-XX:+UnlockExperimentalVMOptions         # 启用实验特性
-XX:+UseCGroupMemoryLimitForHeap         # 容器内存限制
-Dfile.encoding=UTF-8                    # 字符编码
"

# 步骤级内存控制
export PDI_STEP_CACHE_SIZE="50000"       # 步骤缓存大小
export PDI_ROW_BUFFER_SIZE="100000"      # 行缓冲大小
```

### 4.2 连接池管理

```xml
<!-- 数据库连接池配置 -->
<connection>
    <name>Source_Pool</name>
    <pooling_enabled>Y</pooling_enabled>
    <initial_pool_size>2</initial_pool_size>
    <maximum_pool_size>10</maximum_pool_size>
    <connection_test_query>SELECT 1</connection_test_query>
    <idle_test_period>300</idle_test_period>
    <test_on_borrow>Y</test_on_borrow>
    <test_on_return>N</test_on_return>
    <test_while_idle>Y</test_while_idle>
</connection>

<connection>
    <name>StarRocks_Pool</name>
    <pooling_enabled>Y</pooling_enabled>
    <initial_pool_size>4</initial_pool_size>
    <maximum_pool_size>20</maximum_pool_size>
    <connection_test_query>SELECT 1</connection_test_query>
</connection>
```

### 4.3 流量控制机制

```javascript
// 动态调整并行度
var current_cpu_usage = getCpuUsage();  // 自定义函数获取 CPU 使用率
var current_memory_usage = getMemoryUsage();  // 自定义函数获取内存使用率

var parallel_count = parseInt(getVariable("PARALLEL_COUNT", "4"));

// 根据资源使用情况调整并行度
if (current_cpu_usage > 85 || current_memory_usage > 80) {
    // 资源紧张，减少并行度
    parallel_count = Math.max(parallel_count - 1, 1);
    writeToLog("w", "资源使用率较高，降低并行度至: " + parallel_count);
} else if (current_cpu_usage < 50 && current_memory_usage < 60) {
    // 资源充足，可以增加并行度
    parallel_count = Math.min(parallel_count + 1, 8);
    writeToLog("i", "资源使用率较低，提升并行度至: " + parallel_count);
}

setVariable("PARALLEL_COUNT", parallel_count.toString());

// 动态调整批量大小
var current_batch_size = parseInt(getVariable("BATCH_SIZE", "10000"));
var last_process_time = parseInt(getVariable("LAST_PROCESS_TIME", "0"));

if (last_process_time > 300000) {  // 超过 5 分钟
    current_batch_size = Math.max(current_batch_size * 0.8, 1000);
} else if (last_process_time < 60000) {  // 小于 1 分钟
    current_batch_size = Math.min(current_batch_size * 1.2, 100000);
}

setVariable("BATCH_SIZE", current_batch_size.toString());
```

## 5. 错误处理和重试机制

### 5.1 分片级错误隔离

```xml
<job>
    <name>Resilient Batch Processing</name>
    
    <!-- 记录开始状态 -->
    <entry>
        <name>Record Start Status</name>
        <type>SQL</type>
        <sql>
            INSERT INTO shard_status (shard_id, status, start_time)
            VALUES (${SHARD_ID}, 'running', NOW())
            ON DUPLICATE KEY UPDATE status = 'running', start_time = NOW()
        </sql>
    </entry>
    
    <!-- 执行分片处理 -->
    <entry>
        <name>Process Shard</name>
        <type>TRANS</type>
        <filename>shard_processor.ktr</filename>
        <on_error>Handle Shard Error</on_error>
    </entry>
    
    <!-- 成功处理 -->
    <entry>
        <name>Record Success</name>
        <type>SQL</type>
        <sql>
            UPDATE shard_status 
            SET status = 'completed', 
                end_time = NOW(),
                processed_rows = ${PROCESSED_ROWS}
            WHERE shard_id = ${SHARD_ID}
        </sql>
    </entry>
    
    <!-- 错误处理 -->
    <entry>
        <name>Handle Shard Error</name>
        <type>SQL</type>
        <sql>
            UPDATE shard_status 
            SET status = 'failed',
                end_time = NOW(),
                error_message = '${ERROR_MESSAGE}'
            WHERE shard_id = ${SHARD_ID}
        </sql>
        <on_success>Notify Error</on_success>
    </entry>
    
    <!-- 错误通知 -->
    <entry>
        <name>Notify Error</name>
        <type>MAIL</type>
        <server>smtp_server</server>
        <subject>批处理分片 ${SHARD_ID} 失败</subject>
        <message>分片 ${SHARD_ID} 处理失败: ${ERROR_MESSAGE}</message>
    </entry>
</job>
```

### 5.2 智能重试策略

```javascript
// 指数退避重试算法
function calculateRetryDelay(retryCount, baseDelayMs, maxDelayMs) {
    var delay = baseDelayMs * Math.pow(2, retryCount);
    return Math.min(delay, maxDelayMs);
}

var retry_count = parseInt(getVariable("RETRY_COUNT", "0"));
var max_retries = parseInt(getVariable("MAX_RETRIES", "3"));
var base_delay = 5000; // 5 秒基础延迟
var max_delay = 300000; // 最大 5 分钟延迟

if (retry_count < max_retries) {
    var delay_ms = calculateRetryDelay(retry_count, base_delay, max_delay);
    
    writeToLog("w", "第 " + (retry_count + 1) + " 次重试，延迟 " + (delay_ms / 1000) + " 秒");
    
    // 等待指定时间
    java.lang.Thread.sleep(delay_ms);
    
    setVariable("RETRY_COUNT", (retry_count + 1).toString());
    should_retry = true;
} else {
    writeToLog("e", "达到最大重试次数，停止重试");
    should_retry = false;
}
```

### 5.3 断点续传机制

```sql
-- 创建处理状态表
CREATE TABLE batch_progress (
    batch_id VARCHAR(64),
    shard_id INT,
    start_id BIGINT,
    end_id BIGINT,
    last_processed_id BIGINT,
    processed_rows BIGINT,
    status ENUM('pending', 'running', 'completed', 'failed'),
    start_time DATETIME,
    end_time DATETIME,
    error_message TEXT,
    PRIMARY KEY (batch_id, shard_id)
);
```

```javascript
// 断点续传逻辑
var batch_id = getVariable("BATCH_ID");
var shard_id = parseInt(getVariable("SHARD_ID"));

// 查询上次处理进度
var last_processed_id = getVariableFromDB(
    "SELECT last_processed_id FROM batch_progress WHERE batch_id = '" + batch_id + 
    "' AND shard_id = " + shard_id
);

var original_start_id = parseInt(getVariable("SHARD_START_ID"));
var start_id = last_processed_id ? Math.max(last_processed_id + 1, original_start_id) : original_start_id;

setVariable("EFFECTIVE_START_ID", start_id.toString());

if (last_processed_id && last_processed_id > original_start_id) {
    writeToLog("i", "从断点 ID " + start_id + " 继续处理分片 " + shard_id);
} else {
    writeToLog("i", "开始处理分片 " + shard_id + "，起始 ID " + start_id);
}
```

## 6. 性能监控和调优

### 6.1 实时性能监控

```javascript
// 性能指标收集
var start_time = new Date().getTime();

// ... 数据处理逻辑 ...

var end_time = new Date().getTime();
var process_time_ms = end_time - start_time;
var processed_rows = parseInt(getVariable("PROCESSED_ROWS", "0"));

// 计算性能指标
var rows_per_second = processed_rows / (process_time_ms / 1000);
var memory_usage = getMemoryUsage();  // MB
var cpu_usage = getCpuUsage();        // %

// 记录性能指标到监控表
var sql = "INSERT INTO performance_metrics (" +
    "batch_id, shard_id, timestamp, process_time_ms, processed_rows, " +
    "rows_per_second, memory_usage_mb, cpu_usage_percent" +
    ") VALUES (" +
    "'" + getVariable("BATCH_ID") + "', " +
    getVariable("SHARD_ID") + ", " +
    "NOW(), " + process_time_ms + ", " + processed_rows + ", " +
    rows_per_second.toFixed(2) + ", " + memory_usage + ", " + cpu_usage +
    ")";

executeSQL(sql);

// 输出性能摘要
writeToLog("i", "分片 " + getVariable("SHARD_ID") + " 性能指标:");
writeToLog("i", "  - 处理时间: " + (process_time_ms / 1000).toFixed(2) + " 秒");
writeToLog("i", "  - 处理行数: " + processed_rows);
writeToLog("i", "  - 处理速率: " + rows_per_second.toFixed(0) + " 行/秒");
writeToLog("i", "  - 内存使用: " + memory_usage + " MB");
writeToLog("i", "  - CPU 使用: " + cpu_usage + "%");
```

### 6.2 瓶颈识别和调优

```bash
#!/bin/bash
# performance_analyzer.sh

LOG_FILE="/path/to/batch_process.log"
PERF_LOG="/path/to/performance.log"

echo "=== 批处理性能分析报告 ===" > "$PERF_LOG"
echo "生成时间: $(date)" >> "$PERF_LOG"
echo "" >> "$PERF_LOG"

# 分析处理速率
echo "=== 处理速率分析 ===" >> "$PERF_LOG"
grep "处理速率:" "$LOG_FILE" | tail -20 | \
awk -F: '{print $NF}' | awk '{print $1}' | \
awk '{sum+=$1; count++} END {
    if(count>0) {
        avg=sum/count;
        print "平均处理速率: " avg " 行/秒"
        if(avg < 1000) print "⚠️  处理速率较低，建议检查 SQL 优化和索引"
        else if(avg > 10000) print "✅ 处理速率良好"
        else print "ℹ️  处理速率中等"
    }
}' >> "$PERF_LOG"

# 分析内存使用
echo "" >> "$PERF_LOG"
echo "=== 内存使用分析 ===" >> "$PERF_LOG"
grep "内存使用:" "$LOG_FILE" | tail -20 | \
awk -F: '{print $NF}' | awk '{print $1}' | \
awk '{sum+=$1; count++; if($1>max) max=$1} END {
    if(count>0) {
        avg=sum/count;
        print "平均内存使用: " avg " MB"
        print "峰值内存使用: " max " MB"
        if(max > 8192) print "⚠️  内存使用较高，建议调整 JVM 参数或减少批量大小"
        else print "✅ 内存使用正常"
    }
}' >> "$PERF_LOG"

# 分析错误率
echo "" >> "$PERF_LOG"
echo "=== 错误率分析 ===" >> "$PERF_LOG"
TOTAL_BATCHES=$(grep -c "分片.*开始处理\|分片.*处理完成\|分片.*处理失败" "$LOG_FILE")
ERROR_BATCHES=$(grep -c "分片.*处理失败" "$LOG_FILE")

if [ "$TOTAL_BATCHES" -gt 0 ]; then
    ERROR_RATE=$(echo "scale=2; $ERROR_BATCHES * 100 / $TOTAL_BATCHES" | bc)
    echo "总处理批次: $TOTAL_BATCHES" >> "$PERF_LOG"
    echo "失败批次: $ERROR_BATCHES" >> "$PERF_LOG"
    echo "错误率: $ERROR_RATE%" >> "$PERF_LOG"
    
    if (( $(echo "$ERROR_RATE > 5" | bc -l) )); then
        echo "⚠️  错误率较高，需要检查错误日志" >> "$PERF_LOG"
    else
        echo "✅ 错误率在可接受范围内" >> "$PERF_LOG"
    fi
fi

echo "" >> "$PERF_LOG"
echo "详细报告已生成: $PERF_LOG"
```

## 7. Aggregate 表配合循环的高级场景

### 7.1 多年数据按月聚合场景

在数据仓库场景中，经常需要将三年的明细数据按月聚合到 StarRocks 的 Aggregate 模型表中。虽然可以一次性聚合整年的数据，但为了避免内存压力和提高处理效率，通常采用循环方式分批处理。

#### 场景描述
- **数据源**：3年的订单明细数据（约1亿条记录）
- **目标表**：Aggregate 模型的年度汇总表
- **处理策略**：按月循环，逐月聚合到年度表中
- **聚合逻辑**：不是简单的数据导入，而是利用 Aggregate 模型的预聚合特性

#### 目标 Aggregate 表设计

```sql
-- 年度销售汇总表（Aggregate模型）
CREATE TABLE yearly_sales_summary (
    year INT NOT NULL,
    region VARCHAR(50) NOT NULL,
    product_category VARCHAR(50) NOT NULL,
    
    -- 聚合指标列
    total_amount SUM DECIMAL(18,2) DEFAULT "0" COMMENT "年度总销售额",
    order_count SUM BIGINT DEFAULT "0" COMMENT "年度订单数",
    avg_order_value REPLACE DECIMAL(10,2) DEFAULT "0" COMMENT "平均订单价值",
    max_single_order MAX DECIMAL(10,2) DEFAULT "0" COMMENT "单笔最高订单",
    unique_customers HLL HLL_UNION COMMENT "年度活跃客户数",
    monthly_peak MAX DECIMAL(15,2) DEFAULT "0" COMMENT "月度销售峰值"
)
AGGREGATE KEY(year, region, product_category)
DISTRIBUTED BY HASH(region) BUCKETS 10
PROPERTIES ("replication_num" = "3");
```

### 7.2 Kettle 循环聚合实现

#### 主 Job 设计

```xml
<job>
    <name>Yearly Aggregation with Monthly Loop</name>
    
    <!-- 初始化参数 -->
    <entry>
        <name>Initialize Parameters</name>
        <type>EVAL</type>
        <script>
            // 设置处理年份和月份范围
            parent_job.setVariable("TARGET_YEAR", "2023");
            parent_job.setVariable("START_MONTH", "1");
            parent_job.setVariable("END_MONTH", "12");
            parent_job.setVariable("CURRENT_MONTH", "1");
            
            // 聚合模式标识
            parent_job.setVariable("AGGREGATE_MODE", "true");
            parent_job.setVariable("BATCH_SIZE", "100000");
        </script>
    </entry>
    
    <!-- 清理目标年份的历史数据 -->
    <entry>
        <name>Clean Target Year Data</name>
        <type>SQL</type>
        <sql>
            DELETE FROM yearly_sales_summary 
            WHERE year = ${TARGET_YEAR}
        </sql>
    </entry>
    
    <!-- 月份循环处理 -->
    <entry>
        <name>Monthly Loop Controller</name>
        <type>EVAL</type>
        <script>
            var current_month = parseInt(getVariable("CURRENT_MONTH", "1"));
            var end_month = parseInt(getVariable("END_MONTH", "12"));
            var target_year = getVariable("TARGET_YEAR");
            
            if (current_month <= end_month) {
                // 设置当前处理月份的参数
                parent_job.setVariable("PROCESSING_YEAR", target_year);
                parent_job.setVariable("PROCESSING_MONTH", current_month.toString().padStart(2, '0'));
                parent_job.setVariable("MONTH_NAME", target_year + "-" + current_month.toString().padStart(2, '0'));
                
                writeToLog("i", "开始处理 " + target_year + " 年 " + current_month + " 月的数据聚合");
                should_continue = true;
            } else {
                writeToLog("i", "所有月份处理完成");
                should_continue = false;
            }
        </script>
        <next>Process Monthly Data</next>
    </entry>
    
    <!-- 处理单月数据 -->
    <entry>
        <name>Process Monthly Data</name>
        <type>TRANS</type>
        <filename>monthly_aggregate_processor.ktr</filename>
        <parameters>
            <parameter><name>YEAR</name><value>${PROCESSING_YEAR}</value></parameter>
            <parameter><name>MONTH</name><value>${PROCESSING_MONTH}</value></parameter>
            <parameter><name>MONTH_NAME</name><value>${MONTH_NAME}</value></parameter>
        </parameters>
        <next>Increment Month</next>
    </entry>
    
    <!-- 递增月份 -->
    <entry>
        <name>Increment Month</name>
        <type>EVAL</type>
        <script>
            var current_month = parseInt(getVariable("CURRENT_MONTH"));
            current_month++;
            parent_job.setVariable("CURRENT_MONTH", current_month.toString());
        </script>
        <next>Monthly Loop Controller</next>
    </entry>
    
    <!-- 最终汇总验证 -->
    <entry>
        <name>Final Summary Validation</name>
        <type>SQL</type>
        <sql>
            SELECT 
                year,
                COUNT(*) as dimension_count,
                SUM(total_amount) as total_yearly_amount,
                SUM(order_count) as total_yearly_orders
            FROM yearly_sales_summary 
            WHERE year = ${TARGET_YEAR}
            GROUP BY year
        </sql>
    </entry>
</job>
```

#### 月度聚合转换（monthly_aggregate_processor.ktr）

```xml
<transformation>
    <name>monthly_aggregate_processor</name>
    
    <!-- 读取月度明细数据 -->
    <step>
        <name>Read Monthly Orders</name>
        <type>TableInput</type>
        <sql>
            SELECT 
                ${YEAR} as year,
                u.region,
                p.category as product_category,
                o.order_amount,
                o.order_id,
                o.user_id,
                -- 预先计算月度峰值
                SUM(o.order_amount) OVER (
                    PARTITION BY u.region, p.category 
                    ORDER BY o.order_date
                ) as running_monthly_total
            FROM orders o
            JOIN users u ON o.user_id = u.user_id  
            JOIN products p ON o.product_id = p.product_id
            WHERE o.order_date >= '${YEAR}-${MONTH}-01'
              AND o.order_date < '${YEAR}-${MONTH}-01'::DATE + INTERVAL '1 month'
              AND o.status = 'COMPLETED'
            ORDER BY u.region, p.category, o.order_date
        </sql>
    </step>
    
    <!-- 月度数据预聚合 -->
    <step>
        <name>Monthly Pre-Aggregation</name>
        <type>GroupBy</type>
        <group>
            <field><name>year</name></field>
            <field><name>region</name></field> 
            <field><name>product_category</name></field>
        </group>
        <fields>
            <!-- 利用 Aggregate 模型的 SUM 特性 -->
            <field>
                <name>monthly_amount</name>
                <aggregate>SUM</aggregate>
                <subject>order_amount</subject>
            </field>
            <field>
                <name>monthly_orders</name>
                <aggregate>COUNT</aggregate>
                <subject>order_id</subject>
            </field>
            <field>
                <name>avg_order_value</name>
                <aggregate>AVERAGE</aggregate>
                <subject>order_amount</subject>
            </field>
            <field>
                <name>max_single_order</name>
                <aggregate>MAXIMUM</aggregate>
                <subject>order_amount</subject>
            </field>
            <field>
                <name>monthly_peak</name>
                <aggregate>MAXIMUM</aggregate>
                <subject>running_monthly_total</subject>
            </field>
        </fields>
    </step>
    
    <!-- HLL 用户去重计算 -->
    <step>
        <name>Calculate HLL Users</name>
        <type>Calculator</type>
        <calculation>
            <field_name>unique_customers</field_name>
            <calc_type>HLL_HASH</calc_type>
            <field_a>user_id</field_a>
        </calculation>
    </step>
    
    <!-- 写入 Aggregate 表（自动聚合） -->
    <step>
        <name>Write to Aggregate Table</name>
        <type>TableOutput</type>
        <table>yearly_sales_summary</table>
        <commit_size>1000</commit_size>
        <use_batch>Y</use_batch>
        <!-- 关键：利用 INSERT 让 StarRocks 自动聚合 -->
        <insert_only>N</insert_only>
    </step>
    
    <!-- 处理进度日志 -->
    <step>
        <name>Log Processing Progress</name>
        <type>WriteToLog</type>
        <loglevel>Basic</loglevel>
        <displayHeader>Y</displayHeader>
        <limitRows>N</limitRows>
        <fields>
            <field><name>year</name></field>
            <field><name>region</name></field>
            <field><name>product_category</name></field>
            <field><name>monthly_amount</name></field>
            <field><name>monthly_orders</name></field>
        </fields>
    </step>
</transformation>
```

### 7.3 Aggregate 模型的关键机制

#### 自动聚合原理

当向 Aggregate 表插入数据时，StarRocks 会自动进行聚合：

```sql
-- 第一次插入（1月数据）
INSERT INTO yearly_sales_summary VALUES 
(2023, '北京', '电子产品', 100000, 500, 200, 1500, hll_hash(12345), 100000);

-- 第二次插入（2月数据）- StarRocks 自动与1月数据聚合
INSERT INTO yearly_sales_summary VALUES 
(2023, '北京', '电子产品', 120000, 600, 200, 1800, hll_hash(12346), 120000);

-- 结果：StarRocks 自动合并为
-- (2023, '北京', '电子产品', 220000, 1100, 200, 1800, hll_union(...), 120000)
```

#### 聚合函数行为说明

```javascript
// Kettle 中的聚合逻辑理解
var aggregation_rules = {
    "SUM": "多次插入的值会累加",
    "MAX": "保留所有插入中的最大值", 
    "MIN": "保留所有插入中的最小值",
    "REPLACE": "使用最后一次插入的值",
    "HLL_UNION": "合并HLL集合，保持去重特性",
    "BITMAP_UNION": "合并BITMAP集合，精确去重"
};

writeToLog("i", "Aggregate 模型会在插入时自动应用这些聚合规则");
```

### 7.4 循环处理的优化策略

#### 内存管理

```xml
<!-- 优化的转换配置 -->
<transformation>
    <info>
        <name>memory_optimized_aggregation</name>
        <!-- 控制步骤缓存大小 -->
        <step_performance_capturing_enabled>Y</step_performance_capturing_enabled>
        <step_performance_capturing_size_limit>1000</step_performance_capturing_size_limit>
    </info>
    
    <!-- 分批读取避免内存溢出 -->
    <step>
        <name>Batched Monthly Read</name>
        <type>TableInput</type>
        <limit>50000</limit>  <!-- 限制单批次读取量 -->
        <sql>
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (ORDER BY order_date) as rn
                FROM orders 
                WHERE order_date >= '${YEAR}-${MONTH}-01'
                  AND order_date < '${YEAR}-${MONTH}-01'::DATE + INTERVAL '1 month'
            ) t 
            WHERE rn BETWEEN ${OFFSET} AND ${OFFSET} + 50000
        </sql>
    </step>
</transformation>
```

#### 错误处理和重试

```javascript
// 月度处理错误恢复
function handleMonthlyProcessError() {
    var current_month = parseInt(getVariable("CURRENT_MONTH"));
    var error_count = parseInt(getVariable("MONTH_ERROR_COUNT", "0"));
    
    if (error_count < 3) {
        // 重试当前月份
        writeToLog("w", "月份 " + current_month + " 处理失败，第 " + (error_count + 1) + " 次重试");
        setVariable("MONTH_ERROR_COUNT", (error_count + 1).toString());
        
        // 清理当前月份的部分数据
        executeSQL("DELETE FROM yearly_sales_summary WHERE year = " + 
                  getVariable("TARGET_YEAR") + " AND month_flag = " + current_month);
        
        return "RETRY_CURRENT_MONTH";
    } else {
        // 跳过当前月份，记录错误
        writeToLog("e", "月份 " + current_month + " 多次失败，跳过处理");
        setVariable("MONTH_ERROR_COUNT", "0");
        setVariable("CURRENT_MONTH", (current_month + 1).toString());
        
        return "SKIP_TO_NEXT_MONTH";
    }
}
```

### 7.5 性能监控和验证

#### 聚合结果验证

```sql
-- 验证聚合的正确性
-- 1. 检查每个维度的数据完整性
SELECT 
    year,
    region, 
    product_category,
    total_amount,
    order_count,
    ROUND(total_amount / order_count, 2) as calculated_avg
FROM yearly_sales_summary 
WHERE year = 2023
ORDER BY total_amount DESC;

-- 2. 与原始数据对比验证
SELECT 
    'source' as data_type,
    2023 as year,
    u.region,
    p.category,
    SUM(o.order_amount) as total_amount,
    COUNT(*) as order_count
FROM orders o
JOIN users u ON o.user_id = u.user_id
JOIN products p ON o.product_id = p.product_id  
WHERE YEAR(o.order_date) = 2023
GROUP BY u.region, p.category

UNION ALL

SELECT 
    'aggregated' as data_type,
    year,
    region,
    product_category,
    total_amount,
    order_count
FROM yearly_sales_summary 
WHERE year = 2023;
```

#### 处理效率监控

```javascript
// 性能监控脚本
var start_time = new Date().getTime();

// ... 处理逻辑 ...

var end_time = new Date().getTime();
var process_time = end_time - start_time;
var records_processed = parseInt(getVariable("RECORDS_PROCESSED", "0"));

var performance_metrics = {
    "month": getVariable("PROCESSING_MONTH"),
    "processing_time_sec": Math.round(process_time / 1000),
    "records_processed": records_processed,
    "records_per_second": Math.round(records_processed / (process_time / 1000)),
    "memory_usage_mb": getMemoryUsage()
};

writeToLog("i", "月度处理性能: " + JSON.stringify(performance_metrics));
```

### 7.6 最佳实践要点

#### Aggregate 模型使用建议

1. **聚合键设计**
   - 选择业务中真正需要分析的维度作为聚合键
   - 聚合键的组合基数不宜过高（建议 < 1000万）
   - 按查询频率调整聚合键顺序

2. **循环粒度选择**
   - 按月循环：平衡内存使用和处理效率
   - 按周循环：适合实时性要求较高的场景
   - 按日循环：用于增量更新场景

3. **资源控制**
   - 单次循环的数据量控制在 100MB-1GB
   - 合理设置 Kettle 的 commit_size（建议1000-10000）
   - 监控 StarRocks 的 compaction 状态

4. **数据质量保证**
   - 在每个循环后验证聚合结果
   - 实现断点续传机制
   - 建立完整的错误日志和告警

通过这种 Aggregate 表配合循环的方式，可以高效处理大规模历史数据的聚合场景，充分利用 StarRocks 预聚合的优势。

## 8. 最佳实践总结

### 8.1 分片策略选择
- **历史数据迁移**：优先使用时间范围分片，与 StarRocks 分区策略对应
- **大表全量同步**：使用主键范围分片，确保数据完整性
- **实时数据处理**：使用 Hash 分片，保证负载均衡
- **聚合场景**：使用时间循环分片，配合 Aggregate 模型实现高效预聚合

### 8.2 并行度设置
- **CPU 密集型**：并行度 = CPU 核心数
- **I/O 密集型**：并行度 = CPU 核心数 × 2
- **内存受限型**：根据可用内存动态调整
- **聚合计算型**：适度降低并行度，避免聚合冲突

### 8.3 资源管理要点
- 设置合理的 JVM 堆内存，通常为系统内存的 60-70%
- 使用连接池避免频繁创建数据库连接
- 实施流量控制，防止系统过载
- 定期监控和清理临时文件
- Aggregate 场景需监控 StarRocks compaction 状态

### 8.4 错误处理策略
- 实现分片级错误隔离，单个分片失败不影响整体
- 采用指数退避重试策略，避免雪崩效应
- 支持断点续传，提高处理效率
- 建立完善的监控告警机制
- Aggregate 场景需要数据一致性验证

### 8.5 性能调优建议
- 定期分析性能指标，识别瓶颈点
- 优化 SQL 查询，使用合适的索引
- 调整批量大小，平衡内存使用和处理效率
- 使用 Stream Load 替代 INSERT 提升写入性能
- Aggregate 场景优化聚合键设计和分桶策略

通过合理的批量处理策略，特别是结合 StarRocks Aggregate 模型的预聚合特性，可以显著提升大数据量的 ETL 处理效率和系统稳定性。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](modern-etl-tools.md) | [➡️ 下一页](kettle-scripting.md)
---