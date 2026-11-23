DELIMITER $$

CREATE TRIGGER bi_membership_period BEFORE INSERT ON membership_period FOR EACH ROW
BEGIN
  DECLARE v_person BIGINT UNSIGNED;
  DECLARE v_overlap INT;
  SELECT id INTO v_person FROM person WHERE id = NEW.person_id FOR UPDATE;
  SELECT COUNT(*) INTO v_overlap FROM membership_period
  WHERE person_id = NEW.person_id
    AND (left_at IS NULL OR left_at > NEW.joined_at)
    AND (NEW.left_at IS NULL OR joined_at < NEW.left_at) FOR SHARE;
  IF v_overlap > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Membership periods overlap';
  END IF;
  IF NEW.joined_at > CURRENT_TIMESTAMP(6) OR NEW.left_at > CURRENT_TIMESTAMP(6) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Membership dates must be effective';
  END IF;
END$$

CREATE TRIGGER bu_membership_period BEFORE UPDATE ON membership_period FOR EACH ROW
BEGIN
  IF NEW.id <> OLD.id OR NEW.person_id <> OLD.person_id OR NEW.cohort_id <> OLD.cohort_id
     OR NEW.joined_at <> OLD.joined_at OR OLD.left_at IS NOT NULL
     OR NEW.left_at IS NULL OR NEW.left_at > CURRENT_TIMESTAMP(6)
     OR EXISTS (SELECT 1 FROM membership_position
                WHERE membership_id = OLD.id
                  AND (starts_at >= NEW.left_at OR ends_at > NEW.left_at) FOR SHARE)
     OR EXISTS (SELECT 1 FROM work_assignment
                WHERE membership_id = OLD.id AND assigned_at >= NEW.left_at FOR SHARE)
     OR EXISTS (SELECT 1 FROM work_contribution
                WHERE membership_id = OLD.id AND worked_at >= NEW.left_at FOR SHARE)
     OR EXISTS (SELECT 1 FROM review_record
                WHERE membership_id = OLD.id AND reviewed_at >= NEW.left_at FOR SHARE) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Exit would invalidate membership history';
  END IF;
END$$

CREATE TRIGGER ai_membership_period AFTER INSERT ON membership_period FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'MEMBERSHIP_ADD', 'membership_period', NEW.id,
          JSON_OBJECT('person_id', NEW.person_id, 'cohort_id', NEW.cohort_id))$$

CREATE TRIGGER au_membership_period AFTER UPDATE ON membership_period FOR EACH ROW
BEGIN
  UPDATE work_assignment SET ended_at = NEW.left_at
  WHERE membership_id = NEW.id AND ended_at IS NULL;
  UPDATE account SET enabled = FALSE WHERE person_id = NEW.person_id AND enabled = TRUE;
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'MEMBERSHIP_EXIT', 'membership_period', NEW.id,
          JSON_OBJECT('person_id', NEW.person_id, 'left_at', NEW.left_at));
END$$

CREATE TRIGGER bi_membership_position BEFORE INSERT ON membership_position FOR EACH ROW
BEGIN
  DECLARE v_join DATETIME(6);
  DECLARE v_left DATETIME(6);
  DECLARE v_overlap INT;
  SELECT joined_at, left_at INTO v_join, v_left
  FROM membership_period WHERE id = NEW.membership_id FOR UPDATE;
  SELECT COUNT(*) INTO v_overlap FROM membership_position
  WHERE membership_id = NEW.membership_id
    AND (ends_at IS NULL OR ends_at > NEW.starts_at)
    AND (NEW.ends_at IS NULL OR starts_at < NEW.ends_at) FOR SHARE;
  IF NEW.starts_at < v_join OR (v_left IS NOT NULL
     AND (NEW.starts_at >= v_left OR NEW.ends_at > v_left)) OR v_overlap > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Position is outside membership or overlaps';
  END IF;
END$$

CREATE TRIGGER bu_membership_position BEFORE UPDATE ON membership_position FOR EACH ROW
BEGIN
  DECLARE v_left DATETIME(6);
  SELECT left_at INTO v_left FROM membership_period WHERE id = OLD.membership_id FOR UPDATE;
  IF NEW.id <> OLD.id OR NEW.membership_id <> OLD.membership_id
     OR NEW.position_code <> OLD.position_code OR NEW.starts_at <> OLD.starts_at
     OR OLD.ends_at IS NOT NULL OR NEW.ends_at IS NULL
     OR (v_left IS NOT NULL AND NEW.ends_at > v_left) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only closing an open position is allowed';
  END IF;
END$$

