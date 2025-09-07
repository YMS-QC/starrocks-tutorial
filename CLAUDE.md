# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

这是一个StarRocks SQL和ETL开发人员快速教程项目，专门针对从Oracle/MySQL迁移到StarRocks的场景设计。重点关注Kettle集成、表模型设计、分区分桶优化和SQL调优。

## 项目架构

### 核心目录结构
- `docs/` - 教程文档，按章节组织（01-introduction到07-best-practices）
  - `01-introduction/` - StarRocks简介和核心概念
  - `02-quick-start/` - Docker部署和快速开始
  - `03-table-design/` - 表设计核心（表模型、分区、分桶、索引、事务）
  - `04-kettle-integration/` - Kettle ETL集成和数据迁移
  - `05-sql-optimization/` - SQL优化（查询分析、索引、Join、聚合）
  - `06-advanced-features/` - 高级特性（物化视图、执行引擎等）
  - `07-best-practices/` - 生产环境最佳实践
  - `version-comparison.md` - 版本特性对照表
- `examples/` - 示例代码
  - `sql/table-creation/` - 建表SQL示例
- `config/` - StarRocks配置文件（be.conf, fe.conf）
- `docker-compose.yml` - 完整的StarRocks 3.2容器化部署
- `start.sh` - 一键启动脚本，包含环境检查和集群初始化
- `test-connection.sh` - 连接测试和健康检查脚本
- `CLAUDE.md` - Claude Code项目配置文件

### 文档组织原则
每个章节采用递进式学习路径：
1. 理论概念介绍
2. 版本兼容性说明
3. 实际操作示例
4. 最佳实践总结
5. 常见问题解答

所有文档都包含统一的导航链接系统：
```markdown
---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](previous.md) | [➡️ 下一页](next.md)
---
```

## 常用命令

### 环境管理
```bash
# 一键启动StarRocks集群（包含FE、BE、管理工具）
./start.sh

# 连接测试和健康检查
./test-connection.sh

# 停止所有服务
docker-compose down

# 启动核心服务（不包含管理工具）
docker-compose up -d starrocks-fe starrocks-be

# 启动包含管理工具的完整服务
docker-compose --profile tools up -d
```

### 连接方式
```bash
# MySQL客户端连接
mysql -h localhost -P 9030 -u root

# 使用容器内mysql客户端
docker exec -it mysql-client mysql -h starrocks-fe -P 9030 -u root

# Web管理界面
# FE: http://localhost:8030
# BE: http://localhost:8040  
# Adminer: http://localhost:8080
```

### 集群管理
```sql
-- 检查集群状态
SHOW BACKENDS;
SHOW FRONTENDS;

-- 手动添加BE节点（如果自动添加失败）
ALTER SYSTEM ADD BACKEND 'starrocks-be:9050';

-- 查看数据库和表
SHOW DATABASES;
USE demo_etl;
SHOW TABLES;
```

## 核心技术栈

- **数据库**: StarRocks 3.2+（实时分析型数据库）
- **ETL工具**: Kettle (Pentaho Data Integration)
- **源数据库**: Oracle, MySQL
- **数据加载**: Stream Load API
- **查询优化**: 物化视图、分区、分桶、索引
- **容器化**: Docker + Docker Compose
- **版本控制**: Git with 中文文档支持

## 关键概念

### StarRocks表模型
- **Duplicate模型**: 明细数据，保留所有原始记录
- **Aggregate模型**: 预聚合数据，支持SUM/MAX/MIN/REPLACE等
- **Unique模型**: 主键唯一，支持更新（MoR/CoW两种模式）
- **Primary Key模型**: 3.0+版本，支持实时更新和删除（主键表）

### 分区策略
- Range分区（时间分区为主）
- List分区（枚举值分区）
- 动态分区管理
- Expression分区（3.0+版本支持）

