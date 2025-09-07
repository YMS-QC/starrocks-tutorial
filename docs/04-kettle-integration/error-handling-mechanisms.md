---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](batch-processing-strategies.md) | [➡️ 下一页](../05-sql-optimization/query-analysis.md)
---

# 错误处理机制

本章节详细介绍在 Kettle/PDI 与 StarRocks 集成过程中的错误处理机制，包括错误分类、处理策略、监控告警和故障恢复等关键技术。

## 1. 错误分类和识别

### 1.1 数据源错误

**连接错误**：
```javascript
// 数据库连接错误检测
try {
    var connection = getConnection("source_db");
    if (!connection || connection.isClosed()) {
        error_type = "CONNECTION_ERROR";
        error_message = "无法连接到数据源";
        should_retry = true;
        retry_delay = 30000; // 30秒后重试
    }
} catch (e) {
    error_type = "CONNECTION_TIMEOUT";
    error_message = "连接超时: " + e.message;
    should_retry = true;
    retry_delay = 60000; // 1分钟后重试
}
```

**数据读取错误**：
```sql
-- 检测表结构变更
SELECT COUNT(*) as column_count
FROM INFORMATION_SCHEMA.COLUMNS 
WHERE TABLE_SCHEMA = 'source_db' 
  AND TABLE_NAME = 'orders'
  AND COLUMN_NAME IN ('id', 'user_id', 'product_id', 'order_date', 'amount');

-- 如果 column_count != 5，说明表结构发生变化
```

### 1.2 数据质量错误

**空值错误**：
```javascript
// 必填字段空值检查
var required_fields = ['user_id', 'product_id', 'order_date', 'amount'];
var error_fields = [];

for (var i = 0; i < required_fields.length; i++) {
    var field_name = required_fields[i];
    var field_value = eval(field_name);
    
    if (field_value == null || field_value == undefined || field_value === '') {
        error_fields.push(field_name);
    }
}

if (error_fields.length > 0) {
    error_type = "NULL_VALUE_ERROR";
    error_message = "必填字段为空: " + error_fields.join(', ');
    error_action = "SKIP_RECORD";  // 跳过该记录
    
    // 记录错误数据
    writeToLog("w", "记录 ID " + id + " 存在空值字段: " + error_fields.join(', '));
}
```

**数据类型错误**：
```javascript
// 数据类型验证
function validateDataTypes(record) {
    var errors = [];
    
    // 数值类型检查
    if (record.amount != null && isNaN(parseFloat(record.amount))) {
        errors.push("amount 字段不是有效数值: " + record.amount);
    }
    
    // 日期类型检查
    if (record.order_date != null && !(record.order_date instanceof Date)) {
        try {
            var date = new Date(record.order_date);
            if (isNaN(date.getTime())) {
                errors.push("order_date 字段不是有效日期: " + record.order_date);
            }
        } catch (e) {
            errors.push("order_date 字段格式错误: " + record.order_date);
        }
    }
    
    // 字符串长度检查
    if (record.status != null && record.status.length > 20) {
        errors.push("status 字段长度超限: " + record.status.length + " > 20");
    }
    
    return errors;
}

var validation_errors = validateDataTypes({
    amount: amount,
    order_date: order_date,
    status: status
});

if (validation_errors.length > 0) {
    error_type = "DATA_TYPE_ERROR";
    error_message = validation_errors.join('; ');
    error_action = "TRANSFORM_AND_CONTINUE";  // 尝试转换后继续
}
```

### 1.3 StarRocks 写入错误

**Stream Load 错误**：
```javascript
// 解析 Stream Load 响应
var response = JSON.parse(load_result);

if (response.Status != "Success") {
    error_type = "STREAM_LOAD_ERROR";
    error_message = response.Message;
    
    // 根据错误类型制定处理策略
    switch (response.Status) {
        case "Fail":
            if (response.Message.indexOf("timeout") > -1) {
                error_action = "RETRY_WITH_SMALLER_BATCH";
                suggested_batch_size = Math.max(current_batch_size / 2, 1000);
            } else if (response.Message.indexOf("disk space") > -1) {
                error_action = "WAIT_AND_RETRY";
                retry_delay = 300000; // 5分钟后重试
            } else {
                error_action = "CHECK_DATA_AND_MANUAL_FIX";
            }
            break;
            
        case "Cancelled":
            error_action = "RETRY_IMMEDIATELY";
            break;
            
        default:
            error_action = "ESCALATE_TO_ADMIN";
    }
    
    // 记录详细错误信息
    if (response.ErrorURL) {
        error_details_url = response.ErrorURL;
        // 获取详细错误信息用于分析
    }
}
```

