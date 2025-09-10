---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](batch-processing-strategies.md) | [➡️ 下一页](error-handling-mechanisms.md)
---

# Kettle脚本开发指南

## 学习目标

- 掌握Kettle中各种脚本类型的使用方法
- 学会JavaScript脚本在数据处理中的应用
- 了解时间分区拆分和循环处理技术
- 掌握大数据量分批处理的最佳实践
- 学会构建复杂的ETL流程控制逻辑

## Kettle脚本类型概览

### 1. 支持的脚本类型

| 脚本类型 | 引擎 | 版本支持 | 用途 | 性能特点 |
|---------|------|---------|------|---------|
| **JavaScript** | Rhino/Nashorn | PDI 3.0+ | 数据转换、流程控制 | 中等，语法简单 |
| **Java** | JVM | PDI 4.0+ | 高性能计算 | 最高，需要编译 |
| **Jython** | Python解释器 | PDI 5.0+ | Python语法 | 较低，语法灵活 |
| **Groovy** | JVM | PDI 6.0+ | 动态语言 | 高，功能强大 |
| **SQL脚本** | 数据库引擎 | 所有版本 | 数据库操作 | 取决于数据库 |

### 2. JavaScript引擎版本演进

| PDI版本 | JavaScript引擎 | ECMAScript版本 | 特性支持 |
|---------|---------------|---------------|---------|
| PDI 3.x-7.x | Rhino | ES3/ES5部分 | 基础语法、对象操作 |
| PDI 8.x+ | Nashorn | ES5+ | 更好的性能、更多ES特性 |
| PDI 9.x+ | GraalVM JS | ES6+ | 现代JavaScript语法 |

## JavaScript脚本步骤详解

### 1. 修改JavaScript值步骤

#### 基础配置
```javascript
// 步骤：修改JavaScript值（Modified JavaScript Value）
// 用途：逐行处理数据，修改字段值

// 获取输入字段值
var userId = getVariable("user_id", 0);
var userName = getVariable("user_name", "");
var regDate = getVariable("register_date", new Date());

// 数据类型转换
var userIdInt = parseInt(userId);
var userNameStr = String(userName).trim();
var regDateTime = new Date(regDate);

// 字段计算和转换
var ageGroup = userIdInt < 1000000 ? "老用户" : "新用户";
var registerYear = regDateTime.getFullYear();
var monthsSinceReg = Math.floor((new Date() - regDateTime) / (1000 * 60 * 60 * 24 * 30));

// 输出新字段（在步骤配置中定义输出字段）
age_group = ageGroup;
register_year = registerYear;
months_since_registration = monthsSinceReg;
```

#### 时间处理函数库
```javascript
// 日期工具函数
function formatDate(date, format) {
    if (!(date instanceof Date)) {
        date = new Date(date);
    }
    
    var year = date.getFullYear();
    var month = String(date.getMonth() + 1).padStart(2, '0');
    var day = String(date.getDate()).padStart(2, '0');
    var hour = String(date.getHours()).padStart(2, '0');
    var minute = String(date.getMinutes()).padStart(2, '0');
    var second = String(date.getSeconds()).padStart(2, '0');
    
    switch(format) {
        case 'YYYY-MM-DD': return year + '-' + month + '-' + day;
        case 'YYYYMM': return year + month;
        case 'YYYY-MM-DD HH:mm:ss': 
            return year + '-' + month + '-' + day + ' ' + hour + ':' + minute + ':' + second;
        default: return date.toString();
    }
}

// 时间分区函数
function getPartitionValue(date, partitionType) {
    var dt = new Date(date);
    switch(partitionType) {
        case 'YEAR': return dt.getFullYear();
        case 'MONTH': return formatDate(dt, 'YYYYMM');
        case 'DAY': return formatDate(dt, 'YYYY-MM-DD');
        case 'HOUR': return formatDate(dt, 'YYYY-MM-DD HH:mm:ss').substring(0, 13);
        default: return formatDate(dt, 'YYYY-MM-DD');
    }
}

// 日期范围生成
function generateDateRange(startDate, endDate, interval) {
    var dates = [];
    var current = new Date(startDate);
    var end = new Date(endDate);
    
    while (current <= end) {
        dates.push(new Date(current));
        switch(interval) {
            case 'DAY': current.setDate(current.getDate() + 1); break;
            case 'WEEK': current.setDate(current.getDate() + 7); break;
            case 'MONTH': current.setMonth(current.getMonth() + 1); break;
            case 'YEAR': current.setFullYear(current.getFullYear() + 1); break;
        }
    }
    return dates;
}

// 使用示例
var partitionValue = getPartitionValue(register_date, 'MONTH');
var dateStr = formatDate(new Date(), 'YYYY-MM-DD HH:mm:ss');

// 输出字段
partition_month = partitionValue;
formatted_date = dateStr;
```