CREATE TRIGGER ai_account AFTER INSERT ON account FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'ACCOUNT_ADD', 'account', NEW.id,
          JSON_OBJECT('enabled', NEW.enabled))$$

CREATE TRIGGER au_account AFTER UPDATE ON account FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'ACCOUNT_CHANGE', 'account', NEW.id,
          JSON_OBJECT('enabled', NEW.enabled, 'hash_changed', NEW.password_hash <> OLD.password_hash))$$

CREATE TRIGGER ai_account_role AFTER INSERT ON account_role FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'ACCOUNT_ROLE_GRANT', 'account', NEW.account_id,
          JSON_OBJECT('role', NEW.role_code))$$

CREATE TRIGGER ad_account_role AFTER DELETE ON account_role FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'ACCOUNT_ROLE_REVOKE', 'account', OLD.account_id,
          JSON_OBJECT('role', OLD.role_code))$$

CREATE TRIGGER ai_role_permission AFTER INSERT ON role_permission FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'ROLE_PERMISSION_GRANT', 'role_permission', 0,
          JSON_OBJECT('role', NEW.role_code, 'permission', NEW.permission_code))$$

CREATE TRIGGER ad_role_permission AFTER DELETE ON role_permission FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NULL, SESSION_USER(), 'ROLE_PERMISSION_REVOKE', 'role_permission', 0,
          JSON_OBJECT('role', OLD.role_code, 'permission', OLD.permission_code))$$

CREATE TRIGGER bu_work_item BEFORE UPDATE ON work_item FOR EACH ROW
BEGIN
  IF NEW.id <> OLD.id OR NEW.project_id <> OLD.project_id OR NEW.kind <> OLD.kind
     OR NOT (NEW.editing_mode <=> OLD.editing_mode) OR NEW.is_required <> OLD.is_required
     OR NEW.lock_version <> OLD.lock_version + 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Work identity is fixed and lock_version must advance';
  END IF;
END$$

CREATE TRIGGER ai_work_item AFTER INSERT ON work_item FOR EACH ROW
  INSERT INTO work_status_history(work_item_id, old_status, new_status, lock_version, changed_by)
  VALUES (NEW.id, NULL, NEW.status, NEW.lock_version, NEW.changed_by)$$

CREATE TRIGGER au_work_item AFTER UPDATE ON work_item FOR EACH ROW
BEGIN
  IF NEW.status <> OLD.status THEN
    INSERT INTO work_status_history(work_item_id, old_status, new_status, lock_version, changed_by)
    VALUES (NEW.id, OLD.status, NEW.status, NEW.lock_version, NEW.changed_by);
    INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
    VALUES (NEW.changed_by, SESSION_USER(), 'WORK_STATUS', 'work_item', NEW.id,
            JSON_OBJECT('from', OLD.status, 'to', NEW.status, 'version', NEW.lock_version));
  END IF;
END$$

CREATE TRIGGER bi_work_assignment BEFORE INSERT ON work_assignment FOR EACH ROW
BEGIN
  DECLARE v_kind VARCHAR(20);
  DECLARE v_mode VARCHAR(12);
  DECLARE v_join DATETIME(6);
  DECLARE v_left DATETIME(6);
  DECLARE v_position VARCHAR(20);
  DECLARE v_active INT;
  SELECT kind, editing_mode INTO v_kind, v_mode
  FROM work_item WHERE id = NEW.work_item_id FOR UPDATE;
  SELECT joined_at, left_at INTO v_join, v_left
  FROM membership_period WHERE id = NEW.membership_id FOR UPDATE;
  IF v_left IS NOT NULL OR v_join > NEW.assigned_at OR NEW.assigned_at > CURRENT_TIMESTAMP(6)
     OR NEW.ended_at IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'New assignment requires an active member';
  END IF;
  IF v_kind IN ('WRITING','LAYOUT','VIDEO_EDIT','PHOTO','VIDEO_SHOOT','COPY_EDIT') THEN
    SELECT MAX(position_code) INTO v_position FROM membership_position
    WHERE membership_id = NEW.membership_id AND starts_at <= NEW.assigned_at
      AND (ends_at IS NULL OR ends_at > NEW.assigned_at) FOR SHARE;
    IF NOT (v_position <=> CASE WHEN v_kind = 'COPY_EDIT' THEN 'CHIEF'
                                WHEN v_mode = 'MINISTER' THEN 'MINISTER'
                                ELSE 'MEMBER' END) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Assignment requires the appropriate organization position';
    END IF;
  END IF;
  IF v_kind IN ('WRITING','LAYOUT') OR v_mode = 'MINISTER' THEN
    SELECT COUNT(*) INTO v_active FROM work_assignment
    WHERE work_item_id = NEW.work_item_id AND ended_at IS NULL FOR SHARE;
    IF v_active > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This work item has only one assignment slot';
    END IF;
  END IF;