### 1.4 系统资源错误

**内存不足错误**：
```javascript
// 内存使用监控
var memory_info = getMemoryInfo();
var memory_usage_percent = (memory_info.used * 100.0) / memory_info.total;

if (memory_usage_percent > 90) {
    error_type = "MEMORY_SHORTAGE";
    error_message = "内存使用率过高: " + memory_usage_percent.toFixed(2) + "%";
    error_action = "REDUCE_BATCH_SIZE_AND_GC";
    
    // 强制垃圾回收
    java.lang.System.gc();
    
    // 减少批量大小
    var current_batch_size = parseInt(getVariable("BATCH_SIZE", "10000"));
    var new_batch_size = Math.max(current_batch_size / 2, 500);
    setVariable("BATCH_SIZE", new_batch_size.toString());
    
    writeToLog("w", "内存不足，调整批量大小从 " + current_batch_size + " 到 " + new_batch_size);
}
```

## 2. 错误处理策略

### 2.1 分层错误处理架构

```
应用层错误处理
    ↓
业务逻辑层错误处理  
    ↓
数据访问层错误处理
    ↓
基础设施层错误处理
    ↓
系统层错误处理
```

### 2.2 错误处理决策树

```xml
<!-- 错误处理决策流程 -->
<step>
    <name>Error Classification</name>
    <type>JavaScript</type>
    <script>
        var error_code = getVariable("ERROR_CODE");
        var error_severity = "LOW";
        var error_action = "CONTINUE";
        var should_notify = false;
        
        if (error_code.startsWith("CONN_")) {
            error_severity = "HIGH";
            error_action = "RETRY_WITH_BACKOFF";
            should_notify = true;
        } else if (error_code.startsWith("DATA_")) {
            error_severity = "MEDIUM";
            error_action = "SKIP_AND_LOG";
            should_notify = false;
        } else if (error_code.startsWith("SYSTEM_")) {
            error_severity = "CRITICAL";
            error_action = "STOP_AND_ALERT";
            should_notify = true;
        }
        
        setVariable("ERROR_SEVERITY", error_severity);
        setVariable("ERROR_ACTION", error_action);
        setVariable("SHOULD_NOTIFY", should_notify.toString());
    </script>
</step>
```

### 2.3 自适应重试机制

```javascript
// 自适应重试算法
function calculateRetryStrategy(errorType, retryCount, lastRetryDuration) {
    var strategy = {
        shouldRetry: false,
        delay: 0,
        maxRetries: 3,
        backoffMultiplier: 2.0,
        jitterRange: 0.1
    };
    
    switch (errorType) {
        case "CONNECTION_ERROR":
            strategy.shouldRetry = retryCount < 5;
            strategy.delay = Math.min(5000 * Math.pow(2, retryCount), 300000);
            strategy.maxRetries = 5;
            break;
            
        case "TIMEOUT_ERROR":
            strategy.shouldRetry = retryCount < 3;
            strategy.delay = 30000 * (retryCount + 1);
            strategy.maxRetries = 3;
            break;
            
        case "RESOURCE_ERROR":
            strategy.shouldRetry = retryCount < 2;
            strategy.delay = 60000 * Math.pow(2, retryCount);
            strategy.maxRetries = 2;
            break;
            
        case "DATA_ERROR":
            strategy.shouldRetry = false; // 数据错误通常不重试
            break;
    }
    
    // 添加随机抖动避免雷群效应
    if (strategy.shouldRetry && strategy.delay > 0) {
        var jitter = strategy.delay * strategy.jitterRange * (Math.random() - 0.5);
        strategy.delay = Math.max(1000, strategy.delay + jitter);
    }
    
    return strategy;
}

// 执行重试逻辑
var error_type = getVariable("ERROR_TYPE");
var retry_count = parseInt(getVariable("RETRY_COUNT", "0"));
var last_retry_duration = parseInt(getVariable("LAST_RETRY_DURATION", "0"));

var retry_strategy = calculateRetryStrategy(error_type, retry_count, last_retry_duration);

if (retry_strategy.shouldRetry && retry_count < retry_strategy.maxRetries) {
    writeToLog("w", "第 " + (retry_count + 1) + " 次重试 " + error_type + "，延迟 " + 
               (retry_strategy.delay / 1000) + " 秒");
    
    // 等待指定时间
    java.lang.Thread.sleep(retry_strategy.delay);
    
    setVariable("RETRY_COUNT", (retry_count + 1).toString());
    setVariable("SHOULD_RETRY", "true");
} else {
    writeToLog("e", "达到最大重试次数或不可重试错误，停止重试");
    setVariable("SHOULD_RETRY", "false");
}
```