### 2. JavaScript步骤（执行脚本）

#### 流程控制脚本
```javascript
// 步骤：JavaScript（用于流程控制，不处理数据行）
// 获取作业/转换变量
var processDate = getVariable("PROCESS_DATE", "2024-01-01");
var targetTable = getVariable("TARGET_TABLE", "fact_sales");
var partitionType = getVariable("PARTITION_TYPE", "MONTH");

// 解析处理日期
var processDateTime = new Date(processDate);
var currentYear = processDateTime.getFullYear();
var currentMonth = processDateTime.getMonth() + 1; // JavaScript月份从0开始

// 生成分区列表
var partitions = [];
if (partitionType === "MONTH") {
    // 生成指定年份的所有月分区
    for (var month = 1; month <= 12; month++) {
        var partitionValue = currentYear + String(month).padStart(2, '0');
        partitions.push({
            year: currentYear,
            month: month,
            partition: partitionValue,
            startDate: currentYear + '-' + String(month).padStart(2, '0') + '-01',
            endDate: new Date(currentYear, month, 0).toISOString().substring(0, 10) // 月末日期
        });
    }
} else if (partitionType === "YEAR") {
    // 生成多年分区
    var startYear = currentYear - 2; // 处理最近3年
    for (var year = startYear; year <= currentYear; year++) {
        partitions.push({
            year: year,
            partition: String(year),
            startDate: year + '-01-01',
            endDate: year + '-12-31'
        });
    }
}

// 将分区信息存储到变量中供后续步骤使用
setVariable("PARTITION_COUNT", partitions.length);
setVariable("PARTITION_LIST", JSON.stringify(partitions));

// 记录日志
writeToLog("分区生成完成，共 " + partitions.length + " 个分区");
writeToLog("分区列表: " + JSON.stringify(partitions, null, 2));
```

### 3. 生成记录步骤结合JavaScript

#### 动态生成时间分区记录
```javascript
// 配置生成记录步骤
// 1. 在"生成记录"步骤中设置：
//    - 限制: 1（生成1行）
//    - 字段定义: 
//      * partition_info: String类型

// 2. 在"修改JavaScript值"步骤中处理：
// 获取参数
var startDate = getVariable("START_DATE", "2022-01-01");  
var endDate = getVariable("END_DATE", "2024-12-31");
var processMode = getVariable("PROCESS_MODE", "MONTHLY");

// 生成时间分区信息
function generateTimePartitions(start, end, mode) {
    var partitions = [];
    var current = new Date(start);
    var endDate = new Date(end);
    
    while (current <= endDate) {
        var partition = {
            startDate: formatDate(current, 'YYYY-MM-DD'),
            partitionKey: '',
            sqlCondition: ''
        };
        
        if (mode === 'MONTHLY') {
            var nextMonth = new Date(current);
            nextMonth.setMonth(nextMonth.getMonth() + 1);
            nextMonth.setDate(0); // 月末
            
            partition.endDate = formatDate(nextMonth, 'YYYY-MM-DD');
            partition.partitionKey = formatDate(current, 'YYYYMM');
            partition.sqlCondition = "order_date >= '" + partition.startDate + 
                                   "' AND order_date <= '" + partition.endDate + "'";
            
            // 移动到下个月
            current.setMonth(current.getMonth() + 1);
            current.setDate(1);
        } else if (mode === 'YEARLY') {
            partition.endDate = current.getFullYear() + '-12-31';
            partition.partitionKey = String(current.getFullYear());
            partition.sqlCondition = "YEAR(order_date) = " + current.getFullYear();
            
            // 移动到下一年
            current.setFullYear(current.getFullYear() + 1);
            current.setMonth(0);
            current.setDate(1);
        }
        
        partitions.push(partition);
    }
    
    return partitions;
}

// 生成分区数据
var partitionData = generateTimePartitions(startDate, endDate, processMode);

// 将结果序列化为JSON字符串
partition_info = JSON.stringify(partitionData);

// 设置全局变量供其他步骤使用
setVariable("TOTAL_PARTITIONS", partitionData.length);
setVariable("CURRENT_PARTITION_INDEX", 0);
```

