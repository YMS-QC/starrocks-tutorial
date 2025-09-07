---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../04-kettle-integration/error-handling-mechanisms.md) | [➡️ 下一页](join-optimization.md)
---

# StarRocks查询分析工具

> **版本要求**：本章节内容适用于StarRocks 1.19+，建议使用2.5+版本以获得完整功能支持

## 学习目标

- 掌握EXPLAIN语句分析查询执行计划
- 学会使用Profile工具诊断查询性能
- 了解StarRocks查询优化器的工作原理
- 掌握性能监控和慢查询分析方法

## EXPLAIN执行计划分析

### 1. EXPLAIN语句类型 

> **版本支持**：不同EXPLAIN类型的版本要求
> - EXPLAIN：StarRocks 1.19+
> - EXPLAIN VERBOSE：StarRocks 2.0+ 
> - EXPLAIN ANALYZE：StarRocks 2.5+
> - EXPLAIN COSTS：StarRocks 2.5+

| EXPLAIN类型 | 用途 | 详细程度 | 适用场景 | 最低版本 |
|------------|------|---------|---------|----------|
| **EXPLAIN** | 基础执行计划 | 中等 | 日常调优 | 1.19+ |
| **EXPLAIN VERBOSE** | 详细执行计划 | 高 | 深度分析 | 2.0+ |
| **EXPLAIN ANALYZE** | 实际执行统计 | 最高 | 性能诊断 | 2.5+ |
| **EXPLAIN COSTS** | 成本估算信息 | 中等 | 成本分析 | 2.5+ |
| **EXPLAIN** | 基础执行计划 | 中等 | 日常调优 |
| **EXPLAIN VERBOSE** | 详细执行计划 | 高 | 深度分析 |
| **EXPLAIN ANALYZE** | 实际执行统计 | 最高 | 性能诊断 |
| **EXPLAIN COSTS** | 成本估算信息 | 中等 | 成本分析 |

### 2. 基础EXPLAIN使用

```sql
-- 创建测试表和数据
USE demo_etl;

-- 简单查询的执行计划
EXPLAIN 
SELECT * FROM users WHERE age > 25;

-- 输出解读：
/*
+----------------------------------------------------+
| Explain String                                      |
+----------------------------------------------------+
| PLAN FRAGMENT 0                                    |
|  OUTPUT EXPRS:1: user_id | 2: username | ...       |
|   PARTITION: UNPARTITIONED                         |
|                                                    |
|   RESULT SINK                                      |
|                                                    |
|   0:OlapScanNode                                   |
|      TABLE: users                                  |
|      PREAGGREGATION: ON                            |
|      PREDICATES: 4: age > 25                       |
|      partitions=1/1                                |
|      rollup: users                                 |
|      tabletRatio=10/10                             |
|      tabletList=10009,10011,10013...               |
|      cardinality=1000                              |
|      avgRowSize=2.0                                |
+----------------------------------------------------+
*/

-- 关键信息解读：
-- OlapScanNode: 表扫描节点
-- PREDICATES: 过滤条件（已下推到存储层）
-- partitions=1/1: 扫描分区数/总分区数
-- tabletRatio=10/10: 扫描Tablet数/总Tablet数
-- cardinality: 估计返回行数
```

### 3. 复杂查询分析

```sql
-- 多表Join查询
EXPLAIN 
SELECT 
    u.username,
    u.city,
    COUNT(*) as order_count,
    SUM(o.amount) as total_amount
FROM users u
JOIN orders o ON u.user_id = o.user_id
WHERE u.age > 25 
  AND o.status = 'PAID'
  AND o.order_date >= '2024-01-01'
GROUP BY u.user_id, u.username, u.city
ORDER BY total_amount DESC
LIMIT 10;

-- 分析执行计划中的关键节点：
/*
主要节点类型：
1. OlapScanNode - 表扫描
2. HashJoinNode - Hash连接
3. AggregationNode - 聚合计算
4. SortNode - 排序
5. TopNNode - TOP-N优化
6. ExchangeNode - 数据交换
*/
```

### 4. EXPLAIN VERBOSE详细分析