## 3. 错误数据处理

### 3.1 错误数据隔离

```sql
-- 创建错误数据表
CREATE TABLE error_records (
    error_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id VARCHAR(64),
    table_name VARCHAR(64),
    error_type VARCHAR(32),
    error_message TEXT,
    original_data JSON,
    error_timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    resolved BOOLEAN DEFAULT FALSE,
    resolve_timestamp DATETIME
);

-- 创建错误统计视图
CREATE VIEW error_summary AS
SELECT 
    DATE(error_timestamp) as error_date,
    table_name,
    error_type,
    COUNT(*) as error_count,
    COUNT(DISTINCT batch_id) as affected_batches
FROM error_records 
WHERE error_timestamp >= DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY DATE(error_timestamp), table_name, error_type
ORDER BY error_date DESC, error_count DESC;
```

### 3.2 错误数据修复

```xml
<!-- 错误数据修复转换 -->
<transformation>
    <name>Error Data Repair</name>
    
    <!-- 读取错误数据 -->
    <step>
        <name>Read Error Records</name>
        <type>TableInput</type>
        <sql>
            SELECT error_id, error_type, original_data, error_message
            FROM error_records 
            WHERE resolved = FALSE 
              AND error_type IN ('DATA_TYPE_ERROR', 'NULL_VALUE_ERROR')
            ORDER BY error_timestamp
            LIMIT 1000
        </sql>
    </step>
    
    <!-- 解析原始数据 -->
    <step>
        <name>Parse Original Data</name>
        <type>JSONInput</type>
        <jsonfield>original_data</jsonfield>
        <fields>
            <field><name>id</name><type>Integer</type></field>
            <field><name>user_id</name><type>Integer</type></field>
            <field><name>product_id</name><type>Integer</type></field>
            <field><name>order_date</name><type>String</type></field>
            <field><name>amount</name><type>String</type></field>
            <field><name>status</name><type>String</type></field>
        </fields>
    </step>
    
    <!-- 应用修复规则 -->
    <step>
        <name>Apply Repair Rules</name>
        <type>JavaScript</type>
        <script>
            var repaired = false;
            var repair_actions = [];
            
            // 修复空值
            if (error_type == "NULL_VALUE_ERROR") {
                if (!user_id || user_id === '') {
                    user_id = -1;  // 使用默认值
                    repair_actions.push("user_id设为默认值-1");
                    repaired = true;
                }
                
                if (!amount || amount === '') {
                    amount = "0.00";
                    repair_actions.push("amount设为默认值0.00");
                    repaired = true;
                }
            }
            
            // 修复数据类型
            if (error_type == "DATA_TYPE_ERROR") {
                if (amount && isNaN(parseFloat(amount))) {
                    // 尝试从字符串中提取数值
                    var numeric_match = amount.match(/[\d\.]+/);
                    if (numeric_match) {
                        amount = parseFloat(numeric_match[0]).toFixed(2);
                        repair_actions.push("从'" + original_amount + "'提取数值: " + amount);
                        repaired = true;
                    }
                }
                
                if (order_date && !(new Date(order_date).getTime())) {
                    // 尝试修复日期格式
                    var date_patterns = [
                        /(\d{4})-(\d{2})-(\d{2})/,  // YYYY-MM-DD
                        /(\d{2})\/(\d{2})\/(\d{4})/, // MM/DD/YYYY
                        /(\d{4})(\d{2})(\d{2})/      // YYYYMMDD
                    ];
                    
                    for (var i = 0; i < date_patterns.length; i++) {
                        var match = order_date.match(date_patterns[i]);
                        if (match) {
                            order_date = match[1] + "-" + match[2] + "-" + match[3];
                            repair_actions.push("修复日期格式: " + order_date);
                            repaired = true;
                            break;
                        }
                    }
                }
            }
            
            repair_success = repaired;
            repair_message = repair_actions.join('; ');
        </script>
    </step>
    
    <!-- 写入修复后的数据 -->
    <step>
        <name>Insert Repaired Data</name>
        <type>TableOutput</type>
        <table>orders</table>
        <condition>
            <field>repair_success</field>
            <function>=</function>
            <value>true</value>
        </condition>
    </step>
    
    <!-- 更新错误记录状态 -->
    <step>
        <name>Update Error Status</name>
        <type>ExecSQL</type>
        <sql>
            UPDATE error_records 
            SET resolved = TRUE, 
                resolve_timestamp = NOW(),
                repair_message = ?
            WHERE error_id = ?
        </sql>
        <params>
            <param>repair_message</param>
            <param>error_id</param>
        </params>
    </step>
</transformation>
```

