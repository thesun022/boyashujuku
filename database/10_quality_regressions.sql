-- Disposable demo database only. Workflow and membership procedures commit fixture changes.
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';
DELIMITER $$

CREATE PROCEDURE _boya_qa_assert(IN p_ok BOOLEAN, IN p_case VARCHAR(100))
SQL SECURITY INVOKER
BEGIN
  IF NOT (p_ok <=> TRUE) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = p_case;
  END IF;
  SELECT 'PASS' AS result, p_case AS quality_case;
END$$

CREATE PROCEDURE _boya_qa_error(
  IN p_sql TEXT, IN p_errno INT, IN p_detail VARCHAR(100), IN p_case VARCHAR(100)
)
SQL SECURITY INVOKER
BEGIN
  DECLARE v_errno INT DEFAULT 0;
  DECLARE v_detail TEXT DEFAULT '';
  DECLARE v_failure VARCHAR(128);
  SET @boya_qa_sql = p_sql;
  PREPARE boya_qa_statement FROM @boya_qa_sql;
  BEGIN
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
      GET STACKED DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO, v_detail = MESSAGE_TEXT;
    EXECUTE boya_qa_statement;
  END;
  DEALLOCATE PREPARE boya_qa_statement;
  IF v_errno <> p_errno OR LOCATE(p_detail, v_detail) = 0 THEN
    SET v_failure = LEFT(CONCAT(p_case, ': expected ',p_errno,', got ',v_errno,' ',v_detail), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_failure;
  END IF;
  CALL _boya_qa_assert(TRUE, p_case);
END$$

DELIMITER ;

-- Teacher return, correction, version chain and approval.
CALL sp_create_campaign(1,'QA-SECOND-RETURN','QA teacher return',CURRENT_TIMESTAMP(6),NULL,FALSE);
SET @qa_campaign = (SELECT id FROM campaign WHERE code = 'QA-SECOND-RETURN');
CALL sp_create_project(1,@qa_campaign,'QA-VIDEO','QA second review','VIDEO','REVIEWED',TRUE);
CALL sp_create_project(1,@qa_campaign,'QA-SHARED','QA shared assets','OTHER','WORK_ONLY',FALSE);
SET @qa_project = (SELECT id FROM project WHERE campaign_id = @qa_campaign AND code = 'QA-VIDEO');
SET @qa_shared = (SELECT id FROM project WHERE campaign_id = @qa_campaign AND code = 'QA-SHARED');
CALL sp_create_work(1,@qa_project,'EDIT','QA editing','VIDEO_EDIT','MEMBER',TRUE);
SET @qa_work = (SELECT id FROM work_item WHERE project_id = @qa_project);
CALL sp_set_review_route(1,@qa_project,'MINISTER',1);
CALL sp_set_review_route(1,@qa_project,'CHIEF',2);
CALL sp_set_review_route(1,@qa_project,'SECOND',3);
CALL sp_assign_work(1,@qa_work,9);
CALL sp_log_contribution(9,@qa_work,9,'PRIMARY','2026-10-26 09:00',40,'QA first cut');
CALL sp_set_work_status(1,@qa_work,0,'IN_PROGRESS');
CALL sp_register_asset(9,@qa_project,'VIDEO_FINAL','QA original','files/qa/original.mp4',SHA2('QA fixture 1',256),@qa_source);
CALL sp_submit(9,@qa_project,'VIDEO',JSON_ARRAY(@qa_source),'QA v1',@qa_v1);
CALL sp_review_submission(1,@qa_v1,'APPROVED','QA minister accepted');
CALL sp_review_submission(2,@qa_v1,'APPROVED','QA chief accepted v1');
CALL sp_review_submission(3,@qa_v1,'RETURNED','QA teacher: correct ending captions');

CALL _boya_qa_assert((SELECT stage = 'SECOND' AND reviewer_id = 3 AND membership_id IS NULL
  AND decision = 'RETURNED' AND feedback = 'QA teacher: correct ending captions'
  FROM review_record WHERE submission_id = @qa_v1 AND stage = 'SECOND'), 'Q01 teacher return preserves stage and feedback');
CALL _boya_qa_assert((SELECT from_person_id = 3 AND to_person_id = 1 AND to_stage = 'REWORK'
  FROM handover_record WHERE submission_id = @qa_v1 ORDER BY id DESC LIMIT 1), 'Q02 teacher hands rework to minister');
CALL _boya_qa_assert((SELECT project_status = 'RETURNED' FROM v_campaign_progress WHERE project_id = @qa_project)
  AND NOT EXISTS (SELECT 1 FROM v_pending_reviews WHERE submission_id = @qa_v1), 'Q03 returned version leaves review queue');
CALL _boya_qa_error('CALL sp_publish(1,@qa_v1,''VIDEO'',''https://example.invalid/qa/early'')',
  1644,'requires current approved', 'Q04 returned version cannot be published');
CALL _boya_qa_error('CALL sp_submit(9,@qa_project,''VIDEO'',JSON_ARRAY(@qa_source),''too early'',@qa_unexpected)',
  1644,'awaiting review or rework handover', 'Q05 rework submission requires minister forwarding');
CALL sp_forward_rework(1,@qa_v1,'QA forwarded teacher feedback');
CALL sp_log_contribution(9,@qa_work,9,'PRIMARY','2026-10-26 10:00',15,'QA corrected captions');
CALL sp_register_asset(9,@qa_project,'VIDEO_FINAL','QA correction','files/qa/corrected.mp4',SHA2('QA fixture 2',256),@qa_correction);
CALL sp_submit(9,@qa_project,'VIDEO',JSON_ARRAY(@qa_correction),'QA v2',@qa_v2);
CALL _boya_qa_assert((SELECT version_no = 2 AND previous_id = @qa_v1 FROM submission WHERE id = @qa_v2)
  AND (SELECT COUNT(*) = 3 FROM review_record WHERE submission_id = @qa_v1)
  AND EXISTS (SELECT 1 FROM submission_asset WHERE submission_id = @qa_v1 AND asset_id = @qa_source)
  AND EXISTS (SELECT 1 FROM submission_asset WHERE submission_id = @qa_v2 AND asset_id = @qa_correction),
  'Q06 corrected and original versions retain distinct assets and reviews');
CALL sp_review_submission(1,@qa_v2,'APPROVED','QA minister accepted v2');
CALL sp_review_submission(2,@qa_v2,'APPROVED','QA chief accepted v2');
CALL sp_review_submission(3,@qa_v2,'APPROVED','QA teacher accepted v2');
CALL sp_set_work_status(1,@qa_work,1,'DONE');
CALL sp_publish(1,@qa_v2,'VIDEO','https://example.invalid/qa/final');
CALL _boya_qa_assert((SELECT COUNT(*) = 1 AND SUM(submission_id = @qa_v2) = 1
  FROM publication WHERE submission_id IN (@qa_v1,@qa_v2)) AND (SELECT project_status = 'PUBLISHED' FROM v_campaign_progress
  WHERE project_id = @qa_project), 'Q07 only the approved correction is published');

-- Retain one metadata row shared across projects and pinned by a historical version.
START TRANSACTION;
INSERT INTO project_asset(project_id,asset_id) VALUES (@qa_shared,@qa_source);
CALL _boya_qa_assert((SELECT COUNT(*) = 2 FROM project_asset WHERE asset_id = @qa_source)
  AND (SELECT uri = 'files/qa/original.mp4' AND OCTET_LENGTH(sha256) = 32
       FROM asset WHERE id = @qa_source)
  AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE()
                 AND table_name = 'asset' AND data_type IN ('tinyblob','blob','mediumblob','longblob')),
  'Q08 two projects share one external file metadata row');
