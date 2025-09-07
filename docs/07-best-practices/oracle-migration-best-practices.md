---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](production-deployment.md) | [➡️ 下一页](mysql-migration-best-practices.md)
---

# Oracle 迁移最佳实践

Oracle 到 StarRocks 的数据迁移是一个复杂的系统工程，涉及架构评估、数据迁移、应用适配和性能优化等多个环节。本章节总结了完整的迁移最佳实践和经验教训。

## 1. 迁移评估和规划

### 1.1 现状评估

**数据库规模评估**
```sql
-- Oracle 数据库容量评估
SELECT 
    owner,
    segment_type,
    COUNT(*) as object_count,
    ROUND(SUM(bytes)/1024/1024/1024, 2) as size_gb
FROM dba_segments 
WHERE owner NOT IN ('SYS','SYSTEM','SYSAUX','DBSNMP','OUTLN')
GROUP BY owner, segment_type
ORDER BY size_gb DESC;

-- 表空间使用情况
SELECT 
    tablespace_name,
    ROUND(total_mb/1024, 2) as total_gb,
    ROUND(used_mb/1024, 2) as used_gb,
    ROUND(free_mb/1024, 2) as free_gb,
    ROUND(used_mb*100/total_mb, 2) as usage_percent
FROM (
    SELECT 
        ts.tablespace_name,
        ts.total_mb,
        NVL(fs.free_mb, 0) as free_mb,
        ts.total_mb - NVL(fs.free_mb, 0) as used_mb
    FROM (
        SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024, 2) as total_mb
        FROM dba_data_files GROUP BY tablespace_name
    ) ts LEFT JOIN (
        SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024, 2) as free_mb
        FROM dba_free_space GROUP BY tablespace_name
    ) fs ON ts.tablespace_name = fs.tablespace_name
)
ORDER BY used_gb DESC;
```

**数据量分布分析**
```sql
-- 大表识别（超过1GB的表）
SELECT 
    owner,
    table_name,
    num_rows,
    ROUND(avg_row_len * num_rows / 1024 / 1024 / 1024, 2) as estimated_size_gb,
    last_analyzed
FROM dba_tables 
WHERE owner NOT IN ('SYS','SYSTEM','SYSAUX')
  AND num_rows > 0
  AND avg_row_len * num_rows > 1024*1024*1024  -- 大于1GB
ORDER BY estimated_size_gb DESC;

-- 数据增长趋势分析
SELECT 
    TO_CHAR(timestamp, 'YYYY-MM') as month,
    COUNT(*) as table_count,
    AVG(num_rows) as avg_rows_per_table
FROM dba_tab_modifications
WHERE timestamp >= ADD_MONTHS(SYSDATE, -12)
GROUP BY TO_CHAR(timestamp, 'YYYY-MM')
ORDER BY month;
```

**查询模式分析**
```sql
-- 高频SQL识别
SELECT 
    sql_text,
    executions,
    elapsed_time / 1000000 as total_elapsed_seconds,
    (elapsed_time / executions) / 1000000 as avg_elapsed_seconds,
    cpu_time / 1000000 as total_cpu_seconds,
    disk_reads,
    buffer_gets
FROM v$sql
WHERE executions > 100  -- 执行次数超过100次
  AND elapsed_time > 0
ORDER BY total_elapsed_seconds DESC;

-- JOIN 模式分析
SELECT 
    REGEXP_SUBSTR(UPPER(sql_text), 'FROM\s+(\w+)', 1, 1, NULL, 1) as main_table,
    REGEXP_SUBSTR(UPPER(sql_text), 'JOIN\s+(\w+)', 1, 1, NULL, 1) as join_table,
    COUNT(*) as frequency
FROM v$sql
WHERE UPPER(sql_text) LIKE '%JOIN%'
  AND executions > 10
GROUP BY 
    REGEXP_SUBSTR(UPPER(sql_text), 'FROM\s+(\w+)', 1, 1, NULL, 1),
    REGEXP_SUBSTR(UPPER(sql_text), 'JOIN\s+(\w+)', 1, 1, NULL, 1)
ORDER BY frequency DESC;
```

### 1.2 业务依赖分析

**应用系统清单**
```sql
-- 连接会话分析
SELECT 
    machine,
    program,
    username,
    COUNT(*) as session_count,
    COUNT(DISTINCT sid) as unique_sessions
FROM v$session
WHERE type = 'USER'
  AND username NOT IN ('SYS','SYSTEM','DBSNMP')
GROUP BY machine, program, username
ORDER BY session_count DESC;

-- 数据库对象依赖关系
SELECT 
    owner,
    name,
    type,
    referenced_owner,
    referenced_name,
    referenced_type,
    dependency_type
FROM dba_dependencies
WHERE owner NOT IN ('SYS','SYSTEM','PUBLIC')
  AND referenced_owner NOT IN ('SYS','SYSTEM','PUBLIC')
ORDER BY owner, name;
```

**Oracle 特性使用情况**
```sql
-- 存储过程和函数统计
SELECT 
    owner,
    object_type,
    COUNT(*) as object_count,
    COUNT(CASE WHEN status = 'INVALID' THEN 1 END) as invalid_count
FROM dba_objects
WHERE object_type IN ('PROCEDURE', 'FUNCTION', 'PACKAGE', 'TRIGGER')
  AND owner NOT IN ('SYS','SYSTEM','SYSAUX')
GROUP BY owner, object_type
ORDER BY owner, object_count DESC;

-- 高级特性使用检查
SELECT 'PARTITIONED_TABLES' as feature, COUNT(*) as usage_count
FROM dba_part_tables
WHERE owner NOT IN ('SYS','SYSTEM')
UNION ALL
SELECT 'MATERIALIZED_VIEWS', COUNT(*)
FROM dba_mviews
WHERE owner NOT IN ('SYS','SYSTEM')
UNION ALL
SELECT 'SEQUENCES', COUNT(*)
FROM dba_sequences
WHERE sequence_owner NOT IN ('SYS','SYSTEM')
UNION ALL
SELECT 'SYNONYMS', COUNT(*)
FROM dba_synonyms
WHERE owner NOT IN ('SYS','SYSTEM','PUBLIC');
```

### 1.3 迁移可行性评估

**兼容性检查矩阵**

