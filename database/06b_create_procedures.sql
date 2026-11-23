-- Public sp_* entry points own their transactions. Call with no outer transaction.
DELIMITER $$

CREATE PROCEDURE boya_require(IN p_actor BIGINT UNSIGNED, IN p_permission VARCHAR(40))
SQL SECURITY DEFINER READS SQL DATA
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM account a
    JOIN account_role ar ON ar.account_id = a.id
    JOIN role_permission rp ON rp.role_code = ar.role_code
    WHERE a.person_id = p_actor AND a.enabled AND rp.permission_code = p_permission
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Actor is disabled or lacks business permission';
  END IF;
END$$

CREATE PROCEDURE boya_audit(
  IN p_actor BIGINT UNSIGNED, IN p_action VARCHAR(48), IN p_type VARCHAR(40),
  IN p_id BIGINT UNSIGNED, IN p_detail JSON
)
SQL SECURITY DEFINER MODIFIES SQL DATA
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (p_actor, SESSION_USER(), p_action, p_type, p_id, p_detail)$$

CREATE PROCEDURE boya_lock_project(IN p_project BIGINT UNSIGNED)
SQL SECURITY DEFINER READS SQL DATA
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  SELECT id INTO v_id FROM project WHERE id = p_project FOR UPDATE;
  IF v_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Project does not exist';
  END IF;
  IF EXISTS (SELECT 1 FROM publication pub JOIN submission s ON s.id = pub.submission_id
             WHERE s.project_id = p_project) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Published project is closed';
  END IF;
END$$

CREATE PROCEDURE boya_lock_work(IN p_work BIGINT UNSIGNED, OUT p_project BIGINT UNSIGNED)
SQL SECURITY DEFINER READS SQL DATA
BEGIN
  SELECT project_id INTO p_project FROM work_item WHERE id = p_work;
  CALL boya_lock_project(p_project);
END$$

