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

## 聚合模型多月批处理实战

### 1. 聚合模型批处理场景

针对**StarRocks聚合模型(Aggregate Model)**的特殊处理方式，在处理三年历史数据按月分批聚合到年度聚合表时，需要考虑以下关键点：

#### 聚合模型的特点
- **自动聚合**：相同Key的数据会自动按照聚合函数合并
- **增量友好**：支持多次插入相同Key的数据，自动累加聚合
- **分批处理优势**：可以避免一次性扫描三年数据造成的性能问题

### 2. 年度聚合表设计

#### StarRocks聚合表结构
```sql
-- 年度销售聚合表（聚合模型）
CREATE TABLE agg_yearly_sales_summary (
    year INT NOT NULL COMMENT '年份',
    product_category VARCHAR(50) NOT NULL COMMENT '产品类别',
    customer_segment VARCHAR(30) NOT NULL COMMENT '客户分群',
    sales_region VARCHAR(20) NOT NULL COMMENT '销售区域',
    -- 聚合指标字段
    total_orders BIGINT SUM NOT NULL DEFAULT '0' COMMENT '总订单数',
    unique_customers BIGINT SUM NOT NULL DEFAULT '0' COMMENT '去重客户数（需特殊处理）',
    total_revenue DECIMAL(15,2) SUM NOT NULL DEFAULT '0.00' COMMENT '总收入',
    total_profit DECIMAL(15,2) SUM NOT NULL DEFAULT '0.00' COMMENT '总利润',
    avg_order_value DECIMAL(10,2) REPLACE NOT NULL DEFAULT '0.00' COMMENT '平均订单价值',
    max_single_order DECIMAL(10,2) MAX NOT NULL DEFAULT '0.00' COMMENT '最大单笔订单',
    min_single_order DECIMAL(10,2) MIN NOT NULL DEFAULT '999999.99' COMMENT '最小单笔订单',
    last_updated DATETIME REPLACE NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '最后更新时间'
) ENGINE = OLAP
AGGREGATE KEY(year, product_category, customer_segment, sales_region)
PARTITION BY RANGE(year) (
    PARTITION p2022 VALUES [("2022"), ("2023")),
    PARTITION p2023 VALUES [("2023"), ("2024")),
    PARTITION p2024 VALUES [("2024"), ("2025"))
)
DISTRIBUTED BY HASH(product_category, customer_segment) BUCKETS 8
PROPERTIES (
    'replication_num' = '1',
    'storage_format' = 'v2'
);
```

### 3. 月度分批聚合JavaScript脚本

#### 聚合模型批处理初始化脚本
```javascript
// 聚合模型批处理作业初始化脚本
// 针对StarRocks聚合模型的特殊处理逻辑

// 设置处理参数
var startYear = 2022;
var endYear = 2024;
var sourceTable = "fact_monthly_sales";  // 月度明细表
var targetTable = "agg_yearly_sales_summary";  // 年度聚合表
var processMode = "AGGREGATE_BATCH";  // 聚合批处理模式

// 生成月度批处理列表 - 专门针对聚合表
var monthlyBatches = [];
for (var year = startYear; year <= endYear; year++) {
    for (var month = 1; month <= 12; month++) {
        // 跳过未来月份
        var currentDate = new Date();
        var processMonth = new Date(year, month - 1, 1);
        if (processMonth > currentDate) break;
        
        var monthStr = String(month).padStart(2, '0');
        var batch = {
            batchId: year + monthStr,
            targetYear: year,  // 聚合到的目标年份
            sourceYear: year,
            sourceMonth: month,
            monthKey: year + monthStr,
            startDate: year + '-' + monthStr + '-01',
            endDate: '',
            
            // 聚合模型专用字段
            aggregateMode: 'MONTHLY_TO_YEARLY',
            needsDeduplication: true,  // 客户去重需要特殊处理
            batchSize: 10000,
            
            // SQL条件
            sourceCondition: '',
            targetPartition: 'p' + year
        };
        
        // 计算月末日期
        var lastDay = new Date(year, month, 0).getDate();
        batch.endDate = year + '-' + monthStr + '-' + String(lastDay).padStart(2, '0');
        
        // 生成源表查询条件
        batch.sourceCondition = "order_date >= '" + batch.startDate + 
                              "' AND order_date <= '" + batch.endDate + "'";
        
        monthlyBatches.push(batch);
    }
}

// 设置聚合批处理专用变量
setVariable("MONTHLY_BATCHES", JSON.stringify(monthlyBatches));
setVariable("TOTAL_BATCHES", monthlyBatches.length);
setVariable("CURRENT_BATCH_INDEX", 0);
setVariable("CONTINUE_BATCH", "TRUE");
setVariable("SOURCE_TABLE", sourceTable);
setVariable("TARGET_TABLE", targetTable);
setVariable("PROCESS_MODE", processMode);

// 聚合处理统计
setVariable("PROCESSED_BATCHES", 0);
setVariable("FAILED_BATCHES", 0);
setVariable("TOTAL_RECORDS_PROCESSED", 0);

// 记录聚合批处理开始
setVariable("BATCH_START_TIME", new Date().getTime());

writeToLog("=== 聚合模型批处理初始化 ===");
writeToLog("源表: " + sourceTable);
writeToLog("目标表: " + targetTable + " (聚合模型)");
writeToLog("处理模式: " + processMode);
writeToLog("时间范围: " + startYear + "-01 到 " + endYear + "-12");
writeToLog("总批次数: " + monthlyBatches.length + " 个月度批次");
writeToLog("聚合策略: 月度数据聚合到年度汇总");
```

