# 数据字典及索引

以下定义与建表脚本一致。外键默认为 RESTRICT/NO ACTION，主键和 UNIQUE 自动建立索引。MySQL 还会为没有适用索引的外键列建立索引。

## 1 `person` 人员

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `person_code` | `VARCHAR(40)` | `NOT NULL UNIQUE` | 对内人员编号 |
| `display_name` | `VARCHAR(100)` | `NOT NULL` | 展示姓名 |
| `contact` | `VARCHAR(160)` | `NULL` | 可选联系方式 |
| `created_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 创建时间 |

## 2 `cohort` 届次

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `code` | `VARCHAR(20)` | `NOT NULL UNIQUE` | 业务编码 |
| `label` | `VARCHAR(80)` | `NOT NULL` | 业务显示名称 |
| `intake_year` | `SMALLINT UNSIGNED` | `NOT NULL` | 入届年份 |

- `CONSTRAINT ck_cohort_year CHECK (intake_year BETWEEN 1900 AND 9999)`

## 3 `membership_period` 成员任期

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `person_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 关联人员 |
| `cohort_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → cohort.id` | 关联届次 |
| `joined_at` | `DATETIME(6)` | `NOT NULL` | 任期生效时间 |
| `left_at` | `DATETIME(6)` | `NULL` | 退出生效时间，空表示开放 |
| `open_person_id` | `BIGINT UNSIGNED` | `GENERATED ALWAYS AS (IF(left_at IS NULL, person_id, NULL)) VIRTUAL` | 仅开放任期投影人员 ID，为唯一约束提供键 |

- `UNIQUE KEY uq_membership_open (open_person_id)`
- `CONSTRAINT ck_membership_dates CHECK (left_at IS NULL OR left_at > joined_at)`
- `INDEX ix_membership_period_person_dates (person_id, joined_at, left_at)`
- `INDEX ix_membership_period_cohort (cohort_id, joined_at)`

## 4 `position` 组织职务

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `code` | `VARCHAR(20)` | `PRIMARY KEY` | 业务编码 |
| `label` | `VARCHAR(60)` | `NOT NULL UNIQUE` | 业务显示名称 |
| `hierarchy_rank` | `TINYINT UNSIGNED` | `NOT NULL UNIQUE` | 数字越小代表组织层级越高 |

## 5 `membership_position` 任职时段

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `membership_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → membership_period.id` | 关联成员任期 |
| `position_code` | `VARCHAR(20)` | `NOT NULL；FK → position.code` | 关联组织职务 |
| `starts_at` | `DATETIME(6)` | `NOT NULL` | 区间起点，包含 |
| `ends_at` | `DATETIME(6)` | `NULL` | 区间终点，不包含；允许空时表示未结束 |

- `UNIQUE KEY uq_position_start (membership_id, starts_at)`
- `CONSTRAINT ck_position_dates CHECK (ends_at IS NULL OR ends_at > starts_at)`

## 6 `skill` 技能

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `code` | `VARCHAR(40)` | `NOT NULL UNIQUE` | 业务编码 |
| `label` | `VARCHAR(60)` | `NOT NULL UNIQUE` | 业务显示名称 |

## 7 `person_skill` 人员技能

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `person_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → person.id` | 关联人员 |
| `skill_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → skill.id` | 关联技能 |

- `PRIMARY KEY (person_id, skill_id)`

