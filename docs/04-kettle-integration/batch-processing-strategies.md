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

## 7. 聚合表配合循环处理

### 7.1 场景描述

在实际的数据仓库项目中，经常需要处理历史数据的聚合场景：
- **数据源**：三年的明细数据，按月分批存储
- **目标表**：StarRocks Aggregate 聚合模型表，按年度聚合
- **处理策略**：分月多次聚合到目标表，而不是一次性处理全年数据

这种场景特别适合使用 Kettle 循环机制配合 StarRocks 聚合模型来实现。

### 7.2 聚合表设计

首先设计 StarRocks 聚合模型表结构：

```sql
-- 年度销售聚合表
CREATE TABLE annual_sales_summary (
    year_id INT NOT NULL,
    region_code VARCHAR(50) NOT NULL,
    product_category VARCHAR(100) NOT NULL,
    total_sales DECIMAL(18,2) SUM DEFAULT "0",
    total_orders BIGINT SUM DEFAULT "0", 
    avg_order_amount DECIMAL(10,2) REPLACE DEFAULT "0",
    max_single_order DECIMAL(10,2) MAX DEFAULT "0",
    min_single_order DECIMAL(10,2) MIN DEFAULT "999999",
    last_updated DATETIME REPLACE DEFAULT CURRENT_TIMESTAMP
) ENGINE=OLAP
AGGREGATE KEY(year_id, region_code, product_category)
COMMENT "年度销售数据聚合表"
DISTRIBUTED BY HASH(year_id, region_code) BUCKETS 8
PROPERTIES (
    "replication_num" = "3",
    "enable_persistent_index" = "true"
);
```

### 7.3 Kettle 循环处理实现

#### 7.3.1 主控循环 Job 设计

```xml
<job>
    <name>Annual Aggregation with Monthly Loop</name>
    
    <!-- 初始化年度和月份参数 -->
    <entry>
        <name>Initialize Parameters</name>
        <type>EVAL</type>
        <script>
            // 设置要处理的年份范围
            var startYear = 2021;
            var endYear = 2023;
            var currentYear = startYear;
            
            parent_job.setVariable("START_YEAR", startYear.toString());
            parent_job.setVariable("END_YEAR", endYear.toString());
            parent_job.setVariable("CURRENT_YEAR", currentYear.toString());
            
            // 月份循环参数
            parent_job.setVariable("START_MONTH", "1");
            parent_job.setVariable("END_MONTH", "12");
            parent_job.setVariable("CURRENT_MONTH", "1");
            
            writeToLog("i", "开始处理年度聚合，年份范围：" + startYear + " - " + endYear);
        </script>
    </entry>
    
    <!-- 年度循环开始 -->
    <entry>
        <name>Year Loop Start</name>
        <type>SIMPLE_EVAL</type>
        <script>
            var currentYear = parseInt(parent_job.getVariable("CURRENT_YEAR"));
            var endYear = parseInt(parent_job.getVariable("END_YEAR"));
            
            if (currentYear <= endYear) {
                writeToLog("i", "开始处理年份：" + currentYear);
                // 重置月份循环
                parent_job.setVariable("CURRENT_MONTH", "1");
                result = true;
            } else {
                writeToLog("i", "年度循环结束");
                result = false;
            }
        </script>
        <on_success>Month Loop Start</on_success>
        <on_failure>Job End</on_failure>
    </entry>
    
    <!-- 月份循环开始 -->
    <entry>
        <name>Month Loop Start</name>
        <type>SIMPLE_EVAL</type>
        <script>
            var currentMonth = parseInt(parent_job.getVariable("CURRENT_MONTH"));
            var endMonth = parseInt(parent_job.getVariable("END_MONTH"));
            var currentYear = parent_job.getVariable("CURRENT_YEAR");
            
            if (currentMonth <= endMonth) {
                var monthStr = currentMonth < 10 ? "0" + currentMonth : currentMonth.toString();
                writeToLog("i", "处理月份：" + currentYear + "-" + monthStr);
                parent_job.setVariable("CURRENT_MONTH_STR", monthStr);
                result = true;
            } else {
                writeToLog("i", "当前年份月份循环结束，进入下一年");
                result = false;
            }
        </script>
        <on_success>Process Monthly Aggregation</on_success>
        <on_failure>Next Year</on_failure>
    </entry>
    
    <!-- 执行月度聚合 -->
    <entry>
        <name>Process Monthly Aggregation</name>
        <type>TRANS</type>
        <filename>monthly_aggregate_processor.ktr</filename>
        <parameters>
            <parameter><name>PROCESS_YEAR</name><value>${CURRENT_YEAR}</value></parameter>
            <parameter><name>PROCESS_MONTH</name><value>${CURRENT_MONTH_STR}</value></parameter>
        </parameters>
        <on_success>Next Month</on_success>
        <on_failure>Handle Month Error</on_failure>
    </entry>
    
    <!-- 处理下个月 -->
    <entry>
        <name>Next Month</name>
        <type>SIMPLE_EVAL</type>
        <script>
            var currentMonth = parseInt(parent_job.getVariable("CURRENT_MONTH")) + 1;
            parent_job.setVariable("CURRENT_MONTH", currentMonth.toString());
        </script>
        <on_success>Month Loop Start</on_success>
    </entry>
    
    <!-- 处理下一年 -->
    <entry>
        <name>Next Year</name>
        <type>SIMPLE_EVAL</type>
        <script>
            var currentYear = parseInt(parent_job.getVariable("CURRENT_YEAR")) + 1;
            parent_job.setVariable("CURRENT_YEAR", currentYear.toString());
        </script>
        <on_success>Year Loop Start</on_success>
    </entry>
    
    <!-- 月份处理错误 -->
    <entry>
        <name>Handle Month Error</name>
        <type>MAIL</type>
        <subject>月度聚合处理失败</subject>
        <message>年份 ${CURRENT_YEAR} 月份 ${CURRENT_MONTH_STR} 聚合处理失败</message>
        <on_success>Next Month</on_success>
    </entry>
</job>
```