#### 聚合查询SQL生成
```sql
-- 月度数据聚合到年度表的SQL（在表输入步骤中使用）
-- 专门针对StarRocks聚合模型设计

-- 第一步：基础聚合查询
SELECT 
    ${TARGET_YEAR} as year,
    product_category,
    customer_segment,
    sales_region,
    
    -- 可直接聚合的指标
    COUNT(*) as total_orders,
    SUM(order_amount) as total_revenue,
    SUM(profit_amount) as total_profit,
    MAX(order_amount) as max_single_order,
    MIN(order_amount) as min_single_order,
    
    -- 需要特殊处理的指标
    COUNT(DISTINCT customer_id) as unique_customers_batch,  -- 批次内去重
    AVG(order_amount) as avg_order_value_batch,  -- 批次内平均值
    
    -- 聚合模型元数据
    '${CURRENT_BATCH_ID}' as batch_id,
    COUNT(*) as batch_record_count,
    NOW() as last_updated
    
FROM ${SOURCE_TABLE}
WHERE ${SOURCE_CONDITION}
  AND order_status IN ('COMPLETED', 'SHIPPED', 'DELIVERED')
GROUP BY 
    product_category,
    customer_segment,
    sales_region;
```

#### 聚合模型专用处理脚本
```javascript
// 修改JavaScript值步骤 - 聚合模型特殊处理
// 针对聚合表的字段计算和转换

// 获取输入字段
var year = getVariable("year", 0);
var productCategory = getVariable("product_category", "");
var customerSegment = getVariable("customer_segment", "");
var salesRegion = getVariable("sales_region", "");

// 基础聚合字段
var totalOrders = getVariable("total_orders", 0);
var totalRevenue = getVariable("total_revenue", 0);
var totalProfit = getVariable("total_profit", 0);
var maxOrder = getVariable("max_single_order", 0);
var minOrder = getVariable("min_single_order", 0);

// 需要特殊处理的字段
var uniqueCustomersBatch = getVariable("unique_customers_batch", 0);
var avgOrderValueBatch = getVariable("avg_order_value_batch", 0);
var batchRecordCount = getVariable("batch_record_count", 0);

// 聚合模型特殊处理逻辑
// 1. 客户去重处理 - 使用HyperLogLog或分批去重策略
var customersContribution = uniqueCustomersBatch;
// 注意：在聚合模型中，COUNT DISTINCT会累加，需要在应用层处理真正的去重

// 2. 平均值处理 - 转换为REPLACE聚合函数兼容格式
// 在聚合表中，平均值不能直接用SUM聚合，需要用REPLACE
var avgOrderValue = avgOrderValueBatch;  // 这将被REPLACE函数更新为最新值

// 3. 最小值处理 - 确保不会被0覆盖
if (minOrder <= 0 || minOrder > 999999) {
    minOrder = totalRevenue > 0 ? Math.min(avgOrderValueBatch, maxOrder) : 999999.99;
}

// 4. 数据质量检查
var dataQualityFlag = "GOOD";
if (totalOrders <= 0 || totalRevenue < 0) {
    dataQualityFlag = "WARNING";
    writeToLog("数据质量警告: " + productCategory + "-" + customerSegment + 
              " 订单数=" + totalOrders + " 收入=" + totalRevenue);
}

// 5. 聚合模型优化：预计算一些派生指标
var profitMargin = totalRevenue > 0 ? (totalProfit / totalRevenue * 100) : 0;
var avgProfitPerOrder = totalOrders > 0 ? (totalProfit / totalOrders) : 0;

// 输出到聚合表的字段（与CREATE TABLE对应）
year_out = year;
product_category_out = productCategory;
customer_segment_out = customerSegment;
sales_region_out = salesRegion;
total_orders_out = totalOrders;  // SUM聚合
unique_customers_out = customersContribution;  // SUM聚合（近似值）
total_revenue_out = totalRevenue;  // SUM聚合
total_profit_out = totalProfit;  // SUM聚合
avg_order_value_out = avgOrderValue;  // REPLACE聚合
max_single_order_out = maxOrder;  // MAX聚合
min_single_order_out = minOrder;  // MIN聚合
last_updated_out = new Date();  // REPLACE聚合

// 额外的元数据字段（如果表结构包含）
batch_id_out = getVariable("CURRENT_BATCH_ID", "");
data_quality_out = dataQualityFlag;
profit_margin_out = Math.round(profitMargin * 100) / 100;
avg_profit_per_order_out = Math.round(avgProfitPerOrder * 100) / 100;

// 记录处理信息
if (totalOrders > 1000) {  // 只记录大批次
    writeToLog("聚合批次处理: " + productCategory + " " + totalOrders + "单 " + 
              Math.round(totalRevenue) + "元 " + customersContribution + "客户");
}
```