CREATE PROCEDURE boya_reviewer(
  IN p_project BIGINT UNSIGNED, IN p_stage VARCHAR(20), OUT p_person BIGINT UNSIGNED
)
SQL SECURITY DEFINER READS SQL DATA
BEGIN
  SET p_person = NULL;
  SELECT reviewer_id INTO p_person FROM project_review_route
  WHERE project_id = p_project AND stage = p_stage;
  IF p_person IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Project is missing a required reviewer';
  END IF;
  CALL boya_require(p_person, 'REVIEW');
  IF p_stage IN ('MINISTER','CHIEF') AND NOT EXISTS (
    SELECT 1 FROM v_current_members WHERE person_id = p_person AND position_code = p_stage
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reviewer must currently hold the required position';
  END IF;
END$$

CREATE PROCEDURE sp_create_campaign(
  IN p_actor BIGINT UNSIGNED, IN p_code VARCHAR(40), IN p_title VARCHAR(180),
  IN p_start DATETIME(6), IN p_end DATETIME(6), IN p_third BOOLEAN
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_PROJECT');
  INSERT INTO campaign(code, title, starts_at, ends_at, requires_third_review, created_by)
  VALUES (p_code, p_title, p_start, p_end, p_third, p_actor);
  CALL boya_audit(p_actor, 'CAMPAIGN_CREATE', 'campaign', LAST_INSERT_ID(), NULL);
  COMMIT;
END$$

CREATE PROCEDURE sp_create_project(
  IN p_actor BIGINT UNSIGNED, IN p_campaign BIGINT UNSIGNED, IN p_code VARCHAR(40),
  IN p_title VARCHAR(180), IN p_kind VARCHAR(20), IN p_delivery VARCHAR(20), IN p_required BOOLEAN
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_PROJECT');
  INSERT INTO project(campaign_id, code, title, kind, delivery_mode, is_required, created_by)
  VALUES (p_campaign, p_code, p_title, p_kind, p_delivery, p_required, p_actor);
  CALL boya_audit(p_actor, 'PROJECT_CREATE', 'project', LAST_INSERT_ID(), NULL);
  COMMIT;
END$$

CREATE PROCEDURE sp_create_work(
  IN p_actor BIGINT UNSIGNED, IN p_project BIGINT UNSIGNED, IN p_code VARCHAR(40),
  IN p_title VARCHAR(180), IN p_kind VARCHAR(20), IN p_mode VARCHAR(12), IN p_required BOOLEAN
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_PROJECT');
  CALL boya_lock_project(p_project);
  INSERT INTO work_item(project_id, code, title, kind, editing_mode, is_required, changed_by)
  VALUES (p_project, p_code, p_title, p_kind, p_mode, p_required, p_actor);
  CALL boya_audit(p_actor, 'WORK_CREATE', 'work_item', LAST_INSERT_ID(), NULL);
  COMMIT;
END$$

CREATE PROCEDURE sp_set_review_route(
  IN p_actor BIGINT UNSIGNED, IN p_project BIGINT UNSIGNED,
  IN p_stage VARCHAR(20), IN p_reviewer BIGINT UNSIGNED
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_reviewer BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_PROJECT');
  CALL boya_lock_project(p_project);
  IF (p_stage <> 'THIRD' AND EXISTS (SELECT 1 FROM submission WHERE project_id = p_project))
     OR (p_stage = 'THIRD' AND EXISTS (
       SELECT 1 FROM submission s JOIN handover_record h ON h.submission_id = s.id
       WHERE s.project_id = p_project AND h.to_stage = 'THIRD'
     )) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Review route is fixed after its handover is in use';
  END IF;
  IF EXISTS (SELECT 1 FROM project_review_route WHERE project_id = p_project AND stage = p_stage) THEN
    UPDATE project_review_route SET reviewer_id = p_reviewer
    WHERE project_id = p_project AND stage = p_stage;
  ELSE
    INSERT INTO project_review_route(project_id, stage, reviewer_id)
    VALUES (p_project, p_stage, p_reviewer);
  END IF;
  CALL boya_reviewer(p_project, p_stage, v_reviewer);
  CALL boya_audit(p_actor, 'REVIEW_ROUTE', 'project', p_project,
                  JSON_OBJECT('stage', p_stage, 'reviewer_id', p_reviewer));
  COMMIT;
END$$

CREATE PROCEDURE sp_set_campaign_third_review(
  IN p_actor BIGINT UNSIGNED, IN p_campaign BIGINT UNSIGNED, IN p_required BOOLEAN
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_PROJECT');
  SELECT id INTO v_id FROM campaign WHERE id = p_campaign FOR UPDATE;
  IF v_id IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Campaign does not exist'; END IF;
  UPDATE campaign SET requires_third_review = p_required WHERE id = p_campaign;
  CALL boya_audit(p_actor, 'CAMPAIGN_THIRD', 'campaign', p_campaign, JSON_OBJECT('required', p_required));
  COMMIT;
END$$

CREATE PROCEDURE sp_assign_work(
  IN p_actor BIGINT UNSIGNED, IN p_work BIGINT UNSIGNED, IN p_membership BIGINT UNSIGNED
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'ASSIGN_WORK');
  CALL boya_lock_work(p_work, v_project);
  INSERT INTO work_assignment(work_item_id, membership_id, assigned_by)
  VALUES (p_work, p_membership, p_actor);
  CALL boya_audit(p_actor, 'WORK_ASSIGN', 'work_assignment', LAST_INSERT_ID(),
                  JSON_OBJECT('work_item_id', p_work, 'membership_id', p_membership));
  COMMIT;
END$$

CREATE PROCEDURE sp_end_work_assignment(IN p_actor BIGINT UNSIGNED, IN p_assignment BIGINT UNSIGNED)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_work BIGINT UNSIGNED;
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'ASSIGN_WORK');
  SELECT work_item_id INTO v_work FROM work_assignment WHERE id = p_assignment;
  CALL boya_lock_work(v_work, v_project);
  UPDATE work_assignment SET ended_at = CURRENT_TIMESTAMP(6)
  WHERE id = p_assignment AND ended_at IS NULL;
  IF ROW_COUNT() <> 1 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Assignment is closed'; END IF;
  CALL boya_audit(p_actor, 'WORK_UNASSIGN', 'work_assignment', p_assignment, NULL);
  COMMIT;
END$$

CREATE PROCEDURE sp_log_contribution(
  IN p_actor BIGINT UNSIGNED, IN p_work BIGINT UNSIGNED, IN p_membership BIGINT UNSIGNED,
  IN p_participation VARCHAR(20), IN p_worked DATETIME(6),
  IN p_minutes SMALLINT UNSIGNED, IN p_note VARCHAR(500)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE v_person BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  SELECT person_id INTO v_person FROM membership_period WHERE id = p_membership;
  IF p_actor = v_person THEN
    CALL boya_require(p_actor, 'LOG_WORK');
  ELSE
    CALL boya_require(p_actor, 'LOG_WORK_FOR_OTHERS');
  END IF;
  CALL boya_lock_work(p_work, v_project);
  INSERT INTO work_contribution
    (work_item_id, membership_id, participation, worked_at, minutes_spent, note, recorded_by)
  VALUES (p_work, p_membership, p_participation, p_worked, p_minutes, p_note, p_actor);
  CALL boya_audit(p_actor, 'WORK_CONTRIBUTE', 'work_contribution', LAST_INSERT_ID(),
                  JSON_OBJECT('work_item_id', p_work, 'membership_id', p_membership));
  COMMIT;
END$$

CREATE PROCEDURE sp_set_work_status(
  IN p_actor BIGINT UNSIGNED, IN p_work BIGINT UNSIGNED,
  IN p_expected INT UNSIGNED, IN p_status VARCHAR(20)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_PROJECT');
  CALL boya_lock_work(p_work, v_project);
  IF p_status = 'DONE' AND NOT EXISTS (SELECT 1 FROM work_contribution WHERE work_item_id = p_work) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Finished work requires an actual contribution';
  END IF;
  UPDATE work_item SET status = p_status, lock_version = lock_version + 1, changed_by = p_actor
  WHERE id = p_work AND lock_version = p_expected AND status <> p_status;
  IF ROW_COUNT() <> 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Work version conflict or status unchanged';
  END IF;
  COMMIT;
END$$

CREATE PROCEDURE sp_exit_member(IN p_actor BIGINT UNSIGNED, IN p_membership BIGINT UNSIGNED)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_MEMBER');
  UPDATE membership_period SET left_at = CURRENT_TIMESTAMP(6)
  WHERE id = p_membership AND left_at IS NULL;
  IF ROW_COUNT() <> 1 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Open membership is required'; END IF;
  CALL boya_audit(p_actor, 'MEMBER_EXIT', 'membership_period', p_membership, NULL);
  COMMIT;
END$$

CREATE PROCEDURE sp_register_asset(
  IN p_actor BIGINT UNSIGNED, IN p_project BIGINT UNSIGNED, IN p_kind VARCHAR(20),
  IN p_title VARCHAR(180), IN p_uri VARCHAR(1024), IN p_hash CHAR(64), OUT p_asset BIGINT UNSIGNED
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'REGISTER_ASSET');
  CALL boya_lock_project(p_project);
  IF (p_kind IN ('XIUMI_LINK','WECHAT_LINK') AND p_uri NOT LIKE 'https://%')
     OR (p_hash IS NOT NULL AND p_hash NOT REGEXP '^[0-9A-Fa-f]{64}$') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Asset HTTPS link or hash is invalid';
  END IF;
  INSERT INTO asset(kind, title, uri, sha256, creator_id)
  VALUES (p_kind, p_title, p_uri, UNHEX(p_hash), p_actor);
  SET p_asset = LAST_INSERT_ID();
  INSERT INTO project_asset(project_id, asset_id) VALUES (p_project, p_asset);
  CALL boya_audit(p_actor, 'ASSET_REGISTER', 'asset', p_asset, JSON_OBJECT('project_id', p_project));
  COMMIT;
END$$

CREATE PROCEDURE sp_submit(
  IN p_actor BIGINT UNSIGNED, IN p_project BIGINT UNSIGNED, IN p_kind VARCHAR(20),
  IN p_assets JSON, IN p_note VARCHAR(500), OUT p_submission BIGINT UNSIGNED
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_kind VARCHAR(20);
  DECLARE v_delivery VARCHAR(20);
  DECLARE v_last BIGINT UNSIGNED;
  DECLARE v_version INT UNSIGNED DEFAULT 0;
  DECLARE v_stage VARCHAR(20);
  DECLARE v_to BIGINT UNSIGNED;
  DECLARE v_reviewer BIGINT UNSIGNED;
  DECLARE v_initial VARCHAR(20);
  DECLARE v_mode VARCHAR(12);
  DECLARE v_work BIGINT UNSIGNED;
  DECLARE v_matching INT;
  DECLARE v_word INT;
  DECLARE v_photo INT;
  DECLARE v_xiumi INT;
  DECLARE v_wechat INT;
  DECLARE v_video INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'SUBMIT');
  CALL boya_lock_project(p_project);
  SELECT kind, delivery_mode INTO v_kind, v_delivery
  FROM project WHERE id = p_project;
  IF v_delivery <> 'REVIEWED' OR p_kind IS NULL OR p_assets IS NULL OR JSON_TYPE(p_assets) <> 'ARRAY'
     OR JSON_LENGTH(p_assets) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Submission requires a reviewed project and asset array';
  END IF;
  SELECT id, version_no INTO v_last, v_version FROM submission
  WHERE project_id = p_project ORDER BY version_no DESC LIMIT 1;
  IF v_last IS NOT NULL THEN
    SELECT to_stage, to_person_id INTO v_stage, v_to FROM handover_record
    WHERE submission_id = v_last ORDER BY id DESC LIMIT 1;
    IF NOT (v_to <=> p_actor) OR v_stage NOT IN ('REWORK','WECHAT_DRAFT') THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Previous version is awaiting review or rework handover';
    END IF;
  END IF;
  SET v_initial = 'MINISTER';
  CASE v_kind
    WHEN 'ARTICLE' THEN
      IF (v_stage <=> 'WECHAT_DRAFT') THEN
        IF p_kind <> 'WECHAT' THEN
          SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Approved Xiumi requires a WeChat draft';
        END IF;
        SET v_initial = 'CHIEF';
      ELSEIF p_kind <> 'XIUMI' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Article must begin or restart at Xiumi';
      END IF;
      SELECT id INTO v_work FROM work_item WHERE project_id = p_project AND kind = 'LAYOUT';
      IF NOT EXISTS (SELECT 1 FROM work_item WHERE project_id = p_project AND kind = 'WRITING') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Article requires a writing work item';
      END IF;
    WHEN 'VIDEO' THEN
      IF p_kind <> 'VIDEO' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Video project requires a video submission';
      END IF;
      SELECT id, editing_mode INTO v_work, v_mode FROM work_item
      WHERE project_id = p_project AND kind = 'VIDEO_EDIT';
      IF v_mode = 'MINISTER' THEN SET v_initial = 'CHIEF'; END IF;
    ELSE
      IF p_kind <> 'GENERIC' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This project requires a generic submission';
      END IF;
  END CASE;
  IF NOT EXISTS (
    SELECT 1 FROM work_contribution wc
    JOIN membership_period mp ON mp.id = wc.membership_id
    JOIN work_item w ON w.id = wc.work_item_id
    WHERE w.project_id = p_project AND (w.id = v_work OR v_kind NOT IN ('ARTICLE','VIDEO'))
      AND mp.person_id = p_actor AND mp.left_at IS NULL
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Submitter must have an actual qualifying contribution';
  END IF;
  IF v_kind = 'VIDEO' AND NOT EXISTS (
    SELECT 1 FROM work_assignment a JOIN membership_period m ON m.id = a.membership_id
    WHERE a.work_item_id = v_work AND a.ended_at IS NULL AND m.person_id = p_actor
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Video submitter must be an assigned editor';
  END IF;
  IF v_initial = 'MINISTER' OR v_kind = 'ARTICLE' THEN
    CALL boya_reviewer(p_project, 'MINISTER', v_reviewer);
  END IF;
  CALL boya_reviewer(p_project, 'CHIEF', v_reviewer);
  CALL boya_reviewer(p_project, 'SECOND', v_reviewer);
  IF EXISTS (SELECT 1 FROM project_review_route rr
             WHERE rr.project_id = p_project AND rr.reviewer_id = p_actor
               AND (rr.stage IN ('CHIEF','SECOND')
                 OR (rr.stage = 'MINISTER' AND v_initial = 'MINISTER'))) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Submitter cannot be an applicable reviewer';
  END IF;
  CALL boya_reviewer(p_project, v_initial, v_reviewer);
  SELECT COUNT(DISTINCT a.id), SUM(a.kind = 'WORD'), SUM(a.kind = 'PHOTO'),
         SUM(a.kind = 'XIUMI_LINK'), SUM(a.kind = 'WECHAT_LINK'), SUM(a.kind = 'VIDEO_FINAL')
  INTO v_matching, v_word, v_photo, v_xiumi, v_wechat, v_video
  FROM JSON_TABLE(p_assets, '$[*]' COLUMNS (asset_id BIGINT UNSIGNED PATH '$' ERROR ON ERROR)) AS ids
  JOIN project_asset pa ON pa.project_id = p_project AND pa.asset_id = ids.asset_id
  JOIN asset a ON a.id = pa.asset_id;
  IF v_matching <> JSON_LENGTH(p_assets)
     OR (p_kind = 'XIUMI' AND (v_word < 1 OR v_photo < 1 OR v_xiumi <> 1))
     OR (p_kind = 'WECHAT' AND v_wechat <> 1)
     OR (p_kind = 'VIDEO' AND v_video < 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Submission assets are missing, duplicated or from a different project';
  END IF;
  INSERT INTO submission(project_id, version_no, previous_id, kind, start_stage,
                         submitted_by, note)
  VALUES (p_project, v_version + 1, v_last, p_kind, v_initial, p_actor, p_note);
  SET p_submission = LAST_INSERT_ID();
  INSERT INTO submission_asset(submission_id, asset_id)
  SELECT p_submission, ids.asset_id
  FROM JSON_TABLE(p_assets, '$[*]' COLUMNS (asset_id BIGINT UNSIGNED PATH '$' ERROR ON ERROR)) AS ids;
  INSERT INTO handover_record(submission_id, from_person_id, to_person_id, to_stage, note)
  VALUES (p_submission, p_actor, v_reviewer, v_initial, p_note);
  CALL boya_audit(p_actor, 'SUBMIT', 'submission', p_submission,
                  JSON_OBJECT('project_id', p_project, 'version', v_version + 1, 'initial_stage', v_initial));
  COMMIT;
END$$

CREATE PROCEDURE sp_review_submission(
  IN p_actor BIGINT UNSIGNED, IN p_submission BIGINT UNSIGNED,
  IN p_decision VARCHAR(20), IN p_feedback VARCHAR(1000)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE v_latest BIGINT UNSIGNED;
  DECLARE v_author BIGINT UNSIGNED;
  DECLARE v_kind VARCHAR(20);
  DECLARE v_initial VARCHAR(20);
  DECLARE v_third BOOLEAN;
  DECLARE v_stage VARCHAR(20);
  DECLARE v_next VARCHAR(20);
  DECLARE v_to BIGINT UNSIGNED;
  DECLARE v_reviewer BIGINT UNSIGNED;
  DECLARE v_member BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'REVIEW');
  SELECT project_id, submitted_by, kind, start_stage, third_required
  INTO v_project, v_author, v_kind, v_initial, v_third FROM submission WHERE id = p_submission;
  CALL boya_lock_project(v_project);
  SELECT id INTO v_latest FROM submission
  WHERE project_id = v_project ORDER BY version_no DESC LIMIT 1;
  SELECT to_stage, to_person_id INTO v_stage, v_to FROM handover_record
  WHERE submission_id = p_submission ORDER BY id DESC LIMIT 1;
  IF v_latest <> p_submission OR NOT (v_to <=> p_actor) OR v_author = p_actor
     OR v_stage NOT IN ('MINISTER','CHIEF','SECOND','THIRD') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This version is not pending review by this actor';
  END IF;
  CALL boya_reviewer(v_project, v_stage, v_reviewer);
  IF v_reviewer <> p_actor THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Actor is not the configured reviewer';
  END IF;
  IF v_kind = 'VIDEO' AND EXISTS (
    SELECT 1 FROM work_item w JOIN work_contribution x ON x.work_item_id = w.id
    JOIN membership_period m ON m.id = x.membership_id
    WHERE w.project_id = v_project AND w.kind = 'VIDEO_EDIT' AND m.person_id = p_actor
  ) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Video editors cannot review their own work';
  END IF;
  SELECT id INTO v_member FROM membership_period WHERE person_id = p_actor AND left_at IS NULL
    AND joined_at <= CURRENT_TIMESTAMP(6) FOR SHARE;
  SET v_to = NULL;
  IF p_decision = 'RETURNED' THEN
    SET v_next = 'REWORK';
    IF v_stage = 'MINISTER' OR (v_kind = 'VIDEO' AND v_initial = 'CHIEF') THEN
      SET v_to = v_author;
    ELSE
      CALL boya_reviewer(v_project, 'MINISTER', v_to);
    END IF;
  ELSEIF p_decision = 'APPROVED' THEN
    IF v_stage = 'SECOND' THEN
      SELECT c.requires_third_review INTO v_third
      FROM project p JOIN campaign c ON c.id = p.campaign_id
      WHERE p.id = v_project FOR SHARE;
      UPDATE submission SET third_required = v_third WHERE id = p_submission;
    END IF;
    SET v_next = CASE v_stage
      WHEN 'MINISTER' THEN IF(v_kind = 'XIUMI', 'WECHAT_DRAFT', 'CHIEF')
      WHEN 'CHIEF' THEN 'SECOND'
      WHEN 'SECOND' THEN IF(v_third, 'THIRD', 'PUBLISH')
      ELSE 'PUBLISH'
    END;
    IF v_next = 'WECHAT_DRAFT' THEN SET v_to = v_author;
    ELSEIF v_next <> 'PUBLISH' THEN CALL boya_reviewer(v_project, v_next, v_to);
    END IF;
    IF v_next IN ('CHIEF','SECOND','THIRD') AND v_to = v_author THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Submitter cannot be an applicable reviewer';
    END IF;
  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Review decision is invalid';
  END IF;
  INSERT INTO review_record(submission_id, stage, reviewer_id, membership_id, decision, feedback)
  VALUES (p_submission, v_stage, p_actor, v_member, p_decision, p_feedback);
  INSERT INTO handover_record(submission_id, from_person_id, to_person_id, to_stage)
  VALUES (p_submission, p_actor, v_to, v_next);
  CALL boya_audit(p_actor, 'REVIEW', 'review_record',
    (SELECT id FROM review_record WHERE submission_id = p_submission AND stage = v_stage),
    JSON_OBJECT('submission_id', p_submission, 'stage', v_stage, 'decision', p_decision));
  COMMIT;
END$$

CREATE PROCEDURE sp_forward_rework(
  IN p_actor BIGINT UNSIGNED, IN p_submission BIGINT UNSIGNED, IN p_note VARCHAR(500)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE v_author BIGINT UNSIGNED;
  DECLARE v_stage VARCHAR(20);
  DECLARE v_to BIGINT UNSIGNED;
  DECLARE v_minister BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'ASSIGN_WORK');
  SELECT project_id, submitted_by INTO v_project, v_author FROM submission WHERE id = p_submission;
  CALL boya_lock_project(v_project);
  CALL boya_reviewer(v_project, 'MINISTER', v_minister);
  SELECT to_stage, to_person_id INTO v_stage, v_to FROM handover_record
  WHERE submission_id = p_submission ORDER BY id DESC LIMIT 1;
  IF v_minister <> p_actor OR NOT (v_to <=> p_actor) OR v_author = p_actor
     OR NOT (v_stage <=> 'REWORK')
     OR EXISTS (SELECT 1 FROM submission WHERE previous_id = p_submission) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Version is not awaiting minister rework forwarding';
  END IF;
  CALL boya_require(v_author, 'SUBMIT');
  INSERT INTO handover_record(submission_id, from_person_id, to_person_id, to_stage, note)
  VALUES (p_submission, p_actor, v_author, 'REWORK', p_note);
  CALL boya_audit(p_actor, 'REWORK_FORWARD', 'handover_record', LAST_INSERT_ID(),
                  JSON_OBJECT('submission_id', p_submission, 'to', v_author));
  COMMIT;
END$$

CREATE PROCEDURE sp_publish(
  IN p_actor BIGINT UNSIGNED, IN p_submission BIGINT UNSIGNED,
  IN p_channel VARCHAR(60), IN p_url VARCHAR(1024)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'PUBLISH');
  SELECT project_id INTO v_project FROM submission WHERE id = p_submission;
  CALL boya_lock_project(v_project);
  INSERT INTO publication(submission_id, channel, url, published_by)
  VALUES (p_submission, p_channel, p_url, p_actor);
  COMMIT;
END$$

CREATE PROCEDURE sp_reserve_camera(
  IN p_actor BIGINT UNSIGNED, IN p_equipment BIGINT UNSIGNED, IN p_work BIGINT UNSIGNED,
  IN p_membership BIGINT UNSIGNED, IN p_start DATETIME(6), IN p_end DATETIME(6)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_CAMERA');
  CALL boya_lock_work(p_work, v_project);
  IF NOT EXISTS (SELECT 1 FROM work_item WHERE id = p_work AND kind IN ('PHOTO','VIDEO_SHOOT')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Camera use requires a photo or video shoot task';
  END IF;
  INSERT INTO equipment_usage(equipment_id, work_item_id, membership_id, reserved_by, starts_at, ends_at)
  VALUES (p_equipment, p_work, p_membership, p_actor, p_start, p_end);
  CALL boya_audit(p_actor, 'CAMERA_RESERVE', 'equipment_usage', LAST_INSERT_ID(),
                  JSON_OBJECT('equipment_id', p_equipment, 'work_item_id', p_work));
  COMMIT;
END$$

CREATE PROCEDURE sp_change_camera_usage(
  IN p_actor BIGINT UNSIGNED, IN p_usage BIGINT UNSIGNED, IN p_action VARCHAR(20)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_equipment BIGINT UNSIGNED;
  DECLARE v_lock BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL boya_require(p_actor, 'MANAGE_CAMERA');
  SELECT equipment_id INTO v_equipment FROM equipment_usage WHERE id = p_usage;
  SELECT id INTO v_lock FROM equipment WHERE id = v_equipment FOR UPDATE;
  IF p_action = 'CHECKOUT' THEN
    UPDATE equipment_usage SET checked_out_at = CURRENT_TIMESTAMP(6)
    WHERE id = p_usage AND checked_out_at IS NULL AND cancelled_at IS NULL;
  ELSEIF p_action = 'RETURN' THEN
    UPDATE equipment_usage SET returned_at = CURRENT_TIMESTAMP(6)
    WHERE id = p_usage AND checked_out_at IS NOT NULL AND returned_at IS NULL;
  ELSEIF p_action = 'CANCEL' THEN
    UPDATE equipment_usage SET cancelled_at = CURRENT_TIMESTAMP(6)
    WHERE id = p_usage AND checked_out_at IS NULL AND cancelled_at IS NULL;
  ELSE
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown camera action';
  END IF;
  IF ROW_COUNT() <> 1 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Camera usage state conflict'; END IF;
  CALL boya_audit(p_actor, 'CAMERA_USE', 'equipment_usage', p_usage, JSON_OBJECT('action', p_action));
  COMMIT;
END$$

DELIMITER ;