END$$

CREATE TRIGGER bu_work_assignment BEFORE UPDATE ON work_assignment FOR EACH ROW
BEGIN
  IF NEW.id <> OLD.id OR NEW.work_item_id <> OLD.work_item_id OR NEW.membership_id <> OLD.membership_id
     OR NEW.assigned_at <> OLD.assigned_at OR NEW.assigned_by <> OLD.assigned_by
     OR OLD.ended_at IS NOT NULL OR NEW.ended_at IS NULL OR NEW.ended_at > CURRENT_TIMESTAMP(6) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only ending an active assignment is allowed';
  END IF;
END$$

CREATE TRIGGER bi_work_contribution BEFORE INSERT ON work_contribution FOR EACH ROW
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE v_join DATETIME(6);
  DECLARE v_left DATETIME(6);
  DECLARE v_kind VARCHAR(20);
  DECLARE v_mode VARCHAR(12);
  DECLARE v_position VARCHAR(20);
  DECLARE v_other INT;
  SELECT project_id, kind, editing_mode INTO v_project, v_kind, v_mode
  FROM work_item WHERE id = NEW.work_item_id;
  SELECT id INTO v_project FROM project WHERE id = v_project FOR UPDATE;
  SELECT joined_at, left_at INTO v_join, v_left
  FROM membership_period WHERE id = NEW.membership_id FOR UPDATE;
  IF NEW.worked_at < v_join OR NEW.worked_at >= v_left OR NEW.worked_at > CURRENT_TIMESTAMP(6) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Contribution must occur during membership';
  END IF;
  IF v_kind IN ('WRITING','LAYOUT','PHOTO','VIDEO_SHOOT','VIDEO_EDIT','COPY_EDIT') THEN
    SELECT MAX(position_code) INTO v_position FROM membership_position
    WHERE membership_id = NEW.membership_id AND starts_at <= NEW.worked_at
      AND (ends_at IS NULL OR ends_at > NEW.worked_at) FOR SHARE;
    IF NOT (v_position <=> CASE WHEN v_kind = 'COPY_EDIT' THEN 'CHIEF'
                                WHEN v_mode = 'MINISTER' THEN 'MINISTER'
                                ELSE 'MEMBER' END) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Contributor organization position is invalid';
    END IF;
  END IF;
  IF v_kind IN ('WRITING','LAYOUT') OR v_mode = 'MINISTER' THEN
    SELECT COUNT(*) INTO v_other FROM work_contribution
    WHERE work_item_id = NEW.work_item_id AND membership_id <> NEW.membership_id FOR SHARE;
    IF v_other > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This work item has a single contributor';
    END IF;
  END IF;
END$$

CREATE TRIGGER bi_publication BEFORE INSERT ON publication FOR EACH ROW
BEGIN
  DECLARE v_project BIGINT UNSIGNED;
  DECLARE v_latest BIGINT UNSIGNED;
  DECLARE v_kind VARCHAR(20);
  DECLARE v_start VARCHAR(20);
  DECLARE v_third BOOLEAN;
  DECLARE v_stage VARCHAR(20);
  DECLARE v_approved INT;
  DECLARE v_unfinished INT;
  DECLARE v_work INT;
  SELECT project_id, kind, start_stage, third_required INTO v_project, v_kind, v_start, v_third
  FROM submission WHERE id = NEW.submission_id;
  SELECT id INTO v_project FROM project WHERE id = v_project AND delivery_mode = 'REVIEWED' FOR UPDATE;
  SELECT id INTO v_latest FROM submission
  WHERE project_id = v_project ORDER BY version_no DESC LIMIT 1 FOR SHARE;
  SELECT to_stage INTO v_stage FROM handover_record
  WHERE submission_id = NEW.submission_id ORDER BY id DESC LIMIT 1 FOR SHARE;
  SELECT COUNT(*) INTO v_approved FROM review_record
  WHERE submission_id = NEW.submission_id AND decision = 'APPROVED'
    AND (stage IN ('CHIEF','SECOND') OR (stage = 'MINISTER' AND v_start = 'MINISTER')
       OR (stage = 'THIRD' AND v_third)) FOR SHARE;
  SELECT COUNT(*), COALESCE(SUM(status <> 'DONE'), 0) INTO v_work, v_unfinished
  FROM work_item WHERE project_id = v_project AND is_required FOR SHARE;
  IF NOT (v_latest <=> NEW.submission_id) OR v_kind = 'XIUMI' OR v_third IS NULL
     OR NOT (v_stage <=> 'PUBLISH') OR v_approved <> 2 + (v_start = 'MINISTER') + v_third
     OR v_work = 0 OR v_unfinished > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Publication requires current approved version and finished work';
  END IF;