-- Isolate the project-reference checks from the separate version-reference check.
DELETE FROM submission_asset WHERE submission_id = @qa_v1 AND asset_id = @qa_source;
CALL _boya_qa_error('DELETE FROM asset WHERE id=@qa_source',1451,'fk_project_asset_asset_id',
  'Q09 project reference restricts shared metadata deletion');
DELETE FROM project_asset WHERE project_id = @qa_project AND asset_id = @qa_source;
CALL _boya_qa_error('DELETE FROM asset WHERE id=@qa_source',1451,'fk_project_asset_asset_id',
  'Q10 remaining project still restricts shared metadata deletion');
DELETE FROM project_asset WHERE project_id = @qa_shared AND asset_id = @qa_source;
INSERT INTO submission_asset(submission_id,asset_id) VALUES (@qa_v1,@qa_source);
CALL _boya_qa_error('DELETE FROM asset WHERE id=@qa_source',1451,'fk_submission_asset_asset_id',
  'Q11 historical submission alone restricts metadata deletion');
ROLLBACK;
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM asset WHERE id = @qa_source)
  AND EXISTS (SELECT 1 FROM project_asset WHERE project_id = @qa_project AND asset_id = @qa_source)
  AND EXISTS (SELECT 1 FROM submission_asset WHERE submission_id = @qa_v1 AND asset_id = @qa_source),
  'Q12 source metadata and historical bindings survive cleanup attempts');