### 4. 聚合模型批次循环控制

#### 批次控制JavaScript脚本
```javascript
// 聚合模型专用的批次循环控制脚本
var batchListJson = getVariable("MONTHLY_BATCHES", "[]");
var batchList = JSON.parse(batchListJson);
var currentIndex = parseInt(getVariable("CURRENT_BATCH_INDEX", "0"));
var processedCount = parseInt(getVariable("PROCESSED_BATCHES", "0"));
var failedCount = parseInt(getVariable("FAILED_BATCHES", "0"));
var totalProcessed = parseInt(getVariable("TOTAL_RECORDS_PROCESSED", "0"));

// 检查当前批次处理结果
var batchResult = getVariable("BATCH_RESULT", "UNKNOWN");
var batchRecords = parseInt(getVariable("BATCH_RECORDS", "0"));

if (batchResult === "SUCCESS") {
    setVariable("PROCESSED_BATCHES", processedCount + 1);
    setVariable("TOTAL_RECORDS_PROCESSED", totalProcessed + batchRecords);
    
    var currentBatch = batchList[currentIndex - 1];  // 上一个处理完的批次
    writeToLog("聚合批次完成: " + currentBatch.monthKey + 
              " -> 年度表" + currentBatch.targetYear + 
              " (" + batchRecords + "条记录)");
} else if (batchResult === "FAILED") {
    setVariable("FAILED_BATCHES", failedCount + 1);
    writeToLog("聚合批次失败: " + getVariable("CURRENT_BATCH_ID", ""));
}

// 检查是否继续批处理
if (currentIndex < batchList.length) {
    var nextBatch = batchList[currentIndex];
    
    // 设置下一个批次的参数
    setVariable("CURRENT_BATCH_ID", nextBatch.batchId);
    setVariable("TARGET_YEAR", nextBatch.targetYear);
    setVariable("SOURCE_YEAR", nextBatch.sourceYear);
    setVariable("SOURCE_MONTH", nextBatch.sourceMonth);
    setVariable("SOURCE_CONDITION", nextBatch.sourceCondition);
    setVariable("CURRENT_BATCH_SIZE", nextBatch.batchSize);
    setVariable("TARGET_PARTITION", nextBatch.targetPartition);
    
    // 更新循环状态
    setVariable("CURRENT_BATCH_INDEX", currentIndex + 1);
    setVariable("CONTINUE_BATCH", "TRUE");
    
    // 显示批处理进度
    var progress = Math.round((currentIndex / batchList.length) * 100);
    var eta = calculateETA(currentIndex, batchList.length);
    
    writeToLog("=== 聚合批次 " + (currentIndex + 1) + "/" + batchList.length + " (" + progress + "%) ===");
    writeToLog("处理月份: " + nextBatch.sourceYear + "-" + 
              String(nextBatch.sourceMonth).padStart(2, '0'));
    writeToLog("目标年表: " + nextBatch.targetYear);
    writeToLog("预计剩余: " + eta + " 分钟");
    
    // 聚合模型优化：检查目标分区状态
    checkTargetPartitionStatus(nextBatch.targetPartition);
    
    // 内存检查（聚合处理内存敏感）
    var memoryInfo = checkMemoryUsage();
    if (memoryInfo.usagePercent > 70) {
        writeToLog("内存使用率: " + memoryInfo.usagePercent + "%, 建议暂停");
        // 可以选择暂停或调整批次大小
        if (nextBatch.batchSize > 5000) {
            nextBatch.batchSize = Math.max(1000, nextBatch.batchSize * 0.7);
            setVariable("CURRENT_BATCH_SIZE", nextBatch.batchSize);
            writeToLog("调整批次大小至: " + nextBatch.batchSize);
        }
    }
} else {
    // 所有批次处理完成
    setVariable("CONTINUE_BATCH", "FALSE");
    finalizeAggregation();
}

// 计算预计完成时间
function calculateETA(currentIndex, totalBatches) {
    var elapsedTime = new Date().getTime() - parseInt(getVariable("BATCH_START_TIME", "0"));
    var avgTimePerBatch = currentIndex > 0 ? elapsedTime / currentIndex : 0;
    var remainingBatches = totalBatches - currentIndex;
    var etaMs = avgTimePerBatch * remainingBatches;
    return Math.round(etaMs / (1000 * 60));  // 转换为分钟
}

// 检查目标分区状态
function checkTargetPartitionStatus(partition) {
    // 可以通过SQL查询检查分区的数据量
    writeToLog("目标分区 " + partition + " 状态检查完成");
}

// 完成聚合处理汇总
function finalizeAggregation() {
    var totalBatches = batchList.length;
    var successCount = parseInt(getVariable("PROCESSED_BATCHES", "0"));
    var errorCount = parseInt(getVariable("FAILED_BATCHES", "0"));
    var totalRecords = parseInt(getVariable("TOTAL_RECORDS_PROCESSED", "0"));
    
    var endTime = new Date();
    var startTime = new Date(parseInt(getVariable("BATCH_START_TIME", endTime.getTime())));
    var durationMinutes = Math.round((endTime - startTime) / (1000 * 60));
    
    var summary = "=== 聚合模型批处理完成 ===" +
                 "\n处理模式: 月度数据 -> 年度聚合表" +
                 "\n开始时间: " + startTime.toLocaleString() +
                 "\n结束时间: " + endTime.toLocaleString() +
                 "\n总耗时: " + durationMinutes + " 分钟" +
                 "\n批次总数: " + totalBatches +
                 "\n成功批次: " + successCount + 
                 "\n失败批次: " + errorCount +
                 "\n总记录数: " + totalRecords +
                 "\n成功率: " + Math.round((successCount / totalBatches) * 100) + "%" +
                 "\n平均速度: " + Math.round(totalRecords / durationMinutes) + " 记录/分钟";
    
    writeToLog(summary);
    
    // 设置最终状态
    if (errorCount === 0) {
        setVariable("AGGREGATION_STATUS", "ALL_SUCCESS");
        writeToLog("🎉 所有月度数据已成功聚合到年度表");
    } else if (successCount > errorCount) {
        setVariable("AGGREGATION_STATUS", "PARTIAL_SUCCESS");
        writeToLog("⚠️  部分批次失败，需要检查失败的" + errorCount + "个批次");
    } else {
        setVariable("AGGREGATION_STATUS", "FAILED");
        writeToLog("❌ 聚合处理失败，成功批次过少");
    }
    
    // 建议后续操作
    writeToLog("=== 建议后续操作 ===");
    writeToLog("1. 检查聚合表数据完整性: SELECT year, COUNT(*) FROM " + 
              getVariable("TARGET_TABLE", "") + " GROUP BY year");
    writeToLog("2. 验证聚合结果准确性: 对比源表和目标表的汇总数据");
    writeToLog("3. 更新统计信息: ANALYZE TABLE " + getVariable("TARGET_TABLE", ""));
    
    if (errorCount > 0) {
        writeToLog("4. 重新处理失败批次或手动修复数据");
    }
}
```

