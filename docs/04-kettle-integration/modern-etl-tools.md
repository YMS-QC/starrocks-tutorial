---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](stream-load-integration.md) | [➡️ 下一页](batch-processing-strategies.md)
---

# 现代ETL工具集成

> **版本要求**：本章节内容适用于StarRocks 2.0+，建议使用3.0+版本以获得最佳工具兼容性

## 概述

除了传统的Kettle工具，StarRocks还支持与多种现代ETL和数据集成工具的集成。本章介绍主流现代ETL工具与StarRocks的集成方案，涵盖实时、批量、云原生等多种场景。

## 现代ETL工具对比

> **版本支持说明**：不同工具与StarRocks集成的版本要求

| 工具 | 类型 | 优势 | 适用场景 | StarRocks集成 | 最低版本要求 |
|------|------|------|---------|--------------|----------|
| **dbt** | SQL转换 | SQL原生、版本控制 | 数据转换、建模 | ✅ 原生支持 | StarRocks 2.5+ |
| **Airbyte** | 数据同步 | 开源、连接器丰富 | 数据源同步 | ✅ 官方连接器 | StarRocks 2.0+ |
| **Apache SeaTunnel** | 流批一体 | 高性能、易用 | 大数据处理 | ✅ 原生支持 | StarRocks 2.5+ |
| **Flink CDC** | 实时同步 | 低延迟、高吞吐 | 实时数据同步 | ✅ 完美支持 | StarRocks 2.0+ |
| **DataX** | 阿里开源 | 成熟稳定 | 离线数据同步 | ✅ 插件支持 | StarRocks 2.0+ |
| **Debezium** | CDC工具 | 事件驱动 | 数据库变更同步 | ✅ Kafka集成 | StarRocks 2.0+ |
| **Spark** | 大数据处理 | 生态丰富、成熟 | 大规模数据处理 | ✅ 官方连接器 | StarRocks 2.3+ |
| **Apache Doris** | 迁移工具 | 同类产品迁移 | 从Doris迁移 | ✅ 兼容支持 | StarRocks 3.0+ |
| **Vector** | 日志收集 | 高性能日志处理 | 日志数据同步 | ✅ HTTP Sink | StarRocks 2.5+ |
| **Tapdata** | 实时数据 | 低代码、实时 | 企业级数据同步 | ✅ 官方支持 | StarRocks 2.5+ |
| **dbt** | SQL转换 | SQL原生、版本控制 | 数据转换、建模 | ✅ 原生支持 |
| **Airbyte** | 数据同步 | 开源、连接器丰富 | 数据源同步 | ✅ 官方连接器 |
| **Apache SeaTunnel** | 流批一体 | 高性能、易用 | 大数据处理 | ✅ 原生支持 |
| **Flink CDC** | 实时同步 | 低延迟、高吞吐 | 实时数据同步 | ✅ 完美支持 |
| **DataX** | 阿里开源 | 成熟稳定 | 离线数据同步 | ✅ 插件支持 |
| **Debezium** | CDC工具 | 事件驱动 | 数据库变更同步 | ✅ Kafka集成 |

## dbt集成

> **版本要求**：dbt-starrocks需要StarRocks 2.5+
> - dbt Core 1.5+：支持基础功能
> - dbt Core 1.6+：支持增量模型和快照
> - dbt Core 1.7+：支持高级StarRocks特性

### 安装配置

```bash
# 1. 安装dbt-starrocks（推荐最新版本）
pip install dbt-starrocks>=1.7.0

# 2. 创建profiles.yml配置文件
mkdir ~/.dbt
cat > ~/.dbt/profiles.yml << EOF
starrocks_profile:
  target: dev
  outputs:
    dev:
      type: starrocks
      host: localhost
      port: 9030
      user: root
      password: ""
      database: dbt_demo
      schema: public
      threads: 8
      keepalives_idle: 0
EOF
```

### dbt项目示例

```yaml
# dbt_project.yml
name: 'starrocks_demo'
version: '1.0.0'
config-version: 2

profile: 'starrocks_profile'
require-dbt-version: ">=1.6.0"  # 指定最低dbt版本

model-paths: ["models"]
analysis-paths: ["analyses"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

target-path: "target"
clean-targets:
  - "target"
  - "dbt_packages"

models:
  starrocks_demo:
    staging:
      materialized: view
    marts:
      materialized: table
      distributed_by: ['id']
```

### 模型定义

