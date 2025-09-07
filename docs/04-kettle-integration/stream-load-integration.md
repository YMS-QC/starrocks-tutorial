---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](mysql-to-starrocks.md) | [➡️ 下一页](modern-etl-tools.md)
---

# Kettle Stream Load 集成

本章节详细介绍如何在 Kettle/PDI 中集成 StarRocks Stream Load 功能，实现高效的批量数据导入，包括 HTTP 调用配置、数据格式处理和性能优化策略。

## 1. Stream Load 基础概念

### 1.1 Stream Load 介绍

Stream Load 是 StarRocks 提供的高性能数据导入方式，具有以下特点：
- **实时导入**：支持流式数据导入，延迟低
- **高吞吐**：支持大批量数据快速导入
- **事务性**：导入过程具有事务特性，保证数据一致性
- **灵活性**：支持 CSV、JSON 等多种数据格式

### 1.2 Stream Load vs INSERT 对比

| 特性 | Stream Load | INSERT |
|------|------------|---------|
| 性能 | 高（批量优化） | 中等（逐行处理） |
| 事务 | 支持大批量事务 | 支持小批量事务 |
| 数据格式 | CSV、JSON、Parquet | SQL VALUES |
| 资源消耗 | 低（流式处理） | 高（SQL 解析） |
| 错误处理 | 灵活的错误策略 | 标准 SQL 错误 |
| 适用场景 | 大批量 ETL | 小批量 OLTP |

## 2. Kettle 中的 Stream Load 实现

### 2.1 HTTP Client 步骤配置

```xml
<!-- HTTP Client 步骤配置 -->
<step>
    <name>StarRocks Stream Load</name>
    <type>HTTP</type>
    <method>PUT</method>
    <url>http://starrocks_host:8030/api/database_name/table_name/_stream_load</url>
    <headers>
        <header>
            <name>Authorization</name>
            <value>Basic ${BASE64_CREDENTIALS}</value>
        </header>
        <header>
            <name>Content-Type</name>
            <value>text/plain</value>
        </header>
        <header>
            <name>column_separator</name>
            <value>,</value>
        </header>
        <header>
            <name>timeout</name>
            <value>3600</value>
        </header>
        <header>
            <name>max_filter_ratio</name>
            <value>0.1</value>
        </header>
    </headers>
    <body_field>csv_data</body_field>
    <result_field>load_result</result_field>
    <response_time_field>response_time</response_time_field>
    <response_header_field>response_headers</response_header_field>
</step>
```

### 2.2 数据格式转换流程

```
Table Input (Source Database)
    ↓
Select Values (Data Type Conversion)
    ↓
Text File Output (Generate CSV)  -- 生成 CSV 数据
    ↓
File Input (Read CSV as Single Field)
    ↓
HTTP Client (Stream Load)
    ↓
JSON Input (Parse Response)
    ↓
Filter Rows (Check Success)
    ↓
Update Status
```

### 2.3 CSV 数据生成

```javascript
// JavaScript 步骤：生成 CSV 行
var csv_line = "";
var fields = [user_id, product_id, order_date, amount, status, created_at];

for (var i = 0; i < fields.length; i++) {
    var field_value = fields[i];
    
    // 处理 null 值
    if (field_value == null || field_value == undefined) {
        field_value = "\\N";
    }
    // 处理字符串中的特殊字符
    else if (typeof field_value === 'string') {
        field_value = field_value.replace(/"/g, '""');  // 转义双引号
        if (field_value.indexOf(',') >= 0 || field_value.indexOf('\n') >= 0) {
            field_value = '"' + field_value + '"';      // 包含逗号或换行符的字段加引号
        }
    }
    // 处理日期时间格式
    else if (field_value instanceof Date) {
        field_value = field_value.toISOString().slice(0, 19).replace('T', ' ');
    }
    
    csv_line += (i > 0 ? "," : "") + field_value;
}

csv_data = csv_line;
```

