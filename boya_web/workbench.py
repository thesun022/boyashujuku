from flask import Blueprint, abort, g, jsonify, render_template, request

from .auth import login_required, require
from .dashboard import dashboard_response
from .db import query


workbench = Blueprint("workbench", __name__)
PAGE_SIZE = 20
STATUS_LABELS = {"TODO": "待处理", "IN_PROGRESS": "进行中", "BLOCKED": "受阻",
                 "DONE": "已完成", "CANCELLED": "已取消"}


@workbench.get("/")
@login_required
def home():
    return render_template("home.html")


@workbench.get("/api/dashboard")
@login_required
def api_dashboard():
    return dashboard_response()


@workbench.get("/tasks")
@require("LOG_WORK")
def tasks():
    return render_template("records.html", title="我的任务", category="tasks",
                           endpoint="/api/tasks", columns=("任务", "项目", "状态", "更新时间"))


@workbench.get("/reviews")
@require("REVIEW")
def reviews():
    return render_template("records.html", title="待我审核", category="reviews",
                           endpoint="/api/reviews", columns=("项目", "版本", "审核阶段", "交接时间"))


@workbench.get("/api/me")
@login_required
def api_me():
    who = g.identity
    return jsonify(person_id=who.person_id, username=who.username, display_name=who.display_name,
                   roles=who.roles, permissions=sorted(who.permissions), titles=who.titles)


def page_params():
    page = request.args.get("page", "1", type=str)
    term = request.args.get("q", "").strip()
    if not page.isascii() or not page.isdecimal() or len(page) > 6 or int(page) < 1 or len(term) > 80:
        abort(400)
    return int(page), term


def paginate(sql, arguments, timestamp_column):
    page, term = page_params()
    rows = query(sql, (*arguments, term, PAGE_SIZE + 1, (page - 1) * PAGE_SIZE))
    for row in rows:
        row[timestamp_column] = row[timestamp_column].isoformat(timespec="seconds")
    return jsonify(items=rows[:PAGE_SIZE], page=page, has_next=len(rows) > PAGE_SIZE)


@workbench.get("/api/tasks")
@require("LOG_WORK")
def api_tasks():
    return paginate(
        """
        SELECT work_id, title, project_title, campaign_title, status, updated_at
        FROM v_web_assigned_tasks
        WHERE person_id = %s AND LOCATE(%s, CONCAT_WS(' ', title, project_title, campaign_title)) > 0
        ORDER BY updated_at DESC, work_id
        LIMIT %s OFFSET %s
        """, (g.identity.person_id,), "updated_at",
    )


@workbench.get("/api/tasks/<int:work_id>")
@require("LOG_WORK")
def api_task(work_id):
    rows = query(
        """
        SELECT work_id, title, kind, project_title, campaign_title, status, updated_at
        FROM v_web_assigned_tasks WHERE person_id = %s AND work_id = %s
        """, (g.identity.person_id, work_id),
    )
    if not rows:
        abort(404)
    task = rows[0]
    task["updated_at"] = task["updated_at"].isoformat(timespec="seconds")
    task["status_label"] = STATUS_LABELS.get(task["status"], task["status"])
    return jsonify(task)


@workbench.get("/api/reviews")
@require("REVIEW")
def api_reviews():
    return paginate(
        """
        SELECT submission_id, project_title, version_no, review_stage, handed_at
        FROM v_pending_reviews
        WHERE reviewer_id = %s AND LOCATE(%s, project_title) > 0
        ORDER BY handed_at DESC, submission_id
        LIMIT %s OFFSET %s
        """, (g.identity.person_id,), "handed_at",
    )


@workbench.get("/api/reviews/<int:submission_id>")
@require("REVIEW")
def api_review(submission_id):
    rows = query(
        """
        SELECT submission_id, project_title, version_no, submission_kind, review_stage, handed_at
        FROM v_pending_reviews WHERE reviewer_id = %s AND submission_id = %s
        """, (g.identity.person_id, submission_id),
    )
    if not rows:
        abort(404)
    review = rows[0]
    review["handed_at"] = review["handed_at"].isoformat(timespec="seconds")
    return jsonify(review)
