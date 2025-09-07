# StarRocks SQL 和 ETL 开发教程

> 面向 SQL 和 ETL 开发人员的 StarRocks 快速教程，专注于 Oracle/MySQL 到 StarRocks 的迁移实战。

## 🎯 教程简介

本教程面向具备一定数据库基础的 SQL 和 ETL 开发人员，重点介绍如何从 Oracle/MySQL 迁移到 StarRocks。通过系统性的理论讲解和实战演练，帮助你快速掌握 StarRocks 的核心技术和最佳实践。

> ⚠️ **重要提示**：StarRocks 是分析型数据库(OLAP)，专长于查询分析而非事务处理。本教程强调正确的架构设计：**OLTP 业务保留传统数据库，OLAP 分析使用 StarRocks**，通过 ETL 实现数据一致性保证。

### 🌟 核心特色

- 📚 **理论与实战结合**：从 StarRocks 基础概念到生产环境部署
- 🔧 **工具深度集成**：基于 Kettle 的 Oracle/MySQL 到 StarRocks ETL 方案
- ⚡ **性能优化导向**：深入讲解 StarRocks SQL 优化技巧
- 🎯 **场景化教学**：真实业务场景和问题解决方案
- 💾 **事务一致性专题**：详解分析型数据库事务特点，强调正确的架构设计

### 👥 适用人群

- SQL 开发工程师
- ETL 开发工程师
- 数据库管理员
- 数据架构师和数据平台工程师

## 🚀 快速开始

### 环境要求

- Docker 20.10+ 和 Docker Compose
- 内存 8GB 以上（推荐 16GB）
- Kettle 9.0+（用于 ETL 实战）
- MySQL Client 或 DBeaver 数据库工具

### 一键部署

```bash
# 克隆教程代码
git clone https://github.com/your-repo/starrocks-tutorial.git
cd starrocks-tutorial

# 使用 Docker Compose 启动 StarRocks
docker-compose up -d

# 验证部署
mysql -h 127.0.0.1 -P 9030 -u root
```

## 📖 教程目录

### [第1章：StarRocks 简介](docs/01-introduction/)
- [什么是 StarRocks](docs/01-introduction/what-is-starrocks.md) - 产品定位和核心优势

### [第2章：快速开始](docs/02-quick-start/) 
- [Docker 环境部署](docs/02-quick-start/installation-docker.md) - 一键部署开发环境
- [连接工具配置](docs/02-quick-start/connect-tools.md) - DBeaver/DataGrip 配置指南
- [第一个 ETL 任务](docs/02-quick-start/first-etl.md) - 快速上手实战

### [第3章：表设计核心](docs/03-table-design/) 🔥重点
- [表模型详解](docs/03-table-design/table-models.md) - Duplicate/Aggregate/Unique/Primary Key模型选择
- [分区策略设计](docs/03-table-design/partition-strategy.md) - Range/List 分区最佳实践
- [分桶设计优化](docs/03-table-design/bucket-design.md) - 分桶数量和分布键优化
- [索引设计详解](docs/03-table-design/index-design.md) - 前缀/Bitmap/Bloom Filter/倒排/N-gram索引完整指南 🆕
- [数据类型映射](docs/03-table-design/data-types-mapping.md) - Oracle/MySQL 类型完整映射
- [事务和数据一致性](docs/03-table-design/transaction-consistency.md) - 事务模型和ACID特性详解

### [第4章：Kettle 集成](docs/04-kettle-integration/)
- [Kettle 环境配置](docs/04-kettle-integration/kettle-setup.md) - JDBC 驱动和连接配置
- [Oracle 到 StarRocks](docs/04-kettle-integration/oracle-to-starrocks.md) - Oracle 迁移完整方案
- [MySQL 到 StarRocks](docs/04-kettle-integration/mysql-to-starrocks.md) - MySQL 迁移最佳实践
- [Stream Load 集成](docs/04-kettle-integration/stream-load-integration.md) - 高性能数据导入
- [批量处理策略](docs/04-kettle-integration/batch-processing-strategies.md) - 大数据量处理技巧
- [错误处理机制](docs/04-kettle-integration/error-handling-mechanisms.md) - 完善的异常处理