```sql
-- 获取详细执行计划
EXPLAIN VERBOSE
SELECT 
    o.product_name,
    SUM(o.amount) as total_sales
FROM orders o
WHERE o.order_date BETWEEN '2024-01-01' AND '2024-01-31'
GROUP BY o.product_name
HAVING SUM(o.amount) > 10000
ORDER BY total_sales DESC;

-- VERBOSE额外提供的信息：
-- - 列的详细映射关系
-- - 数据类型信息
-- - 内存使用估算
-- - 网络传输估算
-- - 中间结果大小估算
```

### 5. EXPLAIN COSTS成本分析

```sql
-- 查看查询成本估算
EXPLAIN COSTS
SELECT 
    u.city,
    AVG(o.amount) as avg_amount
FROM users u
JOIN orders o ON u.user_id = o.user_id
WHERE o.status = 'PAID'
GROUP BY u.city;

-- 成本信息包括：
-- - CPU成本
-- - 内存成本
-- - 网络成本
-- - I/O成本
-- - 总成本估算
```

## Profile性能分析

> **版本说明**：Profile功能在不同版本中的支持情况
> - 基础Profile：StarRocks 1.19+
> - Pipeline Profile：StarRocks 2.5+
> - 详细统计信息：StarRocks 3.0+

### 1. 开启Profile功能

```sql
-- 开启当前会话的Profile
SET enable_profile = true;

-- 设置Profile详细级别（StarRocks 2.5+）
SET pipeline_profile_level = 2;  -- 0-3, 数字越大越详细

-- 执行需要分析的查询
SELECT 
    category,
    COUNT(*) as product_count,
    AVG(price) as avg_price,
    SUM(amount) as total_sales
FROM orders 
WHERE order_date >= '2024-01-01'
  AND status = 'PAID'
GROUP BY category
ORDER BY total_sales DESC;
```

### 2. 查看Profile结果

```sql
-- 查看最近执行的查询Profile
SHOW QUERY PROFILE "/";

-- 查看具体某个查询的Profile
SHOW QUERY PROFILE "<query_id>";

-- 查看Profile列表
SHOW QUERY PROFILE LIMIT 10;
```

### 3. Profile结果分析

```sql
-- Profile详细信息示例和解读
/*
查询ID: 20240115_123456_00001_abcdef

执行时间分析：
- TotalTime: 总执行时间
- PlanTime: 生成执行计划时间
- ScheduleTime: 任务调度时间
- FetchResultTime: 获取结果时间
- WriteResultTime: 写结果时间

各个Pipeline的详细信息：
Pipeline 0 (ScanOperator):
  - ActiveTime: 实际执行时间
  - PendingTime: 等待时间
  - DriverTotalTime: 驱动器总时间
  - InputRows/OutputRows: 输入/输出行数
  - InputBytes/OutputBytes: 输入/输出字节数

关键性能指标：
1. 扫描效率：InputRows vs OutputRows比率
2. 过滤效率：过滤后剩余数据比例  
3. 内存使用：PeakMemoryUsage
4. 网络传输：NetworkBytes
5. 并发度：DOP (Degree of Parallelism)
*/
```

### 4. 慢查询分析

```sql
-- 查看慢查询（执行时间>5秒）
SELECT 
    query_id,
    user,
    database_name,
    sql_text,
    query_start_time,
    total_time_ms,
    scan_rows,
    scan_bytes
FROM information_schema.query_log 
WHERE total_time_ms > 5000
ORDER BY query_start_time DESC
LIMIT 10;

-- 分析特定慢查询
SHOW QUERY PROFILE "<slow_query_id>";
```

## 执行计划优化案例

### 1. 分区裁剪优化

```sql
-- 优化前：全表扫描
EXPLAIN 
SELECT * FROM orders 
WHERE MONTH(order_date) = 1;  -- 使用函数导致无法分区裁剪

/*
执行计划显示：
partitions=3/3  -- 扫描所有分区
*/

-- 优化后：分区裁剪
EXPLAIN 
SELECT * FROM orders 
WHERE order_date >= '2024-01-01' 
  AND order_date < '2024-02-01';  -- 范围条件支持分区裁剪

/*
执行计划显示：
partitions=1/3  -- 只扫描1个分区
性能提升：66%的数据扫描减少
*/
```

### 2. 谓词下推优化

