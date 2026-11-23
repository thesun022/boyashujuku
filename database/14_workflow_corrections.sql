-- One-time upgrade after 13, with the application stopped. Existing publications and hours retain their history.
CREATE TABLE voided_work_contribution (
  id BIGINT UNSIGNED PRIMARY KEY,
  work_item_id BIGINT UNSIGNED NOT NULL,
  membership_id BIGINT UNSIGNED NOT NULL,
  participation ENUM('PRIMARY','COLLABORATOR') NOT NULL,
  worked_at DATETIME(6) NOT NULL,
  minutes_spent SMALLINT UNSIGNED NOT NULL,
  note VARCHAR(500),
  recorded_by BIGINT UNSIGNED NOT NULL,
  voided_by BIGINT UNSIGNED NOT NULL,
  voided_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  reason VARCHAR(500) NOT NULL,
  FOREIGN KEY (work_item_id) REFERENCES work_item(id),
  FOREIGN KEY (membership_id) REFERENCES membership_period(id),
  FOREIGN KEY (recorded_by) REFERENCES person(id),
  FOREIGN KEY (voided_by) REFERENCES person(id),
  CHECK (minutes_spent > 0 AND CHAR_LENGTH(TRIM(reason)) > 0)
) ENGINE=InnoDB;

INSERT INTO role_permission(role_code,permission_code)
  SELECT 'CHIEF_EDITOR','PUBLISH' WHERE NOT EXISTS (
    SELECT 1 FROM role_permission WHERE role_code='CHIEF_EDITOR' AND permission_code='PUBLISH');

CREATE SQL SECURITY DEFINER VIEW v_project_publishers AS
WITH publishers AS (
  SELECT a.person_id, MAX(rp.permission_code='MANAGE_PROJECT') AS manages
  FROM account a JOIN account_role ar ON ar.account_id=a.id
  JOIN role_permission rp ON rp.role_code=ar.role_code
  WHERE a.enabled GROUP BY a.person_id HAVING MAX(rp.permission_code='PUBLISH')=1
)
SELECT p.id AS project_id, u.person_id
FROM project p JOIN project_review_route r ON r.project_id=p.id AND r.stage='CHIEF'
JOIN v_current_members m ON m.person_id=r.reviewer_id AND m.position_code='CHIEF'
JOIN publishers u ON u.person_id=m.person_id WHERE p.kind='ARTICLE'
UNION ALL
SELECT p.id, u.person_id FROM project p JOIN campaign c ON c.id=p.campaign_id
JOIN publishers u ON u.manages AND u.person_id IN (p.created_by,c.created_by)
WHERE p.kind<>'ARTICLE' AND p.delivery_mode='REVIEWED';

DELIMITER $$
CREATE PROCEDURE sp_void_contribution(
  IN p_actor BIGINT UNSIGNED, IN p_work BIGINT UNSIGNED, IN p_entry BIGINT UNSIGNED, IN p_reason VARCHAR(500)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor,'LOG_WORK_FOR_OTHERS');
  CALL boya_require(p_actor,'MANAGE_PROJECT');
  SELECT project_id INTO v_project FROM work_item WHERE id=p_work;
  SELECT id INTO v_project FROM project WHERE id=v_project FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM project p JOIN campaign c ON c.id=p.campaign_id
                 WHERE p.id=v_project AND p_actor IN (p.created_by,c.created_by)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Correction requires project manager';
  END IF;
  IF p_reason IS NULL OR CHAR_LENGTH(TRIM(p_reason))=0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Correction requires a reason';
  END IF;
  INSERT INTO voided_work_contribution
    (id,work_item_id,membership_id,participation,worked_at,minutes_spent,note,recorded_by,voided_by,reason)
    SELECT id,work_item_id,membership_id,participation,worked_at,minutes_spent,note,recorded_by,p_actor,TRIM(p_reason)
    FROM work_contribution WHERE id=p_entry AND work_item_id=p_work;
  IF ROW_COUNT()<>1 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No effective contribution to void'; END IF;
  DELETE FROM work_contribution WHERE id=p_entry AND work_item_id=p_work;
  CALL boya_audit(p_actor,'WORK_CONTRIBUTION_VOID','work_contribution',p_entry,
                  JSON_OBJECT('work_item_id',p_work,'reason',TRIM(p_reason)));
  IF NOT EXISTS (SELECT 1 FROM work_contribution WHERE work_item_id=p_work)
     AND NOT EXISTS (SELECT 1 FROM publication pub JOIN submission s ON s.id=pub.submission_id
                     WHERE s.project_id=v_project) THEN
    UPDATE work_item SET status='IN_PROGRESS',lock_version=lock_version+1,changed_by=p_actor
    WHERE id=p_work AND status='DONE';
  END IF;
  COMMIT;
END$$

DROP PROCEDURE sp_publish$$
CREATE PROCEDURE sp_publish(
  IN p_actor BIGINT UNSIGNED, IN p_submission BIGINT UNSIGNED, IN p_channel VARCHAR(60), IN p_url VARCHAR(1024)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE v_kind VARCHAR(20);
  DECLARE v_problem VARCHAR(128);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor,'PUBLISH');
  SELECT s.project_id,p.kind INTO v_project,v_kind FROM submission s JOIN project p ON p.id=s.project_id
    WHERE s.id=p_submission;
  CALL boya_lock_project(v_project);
  IF NOT EXISTS (SELECT 1 FROM v_project_publishers WHERE project_id=v_project AND person_id=p_actor) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Actor is not the project publisher';
  END IF;
  IF v_kind='ARTICLE' THEN
    SELECT CONCAT(IF(w.status IN ('BLOCKED','CANCELLED'),'TASK_STATUS:','TASK_HOURS:'),LEFT(w.title,95))
      INTO v_problem FROM work_item w
      WHERE w.project_id=v_project AND w.is_required AND (w.status IN ('BLOCKED','CANCELLED') OR
        NOT EXISTS (SELECT 1 FROM work_contribution a WHERE a.work_item_id=w.id))
      ORDER BY w.id LIMIT 1;
    IF v_problem IS NOT NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT=v_problem; END IF;
    UPDATE work_item SET status='DONE',lock_version=lock_version+1,changed_by=p_actor
      WHERE project_id=v_project AND is_required AND status IN ('TODO','IN_PROGRESS');
  END IF;
  -- The existing publication trigger verifies the latest version, every review and required task.
  -- A rejection rolls back the status history and all task updates along with the publication.
  INSERT INTO publication(submission_id,channel,url,published_by) VALUES(p_submission,p_channel,p_url,p_actor);
  COMMIT;
END$$
DELIMITER ;

GRANT SELECT ON boya_media_center.voided_work_contribution TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.v_project_publishers TO 'boya_web_auth'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_void_contribution TO 'boya_media_center_runtime'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_publish TO 'boya_media_center_runtime'@'%';