| Oracle 特性 | StarRocks 支持度 | 迁移复杂度 | 替代方案 |
|------------|-----------------|-----------|----------|
| 基础数据类型 | 95% | 低 | 数据类型映射 |
| 分区表 | 80% | 中 | Range/List分区 |
| 索引 | 70% | 中 | Bitmap/Bloom Filter |
| 存储过程 | 0% | 高 | 应用层实现 |
| 触发器 | 0% | 高 | 应用层实现 |
| 序列 | 0% | 低 | UUID/雪花算法 |
| 物化视图 | 90% | 中 | 物化视图重建 |
| 外键约束 | 0% | 中 | 应用层校验 |

**风险评估**
- **高风险**：大量存储过程、复杂触发器、外键约束密集
- **中等风险**：复杂分区策略、大量物化视图、特殊数据类型
- **低风险**：简单查询为主、基础数据类型、少量复杂逻辑

## 2. 迁移策略设计

### 2.1 迁移模式选择

**大爆炸迁移（Big Bang）**
```
优点：
- 迁移周期短
- 数据一致性好
- 运维复杂度低

缺点：
- 业务中断时间长
- 风险集中度高
- 回滚困难

适用场景：
- 中小规模数据库（< 1TB）
- 业务允许长时间中断
- 迁移时间窗口充足
```

**并行运行迁移（Parallel Running）**
```
优点：
- 业务中断时间短
- 风险可控
- 可以逐步验证

缺点：
- 迁移周期长
- 数据同步复杂
- 运维成本高

适用场景：
- 大规模数据库（> 1TB）
- 核心业务系统
- 7x24业务要求
```

**分阶段迁移（Phased Migration）**
```
优点：
- 风险分散
- 可以积累经验
- 逐步优化

缺点：
- 总周期较长
- 系统复杂度高
- 需要详细规划

适用场景：
- 复杂业务系统
- 多个应用系统
- 有充足时间窗口
```

### 2.2 技术架构设计

**迁移架构图**
```
Oracle 数据库
    ↓ 
数据抽取层 (Kettle/DataX/Flink CDC)
    ↓
数据传输层 (Kafka/File/Network)
    ↓
数据加载层 (Stream Load/Routine Load)
    ↓
StarRocks 数据库
    ↓
数据验证层 (自动化校验脚本)
```

**并行运行架构**
```sql
-- 双写架构设计
CREATE TABLE orders_shadow (
    -- 与Oracle表结构对应的StarRocks表
    order_id BIGINT,
    customer_id BIGINT,
    order_date DATE,
    amount DECIMAL(10,2),
    status VARCHAR(20)
) ENGINE=OLAP
DUPLICATE KEY(order_id)
PARTITION BY RANGE(order_date) (
    -- 动态分区配置
)
DISTRIBUTED BY HASH(customer_id) BUCKETS 32;

-- 数据对比验证表
CREATE TABLE migration_validation (
    table_name VARCHAR(64),
    check_date DATE,
    oracle_count BIGINT,
    starrocks_count BIGINT,
    count_diff BIGINT,
    oracle_sum DECIMAL(20,2),
    starrocks_sum DECIMAL(20,2),
    sum_diff DECIMAL(20,2),
    validation_status VARCHAR(20),
    check_time DATETIME
) ENGINE=OLAP
DUPLICATE KEY(table_name, check_date)
DISTRIBUTED BY HASH(table_name) BUCKETS 8;
```

## 3. 数据迁移实施

### 3.1 全量数据迁移

**分批迁移策略**
```bash
#!/bin/bash
# full_migration.sh - 全量数据迁移脚本

ORACLE_HOST="oracle.company.com"
ORACLE_USER="migration_user" 
ORACLE_PASSWORD="migration_password"
STARROCKS_HOST="starrocks.company.com"

# 大表列表（需要分批处理）
LARGE_TABLES=("orders" "order_details" "customer_transactions" "product_reviews")

# 小表列表（可以一次性迁移）
SMALL_TABLES=("customers" "products" "categories" "regions")

migrate_large_table() {
    local table_name=$1
    local batch_size=100000
    
    echo "开始迁移大表: $table_name"
    
    # 获取数据范围
    local min_id=$(sqlplus -s $ORACLE_USER/$ORACLE_PASSWORD@$ORACLE_HOST <<EOF
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT MIN(id) FROM $table_name;
EXIT;
EOF
    )
    
    local max_id=$(sqlplus -s $ORACLE_USER/$ORACLE_PASSWORD@$ORACLE_HOST <<EOF
SET PAGESIZE 0  
SET FEEDBACK OFF
SELECT MAX(id) FROM $table_name;
EXIT;
EOF
    )
    
    echo "表 $table_name 数据范围: $min_id - $max_id"
    
    # 分批迁移
    local current_id=$min_id
    while [ $current_id -le $max_id ]; do
        local end_id=$((current_id + batch_size - 1))
        if [ $end_id -gt $max_id ]; then
            end_id=$max_id
        fi
        
        echo "迁移 $table_name 批次: $current_id - $end_id"
        
        # 执行Kettle作业
        kitchen.sh -file="/path/to/migration_${table_name}.kjb" \
                   -param:START_ID=$current_id \
                   -param:END_ID=$end_id \
                   -level=Basic
        
        if [ $? -eq 0 ]; then
            echo "批次 $current_id - $end_id 迁移成功"
        else
            echo "批次 $current_id - $end_id 迁移失败"
            exit 1
        fi
        
        current_id=$((end_id + 1))
        sleep 10  # 避免过度负载
    done
    
    echo "大表 $table_name 迁移完成"
}

# 迁移小表
for table in "${SMALL_TABLES[@]}"; do
    echo "迁移小表: $table"
    kitchen.sh -file="/path/to/migration_${table}.kjb" -level=Basic
done

# 迁移大表
for table in "${LARGE_TABLES[@]}"; do
    migrate_large_table $table
done

echo "全量数据迁移完成"
```