## 4. 监控和告警

### 4.1 实时监控指标

```javascript
// 错误率监控
var total_processed = parseInt(getVariable("TOTAL_PROCESSED", "0"));
var total_errors = parseInt(getVariable("TOTAL_ERRORS", "0"));
var error_rate = total_processed > 0 ? (total_errors * 100.0 / total_processed) : 0;

// 设置错误率阈值
var error_rate_threshold = parseFloat(getVariable("ERROR_RATE_THRESHOLD", "5.0"));

if (error_rate > error_rate_threshold) {
    alert_level = "WARNING";
    alert_message = "错误率过高: " + error_rate.toFixed(2) + "% (阈值: " + error_rate_threshold + "%)";
    should_alert = true;
    
    writeToLog("w", alert_message);
    setVariable("ALERT_TRIGGERED", "true");
} else {
    alert_level = "INFO";
    should_alert = false;
}

// 处理速率监控
var processing_rate = parseInt(getVariable("PROCESSING_RATE", "0"));
var min_processing_rate = parseInt(getVariable("MIN_PROCESSING_RATE", "1000"));

if (processing_rate < min_processing_rate && processing_rate > 0) {
    performance_alert = "处理速率过低: " + processing_rate + " 行/秒 (最低要求: " + min_processing_rate + " 行/秒)";
    writeToLog("w", performance_alert);
}

// 连续错误监控
var consecutive_errors = parseInt(getVariable("CONSECUTIVE_ERRORS", "0"));
var max_consecutive_errors = parseInt(getVariable("MAX_CONSECUTIVE_ERRORS", "10"));

if (consecutive_errors >= max_consecutive_errors) {
    critical_alert = "连续错误次数达到上限: " + consecutive_errors;
    alert_level = "CRITICAL";
    should_stop_processing = true;
    writeToLog("e", critical_alert);
}
```

### 4.2 告警通知机制

```xml
<!-- 邮件告警配置 -->
<step>
    <name>Send Error Alert</name>
    <type>Mail</type>
    <server>smtp.company.com</server>
    <port>587</port>
    <username>etl_monitor@company.com</username>
    <password>${SMTP_PASSWORD}</password>
    <authentication>Y</authentication>
    <secureconnectiontype>TLS</secureconnectiontype>
    <replyToAddress>noreply@company.com</replyToAddress>
    <replyToName>ETL监控系统</replyToName>
    <subject>ETL作业告警: ${ALERT_LEVEL} - ${JOB_NAME}</subject>
    <recipients>
        <recipient>
            <address>etl-admin@company.com</address>
            <name>ETL管理员</name>
            <type>TO</type>
        </recipient>
        <recipient>
            <address>dba-team@company.com</address>
            <name>DBA团队</name>
            <type>CC</type>
        </recipient>
    </recipients>
    <message>
        <![CDATA[
        ETL作业异常报告
        
        作业名称: ${JOB_NAME}
        告警级别: ${ALERT_LEVEL}
        发生时间: ${CURRENT_TIMESTAMP}
        
        错误详情:
        - 错误类型: ${ERROR_TYPE}
        - 错误消息: ${ERROR_MESSAGE}
        - 影响记录数: ${AFFECTED_RECORDS}
        - 当前错误率: ${ERROR_RATE}%
        
        处理状态:
        - 总处理记录: ${TOTAL_PROCESSED}
        - 成功记录: ${SUCCESSFUL_RECORDS}
        - 错误记录: ${ERROR_RECORDS}
        - 处理速率: ${PROCESSING_RATE} 行/秒
        
        建议操作:
        ${SUGGESTED_ACTIONS}
        
        详细日志请查看: ${LOG_FILE_PATH}
        监控面板: ${MONITORING_DASHBOARD_URL}
        ]]>
    </message>
    <attachFiles>Y</attachFiles>
    <zipFiles>N</zipFiles>
    <attachedFiles>
        <file>${ERROR_LOG_FILE}</file>
    </attachedFiles>
</step>
```

### 4.3 Webhook 集成

