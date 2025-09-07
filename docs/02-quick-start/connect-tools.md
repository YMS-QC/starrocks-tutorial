# 连接工具配置指南

---

## 📖 导航

[🏠 返回主页](../../README.md) | [⬅️ 上一页](installation-docker.md) | [➡️ 下一页](first-etl.md)

---

## 学习目标

- 掌握多种客户端工具连接StarRocks的方法
- 了解JDBC/ODBC驱动的配置和使用
- 学会使用图形界面工具管理StarRocks
- 掌握编程语言连接StarRocks的方法

## 连接参数说明

### 基础连接信息

| 参数 | 值 | 说明 |
|------|-----|------|
| **主机地址** | localhost | StarRocks FE地址 |
| **端口** | 9030 | MySQL协议端口 |
| **用户名** | root | 默认管理员用户 |
| **密码** | (空) | 默认无密码 |
| **数据库** | information_schema | 默认数据库 |

### 连接字符串格式

```bash
# MySQL协议连接字符串
mysql://username:password@host:port/database

# JDBC连接字符串  
jdbc:mysql://host:port/database?useSSL=false&allowPublicKeyRetrieval=true

# 示例
mysql://root@localhost:9030/
jdbc:mysql://localhost:9030/?useSSL=false
```

## 命令行工具

### 1. MySQL客户端

```bash
# 安装MySQL客户端
# CentOS/RHEL
yum install mysql -y

# Ubuntu/Debian  
apt-get install mysql-client -y

# macOS
brew install mysql-client

# 连接StarRocks
mysql -h localhost -P 9030 -u root

# 带密码连接
mysql -h localhost -P 9030 -u root -p

# 连接到指定数据库
mysql -h localhost -P 9030 -u root test_db

# 执行单条SQL
mysql -h localhost -P 9030 -u root -e "SHOW DATABASES;"

# 执行SQL文件
mysql -h localhost -P 9030 -u root < script.sql
```

### 2. 使用Docker中的MySQL客户端

```bash
# 启动包含mysql-client的容器
docker-compose --profile tools up -d

# 连接StarRocks
docker exec -it mysql-client mysql -h starrocks-fe -P 9030 -u root

# 或者直接运行临时容器
docker run -it --rm --network starrocks-tutorial_starrocks-network \
  mysql:8.0 mysql -h starrocks-fe -P 9030 -u root
```

### 3. 基础SQL验证

```sql
-- 连接后执行基础验证
SHOW DATABASES;
SHOW VARIABLES LIKE 'version%';
SELECT USER(), DATABASE(), NOW();

-- 创建测试数据库和表
CREATE DATABASE IF NOT EXISTS test_db;
USE test_db;

CREATE TABLE users (
    id INT,
    name VARCHAR(50),
    age INT,
    create_time DATETIME DEFAULT CURRENT_TIMESTAMP
) DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 1;

INSERT INTO users VALUES (1, 'Alice', 25, NOW());
SELECT * FROM users;
```

## 图形界面工具

### 1. DBeaver配置

#### 下载和安装
```bash
# 下载地址
https://dbeaver.io/download/

# 支持的操作系统
- Windows 10/11
- macOS 10.14+  
- Linux (Ubuntu 18.04+)
```

#### 连接配置步骤

1. **创建新连接**
```
文件 -> 新建 -> 数据库连接 -> MySQL
```

2. **配置连接参数**
```
主机: localhost
端口: 9030  
数据库: (空或information_schema)
用户名: root
密码: (空)
```

3. **高级设置**
```
Driver properties:
- useSSL: false
- allowPublicKeyRetrieval: true
- serverTimezone: Asia/Shanghai
```

4. **测试连接**
```
点击"测试连接"按钮验证
```

#### DBeaver使用示例

```sql
-- 在DBeaver SQL编辑器中执行
-- 查看所有数据库
SHOW DATABASES;

-- 查看表结构
DESCRIBE your_table_name;

-- 执行查询
SELECT * FROM information_schema.tables 
WHERE table_schema = 'test_db';

-- 查看执行计划
EXPLAIN SELECT * FROM users WHERE age > 25;
```

### 2. DataGrip配置

#### 创建数据源
```
Database -> + -> Data Source -> MySQL
```