**数据一致性验证**
```bash
#!/bin/bash
# data_validation.sh - 数据一致性验证

validate_table() {
    local table_name=$1
    
    echo "验证表: $table_name"
    
    # Oracle记录数
    oracle_count=$(sqlplus -s $ORACLE_USER/$ORACLE_PASSWORD@$ORACLE_HOST <<EOF
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT COUNT(*) FROM $table_name;
EXIT;
EOF
    )
    
    # StarRocks记录数
    starrocks_count=$(mysql -h $STARROCKS_HOST -P 9030 -u root -se \
        "SELECT COUNT(*) FROM $table_name")
    
    # 金额字段求和对比
    oracle_sum=$(sqlplus -s $ORACLE_USER/$ORACLE_PASSWORD@$ORACLE_HOST <<EOF
SET PAGESIZE 0
SET FEEDBACK OFF  
SELECT NVL(SUM(amount), 0) FROM $table_name WHERE amount IS NOT NULL;
EXIT;
EOF
    )
    
    starrocks_sum=$(mysql -h $STARROCKS_HOST -P 9030 -u root -se \
        "SELECT IFNULL(SUM(amount), 0) FROM $table_name WHERE amount IS NOT NULL")
    
    # 结果对比
    count_diff=$((oracle_count - starrocks_count))
    sum_diff=$(echo "$oracle_sum - $starrocks_sum" | bc)
    
    if [ $count_diff -eq 0 ] && [ "$sum_diff" == "0" ]; then
        echo "✓ $table_name 验证通过 - 记录数: $oracle_count, 金额: $oracle_sum"
        validation_status="PASS"
    else
        echo "✗ $table_name 验证失败 - 记录差异: $count_diff, 金额差异: $sum_diff"
        validation_status="FAIL"
    fi
    
    # 记录验证结果
    mysql -h $STARROCKS_HOST -P 9030 -u root -e "
        INSERT INTO migration_validation 
        VALUES (
            '$table_name', 
            CURRENT_DATE,
            $oracle_count,
            $starrocks_count, 
            $count_diff,
            $oracle_sum,
            $starrocks_sum,
            $sum_diff,
            '$validation_status',
            NOW()
        )"
}

# 验证所有迁移的表
TABLES=("orders" "customers" "products" "order_details")
for table in "${TABLES[@]}"; do
    validate_table $table
done
```

### 3.2 增量数据同步

**基于时间戳的增量同步**
```sql
-- 创建增量同步控制表
CREATE TABLE sync_control (
    table_name VARCHAR(64) PRIMARY KEY,
    last_sync_time DATETIME,
    sync_status VARCHAR(20),
    processed_rows BIGINT,
    error_count INT,
    last_update_time DATETIME
) ENGINE=OLAP
DUPLICATE KEY(table_name)
DISTRIBUTED BY HASH(table_name) BUCKETS 4;

-- Kettle增量同步作业
-- 1. 获取上次同步时间
-- 2. 查询增量数据
-- 3. 执行数据转换
-- 4. 写入StarRocks
-- 5. 更新同步状态
```

**基于 Oracle LogMiner 的 CDC**
```sql
-- 启用归档日志模式（需要DBA权限）
ALTER DATABASE ARCHIVELOG;

-- 启用补充日志
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- 配置LogMiner
EXEC DBMS_LOGMNR.ADD_LOGFILE('/path/to/archive/log');
EXEC DBMS_LOGMNR.START_LOGMNR();

-- 查询变更数据
SELECT 
    SCN,
    TIMESTAMP,
    USERNAME,
    OPERATION,
    TABLE_NAME,
    SQL_REDO,
    SQL_UNDO
FROM V$LOGMNR_CONTENTS
WHERE TABLE_NAME IN ('ORDERS', 'CUSTOMERS')
  AND OPERATION IN ('INSERT', 'UPDATE', 'DELETE')
  AND TIMESTAMP > (SELECT last_sync_time FROM sync_control WHERE table_name = 'CDC_SYNC');
```

## 4. 事务模型差异与应用适配

### ⚠️ 重要架构原则

**在迁移Oracle到StarRocks时，关键是要转变架构思维：**

- **Oracle**：OLTP数据库，事务是核心功能，业务逻辑依赖完整的ACID特性
- **StarRocks**：OLAP数据库，查询分析是核心，事务是辅助功能

#### 📋 迁移策略建议

| Oracle使用场景 | 是否适合迁移到StarRocks | 推荐方案 |
|-------------|---------------------|---------|
| **OLTP核心业务** | ❌ 不建议 | 保留Oracle，StarRocks作为分析库 |
| **数据仓库ETL** | ✅ 建议 | 完全迁移，使用ETL保证一致性 |
| **报表查询** | ✅ 强烈建议 | 迁移到StarRocks，性能大幅提升 |
| **复杂存储过程** | ❌ 不建议 | 重构为应用层逻辑 |
| **批量数据处理** | ✅ 建议 | 迁移并优化为分区批处理 |

#### 🏗️ 推荐的迁移架构

```
传统Oracle架构：
[应用] -> [Oracle] -> [复杂事务+业务逻辑+查询分析]

推荐的分离架构：
[应用] -> [MySQL/Oracle(OLTP)] -> [CDC/ETL] -> [StarRocks(OLAP)] -> [BI/报表]
           ↓                                    ↓
    [事务业务逻辑]                         [查询分析]
```

### 4.1 Oracle vs StarRocks 事务对比

Oracle和StarRocks在事务模型上存在根本性差异。**但重要的是理解：这种差异反映了两者不同的设计目标。**

#### 4.1.1 事务支持对比

| 特性 | Oracle | StarRocks | 迁移影响 |
|------|--------|-----------|----------|
| **事务类型** | 完整ACID事务 | SQL事务(v3.5+)<br>Stream Load事务(v2.4+) | 高 - 需要重构事务逻辑 |
| **隔离级别** | RC/RR/SI多种级别 | 有限READ COMMITTED | 高 - 隔离行为差异 |
| **事务内可见性** | ✅ 支持 | ❌ 不支持 | 高 - 影响业务逻辑 |
| **跨会话一致性** | ✅ 立即一致 | ❌ 需要SYNC语句 | 中 - 需要代码调整 |
| **嵌套事务** | ✅ 支持SAVEPOINT | ❌ 不支持 | 中 - 需要重构逻辑 |
| **分布式事务** | ✅ 2PC/XA | ✅ 2PC（Stream Load） | 低 - 部分支持 |
| **死锁检测** | ✅ 自动检测 | ❌ 无写冲突检测 | 低 - 应用层处理 |

#### 4.1.2 关键差异详解

**1. 事务内数据可见性差异**