### 分桶设计
- 理想分桶数 = 数据总量(GB) / 1-2GB
- 高基数列作为分桶键
- 避免数据倾斜
- 自动分桶（Auto Bucketing 3.2+版本支持）

## 数据库迁移要点

### Oracle到StarRocks迁移

#### 数据类型映射
- NUMBER → DECIMAL/BIGINT/LARGEINT
- VARCHAR2 → VARCHAR
- DATE/TIMESTAMP → DATETIME
- CLOB → STRING
- BLOB → 需要转换处理

#### 特性映射
- 序列 → 自增列或应用层生成
- 分区表 → Range/List分区
- 索引 → StarRocks自动索引 + Bitmap/Bloom Filter
- 物化视图 → StarRocks物化视图

### MySQL到StarRocks迁移

#### 数据类型映射
- TINYINT/SMALLINT/INT/BIGINT → 对应整数类型
- MEDIUMINT → INT (3字节转4字节)
- DECIMAL → DECIMAL
- VARCHAR/CHAR → VARCHAR/CHAR
- TEXT/MEDIUMTEXT/LONGTEXT → STRING
- DATE/DATETIME → DATE/DATETIME
- TIMESTAMP → DATETIME
- TIME → STRING
- JSON → JSON/STRING
- ENUM/SET → VARCHAR
- BLOB/BINARY → STRING

#### 特性差异
- AUTO_INCREMENT → StarRocks AUTO_INCREMENT
- 外键约束 → 应用层维护（不支持）
- 触发器 → 应用层实现
- 存储过程 → 改写为SQL
- 事务 → 仅支持单表事务
- 字符集 → utf8mb4转UTF-8

#### 迁移工具
1. **MySQL Binlog + Flink CDC**: 实时同步
2. **DataX + Stream Load**: 批量迁移
3. **Kettle + JDBC**: 复杂转换
4. **mysqldump + Stream Load**: 一次性迁移

#### 注意事项
- NULL值处理基本一致
- GROUP BY行为需注意ONLY_FULL_GROUP_BY差异
- 查询优化器不同，需重新调优
- 依赖分区分桶而非传统索引

## ETL开发模式

### Kettle集成流程
```
Oracle/MySQL(源) → Kettle(转换) → Stream Load → StarRocks(目标)
```

### 同步模式
- 全量同步: Truncate + Load
- 增量同步: 基于时间戳/自增ID/CDC
- 实时同步: Kettle + Kafka + Routine Load

### Stream Load最佳实践
```bash
# 基本Stream Load示例
curl --location-trusted -u root: -H "label:test_load_001" \
    -H "column_separator:," \
    -T data.csv \
    http://localhost:8040/api/demo_etl/user_behavior/_stream_load

# 批量大小建议：10K-100K行，根据系统资源调整
# 超时时间建议：300-600秒
# 错误容忍度：max_filter_ratio建议0.01-0.1
```

## SQL优化重点

### 查询分析
- 使用EXPLAIN/EXPLAIN ANALYZE查看执行计划
- Profile分析找出瓶颈
- 版本差异：EXPLAIN ANALYZE在2.5+版本支持

### Join优化
- Broadcast Join（小表广播）：小于100MB的表
- Shuffle Join（大表shuffle）：数据重分布
- Colocation Join（本地join）：2.0+版本支持

### 聚合优化
- 物化视图自动改写：2.5+异步物化视图
- Rollup表加速：传统同步物化视图
- Bitmap函数优化Count Distinct：精确去重计算

### 索引策略
- 前缀索引：自动创建，基于排序键
- Bitmap索引：低基数列（<1000唯一值）
- Bloom Filter索引：高基数列的等值查询
- 倒排索引（GIN）：3.1+版本支持全文检索
- N-gram Bloom Filter：3.2+版本支持模糊匹配
- 持久化索引：3.0+版本Primary Key表专用

## 版本兼容性指南

