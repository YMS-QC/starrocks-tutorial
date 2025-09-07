---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](materialized-views.md) | [➡️ 下一页](colocation-join.md)
---

# 动态分区

动态分区是 StarRocks 提供的自动分区管理功能，可以根据时间或数据特征自动创建、删除分区，极大简化了大数据量表的分区维护工作。本章节详细介绍动态分区的原理、配置方法和最佳实践。

## 1. 动态分区概述

### 1.1 动态分区原理

动态分区通过后台任务自动执行以下操作：

- **自动创建**：根据当前时间和配置规则自动创建未来分区
- **自动删除**：自动删除过期的历史分区
- **滚动维护**：保持固定数量的分区，实现数据生命周期管理
- **无缝切换**：分区创建和删除对业务查询透明

### 1.2 动态分区优势

**管理简化**
- 无需手动创建分区，避免人为错误
- 自动清理历史数据，节省存储空间
- 统一的分区管理策略，降低维护成本

**性能优化**
- 分区裁剪优化查询性能
- 并行加载和查询处理
- 历史数据归档策略

**业务连续性**
- 7x24小时自动运行，无需人工干预
- 避免因分区缺失导致的数据写入失败
- 平滑的数据生命周期管理

### 1.3 支持的分区类型

| 分区类型 | 时间单位 | 分区命名规则 | 适用场景 |
|---------|---------|-------------|----------|
| 天分区 | DAY | p20230101 | 日志数据、交易记录 |
| 周分区 | WEEK | p2023_01 | 周报表、活动数据 |
| 月分区 | MONTH | p202301 | 月度统计、历史归档 |
| 季度分区 | QUARTER | p2023_Q1 | 季度报表 |
| 年分区 | YEAR | p2023 | 年度数据归档 |

## 2. 动态分区配置

### 2.1 基础配置

```sql
-- 创建带动态分区的表
CREATE TABLE sales_data (
    sale_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    product_id BIGINT NOT NULL,
    sale_date DATE NOT NULL,
    amount DECIMAL(10,2),
    created_time DATETIME
) ENGINE=OLAP
DUPLICATE KEY(sale_id)
PARTITION BY RANGE(sale_date) (
    PARTITION p20230101 VALUES [('2023-01-01'), ('2023-01-02')),
    PARTITION p20230102 VALUES [('2023-01-02'), ('2023-01-03'))
)
DISTRIBUTED BY HASH(user_id) BUCKETS 32
PROPERTIES (
    -- 启用动态分区
    "dynamic_partition.enable" = "true",
    
    -- 分区时间单位（DAY/WEEK/MONTH/QUARTER/YEAR）
    "dynamic_partition.time_unit" = "DAY",
    
    -- 分区时间列
    "dynamic_partition.time_zone" = "Asia/Shanghai",
    
    -- 提前创建分区数量（未来7天）
    "dynamic_partition.end" = "7",
    
    -- 保留历史分区数量（过去30天）
    "dynamic_partition.start" = "-30",
    
    -- 分区名前缀
    "dynamic_partition.prefix" = "p",
    
    -- 分区桶数
    "dynamic_partition.buckets" = "32",
    
    -- 副本数
    "replication_num" = "3"
);
```

### 2.2 详细参数说明

**核心参数**
```sql
-- 动态分区开关
"dynamic_partition.enable" = "true"      -- 启用动态分区

-- 时间配置
"dynamic_partition.time_unit" = "DAY"    -- 分区时间粒度
"dynamic_partition.time_zone" = "Asia/Shanghai"  -- 时区设置

-- 分区范围
"dynamic_partition.start" = "-30"        -- 保留30天前的分区
"dynamic_partition.end" = "7"            -- 预创建7天后的分区

-- 命名配置  
"dynamic_partition.prefix" = "p"         -- 分区名前缀
```

**高级参数**
```sql
-- 分区属性
"dynamic_partition.buckets" = "32"       -- 新分区的桶数
"dynamic_partition.replication_num" = "3" -- 新分区的副本数

-- 执行配置
"dynamic_partition.start_day_of_week" = "1"    -- 周分区起始日（1=周一）
"dynamic_partition.start_day_of_month" = "1"   -- 月分区起始日

-- 历史数据处理
"dynamic_partition.history_partition_num" = "0" -- 创建历史分区数量
```

### 2.3 不同时间粒度配置