## 循环处理和分批执行

### 1. 使用JavaScript实现循环控制

#### 分区循环处理作业
```javascript
// 作业中的JavaScript脚本步骤
// 获取分区信息
var partitionListJson = getVariable("PARTITION_LIST", "[]");
var partitionList = JSON.parse(partitionListJson);
var currentIndex = parseInt(getVariable("CURRENT_PARTITION_INDEX", "0"));
var totalPartitions = partitionList.length;

// 检查是否还有分区需要处理
if (currentIndex < totalPartitions) {
    var currentPartition = partitionList[currentIndex];
    
    // 设置当前分区的处理参数
    setVariable("CURRENT_PARTITION", currentPartition.partition);
    setVariable("CURRENT_START_DATE", currentPartition.startDate);
    setVariable("CURRENT_END_DATE", currentPartition.endDate);
    setVariable("CURRENT_YEAR", currentPartition.year);
    setVariable("CURRENT_MONTH", currentPartition.month || "");
    
    // 更新索引
    setVariable("CURRENT_PARTITION_INDEX", currentIndex + 1);
    
    // 设置继续循环标志
    setVariable("CONTINUE_LOOP", "TRUE");
    
    // 记录处理进度
    var progressMsg = "处理分区 " + (currentIndex + 1) + "/" + totalPartitions + 
                     ": " + currentPartition.partition +
                     " (" + currentPartition.startDate + " - " + currentPartition.endDate + ")";
    writeToLog(progressMsg);
} else {
    // 所有分区处理完成
    setVariable("CONTINUE_LOOP", "FALSE");
    writeToLog("所有分区处理完成，共处理 " + totalPartitions + " 个分区");
}
```

### 2. 三年数据月度聚合完整案例

#### 作业结构设计
```
主作业(main_aggregation_job.kjb):
├── 初始化脚本 (JavaScript)
├── 循环开始
│   ├── 条件判断 (${CONTINUE_LOOP} == TRUE)
│   ├── 执行月度聚合转换 (monthly_aggregation.ktr)
│   ├── 更新循环变量 (JavaScript)
│   └── 循环结束判断
└── 清理和汇总
```

#### 初始化脚本
```javascript
// 主作业中的初始化JavaScript脚本
// 设置处理参数
var startYear = 2022;
var endYear = 2024;
var sourceTable = "fact_orders";
var targetTable = "agg_monthly_sales";

// 生成月度分区列表
var monthlyPartitions = [];
for (var year = startYear; year <= endYear; year++) {
    for (var month = 1; month <= 12; month++) {
        // 跳过未来月份
        var currentDate = new Date();
        var partitionDate = new Date(year, month - 1, 1);
        if (partitionDate > currentDate) break;
        
        var monthStr = String(month).padStart(2, '0');
        var partition = {
            year: year,
            month: month,
            partition: year + monthStr,
            startDate: year + '-' + monthStr + '-01',
            endDate: '',  // 将在下面计算
            sourceCondition: '',
            targetPartition: 'p' + year + monthStr
        };
        
        // 计算月末日期
        var lastDay = new Date(year, month, 0).getDate();
        partition.endDate = year + '-' + monthStr + '-' + String(lastDay).padStart(2, '0');
        
        // 生成源表查询条件
        partition.sourceCondition = "order_date >= '" + partition.startDate + 
                                  "' AND order_date <= '" + partition.endDate + "'";
        
        monthlyPartitions.push(partition);
    }
}

// 设置全局变量
setVariable("PARTITION_LIST", JSON.stringify(monthlyPartitions));
setVariable("TOTAL_PARTITIONS", monthlyPartitions.length);
setVariable("CURRENT_PARTITION_INDEX", 0);
setVariable("CONTINUE_LOOP", "TRUE");
setVariable("SOURCE_TABLE", sourceTable);
setVariable("TARGET_TABLE", targetTable);
setVariable("PROCESSED_COUNT", 0);
setVariable("ERROR_COUNT", 0);

writeToLog("初始化完成，将处理 " + monthlyPartitions.length + " 个月度分区");
writeToLog("时间范围: " + startYear + "-01 到 " + endYear + "-12");
```