```sql
-- 优化前：Join后过滤
EXPLAIN 
SELECT u.username, o.amount
FROM users u
JOIN orders o ON u.user_id = o.user_id
WHERE o.status = 'PAID';  -- 过滤条件没有下推

-- StarRocks自动优化：谓词下推
/*
优化器会将过滤条件下推到orders表的扫描阶段：
OlapScanNode (orders):
  PREDICATES: status = 'PAID'
  
这样可以减少Join的数据量
*/
```

### 3. Join顺序优化

```sql
-- 多表Join的优化
EXPLAIN 
SELECT 
    u.username,
    o.product_name,
    p.category
FROM users u          -- 10万行
JOIN orders o ON u.user_id = o.user_id    -- 100万行
JOIN products p ON o.product_id = p.product_id  -- 1万行
WHERE u.city = '北京';

-- 优化器会调整Join顺序：
-- 1. 先过滤users表（city='北京'），得到较少数据
-- 2. users JOIN orders（减少Join的右表数据量）
-- 3. 结果 JOIN products（products表最小，最后Join）
```

### 4. 聚合下推优化

```sql
-- 优化前：Join后聚合
SELECT 
    u.city,
    SUM(o.amount) as total_amount
FROM users u
JOIN orders o ON u.user_id = o.user_id
WHERE o.status = 'PAID'
GROUP BY u.city;

-- StarRocks优化：预聚合
/*
优化器可能生成如下计划：
1. 对orders表先按user_id预聚合
2. 再与users表Join
3. 最后按city聚合

这样可以减少Join的数据量
*/
```

## 查询优化器配置

### 1. CBO优化器参数

> **版本演进**：CBO优化器的发展历程
> - CBO v1：StarRocks 1.19+（基础成本优化）
> - CBO v2：StarRocks 2.3+（增强Join重排序）
> - CBO v3：StarRocks 2.5+（统计信息优化）
> - CBO v4：StarRocks 3.0+（自适应查询优化）

```sql
-- 查看优化器相关参数
SHOW VARIABLES LIKE '%optimizer%';
SHOW VARIABLES LIKE '%cbo%';

-- 关键参数说明：
-- enable_cbo: 启用基于成本的优化器
-- cbo_max_reorder_node: Join重排序的最大表数
-- cbo_push_down_aggregate: 启用聚合下推
-- cbo_prune_shuffle_column: 启用列裁剪
```

### 2. 统计信息收集

> **版本说明**：统计信息功能的版本要求
> - 手动统计信息：StarRocks 2.0+
> - 自动统计信息：StarRocks 2.5+
> - 直方图统计：StarRocks 3.0+
> - 自适应统计：StarRocks 3.1+

```sql
-- 手动收集表统计信息
ANALYZE TABLE orders;
ANALYZE TABLE users;

-- 查看统计信息
SHOW STATS META;

-- 查看特定表的统计信息
SHOW COLUMN STATS orders;

-- 统计信息对查询优化的影响：
-- 1. 行数估算：影响Join顺序
-- 2. 数据分布：影响Join算法选择
-- 3. 选择性：影响索引使用
```

### 3. Hint使用

> **Hint支持版本**：
> - BROADCAST/SHUFFLE Hint：StarRocks 2.0+
> - LEADING Hint：StarRocks 2.3+
> - SET_VAR Hint：StarRocks 2.5+
> - USE_INDEX Hint：StarRocks 3.0+

```sql
-- 强制使用特定Join算法
SELECT /*+ BROADCAST(u) */ 
    u.username, o.amount
FROM users u
JOIN orders o ON u.user_id = o.user_id;

-- 强制Join顺序
SELECT /*+ LEADING(u, o, p) */
    u.username, o.product_name, p.category
FROM users u, orders o, products p
WHERE u.user_id = o.user_id 
  AND o.product_id = p.product_id;

-- 设置并行度
SELECT /*+ SET_VAR(parallel_fragment_exec_instance_num=4) */
    COUNT(*) FROM orders;
```

## 性能监控和告警

### 1. 系统性能监控

```sql
-- 查看系统整体性能
SHOW PROCESSLIST;

-- 查看正在执行的查询
SHOW FULL PROCESSLIST;

-- 查看查询队列
SHOW QUEUES;

-- 查看资源使用情况
SHOW BACKENDS;

-- 获取详细的后端状态
SHOW PROC '/backends'\G
```

