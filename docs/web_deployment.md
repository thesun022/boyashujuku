# Web 安装、迁移与恢复

Windows 本机演示和依赖安装见 [项目 README](../README.md)。演示程序自动启动独立 MySQL，正式库相关账号和结构由 DBA 在审阅后配置。

## 新实例与已有库

- 新实例先按 [数据库安装顺序](../database/README.md) 建立 29 张基础表及业务对象。加载虚构案例时，可用 `tests.web_lab` 自动化。
- 已有 `boya_media_center` 时，先核对现有数据、约束和已应用的 Web 扩展，执行带 Binlog 位点的全量备份并备份素材目录，再在恢复副本校验迁移。Web 扩展依次为 [11 认证](../database/11_web_auth.sql)、[12 仪表盘](../database/12_web_dashboard.sql)、[13 业务操作](../database/13_web_operations.sql)、[14 工时纠错与推文发布](../database/14_workflow_corrections.sql)。脚本用于一次性迁移，遇到部分应用先核对现有对象。
- 11 新增会话表 `web_session`。12 新增只读汇总过程。13 新增文件清理队列 `web_file_cleanup`、系统管理员角色和 Web 服务授权。14 新增作废工时表 `voided_work_contribution`、可发布人视图 `v_project_publishers`、纠错过程 `sp_void_contribution`，并替换发布过程 `sp_publish`。29 张基础表加这三张扩展表，共 32 张表。
- 已装到 13 的持久测试库可在暂停 Web 写入后单独执行 14，再启动新版应用。迁移保留既有工时和历史发布人的署名。已有误登工时需由项目负责人逐条核实作废。开发副本若需回退，使用升级前匹配的备份与应用版本恢复到单独实例核验，保留原库及升级后的审计记录。
- DBA 为 Web 进程创建专用的本机 MySQL 用户，授予并激活 `boya_web_auth`。管理员初始化使用 [交互命令](../README.md)，默认分配 `SYSTEM_ADMIN`。密码通过运行环境提供。该 MySQL 用户由后端进程独占，浏览器以会话登录。

## 文件与服务配置

`BOYA_ASSET_ROOT` 指向受保护的素材目录，目录位于公开静态资源之外，MySQL 仅保存相对文件键和内容哈希。Word 和图片每个文件上限为 20 MiB，视频默认 512 MiB，可通过 `BOYA_VIDEO_MAX_MIB` 调整，需同步核对 WSGI 请求体限制和可用空间。支持 DOCX、JPEG、PNG、GIF、WEBP、MP4、MOV、WebM。Word 提供文字内容预览，视频播放取决于浏览器支持的实际编码。

常用运行变量和 Waitress 启动命令见 [项目 README](../README.md)。非本机访问使用 HTTPS、反向代理和适当的环境凭据管理，启用 `BOYA_HTTPS=1`。会话不应进入公开归档或面向用户的日志。

## 发布与恢复验收

1. 在隔离副本运行 [现有备份恢复说明](../database/08_backup_restore.md)，检查数据库与独立文件备份的校验清单。
2. 使用不同账号验证首页、成员维护、媒体预览与下载、审核权限、状态冲突以及历史记录。
3. 恢复目标需重建全局 SQL 账号与角色授权。Web 会话属于当前运行环境，恢复实例使用新的会话密钥并清理已恢复的会话记录，以便用户重新登录。
4. 正式库按已确认的脚本范围和计划执行。在记录备份位置、脚本、运行结果和回退方案后启用正式应用。