#### 7.3.2 月度聚合处理转换

```xml
<transformation>
    <name>monthly_aggregate_processor</name>
    
    <!-- 读取月度明细数据 -->
    <step>
        <name>Read Monthly Detail Data</name>
        <type>TableInput</type>
        <connection>Source_Database</connection>
        <sql>
            SELECT 
                ${PROCESS_YEAR} as year_id,
                region_code,
                product_category,
                SUM(sale_amount) as monthly_sales,
                COUNT(*) as monthly_orders,
                AVG(sale_amount) as avg_order_amount,
                MAX(sale_amount) as max_single_order,
                MIN(sale_amount) as min_single_order,
                NOW() as last_updated
            FROM sales_detail 
            WHERE DATE_FORMAT(order_date, '%Y-%m') = '${PROCESS_YEAR}-${PROCESS_MONTH}'
            GROUP BY region_code, product_category
            HAVING SUM(sale_amount) > 0
        </sql>
    </step>
    
    <!-- 数据验证 -->
    <step>
        <name>Validate Monthly Data</name>
        <type>FilterRows</type>
        <condition>
            <field>monthly_sales</field>
            <function>></function>
            <value>0</value>
        </condition>
        <send_true_to>Transform for StarRocks</send_true_to>
        <send_false_to>Log Invalid Data</send_false_to>
    </step>
    
    <!-- 记录无效数据 -->
    <step>
        <name>Log Invalid Data</name>
        <type>WriteToLog</type>
        <loglevel>error</loglevel>
        <displayHeader>Y</displayHeader>
        <logmessage>发现无效的月度数据：年份=${PROCESS_YEAR}, 月份=${PROCESS_MONTH}</logmessage>
    </step>
    
    <!-- 转换为 StarRocks 聚合格式 -->
    <step>
        <name>Transform for StarRocks</name>
        <type>SelectValues</type>
        <fields>
            <field><name>year_id</name><rename>year_id</rename><type>Integer</type></field>
            <field><name>region_code</name><rename>region_code</rename><type>String</type><length>50</length></field>
            <field><name>product_category</name><rename>product_category</rename><type>String</type><length>100</length></field>
            <field><name>monthly_sales</name><rename>total_sales</rename><type>BigNumber</type><precision>18</precision><scale>2</scale></field>
            <field><name>monthly_orders</name><rename>total_orders</rename><type>Integer</type></field>
            <field><name>avg_order_amount</name><rename>avg_order_amount</rename><type>BigNumber</type><precision>10</precision><scale>2</scale></field>
            <field><name>max_single_order</name><rename>max_single_order</rename><type>BigNumber</type><precision>10</precision><scale>2</scale></field>
            <field><name>min_single_order</name><rename>min_single_order</rename><type>BigNumber</type><precision>10</precision><scale>2</scale></field>
            <field><name>last_updated</name><rename>last_updated</rename><type>Date</type></field>
        </fields>
    </step>
    
    <!-- 写入 StarRocks 聚合表 -->
    <step>
        <name>Load to StarRocks Aggregate Table</name>
        <type>TableOutput</type>
        <connection>StarRocks_Connection</connection>
        <table>annual_sales_summary</table>
        <commit_size>1000</commit_size>
        <use_batch>Y</use_batch>
        <batch_size>1000</batch_size>
    </step>
    
    <!-- 记录处理统计 -->
    <step>
        <name>Log Processing Statistics</name>
        <type>WriteToLog</type>
        <loglevel>basic</loglevel>
        <logmessage>月度聚合完成 - 年份: ${PROCESS_YEAR}, 月份: ${PROCESS_MONTH}, 处理记录数: #</logmessage>
    </step>
</transformation>
```