## 3. 高级配置和优化

### 3.1 认证和安全配置

```javascript
// 生成 Basic Auth 认证头
var username = "root";
var password = "";
var credentials = username + ":" + password;
var base64_credentials = Packages.java.util.Base64.getEncoder().encodeToString(
    new java.lang.String(credentials).getBytes("UTF-8")
);
BASE64_CREDENTIALS = base64_credentials;

// 或使用变量替换
// ${STARROCKS_USER}:${STARROCKS_PASSWORD}
```

### 3.2 完整的 Stream Load Headers

```xml
<headers>
    <!-- 基础认证 -->
    <header><name>Authorization</name><value>Basic ${BASE64_CREDENTIALS}</value></header>
    
    <!-- 数据格式配置 -->
    <header><name>column_separator</name><value>,</value></header>
    <header><name>row_delimiter</name><value>\n</value></header>
    <header><name>skip_header</name><value>0</value></header>
    
    <!-- 数据处理配置 -->
    <header><name>max_filter_ratio</name><value>0.1</value></header>
    <header><name>timeout</name><value>3600</value></header>
    <header><name>strict_mode</name><value>false</value></header>
    
    <!-- 性能优化配置 -->
    <header><name>load_mem_limit</name><value>2147483648</value></header>
    <header><name>partial_update</name><value>false</value></header>
    
    <!-- 字符编码 -->
    <header><name>format</name><value>csv</value></header>
    <header><name>charset</name><value>UTF-8</value></header>
    
    <!-- 错误处理 -->
    <header><name>log_rejected_record_num</name><value>1000</value></header>
</headers>
```

### 3.3 JSON 格式 Stream Load

```xml
<!-- JSON 格式配置 -->
<headers>
    <header><name>Content-Type</name><value>application/json</value></header>
    <header><name>format</name><value>json</value></header>
    <header><name>jsonpaths</name><value>["$.user_id","$.product_id","$.order_date","$.amount","$.status"]</value></header>
    <header><name>strip_outer_array</name><value>true</value></header>
</headers>
```

```javascript
// JavaScript: 生成 JSON 数据
var json_record = {
    "user_id": user_id,
    "product_id": product_id, 
    "order_date": order_date_str,
    "amount": amount,
    "status": status,
    "created_at": created_at_str
};

if (json_batch == null) {
    json_batch = [];
}
json_batch.push(json_record);

// 当批次达到指定大小时，输出 JSON 数组
if (json_batch.length >= batch_size) {
    json_data = JSON.stringify(json_batch);
    json_batch = [];  // 重置批次
} else {
    json_data = null; // 继续积累
}
```

## 4. 错误处理和重试机制

### 4.1 响应解析

```javascript
// JavaScript: 解析 Stream Load 响应
var response = JSON.parse(load_result);

load_status = response.Status;
load_message = response.Message;
loaded_rows = response.NumberLoadedRows || 0;
filtered_rows = response.NumberFilteredRows || 0;
unselected_rows = response.NumberUnselectedRows || 0;
load_bytes = response.LoadBytes || 0;
load_time_ms = response.LoadTimeMs || 0;

// 判断加载是否成功
if (load_status == "Success") {
    success_flag = true;
    error_message = null;
} else {
    success_flag = false;
    error_message = load_message;
    
    // 记录错误详情
    if (response.ErrorURL) {
        error_url = response.ErrorURL;
        // 可以通过 HTTP Client 获取详细错误信息
    }
}

// 计算成功率
if (loaded_rows + filtered_rows > 0) {
    success_rate = loaded_rows * 1.0 / (loaded_rows + filtered_rows);
} else {
    success_rate = 0;
}
```

### 4.2 重试逻辑实现

