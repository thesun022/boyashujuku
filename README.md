# 山大博雅传媒中心综合业务管理系统

Web 系统包含登录与权限、首页仪表盘、人员管理、宣传活动与项目、任务、素材、推文、视频、审核、相机、统计和系统管理。中文页面通过同源 API 操作 MySQL，可以用多个身份完成分配任务、上传素材、退回重提、审核和发布。

## 在本机打开演示

在 Windows 的 PowerShell 中运行以下两行。

```powershell
Set-Location -LiteralPath 'E:\STUDY\boyashujuku'
& '.\.venv\Scripts\python.exe' -X utf8 -m tests.web_lab --preview
```

按提示为本次演示账号设置一个 12 至 256 字符的密码。程序会建立独立 MySQL 演示实例，准备好后显示网址。默认地址为 [http://127.0.0.1:8080/login](http://127.0.0.1:8080/login)。用下面任一账号和刚设置的密码登录。终端按 Ctrl+C 结束演示。如果 8080 已被占用，启动时可加 `--port 8081`。

| 演示账号 | 可体验的内容 |
| --- | --- |
| `demo-writer` | 部员，查看分给本人的撰稿任务 |
| `demo-layout`、`demo-photo-a`、`demo-video` | 排版、摄影或剪辑成员，登记参与、上传项目素材及提交获分配的成果 |
| `demo-minister` | 部长，创建项目、分配任务、纠正误登工时、初审推文和发布所管理的视频 |
| `demo-chief` | 主编，从工作台审阅作品，登记本人负责的推文正式发布 |
| `demo-second` | 二审人，查看分给本人的待审核成果 |
| `demo-third` | 三审人，查看等待三审的部长剪辑样例 |
| `demo-web-admin` | 独立管理员账号，管理人员、账号、系统角色、日志并查看备份恢复说明 |

演示数据使用虚构身份。每次启动时都会重新初始化，预设账号只在本次临时实例中生效。可按 [角色与操作指南](docs/web_operator_guide.md) 用不同浏览器窗口切换身份。

## 依赖安装

如需重新建立开发环境，在项目根目录运行下列命令。使用明确的 Python 可执行路径以适应该机的 Anaconda 安装，也可以替换为其他受支持的 Python 3.14 解释器。

```powershell
& 'E:\anaconda\python.exe' -m venv --without-pip .venv
& 'E:\anaconda\python.exe' -m pip --python .venv install -r requirements-dev.txt
```

Web 运行依赖见 `requirements.txt`，测试依赖增加 pytest 和 Playwright，浏览器测试使用本机 Microsoft Edge。Bootstrap 样式和 Chart.js 随工程提供。

## 验证

```powershell
& '.\.venv\Scripts\python.exe' -X utf8 -m tests.web_lab
```

该命令在独立 MySQL 8.0.46 实例中执行基础数据库断言，依次安装 Web 扩展 11 至 14，再运行接口和 Edge 浏览器测试。第 14 号迁移加入工时纠错、推文发布权限和发布结项。[完整 Web 验收记录](docs/web_final_verification.md)

## 连接已准备的开发库

对已有开发库，由维护账号按 `11 → 12 → 13 → 14` 安装尚未应用的 Web 扩展，并给专用应用账号授予 `boya_web_auth`。应用从进程环境读取 `BOYA_DB_USER`、`BOYA_DB_PASSWORD` 和至少 32 字符的随机 `BOYA_SECRET_KEY`，可通过 `BOYA_DB_HOST`、`BOYA_DB_PORT` 指定目标。使用 HTTPS 时设 `BOYA_HTTPS=1`。材料目录由 `BOYA_ASSET_ROOT` 配置，视频上限由 `BOYA_VIDEO_MAX_MIB` 配置，默认 512 MiB。详细步骤见 [部署与迁移说明](docs/web_deployment.md)。配置就绪后启动服务。

```powershell
& '.\.venv\Scripts\waitress-serve.exe' --host 127.0.0.1 --port 8080 --call boya_web:create_app
```

在开发库中可用以下交互命令初始化管理员。端口 13306 与维护账号名称是示例，应换成已准备的开发实例配置。命令会分别提示输入 Web 密码和 MySQL 维护密码。

```powershell
& '.\.venv\Scripts\python.exe' -m boya_web.bootstrap --port 13306 --db-user db_maint --person-code WEB-ADMIN --username web-admin --display-name '系统管理员'
```

已经存在账号时，可对同一人员和账号明确指定 `--reset-password` 来替换 Web 密码。角色及启用状态沿用现值。现有 MySQL80 项目库的 Web 扩展和应用账号在审阅后另行部署。