```sql
-- models/staging/stg_orders.sql
{{ config(
    materialized='view'
) }}

SELECT
    order_id,
    user_id,
    product_id,
    order_time,
    amount,
    status,
    CURRENT_TIMESTAMP() as updated_at
FROM {{ source('raw_data', 'orders') }}
WHERE status != 'CANCELLED'

-- models/marts/dim_users.sql
{{ config(
    materialized='table',
    distributed_by=['user_id'],
    partition_by=['date_trunc(\'day\', register_date)']
) }}

SELECT
    user_id,
    username,
    email,
    register_date,
    city,
    age_group,
    CURRENT_TIMESTAMP() as dbt_updated_at
FROM {{ ref('stg_users') }}

-- models/marts/fact_orders_daily.sql
{{ config(
    materialized='table',
    distributed_by=['order_date', 'user_id']
) }}

SELECT
    DATE_TRUNC('day', order_time) as order_date,
    user_id,
    COUNT(*) as order_count,
    SUM(amount) as total_amount,
    AVG(amount) as avg_amount
FROM {{ ref('stg_orders') }}
GROUP BY 1, 2
```

## Airbyte集成

### 连接器配置

```json
{
  "destinationType": "starrocks",
  "connectionConfiguration": {
    "host": "localhost",
    "port": 9030,
    "database": "airbyte_demo",
    "username": "root",
    "password": "",
    "loading_method": {
      "method": "Stream Load"
    },
    "tunnel_method": {
      "tunnel_method": "NO_TUNNEL"
    }
  }
}
```

### 同步配置示例

```yaml
# airbyte-config.yml
version: "0.50.0"
definitions:
  sources:
    mysql_source:
      type: mysql
      configuration:
        host: mysql-host
        port: 3306
        database: ecommerce
        username: airbyte_user
        password: ${MYSQL_PASSWORD}
        replication_method: CDC
        
  destinations:
    starrocks_dest:
      type: starrocks
      configuration:
        host: starrocks-fe
        port: 9030
        database: ecommerce_dw
        username: root
        password: ""
        
connections:
  - source: mysql_source
    destination: starrocks_dest
    sync_catalog:
      streams:
        - stream: users
          destination_sync_mode: append_dedup
          primary_key: [user_id]
        - stream: orders
          destination_sync_mode: append_dedup
          primary_key: [order_id]
```

## Apache SeaTunnel集成

> **版本要求**：SeaTunnel 2.3+支持StarRocks Sink
> - SeaTunnel 2.3.0+：基础StarRocks连接器支持
> - SeaTunnel 2.3.3+：优化的批量导入性能
> - SeaTunnel 2.3.4+：完整的流式处理支持

### 安装配置

```bash
# 下载SeaTunnel（推荐最新稳定版）
wget https://github.com/apache/seatunnel/releases/download/v2.3.4/apache-seatunnel-2.3.4-bin.tar.gz
tar -xzf apache-seatunnel-2.3.4-bin.tar.gz
cd apache-seatunnel-2.3.4
tar -xzf apache-seatunnel-2.3.3-bin.tar.gz
cd apache-seatunnel-2.3.3

# 配置StarRocks连接器
cp connector/starrocks/* lib/
```

### 配置文件示例

```hocon
# config/mysql-to-starrocks.conf
env {
  execution.parallelism = 1
  job.mode = "BATCH"
}

source {
  MySQL {
    url = "jdbc:mysql://localhost:3306/ecommerce?useSSL=false&serverTimezone=UTC"
    driver = "com.mysql.cj.jdbc.Driver"
    user = "root"
    password = "password"
    query = "SELECT * FROM orders WHERE created_at >= '2024-01-01'"
  }
}

transform {
  Sql {
    sql = """
      SELECT 
        order_id,
        user_id,
        product_id,
        amount,
        DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') as order_time,
        status
      FROM orders
    """
  }
}

sink {
  StarRocks {
    nodeUrls = ["localhost:8030"]
    username = "root"
    password = ""
    database = "ecommerce_dw"
    table = "orders"
    batch_max_rows = 100000
    starrocks.columns = ["order_id", "user_id", "product_id", "amount", "order_time", "status"]
  }
}
```

### 运行作业

```bash
# 批量同步
./bin/seatunnel.sh --config config/mysql-to-starrocks.conf

# 流式同步配置
env {
  job.mode = "STREAMING"
  checkpoint.interval = 30000
}

source {
  MySQL-CDC {
    hostname = "localhost"
    port = 3306
    username = "root"
    password = "password"
    database-name = "ecommerce"
    table-name = "orders"
    startup.mode = "latest-offset"
  }
}

sink {
  StarRocks {
    nodeUrls = ["localhost:8030"]
    username = "root"
    password = ""
    database = "ecommerce_dw"
    table = "orders_realtime"
    batch_max_rows = 10000
    batch_interval_ms = 5000
  }
}
```