```xml
<!-- 重试作业设计 -->
<job>
    <name>Stream Load with Retry</name>
    
    <!-- 初始化重试计数器 -->
    <entry>
        <name>Init Retry Counter</name>
        <type>EVAL</type>
        <script>
            parent_job.setVariable("RETRY_COUNT", "0");
            parent_job.setVariable("MAX_RETRY", "3");
        </script>
    </entry>
    
    <!-- 执行 Stream Load 转换 -->
    <entry>
        <name>Execute Stream Load</name>
        <type>TRANS</type>
        <filename>stream_load_transform.ktr</filename>
        <on_error>RETRY_LOGIC</on_error>
    </entry>
    
    <!-- 重试逻辑 -->
    <entry>
        <name>RETRY_LOGIC</name>
        <type>EVAL</type>
        <script>
            var retry_count = parseInt(parent_job.getVariable("RETRY_COUNT"));
            var max_retry = parseInt(parent_job.getVariable("MAX_RETRY"));
            
            if (retry_count < max_retry) {
                parent_job.setVariable("RETRY_COUNT", (retry_count + 1).toString());
                // 等待一段时间后重试
                java.lang.Thread.sleep(5000 * Math.pow(2, retry_count)); // 指数退避
                return true;  // 继续重试
            } else {
                return false; // 达到最大重试次数，停止
            }
        </script>
        <on_success>Execute Stream Load</on_success>
    </entry>
    
    <!-- 失败处理 -->
    <entry>
        <name>Handle Final Failure</name>
        <type>MAIL</type>
        <server>smtp_server</server>
        <subject>Stream Load 失败通知</subject>
        <message>Stream Load 任务在 ${MAX_RETRY} 次重试后仍然失败</message>
    </entry>
</job>
```

### 4.3 部分成功处理策略

```javascript
// 处理部分成功的情况
if (load_status == "Success" && filtered_rows > 0) {
    var filter_ratio = filtered_rows * 1.0 / (loaded_rows + filtered_rows);
    
    if (filter_ratio > acceptable_filter_ratio) {
        // 过滤率过高，需要人工处理
        alert_flag = true;
        alert_message = "过滤率过高: " + (filter_ratio * 100).toFixed(2) + "%";
        
        // 记录问题数据供后续分析
        problem_data_flag = true;
    } else {
        // 可接受的过滤率，记录日志继续
        alert_flag = false;
        writeToLog("w", "存在过滤数据，过滤率: " + (filter_ratio * 100).toFixed(2) + "%");
    }
}
```

## 5. 性能优化策略

### 5.1 批量大小优化

```javascript
// 动态调整批量大小
var current_batch_size = parseInt(getVariable("BATCH_SIZE", "10000"));
var last_load_time = parseInt(getVariable("LAST_LOAD_TIME", "0"));
var target_load_time = 30000; // 目标加载时间 30 秒

if (last_load_time > 0) {
    if (last_load_time < target_load_time * 0.7) {
        // 加载时间过短，增加批量大小
        current_batch_size = Math.min(current_batch_size * 1.2, 100000);
    } else if (last_load_time > target_load_time * 1.3) {
        // 加载时间过长，减少批量大小  
        current_batch_size = Math.max(current_batch_size * 0.8, 1000);
    }
    
    setVariable("BATCH_SIZE", current_batch_size.toString());
}

batch_size = current_batch_size;
```

### 5.2 并行 Stream Load

```xml
<!-- 使用 Data Grid 步骤创建多个并行流 -->
<step>
    <name>Create Parallel Streams</name>
    <type>DataGrid</type>
    <data>
        <line><item>0</item></line>
        <line><item>1</item></line>
        <line><item>2</item></line>
        <line><item>3</item></line>
    </data>
    <fields>
        <field><name>stream_id</name><type>Integer</type></field>
    </fields>
</step>

<!-- 分流处理 -->
<step>
    <name>Distribute Data</name>
    <type>Calculator</type>
    <calculation>
        <field_name>shard_key</field_name>
        <calc_type>MOD</calc_type>
        <field_a>record_id</field_a>
        <field_b>4</field_b>  <!-- 4个并行流 -->
        <value_type>Integer</value_type>
    </calculation>
</step>

<!-- 多个 Stream Load 步骤并行执行 -->
<step>
    <name>Stream Load 0</name>
    <type>FilterRows</type>
    <condition>
        <field>shard_key</field>
        <function>=</function>
        <value>0</value>
    </condition>
    <target_step>HTTP Stream Load</target_step>
</step>
```

