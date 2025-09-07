---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../03-table-design/data-types-mapping.md) | [➡️ 下一页](oracle-to-starrocks.md)
---

# Kettle环境配置

## 学习目标

- 掌握Kettle（PDI）的安装和基础配置
- 学会配置StarRocks JDBC驱动和数据库连接
- 了解Kettle性能优化和内存配置
- 掌握Kettle与StarRocks的集成最佳实践

## Kettle简介

### 什么是Kettle（PDI）

Kettle（Pentaho Data Integration，PDI）是一个开源的ETL工具，提供图形化的数据集成环境，支持：

- **数据抽取（Extract）**：从各种数据源读取数据
- **数据转换（Transform）**：清洗、转换、聚合数据
- **数据加载（Load）**：将数据写入目标系统

### Kettle核心组件

| 组件 | 用途 | 文件扩展名 | 说明 |
|------|------|-----------|------|
| **Spoon** | 图形化设计器 | - | 用于设计转换和作业 |
| **Pan** | 转换执行引擎 | .ktr | 执行数据转换 |
| **Kitchen** | 作业执行引擎 | .kjb | 执行作业流程 |
| **Carte** | Web服务器 | - | 远程执行和监控 |

## Kettle安装配置

### 1. 系统要求

| 组件 | 最低要求 | 推荐配置 |
|------|---------|---------|
| **操作系统** | Windows 10/Linux/macOS | Windows 10+ 64位 |
| **Java** | JRE 8+ | OpenJDK 11 |
| **内存** | 4GB | 8GB+ |
| **磁盘** | 2GB | 10GB+ |
| **CPU** | 2核 | 4核+ |

### 2. 下载安装

```bash
# 1. 下载Kettle
# 访问：https://www.hitachivantara.com/en-us/products/pentaho-platform.html
# 或者：https://sourceforge.net/projects/pentaho/

# 2. 解压安装包
# Windows
unzip pdi-ce-9.4.0.0-343.zip
cd data-integration

# Linux/macOS
tar -xzf pdi-ce-9.4.0.0-343.tar.gz
cd data-integration

# 3. 验证Java环境
java -version
# 需要Java 8或更高版本
```

### 3. 启动Kettle

```bash
# Windows
cd data-integration
Spoon.bat

# Linux/macOS
cd data-integration
./spoon.sh

# 命令行执行转换
# Windows
pan.bat /file:C:\path\to\transformation.ktr

# Linux/macOS  
./pan.sh -file=/path/to/transformation.ktr
```

## StarRocks JDBC驱动配置

### 1. 下载StarRocks JDBC驱动

```bash
# 方法1：从StarRocks官网下载
# https://docs.starrocks.io/zh/docs/loading/Spark-connector-starrocks/

# 方法2：使用MySQL JDBC驱动（兼容）
# https://dev.mysql.com/downloads/connector/j/
wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-8.0.33.jar
```

### 2. 安装JDBC驱动

```bash
# 将JDBC驱动复制到Kettle的lib目录
# Windows
copy mysql-connector-java-8.0.33.jar data-integration\lib\

# Linux/macOS
cp mysql-connector-java-8.0.33.jar data-integration/lib/

# 重启Spoon使驱动生效
```

### 3. 创建数据库连接

在Spoon中创建StarRocks连接：

```
1. 打开Spoon → 视图 → 数据库连接
2. 右键 → 新建连接
3. 配置连接参数：

连接名称: StarRocks_Connection
连接类型: MySQL
访问方式: 本地
服务器名称: localhost
端口号: 9030
数据库名: demo_etl
用户名: root  
密码: (空)
```

### 4. 连接测试和验证

```sql
-- 在连接配置中点击"测试"按钮
-- 或者在SQL编辑器中执行：

-- 测试连接
SELECT 1 as test;

-- 查看数据库信息
SELECT VERSION() as starrocks_version;
SHOW DATABASES;

-- 验证表访问
SELECT COUNT(*) FROM information_schema.tables 
WHERE table_schema = 'demo_etl';
```

## Kettle性能优化配置

### 1. JVM内存配置

