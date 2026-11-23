CREATE SQL SECURITY DEFINER VIEW v_current_members AS
SELECT m.id AS membership_id, p.id AS person_id, p.person_code, p.display_name,
       c.id AS cohort_id, c.code AS cohort_code, m.joined_at,
       mp.position_code
FROM membership_period m
JOIN person p ON p.id = m.person_id
JOIN cohort c ON c.id = m.cohort_id
LEFT JOIN membership_position mp ON mp.membership_id = m.id
  AND mp.starts_at <= CURRENT_TIMESTAMP(6)
  AND (mp.ends_at IS NULL OR mp.ends_at > CURRENT_TIMESTAMP(6))
WHERE m.joined_at <= CURRENT_TIMESTAMP(6) AND m.left_at IS NULL;

CREATE SQL SECURITY DEFINER VIEW v_member_workload AS
WITH actual_work AS (
  SELECT wc.membership_id, CAST(w.kind AS CHAR(16)) AS work_type,
         DATE(wc.worked_at) AS work_date, wc.minutes_spent
  FROM work_contribution wc
  JOIN work_item w ON w.id = wc.work_item_id
  UNION ALL
  SELECT r.membership_id, 'REVIEW', DATE(r.reviewed_at), NULL
  FROM review_record r
  WHERE r.membership_id IS NOT NULL
)
SELECT m.id AS membership_id, p.id AS person_id, p.display_name,
       c.id AS cohort_id, c.code AS cohort_code,
       a.work_type, a.work_date, COUNT(*) AS entry_count,
       SUM(a.minutes_spent) AS minutes_spent
FROM actual_work a
JOIN membership_period m ON m.id = a.membership_id
JOIN person p ON p.id = m.person_id
JOIN cohort c ON c.id = m.cohort_id
GROUP BY m.id, p.id, p.display_name, c.id, c.code, a.work_type, a.work_date;

CREATE SQL SECURITY DEFINER VIEW v_pending_reviews AS
SELECT s.project_id, p.title AS project_title, s.id AS submission_id,
       s.version_no, s.kind AS submission_kind, h.to_stage AS review_stage,
       h.to_person_id AS reviewer_id, person.display_name AS reviewer_name, h.handed_at
FROM submission s
JOIN project p ON p.id = s.project_id
JOIN handover_record h ON h.submission_id = s.id
JOIN person ON person.id = h.to_person_id
WHERE h.to_stage IN ('MINISTER','CHIEF','SECOND','THIRD')
  AND NOT EXISTS (SELECT 1 FROM submission newer WHERE newer.previous_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM handover_record newer
                  WHERE newer.submission_id = s.id AND newer.id > h.id)
  AND NOT EXISTS (SELECT 1 FROM review_record r
                  WHERE r.submission_id = s.id AND r.stage = h.to_stage);