### 5.3 连接池优化

```xml
<!-- HTTP 连接池配置 -->
<step_performance_capturing_enabled>Y</step_performance_capturing_enabled>
<step_performance_capturing_size_limit>100</step_performance_capturing_size_limit>

<!-- HTTP Client 高级配置 -->
<http_client_config>
    <socket_timeout>300000</socket_timeout>
    <connection_timeout>60000</connection_timeout>
    <connection_pool_timeout>60000</connection_pool_timeout>
    <max_connections_per_host>10</max_connections_per_host>
    <max_total_connections>50</max_total_connections>
    <close_idle_connections_time>300</close_idle_connections_time>
</http_client_config>
```

## 6. 监控和日志

### 6.1 性能指标监控

```javascript
// 性能指标计算
var throughput_mb_per_sec = (load_bytes / 1024 / 1024) / (load_time_ms / 1000);
var records_per_sec = loaded_rows / (load_time_ms / 1000);
var avg_record_size = load_bytes / loaded_rows;

// 记录性能指标
writeToLog("i", "Stream Load 性能指标:");
writeToLog("i", "  - 吞吐量: " + throughput_mb_per_sec.toFixed(2) + " MB/s");
writeToLog("i", "  - 记录速率: " + records_per_sec.toFixed(0) + " records/s");
writeToLog("i", "  - 平均记录大小: " + avg_record_size.toFixed(0) + " bytes");
writeToLog("i", "  - 总耗时: " + (load_time_ms / 1000).toFixed(2) + " s");

// 设置变量供后续步骤使用
setVariable("THROUGHPUT", throughput_mb_per_sec.toFixed(2));
setVariable("RECORDS_PER_SEC", records_per_sec.toFixed(0));
```

### 6.2 详细日志记录

```xml
<!-- 日志记录步骤 -->
<step>
    <name>Log Stream Load Result</name>
    <type>WriteToLog</type>
    <loglevel>basic</loglevel>
    <displayHeader>Y</displayHeader>
    <logmessage>Stream Load completed</logmessage>
    <fields>
        <field><name>load_status</name></field>
        <field><name>loaded_rows</name></field>
        <field><name>filtered_rows</name></field>
        <field><name>load_time_ms</name></field>
        <field><name>throughput</name></field>
    </fields>
</step>

<!-- 错误日志记录 -->
<step>
    <name>Log Error Details</name>
    <type>Abort</type>
    <row_threshold>0</row_threshold>
    <message>Stream Load failed: ${error_message}</message>
    <always_log_rows>Y</always_log_rows>
</step>
```

### 6.3 监控告警