### 5. 聚合模型注意事项

#### 数据一致性处理
```javascript
// 聚合模型数据一致性检查脚本
// 在批处理完成后运行

var sourceTable = getVariable("SOURCE_TABLE", "");
var targetTable = getVariable("TARGET_TABLE", "");
var startYear = 2022;
var endYear = 2024;

// 1. 数据总量验证
function validateAggregation() {
    var validationResults = [];
    
    for (var year = startYear; year <= endYear; year++) {
        var validation = {
            year: year,
            sourceCount: 0,
            targetCount: 0,
            sourceRevenue: 0,
            targetRevenue: 0,
            consistency: "UNKNOWN"
        };
        
        // 注意：在实际实现中，这些SQL需要在表输入步骤中执行
        // 这里只是示例逻辑
        writeToLog("验证年度: " + year);
        
        // 源表数据汇总（伪代码）
        // SELECT COUNT(*), SUM(order_amount) FROM fact_monthly_sales WHERE YEAR(order_date) = year
        
        // 目标表数据汇总（伪代码）
        // SELECT SUM(total_orders), SUM(total_revenue) FROM agg_yearly_sales_summary WHERE year = year
        
        validation.consistency = "CHECKING";
        validationResults.push(validation);
    }
    
    setVariable("VALIDATION_RESULTS", JSON.stringify(validationResults));
    writeToLog("数据一致性验证启动，共验证 " + validationResults.length + " 个年度");
}

// 2. 聚合函数处理提醒
writeToLog("=== 聚合模型处理提醒 ===");
writeToLog("1. SUM字段: total_orders, total_revenue, total_profit 会自动累加");
writeToLog("2. REPLACE字段: avg_order_value, last_updated 会被最新值覆盖");
writeToLog("3. MAX字段: max_single_order 会保留历史最大值");
writeToLog("4. MIN字段: min_single_order 会保留历史最小值");
writeToLog("5. 去重字段: unique_customers 需要特殊处理(HyperLogLog或BitMap)");

// 3. 性能优化建议
writeToLog("=== 性能优化建议 ===");
writeToLog("1. 分批大小: 建议10000-50000条记录/批次");
writeToLog("2. 并行处理: 可以按年份并行处理不同批次");
writeToLog("3. 索引策略: 聚合表自动创建前缀索引，无需额外索引");
writeToLog("4. 压缩优化: 聚合表数据量小，压缩效果好");

validateAggregation();
```

