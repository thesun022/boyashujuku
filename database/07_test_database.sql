-- Execute on the initialized demo schema as the deployer, with autocommit on.
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';
DELIMITER $$

CREATE PROCEDURE _boya_fixture_test_assert(IN p_ok BOOLEAN, IN p_label VARCHAR(100))
SQL SECURITY INVOKER
BEGIN
  DECLARE v_error VARCHAR(128);
  IF NOT (p_ok <=> TRUE) THEN
    SET v_error = CONCAT('FAIL ', p_label);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_error;
  END IF;
  SELECT CONCAT('PASS ', p_label) AS test;
END$$

CREATE PROCEDURE _boya_fixture_test_error(
  IN p_sql TEXT, IN p_errno INT, IN p_detail VARCHAR(100), IN p_label VARCHAR(100)
)
SQL SECURITY INVOKER
BEGIN
  DECLARE v_errno INT DEFAULT 0;
  DECLARE v_detail TEXT DEFAULT '';
  SET @boya_test_sql = p_sql;
  PREPARE boya_test_statement FROM @boya_test_sql;
  BEGIN
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
      GET STACKED DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO, v_detail = MESSAGE_TEXT;
    EXECUTE boya_test_statement;
  END;
  DEALLOCATE PREPARE boya_test_statement;
  CALL _boya_fixture_test_assert(v_errno = p_errno AND LOCATE(p_detail, v_detail) > 0, p_label);
END$$

DELIMITER ;

CALL _boya_fixture_test_assert((SELECT COUNT(*) = 29 FROM information_schema.tables
  WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' AND engine = 'InnoDB'
    AND table_collation LIKE 'utf8mb4%'), '29 InnoDB utf8mb4 tables');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 29 FROM information_schema.table_constraints
  WHERE table_schema = DATABASE() AND constraint_type = 'PRIMARY KEY'), '29 primary keys');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 47 FROM information_schema.referential_constraints
  WHERE constraint_schema = DATABASE()), '47 foreign keys');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 24 FROM information_schema.triggers
  WHERE trigger_schema = DATABASE()), '24 triggers');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 5 FROM information_schema.views
  WHERE table_schema = DATABASE()), 'five views');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 22 FROM information_schema.routines
  WHERE routine_schema = DATABASE() AND routine_name NOT LIKE '_boya_fixture_test%'), '22 business routines');

SET @article_id = (SELECT project_id FROM v_campaign_progress WHERE campaign_code = 'SPORTS-2026' AND project_code = 'ARTICLE');
SET @video_id = (SELECT project_id FROM v_campaign_progress WHERE campaign_code = 'SPORTS-2026' AND project_code = 'VIDEO');
SET @work_edit = (SELECT id FROM work_item WHERE project_id = @video_id AND kind = 'VIDEO_EDIT');
SET @work_shoot = (SELECT id FROM work_item WHERE project_id = @video_id AND kind = 'VIDEO_SHOOT');
SET @work_write = (SELECT id FROM work_item WHERE project_id = @article_id AND kind = 'WRITING');
SET @work_layout = (SELECT id FROM work_item WHERE project_id = @article_id AND kind = 'LAYOUT');
SET @work_photo = (SELECT id FROM work_item WHERE project_id = @article_id AND kind = 'PHOTO');
SET @lead_id = (SELECT id FROM project WHERE code = 'LEADER-VIDEO');
SET @lead_work = (SELECT id FROM work_item WHERE project_id = @lead_id AND kind = 'VIDEO_EDIT');
SET @lead_submission = (SELECT id FROM submission WHERE project_id = @lead_id);
SET @team_submission = (SELECT s.id FROM submission s JOIN project p ON p.id = s.project_id WHERE p.code = 'TEAM-VIDEO');

CALL _boya_fixture_test_assert((SELECT COUNT(*) = 8 FROM v_current_members), 'active membership view');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 2 FROM membership_period WHERE person_id = 11),
  'same person can join again in a different cohort');
CALL _boya_fixture_test_assert((SELECT a.enabled = FALSE AND m.left_at IS NOT NULL
  FROM account a JOIN membership_period m ON m.person_id = a.person_id WHERE a.person_id = 10),
  'exit disables the account');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 1 FROM work_assignment
  WHERE membership_id = 10 AND ended_at IS NOT NULL), 'exit closes future assignment eligibility and keeps assignment history');
CALL _boya_fixture_test_assert((SELECT SUM(minutes_spent) = 45 FROM v_member_workload
  WHERE person_id = 10 AND cohort_code = '2025' AND work_type = 'PHOTO'), 'historical workload after exit');
CALL _boya_fixture_test_assert((SELECT SUM(minutes_spent) = 75 FROM v_member_workload
  WHERE person_id = 5 AND cohort_code = '2026' AND work_type = 'WRITING'), 'workload credited to actual writer');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 0 FROM v_member_workload
  WHERE person_id = 7 AND work_type = 'WRITING'), 'initial assignee receives no automatic workload');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 2 FROM work_assignment
  WHERE work_item_id = @work_write), 'original and replacement assignments remain visible');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 2 AND SUM(minutes_spent) = 190
  FROM work_contribution WHERE work_item_id = @work_photo), 'two photographers contributed to the article');