```sql
-- Oracle 行为（事务内变更立即可见）
BEGIN
    INSERT INTO orders VALUES (1001, 'PENDING', 100.00);
    
    -- ✅ Oracle中可以立即查询到刚插入的数据
    SELECT * FROM orders WHERE order_id = 1001;  -- 返回结果
    
    UPDATE orders SET status = 'CONFIRMED' WHERE order_id = 1001;
    
    -- ✅ 可以查询到更新后的数据
    SELECT status FROM orders WHERE order_id = 1001;  -- 返回 'CONFIRMED'
COMMIT;

-- StarRocks 行为（事务内变更不可见）
BEGIN WORK;
    INSERT INTO orders VALUES (1001, 'PENDING', 100.00);
    
    -- ❌ StarRocks中读不到刚插入的数据
    SELECT * FROM orders WHERE order_id = 1001;  -- 空结果集
    
    UPDATE orders SET status = 'CONFIRMED' WHERE order_id = 1001;
    
    -- ❌ 仍然读不到更新的数据
    SELECT status FROM orders WHERE order_id = 1001;  -- 空结果集
COMMIT WORK;

-- ✅ 事务提交后才可见
SYNC;  -- 确保跨会话一致性
SELECT * FROM orders WHERE order_id = 1001;  -- 返回 'CONFIRMED'
```

**2. 跨会话数据一致性差异**

```sql
-- Oracle 行为（立即一致性）
-- Session A
INSERT INTO customer_balance VALUES (1001, 1000.00);
COMMIT;

-- Session B（立即可见）
SELECT balance FROM customer_balance WHERE customer_id = 1001;  -- 返回 1000.00

-- StarRocks 行为（最终一致性）  
-- Session A
INSERT INTO customer_balance VALUES (1001, 1000.00);

-- Session B（可能暂时不可见）
SELECT balance FROM customer_balance WHERE customer_id = 1001;  -- 可能返回空

-- Session B（强制同步后可见）
SYNC;  -- 等待所有节点同步
SELECT balance FROM customer_balance WHERE customer_id = 1001;  -- 返回 1000.00
```

**3. 并发控制差异**

```sql
-- Oracle 行为（悲观锁 + 死锁检测）
-- Session A
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE account_id = 1;

-- Session B（会等待或死锁）
UPDATE accounts SET balance = balance + 50 WHERE account_id = 1;  -- 阻塞

-- StarRocks 行为（无冲突检测）
-- Session A
BEGIN WORK;
UPDATE accounts SET balance = balance - 100 WHERE account_id = 1;

-- Session B（不会阻塞，但可能导致数据不一致）
BEGIN WORK;
UPDATE accounts SET balance = balance + 50 WHERE account_id = 1;  -- 立即执行
COMMIT WORK;

-- 需要应用层实现冲突检测
```

#### 4.1.3 业务逻辑改造指南

**存储过程事务逻辑迁移**

```sql
-- Oracle 存储过程示例
CREATE OR REPLACE PROCEDURE process_order(p_order_id NUMBER) IS
    v_customer_id NUMBER;
    v_current_balance NUMBER;
    v_order_amount NUMBER;
BEGIN
    -- Oracle支持事务内立即读取
    SELECT customer_id, amount INTO v_customer_id, v_order_amount
    FROM orders WHERE order_id = p_order_id;
    
    SELECT balance INTO v_current_balance  
    FROM customer_accounts WHERE customer_id = v_customer_id FOR UPDATE;
    
    IF v_current_balance >= v_order_amount THEN
        -- 扣减余额
        UPDATE customer_accounts 
        SET balance = balance - v_order_amount
        WHERE customer_id = v_customer_id;
        
        -- 更新订单状态
        UPDATE orders 
        SET status = 'CONFIRMED', process_time = SYSDATE
        WHERE order_id = p_order_id;
        
        -- 事务内可以立即查询验证
        SELECT status INTO v_status FROM orders WHERE order_id = p_order_id;
        DBMS_OUTPUT.PUT_LINE('Order status: ' || v_status);
        
        COMMIT;
    ELSE
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20001, 'Insufficient balance');
    END IF;
END;
```

```java
// StarRocks 应用层事务处理
@Service
@Transactional
public class OrderProcessingService {
    
    @Autowired private OrderDAO orderDAO;
    @Autowired private AccountDAO accountDAO;
    
    public void processOrder(Long orderId) throws InsufficientBalanceException {
        
        // 1. 预先获取必要数据（事务外）
        Order order = orderDAO.findById(orderId);
        Account account = accountDAO.findByCustomerId(order.getCustomerId());
        
        if (account.getBalance().compareTo(order.getAmount()) < 0) {
            throw new InsufficientBalanceException("余额不足");
        }
        
        // 2. 执行事务操作
        try {
            // StarRocks单表事务
            accountDAO.updateBalance(order.getCustomerId(), 
                account.getBalance().subtract(order.getAmount()));
            
            orderDAO.updateStatus(orderId, OrderStatus.CONFIRMED);
            
            // 3. 事务提交后验证（需要SYNC）
            syncAndVerify(orderId);
            
        } catch (Exception e) {
            // StarRocks会自动回滚
            log.error("订单处理失败: {}", orderId, e);
            throw new OrderProcessingException("订单处理失败", e);
        }
    }
    
    private void syncAndVerify(Long orderId) {
        // 强制同步确保数据一致性
        jdbcTemplate.execute("SYNC");
        
        // 验证处理结果
        Order updatedOrder = orderDAO.findById(orderId);
        if (!OrderStatus.CONFIRMED.equals(updatedOrder.getStatus())) {
            throw new OrderProcessingException("订单状态更新失败");
        }
    }
}
```

**复杂业务流程重构**