## Flink CDC集成

> **版本要求**：Flink CDC与StarRocks的兼容性
> - Flink 1.14+：基础支持
> - Flink 1.16+：推荐版本，稳定性更好
> - Flink 1.17+：最佳性能，支持最新特性
> - flink-connector-starrocks 1.2.9+：推荐连接器版本

### 依赖配置

```xml
<dependencies>
    <dependency>
        <groupId>com.ververica</groupId>
        <artifactId>flink-connector-mysql-cdc</artifactId>
        <version>2.4.2</version>
    </dependency>
    <dependency>
        <groupId>com.starrocks</groupId>
        <artifactId>flink-connector-starrocks</artifactId>
        <version>1.2.9</version>  <!-- 推荐使用最新版本 -->
    </dependency>
</dependencies>
```

### Flink作业示例

```java
// FlinkCDCToStarRocks.java
public class FlinkCDCToStarRocks {
    public static void main(String[] args) throws Exception {
        StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();
        env.setParallelism(1);
        env.enableCheckpointing(30000);
        
        // MySQL CDC Source
        MySqlSource<String> mySqlSource = MySqlSource.<String>builder()
                .hostname("localhost")
                .port(3306)
                .databaseList("ecommerce")
                .tableList("ecommerce.orders")
                .username("root")
                .password("password")
                .deserializer(new JsonDebeziumDeserializationSchema())
                .build();
                
        // StarRocks Sink
        StarRocksSinkOptions options = StarRocksSinkOptions.builder()
                .withProperty("jdbc-url", "jdbc:mysql://localhost:9030")
                .withProperty("load-url", "localhost:8030")
                .withProperty("username", "root")
                .withProperty("password", "")
                .withProperty("table-name", "ecommerce_dw.orders")
                .withProperty("database-name", "ecommerce_dw")
                .withProperty("sink.properties.format", "json")
                .withProperty("sink.properties.strip_outer_array", "true")
                .build();
                
        env.fromSource(mySqlSource, WatermarkStrategy.noWatermarks(), "MySQL CDC Source")
           .map(new OrderTransformFunction())
           .sinkTo(StarRocksSink.sink(options));
           
        env.execute("MySQL CDC to StarRocks");
    }
}
```

### 配置文件方式（Flink SQL）

```sql
-- create_tables.sql
CREATE TABLE orders_source (
    order_id BIGINT,
    user_id BIGINT,
    product_id BIGINT,
    amount DECIMAL(10,2),
    created_at TIMESTAMP,
    status STRING,
    PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
    'connector' = 'mysql-cdc',
    'hostname' = 'localhost',
    'port' = '3306',
    'username' = 'root',
    'password' = 'password',
    'database-name' = 'ecommerce',
    'table-name' = 'orders'
);

CREATE TABLE orders_sink (
    order_id BIGINT,
    user_id BIGINT,
    product_id BIGINT,
    amount DECIMAL(10,2),
    order_time STRING,
    status STRING
) WITH (
    'connector' = 'starrocks',
    'jdbc-url' = 'jdbc:mysql://localhost:9030',
    'load-url' = 'localhost:8030',
    'database-name' = 'ecommerce_dw',
    'table-name' = 'orders',
    'username' = 'root',
    'password' = '',
    'sink.properties.format' = 'json'
);

-- 实时同步
INSERT INTO orders_sink
SELECT 
    order_id,
    user_id,
    product_id,
    amount,
    DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') as order_time,
    status
FROM orders_source;
```

## DataX集成

### 配置文件

```json
{
    "job": {
        "setting": {
            "speed": {
                "channel": 4,
                "byte": 1048576
            }
        },
        "content": [{
            "reader": {
                "name": "mysqlreader",
                "parameter": {
                    "username": "root",
                    "password": "password",
                    "column": ["order_id", "user_id", "amount", "created_at"],
                    "connection": [{
                        "table": ["orders"],
                        "jdbcUrl": ["jdbc:mysql://localhost:3306/ecommerce"]
                    }]
                }
            },
            "writer": {
                "name": "starrockswriter",
                "parameter": {
                    "username": "root",
                    "password": "",
                    "database": "ecommerce_dw",
                    "table": "orders",
                    "column": ["order_id", "user_id", "amount", "order_time"],
                    "connection": [{
                        "jdbcUrl": "jdbc:mysql://localhost:9030/ecommerce_dw",
                        "loadUrl": ["localhost:8030"]
                    }],
                    "loadProps": {
                        "format": "json",
                        "strip_outer_array": true
                    }
                }
            },
            "transformer": [{
                "name": "dx_groovy",
                "parameter": {
                    "code": "return [record.get(0), record.get(1), record.get(2), new Date().format('yyyy-MM-dd HH:mm:ss')]"
                }
            }]
        }]
    }
}
```