CALL _boya_fixture_test_assert((SELECT SUM(minutes_spent) = 120 FROM v_member_workload
  WHERE person_id = 8 AND work_type = 'PHOTO'), 'actual collaborator workload includes unassigned work');
CALL _boya_fixture_test_assert((SELECT SUM(minutes_spent) = 25 FROM v_member_workload
  WHERE person_id = 2 AND work_type = 'COPY_EDIT'), 'copy-edit workload');
CALL _boya_fixture_test_assert((SELECT SUM(entry_count) = 4 FROM v_member_workload
  WHERE person_id = 2 AND work_type = 'REVIEW'), 'chief review workload includes returned review');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 3 AND MIN(campaign_percent) = 66.67
  FROM v_campaign_progress WHERE campaign_code = 'SPORTS-2026'
  AND ((project_code = 'ARTICLE' AND project_status = 'PUBLISHED')
    OR (project_code = 'VIDEO' AND project_status = 'IN_PROGRESS')
    OR (project_code = 'PHOTO' AND project_status = 'COMPLETED'))), 'independent project states and 66.67 percent campaign');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 4 FROM submission WHERE project_id = @article_id),
  'four immutable article version records');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 2 FROM handover_record h
  JOIN submission s ON s.id = h.submission_id WHERE s.project_id = @article_id AND s.version_no = 2
  AND h.to_stage = 'REWORK'
  AND ((h.from_person_id = 2 AND h.to_person_id = 1) OR (h.from_person_id = 1 AND h.to_person_id = 6))),
  'chief returns to minister, minister forwards to original layout contributor');
CALL _boya_fixture_test_assert((SELECT s.third_required = 0 AND COUNT(r.id) = 2
  FROM publication pub JOIN submission s ON s.id = pub.submission_id
  JOIN review_record r ON r.submission_id = s.id
  WHERE s.project_id = @article_id AND r.stage IN ('CHIEF','SECOND') GROUP BY s.third_required),
  'article published with optional third stage disabled');
CALL _boya_fixture_test_assert((SELECT start_stage = 'CHIEF' AND third_required = 1 FROM submission
  WHERE id = @lead_submission), 'minister-edited video starts at chief, snapshots third stage at second review');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 0 FROM review_record
  WHERE submission_id = @lead_submission AND stage = 'MINISTER'), 'no minister self-review');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 1 FROM v_pending_reviews
  WHERE submission_id = @lead_submission AND review_stage = 'THIRD' AND reviewer_id = 4),
  'third reviewer can be selected while the project is already in review');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 4 FROM publication p JOIN review_record r
  ON r.submission_id = p.submission_id WHERE p.submission_id = @team_submission AND r.decision = 'APPROVED'),
  'member-edited team video completes all four required stages');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 2 FROM v_equipment_status
  WHERE (source = 'OWNED' AND current_status = 'AVAILABLE')
     OR (source = 'BORROWED' AND current_status IN ('IN_USE','OVERDUE'))),
  'owned camera returned; borrowed camera physically checked out');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 3 FROM work_status_history
  WHERE work_item_id = @work_layout AND lock_version IN (0,1,2)), 'automatic work status history');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 2 FROM audit_log
  WHERE action_code = 'PUBLISH' AND entity_type = 'publication'), 'publication audit trail');

CALL _boya_fixture_test_error('CALL sp_publish(1,@lead_submission,''VIDEO'',''https://example.invalid/too-early'')',
  1644,'requires current approved','third approval is mandatory when enabled');
CALL _boya_fixture_test_error('CALL sp_review_submission(1,@lead_submission,''APPROVED'',''self-review'')',
  1644,'not pending review by this actor','unauthorized/self review rejected');
CALL _boya_fixture_test_error('CALL sp_set_work_status(3,@work_edit,1,''BLOCKED'')',
  1644,'lacks business permission','external reviewer cannot manage work');
CALL _boya_fixture_test_error('CALL sp_set_work_status(1,@work_edit,0,''BLOCKED'')',
  1644,'version conflict','stale optimistic version rejected');
CALL _boya_fixture_test_error('CALL sp_assign_work(1,@work_shoot,10)',
  1644,'active member','exited member cannot receive a new assignment');
CALL _boya_fixture_test_error('CALL sp_log_contribution(10,@work_shoot,10,''PRIMARY'',''2026-10-26 12:10'',10,NULL)',
  1644,'Actor is disabled','disabled account cannot log work');

START TRANSACTION;
CALL _boya_fixture_test_error('INSERT INTO person_skill(person_id,skill_id) VALUES (18446744073709551615,1)',
  1452,'foreign key constraint','invalid foreign key rejected');