```java
// Oracle式复杂事务（不适用于StarRocks）
@Transactional
public void complexBusinessFlow(BusinessRequest request) {
    // Oracle支持复杂的事务内逻辑
    Long orderId = createOrder(request);  // 创建订单
    
    Order order = queryOrderInTransaction(orderId);  // 事务内查询 - Oracle支持
    
    updateInventory(order.getItems());  // 更新库存
    
    Account account = queryAccountInTransaction(order.getCustomerId());  // 事务内查询
    
    if (account.getBalance() > order.getAmount()) {
        processPayment(order);  // 处理支付
        updateOrderStatus(order, "PAID");  // 更新状态
    }
}

// StarRocks适配的业务流程
@Service
public class StarRocksBusinessFlowService {
    
    public void complexBusinessFlow(BusinessRequest request) {
        
        // 1. 预检查阶段（事务外获取必要信息）
        BusinessContext context = validateAndPrepare(request);
        
        // 2. 分阶段事务执行
        Long orderId = executeOrderCreation(context);
        
        executeInventoryUpdate(context);
        
        executePaymentProcessing(orderId, context);
        
        // 3. 最终一致性验证
        verifyBusinessFlowCompletion(orderId);
    }
    
    @Transactional
    private Long executeOrderCreation(BusinessContext context) {
        // 单一事务：创建订单
        return orderService.createOrder(context.getOrderData());
    }
    
    @Transactional  
    private void executeInventoryUpdate(BusinessContext context) {
        // 单一事务：更新库存
        inventoryService.updateInventory(context.getInventoryUpdates());
    }
    
    @Transactional
    private void executePaymentProcessing(Long orderId, BusinessContext context) {
        // 单一事务：处理支付和更新订单状态
        paymentService.processPayment(context.getPaymentInfo());
        orderService.updateOrderStatus(orderId, OrderStatus.PAID);
    }
    
    private void verifyBusinessFlowCompletion(Long orderId) {
        // 使用SYNC确保数据一致性后验证
        jdbcTemplate.execute("SYNC");
        
        Order finalOrder = orderService.findById(orderId);
        if (!OrderStatus.PAID.equals(finalOrder.getStatus())) {
            // 触发补偿逻辑或告警
            handleBusinessFlowInconsistency(orderId);
        }
    }
}
```

#### 4.1.4 迁移最佳实践

**1. 事务边界重新设计**
```java
// 原则：最小化事务范围，避免事务内查询依赖
@Component
public class TransactionBoundaryOptimizer {
    
    // ❌ 避免：大事务包含复杂逻辑
    @Transactional
    public void badTransactionPattern(Long orderId) {
        Order order = createOrder();
        // 事务内查询 - StarRocks不支持可见性
        Order queriedOrder = queryOrder(orderId);  
        // 复杂的业务逻辑
        processComplexBusinessLogic(order);
        updateMultipleTables();
    }
    
    // ✅ 推荐：小事务 + 分阶段处理
    public void goodTransactionPattern(Long orderId) {
        // 预处理阶段
        BusinessContext context = prepareBusinessContext();
        
        // 最小事务1：创建核心数据
        Long newOrderId = createOrderTransaction(context);
        
        // 数据同步
        syncAndWait();
        
        // 最小事务2：更新关联数据  
        updateRelatedDataTransaction(newOrderId, context);
        
        // 最终验证
        verifyDataConsistency(newOrderId);
    }
}
```

**2. 一致性检查机制**
```java
@Component  
public class ConsistencyChecker {
    
    @Autowired private JdbcTemplate jdbcTemplate;
    
    public void ensureDataConsistency() {
        // 强制数据同步
        jdbcTemplate.execute("SYNC");
    }
    
    public boolean verifyOrderConsistency(Long orderId) {
        ensureDataConsistency();
        
        // 验证订单数据完整性
        return jdbcTemplate.queryForObject(
            "SELECT COUNT(*) FROM orders WHERE order_id = ? AND status IS NOT NULL",
            Integer.class, orderId) > 0;
    }
    
    public void waitForDataConsistency(String tableName, Object expectedData) {
        int maxRetries = 10;
        int retryCount = 0;
        
        while (retryCount < maxRetries) {
            ensureDataConsistency();
            
            if (dataExists(tableName, expectedData)) {
                return;
            }
            
            try {
                Thread.sleep(1000);  // 等待1秒后重试
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
            retryCount++;
        }
        
        throw new DataConsistencyException("数据一致性验证超时");
    }
}
```

## 5. 应用系统适配

### 5.1 SQL 兼容性处理

**常见SQL改写模式**
```sql
-- Oracle ROWNUM 改写
-- Oracle写法
SELECT * FROM (
    SELECT * FROM orders ORDER BY order_date DESC
) WHERE ROWNUM <= 10;

-- StarRocks写法
SELECT * FROM orders 
ORDER BY order_date DESC 
LIMIT 10;

-- Oracle DECODE 改写
-- Oracle写法
SELECT 
    user_id,
    DECODE(status, 'A', 'Active', 'I', 'Inactive', 'Unknown') as status_desc
FROM users;

-- StarRocks写法
SELECT 
    user_id,
    CASE 
        WHEN status = 'A' THEN 'Active'
        WHEN status = 'I' THEN 'Inactive'
        ELSE 'Unknown'
    END as status_desc
FROM users;

-- Oracle (+) 外连接改写
-- Oracle写法
SELECT u.user_name, o.order_count
FROM users u, (SELECT user_id, COUNT(*) as order_count FROM orders GROUP BY user_id) o
WHERE u.user_id = o.user_id(+);

-- StarRocks写法
SELECT u.user_name, COALESCE(o.order_count, 0) as order_count
FROM users u
LEFT JOIN (SELECT user_id, COUNT(*) as order_count FROM orders GROUP BY user_id) o
ON u.user_id = o.user_id;
```

**日期函数映射**
```sql
-- Oracle TO_CHAR 改写
-- Oracle写法
SELECT TO_CHAR(order_date, 'YYYY-MM') as order_month FROM orders;

-- StarRocks写法
SELECT DATE_FORMAT(order_date, '%Y-%m') as order_month FROM orders;

-- Oracle ADD_MONTHS 改写
-- Oracle写法
SELECT ADD_MONTHS(SYSDATE, -1) as last_month FROM dual;

-- StarRocks写法
SELECT DATE_ADD(CURRENT_DATE, INTERVAL -1 MONTH) as last_month;

-- Oracle TRUNC 改写
-- Oracle写法
SELECT TRUNC(order_date, 'MM') as month_start FROM orders;

-- StarRocks写法
SELECT DATE_FORMAT(order_date, '%Y-%m-01') as month_start FROM orders;
```

### 4.2 应用层改造

