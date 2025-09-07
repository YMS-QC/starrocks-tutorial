---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](data-types-mapping.md) | [➡️ 下一页](../04-kettle-integration/kettle-setup.md)
---

# 事务和数据一致性

> **版本要求**：SQL事务功能从StarRocks 3.5.0开始支持，Stream Load事务从2.4版本开始支持

## ⚠️ 重要架构指导

### 🎯 StarRocks作为分析型数据库的定位

**StarRocks是OLAP数据库，核心优势在于查询分析性能，而非事务处理能力。**

#### 正确的使用方式：
- ✅ **查询分析**：复杂聚合、多维分析、大数据量查询
- ✅ **批量数据加载**：Stream Load、Routine Load等高吞吐导入
- ✅ **实时数据仓库**：准实时的数据分析和报表
- ✅ **数据湖分析**：对接Hive、Iceberg等数据湖格式

#### ❌ 不建议的使用方式：
- ❌ **OLTP业务**：不应替代MySQL/Oracle处理在线交易
- ❌ **复杂事务逻辑**：不依赖StarRocks事务处理业务逻辑
- ❌ **实时写入更新**：不适合高频率的单条记录更新
- ❌ **强一致性要求**：不适合对一致性要求极高的核心业务

### 🏗️ 推荐的数据架构

```
[OLTP系统(MySQL/Oracle)] -> [CDC/ETL] -> [StarRocks] -> [BI/报表]
         ↓                              ↓
   [事务保证]                     [分析查询]
   [业务逻辑]                     [数据展示]
```

**架构原则**：
- **读写分离**：OLTP处理写入和事务，OLAP处理查询和分析
- **最终一致性**：通过ETL保证数据一致性，而非数据库事务
- **分层架构**：业务层、数据层、分析层各司其职

### 📋 事务功能使用建议

| 场景 | StarRocks事务 | 推荐替代方案 | 理由 |
|------|--------------|------------|------|
| **数据导入一致性** | ✅ Stream Load事务 | ETL工具+校验 | 导入场景，功能稳定 |
| **批量数据处理** | ⚠️ 谨慎使用SQL事务 | 分批处理+补偿机制 | 避免长事务影响性能 |
| **业务逻辑处理** | ❌ 不建议 | 应用层事务管理 | 保持架构清晰 |
| **数据修复操作** | ⚠️ 可考虑 | 基于分区的批量操作 | 运维场景，小心使用 |

### 💡 替代方案指导

#### 1. ETL层数据一致性保证（首选）
```bash
# 基于Kettle/DataX的一致性保证
1. 数据抽取 -> 2. 数据校验 -> 3. 数据加载 -> 4. 结果验证
   ↓失败           ↓失败           ↓失败          ↓失败
5. 告警通知    <- 4. 数据回滚   <- 3. 清理数据  <- 2. 重新处理
```

#### 2. 应用层事务协调（推荐）
```java
// 分布式事务协调模式
@Service
public class DataConsistencyCoordinator {
    // 协调多个数据源的一致性
    // 使用补偿事务(Saga)模式
    // 而非依赖数据库事务
}
```

#### 3. 数据版本管理（高级）
```sql
-- 基于版本的数据管理，替代传统事务
CREATE TABLE business_data_versioned (
    business_id BIGINT,
    version_id BIGINT,
    data_snapshot JSON,
    created_time DATETIME
) PARTITION BY RANGE(created_time);
```

## 学习目标

- 理解StarRocks的事务模型和ACID特性
- 掌握StarRocks与Oracle/MySQL事务的关键差异
- 学会在开发中正确处理数据一致性问题
- 了解事务使用限制和最佳实践

## StarRocks事务模型概述

### 1. 事务支持类型

StarRocks提供两种主要的事务支持：

| 事务类型 | 支持版本 | 主要用途 | ACID保证 |
|---------|---------|---------|---------|
| **SQL事务** | 3.5.0+ | 多表批量操作 | 有限ACID |
| **Stream Load事务** | 2.4+ | 高并发数据导入 | 完整ACID |
| **存储引擎事务** | 1.19+ | 单次导入操作 | 快照隔离 |

### 2. 版本功能支持矩阵

