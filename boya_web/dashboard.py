import json

from flask import abort, jsonify, request, session

from .auth import token_digest
from .db import call
from .manage_common import STAGES, WORK_STATES, actor, one
from .media import pending_deliveries
from .projects import pending_task_preview


WORK_TYPES = {
    "WRITING": "新闻稿撰写", "LAYOUT": "秀米排版", "PHOTO": "摄影", "VIDEO_SHOOT": "视频拍摄",
    "VIDEO_EDIT": "视频剪辑", "COPY_EDIT": "责编", "OTHER": "其他工作",
}
CAMERA_STATES = {
    "AVAILABLE": "可用", "RESERVED": "已预约", "IN_USE": "使用中", "OVERDUE": "归还逾期",
    "MAINTENANCE": "维护中", "RETIRED": "已退役", "NOT_YET_BORROWED": "待借入",
    "EXTERNAL_DUE": "待归还出借方", "RETURNED_TO_OWNER": "已归还出借方",
}


def dashboard_response():
    cohort = request.args.get("cohort_id")
    if cohort is not None:
        if not cohort.isascii() or not cohort.isdecimal() or len(cohort) > 20:
            abort(400)
        cohort = int(cohort)
        if not 0 < cohort <= 2**64 - 1:
            abort(400)

    data = call("sp_web_dashboard", (token_digest(session["auth_token"]), cohort))[0]
    result = data.pop("result_code")
    if result == "expired":
        session.clear()
        abort(401)
    if result == "forbidden":
        abort(403)
    if result == "invalid_cohort":
        abort(400)

    for key in ("cohorts", "active_campaigns", "workload", "cameras"):
        values = data[key]
        if values is not None:
            data[key] = json.loads(values)
    if data["cohort_id"] is not None:
        data["cohort_id"] = str(data["cohort_id"])
    if data["cohorts"]:
        data["cohorts"].sort(key=lambda row: (row["year"], int(row["id"])), reverse=True)
    if data["active_campaigns"]:
        data["active_campaigns"].sort(key=lambda row: (row["starts_at"], row["id"]), reverse=True)
    if data["workload"]:
        data["workload"].sort(key=lambda row: (-row["minutes"], row["type"]))
        for row in data["workload"]:
            row["label"] = WORK_TYPES[row["type"]]
    if data["cameras"]:
        data["cameras"].sort(key=lambda row: list(CAMERA_STATES).index(row["status"]))
        for row in data["cameras"]:
            row["label"] = CAMERA_STATES[row["status"]]
    if data["pending_task_count"] is not None:
        tasks = pending_task_preview()
        data["pending_task_count"] = tasks[0]["total"] if tasks else 0
        data["task_actions"] = [{"title": r["title"], "detail": f"{r['project_title']} · {WORK_STATES[r['status']]}",
                                 "label": "办理任务", "href": f"/manage/task-history?id={r['id']}"} for r in tasks]
    data["review_actions"] = [
        {"title": r["title"], "detail": f"第 {r['version_no']} 版 · {STAGES[r['stage']]}", "label": r["label"],
         "href": r["href"], "stage": r["stage"]} for r in pending_deliveries(limit=5)
    ]
    if data["pending_review_count"] == 1:
        pending = one("SELECT submission_id FROM v_pending_reviews WHERE reviewer_id=%s LIMIT 1", (actor(),))
        if pending:
            data["single_review_href"] = f"/manage/review-history?id={pending['submission_id']}"
    return jsonify(data)
