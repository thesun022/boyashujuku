-- Proposed Web phase extension. Apply on a prepared test copy before formal approval.
CREATE TABLE web_session (
  token_hash BINARY(32) PRIMARY KEY,
  account_id BIGINT UNSIGNED NOT NULL,
  created_at DATETIME(6) NOT NULL,
  expires_at DATETIME(6) NOT NULL,
  INDEX ix_web_session_account (account_id),
  INDEX ix_web_session_expiry (expires_at),
  CONSTRAINT fk_web_session_account FOREIGN KEY (account_id) REFERENCES account(id) ON DELETE CASCADE,
  CONSTRAINT ck_web_session_dates CHECK (expires_at > created_at)
) ENGINE=InnoDB;

CREATE SQL SECURITY DEFINER VIEW v_web_assigned_tasks AS
SELECT m.person_id, w.id AS work_id, w.title, w.kind, w.status, w.updated_at,
       p.title AS project_title, c.title AS campaign_title
FROM work_assignment a
JOIN membership_period m ON m.id = a.membership_id
JOIN work_item w ON w.id = a.work_item_id
JOIN project p ON p.id = w.project_id
JOIN campaign c ON c.id = p.campaign_id
WHERE a.ended_at IS NULL AND m.left_at IS NULL AND m.joined_at <= CURRENT_TIMESTAMP(6);

DELIMITER $$

CREATE PROCEDURE sp_web_subject(IN p_username VARCHAR(80))
SQL SECURITY DEFINER READS SQL DATA
  SELECT id AS account_id, password_hash, enabled FROM account WHERE username = p_username$$

CREATE PROCEDURE sp_web_open_session(
  IN p_account_id BIGINT UNSIGNED, IN p_verified_hash VARCHAR(255), IN p_token_hash BINARY(32)
)
SQL SECURITY DEFINER MODIFIES SQL DATA
BEGIN
  DECLARE v_enabled BOOLEAN DEFAULT FALSE;
  DECLARE v_password_hash VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin;
  DECLARE v_created BOOLEAN DEFAULT FALSE;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  SELECT enabled, password_hash INTO v_enabled, v_password_hash FROM account
  WHERE id = p_account_id FOR UPDATE;
  IF v_enabled AND BINARY v_password_hash = BINARY p_verified_hash THEN
    INSERT INTO web_session(token_hash,account_id,created_at,expires_at)
    VALUES (p_token_hash,p_account_id,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6) + INTERVAL 8 HOUR);
    SET v_created = TRUE;
  END IF;
  COMMIT;
  SELECT v_created AS created;
END$$

CREATE PROCEDURE sp_web_read_session(IN p_token_hash BINARY(32))
SQL SECURITY DEFINER READS SQL DATA
  SELECT a.id AS account_id, a.username, p.id AS person_id, p.display_name,
         m.position_code, ar.role_code, sr.label AS role_label, rp.permission_code,
         (SELECT GROUP_CONCAT(DISTINCT rr.stage ORDER BY rr.stage)
          FROM project_review_route rr WHERE rr.reviewer_id = p.id) AS review_stages
  FROM web_session s
  JOIN account a ON a.id = s.account_id
  JOIN person p ON p.id = a.person_id
  LEFT JOIN v_current_members m ON m.person_id = p.id
  LEFT JOIN account_role ar ON ar.account_id = a.id
  LEFT JOIN system_role sr ON sr.code = ar.role_code
  LEFT JOIN role_permission rp ON rp.role_code = ar.role_code
  WHERE s.token_hash = p_token_hash AND s.expires_at > UTC_TIMESTAMP(6) AND a.enabled = TRUE
  ORDER BY ar.role_code, rp.permission_code$$

CREATE PROCEDURE sp_web_close_session(IN p_token_hash BINARY(32))
SQL SECURITY DEFINER MODIFIES SQL DATA
  DELETE FROM web_session WHERE token_hash = p_token_hash$$

CREATE TRIGGER au_account_web_revoke AFTER UPDATE ON account FOR EACH ROW
BEGIN
  IF OLD.enabled <> NEW.enabled OR OLD.password_hash <> NEW.password_hash THEN
    DELETE FROM web_session WHERE account_id = NEW.id;
  END IF;
END$$

DELIMITER ;

CREATE ROLE 'boya_web_auth'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_web_subject TO 'boya_web_auth'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_web_open_session TO 'boya_web_auth'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_web_read_session TO 'boya_web_auth'@'%';
GRANT EXECUTE ON PROCEDURE boya_media_center.sp_web_close_session TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.v_web_assigned_tasks TO 'boya_web_auth'@'%';
GRANT SELECT ON boya_media_center.v_pending_reviews TO 'boya_web_auth'@'%';