**数据访问层重构**
```java
// Oracle JDBC 连接池配置
public class OracleDataSource {
    private static final String ORACLE_URL = "jdbc:oracle:thin:@//oracle:1521/XE";
    private static final String DRIVER_CLASS = "oracle.jdbc.OracleDriver";
    
    @Bean
    public DataSource oracleDataSource() {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(ORACLE_URL);
        config.setUsername("app_user");
        config.setPassword("app_password");
        config.setDriverClassName(DRIVER_CLASS);
        config.setMaximumPoolSize(20);
        return new HikariDataSource(config);
    }
}

// StarRocks JDBC 连接池配置
public class StarRocksDataSource {
    private static final String STARROCKS_URL = "jdbc:mysql://starrocks:9030/warehouse";
    private static final String DRIVER_CLASS = "com.mysql.cj.jdbc.Driver";
    
    @Bean
    public DataSource starrocksDataSource() {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(STARROCKS_URL);
        config.setUsername("app_user");
        config.setPassword("app_password");
        config.setDriverClassName(DRIVER_CLASS);
        config.setMaximumPoolSize(50);  // StarRocks可以支持更多连接
        return new HikariDataSource(config);
    }
}
```

**DAO 层适配**
```java
// 通用DAO接口
public interface OrderDAO {
    List<Order> findOrdersByDateRange(Date startDate, Date endDate);
    long countOrdersByStatus(String status);
    BigDecimal sumAmountByMonth(String month);
}

// Oracle实现
@Repository("oracleOrderDAO")
public class OracleOrderDAOImpl implements OrderDAO {
    
    @Override
    public List<Order> findOrdersByDateRange(Date startDate, Date endDate) {
        String sql = """
            SELECT order_id, customer_id, order_date, amount, status
            FROM orders 
            WHERE order_date >= ? AND order_date < ?
            ORDER BY order_date DESC
            """;
        return jdbcTemplate.query(sql, orderRowMapper, startDate, endDate);
    }
    
    @Override
    public BigDecimal sumAmountByMonth(String month) {
        String sql = """
            SELECT NVL(SUM(amount), 0)
            FROM orders 
            WHERE TO_CHAR(order_date, 'YYYY-MM') = ?
            """;
        return jdbcTemplate.queryForObject(sql, BigDecimal.class, month);
    }
}

// StarRocks实现
@Repository("starrocksOrderDAO")
public class StarRocksOrderDAOImpl implements OrderDAO {
    
    @Override
    public List<Order> findOrdersByDateRange(Date startDate, Date endDate) {
        String sql = """
            SELECT order_id, customer_id, order_date, amount, status
            FROM orders 
            WHERE order_date >= ? AND order_date < ?
            ORDER BY order_date DESC
            """;
        return jdbcTemplate.query(sql, orderRowMapper, startDate, endDate);
    }
    
    @Override
    public BigDecimal sumAmountByMonth(String month) {
        String sql = """
            SELECT IFNULL(SUM(amount), 0)
            FROM orders 
            WHERE DATE_FORMAT(order_date, '%Y-%m') = ?
            """;
        return jdbcTemplate.queryForObject(sql, BigDecimal.class, month);
    }
}
```

**配置切换机制**
```java
// 数据源切换配置
@Configuration
@Profile("migration")
public class MigrationConfig {
    
    @Bean
    @Primary
    public DataSource primaryDataSource(
            @Qualifier("oracleDataSource") DataSource oracleDS,
            @Qualifier("starrocksDataSource") DataSource starrocksDS) {
        
        RoutingDataSource routingDS = new RoutingDataSource();
        Map<Object, Object> targetDataSources = new HashMap<>();
        targetDataSources.put("oracle", oracleDS);
        targetDataSources.put("starrocks", starrocksDS);
        
        routingDS.setTargetDataSources(targetDataSources);
        routingDS.setDefaultTargetDataSource(starrocksDS);  // 默认使用StarRocks
        
        return routingDS;
    }
}

// 动态数据源切换
@Component
public class DataSourceSwitch {
    
    private static final ThreadLocal<String> contextHolder = new ThreadLocal<>();
    
    public static void useOracle() {
        contextHolder.set("oracle");
    }
    
    public static void useStarRocks() {
        contextHolder.set("starrocks");
    }
    
    public static String getCurrentDataSource() {
        return contextHolder.get();
    }
    
    public static void clear() {
        contextHolder.remove();
    }
}
```

## 5. 性能对比测试

### 5.1 基准测试设计

**TPC-H 基准测试**
```bash
#!/bin/bash
# tpch_benchmark.sh - TPC-H 性能对比测试

SCALE_FACTOR=10  # 10GB数据集
ORACLE_HOST="oracle"
STARROCKS_HOST="starrocks"

# 生成测试数据
./dbgen -s $SCALE_FACTOR

# Oracle测试
run_oracle_tpch() {
    echo "执行 Oracle TPC-H 测试..."
    
    for i in {1..22}; do
        echo "执行查询 Q$i"
        start_time=$(date +%s.%N)
        
        sqlplus -s app_user/app_password@$ORACLE_HOST @queries/q$i.sql > /dev/null
        
        end_time=$(date +%s.%N)
        duration=$(echo "$end_time - $start_time" | bc)
        
        echo "Oracle Q$i: ${duration}s" >> oracle_results.txt
    done
}

# StarRocks测试
run_starrocks_tpch() {
    echo "执行 StarRocks TPC-H 测试..."
    
    for i in {1..22}; do
        echo "执行查询 Q$i"
        start_time=$(date +%s.%N)
        
        mysql -h $STARROCKS_HOST -P 9030 -u root < queries_starrocks/q$i.sql > /dev/null
        
        end_time=$(date +%s.%N)
        duration=$(echo "$end_time - $start_time" | bc)
        
        echo "StarRocks Q$i: ${duration}s" >> starrocks_results.txt
    done
}

# 执行测试
run_oracle_tpch
run_starrocks_tpch

# 生成对比报告
python generate_benchmark_report.py oracle_results.txt starrocks_results.txt
```