```bash
# 编辑启动脚本
# Windows: 编辑 Spoon.bat
# Linux/macOS: 编辑 spoon.sh

# 在脚本中添加或修改JVM参数
set PENTAHO_DI_JAVA_OPTIONS=-Xms2048m -Xmx8192m -XX:+UseG1GC -Dfile.encoding=UTF-8

# Linux/macOS版本
export PENTAHO_DI_JAVA_OPTIONS="-Xms2048m -Xmx8192m -XX:+UseG1GC -Dfile.encoding=UTF-8"

# 参数说明：
# -Xms2048m: 初始堆内存2GB
# -Xmx8192m: 最大堆内存8GB  
# -XX:+UseG1GC: 使用G1垃圾收集器
# -Dfile.encoding=UTF-8: 设置文件编码
```

### 2. Kettle配置文件优化

编辑 `data-integration/kettle.properties` 文件：

```properties
# 数据库连接池配置
KETTLE_DATABASE_CONNECTION_POOL_SIZE=20
KETTLE_DATABASE_CONNECTION_POOL_MIN_SIZE=5
KETTLE_DATABASE_CONNECTION_POOL_MAX_SIZE=50

# 步骤性能配置
KETTLE_STEP_PERFORMANCE_SNAPSHOT_LIMIT=1000

# 日志配置
KETTLE_LOG_SIZE_LIMIT=10000
KETTLE_PLUGIN_CACHE_SIZE=1000

# 内存配置
KETTLE_STREAMING_BATCH_SIZE=10000
KETTLE_STREAMING_QUEUE_SIZE=20000

# 文件处理配置
KETTLE_MAX_LOG_SIZE_IN_LINES=50000
KETTLE_MAX_LOG_TIMEOUT_IN_MINUTES=1440
```

### 3. 数据库连接池配置

```sql
-- 在数据库连接的高级选项中配置：

-- 连接池参数
初始连接数: 5
最大活动连接数: 20  
最大空闲连接数: 10
连接超时时间: 30000 (毫秒)

-- MySQL连接参数（用于StarRocks）
useServerPrepStmts=false
rewriteBatchedStatements=true  
useCompression=true
defaultFetchSize=5000
useCursorFetch=true
```

## 基础转换设计

### 1. 创建第一个转换

```
步骤1：新建转换
文件 → 新建 → 转换

步骤2：添加步骤
从左侧面板拖拽以下步骤到画布：
- 输入 → 表输入
- 转换 → 字段选择  
- 输出 → 表输出

步骤3：连接步骤
使用连接线将步骤按顺序连接
```

### 2. 配置表输入步骤

```sql
-- 双击"表输入"步骤，配置：

步骤名称: 读取源数据
数据库连接: [选择源数据库连接]

SQL语句:
SELECT 
    user_id,
    username,
    email,
    age,
    gender,
    city,
    register_date,
    last_login,
    status
FROM users 
WHERE register_date >= '2024-01-01'
  AND status = 'ACTIVE'
ORDER BY user_id;

-- 点击"预览"测试SQL执行结果
```

### 3. 配置字段选择步骤

```
双击"字段选择"步骤：

字段配置:
- user_id: BIGINT → 保留
- username: VARCHAR(50) → 保留，重命名为user_name
- email: VARCHAR(100) → 保留
- age: INT → 保留，如果NULL则默认为0
- gender: VARCHAR(10) → 保留
- city: VARCHAR(50) → 保留，重命名为user_city
- register_date: DATE → 保留
- last_login: DATETIME → 保留  
- status: VARCHAR(20) → 保留

移除字段: (无)
```

### 4. 配置表输出步骤

```sql
-- 双击"表输出"步骤：

步骤名称: 写入StarRocks
数据库连接: StarRocks_Connection
目标表: dim_users

字段映射:
源字段        → 目标字段
user_id      → user_id
user_name    → username  
email        → email
age          → age
gender       → gender
user_city    → city
register_date → register_date
last_login   → last_login
status       → status

选项配置:
☑ 指定数据库字段
☑ 使用批量插入
☐ 截断表
批量大小: 10000
```

### 5. 执行和调试

