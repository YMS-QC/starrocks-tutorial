# StarRocks SQL和ETL开发人员快速教程计划

## 项目背景
- **目标用户**: SQL和ETL开发人员
- **核心场景**: 基于Kettle从Oracle抽取数据到StarRocks
- **重点内容**: 表模型选择、分区分桶优化、SQL调优
- **次要内容**: 大数据生态集成（简要介绍）

## 项目结构
```
starrocks-tutorial/
├── README.md                           # 教程总览和导航
├── TUTORIAL_PLAN.md                   # 教程计划文档（本文件）
├── docs/                               # 文档目录
│   ├── 01-introduction/               # StarRocks简介
│   │   ├── what-is-starrocks.md      # StarRocks定位和特点
│   │   ├── architecture.md           # 架构简介
│   │   └── vs-traditional-dw.md      # 与传统数仓对比
│   ├── 02-quick-start/                # 快速开始
│   │   ├── installation-docker.md    # Docker快速部署
│   │   ├── connect-tools.md          # 连接工具配置
│   │   └── first-etl.md              # 第一个ETL任务
│   ├── 03-table-design/               # 表设计核心（重点）
│   │   ├── table-models.md           # 表模型详解
│   │   ├── partition-strategy.md     # 分区策略设计
│   │   ├── bucket-design.md          # 分桶优化
│   │   └── data-types-mapping.md     # Oracle到StarRocks类型映射
│   ├── 04-kettle-integration/        # Kettle集成
│   │   ├── kettle-setup.md          # Kettle环境配置
│   │   ├── oracle-to-starrocks.md   # Oracle到StarRocks ETL
│   │   ├── stream-load-kettle.md    # Stream Load集成
│   │   ├── batch-strategies.md      # 批量处理策略
│   │   └── error-handling.md        # 错误处理机制
│   ├── 05-sql-optimization/          # SQL优化（重点）
│   │   ├── query-analysis.md        # 查询分析工具
│   │   ├── index-optimization.md    # 索引优化
│   │   ├── join-optimization.md     # Join优化技巧
│   │   ├── aggregate-optimization.md # 聚合优化
│   │   └── runtime-filter.md        # Runtime Filter使用
│   ├── 06-advanced-features/         # 高级特性
│   │   ├── materialized-views.md    # 物化视图加速
│   │   ├── dynamic-partition.md     # 动态分区管理
│   │   ├── colocation-join.md       # Colocation Join
│   │   └── bigdata-integration.md   # 大数据生态简介
│   └── 07-best-practices/            # 最佳实践
│       ├── oracle-migration.md      # Oracle迁移最佳实践
│       ├── kettle-performance.md    # Kettle性能优化
│       ├── monitoring.md            # 监控和运维
│       └── troubleshooting.md       # 常见问题解决
├── examples/                          # 示例代码
│   ├── sql/                         
│   │   ├── table-creation/         # 建表语句示例
│   │   ├── optimization/           # 优化前后对比
│   │   └── migration/              # Oracle SQL迁移示例
│   ├── kettle/                     
│   │   ├── transformations/        # 转换示例
│   │   ├── jobs/                   # 作业示例
│   │   └── templates/              # 模板文件
│   └── scripts/                    
│       ├── stream-load/            # Stream Load脚本
│       └── monitoring/             # 监控脚本
└── labs/                             # 动手实验
    ├── lab01-table-design/          # 表设计实验
    ├── lab02-kettle-etl/           # Kettle ETL实验
    ├── lab03-sql-tuning/           # SQL调优实验
    └── lab04-production-case/      # 生产案例实践
```

## 核心章节内容大纲

### 第1章：StarRocks简介（简化版）
- StarRocks定位：实时分析型数据库
- 核心优势：高性能、实时性、兼容MySQL协议
- FE/BE分离架构简介
- 与传统数仓（Oracle）对比
- 与大数据生态关系（Hive/Spark简要说明）

### 第2章：快速开始
- Docker Compose一键部署
- 客户端工具连接（MySQL Client、DBeaver、DataGrip）
- 创建第一个数据库和表
- 执行基础查询
- 第一个Kettle ETL任务

### 第3章：表设计核心（重点章节）

#### 3.1 表模型详解
##### Duplicate模型
- **适用场景**：明细数据、日志数据、不需要聚合的原始数据
- **特点**：保留全部原始数据，不做任何聚合
- **示例场景**：
  - 交易流水记录
  - 操作日志
  - 原始订单明细

##### Aggregate模型
- **适用场景**：需要预聚合的指标数据
- **聚合函数支持**：
  - SUM：求和
  - MAX/MIN：最大/最小值
  - REPLACE：替换（保留最新值）
  - HLL_UNION：基数统计
  - BITMAP_UNION：精确去重