```javascript
// 发送告警到 Slack/钉钉等协作工具
function sendWebhookAlert(webhook_url, alert_data) {
    var payload = {
        "text": "ETL作业告警",
        "attachments": [
            {
                "color": alert_data.level == "CRITICAL" ? "danger" : "warning",
                "fields": [
                    {
                        "title": "作业名称",
                        "value": alert_data.job_name,
                        "short": true
                    },
                    {
                        "title": "告警级别", 
                        "value": alert_data.level,
                        "short": true
                    },
                    {
                        "title": "错误信息",
                        "value": alert_data.error_message,
                        "short": false
                    },
                    {
                        "title": "错误率",
                        "value": alert_data.error_rate + "%",
                        "short": true
                    },
                    {
                        "title": "发生时间",
                        "value": new Date().toISOString(),
                        "short": true
                    }
                ]
            }
        ]
    };
    
    var http = new org.apache.http.impl.client.HttpClients.createDefault();
    var post = new org.apache.http.client.methods.HttpPost(webhook_url);
    
    post.setHeader("Content-Type", "application/json");
    post.setEntity(new org.apache.http.entity.StringEntity(JSON.stringify(payload)));
    
    try {
        var response = http.execute(post);
        var status_code = response.getStatusLine().getStatusCode();
        
        if (status_code == 200) {
            writeToLog("i", "告警通知已发送到协作工具");
        } else {
            writeToLog("e", "告警通知发送失败: " + status_code);
        }
    } catch (e) {
        writeToLog("e", "告警通知发送异常: " + e.message);
    } finally {
        http.close();
    }
}

// 调用告警通知
if (should_alert) {
    var alert_data = {
        job_name: getVariable("JOB_NAME"),
        level: alert_level,
        error_message: error_message,
        error_rate: error_rate.toFixed(2)
    };
    
    var webhook_url = getVariable("WEBHOOK_URL");
    if (webhook_url) {
        sendWebhookAlert(webhook_url, alert_data);
    }
}
```

## 5. 故障恢复和容灾

### 5.1 检查点机制

```sql
-- 创建检查点表
CREATE TABLE processing_checkpoints (
    checkpoint_id VARCHAR(64) PRIMARY KEY,
    job_name VARCHAR(128),
    table_name VARCHAR(64),
    last_processed_id BIGINT,
    last_processed_timestamp DATETIME,
    processed_records BIGINT,
    checkpoint_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_job_table (job_name, table_name)
);
```

```javascript
// 保存检查点
function saveCheckpoint(job_name, table_name, last_id, processed_count) {
    var checkpoint_id = job_name + "_" + table_name + "_" + new Date().getTime();
    
    var sql = "INSERT INTO processing_checkpoints (" +
        "checkpoint_id, job_name, table_name, last_processed_id, " +
        "processed_records, checkpoint_time" +
        ") VALUES (?, ?, ?, ?, ?, NOW()) " +
        "ON DUPLICATE KEY UPDATE " +
        "last_processed_id = VALUES(last_processed_id), " +
        "processed_records = VALUES(processed_records), " +
        "checkpoint_time = NOW()";
    
    executeSQL(sql, [checkpoint_id, job_name, table_name, last_id, processed_count]);
    
    writeToLog("i", "检查点已保存: " + checkpoint_id + ", 最后处理ID: " + last_id);
}

// 恢复检查点
function loadCheckpoint(job_name, table_name) {
    var sql = "SELECT last_processed_id, processed_records " +
        "FROM processing_checkpoints " +
        "WHERE job_name = ? AND table_name = ? " +
        "ORDER BY checkpoint_time DESC LIMIT 1";
    
    var result = querySQL(sql, [job_name, table_name]);
    
    if (result && result.length > 0) {
        var last_id = result[0].last_processed_id || 0;
        var processed_count = result[0].processed_records || 0;
        
        writeToLog("i", "已加载检查点: 从ID " + last_id + " 继续处理");
        return { last_id: last_id, processed_count: processed_count };
    } else {
        writeToLog("i", "未找到检查点，从头开始处理");
        return { last_id: 0, processed_count: 0 };
    }
}

// 在处理过程中定期保存检查点
var records_since_checkpoint = parseInt(getVariable("RECORDS_SINCE_CHECKPOINT", "0")) + 1;
var checkpoint_interval = parseInt(getVariable("CHECKPOINT_INTERVAL", "10000"));

if (records_since_checkpoint >= checkpoint_interval) {
    saveCheckpoint(
        getVariable("JOB_NAME"),
        getVariable("TABLE_NAME"), 
        current_record_id,
        total_processed_records
    );
    setVariable("RECORDS_SINCE_CHECKPOINT", "0");
} else {
    setVariable("RECORDS_SINCE_CHECKPOINT", records_since_checkpoint.toString());
}
```

### 5.2 自动故障恢复