#### 月度聚合转换
```sql
-- 月度聚合转换(monthly_aggregation.ktr)中的表输入SQL
-- 使用参数化查询

SELECT 
    '${CURRENT_PARTITION}' as partition_key,
    ${CURRENT_YEAR} as year,
    ${CURRENT_MONTH} as month,
    '${CURRENT_START_DATE}' as start_date,
    '${CURRENT_END_DATE}' as end_date,
    product_category,
    customer_segment,
    sales_region,
    COUNT(*) as order_count,
    COUNT(DISTINCT customer_id) as unique_customers,
    SUM(order_amount) as total_amount,
    AVG(order_amount) as avg_amount,
    MAX(order_amount) as max_amount,
    MIN(order_amount) as min_amount,
    SUM(discount_amount) as total_discount,
    SUM(tax_amount) as total_tax
FROM ${SOURCE_TABLE}
WHERE ${CURRENT_START_DATE} <= order_date 
  AND order_date <= '${CURRENT_END_DATE}'
  AND order_status IN ('COMPLETED', 'SHIPPED')
GROUP BY 
    product_category,
    customer_segment, 
    sales_region;
```

#### 表输出配置
```sql
-- 表输出步骤配置
-- 目标表: ${TARGET_TABLE}
-- 分区字段映射:

-- 在表输出的SQL选项卡中使用ON DUPLICATE KEY UPDATE：
INSERT INTO ${TARGET_TABLE} (
    partition_key, year, month, start_date, end_date,
    product_category, customer_segment, sales_region,
    order_count, unique_customers, total_amount, avg_amount,
    max_amount, min_amount, total_discount, total_tax,
    created_time, updated_time
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())
ON DUPLICATE KEY UPDATE
    order_count = VALUES(order_count),
    unique_customers = VALUES(unique_customers),
    total_amount = VALUES(total_amount),
    avg_amount = VALUES(avg_amount),
    max_amount = VALUES(max_amount),
    min_amount = VALUES(min_amount),
    total_discount = VALUES(total_discount),
    total_tax = VALUES(total_tax),
    updated_time = NOW();
```

#### 循环控制脚本
```javascript
// 作业中的循环控制JavaScript脚本
var partitionListJson = getVariable("PARTITION_LIST", "[]");
var partitionList = JSON.parse(partitionListJson);
var currentIndex = parseInt(getVariable("CURRENT_PARTITION_INDEX", "0"));
var processedCount = parseInt(getVariable("PROCESSED_COUNT", "0"));
var errorCount = parseInt(getVariable("ERROR_COUNT", "0"));

// 检查转换执行结果
var transformResult = getVariable("TRANSFORM_RESULT", "UNKNOWN");
if (transformResult === "SUCCESS") {
    setVariable("PROCESSED_COUNT", processedCount + 1);
    writeToLog("分区 " + getVariable("CURRENT_PARTITION") + " 处理成功");
} else {
    setVariable("ERROR_COUNT", errorCount + 1);
    writeToLog("分区 " + getVariable("CURRENT_PARTITION") + " 处理失败: " + transformResult);
}

// 检查是否继续循环
if (currentIndex < partitionList.length) {
    var currentPartition = partitionList[currentIndex];
    
    // 设置下一个分区的参数
    setVariable("CURRENT_PARTITION", currentPartition.partition);
    setVariable("CURRENT_START_DATE", currentPartition.startDate);
    setVariable("CURRENT_END_DATE", currentPartition.endDate);
    setVariable("CURRENT_YEAR", currentPartition.year);
    setVariable("CURRENT_MONTH", currentPartition.month);
    
    // 更新索引
    setVariable("CURRENT_PARTITION_INDEX", currentIndex + 1);
    setVariable("CONTINUE_LOOP", "TRUE");
    
    // 显示进度
    var progress = Math.round((currentIndex / partitionList.length) * 100);
    writeToLog("进度: " + progress + "% (" + (currentIndex + 1) + "/" + partitionList.length + ")");
    
    // 可选：添加延迟避免对数据库造成太大压力
    java.lang.Thread.sleep(1000); // 1秒延迟
} else {
    // 循环结束
    setVariable("CONTINUE_LOOP", "FALSE");
    
    var totalProcessed = parseInt(getVariable("PROCESSED_COUNT", "0"));
    var totalErrors = parseInt(getVariable("ERROR_COUNT", "0"));
    var totalPartitions = partitionList.length;
    
    var summary = "聚合任务完成!" +
                 "\n总分区数: " + totalPartitions +
                 "\n成功处理: " + totalProcessed +
                 "\n处理失败: " + totalErrors +
                 "\n成功率: " + Math.round((totalProcessed / totalPartitions) * 100) + "%";
    
    writeToLog(summary);
    
    // 设置最终结果
    if (totalErrors === 0) {
        setVariable("JOB_RESULT", "SUCCESS");
    } else if (totalProcessed > totalErrors) {
        setVariable("JOB_RESULT", "PARTIAL_SUCCESS");
    } else {
        setVariable("JOB_RESULT", "FAILED");
    }
}
```