CREATE SQL SECURITY DEFINER VIEW v_campaign_progress AS
WITH work_stats AS (
  SELECT project_id, COUNT(*) AS required_work,
         SUM(status = 'DONE') AS complete_work,
         SUM(status <> 'TODO') AS started_work
  FROM work_item WHERE is_required = TRUE
  GROUP BY project_id
), progress AS (
  SELECT c.id AS campaign_id, c.code AS campaign_code, c.title AS campaign_title,
         p.id AS project_id, p.code AS project_code, p.title AS project_title,
         p.is_required, p.kind AS project_kind,
         COALESCE(ws.required_work, 0) AS required_work,
         COALESCE(ws.complete_work, 0) AS complete_work,
         CASE
           WHEN p.id IS NULL THEN NULL
           WHEN pub.id IS NOT NULL THEN 'PUBLISHED'
           WHEN p.delivery_mode = 'WORK_ONLY' AND ws.required_work = ws.complete_work THEN 'COMPLETED'
           WHEN h.to_stage = 'PUBLISH' THEN 'READY_TO_PUBLISH'
           WHEN h.to_stage = 'REWORK' THEN 'RETURNED'
           WHEN h.to_stage IN ('MINISTER','CHIEF','SECOND','THIRD') THEN 'IN_REVIEW'
           WHEN s.id IS NOT NULL OR ws.started_work > 0 THEN 'IN_PROGRESS'
           ELSE 'PLANNED'
         END AS project_status
  FROM campaign c
  LEFT JOIN project p ON p.campaign_id = c.id
  LEFT JOIN work_stats ws ON ws.project_id = p.id
  LEFT JOIN submission s ON s.project_id = p.id
    AND NOT EXISTS (SELECT 1 FROM submission newer WHERE newer.previous_id = s.id)
  LEFT JOIN handover_record h ON h.submission_id = s.id
    AND NOT EXISTS (SELECT 1 FROM handover_record newer
                    WHERE newer.submission_id = s.id AND newer.id > h.id)
  LEFT JOIN publication pub ON pub.submission_id = s.id
), totals AS (
  SELECT progress.*,
         SUM(IF(is_required = TRUE, 1, 0)) OVER (PARTITION BY campaign_id) AS campaign_required_projects,
         SUM(IF(is_required = TRUE AND project_status IN ('PUBLISHED','COMPLETED'), 1, 0))
            OVER (PARTITION BY campaign_id) AS campaign_completed_projects
  FROM progress
)
SELECT totals.*,
       ROUND(100 * campaign_completed_projects / NULLIF(campaign_required_projects, 0), 2)
         AS campaign_percent
FROM totals;

CREATE SQL SECURITY DEFINER VIEW v_equipment_status AS
SELECT e.id AS equipment_id, e.code, e.name, e.model, e.source, e.inventory_status,
       e.borrowed_at, e.due_back_at, e.external_returned_at,
       active.id AS current_usage_id, m.person_id AS current_user_id,
       p.display_name AS current_user_name, w.id AS current_work_id, w.title AS current_work_title,
       active.starts_at, active.ends_at, active.checked_out_at,
       CASE
         WHEN e.external_returned_at IS NOT NULL THEN 'RETURNED_TO_OWNER'
         WHEN active.checked_out_at IS NOT NULL AND active.ends_at <= CURRENT_TIMESTAMP(6) THEN 'OVERDUE'
         WHEN active.checked_out_at IS NOT NULL THEN 'IN_USE'
         WHEN e.inventory_status <> 'AVAILABLE' THEN e.inventory_status
         WHEN e.source = 'BORROWED' AND e.borrowed_at > CURRENT_TIMESTAMP(6) THEN 'NOT_YET_BORROWED'
         WHEN e.source = 'BORROWED' AND e.due_back_at <= CURRENT_TIMESTAMP(6) THEN 'EXTERNAL_DUE'
         WHEN active.id IS NOT NULL THEN 'RESERVED'
         ELSE 'AVAILABLE'
       END AS current_status,
       (SELECT MIN(future.starts_at) FROM equipment_usage future
        WHERE future.equipment_id = e.id AND future.cancelled_at IS NULL
          AND future.starts_at > CURRENT_TIMESTAMP(6)) AS next_reservation
FROM equipment e
LEFT JOIN equipment_usage active ON active.id = (
  SELECT u.id FROM equipment_usage u
  WHERE u.equipment_id = e.id AND u.cancelled_at IS NULL AND u.returned_at IS NULL
    AND (u.checked_out_at IS NOT NULL
      OR (u.starts_at <= CURRENT_TIMESTAMP(6) AND u.ends_at > CURRENT_TIMESTAMP(6)))
  ORDER BY (u.checked_out_at IS NOT NULL) DESC, u.starts_at, u.id LIMIT 1
)
LEFT JOIN membership_period m ON m.id = active.membership_id
LEFT JOIN person p ON p.id = m.person_id
LEFT JOIN work_item w ON w.id = active.work_item_id;
