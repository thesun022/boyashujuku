SET NAMES utf8mb4;
SET default_storage_engine = InnoDB;

CREATE TABLE person (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  person_code VARCHAR(40) NOT NULL UNIQUE,
  display_name VARCHAR(100) NOT NULL,
  contact VARCHAR(160) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
);

CREATE TABLE cohort (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(20) NOT NULL UNIQUE,
  label VARCHAR(80) NOT NULL,
  intake_year SMALLINT UNSIGNED NOT NULL,
  CONSTRAINT ck_cohort_year CHECK (intake_year BETWEEN 1900 AND 9999)
);

CREATE TABLE membership_period (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  person_id BIGINT UNSIGNED NOT NULL,
  cohort_id BIGINT UNSIGNED NOT NULL,
  joined_at DATETIME(6) NOT NULL,
  left_at DATETIME(6) NULL,
  open_person_id BIGINT UNSIGNED GENERATED ALWAYS AS
    (IF(left_at IS NULL, person_id, NULL)) VIRTUAL,
  UNIQUE KEY uq_membership_open (open_person_id),
  CONSTRAINT ck_membership_dates CHECK (left_at IS NULL OR left_at > joined_at)
);

CREATE TABLE `position` (
  code VARCHAR(20) PRIMARY KEY,
  label VARCHAR(60) NOT NULL UNIQUE,
  hierarchy_rank TINYINT UNSIGNED NOT NULL UNIQUE
);

CREATE TABLE membership_position (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  membership_id BIGINT UNSIGNED NOT NULL,
  position_code VARCHAR(20) NOT NULL,
  starts_at DATETIME(6) NOT NULL,
  ends_at DATETIME(6) NULL,
  UNIQUE KEY uq_position_start (membership_id, starts_at),
  CONSTRAINT ck_position_dates CHECK (ends_at IS NULL OR ends_at > starts_at)
);

CREATE TABLE skill (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(40) NOT NULL UNIQUE,
  label VARCHAR(60) NOT NULL UNIQUE
);

CREATE TABLE person_skill (
  person_id BIGINT UNSIGNED NOT NULL,
  skill_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (person_id, skill_id)
);

CREATE TABLE account (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  person_id BIGINT UNSIGNED NOT NULL UNIQUE,
  username VARCHAR(80) NOT NULL UNIQUE,
  password_hash VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  CONSTRAINT ck_account_enabled CHECK (enabled IN (0, 1)),
  CONSTRAINT ck_account_hash CHECK (password_hash LIKE '$argon2id$v=19$m=%')
);