## 8 `account` 用户账号

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `person_id` | `BIGINT UNSIGNED` | `NOT NULL UNIQUE；FK → person.id` | 关联人员 |
| `username` | `VARCHAR(80)` | `NOT NULL UNIQUE` | 业务系统登录名 |
| `password_hash` | `VARCHAR(255)` | `CHARACTER SET ascii COLLATE ascii_bin NOT NULL` | Argon2id PHC 编码 |
| `enabled` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | 账号授权开关 |
| `created_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 创建时间 |

- `CONSTRAINT ck_account_enabled CHECK (enabled IN (0, 1))`
- `CONSTRAINT ck_account_hash CHECK (password_hash LIKE '$argon2id$v=19$m=%')`

## 9 `system_role` 系统角色

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `code` | `VARCHAR(40)` | `PRIMARY KEY` | 业务编码 |
| `label` | `VARCHAR(80)` | `NOT NULL UNIQUE` | 业务显示名称 |

## 10 `permission` 操作权限

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `code` | `VARCHAR(40)` | `PRIMARY KEY` | 业务编码 |
| `label` | `VARCHAR(80)` | `NOT NULL UNIQUE` | 业务显示名称 |

## 11 `role_permission` 角色权限

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `role_code` | `VARCHAR(40)` | `NOT NULL；PRIMARY KEY；FK → system_role.code` | 关联系统角色 |
| `permission_code` | `VARCHAR(40)` | `NOT NULL；PRIMARY KEY；FK → permission.code` | 关联操作权限 |

- `PRIMARY KEY (role_code, permission_code)`

## 12 `account_role` 账号授权

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `account_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → account.id` | 关联用户账号 |
| `role_code` | `VARCHAR(40)` | `NOT NULL；PRIMARY KEY；FK → system_role.code` | 关联系统角色 |

- `PRIMARY KEY (account_id, role_code)`

## 13 `campaign` 宣传活动

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `code` | `VARCHAR(40)` | `NOT NULL UNIQUE` | 业务编码 |
| `title` | `VARCHAR(180)` | `NOT NULL` | 业务标题 |
| `starts_at` | `DATETIME(6)` | `NOT NULL` | 区间起点，包含 |
| `ends_at` | `DATETIME(6)` | `NULL` | 区间终点，不包含；允许空时表示未结束 |
| `requires_third_review` | `BOOLEAN` | `NOT NULL DEFAULT FALSE` | 二审通过时读取的活动三审设置 |
| `created_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 登记此对象的人员 |

- `CONSTRAINT ck_campaign_dates CHECK (ends_at IS NULL OR ends_at > starts_at)`
- `CONSTRAINT ck_campaign_third CHECK (requires_third_review IN (0, 1))`

## 14 `project` 宣传项目

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `campaign_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → campaign.id` | 关联宣传活动 |
| `code` | `VARCHAR(40)` | `NOT NULL` | 业务编码 |
| `title` | `VARCHAR(180)` | `NOT NULL` | 业务标题 |
| `kind` | `ENUM('ARTICLE','VIDEO','PHOTO','OTHER')` | `NOT NULL` | 业务类型，枚举值见字段定义 |
| `delivery_mode` | `ENUM('WORK_ONLY','REVIEWED')` | `NOT NULL` | 完成条件类别 |
| `is_required` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | 是否纳入上级完成口径 |
| `created_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 登记此对象的人员 |

- `UNIQUE KEY uq_project_code (campaign_id, code)`
- `CONSTRAINT ck_project_required CHECK (is_required IN (0, 1))`
- `CONSTRAINT ck_project_delivery CHECK (kind NOT IN ('ARTICLE','VIDEO') OR delivery_mode = 'REVIEWED')`

## 15 `project_review_route` 项目审核名单

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `project_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → project.id` | 关联宣传项目 |
| `stage` | `ENUM('MINISTER','CHIEF','SECOND','THIRD')` | `NOT NULL；PRIMARY KEY` | 审核级别 |
| `reviewer_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 指定或实际审核人员 |

- `PRIMARY KEY (project_id, stage)`
- `UNIQUE KEY uq_route_reviewer (project_id, reviewer_id)`