#### 连接配置
```
Host: localhost
Port: 9030
User: root  
Password: (空)
Database: information_schema

Advanced:
- serverTimezone: Asia/Shanghai
- useSSL: false
```

#### DataGrip特色功能

```sql
-- 智能代码补全
SELECT u.name, u.age 
FROM users u  -- 自动补全表别名
WHERE u.age > 25; -- 智能提示字段

-- 查询历史
-- DataGrip自动保存查询历史

-- 数据库导航
-- 左侧面板显示数据库结构树

-- SQL格式化
-- Ctrl+Alt+L 格式化SQL代码
```

### 3. MySQL Workbench配置

#### 连接设置
```
Connection Method: Standard (TCP/IP)
Hostname: localhost  
Port: 9030
Username: root
Password: (空存储)

Advanced -> Others:
useSSL=0
allowPublicKeyRetrieval=true
```

#### 使用注意事项
```sql
-- MySQL Workbench可能不完全兼容StarRocks
-- 建议使用基本功能：
-- 1. 连接和查询
-- 2. 表结构查看
-- 3. 数据浏览

-- 不建议使用的功能：
-- 1. 表设计器（StarRocks语法差异）
-- 2. 数据建模工具
-- 3. 服务器管理功能
```

### 4. Adminer Web界面

```bash
# 启动Adminer（已包含在docker-compose中）
docker-compose --profile tools up -d adminer

# 访问Web界面
http://localhost:8080

# 登录信息
系统: MySQL
服务器: starrocks-fe:9030  
用户名: root
密码: (空)
数据库: (空)
```

## 编程语言连接

### 1. Java (JDBC)

#### Maven依赖
```xml
<dependency>
    <groupId>mysql</groupId>
    <artifactId>mysql-connector-java</artifactId>
    <version>8.0.33</version>
</dependency>
```

#### 连接示例
```java
import java.sql.*;

public class StarRocksConnection {
    private static final String URL = "jdbc:mysql://localhost:9030/test_db?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Shanghai";
    private static final String USER = "root";
    private static final String PASSWORD = "";
    
    public static void main(String[] args) {
        try {
            // 建立连接
            Connection conn = DriverManager.getConnection(URL, USER, PASSWORD);
            System.out.println("连接成功！");
            
            // 执行查询
            Statement stmt = conn.createStatement();
            ResultSet rs = stmt.executeQuery("SELECT * FROM users LIMIT 10");
            
            // 处理结果
            while (rs.next()) {
                int id = rs.getInt("id");
                String name = rs.getString("name");
                int age = rs.getInt("age");
                System.out.println(String.format("ID: %d, Name: %s, Age: %d", id, name, age));
            }
            
            // 关闭连接
            rs.close();
            stmt.close();
            conn.close();
            
        } catch (SQLException e) {
            e.printStackTrace();
        }
    }
}
```

#### 连接池配置（HikariCP）
```java
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

// 连接池配置
HikariConfig config = new HikariConfig();
config.setJdbcUrl("jdbc:mysql://localhost:9030/test_db?useSSL=false&serverTimezone=Asia/Shanghai");
config.setUsername("root");
config.setPassword("");
config.setMaximumPoolSize(20);
config.setMinimumIdle(5);
config.setConnectionTimeout(30000);
config.setIdleTimeout(600000);
config.setMaxLifetime(1800000);

HikariDataSource dataSource = new HikariDataSource(config);
```

### 2. Python

#### 安装依赖
```bash
pip install PyMySQL pandas sqlalchemy
```

