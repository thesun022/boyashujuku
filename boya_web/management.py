import re

from flask import Blueprint, abort, jsonify, render_template, request
from pymysql import MySQLError

from . import media, operations, people, projects
from .auth import login_required
from .manage_common import allowed, number, text


management = Blueprint("management", __name__)

PAGES = {
    "people": ("人员管理", people.roster, people.save_member),
    "member-history": ("成员履历", people.member_history, None),
    "skills": ("技能字典", people.skill_list, people.save_skill),
    "campaigns": ("宣传活动", projects.campaigns, projects.save_campaign),
    "projects": ("宣传项目", projects.projects, projects.save_project),
    "tasks": ("任务管理", projects.tasks, projects.save_task),
    "task-history": ("任务详情与历史", projects.task_history, projects.save_task),
    "assets": ("素材管理", media.asset_list, media.save_asset),
    "asset-references": ("素材引用", media.asset_references, media.save_asset),
    "articles": ("推文管理", lambda _args: media.production_list("ARTICLE"), None),
    "videos": ("视频管理", lambda _args: media.production_list("VIDEO"), None),
    "versions": ("作品版本与发布", media.versions, media.save_version),
    "review-center": ("审核管理", media.review_center, None),
    "review-history": ("版本审核与交接", media.review_history, media.save_version),
    "cameras": ("相机管理", operations.cameras, operations.save_camera),
    "camera-usage": ("相机预约与借还", operations.camera_usage, operations.save_camera_usage),
    "statistics": ("统计分析", operations.statistics, None),
    "system": ("系统管理", operations.system_accounts, operations.save_account),
    "roles": ("角色权限", operations.role_list, operations.save_role),
    "audit": ("操作日志", operations.audit_list, None),
    "backup": ("备份与恢复", operations.backups, operations.cleanup_file),
}

PARENTS = {
    "member-history": "people", "skills": "people", "projects": "campaigns", "task-history": "tasks",
    "asset-references": "assets", "versions": "campaigns", "review-history": "review-center",
    "camera-usage": "cameras", "roles": "system", "audit": "system", "backup": "system",
}
REQUIRED = {
    "people": ("MANAGE_MEMBER",), "member-history": ("MANAGE_MEMBER",), "skills": ("MANAGE_MEMBER",),
    "tasks": ("MANAGE_PROJECT", "LOG_WORK"), "task-history": ("MANAGE_PROJECT", "LOG_WORK"),
    "review-center": ("REVIEW", "ASSIGN_WORK", "PUBLISH", "SUBMIT"), "cameras": ("MANAGE_CAMERA",),
    "camera-usage": ("MANAGE_CAMERA",), "system": ("MANAGE_SYSTEM",), "roles": ("MANAGE_SYSTEM",),
    "audit": ("MANAGE_SYSTEM",), "backup": ("MANAGE_SYSTEM",),
}

BUSINESS_MESSAGES = {
    "Work version conflict": "任务已变更，请刷新后重新选择状态。",
    "Finished work requires an actual contribution": "请先登记实际参与，再将任务标记为完成。",
    "No effective contribution to void": "这条工时已作废，或不属于此任务。请查看实际参与记录。",
    "Actor is not the project publisher": "当前账号没有此项目的发布权限。",
    "Project is missing a required reviewer": "请先配置此项目的必要审核人员。",
    "Reviewer must currently hold": "审核人须具备相应的在任职务和审核权限。",
    "Review route is fixed": "该审核阶段已经投入使用，不能改写历史审核路线。",
    "Member is not active": "该成员已退出或尚未加入。",
    "Assignment requires an active member": "请分配给在任成员。",
    "New assignment requires an active member": "请分配给在任成员。",
    "Assignment requires the appropriate organization position": "任务需要与成员职务匹配。",
    "only one assignment slot": "此任务只允许分配给一位成员。",
    "Membership periods overlap": "该人员已有重叠的任期。",
    "Camera reservation overlaps": "同一相机在此时间段已有预约。",
    "Equipment usage time overlaps": "同一相机在此时间段已有预约。",
    "Camera usage state conflict": "当前预约状态不支持该借还操作。",
    "Camera cannot be checked out": "当前相机有未归还使用、状态不可用，或操作超出预约时间。",
    "Camera or member is unavailable": "相机或人员当前不可预约，请检查设备状态、借用日期和成员状态。",
    "Check constraint 'ck_usage_checkout'": "请在预约时间范围内签出设备。",
    "Project is already published": "此项目已发布，相关历史已归档。",
    "Published project is closed": "此项目已发布，相关历史已归档。",
    "Previous version is awaiting review": "上一版本仍在处理，请等待审核或退回交接。",
    "Submitter must have an actual qualifying contribution": "请先为当前工作的实际参与登记工作量。",
    "Video submitter must be an assigned editor": "须由当前已分配的实际剪辑人员提交。",
    "Article requires a writing work item": "请先为推文项目创建撰稿任务。",
    "Submission assets are missing": "提交素材不符合要求。秀米版需原稿、照片和秀米链接，草稿版需微信链接，视频需成片。",
    "Article must begin": "请先提交秀米排版预览。",
    "Approved Xiumi requires": "秀米版已通过，请提交公众号草稿预览。",
    "Publication requires current approved": "发布前须完成必需任务，并通过项目要求的所有审核。",
    "This version is not pending review": "此版本已切换审核状态，或当前审核人不匹配。",
}