## 16 `work_item` 工作事项

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `project_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → project.id` | 关联宣传项目 |
| `code` | `VARCHAR(40)` | `NOT NULL` | 业务编码 |
| `title` | `VARCHAR(180)` | `NOT NULL` | 业务标题 |
| `kind` | `ENUM('WRITING','LAYOUT','PHOTO','VIDEO_SHOOT','VIDEO_EDIT','COPY_EDIT','OTHER')` | `NOT NULL` | 业务类型，枚举值见字段定义 |
| `editing_mode` | `ENUM('MEMBER','MINISTER')` | `NULL` | 视频剪辑分流依据 |
| `is_required` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | 是否纳入上级完成口径 |
| `status` | `ENUM('TODO','IN_PROGRESS','BLOCKED','DONE','CANCELLED')` | `NOT NULL DEFAULT 'TODO'` | 工作状态 |
| `lock_version` | `INT UNSIGNED` | `NOT NULL DEFAULT 0` | 用于比较更新的修订号 |
| `changed_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 此次状态创建或修改的人员 |
| `updated_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)` | 最近更新时间 |
| `single_kind` | `VARCHAR(20)` | `GENERATED ALWAYS AS (IF(kind IN ('WRITING','LAYOUT','VIDEO_EDIT'), kind, NULL)) VIRTUAL` | 单例类型标记，用于每项目的工作种类唯一约束 |

- `UNIQUE KEY uq_work_code (project_id, code)`
- `UNIQUE KEY uq_work_single_kind (project_id, single_kind)`
- `CONSTRAINT ck_work_required CHECK (is_required IN (0, 1))`
- `CONSTRAINT ck_work_editing CHECK ((kind = 'VIDEO_EDIT' AND editing_mode IS NOT NULL) OR (kind <> 'VIDEO_EDIT' AND editing_mode IS NULL))`
- `INDEX ix_work_item_project_required (project_id, is_required, status)`

## 17 `work_assignment` 工作指派

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `work_item_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → work_item.id` | 关联工作事项 |
| `membership_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → membership_period.id` | 关联成员任期 |
| `assigned_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 作出该次指派的人员 |
| `assigned_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 指派时间 |
| `ended_at` | `DATETIME(6)` | `NULL` | 指派结束时间，空为开放 |
| `active_membership_id` | `BIGINT UNSIGNED` | `GENERATED ALWAYS AS (IF(ended_at IS NULL, membership_id, NULL)) VIRTUAL` | 仅开放指派投影任期 ID |

- `UNIQUE KEY uq_assignment_active (work_item_id, active_membership_id)`
- `CONSTRAINT ck_assignment_dates CHECK (ended_at IS NULL OR ended_at > assigned_at)`
- `INDEX ix_work_assignment_current (work_item_id, ended_at)`

## 18 `work_contribution` 实际工作登记

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `work_item_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → work_item.id` | 关联工作事项 |
| `membership_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → membership_period.id` | 关联成员任期 |
| `participation` | `ENUM('PRIMARY','COLLABORATOR')` | `NOT NULL` | 实际主办或协作身份 |
| `worked_at` | `DATETIME(6)` | `NOT NULL` | 实际贡献发生时间 |
| `minutes_spent` | `SMALLINT UNSIGNED` | `NOT NULL` | 实际投入的分钟数 |
| `note` | `VARCHAR(500)` | `NULL` | 补充业务说明 |
| `recorded_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 登记贡献的人员 |

- `UNIQUE KEY uq_contribution_time (work_item_id, membership_id, worked_at)`
- `CONSTRAINT ck_contribution_minutes CHECK (minutes_spent > 0)`
- `INDEX ix_work_contribution_member_date (membership_id, worked_at)`

## 19 `work_status_history` 工作状态历史

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `work_item_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → work_item.id` | 关联工作事项 |
| `old_status` | `ENUM('TODO','IN_PROGRESS','BLOCKED','DONE','CANCELLED')` | `NULL` | 历史事件前的状态，创建事件为空 |
| `new_status` | `ENUM('TODO','IN_PROGRESS','BLOCKED','DONE','CANCELLED')` | `NOT NULL` | 历史事件后的状态 |
| `lock_version` | `INT UNSIGNED` | `NOT NULL` | 用于比较更新的修订号 |
| `changed_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 此次状态创建或修改的人员 |
| `changed_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 工作变更事件时间 |

- `UNIQUE KEY uq_history_version (work_item_id, lock_version)`

## 20 `asset` 文件或外部链接

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `kind` | `ENUM('WORD','PHOTO','VIDEO_RAW','VIDEO_FINAL','XIUMI_LINK','WECHAT_LINK','OTHER')` | `NOT NULL` | 业务类型，枚举值见字段定义 |
| `title` | `VARCHAR(180)` | `NOT NULL` | 业务标题 |
| `uri` | `VARCHAR(1024)` | `NOT NULL` | 保存位置的相对文件键或外部 HTTPS 链接 |
| `sha256` | `BINARY(32)` | `NULL` | 文件内容 SHA-256 二进制值，链接可空 |
| `creator_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 创作者或素材登记归属人 |
| `created_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 创建时间 |

- `CONSTRAINT ck_asset_uri CHECK (CHAR_LENGTH(TRIM(uri)) > 0)`
- `INDEX ix_asset_creator_kind (creator_id, kind)`