## 新兴ETL工具

### Spark连接器

> **版本支持**：StarRocks Spark连接器需要StarRocks 2.3+

```scala
// Spark 3.x 配置
val spark = SparkSession.builder()
  .appName("StarRocks Integration")
  .config("spark.sql.catalog.starrocks", "com.starrocks.connector.spark.StarRocksCatalog")
  .config("spark.sql.catalog.starrocks.starrocks.fe.http.url", "http://localhost:8030")
  .config("spark.sql.catalog.starrocks.starrocks.fe.jdbc.url", "jdbc:mysql://localhost:9030")
  .config("spark.sql.catalog.starrocks.starrocks.user", "root")
  .config("spark.sql.catalog.starrocks.starrocks.password", "")
  .getOrCreate()

// 读取StarRocks表
val df = spark.read
  .format("starrocks")
  .option("starrocks.table.identifier", "database.table")
  .option("starrocks.fe.http.url", "http://localhost:8030")
  .option("starrocks.fe.jdbc.url", "jdbc:mysql://localhost:9030")
  .option("starrocks.user", "root")
  .option("starrocks.password", "")
  .load()

// 写入StarRocks
df.write
  .format("starrocks")
  .option("starrocks.table.identifier", "database.target_table")
  .option("starrocks.fe.http.url", "http://localhost:8030")
  .option("starrocks.fe.jdbc.url", "jdbc:mysql://localhost:9030")
  .option("starrocks.user", "root")
  .option("starrocks.password", "")
  .mode("append")
  .save()
```

### Vector日志收集器

> **版本支持**：Vector需要StarRocks 2.5+的HTTP API

```toml
# vector.toml
[sources.logs]
type = "file"
include = ["/var/log/app.log"]

[transforms.parse_logs]
type = "json_parser"
inputs = ["logs"]

[sinks.starrocks]
type = "http"
inputs = ["parse_logs"]
uri = "http://localhost:8030/api/mydb/mytable/_stream_load"
method = "put"
headers.Authorization = "Basic cm9vdDo="  # base64(user:password)
headers.format = "json"
headers.strip_outer_array = "true"
```

### Tapdata实时数据平台

> **版本支持**：Tapdata需要StarRocks 2.5+

```json
{
  "type": "starrocks",
  "name": "StarRocks Target",
  "config": {
    "host": "localhost",
    "port": 9030,
    "database": "tapdata_demo",
    "username": "root",
    "password": "",
    "loadUrl": "localhost:8030",
    "batchSize": 1000,
    "flushInterval": 5000,
    "enableUpsert": true
  }
}
```

## 现代ETL工具选择指南

### 按使用场景选择

| 场景 | 推荐工具 | 原因 | StarRocks版本要求 |
|------|---------|------|
| **数据建模转换** | dbt | SQL原生，版本控制，文档生成 | 2.5+ |
| **多源数据同步** | Airbyte | 连接器丰富，配置简单 | 2.0+ |
| **大数据批处理** | SeaTunnel/Spark | 高性能，支持复杂转换 | 2.3+ |
| **实时数据同步** | Flink CDC | 低延迟，高可靠性 | 2.0+ |
| **离线定时同步** | DataX | 成熟稳定，阿里生态 | 2.0+ |
| **日志数据收集** | Vector | 高性能，配置灵活 | 2.5+ |
| **企业级同步** | Tapdata | 低代码，实时性好 | 2.5+ |

### 按团队技能选择

| 技能背景 | 推荐工具 | 学习成本 |
|----------|---------|---------|
| **SQL专家** | dbt | 低 |
| **Java开发** | Flink CDC | 中等 |
| **大数据工程师** | SeaTunnel | 中等 |
| **运维人员** | Airbyte | 低 |
| **传统ETL** | DataX | 低 |

### 性能对比

