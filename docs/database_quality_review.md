# 第九节补充设计审查

本轮以原有 29 张表为最终结构。新增结构核对、行为回归和隔离验证入口。原表关系及字段定义见 [E-R 图](er_diagram.mmd) 和 [数据字典](data_dictionary.md)。

## 要求与交付

| 要求 | 已有实现与本轮补充 |
| --- | --- |
| 1. 退回、修改和重提 | 原用例覆盖主编退回微信预览。本轮复现老师二审退回、部长转回剪辑人员、修改后独立成版并重新审核。核对前版、意见、交接和绑定素材 |
| 2. 职务变化及退出后的历史查询 | 新用例先将虚构主编调整为部员，再办理退出。核对原审核级别、人员、原任期、审核时的任职区间、意见和工作量 |
| 3. 大文件外部存储 | 沿用 `asset` 中的文件键、类型、SHA-256 等元数据，视频内容放在外部。新增字段及元数据断言 |
| 4. 共享素材删除 | 新用例验证两个项目引用同一个素材，移除一个项目关联后另一个关联仍保护元数据；历史版本也能独立保护元数据 |
| 5. 异常业务与并发 | 主编退回、部长独剪、退出后重新分配、推文和视频独立、相机冲突及同一任务更新由原用例及双会话脚本验证。此次补齐老师退回 |
| 6. 技术决策 | 记录审核历史、文件生命周期、逐对象验证、按环境部署的理由 |
| 7. 对象测试 | 为每个视图、触发器、索引和约束提供结构断言；视图和触发器另有业务用例，所有具名 CHECK 均有实际失败用例 |
| 8. 测试先行 | 原项目先在临时实例从空库建表和测试，再部署到 MySQL80。本轮从另一空实例验证补充内容 |
| 9. 保密 | 虚构人员、示例域名和文件键用于测试。管理员凭据使用客户端登录路径管理，文件访问凭据由部署环境管理 |
| 10. 操作记录 | 保留导入、基础测试、逐对象测试、补充用例和双会话日志。本轮执行命令及结果见 [验证记录](database_verification.md) |
| 11. 正式变更确认 | 初版正式部署发生在本条要求提出前。本轮正式库操作记录为空。此后正式库建库或结构变更以设计审查和用户确认为前置条件 |

## 设计决策

### 审核历史按事件发生时间查询

`submission.previous_id` 和 `version_no` 建立版本链。`review_record` 固定登记签审级别、审核人员、审核当时的成员任期、时间、决定和意见。当前职务用于授权新审核，查询历史时采用本条审核的 `stage`。需要查历史组织职务时，用 `reviewed_at` 匹配当时的任职区间。外部老师的 `membership_id` 可以为空，因此用左连接。

```sql
SELECT s.project_id, s.version_no, r.stage, p.person_code, r.reviewer_id,
       r.membership_id, mp.position_code AS position_at_review,
       r.decision, r.feedback, r.reviewed_at
FROM review_record r
JOIN submission s ON s.id = r.submission_id
JOIN person p ON p.id = r.reviewer_id
LEFT JOIN membership_position mp ON mp.membership_id = r.membership_id
  AND mp.starts_at <= r.reviewed_at
  AND (mp.ends_at IS NULL OR mp.ends_at > r.reviewed_at)
WHERE p.person_code = 'DEMO-CHIEF'
ORDER BY r.reviewed_at, r.id;
```

### 共享引用和外部归档

维护共享素材时，为已有的文件元数据行增加 `project_asset` 关联。已送审版本通过 `submission_asset` 保留引用。两类引用的外键均限制删除；关联本身不代表外部文件的删除操作。操作前可用下列查询盘点同一文件键的全部元数据行及引用，示例文件键来自补充用例。

```sql
SELECT a.id, a.uri,
       (SELECT COUNT(*) FROM project_asset pa WHERE pa.asset_id = a.id) AS project_refs,
       (SELECT COUNT(*) FROM submission_asset sa WHERE sa.asset_id = a.id) AS version_refs
FROM asset a
WHERE a.uri = 'files/qa/original.mp4';
```

当前运行 SQL 角色通过存储过程登记素材，物理文件采用保留策略。外部文件存储接入时，项目服务账号应使用授予读取和上传权限的凭据，并由独立角色管理存储生命周期。数据库外键可保护元数据，外部存储的删除权限须在存储部署中落实。任何未来的物理清理流程都应覆盖所有文件键引用、历史版本和并发新增关联。文件访问凭据留在运行环境的凭据存储。