```bash
#!/bin/bash
# stream_load_monitor.sh

LOG_FILE="/path/to/stream_load.log"
ALERT_THRESHOLD_MB_PER_SEC=10
ALERT_EMAIL="admin@company.com"

# 解析最新的吞吐量
LATEST_THROUGHPUT=$(tail -100 "$LOG_FILE" | grep "吞吐量:" | tail -1 | awk '{print $3}' | sed 's/MB\/s//')

if [ -n "$LATEST_THROUGHPUT" ]; then
    # 检查吞吐量是否低于阈值
    if (( $(echo "$LATEST_THROUGHPUT < $ALERT_THRESHOLD_MB_PER_SEC" | bc -l) )); then
        echo "Stream Load 性能告警: 当前吞吐量 ${LATEST_THROUGHPUT} MB/s 低于阈值 ${ALERT_THRESHOLD_MB_PER_SEC} MB/s" | \
        mail -s "Stream Load 性能告警" "$ALERT_EMAIL"
    fi
fi

# 检查错误率
ERROR_COUNT=$(tail -1000 "$LOG_FILE" | grep -c "Stream Load failed")
TOTAL_COUNT=$(tail -1000 "$LOG_FILE" | grep -c "Stream Load completed\|Stream Load failed")

if [ "$TOTAL_COUNT" -gt 0 ]; then
    ERROR_RATE=$(echo "scale=2; $ERROR_COUNT * 100 / $TOTAL_COUNT" | bc)
    if (( $(echo "$ERROR_RATE > 5" | bc -l) )); then
        echo "Stream Load 错误率告警: 当前错误率 ${ERROR_RATE}% 高于 5%" | \
        mail -s "Stream Load 错误率告警" "$ALERT_EMAIL"
    fi
fi
```

## 7. Stream Load 事务API详解

> **版本要求**：Stream Load事务API从StarRocks 2.4版本开始支持，支持2PC（两阶段提交）

### 7.1 事务API概述

Stream Load事务API提供了完整的两阶段提交能力，确保数据导入的ACID特性：

| API接口 | 作用 | 阶段 | 必需 |
|---------|------|------|------|
| `/api/transaction/begin` | 开始事务 | 准备 | ✅ |
| `/api/transaction/load` | 加载数据 | 执行 | ✅ |
| `/api/transaction/prepare` | 预提交 | 准备提交 | ✅ |
| `/api/transaction/commit` | 提交事务 | 最终提交 | ✅ |
| `/api/transaction/rollback` | 回滚事务 | 错误处理 | 可选 |

### 7.2 事务API使用流程

#### 完整的事务处理流程
```bash
# 1. 开始事务
curl --location-trusted -u root: \
    -H "label:etl_transaction_001" \
    -H "Expect:100-continue" \
    -H "db:demo_etl" \
    -H "table:user_behavior" \
    -H "timeout:600" \
    -H "idle_transaction_timeout:300" \
    -XPOST http://fe_host:8040/api/transaction/begin

# 返回示例：
{
    "TxnId": 12345,
    "Label": "etl_transaction_001", 
    "Status": "OK",
    "Message": ""
}

# 2. 加载数据（可多次调用）
curl --location-trusted -u root: \
    -H "label:etl_transaction_001" \
    -H "Expect:100-continue" \
    -H "db:demo_etl" \
    -H "table:user_behavior" \
    -H "column_separator:," \
    -H "row_delimiter:\n" \
    -H "max_filter_ratio:0.1" \
    --data-binary @user_data_part1.csv \
    -XPOST http://fe_host:8040/api/transaction/load

# 加载更多数据
curl --location-trusted -u root: \
    -H "label:etl_transaction_001" \
    --data-binary @user_data_part2.csv \
    -XPOST http://fe_host:8040/api/transaction/load

# 3. 预提交
curl --location-trusted -u root: \
    -H "label:etl_transaction_001" \
    -H "Expect:100-continue" \
    -H "db:demo_etl" \
    -H "prepared_timeout:3600" \
    -XPOST http://fe_host:8040/api/transaction/prepare

# 4. 提交事务
curl --location-trusted -u root: \
    -H "label:etl_transaction_001" \
    -H "Expect:100-continue" \
    -H "db:demo_etl" \
    -XPOST http://fe_host:8040/api/transaction/commit
```

### 7.3 Kettle中的事务API集成

