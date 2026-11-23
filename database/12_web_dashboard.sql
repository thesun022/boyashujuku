-- Read-only dashboard extension for a copy with 11_web_auth.sql installed.
DELIMITER $$

CREATE PROCEDURE sp_web_dashboard(IN p_session_hash BINARY(32), IN p_cohort_id BIGINT UNSIGNED)
SQL SECURITY DEFINER READS SQL DATA
dashboard: BEGIN
  DECLARE v_account BIGINT UNSIGNED;
  DECLARE v_person BIGINT UNSIGNED;
  DECLARE v_manage_projects BOOLEAN;
  DECLARE v_manage_members BOOLEAN;
  DECLARE v_manage_camera BOOLEAN;
  DECLARE v_work BOOLEAN;
  DECLARE v_review BOOLEAN;
  DECLARE v_roster BOOLEAN;
  DECLARE v_projects BOOLEAN;
  DECLARE v_cohort BIGINT UNSIGNED;

  SELECT a.id, a.person_id INTO v_account, v_person
  FROM web_session s JOIN account a ON a.id = s.account_id
  WHERE s.token_hash = p_session_hash AND s.expires_at > UTC_TIMESTAMP(6) AND a.enabled = TRUE;
  IF v_account IS NULL THEN
    SELECT 'expired' AS result_code;
    LEAVE dashboard;
  END IF;

  SELECT COALESCE(MAX(rp.permission_code = 'MANAGE_PROJECT'), 0),
         COALESCE(MAX(rp.permission_code = 'MANAGE_MEMBER'), 0),
         COALESCE(MAX(rp.permission_code = 'MANAGE_CAMERA'), 0),
         COALESCE(MAX(rp.permission_code = 'LOG_WORK'), 0),
         COALESCE(MAX(rp.permission_code = 'REVIEW'), 0)
  INTO v_manage_projects, v_manage_members, v_manage_camera, v_work, v_review
  FROM account_role ar JOIN role_permission rp ON rp.role_code = ar.role_code
  WHERE ar.account_id = v_account;

  SET v_roster = v_manage_members OR v_manage_projects;
  SET v_projects = v_manage_projects OR v_work;
  IF p_cohort_id IS NOT NULL AND NOT v_roster THEN
    SELECT 'forbidden' AS result_code;
    LEAVE dashboard;
  END IF;
  IF v_roster THEN
    IF p_cohort_id IS NOT NULL THEN
      SELECT id INTO v_cohort FROM cohort WHERE id = p_cohort_id;
      IF v_cohort IS NULL THEN
        SELECT 'invalid_cohort' AS result_code;
        LEAVE dashboard;
      END IF;
    ELSE
      SELECT id INTO v_cohort FROM cohort
      WHERE intake_year <= YEAR(CURRENT_DATE())
      ORDER BY intake_year DESC, id DESC LIMIT 1;
    END IF;
  END IF;

  WITH managed_projects AS (
    SELECT p.id
    FROM project p JOIN campaign c ON c.id = p.campaign_id
    WHERE v_manage_projects AND (p.created_by = v_person OR c.created_by = v_person)
  ), assigned_work AS (
    SELECT w.work_id FROM v_web_assigned_tasks w WHERE v_work AND w.person_id = v_person
  ), visible_projects AS (
    SELECT id FROM managed_projects
    UNION
    SELECT w.project_id FROM assigned_work a JOIN work_item w ON w.id = a.work_id
  ), visible_progress AS (
    SELECT progress.campaign_id, progress.campaign_title, progress.is_required, progress.project_status
    FROM visible_projects p JOIN v_campaign_progress progress ON progress.project_id = p.id
  ), active_campaigns AS (
    SELECT c.id, c.title, c.starts_at,
           COUNT(*) AS project_count,
           SUM(v.is_required = TRUE) AS required_projects,
           SUM(v.is_required = TRUE AND v.project_status IN ('COMPLETED','PUBLISHED')) AS completed_projects
    FROM visible_progress v JOIN campaign c ON c.id = v.campaign_id
    WHERE c.starts_at <= CURRENT_TIMESTAMP(6)
    GROUP BY c.id, c.title, c.starts_at
    HAVING SUM(v.project_status NOT IN ('COMPLETED','PUBLISHED')) > 0
  ), recent_campaigns AS (
    SELECT * FROM active_campaigns ORDER BY starts_at DESC, id DESC LIMIT 5
  ), workload_entries AS (
    SELECT w.kind AS work_type, COUNT(*) AS entry_count, SUM(c.minutes_spent) AS minutes
    FROM managed_projects p JOIN work_item w ON w.project_id = p.id
    JOIN work_contribution c ON c.work_item_id = w.id
    GROUP BY w.kind
    UNION ALL
    SELECT work_type, SUM(entry_count), SUM(minutes_spent)
    FROM v_member_workload
    WHERE NOT v_manage_projects AND v_work AND person_id = v_person AND work_type <> 'REVIEW'
    GROUP BY work_type
  ), camera_status AS (
    SELECT current_status, COUNT(*) AS total
    FROM v_equipment_status
    WHERE v_manage_camera
    GROUP BY current_status
  )
  SELECT 'ok' AS result_code, DATE_FORMAT(CURRENT_TIMESTAMP(6), '%Y-%m-%d %H:%i:%s') AS updated_at,
         IF(v_roster, (SELECT COUNT(*) FROM v_current_members), NULL) AS member_count,
         v_cohort AS cohort_id,
         IF(v_cohort IS NOT NULL, (SELECT COUNT(*) FROM v_current_members WHERE cohort_id = v_cohort), NULL)
           AS cohort_member_count,
         IF(v_roster, (SELECT JSON_ARRAYAGG(JSON_OBJECT('id', CAST(id AS CHAR), 'label', label, 'year', intake_year))
                       FROM cohort), NULL) AS cohorts,
         IF(v_projects, (SELECT COUNT(*) FROM active_campaigns), NULL) AS active_campaign_count,
         IF(v_projects, COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT(
             'id', id, 'title', title, 'starts_at', DATE_FORMAT(starts_at, '%Y-%m-%d'),
             'projects', project_count, 'required', required_projects, 'completed', completed_projects))
             FROM recent_campaigns), JSON_ARRAY()), NULL) AS active_campaigns,
         IF(v_projects, (SELECT COUNT(*) FROM work_item w
                         WHERE w.status IN ('TODO','IN_PROGRESS','BLOCKED')
                           AND (w.project_id IN (SELECT id FROM managed_projects)
                                OR w.id IN (SELECT work_id FROM assigned_work))), NULL) AS pending_task_count,
         IF(v_review, (SELECT COUNT(*) FROM v_pending_reviews WHERE reviewer_id = v_person), NULL)
           AS pending_review_count,
         IF(v_projects, (SELECT COUNT(*) FROM visible_progress WHERE project_status = 'PUBLISHED'), NULL)
           AS published_count,
         IF(v_projects, IF(v_manage_projects, 'managed', 'personal'), NULL) AS workload_scope,
         IF(v_projects, COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT(
             'type', work_type, 'entries', entry_count, 'minutes', minutes)) FROM workload_entries),
             JSON_ARRAY()), NULL) AS workload,
         IF(v_manage_camera, COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT(
             'status', current_status, 'total', total)) FROM camera_status), JSON_ARRAY()), NULL) AS cameras;
END$$

DELIMITER ;

GRANT EXECUTE ON PROCEDURE boya_media_center.sp_web_dashboard TO 'boya_web_auth'@'%';