#### 连接示例
```python
import pymysql
import pandas as pd
from sqlalchemy import create_engine

# 基础连接
def connect_starrocks():
    connection = pymysql.connect(
        host='localhost',
        port=9030,
        user='root',
        password='',
        database='test_db',
        charset='utf8mb4',
        cursorclass=pymysql.cursors.DictCursor
    )
    return connection

# 查询示例
def query_users():
    conn = connect_starrocks()
    try:
        with conn.cursor() as cursor:
            sql = "SELECT * FROM users WHERE age > %s"
            cursor.execute(sql, (25,))
            result = cursor.fetchall()
            return result
    finally:
        conn.close()

# 使用pandas
def query_with_pandas():
    engine = create_engine(
        'mysql+pymysql://root:@localhost:9030/test_db?charset=utf8mb4'
    )
    df = pd.read_sql('SELECT * FROM users', engine)
    return df

# 批量插入
def batch_insert(data):
    conn = connect_starrocks()
    try:
        with conn.cursor() as cursor:
            sql = "INSERT INTO users (id, name, age) VALUES (%s, %s, %s)"
            cursor.executemany(sql, data)
        conn.commit()
    finally:
        conn.close()

# 使用示例
if __name__ == "__main__":
    # 查询数据
    users = query_users()
    print("Users:", users)
    
    # 使用pandas查询
    df = query_with_pandas()
    print("DataFrame shape:", df.shape)
    
    # 批量插入
    sample_data = [
        (101, 'Tom', 28),
        (102, 'Jerry', 32),
        (103, 'Mike', 29)
    ]
    batch_insert(sample_data)
    print("批量插入完成")
```

### 3. Node.js

#### 安装依赖
```bash
npm install mysql2
```

#### 连接示例
```javascript
const mysql = require('mysql2/promise');

// 创建连接池
const pool = mysql.createPool({
    host: 'localhost',
    port: 9030,
    user: 'root',
    password: '',
    database: 'test_db',
    waitForConnections: true,
    connectionLimit: 10,
    queueLimit: 0,
    timezone: '+08:00'
});

// 查询示例
async function queryUsers() {
    try {
        const [rows, fields] = await pool.execute(
            'SELECT * FROM users WHERE age > ?', 
            [25]
        );
        console.log('查询结果:', rows);
        return rows;
    } catch (error) {
        console.error('查询失败:', error);
        throw error;
    }
}

// 插入数据
async function insertUser(id, name, age) {
    try {
        const [result] = await pool.execute(
            'INSERT INTO users (id, name, age) VALUES (?, ?, ?)',
            [id, name, age]
        );
        console.log('插入成功:', result);
        return result;
    } catch (error) {
        console.error('插入失败:', error);
        throw error;
    }
}

// 事务示例
async function transferData() {
    const connection = await pool.getConnection();
    try {
        await connection.beginTransaction();
        
        await connection.execute('INSERT INTO users (id, name, age) VALUES (?, ?, ?)', [201, 'User1', 30]);
        await connection.execute('INSERT INTO users (id, name, age) VALUES (?, ?, ?)', [202, 'User2', 35]);
        
        await connection.commit();
        console.log('事务提交成功');
    } catch (error) {
        await connection.rollback();
        console.error('事务回滚:', error);
    } finally {
        connection.release();
    }
}

// 使用示例
(async () => {
    await queryUsers();
    await insertUser(104, 'John', 27);
    await transferData();
    
    // 关闭连接池
    await pool.end();
})();
```

### 4. Go语言

#### 依赖安装
```bash
go mod init starrocks-demo
go get github.com/go-sql-driver/mysql
```

#### 连接示例
```go
package main

import (
    "database/sql"
    "fmt"
    "log"
    "time"
    
    _ "github.com/go-sql-driver/mysql"
)

type User struct {
    ID         int       `json:"id"`
    Name       string    `json:"name"`
    Age        int       `json:"age"`
    CreateTime time.Time `json:"create_time"`
}

func main() {
    // 连接数据库
    dsn := "root:@tcp(localhost:9030)/test_db?charset=utf8mb4&parseTime=True&loc=Local"
    db, err := sql.Open("mysql", dsn)
    if err != nil {
        log.Fatal("连接失败:", err)
    }
    defer db.Close()
    
    // 测试连接
    if err := db.Ping(); err != nil {
        log.Fatal("Ping失败:", err)
    }
    fmt.Println("连接成功!")
    
    // 配置连接池
    db.SetMaxOpenConns(25)
    db.SetMaxIdleConns(10)
    db.SetConnMaxLifetime(5 * time.Minute)
    
    // 查询示例
    users, err := queryUsers(db)
    if err != nil {
        log.Fatal("查询失败:", err)
    }
    
    for _, user := range users {
        fmt.Printf("User: %+v\n", user)
    }
    
    // 插入示例
    err = insertUser(db, 105, "Alice Go", 28)
    if err != nil {
        log.Fatal("插入失败:", err)
    }
}

func queryUsers(db *sql.DB) ([]User, error) {
    query := "SELECT id, name, age, create_time FROM users WHERE age > ?"
    rows, err := db.Query(query, 25)
    if err != nil {
        return nil, err
    }
    defer rows.Close()
    
    var users []User
    for rows.Next() {
        var user User
        err := rows.Scan(&user.ID, &user.Name, &user.Age, &user.CreateTime)
        if err != nil {
            return nil, err
        }
        users = append(users, user)
    }
    
    return users, nil
}

func insertUser(db *sql.DB, id int, name string, age int) error {
    query := "INSERT INTO users (id, name, age, create_time) VALUES (?, ?, ?, NOW())"
    _, err := db.Exec(query, id, name, age)
    return err
}
```