### 7.4 聚合模型特殊处理要点

#### 7.4.1 聚合函数选择策略

```sql
-- 不同业务指标的聚合函数选择
CREATE TABLE business_metrics_agg (
    time_period VARCHAR(20),
    metric_name VARCHAR(100),
    
    -- SUM：累加类指标（销售额、订单量等）
    total_amount DECIMAL(18,2) SUM DEFAULT "0",
    order_count BIGINT SUM DEFAULT "0",
    
    -- MAX：最大值指标（最高单价、峰值等）
    max_order_amount DECIMAL(18,2) MAX DEFAULT "0",
    peak_concurrent_users INT MAX DEFAULT "0",
    
    -- MIN：最小值指标（最低价格等）
    min_order_amount DECIMAL(18,2) MIN DEFAULT "999999",
    
    -- REPLACE：替换类指标（最新状态、平均值等）
    latest_status VARCHAR(50) REPLACE DEFAULT "unknown",
    avg_rating DECIMAL(3,2) REPLACE DEFAULT "0",
    
    -- REPLACE_IF_NOT_NULL：非空替换
    last_update_time DATETIME REPLACE_IF_NOT_NULL DEFAULT "1900-01-01 00:00:00"
) ENGINE=OLAP
AGGREGATE KEY(time_period, metric_name)
DISTRIBUTED BY HASH(time_period) BUCKETS 4;
```

#### 7.4.2 Kettle 中的聚合处理逻辑

```javascript
// 在 JavaScript 步骤中处理复杂聚合逻辑
var currentSales = parseFloat(getVariable("CURRENT_SALES", "0"));
var newMonthlySales = parseFloat(monthly_sales);

// 累计计算年度销售额
var yearToDateSales = currentSales + newMonthlySales;
setVariable("CURRENT_SALES", yearToDateSales.toString());

// 计算同比增长率
var lastYearSales = parseFloat(getVariable("LAST_YEAR_SALES", "0"));
var growthRate = lastYearSales > 0 ? (yearToDateSales - lastYearSales) / lastYearSales * 100 : 0;

// 输出聚合结果
total_sales = yearToDateSales;
growth_rate = Math.round(growthRate * 100) / 100;  // 保留两位小数

writeToLog("i", "年度累计销售额: " + yearToDateSales + ", 同比增长: " + growthRate + "%");
```

### 7.5 性能优化策略

#### 7.5.1 批量加载优化

```sql
-- 使用 Stream Load 进行高效批量写入
curl --location-trusted -u root: \
    -H "label:aggregate_load_$(date +%s)" \
    -H "column_separator:," \
    -H "skip_header:1" \
    -H "max_filter_ratio:0.1" \
    -H "timeout:300" \
    -T monthly_aggregate_${PROCESS_YEAR}_${PROCESS_MONTH}.csv \
    http://starrocks-fe:8040/api/warehouse/annual_sales_summary/_stream_load
```

#### 7.5.2 分区策略配合

```sql
-- 创建支持动态分区的聚合表
CREATE TABLE annual_sales_summary_partitioned (
    year_id INT NOT NULL,
    region_code VARCHAR(50) NOT NULL,
    product_category VARCHAR(100) NOT NULL,
    total_sales DECIMAL(18,2) SUM DEFAULT "0",
    total_orders BIGINT SUM DEFAULT "0"
) ENGINE=OLAP
AGGREGATE KEY(year_id, region_code, product_category)
PARTITION BY RANGE(year_id) (
    PARTITION p2021 VALUES [("2021"), ("2022")),
    PARTITION p2022 VALUES [("2022"), ("2023")),
    PARTITION p2023 VALUES [("2023"), ("2024"))
)
DISTRIBUTED BY HASH(region_code) BUCKETS 8
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "YEAR",
    "dynamic_partition.start" = "-2",
    "dynamic_partition.end" = "1",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "8"
);
```

### 7.6 监控和调试

#### 7.6.1 聚合过程监控