- **示例场景**：
  - 销售汇总表
  - 用户行为统计
  - 实时指标看板

##### Unique模型
- **适用场景**：需要主键唯一性约束的表
- **更新机制**：
  - Merge on Read (MoR)：读时合并，写入快
  - Copy on Write (CoW)：写时合并，查询快
- **示例场景**：
  - 用户维度表
  - 产品主数据
  - 配置表

##### 模型选择决策流程
```
业务需求分析
├─ 是否需要保留所有明细数据？
│  └─ 是 → Duplicate模型
├─ 是否需要预聚合计算？
│  └─ 是 → Aggregate模型
└─ 是否需要更新数据？
   └─ 是 → Unique模型
```

#### 3.2 分区策略设计
##### Range分区
- 时间分区最佳实践
- 分区粒度选择（日/周/月/年）
- 分区裁剪优化
- 动态分区配置

##### List分区
- 枚举值分区场景
- 多列组合分区

##### 分区设计原则
- 分区列选择（高频过滤条件）
- 分区数量控制（避免过多小分区）
- 历史分区管理策略

#### 3.3 分桶优化
##### 分桶数计算公式
```
理想分桶数 = 数据总量(GB) / 1-2GB
实际分桶数建议：10-100个
```

##### 分桶键选择原则
- 高基数列优先（如用户ID、订单ID）
- 查询条件频繁使用的列
- 避免数据倾斜（均匀分布）
- Join场景的关联键

##### 分桶与查询性能
- 分桶裁剪机制
- 并发度影响
- 数据本地性

#### 3.4 Oracle到StarRocks映射
##### 数据类型映射表
| Oracle类型 | StarRocks类型 | 说明 |
|-----------|--------------|------|
| NUMBER(p,s) | DECIMAL(p,s) | 精确数值 |
| NUMBER | BIGINT/LARGEINT | 整数 |
| VARCHAR2 | VARCHAR | 变长字符串 |
| CHAR | CHAR | 定长字符串 |
| DATE | DATETIME | 日期时间 |
| TIMESTAMP | DATETIME | 时间戳 |
| CLOB | STRING | 大文本 |
| BLOB | - | 不支持，需转换 |

##### Oracle特性迁移
- 序列(Sequence) → 自增列/应用层生成
- 分区表 → Range/List分区
- 索引 → StarRocks自动索引
- 物化视图 → StarRocks物化视图

#### 3.5 MySQL到StarRocks映射
##### 数据类型映射表
| MySQL类型 | StarRocks类型 | 说明 |
|-----------|--------------|------|
| TINYINT | TINYINT | 1字节整数 |
| SMALLINT | SMALLINT | 2字节整数 |
| MEDIUMINT | INT | 3字节转4字节 |
| INT | INT | 4字节整数 |
| BIGINT | BIGINT | 8字节整数 |
| DECIMAL(M,D) | DECIMAL(M,D) | 精确小数 |
| FLOAT | FLOAT | 单精度浮点 |
| DOUBLE | DOUBLE | 双精度浮点 |
| VARCHAR(n) | VARCHAR(n) | 变长字符串 |
| CHAR(n) | CHAR(n) | 定长字符串 |
| TEXT/MEDIUMTEXT/LONGTEXT | STRING | 大文本统一为STRING |
| DATE | DATE | 日期 |
| DATETIME | DATETIME | 日期时间 |
| TIMESTAMP | DATETIME | 时间戳转日期时间 |
| TIME | STRING | 时间转字符串 |
| YEAR | SMALLINT | 年份转小整数 |
| JSON | JSON/STRING | JSON类型 |
| BINARY/VARBINARY | STRING | 二进制转字符串 |
| BLOB | STRING | 二进制大对象转字符串 |
| ENUM | VARCHAR | 枚举转字符串 |
| SET | VARCHAR | 集合转字符串 |

##### MySQL特性迁移
- **AUTO_INCREMENT** → StarRocks AUTO_INCREMENT
- **主键约束** → Unique模型的主键
- **唯一索引** → Unique模型或Duplicate模型+应用层去重
- **外键约束** → 应用层维护（StarRocks不支持外键）
- **触发器** → 应用层实现或Stream Load前处理
- **存储过程/函数** → 改写为StarRocks SQL或应用层逻辑
- **视图** → StarRocks视图
- **分区表** → Range/List分区（需重新设计）
- **全文索引** → 暂不支持，使用LIKE或外部搜索引擎

##### MySQL到StarRocks注意事项
###### 字符集处理
- MySQL默认utf8mb4 → StarRocks默认UTF-8
- 特殊字符和emoji支持需要测试验证
- 排序规则(Collation)差异需要注意

###### NULL值处理
- StarRocks的NULL处理与MySQL基本一致
- 聚合函数对NULL的处理相同
- 注意Unique模型中NULL值的特殊处理