### 2. 查询性能指标

```sql
-- 创建性能监控视图
CREATE VIEW query_performance AS
SELECT 
    query_id,
    user,
    database_name,
    SUBSTR(sql_text, 1, 100) as sql_preview,
    query_start_time,
    total_time_ms,
    scan_rows,
    scan_bytes,
    ROUND(scan_bytes/1024/1024, 2) as scan_mb,
    ROUND(total_time_ms/1000, 2) as total_seconds,
    CASE 
        WHEN total_time_ms > 30000 THEN 'VERY_SLOW'
        WHEN total_time_ms > 10000 THEN 'SLOW' 
        WHEN total_time_ms > 3000 THEN 'NORMAL'
        ELSE 'FAST'
    END as performance_level
FROM information_schema.query_log 
WHERE query_start_time >= DATE_SUB(NOW(), INTERVAL 1 HOUR);

-- 查看性能分布
SELECT 
    performance_level,
    COUNT(*) as query_count,
    AVG(total_seconds) as avg_seconds,
    MAX(total_seconds) as max_seconds
FROM query_performance 
GROUP BY performance_level;
```

### 3. 自动化监控脚本

```bash
#!/bin/bash
# monitor_queries.sh - 查询性能监控脚本

MYSQL_CMD="mysql -h localhost -P 9030 -u root"

# 获取慢查询
echo "=== 慢查询监控 ==="
$MYSQL_CMD -e "
SELECT 
    query_id,
    user,
    SUBSTR(sql_text, 1, 50) as sql_preview,
    ROUND(total_time_ms/1000, 2) as seconds,
    scan_rows,
    ROUND(scan_bytes/1024/1024, 2) as scan_mb
FROM information_schema.query_log 
WHERE total_time_ms > 10000 
  AND query_start_time >= DATE_SUB(NOW(), INTERVAL 1 HOUR)
ORDER BY total_time_ms DESC 
LIMIT 10;
"

# 获取当前活跃查询
echo "=== 当前活跃查询 ==="
$MYSQL_CMD -e "
SELECT 
    Id,
    User,
    Host,
    db,
    Command,
    Time,
    SUBSTR(Info, 1, 50) as Query_Preview
FROM information_schema.processlist 
WHERE Command != 'Sleep' 
  AND Info IS NOT NULL
ORDER BY Time DESC;
"

# 获取系统资源使用
echo "=== 系统资源使用 ==="
$MYSQL_CMD -e "
SELECT 
    Backend_id,
    Host,
    Alive,
    SystemDecommissioned,
    CpuCores,
    MemUsedPct,
    DiskUsedPct
FROM information_schema.backends;
"
```

## 性能调优最佳实践

### 1. 查询优化检查清单

```sql
-- 1. 检查是否使用了分区裁剪
EXPLAIN SELECT * FROM orders 
WHERE order_date = '2024-01-15';
-- 确认：partitions=1/N（不是N/N）

-- 2. 检查是否使用了索引
EXPLAIN SELECT * FROM users 
WHERE user_id = 12345;
-- 确认：使用主键或索引扫描

-- 3. 检查Join算法是否合理
EXPLAIN SELECT u.*, o.* 
FROM users u JOIN orders o ON u.user_id = o.user_id;
-- 大表Join大表：Hash Join
-- 大表Join小表：Broadcast Join

-- 4. 检查聚合是否下推
EXPLAIN SELECT user_id, COUNT(*) 
FROM orders 
GROUP BY user_id;
-- 确认：聚合在数据源附近执行

-- 5. 检查排序是否必要
EXPLAIN SELECT * FROM orders 
ORDER BY order_time 
LIMIT 10;
-- 确认：使用TopN而不是全排序
```

### 2. 常见性能问题诊断