#### HTTP Client步骤配置
```javascript
// Kettle JavaScript步骤：Stream Load事务处理
function executeStreamLoadTransaction() {
    var fe_host = "localhost";
    var fe_port = "8040";
    var base_url = "http://" + fe_host + ":" + fe_port;
    
    var transaction_label = "kettle_job_" + getCurrentTimestamp();
    var database = "demo_etl";
    var table = "user_behavior";
    
    logBasic("Starting Stream Load transaction: " + transaction_label);
    
    try {
        // 1. 开始事务
        var beginParams = {
            url: base_url + "/api/transaction/begin",
            method: "POST",
            headers: {
                "Authorization": "Basic " + java.util.Base64.getEncoder().encodeToString("root:".getBytes()),
                "label": transaction_label,
                "Expect": "100-continue",
                "db": database,
                "table": table,
                "timeout": "1200",
                "idle_transaction_timeout": "300"
            }
        };
        
        var beginResponse = executeHttpRequest(beginParams);
        if (beginResponse.status !== "OK") {
            throw new Error("Begin transaction failed: " + beginResponse.message);
        }
        
        var txnId = beginResponse.txnId;
        logBasic("Transaction started successfully: " + txnId);
        
        // 2. 加载数据（支持多次调用）
        var dataFiles = getDataFilesToProcess(); // 获取待处理文件列表
        
        for (var i = 0; i < dataFiles.length; i++) {
            var dataFile = dataFiles[i];
            var fileContent = readFileContent(dataFile);
            
            var loadParams = {
                url: base_url + "/api/transaction/load",
                method: "POST",
                headers: {
                    "Authorization": "Basic " + java.util.Base64.getEncoder().encodeToString("root:".getBytes()),
                    "label": transaction_label,
                    "Expect": "100-continue",
                    "db": database,
                    "table": table,
                    "column_separator": ",",
                    "row_delimiter": "\\n",
                    "max_filter_ratio": "0.1",
                    "Content-Type": "text/plain"
                },
                data: fileContent
            };
            
            var loadResponse = executeHttpRequest(loadParams);
            if (loadResponse.status !== "OK") {
                // 加载失败，回滚事务
                rollbackTransaction(base_url, transaction_label);
                throw new Error("Load data failed for file " + dataFile + ": " + loadResponse.message);
            }
            
            logBasic("Data loaded successfully from: " + dataFile + 
                    " (Rows: " + loadResponse.numberLoadedRows + 
                    ", Filtered: " + loadResponse.numberFilteredRows + ")");
        }
        
        // 3. 预提交
        var prepareParams = {
            url: base_url + "/api/transaction/prepare", 
            method: "POST",
            headers: {
                "Authorization": "Basic " + java.util.Base64.getEncoder().encodeToString("root:".getBytes()),
                "label": transaction_label,
                "Expect": "100-continue",
                "db": database,
                "prepared_timeout": "3600"
            }
        };
        
        var prepareResponse = executeHttpRequest(prepareParams);
        if (prepareResponse.status !== "OK") {
            rollbackTransaction(base_url, transaction_label);
            throw new Error("Prepare transaction failed: " + prepareResponse.message);
        }
        
        logBasic("Transaction prepared successfully");
        
        // 4. 提交事务
        var commitParams = {
            url: base_url + "/api/transaction/commit",
            method: "POST", 
            headers: {
                "Authorization": "Basic " + java.util.Base64.getEncoder().encodeToString("root:".getBytes()),
                "label": transaction_label,
                "Expect": "100-continue",
                "db": database
            }
        };
        
        var commitResponse = executeHttpRequest(commitParams);
        if (commitResponse.status === "OK") {
            logBasic("Transaction committed successfully: " + 
                    "Total rows: " + commitResponse.numberTotalRows + 
                    ", Load time: " + commitResponse.loadTimeMs + "ms");
            return true;
        } else if (commitResponse.message === "Transaction already commited") {
            logBasic("Transaction already committed: " + transaction_label);
            return true;
        } else {
            throw new Error("Commit transaction failed: " + commitResponse.message);
        }
        
    } catch (e) {
        logError("Stream Load transaction failed: " + e.message);
        // 尝试回滚事务
        try {
            rollbackTransaction(base_url, transaction_label);
        } catch (rollbackError) {
            logError("Rollback failed: " + rollbackError.message);
        }
        throw e;
    }
}

// 回滚事务的辅助函数
function rollbackTransaction(base_url, transaction_label) {
    var rollbackParams = {
        url: base_url + "/api/transaction/rollback",
        method: "POST",
        headers: {
            "Authorization": "Basic " + java.util.Base64.getEncoder().encodeToString("root:".getBytes()),
            "label": transaction_label,
            "Expect": "100-continue"
        }
    };
    
    var rollbackResponse = executeHttpRequest(rollbackParams);
    if (rollbackResponse.status === "OK") {
        logBasic("Transaction rolled back successfully: " + transaction_label);
    } else {
        logError("Rollback failed: " + rollbackResponse.message);
    }
}
```