**天分区配置**
```sql
CREATE TABLE daily_logs (
    log_time DATETIME NOT NULL,
    user_id BIGINT,
    action VARCHAR(100),
    details JSON
) ENGINE=OLAP
DUPLICATE KEY(log_time)
PARTITION BY RANGE(log_time) ()
DISTRIBUTED BY HASH(user_id) BUCKETS 64
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-90",     -- 保留90天
    "dynamic_partition.end" = "3",         -- 提前3天创建
    "dynamic_partition.prefix" = "day_",
    "dynamic_partition.buckets" = "64"
);
```

**月分区配置**
```sql
CREATE TABLE monthly_summary (
    stat_month DATE NOT NULL,
    user_id BIGINT,
    order_count INT,
    total_amount DECIMAL(15,2)
) ENGINE=OLAP
DUPLICATE KEY(stat_month, user_id)
PARTITION BY RANGE(stat_month) ()
DISTRIBUTED BY HASH(user_id) BUCKETS 16
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "MONTH",
    "dynamic_partition.start" = "-24",     -- 保留24个月
    "dynamic_partition.end" = "3",         -- 提前3个月创建
    "dynamic_partition.prefix" = "m_",
    "dynamic_partition.buckets" = "16",
    "dynamic_partition.start_day_of_month" = "1"  -- 月初开始
);
```

**周分区配置**
```sql
CREATE TABLE weekly_reports (
    report_week DATE NOT NULL,
    metric_name VARCHAR(100),
    metric_value DOUBLE
) ENGINE=OLAP
DUPLICATE KEY(report_week, metric_name)
PARTITION BY RANGE(report_week) ()
DISTRIBUTED BY HASH(metric_name) BUCKETS 8
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "WEEK",
    "dynamic_partition.start" = "-52",     -- 保留52周
    "dynamic_partition.end" = "4",         -- 提前4周创建
    "dynamic_partition.prefix" = "week_",
    "dynamic_partition.start_day_of_week" = "1"  -- 周一开始
);
```

## 3. 动态分区管理

### 3.1 查看动态分区状态

```sql
-- 查看表的动态分区配置
SHOW DYNAMIC PARTITION TABLES FROM database_name;

-- 查看特定表的分区信息
SHOW PARTITIONS FROM sales_data;

-- 查看动态分区详细配置
SHOW CREATE TABLE sales_data;

-- 查看动态分区任务执行历史
SELECT 
    table_name,
    partition_name,
    operation_type,
    operation_time,
    status
FROM information_schema.dynamic_partition_history
WHERE table_name = 'sales_data'
ORDER BY operation_time DESC
LIMIT 10;
```

### 3.2 修改动态分区配置

```sql
-- 修改保留天数
ALTER TABLE sales_data SET (
    "dynamic_partition.start" = "-60"  -- 改为保留60天
);

-- 修改预创建天数
ALTER TABLE sales_data SET (
    "dynamic_partition.end" = "14"     -- 改为提前14天创建
);

-- 临时禁用动态分区
ALTER TABLE sales_data SET (
    "dynamic_partition.enable" = "false"
);

-- 重新启用动态分区
ALTER TABLE sales_data SET (
    "dynamic_partition.enable" = "true"
);

-- 修改时区设置
ALTER TABLE sales_data SET (
    "dynamic_partition.time_zone" = "UTC"
);
```

### 3.3 手动分区操作

```sql
-- 手动创建分区（用于异常情况）
ALTER TABLE sales_data ADD PARTITION p20231201 
VALUES [('2023-12-01'), ('2023-12-02'));

-- 手动删除分区
ALTER TABLE sales_data DROP PARTITION p20230101;

-- 手动触发动态分区检查
ADMIN SET FRONTEND CONFIG ("dynamic_partition_check_interval_seconds" = "60");
```

## 4. 监控和运维

### 4.1 动态分区监控

```sql
-- 创建动态分区监控视图
CREATE VIEW dynamic_partition_monitor AS
SELECT 
    table_name,
    COUNT(*) as partition_count,
    MIN(partition_name) as oldest_partition,
    MAX(partition_name) as newest_partition,
    SUM(data_length) / 1024 / 1024 / 1024 as total_size_gb
FROM information_schema.partitions
WHERE table_schema = 'your_database'
  AND partition_name IS NOT NULL
GROUP BY table_name;

-- 查看各表分区分布
SELECT * FROM dynamic_partition_monitor
ORDER BY total_size_gb DESC;
```