```sql
-- 问题1：查询返回大量数据
-- 诊断方法
EXPLAIN ANALYZE SELECT * FROM orders;  -- 查看返回行数

-- 解决方案：添加LIMIT或更精确的过滤条件
SELECT * FROM orders 
WHERE order_date = CURRENT_DATE 
LIMIT 1000;

-- 问题2：多表Join性能差
-- 诊断方法
EXPLAIN SELECT u.*, o.*, p.* 
FROM users u, orders o, products p
WHERE u.user_id = o.user_id 
  AND o.product_id = p.product_id;

-- 解决方案：
-- 1. 使用标准Join语法
-- 2. 先过滤再Join
-- 3. 检查Join键的数据分布

-- 问题3：聚合查询慢
-- 诊断方法
EXPLAIN SELECT category, SUM(amount) 
FROM orders 
GROUP BY category;

-- 解决方案：
-- 1. 创建物化视图
-- 2. 使用分区聚合
-- 3. 考虑预聚合表
```

### 3. 监控告警设置

```sql
-- 创建告警规则表
CREATE TABLE performance_alerts (
    alert_time DATETIME,
    alert_type VARCHAR(50),
    query_id VARCHAR(100),
    message TEXT,
    threshold_value DOUBLE,
    actual_value DOUBLE
) DISTRIBUTED BY HASH(alert_time) BUCKETS 10;

-- 慢查询告警（可以通过定时任务实现）
INSERT INTO performance_alerts
SELECT 
    NOW() as alert_time,
    'SLOW_QUERY' as alert_type,
    query_id,
    CONCAT('查询执行时间超过阈值: ', ROUND(total_time_ms/1000, 2), '秒') as message,
    30.0 as threshold_value,  -- 30秒阈值
    ROUND(total_time_ms/1000, 2) as actual_value
FROM information_schema.query_log 
WHERE total_time_ms > 30000 
  AND query_start_time >= DATE_SUB(NOW(), INTERVAL 5 MINUTE);
```

## 数据一致性检查

> **版本说明**：SYNC语句和一致性检查功能要求
> - SYNC语句：StarRocks 1.19+
> - 事务一致性检查：StarRocks 2.4+（Stream Load事务）
> - 跨会话一致性保证：StarRocks 2.5+

### 1. SYNC语句使用

StarRocks采用最终一致性模型，跨会话读取数据可能存在延迟。SYNC语句可以保证跨会话的强一致性。

```sql
-- 基本SYNC语句
SYNC;

-- 等待所有BE节点数据同步完成
-- 确保后续查询能够读取到最新的数据变更

-- 实际使用场景：ETL后的数据校验
-- 步骤1：数据导入
INSERT INTO target_table 
SELECT * FROM source_table WHERE process_date = '2024-01-15';

-- 步骤2：强制同步（确保数据在所有节点可见）
SYNC;

-- 步骤3：数据校验查询
SELECT COUNT(*) FROM target_table WHERE process_date = '2024-01-15';
```

### 2. 跨会话一致性问题诊断

```sql
-- 问题场景：会话A插入数据，会话B立即查询不到
-- 会话A（数据导入会话）
INSERT INTO user_stats (user_id, stat_date, login_count)
VALUES (12345, '2024-01-15', 5);

-- 会话B（查询会话）- 可能读不到数据
SELECT * FROM user_stats WHERE user_id = 12345 AND stat_date = '2024-01-15';
-- 结果：Empty set (可能的情况)

-- 解决方案：在会话B中使用SYNC
-- 会话B（查询会话）- 正确做法
SYNC;  -- 等待数据同步完成
SELECT * FROM user_stats WHERE user_id = 12345 AND stat_date = '2024-01-15';
-- 结果：确保能读取到最新数据
```

### 3. 数据一致性检查最佳实践

```sql
-- 1. ETL流程中的一致性保证
-- 创建数据校验存储过程
DELIMITER $$
CREATE PROCEDURE validate_etl_results(IN process_date DATE)
BEGIN
    DECLARE source_count INT DEFAULT 0;
    DECLARE target_count INT DEFAULT 0;
    DECLARE validation_result VARCHAR(20);
    
    -- 等待数据同步
    CALL SYNC();
    
    -- 获取源表记录数
    SELECT COUNT(*) INTO source_count 
    FROM source_orders 
    WHERE DATE(create_time) = process_date;
    
    -- 获取目标表记录数
    SELECT COUNT(*) INTO target_count 
    FROM orders 
    WHERE DATE(order_date) = process_date;
    
    -- 校验结果
    IF source_count = target_count THEN
        SET validation_result = 'PASS';
    ELSE
        SET validation_result = 'FAIL';
    END IF;
    
    -- 记录校验结果
    INSERT INTO etl_validation_log VALUES (
        NOW(), process_date, source_count, target_count, validation_result
    );
    
    SELECT validation_result, source_count, target_count;
END$$
DELIMITER ;

-- 使用校验存储过程
CALL validate_etl_results('2024-01-15');
```