### 3. 错误处理和重试机制

#### 带重试的JavaScript控制脚本
```javascript
// 高级循环控制，支持错误重试
var maxRetries = 3;
var currentRetries = parseInt(getVariable("CURRENT_RETRIES", "0"));
var transformResult = getVariable("TRANSFORM_RESULT", "UNKNOWN");
var currentPartition = getVariable("CURRENT_PARTITION", "");

if (transformResult === "SUCCESS") {
    // 成功，重置重试计数器，继续下一个分区
    setVariable("CURRENT_RETRIES", "0");
    
    var processedCount = parseInt(getVariable("PROCESSED_COUNT", "0")) + 1;
    setVariable("PROCESSED_COUNT", processedCount);
    
    writeToLog("分区 " + currentPartition + " 处理成功");
    
    // 移动到下一个分区
    moveToNextPartition();
} else {
    // 失败，检查是否需要重试
    if (currentRetries < maxRetries) {
        // 增加重试计数
        setVariable("CURRENT_RETRIES", currentRetries + 1);
        
        writeToLog("分区 " + currentPartition + " 处理失败，进行第 " + 
                  (currentRetries + 1) + " 次重试");
        
        // 等待一段时间后重试
        var waitTime = 5000 * (currentRetries + 1); // 递增等待时间
        java.lang.Thread.sleep(waitTime);
        
        // 不移动到下一个分区，重新处理当前分区
        setVariable("CONTINUE_LOOP", "TRUE");
    } else {
        // 超过最大重试次数，记录错误并移动到下一个分区
        var errorCount = parseInt(getVariable("ERROR_COUNT", "0")) + 1;
        setVariable("ERROR_COUNT", errorCount);
        setVariable("CURRENT_RETRIES", "0");
        
        writeToLog("分区 " + currentPartition + " 处理失败，已超过最大重试次数(" + 
                  maxRetries + ")，跳过该分区");
        
        // 移动到下一个分区
        moveToNextPartition();
    }
}

// 移动到下一个分区的函数
function moveToNextPartition() {
    var partitionListJson = getVariable("PARTITION_LIST", "[]");
    var partitionList = JSON.parse(partitionListJson);
    var currentIndex = parseInt(getVariable("CURRENT_PARTITION_INDEX", "0"));
    
    if (currentIndex < partitionList.length) {
        var nextPartition = partitionList[currentIndex];
        
        // 设置下一个分区的参数
        setVariable("CURRENT_PARTITION", nextPartition.partition);
        setVariable("CURRENT_START_DATE", nextPartition.startDate);
        setVariable("CURRENT_END_DATE", nextPartition.endDate);
        setVariable("CURRENT_YEAR", nextPartition.year);
        setVariable("CURRENT_MONTH", nextPartition.month || "");
        
        // 更新索引
        setVariable("CURRENT_PARTITION_INDEX", currentIndex + 1);
        setVariable("CONTINUE_LOOP", "TRUE");
        
        // 记录进度
        var progress = Math.round((currentIndex / partitionList.length) * 100);
        writeToLog("移动到下一个分区，进度: " + progress + "% (" + 
                  (currentIndex + 1) + "/" + partitionList.length + ")");
    } else {
        // 所有分区处理完成
        setVariable("CONTINUE_LOOP", "FALSE");
        finalizeBatch();
    }
}

// 批处理完成汇总
function finalizeBatch() {
    var totalProcessed = parseInt(getVariable("PROCESSED_COUNT", "0"));
    var totalErrors = parseInt(getVariable("ERROR_COUNT", "0"));
    var totalPartitions = JSON.parse(getVariable("PARTITION_LIST", "[]")).length;
    
    var endTime = new Date();
    var startTime = new Date(getVariable("BATCH_START_TIME", endTime.getTime()));
    var durationMinutes = Math.round((endTime - startTime) / (1000 * 60));
    
    var summary = "=== 批处理任务完成 ===" +
                 "\n开始时间: " + startTime.toLocaleString() +
                 "\n结束时间: " + endTime.toLocaleString() +
                 "\n总耗时: " + durationMinutes + " 分钟" +
                 "\n总分区数: " + totalPartitions +
                 "\n成功处理: " + totalProcessed +
                 "\n处理失败: " + totalErrors +
                 "\n成功率: " + Math.round((totalProcessed / totalPartitions) * 100) + "%";
    
    writeToLog(summary);
    
    // 设置最终状态
    if (totalErrors === 0) {
        setVariable("FINAL_STATUS", "ALL_SUCCESS");
    } else if (totalProcessed > 0) {
        setVariable("FINAL_STATUS", "PARTIAL_SUCCESS");
    } else {
        setVariable("FINAL_STATUS", "ALL_FAILED");
    }
}
```