### 逐对象断言

[结构核对 SQL](../database/09_schema_contract_tests.sql) 的每一行期望定义对应一个对象。预期和实测定义相同才输出 `PASS`，缺失、定义变化或未登记的新对象均输出 `FAIL`。

| 对象 | 数量 | 核对的预期结果 |
| --- | ---: | --- |
| 视图 | 5 | 对象存在并采用预期安全方式；业务查询返回下表的样例值 |
| 触发器 | 24 | 事件、时机和目标表匹配；行为断言见下表 |
| 索引 | 88 | 表、名称、有序列、可见性、BTREE 类型和唯一性匹配，含 12 个显式普通索引及键约束相关索引 |
| 主键 / UNIQUE | 29 / 25 | 名称和顺序列匹配；重复键场景报 1062 |
| 外键 | 47 | child/parent 列映射一致，更新和删除均限制；错误引用报 1452，删除被引用素材报 1451 |
| CHECK | 24 | 逐项启用；[补充 SQL](../database/10_quality_regressions.sql) 分别触发 3819，并校验报错中的约束名 |
| NOT NULL | 137 | 每个要求必填的列都实际是 `IS_NULLABLE = NO` |

索引核对检验定义及列序。演示库数据量较小，实时计划可因数据分布与统计信息而变化。

### 视图和触发器的行为证据

下表的用例标签可在 [基础测试 SQL](../database/07_test_database.sql) 或 [补充测试 SQL](../database/10_quality_regressions.sql) 搜索，也对应留存日志。

| 视图 | 用例或预期结果 |
| --- | --- |
| `v_current_members` | 基础案例有 8 位在任成员；Q13 调职后显示部员，Q14 退出后移出 |
| `v_member_workload` | 实际撰稿人 75 分钟，退出人员历史摄影 45 分钟；Q14 保留退出主编的审核计数 |
| `v_pending_reviews` | 部长独剪的示例待三审；Q03 被退回版本离开待审列表 |
| `v_campaign_progress` | 运动会推文已发布、摄影完成、视频进行中，总进度 66.67%；Q07 仅已通过的重提交发布 |
| `v_equipment_status` | 自有设备归还，借入设备处于在用或逾期状态 |

| 触发器 | 操作及预期结果 |
| --- | --- |
| `bi_membership_period` | 插入重叠任期报 1644，提示 `periods overlap` |
| `bu_membership_period` | 将退期回填至已发生审核的时间报 1644 |
| `ai_membership_period` | 合法加入写入 `MEMBERSHIP_ADD` |
| `au_membership_period` | 退出停止账号、结束开放分配，写入 `MEMBERSHIP_EXIT` |
| `bi_membership_position` | 插入重叠职位任期报 1644 |
| `bu_membership_position` | 覆盖职务代码报 1644，合法结束后可追加新任职 |
| `ai_account` | 新账号记录 `ACCOUNT_ADD`，审计只含启用状态 |
| `au_account` | 停用记录 `ACCOUNT_CHANGE`，审计含启用状态和哈希变更标记 |
| `ai_account_role` | 账号授权产生 `ACCOUNT_ROLE_GRANT` |
| `ad_account_role` | 撤销账号授权产生 `ACCOUNT_ROLE_REVOKE` |
| `ai_role_permission` | 角色授予权限产生 `ROLE_PERMISSION_GRANT` |
| `ad_role_permission` | 角色撤销权限产生 `ROLE_PERMISSION_REVOKE` |
| `bu_work_item` | 修订号未增加时更新任务报 1644 |
| `ai_work_item` | 新任务记录初始 `TODO` 和版本 0 |
| `au_work_item` | 状态迁移写入历史和 `WORK_STATUS`，事务回滚撤销记录 |
| `bi_work_assignment` | 退出人员和超过写作、排版或独剪名额时报 1644 |
| `bu_work_assignment` | 更改既有指派者报 1644 |
| `bi_work_contribution` | 任期外的贡献报 1644 |
| `bi_publication` | 退回或未完成三审时发布报 1644 |
| `ai_publication` | 审批通过后发布写入 `PUBLISH` |
| `bi_equipment_usage` | 同机预约重叠时报 1644，首尾相接允许 |
| `bu_equipment_usage` | 归还后改写预约时段报 1644 |
| `bu_audit_log` | 更新审计报 1644 |
| `bd_audit_log` | 删除审计报 1644 |