| 功能特性 | v2.5 | v3.0 | v3.1 | v3.2+ | v3.5+ |
|---------|------|------|------|-------|-------|
| **存储引擎ACID** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Stream Load事务** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Routine Load一致性** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **SQL事务(Beta)** | ❌ | ❌ | ❌ | ❌ | ✅ |
| **2PC支持** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **事务标签管理** | ✅ | ✅ | ✅ | ✅ | ✅ |

## ACID特性详解

### 1. 原子性（Atomicity）

**存储引擎级别**：
```sql
-- StarRocks保证每次导入操作的原子性
-- 以下操作要么全部成功，要么全部失败
INSERT INTO user_behavior 
SELECT * FROM source_table WHERE date >= '2024-01-01';
```

**SQL事务级别**（v3.5+）：
```sql
-- 多表操作的原子性保证
BEGIN WORK;
INSERT INTO dim_users SELECT * FROM staging_users;
INSERT INTO fact_orders SELECT * FROM staging_orders; 
-- 任一语句失败，所有变更都会回滚
COMMIT WORK;
```

### 2. 一致性（Consistency）

**会话内一致性**：
```sql
-- 同一会话内立即可见
INSERT INTO test_table VALUES (1, 'data');
SELECT * FROM test_table WHERE id = 1; -- ✅ 可以读取到数据
```

**跨会话一致性**：
```sql
-- Session A
INSERT INTO test_table VALUES (2, 'data');

-- Session B（可能存在延迟）
SELECT * FROM test_table WHERE id = 2; -- ❌ 可能读不到
-- 使用SYNC保证一致性
SYNC;
SELECT * FROM test_table WHERE id = 2; -- ✅ 确保读取到最新数据
```

### 3. 隔离性（Isolation）

**隔离级别限制**：
StarRocks仅支持有限的READ COMMITTED隔离级别

```sql
-- 事务内数据变更不可见的示例
BEGIN WORK;
INSERT INTO test_table VALUES (3, 'test');
-- ❌ 在同一事务内无法读取到刚插入的数据
SELECT * FROM test_table WHERE id = 3; -- 读不到数据
COMMIT WORK;
-- ✅ 提交后其他会话可以读取
```

### 4. 持久性（Durability）

StarRocks通过以下机制保证持久性：
- 多副本存储（默认3副本）
- WAL日志机制
- 定期检查点
- 副本一致性检查

## 与传统数据库的关键差异

### 1. 事务隔离级别对比

| 数据库 | 支持的隔离级别 | 默认级别 | 事务内可见性 |
|--------|--------------|---------|-------------|
| **Oracle** | RC, RR, SI | RC | ✅ 事务内变更可见 |
| **MySQL** | RU, RC, RR, SI | RR | ✅ 事务内变更可见 |
| **StarRocks** | 有限RC | RC | ❌ 事务内变更不可见 |

### 2. 并发控制差异

**传统数据库**：
```sql
-- Oracle/MySQL支持写冲突检测
-- Session A
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;

-- Session B (会等待或检测到冲突)
UPDATE accounts SET balance = balance + 50 WHERE id = 1; -- 阻塞或报错
```

**StarRocks**：
```sql
-- StarRocks不支持写冲突检测
-- 并发写入的可见性依赖于COMMIT的时间顺序
-- 建议在应用层实现冲突检测逻辑
```

### 3. 跨会话数据一致性

**传统数据库**：
```sql
-- 事务提交后立即在所有会话中可见
-- Session A
INSERT INTO orders VALUES (1, 'order1');
COMMIT;

-- Session B（立即可见）
SELECT * FROM orders WHERE id = 1; -- ✅ 立即读取到数据
```

**StarRocks**：
```sql
-- 需要显式同步保证跨会话一致性
-- Session A  
INSERT INTO orders VALUES (1, 'order1');

-- Session B
SYNC; -- 等待所有BE节点数据同步完成
SELECT * FROM orders WHERE id = 1; -- ✅ 确保读取到最新数据
```

## 事务使用限制和约束

### 1. SQL事务限制（v3.5+）

```sql
-- ✅ 支持的操作
BEGIN WORK;
INSERT INTO table1 SELECT * FROM source1;
INSERT INTO table2 SELECT * FROM source2;
COMMIT WORK;

-- ❌ 不支持的操作
BEGIN WORK;
INSERT INTO table1 VALUES (1);
INSERT INTO table1 VALUES (2); -- 错误：同一表多次INSERT
COMMIT WORK;

-- ❌ 不支持的操作
BEGIN WORK;
INSERT INTO db1.table1 VALUES (1);
INSERT INTO db2.table1 VALUES (1); -- 错误：跨数据库操作
COMMIT WORK;
```

