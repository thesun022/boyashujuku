# 博雅传媒中心数据库

运行环境为 MySQL 8.0.16+ 和 PowerShell 7。服务器默认工具目录为 `E:\MySQL\sever\bin`，其他安装可传入 `-ServerBin`。

## 连接和建库

首次配置时，在本机 PowerShell 运行以下命令，在 MySQL 提示符输入管理员密码。已有可用的 `boya_admin` 登录路径时，直接执行下一段检查命令。

```powershell
& 'E:\MySQL\sever\bin\mysql_config_editor.exe' set --login-path=boya_admin --host=127.0.0.1 --port=3306 --user=root --password
```

以下检查命令直接调用 MySQL 客户端，可在任意目录的 PowerShell 中运行。查询结果包含实例版本、Binlog 状态、目标库及对象数量。

```powershell
& 'E:\MySQL\sever\bin\mysql.exe' --login-path=boya_admin --protocol=TCP --table --execute="SELECT VERSION() AS mysql_version, @@global.log_bin AS binlog_enabled; SELECT SCHEMA_NAME FROM information_schema.schemata WHERE SCHEMA_NAME='boya_media_center'; SELECT TABLE_TYPE, COUNT(*) AS total FROM information_schema.tables WHERE TABLE_SCHEMA='boya_media_center' GROUP BY TABLE_TYPE;"
```

设计审查得到确认、隔离测试通过、目标实例中没有 `boya_media_center` 后，可运行以下安装命令。安装脚本再次检查目标库和 SQL 角色名，任何导入失败都会停止。出现部分安装时先查看已完成的步骤和现有对象，再准备增量修复。

```powershell
Set-Location -LiteralPath 'E:\STUDY\boyashujuku'
.\database\Invoke-BoyaDatabase.ps1 -Action Install
.\database\Invoke-BoyaDatabase.ps1 -Action Test
```

默认初始化虚构案例。案例按活动日期补登实际贡献，送审、交接和发布采用演练执行时刻。只部署结构、职务字典和权限字典时使用 `-SkipDemo`，演示断言依赖案例数据。业务连接设置 `SET SESSION time_zone = '+08:00'`，并将手工传入的日期按北京时间解释。

| 顺序 | 脚本 | 内容 |
| --- | --- | --- |
| 1 | `01_create_database.sql` | 新建目标库 |
| 2 | `02_create_tables.sql` | 表、主键、唯一约束与 CHECK |
| 3 | `03_constraints_indexes.sql` | 外键与查询索引 |
| 4 | `05_create_views.sql` | 五个业务查询视图 |
| 5 | `06_create_triggers.sql` | 写入保护及自动历史、审计 |
| 6 | `06b_create_procedures.sql` | 事务化业务入口 |
| 7 | `06c_security_roles.sql` | 新建 MySQL 运行角色并授权 |
| 8 | `04_reference_data.sql` | 组织职务、业务角色和权限 |
| 9 | `04_initial_data.sql` | 虚构案例，经业务过程写入 |
| 10 | `07_test_database.sql` | 案例断言及五个视图的演示查询 |

## 隔离质量测试

在 PowerShell 7 中调用 `Test-BoyaQuality.ps1`。脚本用临时数据目录初始化独立实例，连接限定为本机命名管道，执行建表、基础断言、[逐对象检查](09_schema_contract_tests.sql)、[补充场景](10_quality_regressions.sql)和双会话测试，最后关闭该实例并打印日志目录。

```powershell
& 'E:\STUDY\boyashujuku\database\Test-BoyaQuality.ps1'
```

[补充设计审查](../docs/database_quality_review.md)列出每个视图、触发器和约束的测试预期。补充用例会提交退回、重提及退出记录，适用于隔离测试库。

## 业务接口和权限

- 管理员维护人员、任职、权限字典和相机资产。部长等业务角色通过存储过程创建工作、指派、预约及控制进度。成员通过过程登记贡献及提交版本。审核人只能处理交接给本人的当前版本。
- 业务数据库角色 `boya_media_center_runtime` 有指定视图的 SELECT 和公用 `sp_*` 过程的 EXECUTE。这个角色用于将来受信任的后端服务账号。后端应从已认证会话取人员 ID，拒绝客户端提供的操作者字段，并绑定所有 SQL 参数，例如用驱动执行 `CALL sp_set_work_status(?, ?, ?, ?)`。后端认证需单独获准读取账号哈希字段，且严禁把哈希返回客户端。
- 数据库触发器保护审计行的更新和删除，应用 SQL 角色也没有审计表写权限。拥有 DDL 的数据库管理员仍可以管理表及触发器，请将管理员账号和备份存储独立管控。
- 写入过程自管 COMMIT 和 ROLLBACK。业务连接以自动提交方式调用单个过程。死锁或锁超时后重试整次事务。版本冲突时重新读数据再让用户确认变更。
- 演示账号的随机校验值用于数据测试。真实账号使用新生成的 Argon2id 哈希，服务端认证通过后还需检查账号启用状态。

结构与业务约定见 [数据库设计](../docs/database_design.md) 和 [业务规则](../docs/business_rules.md)。双会话脚本 `Test-BoyaConcurrency.ps1` 会在隔离实例提交独立的测试项目及预约。全量备份、独立实例恢复及 Binlog 回放见 [备份恢复说明](08_backup_restore.md)。