## 高级脚本技术

### 1. 动态SQL生成

```javascript
// 根据分区信息动态生成StarRocks SQL
function generatePartitionedSQL(tableName, partitionInfo, selectFields) {
    var sql = "SELECT ";
    
    // 添加分区字段
    sql += "'" + partitionInfo.partition + "' as partition_key, ";
    sql += partitionInfo.year + " as year, ";
    
    if (partitionInfo.month) {
        sql += partitionInfo.month + " as month, ";
    }
    
    // 添加选择字段
    sql += selectFields.join(", ");
    
    // FROM子句
    sql += "\nFROM " + tableName;
    
    // WHERE子句 - 分区裁剪条件
    sql += "\nWHERE " + partitionInfo.sourceCondition;
    
    // 对于StarRocks，添加分区提示
    sql += "\n/* StarRocks分区提示: 使用时间分区裁剪 */";
    
    return sql;
}

// 生成INSERT语句
function generateInsertSQL(targetTable, fields, onDuplicateUpdate) {
    var insertSQL = "INSERT INTO " + targetTable + " (";
    insertSQL += fields.join(", ");
    insertSQL += ") VALUES (";
    insertSQL += fields.map(function() { return "?"; }).join(", ");
    insertSQL += ")";
    
    if (onDuplicateUpdate && onDuplicateUpdate.length > 0) {
        insertSQL += "\nON DUPLICATE KEY UPDATE ";
        var updatePairs = onDuplicateUpdate.map(function(field) {
            return field + " = VALUES(" + field + ")";
        });
        insertSQL += updatePairs.join(", ");
    }
    
    return insertSQL;
}

// 使用示例
var selectFields = [
    "product_id",
    "COUNT(*) as order_count", 
    "SUM(amount) as total_amount",
    "AVG(amount) as avg_amount"
];

var currentPartition = {
    partition: "202401",
    year: 2024,
    month: 1,
    sourceCondition: "order_date >= '2024-01-01' AND order_date <= '2024-01-31'"
};

var dynamicSQL = generatePartitionedSQL("fact_orders", currentPartition, selectFields);
setVariable("DYNAMIC_SQL", dynamicSQL);

writeToLog("生成的SQL: \n" + dynamicSQL);
```

### 2. 内存优化技术