```
执行转换:
1. 点击工具栏的"执行"按钮（绿色播放图标）
2. 在执行配置窗口中设置：
   - 日志级别: Basic
   - 安全模式: 关闭
   - 显示转换
3. 点击"启动"

查看执行结果:
- 执行日志面板显示详细信息
- 检查每个步骤的输入/输出行数
- 查看错误信息（如果有）
```

## 常用步骤配置

### 1. 数据输入步骤

#### 表输入（Table Input）
```sql
-- 用于执行SQL查询读取数据
-- 支持参数化查询

SELECT * FROM orders 
WHERE order_date = ?  -- 使用参数
  AND amount > ?

-- 在参数选项卡中定义:
-- Parameter: date_param, Type: Date, Default: 2024-01-01
-- Parameter: amount_param, Type: Number, Default: 100
```

#### 文本文件输入（Text File Input）
```
配置文件输入:
文件路径: C:\data\users.csv
分隔符: ,
包围符: "
头部行数: 1

字段定义:
- user_id: Integer
- username: String, Length: 50
- email: String, Length: 100
- age: Integer
```

### 2. 数据转换步骤

#### 计算器（Calculator）
```
创建计算字段:
字段名: full_name
计算类型: 连接字段
字段A: first_name
字段B: last_name
分隔符: " "

字段名: age_group
计算类型: 条件计算
条件: age < 25 ? "青年" : (age < 50 ? "中年" : "老年")
```

#### 值映射（Value Mapper）
```
字段映射配置:
目标字段: gender_cn
源字段: gender

映射规则:
M → 男
F → 女
null → 未知
default → 其他
```

### 3. 数据输出步骤

#### 插入/更新（Insert/Update）
```sql
-- 用于Unique表的UPSERT操作
-- 配置查找条件
查找字段: user_id
更新字段: username, email, age, last_login
插入字段: 全部字段

-- 对应StarRocks的INSERT INTO ... ON DUPLICATE KEY UPDATE
```

#### 同步/异步表输出
```
同步表输出:
- 实时提交每个批次
- 适合小数据量
- 错误时立即停止

异步表输出:
- 批量提交
- 适合大数据量  
- 更好的性能
```

## Kettle监控和日志

### 1. 日志配置

```bash
# 编辑 log4j.xml 配置文件
# 位置：data-integration/system/karaf/etc/

# 设置日志级别
<logger name="org.pentaho" level="INFO"/>
<logger name="org.springframework" level="WARN"/>
<logger name="org.apache" level="WARN"/>

# 日志文件配置
<appender name="file" class="org.apache.log4j.DailyRollingFileAppender">
    <param name="File" value="logs/pdi.log"/>
    <param name="DatePattern" value="'.'yyyy-MM-dd"/>
    <param name="MaxFileSize" value="100MB"/>
    <param name="MaxBackupIndex" value="10"/>
</appender>
```

### 2. 性能监控

```sql
-- 在Spoon中启用步骤性能监控
-- 右键步骤 → 监控此步骤

-- 查看性能指标：
- 输入行数
- 输出行数
- 读取速度（行/秒）
- 写入速度（行/秒）
- 错误行数
- 执行时间

-- 性能分析查询
SELECT 
    step_name,
    lines_read,
    lines_written,
    lines_input,
    lines_output,
    errors,
    start_time,
    end_time,
    TIMESTAMPDIFF(SECOND, start_time, end_time) as duration_seconds
FROM performance_log;
```

### 3. 错误处理

```
错误处理配置：
1. 步骤错误处理
   - 忽略错误：继续处理其他数据
   - 停止转换：遇到错误立即停止
   - 重定向错误行：将错误数据输出到错误流

2. 全局错误处理
   - 设置最大错误数
   - 错误率阈值
   - 邮件通知配置
```

## 命令行执行

### 1. Pan命令（转换执行）

```bash
# 基础语法
pan.bat -file=transformation.ktr -param:param_name=value

# 完整示例
pan.bat \
  -file="D:\etl\user_sync.ktr" \
  -param:start_date=2024-01-01 \
  -param:end_date=2024-01-31 \
  -level=Basic \
  -logfile="D:\logs\user_sync.log"

# 参数说明:
# -file: 转换文件路径
# -param: 传递参数
# -level: 日志级别(Error, Minimal, Basic, Detailed, Debug, Rowlevel)
# -logfile: 日志文件路径
```