## 21 `project_asset` 项目素材

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `project_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → project.id` | 关联宣传项目 |
| `asset_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → asset.id` | 关联文件或外部链接 |

- `PRIMARY KEY (project_id, asset_id)`

## 22 `submission` 成果版本

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `project_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → project.id` | 关联宣传项目 |
| `version_no` | `INT UNSIGNED` | `NOT NULL` | 项目内从 1 递增的版本号 |
| `previous_id` | `BIGINT UNSIGNED` | `NULL；FK → submission.id` | 同项目上一提交版本 |
| `kind` | `ENUM('XIUMI','WECHAT','VIDEO','GENERIC')` | `NOT NULL` | 业务类型，枚举值见字段定义 |
| `start_stage` | `ENUM('MINISTER','CHIEF')` | `NOT NULL` | 版本首个审核级别 |
| `third_required` | `BOOLEAN` | `NULL` | 二审通过时决定的三审快照，决定前为空，秀米版本为空 |
| `submitted_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 提交成果的人员 |
| `submitted_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 版本提交时间 |
| `note` | `VARCHAR(500)` | `NULL` | 补充业务说明 |

- `UNIQUE KEY uq_submission_version (project_id, version_no)`
- `UNIQUE KEY uq_submission_previous (previous_id)`
- `CONSTRAINT ck_submission_version CHECK (version_no > 0)`
- `CONSTRAINT ck_submission_third CHECK (third_required IN (0, 1) AND kind <> 'XIUMI' OR third_required IS NULL)`

## 23 `submission_asset` 版本素材

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `submission_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → submission.id` | 关联成果版本 |
| `asset_id` | `BIGINT UNSIGNED` | `NOT NULL；PRIMARY KEY；FK → asset.id` | 关联文件或外部链接 |

- `PRIMARY KEY (submission_id, asset_id)`

## 24 `review_record` 审核决定

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `submission_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → submission.id` | 关联成果版本 |
| `stage` | `ENUM('MINISTER','CHIEF','SECOND','THIRD')` | `NOT NULL` | 审核级别 |
| `reviewer_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 指定或实际审核人员 |
| `membership_id` | `BIGINT UNSIGNED` | `NULL；FK → membership_period.id` | 关联成员任期 |
| `decision` | `ENUM('APPROVED','RETURNED')` | `NOT NULL` | 审核通过或退回 |
| `feedback` | `VARCHAR(1000)` | `NOT NULL` | 实际审核意见 |
| `reviewed_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 审核决定时间 |

- `UNIQUE KEY uq_review_stage (submission_id, stage)`
- `CONSTRAINT ck_review_feedback CHECK (CHAR_LENGTH(TRIM(feedback)) > 0)`
- `INDEX ix_review_membership_time (membership_id, reviewed_at)`

## 25 `handover_record` 工作交接

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `submission_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → submission.id` | 关联成果版本 |
| `from_person_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 交接发起人 |
| `to_person_id` | `BIGINT UNSIGNED` | `NULL；FK → person.id` | 接收人，待发布状态为空 |
| `to_stage` | `ENUM('MINISTER','CHIEF','SECOND','THIRD','REWORK','WECHAT_DRAFT','PUBLISH')` | `NOT NULL` | 交接目的阶段 |
| `note` | `VARCHAR(500)` | `NULL` | 补充业务说明 |
| `handed_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 交接实际发生时间 |

- `CONSTRAINT ck_handover_recipient CHECK ((to_stage = 'PUBLISH') = (to_person_id IS NULL))`
- `INDEX ix_handover_submission_order (submission_id, id)`

## 26 `publication` 正式发布

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `submission_id` | `BIGINT UNSIGNED` | `NOT NULL UNIQUE；FK → submission.id` | 关联成果版本 |
| `channel` | `VARCHAR(60)` | `NOT NULL` | 发布渠道 |
| `url` | `VARCHAR(1024)` | `NOT NULL` | 公开发布 HTTPS 地址 |
| `published_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 确认发布人员 |
| `published_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 发布登记时间 |

- `CONSTRAINT ck_publication_url CHECK (url LIKE 'https://%')`