-- Position change and member exit must not change a prior review's attribution.
SET @qa_chief_review = (SELECT id FROM review_record WHERE submission_id = @qa_v2 AND stage = 'CHIEF');
SET @qa_review_time = (SELECT reviewed_at FROM review_record WHERE id = @qa_chief_review);
SET @qa_review_total = (SELECT SUM(entry_count) FROM v_member_workload WHERE membership_id = 2 AND work_type = 'REVIEW');
CALL _boya_qa_error('UPDATE membership_period SET left_at=@qa_review_time WHERE id=2',
  1644,'Exit would invalidate membership history','bu_membership_period blocks backdated exit through recorded review');
SET @qa_reassigned_at = CURRENT_TIMESTAMP(6);
UPDATE membership_position SET ends_at = @qa_reassigned_at
WHERE membership_id = 2 AND position_code = 'CHIEF' AND ends_at IS NULL;
INSERT INTO membership_position(membership_id,position_code,starts_at) VALUES (2,'MEMBER',@qa_reassigned_at);
CALL _boya_qa_assert((SELECT position_code = 'MEMBER' FROM v_current_members WHERE membership_id = 2)
  AND (SELECT stage = 'CHIEF' AND reviewer_id = 2 AND feedback = 'QA chief accepted v2'
       FROM review_record WHERE id = @qa_chief_review), 'Q13 current position changes and review retains original chief stage');
CALL sp_exit_member(1,2);
CALL _boya_qa_assert(NOT EXISTS (SELECT 1 FROM v_current_members WHERE membership_id = 2)
  AND (SELECT enabled = FALSE FROM account WHERE person_id = 2)
  AND (SELECT COUNT(*) = 1
       FROM review_record r JOIN membership_period m ON m.id = r.membership_id
       JOIN membership_position position_at_review ON position_at_review.membership_id = m.id
       JOIN person p ON p.id = r.reviewer_id
       WHERE r.id = @qa_chief_review AND r.reviewer_id = m.person_id AND p.person_code = 'DEMO-CHIEF'
         AND m.left_at > r.reviewed_at AND r.stage = 'CHIEF' AND r.feedback = 'QA chief accepted v2'
         AND position_at_review.position_code = 'CHIEF' AND position_at_review.starts_at <= r.reviewed_at
         AND position_at_review.ends_at > r.reviewed_at)
  AND (SELECT SUM(entry_count) = @qa_review_total FROM v_member_workload
       WHERE membership_id = 2 AND work_type = 'REVIEW'), 'Q14 exited reviewer remains queryable and workload is preserved');

-- Exercise all named CHECK predicates and additional trigger paths in a rolled-back transaction.
START TRANSACTION;
SET @qa_probe_time = CURRENT_TIMESTAMP(6) + INTERVAL 3 DAY;
SET @qa_photo = (SELECT MIN(id) FROM work_item WHERE kind = 'PHOTO');
SET @qa_assignment = (SELECT MIN(id) FROM work_assignment WHERE ended_at IS NULL);
SET @qa_vehicle_closed = (SELECT MIN(id) FROM equipment_usage WHERE equipment_id = 1 AND returned_at IS NOT NULL);
SET @qa_approved = (SELECT id FROM publication WHERE submission_id = @qa_v2);
SET @qa_contribution = (SELECT MIN(id) FROM work_contribution);
SET @qa_handover = (SELECT MIN(id) FROM handover_record WHERE submission_id = @qa_v1 AND to_stage = 'CHIEF');
SET @qa_position = (SELECT id FROM membership_position WHERE membership_id = 9 AND ends_at IS NULL);
SET @qa_audit_floor = (SELECT MAX(id) FROM audit_log);
INSERT INTO person(person_code,display_name) VALUES ('QA-CONSTRAINT-PROBE','Fictional SQL constraint probe');
SET @qa_temp_person = LAST_INSERT_ID();

CALL _boya_qa_error('UPDATE account SET enabled=2 WHERE id=9',3819,'ck_account_enabled','CHECK ck_account_enabled');
CALL _boya_qa_error('UPDATE account SET password_hash=''invalid-format-fixture'' WHERE id=9',
  3819,'ck_account_hash','CHECK ck_account_hash');