| 工具 | 批量导入速度 | 实时延迟 | 资源占用 | 可扩展性 | 推荐StarRocks版本 |
|------|-------------|---------|---------|---------|----------------|
| **dbt** | 中等 | N/A | 低 | 中等 | 2.5+ |
| **Airbyte** | 中等 | 分钟级 | 中等 | 高 | 2.0+ |
| **SeaTunnel** | 高 | 秒级 | 中等 | 高 | 2.5+ |
| **Flink CDC** | 高 | 毫秒级 | 高 | 高 | 2.0+ |
| **DataX** | 高 | N/A | 低 | 中等 | 2.0+ |
| **Spark** | 很高 | N/A | 高 | 很高 | 2.3+ |
| **Vector** | 高 | 秒级 | 低 | 高 | 2.5+ |
| **Tapdata** | 高 | 秒级 | 中等 | 高 | 2.5+ |
删除此处的重复内容

## 最佳实践

### 1. 工具组合使用

```
数据源 → Flink CDC(实时同步) → StarRocks(ODS层)
                ↓
         dbt(数据建模) → StarRocks(DWD/DWS层)
                ↓
            BI工具(可视化展示)
```

### 2. 分层架构建议

- **ODS层**：使用Flink CDC或Airbyte直接同步
- **DWD层**：使用dbt进行数据清洗和规范化
- **DWS层**：使用dbt创建聚合表和指标
- **ADS层**：为BI工具优化的应用层表

### 3. 监控和运维

```yaml
# 监控指标
metrics:
  - data_freshness: < 5分钟
  - sync_success_rate: > 99.9%
  - data_quality_score: > 95%
  
# 告警配置  
alerts:
  - sync_failure: 立即告警
  - data_delay: > 10分钟告警
  - quality_drop: < 90%告警
```

## 版本兼容性矩阵

| ETL工具 | StarRocks 2.0 | StarRocks 2.5 | StarRocks 3.0 | StarRocks 3.1+ |
|---------|---------------|---------------|---------------|------------------|
| **dbt** | 基础支持 | ✅ 推荐 | ✅ 完整支持 | ✅ 最新特性 |
| **Airbyte** | ✅ 完整支持 | ✅ 完整支持 | ✅ 完整支持 | ✅ 完整支持 |
| **SeaTunnel** | 基础支持 | ✅ 推荐 | ✅ 完整支持 | ✅ 最新特性 |
| **Flink CDC** | ✅ 完整支持 | ✅ 完整支持 | ✅ 完整支持 | ✅ 最新特性 |
| **DataX** | ✅ 完整支持 | ✅ 完整支持 | ✅ 完整支持 | ✅ 完整支持 |
| **Spark** | 基础支持 | ✅ 推荐 | ✅ 完整支持 | ✅ 最新特性 |
| **Vector** | 不支持 | ✅ 基础支持 | ✅ 完整支持 | ✅ 完整支持 |
| **Tapdata** | 不支持 | ✅ 基础支持 | ✅ 完整支持 | ✅ 完整支持 |

## 版本选择建议

### StarRocks 2.0
- ✅ 适合：基础数据同步需求
- ✅ 推荐工具：Airbyte、Flink CDC、DataX
- ❌ 限制：缺少部分高级特性支持

### StarRocks 2.5+
- ✅ 适合：大多数企业级需求
- ✅ 推荐工具：dbt、SeaTunnel、Vector、Tapdata
- ✅ 优势：完整的工具生态支持

### StarRocks 3.0+
- ✅ 适合：大规模、复杂数据处理需求
- ✅ 推荐工具：所有工具的完整特性
- ✅ 优势：最佳性能和稳定性

### StarRocks 3.1+
- ✅ 适合：最新特性和云原生部署
- ✅ 推荐工具：所有最新版本工具
- ✅ 优势：前沿特性和优化

## 小结

现代ETL工具为StarRocks提供了更加丰富和灵活的数据集成方案：

### 核心推荐（按StarRocks版本）

**StarRocks 2.5+环境**：
- **dbt**：最适合数据建模和转换
- **Flink CDC**：实时同步的最佳选择
- **Airbyte**：多源同步的简单方案
- **SeaTunnel**：大数据处理的高性能选择

**StarRocks 3.0+环境**：
- 上述所有工具 + **Spark连接器**（大规模批处理）
- **Vector**：高性能日志收集
- **Tapdata**：企业级实时同步

建议根据实际需求、团队技能和StarRocks版本，选择合适的工具组合。优先选择与你的StarRocks版本最兼容的工具，以获得最佳的性能和稳定性。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](stream-load-integration.md) | [➡️ 下一页](batch-processing-strategies.md)
---