### 2. 事务数量限制

```sql
-- 查看当前数据库的运行事务数
SHOW PROC '/transaction';

-- 调整事务限制（需要管理员权限）
ADMIN SET FRONTEND CONFIG ("max_running_txn_num_per_db" = "2000");
```

**版本差异**：
- v3.1+：单数据库最大900个并发事务
- v3.1之前：单数据库最大100个并发事务

### 3. 事务超时配置

```sql
-- Stream Load事务超时配置
-- 事务默认超时：600秒
-- 空闲事务超时：300秒
-- 准备状态超时：3600秒（v3.5.4+）

-- Flink集成的事务配置
ADMIN SET FRONTEND CONFIG ("prepared_transaction_default_timeout_second" = "3600");
ADMIN SET FRONTEND CONFIG ("label_keep_max_second" = "259200");
ADMIN SET FRONTEND CONFIG ("label_keep_max_num" = "1000");
```

## 开发最佳实践

### 1. 正确的事务使用模式

**✅ 推荐做法**：
```sql
-- 使用短事务，快速提交
BEGIN WORK;
-- 执行必要的数据操作
INSERT INTO summary_table 
SELECT date, count(*), sum(amount)
FROM detail_table 
WHERE date = '2024-01-01'
GROUP BY date;
COMMIT WORK;

-- 跨会话读取前使用SYNC
SYNC;
SELECT * FROM summary_table WHERE date = '2024-01-01';
```

**❌ 避免的做法**：
```sql
-- 避免长事务
BEGIN WORK;
-- 大量数据处理...
INSERT INTO table1 SELECT * FROM huge_table; -- 可能超时
-- 其他复杂操作...
COMMIT WORK; -- 可能失败

-- 避免依赖事务内数据可见性
BEGIN WORK;
INSERT INTO temp_table VALUES (1, 'data');
SELECT * FROM temp_table WHERE id = 1; -- 读不到数据
COMMIT WORK;
```

### 2. 数据一致性保证策略

**应用层一致性控制**：
```sql
-- 1. 使用唯一标识符避免重复导入
INSERT INTO orders (id, order_no, amount, create_time)
SELECT id, order_no, amount, now()
FROM source_orders 
WHERE batch_id = 'batch_20240101'
AND order_no NOT IN (SELECT order_no FROM orders);

-- 2. 使用SYNC确保数据可见性
SYNC;

-- 3. 验证数据完整性
SELECT COUNT(*) FROM orders WHERE batch_id = 'batch_20240101';
```

**分布式锁模式**：
```sql
-- 使用表级锁定机制
CREATE TABLE process_lock (
    process_name VARCHAR(100) PRIMARY KEY,
    lock_time DATETIME,
    holder VARCHAR(100)
);

-- 获取锁
INSERT INTO process_lock VALUES ('daily_etl', NOW(), 'worker1');

-- 执行ETL操作
BEGIN WORK;
-- ETL逻辑...
COMMIT WORK;

-- 释放锁
DELETE FROM process_lock WHERE process_name = 'daily_etl';
```

### 3. 错误处理和重试机制

```sql
-- 事务失败处理示例
DECLARE retry_count INT DEFAULT 0;
DECLARE max_retries INT DEFAULT 3;

retry_loop: WHILE retry_count < max_retries DO
    BEGIN
        -- 开始事务
        START TRANSACTION;
        
        -- 执行业务逻辑
        INSERT INTO target_table SELECT * FROM source_table WHERE process_flag = 0;
        UPDATE source_table SET process_flag = 1 WHERE process_flag = 0;
        
        -- 提交事务
        COMMIT;
        
        -- 成功则退出循环
        LEAVE retry_loop;
        
    EXCEPTION
        WHEN transaction_timeout THEN
            ROLLBACK;
            SET retry_count = retry_count + 1;
            -- 等待一段时间后重试
            SELECT SLEEP(retry_count * 2);
            
        WHEN connection_error THEN
            ROLLBACK;
            -- 重新建立连接
            -- 重试逻辑...
    END;
END WHILE;
```

### 4. 性能优化建议