CALL _boya_qa_error('UPDATE asset SET uri='' '' WHERE id=@qa_source',3819,'ck_asset_uri','CHECK ck_asset_uri');
CALL _boya_qa_error('UPDATE work_assignment SET ended_at=assigned_at WHERE id=@qa_assignment',
  3819,'ck_assignment_dates','CHECK ck_assignment_dates');
CALL _boya_qa_error('UPDATE campaign SET ends_at=starts_at WHERE id=@qa_campaign',
  3819,'ck_campaign_dates','CHECK ck_campaign_dates');
CALL _boya_qa_error('UPDATE campaign SET requires_third_review=2 WHERE id=@qa_campaign',
  3819,'ck_campaign_third','CHECK ck_campaign_third');
CALL _boya_qa_error('UPDATE cohort SET intake_year=1899 WHERE id=1',3819,'ck_cohort_year','CHECK ck_cohort_year');
CALL _boya_qa_error('UPDATE work_contribution SET minutes_spent=0 WHERE id=@qa_contribution',
  3819,'ck_contribution_minutes','CHECK ck_contribution_minutes');
CALL _boya_qa_error('UPDATE equipment SET source=''BORROWED'' WHERE id=1',
  3819,'ck_equipment_source','CHECK ck_equipment_source');
CALL _boya_qa_error('UPDATE handover_record SET to_person_id=NULL WHERE id=@qa_handover',
  3819,'ck_handover_recipient','CHECK ck_handover_recipient');
CALL _boya_qa_error('INSERT INTO membership_period(person_id,cohort_id,joined_at,left_at)
  VALUES (@qa_temp_person,1,''2025-09-01'',''2025-09-01'')',
  3819,'ck_membership_dates','CHECK ck_membership_dates');
CALL _boya_qa_error('UPDATE membership_position SET ends_at=starts_at WHERE id=@qa_position',
  3819,'ck_position_dates','CHECK ck_position_dates');
CALL _boya_qa_error('UPDATE project SET delivery_mode=''WORK_ONLY'' WHERE id=@qa_project',
  3819,'ck_project_delivery','CHECK ck_project_delivery');
CALL _boya_qa_error('UPDATE project SET is_required=2 WHERE id=@qa_project',
  3819,'ck_project_required','CHECK ck_project_required');
CALL _boya_qa_error('UPDATE publication SET url=''http://example.invalid'' WHERE id=@qa_approved',
  3819,'ck_publication_url','CHECK ck_publication_url');
CALL _boya_qa_error('UPDATE review_record SET feedback='' '' WHERE id=@qa_chief_review',
  3819,'ck_review_feedback','CHECK ck_review_feedback');
CALL _boya_qa_error('UPDATE submission SET version_no=0 WHERE id=@qa_v2',
  3819,'ck_submission_version','CHECK ck_submission_version');
CALL _boya_qa_error('UPDATE submission SET third_required=2 WHERE id=@qa_v2',
  3819,'ck_submission_third','CHECK ck_submission_third');
CALL _boya_qa_error('INSERT INTO work_item(project_id,code,title,kind,editing_mode,changed_by)
  VALUES (@qa_shared,''BAD-EDIT'',''QA'',''OTHER'',''MEMBER'',1)',
  3819,'ck_work_editing','CHECK ck_work_editing');
CALL _boya_qa_error('INSERT INTO work_item(project_id,code,title,kind,is_required,changed_by)
  VALUES (@qa_shared,''BAD-REQUIRED'',''QA'',''OTHER'',2,1)',
  3819,'ck_work_required','CHECK ck_work_required');
CALL _boya_qa_error('INSERT INTO equipment_usage(equipment_id,work_item_id,membership_id,reserved_by,starts_at,ends_at)
  VALUES (1,@qa_photo,9,1,@qa_probe_time,@qa_probe_time)',
  3819,'ck_usage_range','CHECK ck_usage_range');
INSERT INTO equipment_usage(equipment_id,work_item_id,membership_id,reserved_by,starts_at,ends_at)
VALUES (1,@qa_photo,9,1,@qa_probe_time,@qa_probe_time + INTERVAL 1 HOUR);
SET @qa_probe_usage = LAST_INSERT_ID();
CALL _boya_qa_error('UPDATE equipment_usage SET checked_out_at=ends_at WHERE id=@qa_probe_usage',
  3819,'ck_usage_checkout','CHECK ck_usage_checkout');
UPDATE equipment_usage SET checked_out_at = starts_at WHERE id = @qa_probe_usage;
CALL _boya_qa_error('UPDATE equipment_usage SET returned_at=checked_out_at-INTERVAL 1 SECOND WHERE id=@qa_probe_usage',
  3819,'ck_usage_return','CHECK ck_usage_return');