```javascript
// 大数据量处理的内存优化
var BATCH_SIZE = parseInt(getVariable("BATCH_SIZE", "50000"));
var MEMORY_THRESHOLD_MB = parseInt(getVariable("MEMORY_THRESHOLD_MB", "1024"));

// 监控内存使用
function checkMemoryUsage() {
    var runtime = java.lang.Runtime.getRuntime();
    var maxMemory = runtime.maxMemory() / (1024 * 1024); // MB
    var totalMemory = runtime.totalMemory() / (1024 * 1024);
    var freeMemory = runtime.freeMemory() / (1024 * 1024);
    var usedMemory = totalMemory - freeMemory;
    
    var memoryInfo = {
        maxMemory: Math.round(maxMemory),
        totalMemory: Math.round(totalMemory), 
        freeMemory: Math.round(freeMemory),
        usedMemory: Math.round(usedMemory),
        usagePercent: Math.round((usedMemory / maxMemory) * 100)
    };
    
    // 记录内存使用情况
    writeToLog("内存使用: " + memoryInfo.usedMemory + "MB / " + 
               memoryInfo.maxMemory + "MB (" + memoryInfo.usagePercent + "%)");
    
    // 如果内存使用超过阈值，触发GC
    if (memoryInfo.usedMemory > MEMORY_THRESHOLD_MB) {
        writeToLog("内存使用超过阈值，触发垃圾回收");
        runtime.gc();
        
        // 等待GC完成
        java.lang.Thread.sleep(2000);
        
        // 重新检查内存
        var newUsedMemory = Math.round((runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024));
        writeToLog("GC后内存使用: " + newUsedMemory + "MB");
    }
    
    return memoryInfo;
}

// 动态调整批量大小
function adjustBatchSize(memoryInfo) {
    var optimalBatchSize = BATCH_SIZE;
    
    if (memoryInfo.usagePercent > 80) {
        // 内存紧张，减少批量大小
        optimalBatchSize = Math.max(10000, BATCH_SIZE * 0.5);
        writeToLog("内存使用率过高，降低批量大小至: " + optimalBatchSize);
    } else if (memoryInfo.usagePercent < 50) {
        // 内存充足，可以增加批量大小
        optimalBatchSize = Math.min(100000, BATCH_SIZE * 1.5);
        writeToLog("内存充足，提高批量大小至: " + optimalBatchSize);
    }
    
    setVariable("OPTIMAL_BATCH_SIZE", optimalBatchSize);
    return optimalBatchSize;
}

// 在处理每个分区前检查和优化
var memoryInfo = checkMemoryUsage();
var optimalBatchSize = adjustBatchSize(memoryInfo);

// 设置到表输出步骤的批量大小
setVariable("CURRENT_BATCH_SIZE", optimalBatchSize);
```

## 脚本最佳实践

### 1. 性能优化原则

```javascript
// 1. 避免在循环中创建大对象
// 错误示例：
for (var i = 0; i < 100000; i++) {
    var data = new Object(); // 每次循环都创建新对象
    // 处理逻辑
}

// 正确示例：
var data = new Object(); // 在循环外创建
for (var i = 0; i < 100000; i++) {
    // 重用对象，只修改属性
    data.value = i;
    // 处理逻辑
}

// 2. 使用缓存减少重复计算
var dateCache = {};
function getCachedFormattedDate(date) {
    var key = date.getTime();
    if (!dateCache[key]) {
        dateCache[key] = formatDate(date, 'YYYY-MM-DD');
    }
    return dateCache[key];
}

// 3. 批量处理而不是逐条处理
var batchOperations = [];
for (var i = 0; i < rowCount; i++) {
    batchOperations.push({
        operation: 'UPDATE',
        data: getRowData(i)
    });
    
    // 每1000条执行一次批量操作
    if (batchOperations.length >= 1000) {
        executeBatchOperations(batchOperations);
        batchOperations = []; // 清空数组
    }
}

// 处理剩余的操作
if (batchOperations.length > 0) {
    executeBatchOperations(batchOperations);
}
```

### 2. 错误处理和日志记录