**批量操作优化**：
```sql
-- 使用批量插入而非逐行插入
-- ✅ 推荐：批量插入
INSERT INTO target_table 
SELECT * FROM source_table WHERE batch_date = '2024-01-01';

-- ❌ 避免：逐行插入事务
FOR each_row IN (SELECT * FROM source_table) DO
    BEGIN WORK;
    INSERT INTO target_table VALUES (each_row);
    COMMIT WORK;
END FOR;
```

**分区并行处理**：
```sql
-- 按分区并行处理，减少事务冲突
-- 分区1
INSERT INTO target_table 
SELECT * FROM source_table WHERE date_col >= '2024-01-01' AND date_col < '2024-01-02';

-- 分区2（可以并行执行）
INSERT INTO target_table 
SELECT * FROM source_table WHERE date_col >= '2024-01-02' AND date_col < '2024-01-03';
```

## 常见问题和解决方案

### Q1: 为什么在事务内读不到刚插入的数据？

**A**: StarRocks采用有限的READ COMMITTED隔离级别，事务内的数据变更对同一事务内的后续查询不可见。

**解决方案**：
```sql
-- 方案1：将查询逻辑移到事务外
BEGIN WORK;
INSERT INTO temp_table SELECT * FROM source_table;
COMMIT WORK;

-- 事务外查询
SELECT * FROM temp_table;

-- 方案2：使用应用层缓存记录插入的数据
```

### Q2: 如何确保跨会话的数据一致性？

**A**: 使用SYNC语句确保所有BE节点数据同步完成。

```sql
-- 数据写入后
INSERT INTO user_stats SELECT * FROM user_raw_data;

-- 跨会话读取前同步
SYNC;
SELECT * FROM user_stats WHERE date = CURDATE();
```

### Q3: 事务超时如何处理？

**A**: 调整超时参数或拆分大事务为小事务。

```sql
-- 调整全局超时配置
ADMIN SET FRONTEND CONFIG ("prepared_transaction_default_timeout_second" = "7200");

-- 或者拆分大事务
-- 原来的大事务
BEGIN WORK;
INSERT INTO table1 SELECT * FROM huge_table; -- 可能超时
COMMIT WORK;

-- 拆分为小事务
DECLARE batch_size INT DEFAULT 100000;
DECLARE offset_val INT DEFAULT 0;

WHILE offset_val < (SELECT COUNT(*) FROM huge_table) DO
    BEGIN WORK;
    INSERT INTO table1 
    SELECT * FROM huge_table 
    LIMIT batch_size OFFSET offset_val;
    COMMIT WORK;
    
    SET offset_val = offset_val + batch_size;
END WHILE;
```

### Q4: 如何监控事务状态？

**A**: 使用系统表和管理命令监控事务状态。

```sql
-- 查看当前运行的事务
SHOW PROC '/transaction';

-- 查看事务历史
SELECT * FROM information_schema.task_runs 
WHERE task_type = 'TRANSACTION' 
ORDER BY create_time DESC 
LIMIT 10;

-- 检查事务限制告警
SELECT COUNT(*) as running_txns, 
       'Approaching limit' as status
FROM information_schema.transactions 
WHERE state = 'RUNNING'
HAVING COUNT(*) > 800; -- 接近900的限制
```

## 小结

StarRocks的事务模型针对OLAP场景进行了优化，与传统OLTP数据库存在显著差异：

### 核心要点

1. **事务类型**：支持SQL事务（v3.5+）和Stream Load事务（v2.4+）
2. **隔离级别**：仅支持有限的READ COMMITTED，事务内变更不可见
3. **一致性**：会话内立即一致，跨会话需要SYNC语句保证
4. **限制约束**：单数据库事务数量限制、不支持嵌套事务、同表多次操作限制

### 开发指导

- ✅ 使用短事务，快速提交
- ✅ 跨会话读取前使用SYNC同步
- ✅ 应用层实现业务一致性控制
- ✅ 合理配置事务超时参数
- ❌ 避免依赖事务内数据可见性
- ❌ 避免长时间持有事务
- ❌ 避免在单事务内对同一表多次操作

理解这些特性和限制，能够帮助开发者在迁移到StarRocks时避免常见陷阱，构建稳定可靠的数据处理系统。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](data-types-mapping.md) | [➡️ 下一页](../04-kettle-integration/kettle-setup.md)
---