### [第5章：SQL 优化](docs/05-sql-optimization/) 🔥重点
- [查询分析工具](docs/05-sql-optimization/query-analysis.md) - EXPLAIN 和 Profile 使用
- [索引优化策略](docs/05-sql-optimization/index-optimization.md) - 全面的索引优化技巧和性能调优 📈
- [Join 优化技巧](docs/05-sql-optimization/join-optimization.md) - Broadcast/Shuffle/Colocation Join
- [聚合查询优化](docs/05-sql-optimization/aggregate-optimization.md) - 聚合查询和 Rollup

### [第6章：高级特性](docs/06-advanced-features/)
- [物化视图应用](docs/06-advanced-features/materialized-views.md) - 查询加速核心技术
- [动态分区管理](docs/06-advanced-features/dynamic-partitioning.md) - 自动化分区运维
- [Colocation Join](docs/06-advanced-features/colocation-join.md) - 本地化 Join 优化
- [执行引擎深度解析](docs/06-advanced-features/execution-engine-internals.md) - Fragment/Pipeline/向量化执行原理 🆕⭐
- [大数据生态集成](docs/06-advanced-features/big-data-ecosystem.md) - Hive/Spark/Flink 集成

### [第7章：最佳实践](docs/07-best-practices/)
- [Oracle 迁移最佳实践](docs/07-best-practices/oracle-migration-best-practices.md) - 完整迁移指南
- [MySQL 迁移最佳实践](docs/07-best-practices/mysql-migration-best-practices.md) - MySQL 专项优化
- [生产环境部署](docs/07-best-practices/production-deployment.md) - 硬件规划和运维管理

### [版本特性对比](docs/version-comparison.md) 📊参考
- StarRocks 版本特性对照表 - 包含事务功能演进和版本选择指南

## 🧪 实验指南

### Lab 1: 表模型选择实验
通过对比实验理解不同表模型的特点和适用场景

### Lab 2: Kettle ETL 实战
构建完整的 Oracle/MySQL 到 StarRocks ETL 流程

### Lab 3: SQL 优化实战
通过实际案例掌握查询性能优化技巧

### Lab 4: 生产环境案例
模拟真实生产环境的部署和运维场景

## 📝 代码示例

### [SQL 示例](examples/sql/)
- [建表语句](examples/sql/table-creation/) - 各种表模型建表示例
- [查询优化](examples/sql/optimization/) - 优化前后 SQL 对比
- [迁移案例](examples/sql/migration/) - Oracle/MySQL 迁移 SQL

### [Kettle 示例](examples/kettle/)
- [转换模板](examples/kettle/transformations/) - 常用数据转换配置
- [作业模板](examples/kettle/jobs/) - 完整 ETL 作业示例
- [配置模板](examples/kettle/templates/) - 可复用配置模板

### [运维脚本](examples/scripts/)
- [Stream Load 脚本](examples/scripts/stream-load/) - 批量导入脚本
- [监控脚本](examples/scripts/monitoring/) - 性能监控工具

## 📅 学习路径

### 🏃‍♂️ 快速入门（1-2小时）
1. 第1章：了解 StarRocks 概念
2. 第2章：完成环境部署
3. 第3章：掌握基础表设计

### 🚀 进阶学习（3-4小时）
1. 第3章：深入表模型和分区设计
2. 第4章：掌握 Kettle ETL 集成
3. Lab 1-2：动手实验验证

### 🎯 高级应用（5-6小时）
1. 第5章：掌握 SQL 优化技巧
2. 第6章：学习高级特性应用
3. 第7章：了解生产最佳实践
4. Lab 3-4：高级实验挑战

## 🛠️ 推荐开发工具

- **IDE**: IntelliJ IDEA / VSCode
- **数据库工具**: DBeaver / DataGrip
- **ETL 工具**: Pentaho Kettle 9.0+
- **监控工具**: Grafana + Prometheus

## 📋 版本兼容性

- StarRocks 版本：3.x
- Kettle 版本：9.0+
- 更新时间：2024年

## 🤝 参与贡献

欢迎提交 Issue 和 Pull Request 参与教程完善！

## 📄 开源协议

MIT License

## 🔗 相关资源

- [StarRocks 官方文档](https://docs.starrocks.io/)
- [Kettle 官方文档](https://help.pentaho.com/)
- [教程讨论区](https://github.com/your-repo/discussions)

---

**开始学习**: 建议从[什么是 StarRocks](docs/01-introduction/what-is-starrocks.md)开始，按章节顺序逐步学习。每个章节都提供了丰富的代码示例和实战指导，帮助你快速掌握 StarRocks 的核心技术！