CREATE TABLE system_role (
  code VARCHAR(40) PRIMARY KEY,
  label VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE permission (
  code VARCHAR(40) PRIMARY KEY,
  label VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE role_permission (
  role_code VARCHAR(40) NOT NULL,
  permission_code VARCHAR(40) NOT NULL,
  PRIMARY KEY (role_code, permission_code)
);

CREATE TABLE account_role (
  account_id BIGINT UNSIGNED NOT NULL,
  role_code VARCHAR(40) NOT NULL,
  PRIMARY KEY (account_id, role_code)
);

CREATE TABLE campaign (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(40) NOT NULL UNIQUE,
  title VARCHAR(180) NOT NULL,
  starts_at DATETIME(6) NOT NULL,
  ends_at DATETIME(6) NULL,
  requires_third_review BOOLEAN NOT NULL DEFAULT FALSE,
  created_by BIGINT UNSIGNED NOT NULL,
  CONSTRAINT ck_campaign_dates CHECK (ends_at IS NULL OR ends_at > starts_at),
  CONSTRAINT ck_campaign_third CHECK (requires_third_review IN (0, 1))
);

CREATE TABLE project (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  campaign_id BIGINT UNSIGNED NOT NULL,
  code VARCHAR(40) NOT NULL,
  title VARCHAR(180) NOT NULL,
  kind ENUM('ARTICLE','VIDEO','PHOTO','OTHER') NOT NULL,
  delivery_mode ENUM('WORK_ONLY','REVIEWED') NOT NULL,
  is_required BOOLEAN NOT NULL DEFAULT TRUE,
  created_by BIGINT UNSIGNED NOT NULL,
  UNIQUE KEY uq_project_code (campaign_id, code),
  CONSTRAINT ck_project_required CHECK (is_required IN (0, 1)),
  CONSTRAINT ck_project_delivery CHECK
    (kind NOT IN ('ARTICLE','VIDEO') OR delivery_mode = 'REVIEWED')
);

CREATE TABLE project_review_route (
  project_id BIGINT UNSIGNED NOT NULL,
  stage ENUM('MINISTER','CHIEF','SECOND','THIRD') NOT NULL,
  reviewer_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (project_id, stage),
  UNIQUE KEY uq_route_reviewer (project_id, reviewer_id)
);

CREATE TABLE work_item (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  project_id BIGINT UNSIGNED NOT NULL,
  code VARCHAR(40) NOT NULL,
  title VARCHAR(180) NOT NULL,
  kind ENUM('WRITING','LAYOUT','PHOTO','VIDEO_SHOOT','VIDEO_EDIT','COPY_EDIT','OTHER') NOT NULL,
  editing_mode ENUM('MEMBER','MINISTER') NULL,
  is_required BOOLEAN NOT NULL DEFAULT TRUE,
  status ENUM('TODO','IN_PROGRESS','BLOCKED','DONE','CANCELLED') NOT NULL DEFAULT 'TODO',
  lock_version INT UNSIGNED NOT NULL DEFAULT 0,
  changed_by BIGINT UNSIGNED NOT NULL,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  single_kind VARCHAR(20) GENERATED ALWAYS AS
    (IF(kind IN ('WRITING','LAYOUT','VIDEO_EDIT'), kind, NULL)) VIRTUAL,
  UNIQUE KEY uq_work_code (project_id, code),
  UNIQUE KEY uq_work_single_kind (project_id, single_kind),
  CONSTRAINT ck_work_required CHECK (is_required IN (0, 1)),
  CONSTRAINT ck_work_editing CHECK
    ((kind = 'VIDEO_EDIT' AND editing_mode IS NOT NULL)
      OR (kind <> 'VIDEO_EDIT' AND editing_mode IS NULL))
);

CREATE TABLE work_assignment (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  work_item_id BIGINT UNSIGNED NOT NULL,
  membership_id BIGINT UNSIGNED NOT NULL,
  assigned_by BIGINT UNSIGNED NOT NULL,
  assigned_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  ended_at DATETIME(6) NULL,
  active_membership_id BIGINT UNSIGNED GENERATED ALWAYS AS
    (IF(ended_at IS NULL, membership_id, NULL)) VIRTUAL,
  UNIQUE KEY uq_assignment_active (work_item_id, active_membership_id),
  CONSTRAINT ck_assignment_dates CHECK (ended_at IS NULL OR ended_at > assigned_at)
);

CREATE TABLE work_contribution (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  work_item_id BIGINT UNSIGNED NOT NULL,
  membership_id BIGINT UNSIGNED NOT NULL,
  participation ENUM('PRIMARY','COLLABORATOR') NOT NULL,
  worked_at DATETIME(6) NOT NULL,
  minutes_spent SMALLINT UNSIGNED NOT NULL,
  note VARCHAR(500) NULL,
  recorded_by BIGINT UNSIGNED NOT NULL,
  UNIQUE KEY uq_contribution_time (work_item_id, membership_id, worked_at),
  CONSTRAINT ck_contribution_minutes CHECK (minutes_spent > 0)
);

CREATE TABLE work_status_history (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  work_item_id BIGINT UNSIGNED NOT NULL,
  old_status ENUM('TODO','IN_PROGRESS','BLOCKED','DONE','CANCELLED') NULL,
  new_status ENUM('TODO','IN_PROGRESS','BLOCKED','DONE','CANCELLED') NOT NULL,
  lock_version INT UNSIGNED NOT NULL,
  changed_by BIGINT UNSIGNED NOT NULL,
  changed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uq_history_version (work_item_id, lock_version)
);

CREATE TABLE asset (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  kind ENUM('WORD','PHOTO','VIDEO_RAW','VIDEO_FINAL','XIUMI_LINK','WECHAT_LINK','OTHER') NOT NULL,
  title VARCHAR(180) NOT NULL,
  uri VARCHAR(1024) NOT NULL,
  sha256 BINARY(32) NULL,
  creator_id BIGINT UNSIGNED NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  CONSTRAINT ck_asset_uri CHECK (CHAR_LENGTH(TRIM(uri)) > 0)
);

CREATE TABLE project_asset (
  project_id BIGINT UNSIGNED NOT NULL,
  asset_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (project_id, asset_id)
);

CREATE TABLE submission (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  project_id BIGINT UNSIGNED NOT NULL,
  version_no INT UNSIGNED NOT NULL,
  previous_id BIGINT UNSIGNED NULL,
  kind ENUM('XIUMI','WECHAT','VIDEO','GENERIC') NOT NULL,
  start_stage ENUM('MINISTER','CHIEF') NOT NULL,
  third_required BOOLEAN NULL,
  submitted_by BIGINT UNSIGNED NOT NULL,
  submitted_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  note VARCHAR(500) NULL,
  UNIQUE KEY uq_submission_version (project_id, version_no),
  UNIQUE KEY uq_submission_previous (previous_id),
  CONSTRAINT ck_submission_version CHECK (version_no > 0),
  CONSTRAINT ck_submission_third CHECK
    (third_required IN (0, 1) AND kind <> 'XIUMI' OR third_required IS NULL)
);

CREATE TABLE submission_asset (
  submission_id BIGINT UNSIGNED NOT NULL,
  asset_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (submission_id, asset_id)
);

CREATE TABLE review_record (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  submission_id BIGINT UNSIGNED NOT NULL,
  stage ENUM('MINISTER','CHIEF','SECOND','THIRD') NOT NULL,
  reviewer_id BIGINT UNSIGNED NOT NULL,
  membership_id BIGINT UNSIGNED NULL,
  decision ENUM('APPROVED','RETURNED') NOT NULL,
  feedback VARCHAR(1000) NOT NULL,
  reviewed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  UNIQUE KEY uq_review_stage (submission_id, stage),
  CONSTRAINT ck_review_feedback CHECK (CHAR_LENGTH(TRIM(feedback)) > 0)
);

CREATE TABLE handover_record (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  submission_id BIGINT UNSIGNED NOT NULL,
  from_person_id BIGINT UNSIGNED NOT NULL,
  to_person_id BIGINT UNSIGNED NULL,
  to_stage ENUM('MINISTER','CHIEF','SECOND','THIRD','REWORK','WECHAT_DRAFT','PUBLISH') NOT NULL,
  note VARCHAR(500) NULL,
  handed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  CONSTRAINT ck_handover_recipient CHECK ((to_stage = 'PUBLISH') = (to_person_id IS NULL))
);

CREATE TABLE publication (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  submission_id BIGINT UNSIGNED NOT NULL UNIQUE,
  channel VARCHAR(60) NOT NULL,
  url VARCHAR(1024) NOT NULL,
  published_by BIGINT UNSIGNED NOT NULL,
  published_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  CONSTRAINT ck_publication_url CHECK (url LIKE 'https://%')
);

CREATE TABLE equipment (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  code VARCHAR(40) NOT NULL UNIQUE,
  name VARCHAR(100) NOT NULL,
  model VARCHAR(100) NOT NULL,
  source ENUM('OWNED','PURCHASED','BORROWED') NOT NULL,
  inventory_status ENUM('AVAILABLE','MAINTENANCE','RETIRED') NOT NULL DEFAULT 'AVAILABLE',
  borrowed_at DATETIME(6) NULL,
  due_back_at DATETIME(6) NULL,
  external_returned_at DATETIME(6) NULL,
  CONSTRAINT ck_equipment_source CHECK (
    (source = 'BORROWED' AND borrowed_at IS NOT NULL AND due_back_at IS NOT NULL
      AND due_back_at > borrowed_at
      AND (external_returned_at IS NULL OR external_returned_at >= borrowed_at))
    OR (source <> 'BORROWED' AND borrowed_at IS NULL AND due_back_at IS NULL
      AND external_returned_at IS NULL)
  )
);

CREATE TABLE equipment_usage (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  equipment_id BIGINT UNSIGNED NOT NULL,
  work_item_id BIGINT UNSIGNED NOT NULL,
  membership_id BIGINT UNSIGNED NOT NULL,
  reserved_by BIGINT UNSIGNED NOT NULL,
  starts_at DATETIME(6) NOT NULL,
  ends_at DATETIME(6) NOT NULL,
  checked_out_at DATETIME(6) NULL,
  returned_at DATETIME(6) NULL,
  cancelled_at DATETIME(6) NULL,
  CONSTRAINT ck_usage_range CHECK (ends_at > starts_at),
  CONSTRAINT ck_usage_checkout CHECK
    (checked_out_at IS NULL OR (checked_out_at >= starts_at AND checked_out_at < ends_at)),
  CONSTRAINT ck_usage_return CHECK
    (returned_at IS NULL OR (checked_out_at IS NOT NULL AND returned_at >= checked_out_at)),
  CONSTRAINT ck_usage_cancel CHECK (cancelled_at IS NULL OR checked_out_at IS NULL)
);

CREATE TABLE audit_log (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  actor_id BIGINT UNSIGNED NULL,
  db_session_user VARCHAR(320) NOT NULL,
  action_code VARCHAR(48) NOT NULL,
  entity_type VARCHAR(40) NOT NULL,
  entity_id BIGINT UNSIGNED NOT NULL,
  detail JSON NULL,
  occurred_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
);