## 27 `equipment` 相机

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `code` | `VARCHAR(40)` | `NOT NULL UNIQUE` | 业务编码 |
| `name` | `VARCHAR(100)` | `NOT NULL` | 设备名称 |
| `model` | `VARCHAR(100)` | `NOT NULL` | 设备型号 |
| `source` | `ENUM('OWNED','PURCHASED','BORROWED')` | `NOT NULL` | 相机资产来源 |
| `inventory_status` | `ENUM('AVAILABLE','MAINTENANCE','RETIRED')` | `NOT NULL DEFAULT 'AVAILABLE'` | 设备固定可用性状态 |
| `borrowed_at` | `DATETIME(6)` | `NULL` | 外部借入的起点 |
| `due_back_at` | `DATETIME(6)` | `NULL` | 对外预计归还时间 |
| `external_returned_at` | `DATETIME(6)` | `NULL` | 向外部出借方实际归还的时间 |

- `CONSTRAINT ck_equipment_source CHECK ( (source = 'BORROWED' AND borrowed_at IS NOT NULL AND due_back_at IS NOT NULL AND due_back_at > borrowed_at AND (external_returned_at IS NULL OR external_returned_at >= borrowed_at)) OR (source <> 'BORROWED' AND borrowed_at IS NULL AND due_back_at IS NULL AND external_returned_at IS NULL)`
- `)`

## 28 `equipment_usage` 相机预约与使用

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `equipment_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → equipment.id` | 关联相机 |
| `work_item_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → work_item.id` | 关联工作事项 |
| `membership_id` | `BIGINT UNSIGNED` | `NOT NULL；FK → membership_period.id` | 关联成员任期 |
| `reserved_by` | `BIGINT UNSIGNED` | `NOT NULL；FK → person.id` | 为任务预约设备的人员 |
| `starts_at` | `DATETIME(6)` | `NOT NULL` | 区间起点，包含 |
| `ends_at` | `DATETIME(6)` | `NOT NULL` | 区间终点，不包含；允许空时表示未结束 |
| `checked_out_at` | `DATETIME(6)` | `NULL` | 实际领用时间 |
| `returned_at` | `DATETIME(6)` | `NULL` | 实际归还中心时间 |
| `cancelled_at` | `DATETIME(6)` | `NULL` | 预约取消时间 |

- `CONSTRAINT ck_usage_range CHECK (ends_at > starts_at)`
- `CONSTRAINT ck_usage_checkout CHECK (checked_out_at IS NULL OR (checked_out_at >= starts_at AND checked_out_at < ends_at))`
- `CONSTRAINT ck_usage_return CHECK (returned_at IS NULL OR (checked_out_at IS NOT NULL AND returned_at >= checked_out_at))`
- `CONSTRAINT ck_usage_cancel CHECK (cancelled_at IS NULL OR checked_out_at IS NULL)`
- `INDEX ix_equipment_usage_range (equipment_id, starts_at, ends_at)`
- `INDEX ix_equipment_usage_open (equipment_id, returned_at, checked_out_at)`

## 29 `audit_log` 安全审计

| 字段 | SQL 类型 | 约束与默认值 | 含义 |
| --- | --- | --- | --- |
| `id` | `BIGINT UNSIGNED` | `AUTO_INCREMENT PRIMARY KEY` | 代理主键 |
| `actor_id` | `BIGINT UNSIGNED` | `NULL；FK → person.id` | 业务操作者，可空以表示数据库管理操作 |
| `db_session_user` | `VARCHAR(320)` | `NOT NULL` | MySQL 会话账号 |
| `action_code` | `VARCHAR(48)` | `NOT NULL` | 审计动作代码 |
| `entity_type` | `VARCHAR(40)` | `NOT NULL` | 目标业务类型 |
| `entity_id` | `BIGINT UNSIGNED` | `NOT NULL` | 目标 ID，复合键动作可用 0 并在详情记录键 |
| `detail` | `JSON` | `NULL` | 动作详情 JSON |
| `occurred_at` | `DATETIME(6)` | `NOT NULL DEFAULT CURRENT_TIMESTAMP(6)` | 审计事件写入时间 |

- `INDEX ix_audit_entity_time (entity_type, entity_id, occurred_at)`
- `INDEX ix_audit_actor_time (actor_id, occurred_at)`