###### 事务差异
- MySQL支持完整ACID事务
- StarRocks主要支持单表事务，不支持跨表事务
- 批量导入具有原子性（全部成功或全部失败）

###### 性能优化差异
- MySQL依赖索引优化
- StarRocks依赖分区分桶和列式存储
- 查询优化器行为不同，需要重新调优

###### SQL语法差异
- 部分MySQL特有函数需要改写
- GROUP BY行为差异（MySQL 5.7后的ONLY_FULL_GROUP_BY）
- 窗口函数语法基本兼容
- 存储过程需要改写为普通SQL

### 第4章：Kettle集成（实战章节）

#### 4.1 环境配置
- StarRocks JDBC驱动配置
- 数据库连接配置
- 连接池参数优化

#### 4.2 ETL模式设计
##### 全量同步
```
Oracle(源) → Kettle(转换) → Stream Load → StarRocks(目标)
```
- Truncate + Load模式
- 分区替换模式

##### 增量同步
- 基于时间戳增量
- 基于自增ID增量
- 基于CDC日志

##### 实时同步
- Kettle + Kafka + Routine Load
- 准实时批处理

#### 4.3 Stream Load集成
- REST API调用方式
- Kettle插件开发
- 批量大小优化
- 错误处理和重试

#### 4.4 性能优化
- 并行度设置
- 内存配置
- 批次大小调优
- 网络传输优化

### 第5章：SQL优化（重点章节）

#### 5.1 查询分析工具
##### EXPLAIN使用
```sql
-- 查看执行计划
EXPLAIN SELECT ...

-- 查看详细执行统计
EXPLAIN ANALYZE SELECT ...

-- 查看代价估算
EXPLAIN COSTS SELECT ...
```

##### Profile分析
- 开启Profile
- 分析瓶颈阶段
- 优化建议

#### 5.2 索引优化
##### Bitmap索引
- 适用场景：低基数列
- 创建和使用
- 性能影响

##### Bloom Filter索引
- 适用场景：高基数列等值查询
- 配置参数
- 效果评估

##### 前缀索引
- 自动创建机制
- 最左前缀原则

#### 5.3 Join优化
##### Join类型选择
- Broadcast Join（小表广播）
- Shuffle Join（大表shuffle）
- Colocation Join（本地join）

##### Join顺序优化
- 小表驱动大表
- 过滤条件下推
- Join Reorder

##### Join性能调优
```sql
-- 强制Broadcast Join
SELECT /*+ BROADCAST(t1) */ ...

-- 强制Shuffle Join
SELECT /*+ SHUFFLE */ ...
```

#### 5.4 聚合优化
##### 物化视图加速
- 同步物化视图创建
- 自动查询改写
- 刷新策略

##### Rollup使用
- Rollup表创建
- 自动路由机制

##### 分组优化
- Grouping Sets使用
- Cube和Rollup语法

#### 5.5 常见优化案例
##### Count Distinct优化
```sql
-- 优化前
SELECT COUNT(DISTINCT user_id) FROM orders

-- 优化后（使用Bitmap）
SELECT BITMAP_UNION_COUNT(to_bitmap(user_id)) FROM orders
```

##### 大表Join优化
- 分区裁剪
- Runtime Filter
- 物化视图预Join

##### 窗口函数优化
- 分区键选择
- 排序优化

### 第6章：高级特性

#### 6.1 物化视图
- 同步物化视图 vs 异步物化视图
- 创建和管理
- 查询改写机制
- 最佳实践

#### 6.2 动态分区
- 自动分区创建
- 分区生命周期管理
- 配置参数详解

#### 6.3 Colocation Join
- Colocation Group创建
- 数据分布要求
- 性能提升效果

#### 6.4 大数据生态集成（简介）
- External Table for Hive
- Spark Connector
- Flink Connector
- Apache Iceberg支持

### 第7章：最佳实践

#### 7.1 Oracle迁移最佳实践
- 评估和规划
- 数据迁移工具选择
- 性能对比测试
- 兼容性问题处理

#### 7.2 MySQL迁移最佳实践
##### 迁移前评估
- **数据量评估**：统计表大小、记录数、增长速度
- **查询模式分析**：识别高频查询、复杂Join、聚合需求
- **性能基准测试**：记录当前MySQL性能指标作为对比基准
- **依赖关系梳理**：外键、触发器、存储过程的使用情况

##### 迁移工具选择
###### 1. MySQL Binlog + Flink CDC
```
MySQL Binlog → Flink CDC → StarRocks
```
- 适用场景：实时同步、增量迁移
- 优点：低延迟、自动捕获变更
- 缺点：需要Flink环境、配置复杂