```xml
<job>
    <name>Auto Recovery Job</name>
    
    <!-- 检测失败的作业 -->
    <entry>
        <name>Detect Failed Jobs</name>
        <type>SQL</type>
        <sql>
            SELECT job_name, MAX(checkpoint_time) as last_checkpoint
            FROM processing_checkpoints
            WHERE checkpoint_time < DATE_SUB(NOW(), INTERVAL 1 HOUR)
              AND job_name IN (${MONITORED_JOBS})
            GROUP BY job_name
        </sql>
        <setvar>
            <varname>FAILED_JOBS</varname>
        </setvar>
    </entry>
    
    <!-- 自动重启失败的作业 -->
    <entry>
        <name>Restart Failed Jobs</name>
        <type>TRANS</type>
        <filename>restart_failed_jobs.ktr</filename>
        <condition>
            <field>FAILED_JOBS</field>
            <function>IS NOT NULL</function>
        </condition>
    </entry>
    
    <!-- 发送恢复通知 -->
    <entry>
        <name>Send Recovery Notification</name>
        <type>Mail</type>
        <subject>自动故障恢复完成</subject>
        <message>以下作业已自动重启: ${RECOVERED_JOBS}</message>
    </entry>
</job>
```

### 5.3 数据一致性检查

```sql
-- 数据一致性检查脚本
WITH source_summary AS (
    SELECT 
        COUNT(*) as total_records,
        SUM(amount) as total_amount,
        MAX(created_at) as max_created_at
    FROM source_table
    WHERE created_at >= '${CHECK_START_TIME}'
),
target_summary AS (
    SELECT 
        COUNT(*) as total_records,
        SUM(amount) as total_amount,
        MAX(created_at) as max_created_at
    FROM target_table
    WHERE created_at >= '${CHECK_START_TIME}'
)
SELECT 
    s.total_records as source_records,
    t.total_records as target_records,
    s.total_records - t.total_records as record_diff,
    s.total_amount as source_amount,
    t.total_amount as target_amount,
    ABS(s.total_amount - t.total_amount) as amount_diff,
    CASE 
        WHEN s.total_records = t.total_records AND ABS(s.total_amount - t.total_amount) < 0.01 
        THEN 'CONSISTENT'
        ELSE 'INCONSISTENT'
    END as consistency_status
FROM source_summary s
CROSS JOIN target_summary t;
```

## 6. 事务错误处理

> **版本要求**：SQL事务从StarRocks 3.5.0开始支持，Stream Load事务从2.4版本开始支持

### 6.1 事务错误分类

#### SQL事务错误（v3.5+）
```sql
-- 事务超时错误
BEGIN WORK;
INSERT INTO large_table SELECT * FROM source_table; -- 可能超时
-- 错误：Transaction timeout after 600 seconds
COMMIT WORK;
```

**处理策略**：
```javascript
// Kettle JavaScript步骤中处理事务超时
var retry_count = 0;
var max_retries = 3;
var batch_size = 50000;

while (retry_count < max_retries) {
    try {
        // 分批处理避免超时
        execSQL("BEGIN WORK");
        execSQL("INSERT INTO target_table SELECT * FROM source_table LIMIT " + batch_size + " OFFSET " + (retry_count * batch_size));
        execSQL("COMMIT WORK");
        
        logBasic("Transaction committed successfully");
        break;
        
    } catch (e) {
        execSQL("ROLLBACK WORK");
        retry_count++;
        
        if (e.message.contains("timeout")) {
            logError("Transaction timeout, retry " + retry_count + "/" + max_retries);
            // 减少批量大小
            batch_size = batch_size * 0.8;
        } else {
            logError("Transaction error: " + e.message);
            throw e;
        }
    }
}
```

#### Stream Load事务错误
```bash
# 事务状态错误处理
{
    "TxnId": 1,
    "Label": "streamload_txn_example",
    "Status": "FAILED",
    "Message": "TXN_NOT_EXISTS"
}
```