**分区数量告警**
```sql
-- 检查分区数量异常的表
SELECT 
    table_name,
    partition_count,
    CASE 
        WHEN partition_count > 100 THEN 'WARNING: Too many partitions'
        WHEN partition_count < 5 THEN 'WARNING: Too few partitions'
        ELSE 'NORMAL'
    END as status
FROM dynamic_partition_monitor
WHERE partition_count > 100 OR partition_count < 5;
```

### 4.2 性能监控

```sql
-- 动态分区操作性能监控
SELECT 
    DATE(operation_time) as op_date,
    operation_type,
    COUNT(*) as operation_count,
    AVG(TIMESTAMPDIFF(SECOND, start_time, end_time)) as avg_duration_seconds
FROM information_schema.dynamic_partition_history
WHERE operation_time >= CURRENT_DATE - INTERVAL 7 DAY
GROUP BY DATE(operation_time), operation_type
ORDER BY op_date DESC, operation_type;

-- 分区查询性能分析
SELECT 
    table_name,
    partition_name,
    query_count,
    avg_query_time_ms,
    total_rows_examined
FROM information_schema.partition_usage_stats
WHERE query_count > 0
ORDER BY avg_query_time_ms DESC;
```

### 4.3 告警和通知

```bash
#!/bin/bash
# dynamic_partition_monitor.sh

DB_HOST="starrocks_host"
DB_PORT="9030"
DB_USER="root"
ALERT_EMAIL="admin@company.com"

# 检查动态分区失败
FAILED_PARTITIONS=$(mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -se "
SELECT COUNT(*) FROM information_schema.dynamic_partition_history 
WHERE status = 'FAILED' 
  AND operation_time >= NOW() - INTERVAL 1 HOUR
")

if [ "$FAILED_PARTITIONS" -gt 0 ]; then
    echo "动态分区操作失败 $FAILED_PARTITIONS 次" | \
    mail -s "StarRocks 动态分区告警" "$ALERT_EMAIL"
fi

# 检查分区数量异常
ABNORMAL_TABLES=$(mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -se "
SELECT table_name FROM (
    SELECT 
        table_name,
        COUNT(*) as partition_count
    FROM information_schema.partitions
    WHERE table_schema = 'your_database'
      AND partition_name IS NOT NULL
    GROUP BY table_name
    HAVING partition_count > 200 OR partition_count < 3
) t
")

if [ -n "$ABNORMAL_TABLES" ]; then
    echo "以下表分区数量异常: $ABNORMAL_TABLES" | \
    mail -s "StarRocks 分区数量告警" "$ALERT_EMAIL"
fi
```

## 5. 高级应用场景

### 5.1 数据生命周期管理

```sql
-- 多层数据保留策略
CREATE TABLE user_behavior_logs (
    log_time DATETIME NOT NULL,
    user_id BIGINT,
    event_type VARCHAR(50),
    event_data JSON
) ENGINE=OLAP
DUPLICATE KEY(log_time, user_id)
PARTITION BY RANGE(log_time) ()
DISTRIBUTED BY HASH(user_id) BUCKETS 128
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    
    -- 热数据：最近7天，高性能SSD存储
    "dynamic_partition.hot_partition_num" = "7",
    "dynamic_partition.storage_medium" = "SSD",
    
    -- 温数据：8-30天，转为HDD存储  
    "dynamic_partition.start" = "-30",
    "dynamic_partition.end" = "3",
    
    -- 冷数据：自动删除30天前数据
    "dynamic_partition.prefix" = "p"
);

-- 配置存储介质转换
ALTER TABLE user_behavior_logs SET (
    "dynamic_partition.storage_cooldown_time" = "7d"  -- 7天后转为冷存储
);
```

### 5.2 多租户分区管理

```sql
-- 按租户和时间双重分区
CREATE TABLE saas_tenant_data (
    tenant_id INT NOT NULL,
    record_time DATETIME NOT NULL,
    business_data JSON
) ENGINE=OLAP
DUPLICATE KEY(tenant_id, record_time)
PARTITION BY RANGE(record_time) ()
DISTRIBUTED BY HASH(tenant_id) BUCKETS 64
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-90",
    "dynamic_partition.end" = "7",
    "dynamic_partition.prefix" = "tenant_day_"
);

-- 为不同租户配置不同的保留策略
-- 可以通过应用层定期清理特定租户的历史数据
```