```sql
-- 创建聚合进度监控表
CREATE TABLE aggregation_progress (
    batch_id VARCHAR(64),
    process_year INT,
    process_month INT,
    start_time DATETIME,
    end_time DATETIME,
    source_rows BIGINT,
    target_rows BIGINT,
    status ENUM('running', 'completed', 'failed'),
    error_message TEXT,
    PRIMARY KEY (batch_id, process_year, process_month)
) ENGINE=OLAP
DUPLICATE KEY(batch_id)
DISTRIBUTED BY HASH(batch_id) BUCKETS 4;
```

#### 7.6.2 数据一致性验证

```javascript
// 在 Kettle 中验证聚合结果
var sourceSum = getVariableFromDB(
    "SELECT SUM(sale_amount) FROM sales_detail WHERE DATE_FORMAT(order_date, '%Y-%m') = '" + 
    getVariable("PROCESS_YEAR") + "-" + getVariable("PROCESS_MONTH") + "'"
);

var targetSum = getVariableFromDB(
    "SELECT SUM(total_sales) FROM annual_sales_summary WHERE year_id = " + 
    getVariable("PROCESS_YEAR") + " AND last_updated >= '" + getVariable("BATCH_START_TIME") + "'"
);

var variance = Math.abs(sourceSum - targetSum);
var tolerance = sourceSum * 0.001;  // 0.1% 容差

if (variance > tolerance) {
    writeToLog("e", "数据一致性检查失败：源数据合计=" + sourceSum + ", 目标数据合计=" + targetSum);
    throw new Error("聚合结果不一致");
} else {
    writeToLog("i", "数据一致性验证通过：差异=" + variance + " (容差=" + tolerance + ")");
}
```

### 7.7 最佳实践要点

#### 7.7.1 循环处理建议
- **循环粒度**：按月循环比按日循环更高效，减少网络开销
- **错误隔离**：单月失败不影响其他月份处理
- **进度保存**：记录每月处理状态，支持断点续传
- **资源控制**：避免在高峰期运行大量聚合作业

#### 7.7.2 聚合表设计原则
- **合理选择聚合函数**：根据业务语义选择 SUM/MAX/MIN/REPLACE
- **聚合键设计**：包含所有分组维度，避免过度聚合
- **默认值设置**：为聚合列设置合适的默认值
- **索引策略**：聚合键自动创建前缀索引，无需额外索引

#### 7.7.3 性能优化要点
- **批量大小**：每批处理 1-10 万条记录较为合适
- **并发控制**：避免过多并发写入同一聚合表
- **分区对齐**：源表分区策略与聚合表分区策略保持一致
- **预聚合**：在源端先进行部分聚合，减少传输数据量

通过合理的循环设计和聚合模型配置，可以高效地处理大规模历史数据的分批聚合需求。

## 8. 最佳实践总结

### 8.1 分片策略选择
- **历史数据迁移**：优先使用时间范围分片，与 StarRocks 分区策略对应
- **大表全量同步**：使用主键范围分片，确保数据完整性
- **实时数据处理**：使用 Hash 分片，保证负载均衡

### 8.2 并行度设置
- **CPU 密集型**：并行度 = CPU 核心数
- **I/O 密集型**：并行度 = CPU 核心数 × 2
- **内存受限型**：根据可用内存动态调整

### 8.3 资源管理要点
- 设置合理的 JVM 堆内存，通常为系统内存的 60-70%
- 使用连接池避免频繁创建数据库连接
- 实施流量控制，防止系统过载
- 定期监控和清理临时文件

### 8.4 错误处理策略
- 实现分片级错误隔离，单个分片失败不影响整体
- 采用指数退避重试策略，避免雪崩效应
- 支持断点续传，提高处理效率
- 建立完善的监控告警机制

### 8.5 性能调优建议
- 定期分析性能指标，识别瓶颈点
- 优化 SQL 查询，使用合适的索引
- 调整批量大小，平衡内存使用和处理效率
- 使用 Stream Load 替代 INSERT 提升写入性能

### 8.6 聚合表循环处理要点
- **循环设计**：合理设计年度-月份嵌套循环，确保错误隔离
- **聚合函数**：根据业务语义选择合适的聚合函数（SUM/MAX/MIN/REPLACE）
- **性能优化**：配合 StarRocks 分区策略，使用 Stream Load 提升写入性能
- **监控验证**：建立完善的进度监控和数据一致性验证机制

通过合理的批量处理策略，可以显著提升大数据量的 ETL 处理效率和系统稳定性。聚合表配合循环处理为复杂的历史数据聚合场景提供了高效可靠的解决方案。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](modern-etl-tools.md) | [➡️ 下一页](kettle-scripting.md)
---