## 连接故障排查

### 1. 常见错误及解决方案

#### 错误1: Connection refused
```bash
# 错误信息
ERROR 2003 (HY000): Can't connect to MySQL server on 'localhost' (10061)

# 解决方案
1. 检查StarRocks服务是否启动
   docker-compose ps

2. 检查端口是否正确
   netstat -tlnp | grep 9030

3. 检查防火墙设置
   sudo ufw status
```

#### 错误2: Access denied
```bash
# 错误信息
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)

# 解决方案
1. 确认用户名密码正确
2. 检查用户权限
   SHOW GRANTS FOR 'root'@'%';

3. 重置root密码（如需要）
   SET PASSWORD FOR 'root'@'%' = PASSWORD('new_password');
```

#### 错误3: SSL连接错误
```bash
# 错误信息
javax.net.ssl.SSLException: closing inbound before receiving peer's close_notify

# 解决方案
在连接字符串中添加：
useSSL=false&allowPublicKeyRetrieval=true
```

### 2. 连接测试脚本

```bash
#!/bin/bash
# test_connection.sh

echo "测试StarRocks连接..."

# 测试端口连通性
echo "1. 测试端口连通性..."
nc -zv localhost 9030
if [ $? -eq 0 ]; then
    echo "✓ 端口9030可访问"
else
    echo "✗ 端口9030不可访问"
    exit 1
fi

# 测试MySQL协议连接
echo "2. 测试MySQL协议连接..."
mysql -h localhost -P 9030 -u root -e "SELECT 1;" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✓ MySQL协议连接成功"
else
    echo "✗ MySQL协议连接失败"
    exit 1
fi

# 测试基础查询
echo "3. 测试基础查询..."
mysql -h localhost -P 9030 -u root -e "SHOW DATABASES;" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✓ 基础查询正常"
else
    echo "✗ 基础查询失败"
    exit 1
fi

echo "所有连接测试通过！"
```

### 3. 性能监控

```sql
-- 查看当前连接数
SHOW PROCESSLIST;

-- 查看连接统计
SHOW STATUS LIKE 'Connections';
SHOW STATUS LIKE 'Threads_connected';

-- 查看慢查询
SHOW VARIABLES LIKE 'slow_query_log';
SHOW STATUS LIKE 'Slow_queries';

-- 查看缓存命中率
SHOW STATUS LIKE '%cache%';
```

## 最佳实践

### 1. 连接池配置
- **最大连接数**: 根据并发量设置，一般10-50个
- **最小连接数**: 保持5-10个空闲连接
- **连接超时**: 设置合理的超时时间
- **连接验证**: 定期验证连接有效性

### 2. 安全建议
- **创建专用用户**: 不要使用root用户连接应用
- **权限最小化**: 只授予必要的数据库权限
- **网络隔离**: 限制访问来源IP
- **SSL加密**: 生产环境启用SSL连接

### 3. 监控告警
- **连接数监控**: 防止连接数过多
- **慢查询监控**: 及时发现性能问题
- **错误日志监控**: 监控连接错误和异常

## 小结

StarRocks兼容MySQL协议，可以使用各种MySQL客户端工具连接：

1. **命令行工具**: mysql客户端，适合运维和调试
2. **图形界面**: DBeaver、DataGrip，适合开发和管理
3. **编程接口**: JDBC、PyMySQL等，适合应用开发
4. **Web界面**: Adminer，适合轻量级管理

选择合适的连接工具可以提高开发效率和运维便利性。

---

## 📖 导航

[🏠 返回主页](../../README.md) | [⬅️ 上一页](installation-docker.md) | [➡️ 下一页](first-etl.md)

---