CALL _boya_fixture_test_error('INSERT INTO equipment(code,name,model,source) VALUES (''CAM-DEMO-01'',''duplicate'',''camera'',''OWNED'')',
  1062,'Duplicate entry','duplicate equipment code rejected');
CALL _boya_fixture_test_error('INSERT INTO work_contribution(work_item_id,membership_id,participation,worked_at,minutes_spent,recorded_by)
  VALUES (@work_shoot,7,''PRIMARY'',''2026-10-24 08:00'',0,7)',
  3819,'ck_contribution_minutes','CHECK rejects zero minutes');
CALL _boya_fixture_test_error('INSERT INTO membership_period(person_id,cohort_id,joined_at,left_at)
  VALUES (11,1,''2025-10-01'',''2026-01-01'')',
  1644,'periods overlap','closed membership periods cannot overlap');
CALL _boya_fixture_test_error('INSERT INTO work_assignment(work_item_id,membership_id,assigned_by) VALUES (@work_write,8,1)',
  1644,'one assignment slot','writing slot limit');
CALL _boya_fixture_test_error('INSERT INTO work_assignment(work_item_id,membership_id,assigned_by) VALUES (@work_layout,8,1)',
  1644,'one assignment slot','layout slot limit');
CALL _boya_fixture_test_error('INSERT INTO work_assignment(work_item_id,membership_id,assigned_by) VALUES (@lead_work,9,1)',
  1644,'appropriate organization position','minister-only editing rejects member');
CALL _boya_fixture_test_error('INSERT INTO work_assignment(work_item_id,membership_id,assigned_by) VALUES (@lead_work,1,1)',
  1644,'one assignment slot','minister-edited task has one seat');
CALL _boya_fixture_test_error('INSERT INTO work_assignment(work_item_id,membership_id,assigned_by) VALUES (@work_photo,7,1)',
  1062,'Duplicate entry','one active assignment per person on a multi-person task');
SET @reservation_start = (SELECT starts_at FROM equipment_usage WHERE equipment_id = 1);
SET @reservation_end = (SELECT ends_at FROM equipment_usage WHERE equipment_id = 1);
CALL _boya_fixture_test_error('INSERT INTO equipment_usage(equipment_id,work_item_id,membership_id,reserved_by,starts_at,ends_at)
  VALUES (1,@work_shoot,9,1,@reservation_start,@reservation_end)',
  1644,'reservation overlaps','overlapping times rejected across different tasks');
INSERT INTO equipment_usage(equipment_id,work_item_id,membership_id,reserved_by,starts_at,ends_at)
VALUES (1,@work_shoot,9,1,@reservation_end,@reservation_end + INTERVAL 10 MINUTE);
CALL _boya_fixture_test_assert(ROW_COUNT() = 1, 'adjacent reservation intervals permitted');
CALL _boya_fixture_test_error('UPDATE audit_log SET detail = NULL WHERE id = (SELECT MIN(a.id) FROM (SELECT id FROM audit_log LIMIT 1) a)',
  1644,'append-only','audit update prohibited');
SET @audit_id = (SELECT MIN(id) FROM audit_log);
CALL _boya_fixture_test_error('DELETE FROM audit_log WHERE id = @audit_id',
  1644,'append-only','audit delete prohibited');
UPDATE work_item SET status = 'BLOCKED', lock_version = lock_version + 1, changed_by = 1
WHERE id = @work_edit;
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 1 FROM work_status_history
  WHERE work_item_id = @work_edit AND new_status = 'BLOCKED'), 'write and trigger visible inside transaction');
ROLLBACK;
CALL _boya_fixture_test_assert((SELECT status = 'IN_PROGRESS' AND lock_version = 1
  FROM work_item WHERE id = @work_edit), 'rollback restores work state and version');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 0 FROM work_status_history
  WHERE work_item_id = @work_edit AND new_status = 'BLOCKED'), 'rollback removes trigger side effects');
CALL _boya_fixture_test_assert((SELECT COUNT(*) = 1 FROM equipment_usage WHERE equipment_id = 1),
  'rollback removes tentative reservations');

SELECT membership_id, display_name, cohort_code, position_code FROM v_current_members ORDER BY membership_id;
SELECT person_id, cohort_code, work_type, SUM(entry_count) AS entries, SUM(minutes_spent) AS minutes
FROM v_member_workload GROUP BY person_id, cohort_code, work_type ORDER BY person_id, work_type;
SELECT project_title, version_no, review_stage, reviewer_name FROM v_pending_reviews;
SELECT campaign_code, project_code, project_status, campaign_percent FROM v_campaign_progress
ORDER BY campaign_code, project_code;
SELECT code, source, current_status, current_user_name, next_reservation FROM v_equipment_status ORDER BY code;

DROP PROCEDURE _boya_fixture_test_error;
DROP PROCEDURE _boya_fixture_test_assert;