### 4. 实时同步验证

```sql
-- 创建实时同步验证脚本
-- 1. 写入测试数据
INSERT INTO sync_test_table VALUES (
    UNIX_TIMESTAMP(NOW()), 
    CONNECTION_ID(), 
    'test_data'
);

-- 2. 记录写入时间
SET @write_time = NOW();

-- 3. 立即查询（可能读不到）
SET @immediate_count = (
    SELECT COUNT(*) FROM sync_test_table 
    WHERE write_time = @write_time
);

-- 4. SYNC后查询（确保读到）
SYNC;
SET @sync_count = (
    SELECT COUNT(*) FROM sync_test_table 
    WHERE write_time = @write_time
);

-- 5. 对比结果
SELECT 
    @write_time as write_time,
    @immediate_count as immediate_count,
    @sync_count as sync_count,
    CASE 
        WHEN @immediate_count = @sync_count THEN 'CONSISTENT'
        ELSE 'INCONSISTENT'
    END as consistency_status;
```

### 5. 分布式环境中的一致性监控

```sql
-- 创建一致性监控视图
CREATE VIEW consistency_monitor AS
SELECT 
    tablet_id,
    backend_id,
    version,
    version_hash,
    row_count,
    data_size
FROM information_schema.tablets
WHERE table_name = 'orders'
ORDER BY tablet_id, backend_id;

-- 检查副本一致性
SELECT 
    tablet_id,
    COUNT(DISTINCT version) as version_count,
    COUNT(DISTINCT version_hash) as hash_count,
    COUNT(DISTINCT row_count) as row_count_variations,
    CASE 
        WHEN COUNT(DISTINCT version) = 1 
         AND COUNT(DISTINCT version_hash) = 1 
         AND COUNT(DISTINCT row_count) = 1 THEN 'CONSISTENT'
        ELSE 'INCONSISTENT'
    END as consistency_status
FROM consistency_monitor
GROUP BY tablet_id
HAVING consistency_status = 'INCONSISTENT';
```

### 6. 事务一致性检查（v3.5+）

```sql
-- 事务执行后的一致性验证
-- 1. 开始事务并记录操作
BEGIN WORK;

-- 插入操作日志
INSERT INTO transaction_log VALUES (
    UUID(), 'INSERT', 'orders', NOW(), 'STARTED'
);

-- 执行业务操作
INSERT INTO orders (user_id, product_id, amount, order_date)
SELECT user_id, product_id, amount, CURRENT_DATE
FROM staging_orders
WHERE process_flag = 0;

-- 更新处理标记
UPDATE staging_orders SET process_flag = 1 WHERE process_flag = 0;

-- 记录操作完成
UPDATE transaction_log 
SET status = 'COMMITTED', end_time = NOW()
WHERE operation = 'INSERT' AND table_name = 'orders' 
AND DATE(start_time) = CURRENT_DATE;

COMMIT WORK;

-- 2. 事务提交后验证数据一致性
SYNC;  -- 确保数据同步

-- 验证数据完整性
SELECT 
    'staging_orders' as table_name,
    COUNT(*) as processed_count
FROM staging_orders 
WHERE process_flag = 1 AND DATE(update_time) = CURRENT_DATE
UNION ALL
SELECT 
    'orders' as table_name,
    COUNT(*) as inserted_count
FROM orders 
WHERE DATE(order_date) = CURRENT_DATE;

-- 验证事务日志
SELECT * FROM transaction_log 
WHERE DATE(start_time) = CURRENT_DATE 
AND status = 'COMMITTED';
```

### 7. 自动化一致性检查脚本

