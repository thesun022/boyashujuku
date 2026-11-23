-- Install after 11 and 12 on the reviewed Web deployment database.
START TRANSACTION;
INSERT INTO system_role (code,label) VALUES ('SYSTEM_ADMIN','系统管理员');
INSERT INTO permission (code,label) VALUES ('MANAGE_SYSTEM','维护账号、角色和日志');
INSERT INTO role_permission (role_code,permission_code) VALUES
  ('SYSTEM_ADMIN','MANAGE_MEMBER'), ('SYSTEM_ADMIN','MANAGE_SYSTEM');
COMMIT;

-- Physical storage cleanup is durable even if the Windows filesystem is temporarily busy.
CREATE TABLE web_file_cleanup (
  storage_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
  queued_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB;

GRANT 'boya_media_center_runtime'@'%' TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, UPDATE ON boya_media_center.person TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT ON boya_media_center.cohort TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, UPDATE (left_at) ON boya_media_center.membership_period TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, UPDATE (ends_at) ON boya_media_center.membership_position TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, UPDATE ON boya_media_center.skill TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, DELETE ON boya_media_center.person_skill TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.`position` TO 'boya_web_auth'@'%';
GRANT SELECT (id,person_id,username,enabled,created_at), INSERT (person_id,username,password_hash,enabled),
  UPDATE (username,password_hash,enabled) ON boya_media_center.account TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, UPDATE (label) ON boya_media_center.system_role TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.permission TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, DELETE ON boya_media_center.role_permission TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, DELETE ON boya_media_center.account_role TO 'boya_web_auth'@'%';
GRANT SELECT, UPDATE (code,title,starts_at,ends_at,requires_third_review) ON boya_media_center.campaign TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.project TO 'boya_web_auth'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.boya_lock_project TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.project_review_route TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.work_item TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.work_assignment TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.work_contribution TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.work_status_history TO 'boya_web_auth'@'%';
GRANT SELECT, DELETE ON boya_media_center.asset TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, DELETE ON boya_media_center.project_asset TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.submission TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.submission_asset TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.review_record TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.handover_record TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.publication TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, UPDATE ON boya_media_center.equipment TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.equipment_usage TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT ON boya_media_center.audit_log TO 'boya_web_auth'@'%';
GRANT SELECT, INSERT, DELETE ON boya_media_center.web_file_cleanup TO 'boya_web_auth'@'%';
