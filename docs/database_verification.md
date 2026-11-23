# 数据库实验验证记录

验证日期为 2026-11-18，北京时间。操作系统为 Windows 11 25H2，Build 26200.9457。原工作区为空，安装目录中存在 MySQL Community Server 8.0.46、MySQL Workbench 8.0 和 MySQL Shell 8.0。

## 本机 MySQL80 部署

| 检查项 | 实际结果 |
| --- | --- |
| `sc.exe query MySQL80` | `STATE 4 RUNNING` |
| `mysqld.exe --version` | MySQL Community Server 8.0.46 Win64 |
| 连接 `127.0.0.1:3306` | 首次无凭据探测返回 `ERROR 1045 (28000)`。配置 `boya_admin` 后认证成功 |
| 实际服务及 Binlog | 服务端版本 8.0.46，`log_bin = 1`，`binlog_format = ROW` |
| 部署前检查 | 该实例原先没有 `boya_media_center` |
| 正式建库和导入 | 按脚本顺序创建 `boya_media_center`，部署独立运行角色并导入虚构案例 |
| 正式验证 | 52 项断言全部通过，包含 29 张表、47 条外键、5 个视图、24 个触发器和 22 个过程 |
| 正式演示状态 | 微信推文已发布，独立摄影已完成，视频仍在剪辑，运动会活动完成率为 66.67% |

```powershell
.\database\Invoke-BoyaDatabase.ps1 -Action Inspect
.\database\Invoke-BoyaDatabase.ps1 -Action Install
.\database\Invoke-BoyaDatabase.ps1 -Action Test
```

### 正式库全量备份及恢复

- 使用 `boya_admin` 经 TCP 导出正式库。首次导出因 `mysqldump` 不接受 `--connect-timeout` 停止，脚本修正为只给 `mysql` 传该参数后重新导出成功。
- 快照起点为 `DESKTOP-Q6P966G-bin.000002` 的 `208850`。备份及 SHA-256 清单位于本机临时目录 `C:\Users\thesun\AppData\Local\Temp\BoyaLiveRestore01a1eeed\backup`。
- 正式库快照在独立的 `BoyaLiveRestore01a1eeed` 实例恢复成功，重跑 52 项断言全部通过。恢复副本上的两组并发测试中，第二会话分别等待约 4008ms 和 3914ms 后被拒绝。恢复演练结束后已关闭该临时实例。

## 隔离实例操作与结果

使用已安装的 MySQL 8.0.46 在临时数据目录启动三个仅命名管道可访问的实例，分别用于早期 DDL 探测、最终验证和独立恢复。最终验证实例启用了 Binlog。以下结果来自最终验证和恢复实例。

| 验证 | 实际结果 |
| --- | --- |
| 清洁部署 | 执行全部部署及初始数据脚本，创建 29 张 InnoDB utf8mb4 表、47 条外键、5 个视图、24 个触发器、22 个过程 |
| 完整性 | 52 项 SQL 断言通过。无效外键报 1452、重复设备号报 1062、零分钟报 3819，写作和排版名额、部长独剪名额及人员职务检查通过 |
| 工作量与退出 | 实际撰稿人记录 75 分钟，最初被指派者无撰稿工作量。三位摄影参与者保留真实贡献，其中已退出人员保留 45 分钟，账号停用且开放指派结束。重新加入者有两条届次任期 |
| 运动会项目 | 推文 PUBLISHED，视频 IN_PROGRESS，独立摄影 COMPLETED，活动完成率 66.67% |
| 送审 | 推文保留四个版本。主编退回部长，部长转原排版员。部长独剪从主编开始；审核期间开启三审后，二审将其转入待三审。部员协作版经四个级别批准后登记发布 |
| 视图与触发器 | 五个视图实查成功。工作状态变化自动登记历史，未完成三审时发布被拦截，退出触发账号停用 |
| SQL 角色及审计 | 用独立低权限 MySQL 账号实查，成员视图可查，账号表读取、审计表 UPDATE 和 DELETE 均被 MySQL 拒绝；管理员直接变更审计行时触发器也拒绝 |
| 相机 | 自有设备可查到归还历史，借入设备可查到领用人与任务。重叠预约被拦截，首尾相接的区间允许写入 |
| 事务回滚 | 工作状态、修订号、触发器履历和试写相机预约在回滚后恢复 |
| 双会话更新 | 第二个连接等待约 3996ms 后收到 `Work version conflict`。首个更新结果为 `IN_PROGRESS:1` |
| 双会话预约 | 两个不同项目同时争用同一相机。第二个连接等待约 3922ms 后收到 `Camera reservation overlaps`，相机只保留首个预约 |
| 全量恢复 | 独立实例实导成功，恢复 11 人及 2 条发布记录，回放前时间点测试标记为 0。文件归档恢复了 1 个独立校验样本，SHA-256 一致 |
| 时间点恢复 | `boya-bin.000001` 从位置 `208155` 开始，在 `208738` 停止。恢复结果包含 `PITR-KEEP`，排除了截止点后的 `PITR-SKIP`。恢复实例再次通过 52 项断言 |
| 已有库保护 | 在已初始化实例上重试安装与恢复，两个脚本均在写入前停止 |

