import json
from contextlib import contextmanager
from datetime import date, datetime
from urllib.parse import urlsplit

from flask import abort, g, request

from .db import call, get_db, query


WORK_KINDS = {"WRITING": "撰稿", "LAYOUT": "排版", "PHOTO": "摄影", "VIDEO_SHOOT": "视频拍摄",
              "VIDEO_EDIT": "视频剪辑", "COPY_EDIT": "责编", "OTHER": "其他"}
PROJECT_KINDS = {"ARTICLE": "推文", "VIDEO": "视频", "PHOTO": "摄影", "OTHER": "其他"}
WORK_STATES = {"TODO": "待处理", "IN_PROGRESS": "进行中", "BLOCKED": "受阻", "DONE": "已完成", "CANCELLED": "已取消"}
PROJECT_STATES = {"PLANNED": "待开始", "IN_PROGRESS": "进行中", "IN_REVIEW": "审核中", "RETURNED": "已退回",
                  "READY_TO_PUBLISH": "待发布", "COMPLETED": "已完成", "PUBLISHED": "已发布（已完成）"}
STAGES = {"MINISTER": "部长初审", "CHIEF": "主编审核", "SECOND": "二审", "THIRD": "三审",
          "REWORK": "退回修改", "WECHAT_DRAFT": "待同步草稿", "PUBLISH": "待发布"}


def allowed(permission):
    return permission in g.identity.permissions


def require_permission(permission):
    if not allowed(permission):
        abort(403)


def actor():
    return g.identity.person_id


def one(sql, params=()):
    rows = query(sql, params)
    return rows[0] if rows else None


def required_row(sql, params=()):
    row = one(sql, params)
    if row is None:
        abort(404)
    return row


def execute(sql, params=()):
    with get_db().cursor() as cursor:
        cursor.execute(sql, params)
        return cursor.lastrowid or cursor.rowcount


@contextmanager
def transaction():
    connection = get_db()
    connection.begin()
    try:
        yield
        connection.commit()
    except Exception:
        connection.rollback()
        raise


def audit(action, entity, key, detail=None):
    execute(
        """INSERT INTO audit_log(actor_id,db_session_user,action_code,entity_type,entity_id,detail)
           VALUES (%s,SESSION_USER(),%s,%s,%s,%s)""",
        (actor(), action, entity, key, json.dumps(detail, ensure_ascii=False) if detail else None),
    )


def invoke(name, *params, output=False):
    if output:
        with get_db().cursor() as cursor:
            cursor.execute("SET @boya_result = NULL")
            # Procedure names originate from internal call sites only.
            arguments = ",".join(["%s"] * (len(params) + 1) + ["@boya_result"])
            cursor.execute(f"CALL {name}({arguments})", (actor(), *params))
            while cursor.nextset():
                pass
            cursor.execute("SELECT @boya_result AS result")
            return cursor.fetchone()["result"]
    return call(name, (actor(), *params))


def body():
    return request.form if request.mimetype == "multipart/form-data" else (request.get_json(silent=True) or {})


def text(data, key, limit, optional=False):
    value = data.get(key)
    if value is None and optional:
        return None
    if not isinstance(value, str) or len(value.strip()) > limit or (not value.strip() and not optional):
        abort(400, f"请填写有效的 {key}。")
    return value.strip() or None


def number(data, key, *, minimum=1, maximum=2**64 - 1, optional=False):
    value = data.get(key)
    if (value is None or value == "") and optional:
        return None
    try:
        if isinstance(value, bool) or not str(value).isascii() or not str(value).isdecimal() or len(str(value)) > 20:
            raise ValueError
        converted = int(value)
        if not minimum <= converted <= maximum:
            raise ValueError
    except (ValueError, TypeError):
        abort(400, f"{key} 不是有效的编号或数值。")
    return converted


def choices(data, key, options):
    value = text(data, key, 80)
    if value not in options:
        abort(400, f"{key} 选项无效。")
    return value


def selected(data, key):
    values = data.getlist(key) if hasattr(data, "getlist") else data.get(key, [])
    if not isinstance(values, list) or len(values) > 100:
        abort(400, "选择数量无效。")
    return list(dict.fromkeys(number({"id": value}, "id") for value in values))


def date_time(data, key, optional=False):
    value = text(data, key, 32, optional)
    if value is None:
        return None
    try:
        value = datetime.fromisoformat(value)
        if value.tzinfo or value.year < 1900:
            raise ValueError
        return value
    except ValueError:
        abort(400, "请输入有效的北京时间。")


def https_link(data, key="url"):
    value = text(data, key, 1024)
    try:
        parts = urlsplit(value)
        if parts.scheme != "https" or not parts.hostname or parts.username or any(c.isspace() for c in value):
            raise ValueError
    except ValueError:
        abort(400, "请输入有效的 HTTPS 链接。")
    return value


def pretty(value):
    if value is None:
        return "—"
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M")
    if isinstance(value, date):
        return value.isoformat()
    return str(value)


def form_date(value):
    return value.isoformat(timespec="minutes") if value else ""


def option_rows(sql, params=()):
    return [(row["id"], row["label"]) for row in query(sql, params)]


def field(name, label, kind="text", *, value=None, options=None, required=True, placeholder=None):
    return {"name": name, "label": label, "kind": kind, "value": value, "options": options,
            "required": required, "placeholder": placeholder}


def select_field(name, label, options, *, value=None, required=True, multiple=False):
    return field(name, label, "multi" if multiple else "select", value=value,
                 options=list(options.items()) if isinstance(options, dict) else options, required=required)


def button(label, action=None, *, fields=(), identifier=None, confirm=None, href=None):
    return {"label": label, "action": action, "fields": list(fields), "id": identifier,
            "confirm": confirm, "href": href}


def row(*cells, actions=()):
    return {"cells": [value if isinstance(value, dict) else pretty(value) for value in cells], "actions": list(actions)}


def badge(value, vocabulary):
    return {"text": vocabulary.get(value, value), "status": value}


def link(label, href):
    return {"text": label, "href": href}


def listing(columns, rows, *, actions=(), filters=(), timeline=False, description=None):
    return {"columns": columns, "rows": rows, "actions": list(actions), "filters": list(filters),
            "timeline": timeline, "description": description}