def page(module):
    if module not in PAGES:
        abort(404)
    if module in REQUIRED and not any(allowed(permission) for permission in REQUIRED[module]):
        abort(403)
    return PAGES[module]


@management.get("/manage/<module>")
@login_required
def screen(module):
    title, _, _ = page(module)
    parent = PARENTS.get(module, module)
    return render_template("manage.html", section=module, title=title, parent=parent)


def cell_text(value):
    return str(value.get("text", "")) if isinstance(value, dict) else str(value)


def sort_key(value):
    label = cell_text(value)
    return (0, int(label)) if re.fullmatch(r"-?[0-9]{1,30}", label) else (1, label.casefold())


@management.get("/api/manage/<module>")
@login_required
def api_list(module):
    _, load, _ = page(module)
    model = load(request.args)
    term = (text(request.args, "q", 100, True) or "").casefold()
    rows = model["rows"]
    if term:
        rows = [row for row in rows if any(term in cell_text(cell).casefold() for cell in row["cells"])]
    column = number(request.args, "sort", minimum=0, maximum=len(model["columns"]) - 1, optional=True)
    if column is not None:
        rows.sort(key=lambda item: sort_key(item["cells"][column]), reverse=request.args.get("desc") == "1")
    page_no = number(request.args, "page", maximum=100000, optional=True) or 1
    model["total"] = len(rows)
    model["page"] = min(page_no, max(1, (len(rows) + 14) // 15))
    model["page_size"] = 15
    start = (model["page"] - 1) * 15
    model["rows"] = rows[start:start + 15]
    return jsonify(model)


@management.post("/api/manage/<module>/<action>")
@login_required
def api_write(module, action):
    _, _, save = page(module)
    if not save:
        abort(404)
    if request.is_json and not isinstance(request.get_json(silent=True), dict):
        abort(400, "请求需要提交表单对象。")
    try:
        result = save(action)
    except MySQLError as error:
        code, message = error.args[:2]
        if code == 1062:
            abort(409, "已有相同的编号、账号或关联记录。")
        if code == 1451:
            abort(409, "该记录仍被其他数据引用。")
        if code == 1452:
            abort(400, "所选关联记录不存在。")
        if code in {1048, 1264, 1265, 1292, 1406, 3819}:
            for phrase, localized in BUSINESS_MESSAGES.items():
                if phrase in message:
                    abort(409, localized)
            abort(400, "输入不符合字段或状态约束。")
        if code in {1205, 1213}:
            abort(409, "记录正在被其他人修改，请刷新后重试。")
        if code == 1644:
            if message.startswith("TASK_HOURS:"):
                abort(409, f"必做任务「{message.removeprefix('TASK_HOURS:')}」缺少有效工时，请由实际参与人登记后发布。")
            if message.startswith("TASK_STATUS:"):
                abort(409, f"必做任务「{message.removeprefix('TASK_STATUS:')}」处于受阻或已取消状态，请项目负责人核实后发布。")
            for phrase, localized in BUSINESS_MESSAGES.items():
                if phrase in message:
                    abort(409, localized)
            abort(409, "当前业务状态不允许此操作，请刷新查看最新记录。")
        raise
    return jsonify({"message": "操作成功。", **result})


@management.get("/manage/file/<int:asset_id>/<mode>")
@login_required
def file_route(asset_id, mode):
    return media.serve_asset(asset_id, mode)