**处理逻辑**：
```javascript
// Kettle中处理Stream Load事务错误
function handleStreamLoadTransaction() {
    var txn_label = "etl_job_" + getCurrentDateTime();
    var retry_count = 0;
    var max_retries = 3;
    
    while (retry_count < max_retries) {
        try {
            // 1. 开始事务
            var begin_response = httpPost("/api/transaction/begin", {
                "label": txn_label,
                "db": "demo_etl",
                "table": "target_table"
            });
            
            if (begin_response.Status !== "OK") {
                throw new Error("Begin transaction failed: " + begin_response.Message);
            }
            
            // 2. 加载数据
            var load_response = httpPost("/api/transaction/load", data_content, {
                "label": txn_label,
                "column_separator": ","
            });
            
            if (load_response.Status !== "OK") {
                // 回滚事务
                httpPost("/api/transaction/rollback", {"label": txn_label});
                throw new Error("Load data failed: " + load_response.Message);
            }
            
            // 3. 提交事务
            var commit_response = httpPost("/api/transaction/commit", {
                "label": txn_label
            });
            
            if (commit_response.Status === "OK") {
                logBasic("Transaction committed successfully: " + txn_label);
                return true;
            } else if (commit_response.Message === "Transaction already commited") {
                logBasic("Transaction already committed: " + txn_label);
                return true;
            } else {
                throw new Error("Commit failed: " + commit_response.Message);
            }
            
        } catch (e) {
            retry_count++;
            logError("Transaction error (attempt " + retry_count + "): " + e.message);
            
            // 特殊错误处理
            if (e.message.contains("TXN_NOT_EXISTS")) {
                // 事务不存在，重新开始
                txn_label = "etl_job_" + getCurrentDateTime() + "_retry_" + retry_count;
            } else if (e.message.contains("commit timeout")) {
                // 提交超时，等待更长时间
                Thread.sleep(30000); // 等待30秒
            } else if (e.message.contains("publish timeout")) {
                // 发布超时，检查数据是否实际加载成功
                if (checkDataExists(txn_label)) {
                    logBasic("Data successfully loaded despite publish timeout");
                    return true;
                }
            }
            
            if (retry_count >= max_retries) {
                logError("Transaction failed after " + max_retries + " retries");
                throw e;
            }
        }
    }
    
    return false;
}
```

### 6.2 事务并发冲突处理

**事务限制检查**：
```sql
-- 检查当前数据库运行事务数
SELECT db_name, COUNT(*) as running_txns
FROM information_schema.transactions 
WHERE state = 'RUNNING'
GROUP BY db_name
HAVING COUNT(*) > 800; -- 接近限制时告警
```

**Kettle并发控制**：
```javascript
// 控制并发事务数量
var max_concurrent_txns = 50; // 控制在安全范围内
var current_txns = getCurrentRunningTransactionCount();

if (current_txns >= max_concurrent_txns) {
    logBasic("Too many concurrent transactions, waiting...");
    // 等待一段时间后重试
    Thread.sleep(5000);
    return false; // 稍后重试
}

// 继续执行事务逻辑
executeTransaction();
```

### 6.3 事务一致性错误处理

**跨会话一致性问题**：
```javascript
// 确保跨会话数据一致性
function ensureDataConsistency() {
    try {
        // 1. 执行数据变更
        execSQL("INSERT INTO target_table SELECT * FROM source_table WHERE process_flag = 0");
        
        // 2. 强制同步所有BE节点
        execSQL("SYNC");
        
        // 3. 验证数据一致性
        var source_count = execSQLQuery("SELECT COUNT(*) FROM source_table WHERE process_flag = 0")[0][0];
        var target_count = execSQLQuery("SELECT COUNT(*) FROM target_table WHERE batch_id = '" + current_batch_id + "'")[0][0];
        
        if (source_count !== target_count) {
            throw new Error("Data inconsistency detected: source=" + source_count + ", target=" + target_count);
        }
        
        logBasic("Data consistency verified: " + source_count + " records");
        return true;
        
    } catch (e) {
        logError("Consistency check failed: " + e.message);
        // 实施数据修复逻辑
        repairDataInconsistency();
        throw e;
    }
}
```

**事务内数据不可见问题**：
```javascript
// 处理事务内数据不可见的问题
function handleTransactionVisibility() {
    // ❌ 错误做法：依赖事务内数据可见性
    // BEGIN WORK;
    // INSERT INTO temp_table VALUES (1, 'data');
    // SELECT * FROM temp_table WHERE id = 1; // 读不到数据
    // COMMIT WORK;
    
    // ✅ 正确做法：分离插入和查询逻辑
    try {
        // 第一阶段：插入数据
        execSQL("BEGIN WORK");
        execSQL("INSERT INTO temp_table SELECT * FROM source_table WHERE batch_id = '" + current_batch_id + "'");
        execSQL("COMMIT WORK");
        
        // 第二阶段：同步并查询
        execSQL("SYNC");
        var result = execSQLQuery("SELECT COUNT(*) FROM temp_table WHERE batch_id = '" + current_batch_id + "'");
        
        logBasic("Inserted and verified " + result[0][0] + " records");
        return result[0][0];
        
    } catch (e) {
        execSQL("ROLLBACK WORK"); // 确保清理
        throw e;
    }
}
```