### 7.4 事务状态监控和调试

#### 事务状态查询
```sql
-- 查看当前运行的事务
SHOW PROC '/transaction';

-- 查看指定数据库的事务
SHOW PROC '/transaction/demo_etl';

-- 查看事务详细信息
SELECT 
    transaction_id,
    label,
    state,
    db_name,
    table_name,
    create_time,
    commit_time,
    timeout_second
FROM information_schema.transactions 
WHERE label LIKE 'kettle_job_%'
ORDER BY create_time DESC
LIMIT 10;
```

#### 事务性能监控
```javascript
// Kettle中监控事务性能
function monitorTransactionPerformance(txn_label) {
    var start_time = System.currentTimeMillis();
    
    try {
        // 执行事务逻辑
        executeStreamLoadTransaction();
        
        var end_time = System.currentTimeMillis();
        var duration = end_time - start_time;
        
        // 记录性能指标
        logBasic("Transaction performance metrics:");
        logBasic("  Label: " + txn_label);
        logBasic("  Duration: " + duration + " ms");
        logBasic("  Throughput: " + calculateThroughput(total_records, duration) + " records/sec");
        
        // 性能告警检查
        if (duration > 300000) { // 5分钟
            logError("Transaction duration warning: " + duration + " ms exceeds 5 minutes");
            sendPerformanceAlert(txn_label, duration);
        }
        
    } catch (e) {
        var end_time = System.currentTimeMillis();
        var duration = end_time - start_time;
        
        logError("Transaction failed after " + duration + " ms: " + e.message);
        sendTransactionFailureAlert(txn_label, duration, e.message);
        throw e;
    }
}
```

### 7.5 事务错误处理和重试策略

#### 智能重试机制
```javascript
// 事务智能重试处理
function executeStreamLoadWithRetry() {
    var max_retries = 3;
    var base_delay = 5000; // 5秒基础延迟
    
    for (var attempt = 1; attempt <= max_retries; attempt++) {
        var transaction_label = "kettle_retry_" + getCurrentTimestamp() + "_attempt_" + attempt;
        
        try {
            logBasic("Transaction attempt " + attempt + "/" + max_retries + ": " + transaction_label);
            
            return executeStreamLoadTransaction(transaction_label);
            
        } catch (e) {
            logError("Transaction attempt " + attempt + " failed: " + e.message);
            
            // 根据错误类型决定是否重试
            if (!isRetryableError(e.message)) {
                logError("Non-retryable error, aborting: " + e.message);
                throw e;
            }
            
            // 最后一次尝试失败
            if (attempt === max_retries) {
                logError("All retry attempts exhausted");
                throw e;
            }
            
            // 指数退避延迟
            var delay = base_delay * Math.pow(2, attempt - 1);
            logBasic("Retrying after " + delay + " ms...");
            Thread.sleep(delay);
        }
    }
}

// 判断错误是否可重试
function isRetryableError(error_message) {
    var retryable_errors = [
        "timeout",
        "connect failed",
        "network error", 
        "temporary unavailable",
        "too many concurrent transactions"
    ];
    
    for (var i = 0; i < retryable_errors.length; i++) {
        if (error_message.toLowerCase().indexOf(retryable_errors[i]) >= 0) {
            return true;
        }
    }
    
    // 不可重试的错误
    var non_retryable_errors = [
        "data format error",
        "column not found",
        "table not exist",
        "permission denied"
    ];
    
    for (var i = 0; i < non_retryable_errors.length; i++) {
        if (error_message.toLowerCase().indexOf(non_retryable_errors[i]) >= 0) {
            return false;
        }
    }
    
    // 默认可重试
    return true;
}
```