END$$

CREATE TRIGGER ai_publication AFTER INSERT ON publication FOR EACH ROW
  INSERT INTO audit_log(actor_id, db_session_user, action_code, entity_type, entity_id, detail)
  VALUES (NEW.published_by, SESSION_USER(), 'PUBLISH', 'publication', NEW.id,
          JSON_OBJECT('submission_id', NEW.submission_id, 'channel', NEW.channel))$$

CREATE TRIGGER bi_equipment_usage BEFORE INSERT ON equipment_usage FOR EACH ROW
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_borrowed DATETIME(6);
  DECLARE v_due DATETIME(6);
  DECLARE v_external_returned DATETIME(6);
  DECLARE v_left DATETIME(6);
  DECLARE v_conflict INT;
  SELECT inventory_status, borrowed_at, due_back_at, external_returned_at
  INTO v_status, v_borrowed, v_due, v_external_returned
  FROM equipment WHERE id = NEW.equipment_id FOR UPDATE;
  SELECT left_at INTO v_left FROM membership_period WHERE id = NEW.membership_id FOR UPDATE;
  IF v_status <> 'AVAILABLE' OR v_left IS NOT NULL OR v_external_returned IS NOT NULL
     OR NEW.starts_at < v_borrowed OR NEW.ends_at > v_due
     OR NEW.checked_out_at IS NOT NULL OR NEW.returned_at IS NOT NULL OR NEW.cancelled_at IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Camera or member is unavailable for reservation';
  END IF;
  SELECT COUNT(*) INTO v_conflict FROM equipment_usage
  WHERE equipment_id = NEW.equipment_id AND cancelled_at IS NULL
    AND starts_at < NEW.ends_at AND ends_at > NEW.starts_at FOR SHARE;
  IF v_conflict > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Camera reservation overlaps';
  END IF;
END$$

CREATE TRIGGER bu_equipment_usage BEFORE UPDATE ON equipment_usage FOR EACH ROW
BEGIN
  DECLARE v_status VARCHAR(20);
  DECLARE v_external_returned DATETIME(6);
  DECLARE v_left DATETIME(6);
  DECLARE v_conflict INT;
  SELECT inventory_status, external_returned_at INTO v_status, v_external_returned
    FROM equipment WHERE id = OLD.equipment_id FOR UPDATE;
  IF NEW.id <> OLD.id OR NEW.equipment_id <> OLD.equipment_id OR NEW.work_item_id <> OLD.work_item_id
     OR NEW.membership_id <> OLD.membership_id OR NEW.reserved_by <> OLD.reserved_by
     OR NEW.starts_at <> OLD.starts_at OR NEW.ends_at <> OLD.ends_at
     OR OLD.cancelled_at IS NOT NULL OR OLD.returned_at IS NOT NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation identity and closed reservations are fixed';
  END IF;
  IF OLD.checked_out_at IS NULL AND NEW.checked_out_at IS NOT NULL THEN
    SELECT left_at INTO v_left FROM membership_period WHERE id = OLD.membership_id FOR UPDATE;
    SELECT COUNT(*) INTO v_conflict FROM equipment_usage
    WHERE equipment_id = OLD.equipment_id AND id <> OLD.id
      AND checked_out_at IS NOT NULL AND returned_at IS NULL FOR SHARE;
    IF v_conflict > 0 OR v_status <> 'AVAILABLE' OR v_external_returned IS NOT NULL
       OR v_left IS NOT NULL OR NEW.returned_at IS NOT NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Camera cannot be checked out';
    END IF;
  ELSEIF OLD.checked_out_at IS NOT NULL THEN
    IF NOT (OLD.checked_out_at <=> NEW.checked_out_at) OR NEW.returned_at IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'An active checkout can only be returned';
    END IF;
  ELSEIF NEW.cancelled_at IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation update needs a checkout, return or cancellation';
  END IF;
END$$

CREATE TRIGGER bu_audit_log BEFORE UPDATE ON audit_log FOR EACH ROW
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Audit log is append-only'$$

CREATE TRIGGER bd_audit_log BEFORE DELETE ON audit_log FOR EACH ROW
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Audit log is append-only'$$

DELIMITER ;