### 6.4 事务超时处理策略

**动态超时调整**：
```javascript
// 根据数据量动态调整事务超时
function calculateOptimalTimeout(record_count) {
    var base_timeout = 300; // 基础超时5分钟
    var per_record_timeout = 0.01; // 每记录0.01秒
    var calculated_timeout = base_timeout + (record_count * per_record_timeout);
    
    // 限制在合理范围内
    return Math.min(Math.max(calculated_timeout, 300), 7200); // 5分钟到2小时
}

function executeWithTimeout(sql_statement, record_count) {
    var timeout = calculateOptimalTimeout(record_count);
    
    try {
        // 设置语句超时
        getDatabase().setQueryTimeout(timeout);
        
        // 执行SQL
        execSQL(sql_statement);
        
        logBasic("SQL executed successfully with timeout: " + timeout + "s");
        
    } catch (e) {
        if (e.message.contains("timeout")) {
            logError("SQL timeout after " + timeout + " seconds for " + record_count + " records");
            // 尝试分批处理
            return executeBatch(sql_statement, record_count);
        }
        throw e;
    }
}
```

**分批事务处理**：
```javascript
// 将大事务分解为小事务
function executeBatchTransaction(source_table, target_table, batch_size) {
    var total_records = execSQLQuery("SELECT COUNT(*) FROM " + source_table)[0][0];
    var processed_records = 0;
    var failed_batches = [];
    
    logBasic("Starting batch transaction: " + total_records + " total records");
    
    while (processed_records < total_records) {
        var current_batch_size = Math.min(batch_size, total_records - processed_records);
        
        try {
            execSQL("BEGIN WORK");
            
            var insert_sql = "INSERT INTO " + target_table + 
                           " SELECT * FROM " + source_table + 
                           " LIMIT " + current_batch_size + 
                           " OFFSET " + processed_records;
            
            execSQL(insert_sql);
            execSQL("COMMIT WORK");
            
            processed_records += current_batch_size;
            logBasic("Processed batch: " + processed_records + "/" + total_records);
            
        } catch (e) {
            execSQL("ROLLBACK WORK");
            logError("Batch failed at offset " + processed_records + ": " + e.message);
            
            failed_batches.push({
                offset: processed_records,
                size: current_batch_size,
                error: e.message
            });
            
            // 跳过失败的批次继续处理
            processed_records += current_batch_size;
        }
    }
    
    // 处理失败的批次
    if (failed_batches.length > 0) {
        logError("Failed batches: " + failed_batches.length);
        handleFailedBatches(failed_batches, source_table, target_table);
    }
    
    return processed_records;
}
```

## 7. 最佳实践总结

### 7.1 错误处理原则
- **快速失败**：对于致命错误，立即停止处理并告警
- **优雅降级**：对于非致命错误，尝试修复或跳过
- **详细记录**：记录完整的错误上下文和处理过程
- **及时通知**：重要错误及时通知相关人员
- **事务安全**：确保事务的原子性和一致性（v3.5+）

### 7.2 监控策略
- **多维度监控**：错误率、处理速率、资源使用率
- **分级告警**：根据错误严重程度设置不同告警级别
- **历史趋势**：分析错误趋势，提前发现潜在问题
- **自动化响应**：对于常见问题，实现自动化处理
- **事务监控**：监控运行事务数量和事务执行时长

### 7.3 容灾备份
- **检查点机制**：定期保存处理进度，支持断点续传
- **数据备份**：关键数据多副本保存
- **自动恢复**：实现故障自动检测和恢复
- **一致性检查**：定期验证数据一致性
- **事务回滚**：确保失败事务能够完全回滚

### 7.4 运维建议
- 建立完善的错误分类体系和处理预案
- 定期回顾和优化错误处理策略
- 培训操作人员的错误诊断和处理技能
- 持续改进监控告警机制的准确性和及时性
- **事务管理**：制定事务使用规范，避免长事务和并发冲突

### 7.5 事务错误处理要点
- **超时管理**：合理设置事务超时，大数据量使用分批处理
- **并发控制**：监控事务数量，避免达到系统限制
- **一致性保证**：使用SYNC确保跨会话数据一致性  
- **重试机制**：实现智能重试，区分不同类型的事务错误
- **状态监控**：及时发现和处理事务异常状态

通过完善的错误处理机制和事务管理策略，可以显著提升 ETL 系统的稳定性和可靠性，减少故障恢复时间，保障数据处理的连续性和一致性。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](batch-processing-strategies.md) | [➡️ 下一页](../05-sql-optimization/query-analysis.md)
---