### 5.3 实时数据湖集成

```sql
-- 配合外部存储的分层架构
CREATE TABLE realtime_events (
    event_time DATETIME NOT NULL,
    event_id VARCHAR(64),
    event_payload JSON
) ENGINE=OLAP  
DUPLICATE KEY(event_time, event_id)
PARTITION BY RANGE(event_time) ()
DISTRIBUTED BY HASH(event_id) BUCKETS 256
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "HOUR",  -- 小时级分区
    "dynamic_partition.start" = "-48",       -- 保留48小时
    "dynamic_partition.end" = "12",          -- 提前12小时创建
    "dynamic_partition.prefix" = "hour_",
    
    -- 自动导出到对象存储
    "dynamic_partition.auto_export" = "true",
    "dynamic_partition.export_path" = "s3://data-lake/events/"
);
```

## 6. 故障排查

### 6.1 常见问题诊断

**问题1：动态分区未自动创建**
```sql
-- 检查动态分区配置
SHOW DYNAMIC PARTITION TABLES;

-- 检查系统时间和时区
SELECT NOW(), @@time_zone;

-- 检查FE日志
-- 查看fe.log中的dynamic partition相关日志
```

**问题2：历史分区未自动删除**
```sql
-- 检查分区保留配置
SELECT 
    table_name,
    dynamic_partition_start,
    dynamic_partition_end
FROM information_schema.dynamic_partition_tables;

-- 检查分区删除历史
SELECT * FROM information_schema.dynamic_partition_history
WHERE operation_type = 'DROP'
ORDER BY operation_time DESC;
```

**问题3：分区名称冲突**
```sql
-- 检查现有分区命名
SHOW PARTITIONS FROM problem_table;

-- 修复分区命名冲突
ALTER TABLE problem_table SET (
    "dynamic_partition.prefix" = "new_prefix_"
);
```

### 6.2 性能问题优化

**分区过多导致性能下降**
```sql
-- 查看分区数量分布
SELECT 
    table_name,
    COUNT(*) as partition_count,
    AVG(data_length) as avg_partition_size
FROM information_schema.partitions  
WHERE table_schema = 'your_database'
GROUP BY table_name
ORDER BY partition_count DESC;

-- 优化策略：调整分区粒度
ALTER TABLE large_table SET (
    "dynamic_partition.time_unit" = "WEEK"  -- 从DAY改为WEEK
);
```

**分区创建延迟问题**
```sql
-- 检查分区创建延迟
SELECT 
    table_name,
    MAX(partition_name) as latest_partition,
    CURRENT_DATE as current_date
FROM information_schema.partitions
WHERE table_schema = 'your_database'
GROUP BY table_name;

-- 调整检查频率
ADMIN SET FRONTEND CONFIG (
    "dynamic_partition_check_interval_seconds" = "300"  -- 5分钟检查一次
);
```

## 7. 最佳实践总结

### 7.1 设计建议

**分区粒度选择**
- **高频写入数据**：使用DAY或HOUR分区
- **批量数据**：使用WEEK或MONTH分区  
- **历史归档**：使用MONTH或QUARTER分区

**保留策略设计**
- **业务需求**：根据业务查询需求设置保留期
- **存储成本**：平衡查询性能和存储成本
- **合规要求**：考虑数据保留的法规要求

### 7.2 运维建议

**监控要点**
- 动态分区创建和删除的成功率
- 分区数量和存储使用情况  
- 分区操作的执行耗时

**容量规划**
- 预估数据增长速度，合理设置分区保留期
- 监控存储使用趋势，及时调整保留策略
- 考虑节假日等数据波动因素

### 7.3 性能优化

**查询优化**
- 查询条件中包含分区列，利用分区裁剪
- 避免跨大量分区的查询
- 合理设置分区的排序键

**写入优化**  
- 数据按分区列有序写入，提升写入性能
- 避免向过多分区同时写入数据
- 合理设置批量提交大小

动态分区是管理大规模时序数据的重要工具，正确配置和使用可以大幅简化运维工作，提升系统的自动化水平和数据处理效率。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](materialized-views.md) | [➡️ 下一页](colocation-join.md)
---