```javascript
// 完善的错误处理框架
function safeExecute(operation, operationName, maxRetries) {
    maxRetries = maxRetries || 3;
    var lastError;
    
    for (var retry = 0; retry < maxRetries; retry++) {
        try {
            var result = operation();
            
            if (retry > 0) {
                writeToLog(operationName + " 重试成功 (第" + (retry + 1) + "次尝试)");
            }
            
            return result;
        } catch (error) {
            lastError = error;
            
            writeToLog(operationName + " 执行失败 (第" + (retry + 1) + "次尝试): " + 
                      error.message);
            
            if (retry < maxRetries - 1) {
                // 等待时间递增
                var waitTime = 1000 * Math.pow(2, retry); // 指数退避
                java.lang.Thread.sleep(waitTime);
            }
        }
    }
    
    // 所有重试都失败
    writeToLog(operationName + " 最终失败，已尝试 " + maxRetries + " 次");
    throw lastError;
}

// 使用示例
var result = safeExecute(function() {
    return processPartition(currentPartition);
}, "分区处理", 3);

// 结构化日志记录
function logStructured(level, message, data) {
    var timestamp = new Date().toISOString();
    var logEntry = {
        timestamp: timestamp,
        level: level,
        message: message,
        data: data || {},
        partition: getVariable("CURRENT_PARTITION", ""),
        jobId: getVariable("JOB_ID", ""),
        transformationName: getVariable("TRANSFORMATION_NAME", "")
    };
    
    writeToLog(JSON.stringify(logEntry));
}

// 使用结构化日志
logStructured("INFO", "开始处理分区", {
    partitionKey: currentPartition.partition,
    dateRange: {
        start: currentPartition.startDate,
        end: currentPartition.endDate  
    },
    expectedRowCount: getVariable("EXPECTED_ROW_COUNT", "UNKNOWN")
});
```

### 3. 代码组织和模块化

```javascript
// 创建命名空间避免变量冲突
var ETLUtils = {
    // 时间处理模块
    Time: {
        formatDate: function(date, format) {
            // 日期格式化实现
        },
        
        getPartitionValue: function(date, type) {
            // 分区值生成实现
        },
        
        generateDateRange: function(start, end, interval) {
            // 日期范围生成实现
        }
    },
    
    // 内存管理模块
    Memory: {
        checkUsage: function() {
            // 内存使用检查实现
        },
        
        forceGC: function() {
            // 强制垃圾回收实现
        }
    },
    
    // 数据库操作模块
    Database: {
        generateSQL: function(template, params) {
            // SQL生成实现
        },
        
        executeBatch: function(operations) {
            // 批量执行实现
        }
    },
    
    // 日志记录模块
    Logger: {
        info: function(message, data) {
            logStructured("INFO", message, data);
        },
        
        error: function(message, error, data) {
            logStructured("ERROR", message, {
                error: error.message,
                stack: error.stack,
                data: data
            });
        }
    }
};

// 使用模块化代码
var partitionValue = ETLUtils.Time.getPartitionValue(new Date(), 'MONTH');
var memoryInfo = ETLUtils.Memory.checkUsage();
ETLUtils.Logger.info("分区处理开始", {
    partition: partitionValue,
    memoryUsage: memoryInfo.usagePercent + "%"
});
```

## 小结

Kettle脚本开发的核心要点：

### 技术特性
1. **多种脚本引擎**：JavaScript、Java、Groovy、Python支持
2. **版本演进**：从Rhino到Nashorn再到GraalVM JS的性能提升  
3. **灵活部署**：支持图形化设计和命令行执行

### 实践应用
1. **时间分区处理**：动态生成分区条件，支持年、月、日分区
2. **循环批处理**：避免一次性处理大数据量造成的性能问题
3. **错误恢复**：重试机制和断点续传保证数据完整性

### 性能优化
1. **内存管理**：监控内存使用，动态调整批量大小
2. **批量操作**：减少数据库交互次数，提高处理效率
3. **并行处理**：合理利用多线程和分区并行

### 最佳实践
1. **模块化设计**：代码复用和维护性
2. **错误处理**：完善的异常捕获和重试机制
3. **日志监控**：结构化日志便于问题排查

通过Kettle脚本的高级应用，可以构建出灵活、高效、可靠的ETL数据处理流程，特别适合复杂的时间分区数据聚合场景。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](batch-processing-strategies.md) | [➡️ 下一页](error-handling-mechanisms.md)
---