### 推荐版本选择
- **生产稳定**: StarRocks 2.5 LTS（长期支持到2025-12）
- **新特性体验**: StarRocks 3.2+（最新稳定版本）
- **云原生部署**: StarRocks 3.0+（支持Shared-data架构）

### 关键特性版本要求
- Primary Key表模型：3.0+
- 异步物化视图：2.5+
- Colocation Join：2.0+
- 动态分区：1.19+
- 自动分桶：3.2+
- Expression分区：3.0+
- Pipeline执行引擎：2.5+
- 向量化执行：2.0+
- 倒排索引（GIN）：3.1+
- N-gram Bloom Filter：3.2+
- SQL事务：3.5+
- Stream Load事务：2.4+

## 开发规范

### 文档编写
- 所有回复使用中文（根据用户全局配置）
- 每个新特性标注版本要求
- 提供实际可执行的代码示例
- 包含性能优化建议

### 代码示例规范
- SQL示例使用实际业务场景
- Kettle配置提供完整的ktr文件
- 脚本包含错误处理和日志记录
- 版本兼容性检查

### 问题排查
- 优先检查Docker服务状态
- 验证端口占用情况（8030, 9030, 8040等）
- 查看容器日志：`docker-compose logs starrocks-fe`
- 使用test-connection.sh进行全面健康检查

## 教程特色功能

### 导航系统
每个文档都包含统一的导航链接，支持：
- 返回主页
- 上一页/下一页跳转
- 章节内文档互联

### 实验环境
提供完整的Docker化实验环境：
- StarRocks 3.2集群（FE + BE）
- MySQL客户端工具
- Adminer Web管理界面
- 自动化健康检查

### 版本对照
详细的版本特性对照表，帮助用户：
- 选择合适的StarRocks版本
- 了解特性演进历程
- 制定升级计划

使用本教程时，建议按章节顺序学习，每章都包含理论讲解、实战示例和最佳实践，适合SQL开发人员、ETL工程师和数据架构师快速掌握StarRocks核心技术。

## 最新更新记录

### 2024年1月更新
- ✅ **完整教程发布**: 26,609行内容，7大核心章节
- ✅ **索引深度解析**: 新增前缀/Bitmap/Bloom Filter/倒排/N-gram索引完整指南
- ✅ **事务机制详解**: 新增事务模型、ACID特性、数据一致性专题
- ✅ **执行引擎原理**: 新增Fragment/Pipeline/向量化执行深度解析
- ✅ **Docker化环境**: 一键部署StarRocks 3.2集群
- ✅ **版本兼容性**: 支持StarRocks 1.19-3.3+全版本特性对照

### 教程核心优势
1. **理论与实战结合**: 从基础概念到生产实践的完整覆盖
2. **版本演进追踪**: 详细的版本特性对照和升级指导
3. **迁移专业指南**: Oracle/MySQL到StarRocks的完整迁移方案
4. **性能优化导向**: 索引设计、查询优化、执行引擎调优
5. **开箱即用环境**: Docker化部署和自动化脚本

### 适用人群扩展
- **SQL开发人员**: 掌握StarRocks SQL优化和查询分析
- **ETL工程师**: 学习Kettle集成和数据迁移最佳实践  
- **数据库管理员**: 了解集群部署、性能调优和运维管理
- **数据架构师**: 理解表设计、分区策略和技术选型
- **研发工程师**: 深入理解执行引擎原理和底层机制

### 技术栈覆盖
- **存储引擎**: 表模型设计、分区分桶、索引优化
- **执行引擎**: Pipeline模型、向量化执行、Fragment划分
- **查询优化**: CBO优化器、Join算法、聚合优化
- **数据集成**: ETL工具集成、Stream Load API、事务处理
- **运维监控**: 集群管理、性能分析、故障排查

这是一份面向生产环境的StarRocks完整学习资源，帮助团队快速掌握StarRocks核心技术栈。