**业务查询性能测试**
```sql
-- 创建性能测试表
CREATE TABLE performance_test_results (
    test_date DATE,
    database_type VARCHAR(20),
    query_name VARCHAR(100),
    execution_time_seconds DOUBLE,
    rows_returned BIGINT,
    rows_examined BIGINT,
    cpu_time_seconds DOUBLE,
    io_wait_seconds DOUBLE
) ENGINE=OLAP
DUPLICATE KEY(test_date, database_type, query_name)
DISTRIBUTED BY HASH(query_name) BUCKETS 8;

-- 业务查询测试用例
-- 1. 简单聚合查询
SELECT 
    DATE_FORMAT(order_date, '%Y-%m') as month,
    COUNT(*) as order_count,
    SUM(amount) as total_amount
FROM orders
WHERE order_date >= '2023-01-01'
GROUP BY DATE_FORMAT(order_date, '%Y-%m');

-- 2. 复杂JOIN查询
SELECT 
    c.customer_name,
    c.customer_level,
    COUNT(o.order_id) as order_count,
    SUM(o.amount) as total_spent,
    AVG(o.amount) as avg_order_value
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE o.order_date >= '2023-01-01'
  AND c.customer_level IN ('GOLD', 'PLATINUM')
GROUP BY c.customer_id, c.customer_name, c.customer_level
ORDER BY total_spent DESC;

-- 3. 窗口函数查询
SELECT 
    customer_id,
    order_date,
    amount,
    SUM(amount) OVER (
        PARTITION BY customer_id 
        ORDER BY order_date 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) as running_total,
    ROW_NUMBER() OVER (
        PARTITION BY customer_id 
        ORDER BY amount DESC
    ) as order_rank
FROM orders
WHERE order_date >= '2023-01-01';
```

### 5.2 性能优化建议

**Oracle 查询优化经验迁移**
```sql
-- Oracle Hint 转换为 StarRocks 优化
-- Oracle写法（使用Hint）
SELECT /*+ USE_INDEX(orders, idx_orders_date) */
    customer_id, SUM(amount)
FROM orders
WHERE order_date >= DATE '2023-01-01'
GROUP BY customer_id;

-- StarRocks写法（表设计优化）
-- 1. 创建合适的排序键
CREATE TABLE orders_optimized (
    order_id BIGINT,
    customer_id BIGINT,
    order_date DATE,
    amount DECIMAL(10,2)
) ENGINE=OLAP
DUPLICATE KEY(order_id)
PARTITION BY RANGE(order_date) (...)
DISTRIBUTED BY HASH(customer_id) BUCKETS 32
ORDER BY (order_date, customer_id);  -- 关键优化

-- 2. 创建 Bitmap 索引
CREATE INDEX idx_customer_bitmap ON orders_optimized (customer_id) USING BITMAP;

-- 3. 查询自动利用排序键和索引
SELECT customer_id, SUM(amount)
FROM orders_optimized
WHERE order_date >= '2023-01-01'  -- 利用分区裁剪和排序键
GROUP BY customer_id;  -- 利用 Bitmap 索引
```

**存储优化建议**
```sql
-- Oracle 存储参数迁移
-- Oracle表空间 -> StarRocks分区策略
-- Oracle索引 -> StarRocks排序键+索引
-- Oracle物化视图 -> StarRocks物化视图

-- 示例：将Oracle按月分区转换为StarRocks动态分区
CREATE TABLE monthly_sales (
    sale_date DATE,
    customer_id BIGINT,
    amount DECIMAL(12,2)
) ENGINE=OLAP
DUPLICATE KEY(sale_date, customer_id)
PARTITION BY RANGE(sale_date) ()  -- 空分区定义，使用动态分区
DISTRIBUTED BY HASH(customer_id) BUCKETS 64
PROPERTIES (
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "MONTH",
    "dynamic_partition.start" = "-24",  -- 保留24个月
    "dynamic_partition.end" = "3",      -- 提前3个月创建
    "dynamic_partition.prefix" = "p"
);
```

## 6. 运维管理最佳实践

### 6.1 监控体系建设

**迁移监控仪表板**
```python
# migration_monitor.py - 迁移监控脚本
import pymysql
import cx_Oracle
import json
import time
from datetime import datetime, timedelta

class MigrationMonitor:
    def __init__(self):
        self.oracle_conn = cx_Oracle.connect("user/password@oracle:1521/xe")
        self.starrocks_conn = pymysql.connect(
            host='starrocks', port=9030, user='root', password='',
            database='warehouse', charset='utf8mb4'
        )
    
    def check_data_lag(self):
        """检查数据同步延迟"""
        # Oracle最新数据时间
        oracle_cursor = self.oracle_conn.cursor()
        oracle_cursor.execute("""
            SELECT MAX(created_time) FROM orders 
            WHERE created_time >= SYSDATE - 1
        """)
        oracle_latest = oracle_cursor.fetchone()[0]
        
        # StarRocks最新数据时间
        sr_cursor = self.starrocks_conn.cursor()
        sr_cursor.execute("""
            SELECT MAX(created_time) FROM orders 
            WHERE created_time >= NOW() - INTERVAL 1 DAY
        """)
        sr_latest = sr_cursor.fetchone()[0]
        
        if oracle_latest and sr_latest:
            lag_seconds = (oracle_latest - sr_latest).total_seconds()
            return {
                'oracle_latest': oracle_latest.isoformat(),
                'starrocks_latest': sr_latest.isoformat(),
                'lag_seconds': lag_seconds,
                'status': 'OK' if lag_seconds < 300 else 'WARNING'  # 5分钟阈值
            }
        return {'status': 'ERROR', 'message': 'Unable to determine lag'}
    
    def check_data_consistency(self, table_name):
        """检查数据一致性"""
        # Oracle记录数和校验和
        oracle_cursor = self.oracle_conn.cursor()
        oracle_cursor.execute(f"""
            SELECT COUNT(*), NVL(SUM(amount), 0) 
            FROM {table_name} 
            WHERE created_date = TRUNC(SYSDATE)
        """)
        oracle_count, oracle_sum = oracle_cursor.fetchone()
        
        # StarRocks记录数和校验和
        sr_cursor = self.starrocks_conn.cursor()
        sr_cursor.execute(f"""
            SELECT COUNT(*), IFNULL(SUM(amount), 0) 
            FROM {table_name} 
            WHERE DATE(created_time) = CURRENT_DATE
        """)
        sr_count, sr_sum = sr_cursor.fetchone()
        
        return {
            'table': table_name,
            'oracle_count': oracle_count,
            'starrocks_count': sr_count,
            'count_diff': oracle_count - sr_count,
            'oracle_sum': float(oracle_sum) if oracle_sum else 0,
            'starrocks_sum': float(sr_sum) if sr_sum else 0,
            'sum_diff': float(oracle_sum - sr_sum) if oracle_sum and sr_sum else 0,
            'consistent': oracle_count == sr_count and abs(float(oracle_sum - sr_sum)) < 0.01
        }
    
    def generate_daily_report(self):
        """生成日报告"""
        report = {
            'date': datetime.now().strftime('%Y-%m-%d'),
            'data_lag': self.check_data_lag(),
            'table_consistency': []
        }
        
        tables = ['orders', 'customers', 'products', 'order_details']
        for table in tables:
            consistency = self.check_data_consistency(table)
            report['table_consistency'].append(consistency)
        
        return report

# 定时执行监控
if __name__ == "__main__":
    monitor = MigrationMonitor()
    report = monitor.generate_daily_report()
    print(json.dumps(report, indent=2, default=str))
```

