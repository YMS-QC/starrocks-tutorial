---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](modern-etl-tools.md) | [➡️ 下一页](error-handling-mechanisms.md)
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

## 7. 最佳实践总结

### 7.1 分片策略选择
- **历史数据迁移**：优先使用时间范围分片，与 StarRocks 分区策略对应
- **大表全量同步**：使用主键范围分片，确保数据完整性
- **实时数据处理**：使用 Hash 分片，保证负载均衡

### 7.2 并行度设置
- **CPU 密集型**：并行度 = CPU 核心数
- **I/O 密集型**：并行度 = CPU 核心数 × 2
- **内存受限型**：根据可用内存动态调整

### 7.3 资源管理要点
- 设置合理的 JVM 堆内存，通常为系统内存的 60-70%
- 使用连接池避免频繁创建数据库连接
- 实施流量控制，防止系统过载
- 定期监控和清理临时文件

### 7.4 错误处理策略
- 实现分片级错误隔离，单个分片失败不影响整体
- 采用指数退避重试策略，避免雪崩效应
- 支持断点续传，提高处理效率
- 建立完善的监控告警机制

### 7.5 性能调优建议
- 定期分析性能指标，识别瓶颈点
- 优化 SQL 查询，使用合适的索引
- 调整批量大小，平衡内存使用和处理效率
- 使用 Stream Load 替代 INSERT 提升写入性能

通过合理的批量处理策略，可以显著提升大数据量的 ETL 处理效率和系统稳定性。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](modern-etl-tools.md) | [➡️ 下一页](error-handling-mechanisms.md)
---