### 实际使用的项目命令

```powershell
.\database\Invoke-BoyaDatabase.ps1 -Action Install -PipeName BoyaVerify01a1eeed
.\database\Invoke-BoyaDatabase.ps1 -Action Test -PipeName BoyaVerify01a1eeed
.\database\New-BoyaBackup.ps1 -BackupDirectory $backupDir -AssetRoot $fixtureDir -PipeName BoyaVerify01a1eeed
.\database\Restore-BoyaBackup.ps1 -BackupDirectory $backupDir -RestoreAssetRoot $restoredFixtureDir -PipeName BoyaRestore01a1eeed
.\database\Invoke-BoyaDatabase.ps1 -Action Test -PipeName BoyaRestore01a1eeed
.\database\Test-BoyaConcurrency.ps1 -PipeName BoyaRestore01a1eeed
```

初次探测时，沙箱阻止了 InnoDB 创建阶段的文件重命名，通过授权在临时目录独立初始化后解决。PITR 首次取停止点时，PowerShell 同时收集了后续空列，改用确切偏移后成功回放。课程复现可按 [备份恢复命令](../database/08_backup_restore.md) 操作。

实际测试版本为 8.0.46。演示素材路径和外部链接为虚构值，文件恢复以独立字节样本验证。正式部署使用已有的服务配置，其他数据库保持原样。

## 第九节补充验证

2026-11-18 在 MySQL 8.0.46 的全新临时实例中执行以下命令。实例采用独立数据目录和本机命名管道，所有额外用例均在该实例运行，退出时关闭实例。正式库本轮操作记录为空。

```powershell
& 'E:\STUDY\boyashujuku\database\Test-BoyaQuality.ps1'
```

| 阶段 | 实测结果和留存日志 |
| --- | --- |
| 空库安装 | 依次导入 9 个 SQL 文件，独立实例创建 `boya_media_center`。[安装日志](quality_evidence/install.log) |
| 基础测试 | 52 项通过。[基础日志](quality_evidence/baseline.log) |
| 逐对象检查 | 379 项通过，覆盖 5 个视图、24 个触发器、88 个索引、29 个主键、25 个 UNIQUE、47 个外键、24 个 CHECK 和 137 个必填列。日志列依次为结果、类别、表名、对象名、预期、实际。[对象结果](quality_evidence/schema-objects.tsv) |
| 补充行为 | 55 项通过，包含老师退回重提、转岗及退出后查审核、共享素材的 1451 限制、所有 24 个具名 CHECK 的 3819 检测。[补充结果](quality_evidence/quality-regressions.tsv) |
| 双会话 | 旧任务版本等待约 3998ms 后被拒绝，相机重复分配等待约 3890ms 后被拒绝。首个状态保留 `IN_PROGRESS:1`，预约仅保留一条。[并发日志](quality_evidence/concurrency.log) |

设计理由、最终结构链接及每个视图和触发器的预期见 [补充设计审查](database_quality_review.md)。