CALL _boya_qa_error('UPDATE equipment_usage SET returned_at=checked_out_at,cancelled_at=checked_out_at WHERE id=@qa_probe_usage',
  3819,'ck_usage_cancel','CHECK ck_usage_cancel');

INSERT INTO membership_period(person_id,cohort_id,joined_at) VALUES (@qa_temp_person,1,'2025-09-01');
SET @qa_temp_period = LAST_INSERT_ID();
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE entity_type = 'membership_period'
  AND entity_id = @qa_temp_period AND action_code = 'MEMBERSHIP_ADD'), 'ai_membership_period adds audit');
CALL _boya_qa_error('INSERT INTO membership_position(membership_id,position_code,starts_at)
  VALUES (9,''MEMBER'',''2026-09-02'')',1644,'outside membership or overlaps','bi_membership_position rejects overlapping period');
CALL _boya_qa_error('UPDATE membership_position SET position_code=''CHIEF'' WHERE id=@qa_position',
  1644,'Only closing an open position','bu_membership_position rejects rewriting prior position');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE action_code = 'MEMBERSHIP_EXIT'
  AND entity_type = 'membership_period' AND entity_id = 2), 'au_membership_period audits exit');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE action_code = 'ACCOUNT_ADD' AND entity_id = 2
  AND JSON_KEYS(detail) = JSON_ARRAY('enabled')), 'ai_account audit excludes authentication hash');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE action_code = 'ACCOUNT_CHANGE' AND entity_id = 2
  AND JSON_EXTRACT(detail,'$.enabled') = 0 AND JSON_LENGTH(detail) = 2
  AND JSON_CONTAINS_PATH(detail,'one','$.hash_changed')), 'au_account audit records exit without authentication hash');

INSERT INTO account_role(account_id,role_code) VALUES (9,'CHIEF_EDITOR');
DELETE FROM account_role WHERE account_id = 9 AND role_code = 'CHIEF_EDITOR';
INSERT INTO role_permission(role_code,permission_code) VALUES ('CONTRIBUTOR','PUBLISH');
DELETE FROM role_permission WHERE role_code = 'CONTRIBUTOR' AND permission_code = 'PUBLISH';
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE id > @qa_audit_floor
  AND entity_id = 9 AND action_code = 'ACCOUNT_ROLE_GRANT'), 'ai_account_role audits grants');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE id > @qa_audit_floor
  AND entity_id = 9 AND action_code = 'ACCOUNT_ROLE_REVOKE'), 'ad_account_role audits revocations');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE id > @qa_audit_floor
  AND action_code = 'ROLE_PERMISSION_GRANT'), 'ai_role_permission audits grants');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE id > @qa_audit_floor
  AND action_code = 'ROLE_PERMISSION_REVOKE'), 'ad_role_permission audits revocations');

CALL _boya_qa_error('UPDATE work_item SET title=''QA stale lock'' WHERE id=@qa_work',
  1644,'lock_version must advance','bu_work_item rejects writes without advancing version');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM work_status_history WHERE work_item_id = @qa_work
  AND old_status IS NULL AND new_status = 'TODO' AND lock_version = 0), 'ai_work_item records the initial state');
CALL _boya_qa_assert(EXISTS (SELECT 1 FROM audit_log WHERE action_code = 'WORK_STATUS'
  AND entity_id = @qa_work AND JSON_UNQUOTE(JSON_EXTRACT(detail,'$.to')) = 'DONE'), 'au_work_item audits state transition');
CALL _boya_qa_error('UPDATE work_assignment SET assigned_by=2 WHERE id=@qa_assignment',
  1644,'Only ending an active assignment','bu_work_assignment rejects rewriting the assignment');
CALL _boya_qa_error('INSERT INTO work_contribution(work_item_id,membership_id,participation,worked_at,minutes_spent,recorded_by)
  VALUES (@qa_photo,9,''PRIMARY'',''2025-01-01'',30,9)',
  1644,'must occur during membership','bi_work_contribution rejects contribution outside membership');
CALL _boya_qa_error('UPDATE equipment_usage SET starts_at=starts_at-INTERVAL 1 SECOND WHERE id=@qa_vehicle_closed',
  1644,'closed reservations are fixed','bu_equipment_usage protects returned reservation');
ROLLBACK;

DROP PROCEDURE _boya_qa_error;
DROP PROCEDURE _boya_qa_assert;