### 6. 聚合模型vs普通表对比

| 特性 | 聚合模型 | 普通明细表 |
|------|---------|-----------|
| **数据插入** | 自动聚合相同Key | 保留所有原始记录 |
| **存储空间** | 显著压缩 | 存储所有明细 |
| **查询性能** | 预聚合，查询快 | 需要运行时聚合 |
| **更新方式** | 支持增量更新 | 通常需要全量更新 |
| **去重处理** | 需要特殊策略 | 支持准确去重 |
| **适用场景** | 报表、OLAP分析 | 明细查询、审计 |

## 小结

Kettle脚本开发的核心要点：

### 技术特性
1. **多种脚本引擎**：JavaScript、Java、Groovy、Python支持
2. **版本演进**：从Rhino到Nashorn再到GraalVM JS的性能提升  
3. **灵活部署**：支持图形化设计和命令行执行

### 实践应用
1. **时间分区处理**：动态生成分区条件，支持年、月、日分区
2. **循环批处理**：避免一次性处理大数据量造成的性能问题
3. **聚合模型处理**：针对StarRocks聚合表的特殊批处理策略
4. **错误恢复**：重试机制和断点续传保证数据完整性

### 性能优化
1. **内存管理**：监控内存使用，动态调整批量大小
2. **批量操作**：减少数据库交互次数，提高处理效率
3. **并行处理**：合理利用多线程和分区并行
4. **聚合优化**：利用聚合模型自动聚合特性

### 最佳实践
1. **模块化设计**：代码复用和维护性
2. **错误处理**：完善的异常捕获和重试机制
3. **日志监控**：结构化日志便于问题排查
4. **数据一致性**：聚合结果验证和质量检查

通过Kettle脚本的高级应用，特别是针对StarRocks聚合模型的专门处理，可以构建出灵活、高效、可靠的ETL数据处理流程，既能处理复杂的时间分区数据聚合场景，又能充分利用聚合模型的性能优势。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](batch-processing-strategies.md) | [➡️ 下一页](error-handling-mechanisms.md)
---