### 2. Kitchen命令（作业执行）

```bash
# 基础语法  
kitchen.bat -file=job.kjb -param:param_name=value

# 完整示例
kitchen.bat \
  -file="D:\etl\daily_etl_job.kjb" \
  -param:process_date=2024-01-15 \
  -level=Basic \
  -logfile="D:\logs\daily_etl.log"
```

### 3. 调度执行脚本

#### Windows批处理脚本
```batch
@echo off
setlocal enabledelayedexpansion

set KETTLE_HOME=D:\kettle\data-integration
set LOG_DIR=D:\logs
set ETL_DIR=D:\etl

cd /d %KETTLE_HOME%

REM 获取当前日期
for /f "tokens=1-4 delims=/ " %%a in ('date /t') do (
    set current_date=%%d-%%b-%%c
)

REM 执行ETL作业
kitchen.bat ^
  -file="%ETL_DIR%\daily_sync.kjb" ^
  -param:process_date=%current_date% ^
  -level=Basic ^
  -logfile="%LOG_DIR%\daily_sync_%current_date%.log"

REM 检查执行结果
if %ERRORLEVEL% EQU 0 (
    echo ETL job completed successfully
) else (
    echo ETL job failed with error code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)
```

#### Linux Shell脚本
```bash
#!/bin/bash

KETTLE_HOME="/opt/kettle/data-integration"  
LOG_DIR="/var/log/etl"
ETL_DIR="/opt/etl"

cd $KETTLE_HOME

# 获取当前日期
CURRENT_DATE=$(date +%Y-%m-%d)

# 执行ETL作业
./kitchen.sh \
  -file="$ETL_DIR/daily_sync.kjb" \
  -param:process_date=$CURRENT_DATE \
  -level=Basic \
  -logfile="$LOG_DIR/daily_sync_$CURRENT_DATE.log"

# 检查执行结果
if [ $? -eq 0 ]; then
    echo "ETL job completed successfully"
    exit 0
else
    echo "ETL job failed with error code $?"
    exit 1
fi
```

## 最佳实践

### 1. 开发规范

```
命名规范:
- 转换文件: [业务]_[操作]_[源系统]_to_[目标系统].ktr
  示例: user_sync_oracle_to_starrocks.ktr
- 作业文件: [业务]_[频率]_job.kjb
  示例: user_daily_job.kjb
- 步骤命名: 使用描述性名称，如"读取用户数据"、"数据清洗"

目录结构:
kettle-project/
├── transformations/     # 转换文件
├── jobs/               # 作业文件
├── scripts/            # 脚本文件
├── logs/               # 日志文件
├── config/             # 配置文件
└── docs/               # 文档
```

### 2. 性能优化

```
设计原则:
1. 减少步骤数量：合并相似操作
2. 并行处理：使用拷贝行分发
3. 内存管理：避免全部数据加载到内存
4. 批量操作：使用合适的批量大小
5. 索引利用：在JOIN操作中使用索引

批量大小建议:
- 小表(<10万行): 10000
- 中表(10-100万行): 50000  
- 大表(>100万行): 100000
```

### 3. 错误处理策略

```
多层错误处理:
1. 数据验证层：检查数据格式和完整性
2. 转换层：处理数据转换错误
3. 输出层：处理目标系统连接错误  
4. 监控层：记录和报告所有错误

容错设计:
- 设置合理的重试次数
- 实现断点续传功能
- 保存错误数据用于人工处理
- 建立告警机制
```

## 小结

Kettle环境配置的关键要点：

1. **环境准备**：Java 8+、充足内存、JDBC驱动
2. **连接配置**：StarRocks兼容MySQL协议，使用MySQL驱动
3. **性能优化**：JVM参数、连接池、批量大小
4. **开发规范**：命名规范、目录结构、错误处理
5. **监控运维**：日志配置、性能监控、命令行执行

正确配置Kettle环境是成功实施StarRocks ETL项目的基础，为后续的数据迁移工作奠定了坚实基础。

---
## 📖 导航
[🏠 返回主页](../../README.md) | [⬅️ 上一页](../03-table-design/data-types-mapping.md) | [➡️ 下一页](oracle-to-starrocks.md)
---