### 7.6 事务配置优化

#### 超时参数调优
```bash
# FE配置文件调优
# 事务相关配置
prepared_transaction_default_timeout_second = 3600    # 预备事务默认超时1小时
label_keep_max_second = 259200                        # 标签保留3天
label_keep_max_num = 10000                           # 最大标签数量
max_running_txn_num_per_db = 2000                    # 单数据库最大并发事务数
```

#### Kettle作业级别优化
```javascript
// 作业级别的事务配置优化
function configureTransactionOptimal() {
    // 根据数据量调整超时
    var record_count = getEstimatedRecordCount();
    var timeout_seconds;
    
    if (record_count < 100000) {
        timeout_seconds = 300;      // 5分钟
    } else if (record_count < 1000000) {
        timeout_seconds = 1200;     // 20分钟  
    } else {
        timeout_seconds = 3600;     // 1小时
    }
    
    // 根据并发度调整批量大小
    var concurrent_jobs = getCurrentConcurrentJobCount();
    var batch_size;
    
    if (concurrent_jobs <= 2) {
        batch_size = 100000;        // 高批量
    } else if (concurrent_jobs <= 5) {
        batch_size = 50000;         // 中批量
    } else {
        batch_size = 20000;         // 低批量，避免并发冲突
    }
    
    logBasic("Transaction configuration:");
    logBasic("  Estimated records: " + record_count);
    logBasic("  Timeout: " + timeout_seconds + " seconds");
    logBasic("  Batch size: " + batch_size);
    logBasic("  Concurrent jobs: " + concurrent_jobs);
    
    return {
        timeout: timeout_seconds,
        batch_size: batch_size,
        idle_timeout: Math.min(timeout_seconds / 2, 1800) // 空闲超时不超过30分钟
    };
}
```

## 8. 最佳实践总结

### 8.1 数据格式选择
- **小批量数据**：使用 JSON 格式，便于调试和错误定位
- **大批量数据**：使用 CSV 格式，性能更好，占用空间更小  
- **复杂嵌套数据**：使用 JSON 格式，支持复杂数据结构

### 8.2 批量大小调优
- **初始批量**：10,000 - 50,000 行/批
- **内存充足**：可适当增加到 100,000 行/批
- **网络较慢**：适当减少批量大小，避免超时

### 8.3 错误处理策略
- 设置合理的 `max_filter_ratio`，通常 0.01 - 0.1
- 实施指数退避重试机制
- 记录详细的错误信息和问题数据
- 建立告警机制，及时发现和处理问题

### 8.4 性能优化重点
- 使用合适的并行度，避免过度并行造成资源竞争
- 优化网络配置，使用连接池和长连接
- 监控 StarRocks 集群负载，避免负载过高时执行大批量导入
- 定期分析性能指标，持续优化配置参数

### 8.5 事务API最佳实践（v2.4+）
- **标签唯一性**：确保每个事务标签全局唯一，避免冲突
- **合理超时**：根据数据量设置合适的超时参数
- **错误处理**：实现完善的回滚和重试机制
- **状态监控**：及时发现和处理事务异常状态
- **并发控制**：避免超出数据库事务并发限制

Stream Load 是 StarRocks 数据导入的核心功能，配合事务API可以实现更高的数据一致性和可靠性，正确使用可以大幅提升 ETL 性能和稳定性。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](mysql-to-starrocks.md) | [➡️ 下一页](modern-etl-tools.md)
---