###### 2. DataX + Stream Load
```
MySQL → DataX → Stream Load → StarRocks
```
- 适用场景：批量迁移、定时同步
- 优点：配置简单、性能稳定
- 缺点：批处理延迟

###### 3. Kettle + JDBC
```
MySQL → Kettle → JDBC/Stream Load → StarRocks
```
- 适用场景：复杂转换、数据清洗
- 优点：可视化配置、转换能力强
- 缺点：性能相对较低

###### 4. mysqldump + Stream Load
```
mysqldump → CSV → Stream Load → StarRocks
```
- 适用场景：一次性全量迁移
- 优点：简单直接、无需额外工具
- 缺点：不支持增量、大表导出慢

##### MySQL特有优化
###### 连接池配置
```properties
# Kettle数据库连接池优化
initialSize=10
maxActive=50
maxIdle=20
minIdle=10
maxWait=10000
validationQuery=SELECT 1
testOnBorrow=true
testWhileIdle=true
```

###### 批量读取优化
```sql
-- 使用流式查询避免OOM
SET SESSION net_write_timeout = 600;
SET SESSION net_read_timeout = 600;
-- JDBC URL添加参数
jdbc:mysql://host:3306/db?useCursorFetch=true&defaultFetchSize=5000
```

###### 并行抽取策略
- 按主键范围分片
- 按时间分区并行
- 按哈希值分桶

##### 常见问题处理
###### 字符集乱码
```sql
-- 确保字符集一致
ALTER DATABASE db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
-- JDBC URL指定字符集
jdbc:mysql://host:3306/db?characterEncoding=UTF-8
```

###### 时区问题
```sql
-- MySQL时区设置
SET time_zone = '+08:00';
-- StarRocks时区设置
SET global time_zone = 'Asia/Shanghai';
-- JDBC URL处理
jdbc:mysql://host:3306/db?serverTimezone=Asia/Shanghai
```

###### 大表迁移
- 分批迁移：每批100万-500万条
- 使用分区表：按时间或ID范围分区
- 避免长事务：控制单次导入时间
- 监控资源：关注CPU、内存、网络

##### 数据一致性验证
```sql
-- 行数对比
SELECT COUNT(*) FROM mysql_table;
SELECT COUNT(*) FROM starrocks_table;

-- 数据抽样对比
SELECT MD5(GROUP_CONCAT(column_name ORDER BY id)) 
FROM (SELECT * FROM table LIMIT 10000) t;

-- 聚合值对比
SELECT SUM(amount), COUNT(DISTINCT user_id) FROM table;
```

#### 7.2 Kettle作业最佳实践
- 作业设计规范
- 错误处理机制
- 监控告警配置
- 调度策略

#### 7.3 生产环境建议
- 硬件规划
- 集群规模评估
- 备份恢复策略
- 升级方案

## 实验设计

### Lab 1: 表模型选择实验
**目标**：理解不同表模型的特点和适用场景
- 创建三种模型的表
- 导入相同的测试数据
- 执行不同类型的查询
- 对比存储空间和查询性能

### Lab 2: 分区分桶优化实验
**目标**：掌握分区分桶设计技巧
- 创建不同分区策略的表
- 测试分区裁剪效果
- 调整分桶数量
- 验证查询性能差异

### Lab 3: Kettle ETL实战
**目标**：构建完整的ETL流程
- 配置Oracle数据源
- 设计数据转换逻辑
- 实现Stream Load集成
- 性能调优和错误处理

### Lab 4: SQL调优实战
**目标**：掌握SQL优化技巧
- 分析慢查询
- 使用EXPLAIN分析执行计划
- 创建物化视图
- 对比优化前后性能

## 示例代码规划

### SQL示例
- 各种表模型的建表语句
- 分区表创建示例
- 物化视图创建
- 常见查询优化案例

### Kettle示例
- Oracle连接配置
- 数据转换模板
- Stream Load集成
- 错误处理作业

### Shell脚本
- Stream Load脚本封装
- 批量数据导入脚本
- 监控检查脚本
- 自动化运维脚本

## 教程特色总结

1. **场景驱动**：基于真实的Kettle+Oracle ETL场景
2. **重点突出**：聚焦表设计、分区分桶、SQL优化三大核心
3. **循序渐进**：从基础概念到高级优化，层层深入
4. **实战导向**：大量实际案例和动手实验
5. **性能优先**：所有内容围绕性能优化展开
6. **工具结合**：深度集成Kettle工具链
7. **迁移指南**：完整的Oracle迁移方案

## 下一步计划

1. 创建项目目录结构
2. 编写README.md主页
3. 按优先级编写核心章节（表设计、SQL优化）
4. 开发示例代码和脚本
5. 设计并编写实验内容
6. 补充其他章节
7. 整体审校和优化