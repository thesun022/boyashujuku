# 全量备份、文件归档和时间点恢复

## 检查及全量备份

部署账户运行以下命令，核实目标实例版本、运行时 `log_bin` 和 `binlog_format`。

```powershell
.\database\Invoke-BoyaDatabase.ps1 -Action Inspect
.\database\New-BoyaBackup.ps1 -BackupDirectory 'E:\BoyaBackups\full-001' -AssetRoot 'E:\BoyaAssets'
```

备份目录须是新目录且位于素材目录之外。脚本使用 InnoDB 一致性快照，导出目标库的表、数据、视图、存储过程和触发器。启用 Binlog 时，导出中记录起始日志文件和偏移，备份账号需要相应的日志读取及备份权限。MySQL 8.0 旧版客户端使用 `--master-data=2`。关闭 Binlog 时仍可全量恢复，时间点恢复等待管理员安排后续维护。

文件采用相对路径和 SHA-256 清单同步归档，覆盖 Word、照片、视频等本地文件。文件存储应使用不可变键并冻结物理删除；备份窗口暂停相关 DDL 与素材迁移，核对快照引用的文件均已归档。素材在对象存储时，以存储版本和清单做独立快照。外部预览的可用性由对应平台决定，数据库备份保存其历史 URL 及审批信息。虚构案例的素材 URI 是占位值。

建议每天一次全量备份，持续复制 Binlog，保存文件及数据库快照至独立备份存储。至少保留一份全量基线与从基线到目标时间的连续日志。保护备份目录的访问权限，定期校验备份清单并演练。DDL、数据库账户、授予给后端账号的 SQL 角色以及 DEFINER 主体需纳入实例级部署记录。

Binlog 可用单独的日志归档账号，从 `manifest.json` 记录的日志文件开始复制。先备好输出目录，再以实际文件名替换示例名。以下命令持续运行，应监控断线并从最后已校验的文件重新衔接。保留完整源文件名称及顺序，定期确认日志与全量快照间没有缺口。

```powershell
& 'E:\MySQL\sever\bin\mysqlbinlog.exe' --login-path=boya_binlog --read-from-remote-server --raw --stop-never --result-file='E:/BoyaBackups/binlogs/' 'boya-bin.000001'
```

[MySQL 全量备份参数](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html) · [mysqlbinlog 日志归档](https://dev.mysql.com/doc/refman/8.0/en/mysqlbinlog.html)

## 在独立实例恢复全量快照

为独立实例设置 `boya_restore` 登录路径，连接到该实例实际端口。确认其 `information_schema.schemata` 中没有 `boya_media_center`。导入前保留可用的 DEFINER 主体及授予权限，并准备全新的文件恢复目录。

```powershell
& 'E:\MySQL\sever\bin\mysql_config_editor.exe' set --login-path=boya_restore --host=127.0.0.1 --port=3307 --user=root --password
.\database\Restore-BoyaBackup.ps1 -BackupDirectory 'E:\BoyaBackups\full-001' -RestoreAssetRoot 'E:\BoyaRestoredAssets'
```

端口 `3307` 为示例，须指向另一个已准备好的实例。脚本验证 SQL 和文件清单后再建库，流式导入快照，并核验恢复后的文件哈希。MySQL 全局账号和角色需按部署记录恢复。若恢复实例尚未定义运行角色，可以用该实例的管理账号在 `boya_media_center` 执行 `06c_security_roles.sql` 恢复角色与授权。

恢复后核对表、视图和例行程序数量，抽样比对活动、发布、审核链以及文件哈希。恢复的是演示库时可运行以下命令。

```powershell
.\database\Invoke-BoyaDatabase.ps1 -Action Test -LoginPath boya_restore
```

## 回放到指定时间

1. 从 `manifest.json` 的 `BinlogCoordinate` 获取全量快照起点，用输入日志的副本检查事件和事务边界。在指定时间内最后一条要保留的完整事务之后记录停止偏移。
2. 以下示例使用本次单日志演练的数据。对于转动过的日志，将全部连续日志按顺序交给同一次 `mysqlbinlog`，起点作用于第一个文件，终点作用于最后一个文件。共享实例要先确认日志格式与过滤范围。行日志可按数据库筛选，含语句日志或跨库操作时应逐段核对。示例位置仅适用于本次演练的日志文件。
3. 导入前确认目标登录路径指向已恢复的隔离实例、确认回放脚本内容和截止点，再一次性传给同一 MySQL 会话。回放 SQL 含 Binlog 事件，需要兼容的 MySQL 版本和管理权限。

```powershell
$boyaBin = 'E:\MySQL\sever\bin'
$boyaReplay = 'E:\BoyaBackups\replay-001.sql'
& "$boyaBin\mysqlbinlog.exe" --start-position=208155 --stop-position=208738 --database=boya_media_center "--result-file=$boyaReplay" 'E:\BoyaBackups\binlogs\boya-bin.000001'
if ($LASTEXITCODE -ne 0) { throw 'mysqlbinlog failed' }
$boyaImport = Start-Process -FilePath "$boyaBin\mysql.exe" -NoNewWindow -Wait -PassThru -RedirectStandardInput $boyaReplay -ArgumentList '--login-path=boya_restore','--protocol=TCP','--binary-mode=1','--database=boya_media_center'
if ($boyaImport.ExitCode -ne 0) { throw 'Binlog replay failed' }
```

以恢复点的活动代码、行数和审计记录校验事务边界，检查依赖文件的版本，确认无误后由管理员安排切换。实测见 [验证记录](../docs/database_verification.md)。[MySQL 按位置恢复](https://dev.mysql.com/doc/refman/8.0/en/point-in-time-recovery-positions.html)
