from flask import abort

from .db import query
from .manage_common import actor, allowed, option_rows, required_row, require_permission


PROJECTS = """
SELECT p.*, c.title AS campaign_title, c.created_by AS campaign_owner
FROM project p JOIN campaign c ON c.id=p.campaign_id
"""
OWNER = "(p.created_by=%s OR c.created_by=%s)"
PROJECT_ACCESS = f"""
(
  (%s AND {OWNER})
  OR EXISTS (SELECT 1 FROM work_item w JOIN v_web_assigned_tasks a ON a.work_id=w.id
             WHERE w.project_id=p.id AND a.person_id=%s)
  OR EXISTS (SELECT 1 FROM work_item w JOIN work_contribution a ON a.work_item_id=w.id
             JOIN membership_period m ON m.id=a.membership_id
             WHERE w.project_id=p.id AND m.person_id=%s)
  OR EXISTS (SELECT 1 FROM submission s WHERE s.project_id=p.id AND
             (s.submitted_by=%s
              OR EXISTS (SELECT 1 FROM review_record r WHERE r.submission_id=s.id AND r.reviewer_id=%s)
              OR EXISTS (SELECT 1 FROM handover_record h WHERE h.submission_id=s.id AND h.to_person_id=%s)))
)
"""


def scope_params():
    return (allowed("MANAGE_PROJECT"), *((actor(),) * 7))


def project_rows(kind=None, *, include_closed=True):
    return query(
        PROJECTS + " WHERE " + PROJECT_ACCESS
        + (" AND p.kind=%s" if kind else "")
        + ("" if include_closed else " AND NOT EXISTS ("
           "SELECT 1 FROM publication pub JOIN submission s ON s.id=pub.submission_id WHERE s.project_id=p.id)")
        + " ORDER BY p.id DESC",
        (*scope_params(), *((kind,) if kind else ())),
    )


def read_project(project_id):
    return required_row(PROJECTS + " WHERE p.id=%s AND " + PROJECT_ACCESS, (project_id, *scope_params()))


def owns(project):
    return allowed("MANAGE_PROJECT") and actor() in (project["created_by"], project["campaign_owner"])


def manage_project(project_id, permission="MANAGE_PROJECT"):
    require_permission(permission)
    project = read_project(project_id)
    if not owns(project):
        abort(403, "只能维护自己管理的项目。")
    return project


def manage_campaign(campaign_id):
    require_permission("MANAGE_PROJECT")
    return required_row("SELECT * FROM campaign WHERE id=%s AND created_by=%s", (campaign_id, actor()))


def read_task(work_id, *, managed=False):
    work = required_row("SELECT * FROM work_item WHERE id=%s", (work_id,))
    if managed:
        manage_project(work["project_id"])
    else:
        project = read_project(work["project_id"])
        if not owns(project):
            required_row("SELECT work_id FROM v_web_assigned_tasks WHERE work_id=%s AND person_id=%s",
                         (work_id, actor()))
    return work


def membership_options():
    return option_rows("SELECT membership_id AS id, CONCAT(display_name,' · ',cohort_code) AS label "
                       "FROM v_current_members ORDER BY display_name")