```bash
#!/bin/bash
# consistency_check.sh - 数据一致性检查脚本

MYSQL_CMD="mysql -h localhost -P 9030 -u root"
DATE_TO_CHECK=${1:-$(date +%Y-%m-%d)}

echo "=== 数据一致性检查 ==="
echo "检查日期: $DATE_TO_CHECK"

# 1. 强制数据同步
echo "步骤1: 执行数据同步..."
$MYSQL_CMD -e "SYNC;"

# 2. 检查表级别一致性
echo "步骤2: 检查表级别数据一致性..."
$MYSQL_CMD -e "
SELECT 
    table_name,
    SUM(row_count) as total_rows,
    COUNT(DISTINCT backend_id) as backend_count,
    MIN(row_count) as min_rows,
    MAX(row_count) as max_rows,
    CASE 
        WHEN MIN(row_count) = MAX(row_count) THEN 'CONSISTENT'
        ELSE 'INCONSISTENT'
    END as status
FROM (
    SELECT 
        table_name,
        backend_id,
        SUM(row_count) as row_count
    FROM information_schema.tablets t
    JOIN information_schema.tables tb ON t.table_name = tb.table_name
    WHERE tb.table_schema = 'demo_etl'
    GROUP BY table_name, backend_id
) t
GROUP BY table_name
ORDER BY table_name;
"

# 3. 检查关键表的数据量
echo "步骤3: 检查关键表数据量..."
$MYSQL_CMD -e "
SELECT 
    'users' as table_name,
    COUNT(*) as row_count,
    MAX(update_time) as last_update
FROM users
UNION ALL
SELECT 
    'orders' as table_name,
    COUNT(*) as row_count,
    MAX(order_date) as last_update
FROM orders
WHERE DATE(order_date) = '$DATE_TO_CHECK';
"

# 4. 检查副本一致性
echo "步骤4: 检查副本一致性..."
$MYSQL_CMD -e "
SELECT 
    COUNT(*) as inconsistent_tablets
FROM (
    SELECT 
        tablet_id,
        COUNT(DISTINCT version_hash) as hash_variations
    FROM information_schema.tablets
    WHERE table_name IN ('users', 'orders')
    GROUP BY tablet_id
    HAVING hash_variations > 1
) t;
"

echo "=== 一致性检查完成 ==="
```

## 版本特性对比

| 功能特性 | v2.0 | v2.5 | v3.0 | v3.1+ |
|---------|------|------|------|-------|
| **基础EXPLAIN** | ✅ | ✅ | ✅ | ✅ |
| **EXPLAIN ANALYZE** | ❌ | ✅ | ✅ | ✅ |
| **Pipeline Profile** | ❌ | ✅ | ✅ | ✅ |
| **自动统计信息** | ❌ | ✅ | ✅ | ✅ |
| **直方图统计** | ❌ | ❌ | ✅ | ✅ |
| **自适应优化** | ❌ | ❌ | ❌ | ✅ |
| **高级Hint** | 基础 | 增强 | 完整 | 完整 |
| **SYNC一致性** | ✅ | ✅ | ✅ | ✅ |
| **事务一致性检查** | ❌ | 部分 | ✅ | ✅ |

## 小结

StarRocks提供了强大的查询分析工具：

1. **EXPLAIN系列**：分析执行计划，理解查询逻辑
2. **Profile功能**：获取实际执行统计，诊断性能瓶颈  
3. **查询日志**：监控历史查询性能，发现慢查询
4. **系统视图**：监控集群状态和资源使用
5. **数据一致性检查**：使用SYNC语句保证跨会话数据一致性

掌握这些工具的使用，可以：
- 快速定位性能问题
- 验证优化效果  
- 建立性能监控体系
- 制定优化策略
- 确保数据一致性和完整性

### 数据一致性注意事项

在使用StarRocks进行查询分析时，需要特别注意：

- **跨会话一致性**：数据写入后可能存在跨会话的可见性延迟，使用SYNC语句确保一致性
- **事务内可见性**：StarRocks事务内的数据变更对同一事务内的后续查询不可见（v3.5+）
- **分布式一致性**：在分布式环境中，需要监控副本间的数据一致性
- **ETL后校验**：数据导入后必须使用SYNC确保后续查询的准确性

查询分析是SQL优化的基础，结合数据一致性检查，为后续的Join优化、聚合优化等提供了重要依据。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../04-kettle-integration/error-handling-mechanisms.md) | [➡️ 下一页](join-optimization.md)
---