### 6.2 备份恢复策略

**StarRocks 备份策略**
```bash
#!/bin/bash
# backup_strategy.sh - StarRocks备份策略

BACKUP_DIR="/backup/starrocks"
BACKUP_RETENTION_DAYS=30

# 全量备份
full_backup() {
    local backup_name="full_$(date +%Y%m%d_%H%M%S)"
    
    mysql -h starrocks -P 9030 -u root -e "
        BACKUP SNAPSHOT warehouse.${backup_name}
        TO '${BACKUP_DIR}/${backup_name}'
        PROPERTIES ('type' = 'full')
    "
    
    if [ $? -eq 0 ]; then
        echo "全量备份成功: $backup_name"
        
        # 清理旧备份
        find $BACKUP_DIR -name "full_*" -mtime +$BACKUP_RETENTION_DAYS -exec rm -rf {} \;
    else
        echo "全量备份失败"
        exit 1
    fi
}

# 增量备份
incremental_backup() {
    local backup_name="incr_$(date +%Y%m%d_%H%M%S)"
    local last_backup=$(ls -t $BACKUP_DIR/full_* | head -1)
    
    mysql -h starrocks -P 9030 -u root -e "
        BACKUP SNAPSHOT warehouse.${backup_name}
        TO '${BACKUP_DIR}/${backup_name}'
        PROPERTIES (
            'type' = 'incremental',
            'base_snapshot' = '$(basename $last_backup)'
        )
    "
    
    echo "增量备份完成: $backup_name"
}

# 备份调度
case "$1" in
    "full")
        full_backup
        ;;
    "incremental") 
        incremental_backup
        ;;
    *)
        echo "用法: $0 {full|incremental}"
        exit 1
        ;;
esac
```

### 6.3 故障处理预案

**常见故障处理流程**
```bash
#!/bin/bash
# disaster_recovery.sh - 故障恢复处理

# 数据同步中断恢复
recover_sync_failure() {
    echo "检测到数据同步中断，开始恢复..."
    
    # 1. 停止所有同步任务
    kitchen.sh -file="stop_all_sync.kjb"
    
    # 2. 检查数据一致性
    ./data_validation.sh > sync_failure_report.txt
    
    # 3. 重置同步点
    mysql -h starrocks -P 9030 -u root -e "
        UPDATE sync_control 
        SET last_sync_time = DATE_SUB(NOW(), INTERVAL 1 HOUR),
            sync_status = 'RESET'
        WHERE sync_status = 'FAILED'
    "
    
    # 4. 重启同步任务
    kitchen.sh -file="start_all_sync.kjb"
    
    echo "数据同步恢复完成"
}

# StarRocks集群故障恢复
recover_cluster_failure() {
    echo "检测到StarRocks集群故障，开始恢复..."
    
    # 1. 检查集群状态
    mysql -h starrocks -P 9030 -u root -e "SHOW BACKENDS;"
    
    # 2. 重启BE节点（如果需要）
    for be_host in starrocks-be1 starrocks-be2 starrocks-be3; do
        echo "检查BE节点: $be_host"
        if ! curl -f http://$be_host:8040/api/health; then
            echo "重启BE节点: $be_host"
            ssh $be_host "sudo systemctl restart starrocks-be"
        fi
    done
    
    # 3. 等待集群恢复
    sleep 60
    
    # 4. 验证集群健康状态
    mysql -h starrocks -P 9030 -u root -e "SHOW PROC '/backends';"
    
    echo "集群恢复完成"
}

# 故障检测和处理主流程
case "$1" in
    "sync")
        recover_sync_failure
        ;;
    "cluster")
        recover_cluster_failure
        ;;
    *)
        echo "用法: $0 {sync|cluster}"
        exit 1
        ;;
esac
```

## 7. 总结和经验教训

### 7.1 成功关键因素

**充分的前期准备**
- 详细的现状调研和评估
- 完整的迁移方案设计
- 充分的测试验证
- 完善的风险预案

**分阶段实施策略**
- 先小表后大表
- 先非核心业务后核心业务
- 充分的并行运行验证期
- 逐步切换策略

**技术选型合理**
- 选择合适的迁移工具
- 合理的网络架构设计
- 充分的性能测试验证
- 完善的监控体系

### 7.2 常见陷阱

**数据一致性问题**
- 忽视数据类型精度差异
- 时区和字符集问题
- NULL值处理不当
- 浮点数计算误差

**性能期望管理**
- 过度依赖单个优化手段
- 忽视SQL改写的必要性
- 表设计不合理
- 索引策略不当

**运维复杂度低估**
- 缺乏完善的监控体系
- 故障处理预案不足
- 备份恢复策略缺失
- 人员技能准备不足

### 7.3 最佳实践总结

1. **投资足够时间进行前期调研和规划**
2. **建立完善的测试环境和验证流程**
3. **采用分阶段、低风险的迁移策略**
4. **重视数据质量和一致性验证**
5. **建立完善的监控和故障处理机制**
6. **做好团队技能培训和知识转移**
7. **保持足够的回滚窗口和应急预案**

Oracle 到 StarRocks 的迁移是一个系统性工程，需要在技术、流程、人员等多个维度做好充分准备。通过遵循最佳实践和吸取经验教训，可以大大提高迁移成功率和最终效果。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](production-deployment.md) | [➡️ 下一页](mysql-migration-best-practices.md)
---