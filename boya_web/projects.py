from flask import abort, jsonify
from pymysql import MySQLError

from .db import query
from .manage_common import (
    PROJECT_KINDS, PROJECT_STATES, STAGES, WORK_KINDS, WORK_STATES, actor, allowed, audit,
    badge, body, button, choices, date_time, execute, field, form_date, invoke, listing, number,
    one, option_rows, require_permission, row, select_field, text, transaction,
)
from .scopes import manage_campaign, manage_project, membership_options, owns, project_rows, read_project, read_task


YES_NO = {"1": "是", "0": "否"}
PARTICIPATION = {"PRIMARY": "主办", "COLLABORATOR": "协作"}
OPEN_TASK = """w.status IN ('TODO','IN_PROGRESS','BLOCKED') AND NOT EXISTS (
  SELECT 1 FROM submission s JOIN publication pub ON pub.submission_id=s.id WHERE s.project_id=w.project_id)"""


def pending_task_preview():
    return query(f"""SELECT w.id,w.title,w.status,p.title AS project_title,COUNT(*) OVER() AS total
                     FROM work_item w JOIN project p ON p.id=w.project_id JOIN campaign c ON c.id=p.campaign_id
                     WHERE {OPEN_TASK} AND ((%s AND %s IN (p.created_by,c.created_by)) OR
                       (%s AND EXISTS (SELECT 1 FROM v_web_assigned_tasks a WHERE a.work_id=w.id AND a.person_id=%s)))
                     ORDER BY w.updated_at DESC,w.id DESC LIMIT 5""",
                 (allowed("MANAGE_PROJECT"), actor(), allowed("LOG_WORK"), actor()))


def campaign_fields(values=None):
    item = values or {}
    return [
        field("code", "活动编号", value=item.get("code")), field("title", "活动名称", value=item.get("title")),
        field("starts_at", "开始（北京时间）", "datetime-local", value=form_date(item.get("starts_at"))),
        field("ends_at", "结束（北京时间）", "datetime-local", value=form_date(item.get("ends_at")), required=False),
        select_field("third", "启用三审", YES_NO, value=str(item.get("requires_third_review", 0))),
    ]


def campaigns(_arguments):
    visible_ids = {p["campaign_id"] for p in project_rows()}
    campaigns = query("SELECT * FROM campaign ORDER BY starts_at DESC,id DESC")
    rows = []
    for c in campaigns:
        manager = allowed("MANAGE_PROJECT") and c["created_by"] == actor()
        if not manager and c["id"] not in visible_ids:
            continue
        actions = [button("项目与进度", href=f"/manage/projects?id={c['id']}")]
        if manager:
            actions.append(button("编辑", "edit", identifier=c["id"], fields=campaign_fields(c)))
        rows.append(row(c["code"], c["title"], c["starts_at"], c["ends_at"],
                        YES_NO[str(c["requires_third_review"])], actions=actions))
    actions = [button("新建活动", "create", fields=campaign_fields())] if allowed("MANAGE_PROJECT") else []
    return listing(("编号", "活动", "开始", "结束", "三审"), rows, actions=actions)


def projects(arguments):
    campaign_id = number(arguments, "id")
    campaign = one("SELECT * FROM campaign WHERE id=%s", (campaign_id,))
    visible = [p for p in project_rows() if p["campaign_id"] == campaign_id]
    campaign_owner = campaign is not None and allowed("MANAGE_PROJECT") and campaign["created_by"] == actor()
    if not campaign or not (visible or campaign_owner):
        abort(404)
    status = {r["project_id"]: r for r in query("SELECT * FROM v_campaign_progress WHERE campaign_id=%s", (campaign_id,))}
    reviewers = option_rows("SELECT id, display_name AS label FROM person ORDER BY display_name") if any(owns(p) for p in visible) else []
    rows = []
    for project in visible:
        p_id = project["id"]
        progress = status[p_id]
        actions = []
        if project["delivery_mode"] == "REVIEWED":
            actions.append(button("作品与版本", href=f"/manage/versions?id={p_id}"))
        if owns(project):
            actions.append(button("项目任务", href=f"/manage/tasks?project={p_id}"))
            if project["delivery_mode"] == "REVIEWED" and progress["project_status"] != "PUBLISHED":
                actions.append(button("设置审核人", "route", identifier=p_id, fields=[
                    select_field("stage", "审核阶段", {k: STAGES[k] for k in ("MINISTER", "CHIEF", "SECOND", "THIRD")}),
                    select_field("reviewer", "审核人", reviewers),
                ]))
        rows.append(row(project["code"], project["title"], PROJECT_KINDS[project["kind"]],
                        f"{progress['complete_work']}/{progress['required_work']}",
                        badge(progress["project_status"], PROJECT_STATES), actions=actions))
    actions = []
    if campaign_owner:
        actions.append(button("新增项目", "create", identifier=campaign_id, fields=[
            field("code", "项目编号"), field("title", "项目名称"), select_field("kind", "类型", PROJECT_KINDS),
            select_field("delivery", "完成条件", {"REVIEWED": "审核后发布", "WORK_ONLY": "任务完成"}, value="REVIEWED"),
            select_field("required", "必需项目", YES_NO, value="1"),
        ]))
    model = listing(("编号", "项目", "类型", "完成任务", "进度"), rows, actions=actions, description=campaign["title"])
    if visible:
        ids = {p["id"] for p in visible}
        routes = query("""SELECT r.project_id,p.title,r.stage,u.display_name FROM project_review_route r
                          JOIN project p ON p.id=r.project_id JOIN person u ON u.id=r.reviewer_id
                          WHERE p.campaign_id=%s ORDER BY p.id,r.stage""", (campaign_id,))
        model["related"] = [{"title": "已配置审核人", "columns": ["项目", "阶段", "审核人"],
                             "rows": [row(r["title"], STAGES[r["stage"]], r["display_name"])
                                      for r in routes if r["project_id"] in ids]}]
    return model


def task_fields(options):
    return [
        select_field("project", "项目", options), field("code", "任务编号"), field("title", "任务名称"),
        select_field("kind", "工作类型", WORK_KINDS),
        select_field("mode", "视频剪辑方式", {"MEMBER": "部员剪辑", "MINISTER": "部长独剪"}, value="MEMBER"),
        select_field("required", "是否必做", YES_NO, value="1"),
    ]


def tasks(arguments):
    if not (allowed("MANAGE_PROJECT") or allowed("LOG_WORK")):
        abort(403)
    projects = project_rows()
    project_id = number(arguments, "project", optional=True)
    if project_id:
        read_project(project_id)
    managed = {p["id"] for p in projects if owns(p)}
    project_choices = [(p["id"], f"{p['campaign_title']} · {p['title']}") for p in projects]
    states = {"OPEN": "全部待处理", **WORK_STATES}
    state = choices(arguments, "state", states) if arguments.get("state") else None
    condition = f" AND {OPEN_TASK}" if state == "OPEN" else ""
    work = query(f"""
        SELECT w.*,p.title AS project_title,
          GROUP_CONCAT(DISTINCT IF(a.ended_at IS NULL,u.display_name,NULL) ORDER BY u.display_name SEPARATOR '、') AS assignees
        FROM work_item w JOIN project p ON p.id=w.project_id
        LEFT JOIN work_assignment a ON a.work_item_id=w.id
        LEFT JOIN membership_period m ON m.id=a.membership_id LEFT JOIN person u ON u.id=m.person_id
        WHERE (%s IS NULL OR w.project_id=%s){condition}
        GROUP BY w.id,p.title ORDER BY w.updated_at DESC,w.id DESC
    """, (project_id, project_id))
    assigned = {r["work_id"] for r in query("SELECT work_id FROM v_web_assigned_tasks WHERE person_id=%s", (actor(),))}
    if state in WORK_STATES:
        work = [w for w in work if w["status"] == state]
    rows = [row(w["title"], w["project_title"], WORK_KINDS[w["kind"]], w["assignees"],
                badge(w["status"], WORK_STATES), actions=[button("详情", href=f"/manage/task-history?id={w['id']}")])
            for w in work if w["project_id"] in managed or (allowed("LOG_WORK") and w["id"] in assigned)]
    choices_for_creation = [(i, label) for i, label in project_choices if i in managed]
    return listing(("任务", "项目", "类型", "当前负责人", "状态"), rows,
                   filters=[select_field("project", "项目", project_choices, required=False),
                            select_field("state", "任务状态", states, required=False)],
                   actions=[button("创建任务", "create", fields=task_fields(choices_for_creation))]
                   if choices_for_creation else [])


def task_history(arguments):
    if not (allowed("LOG_WORK") or allowed("MANAGE_PROJECT")):
        abort(403)
    work_id = number(arguments, "id")
    work = read_task(work_id)
    manager = owns(read_project(work["project_id"]))
    published = one("""SELECT 1 AS found FROM publication p JOIN submission s ON s.id=p.submission_id
                       WHERE s.project_id=%s""", (work["project_id"],))
    actions = []
    people = membership_options() if manager else []
    if manager and not published:
        if allowed("ASSIGN_WORK"):
            actions.append(button("分配人员", "assign", identifier=work_id, fields=[
                select_field("membership", "在任成员", people),
            ]))
        actions.append(button("修改状态", "status", identifier=work_id, fields=[
            select_field("status", "新状态", WORK_STATES, value=work["status"]),
            field("version", "修订号", "hidden", value=work["lock_version"]),
        ]))
    if not published and (allowed("LOG_WORK") or (manager and allowed("LOG_WORK_FOR_OTHERS"))):
        contributor = one("SELECT membership_id FROM v_current_members WHERE person_id=%s", (actor(),))
        if (manager and allowed("LOG_WORK_FOR_OTHERS")) or contributor:
            options = people if manager and allowed("LOG_WORK_FOR_OTHERS") else [(contributor["membership_id"], "本人")]
            actions.append(button("登记实际参与", "contribution", identifier=work_id, fields=[
                select_field("membership", "参与人", options, value=(contributor or {}).get("membership_id")),
                select_field("participation", "参与身份", PARTICIPATION), field("worked_at", "工作时间", "datetime-local", required=False),
                field("minutes", "投入分钟", "number"), field("note", "说明", "textarea", required=False),
            ]))
    history = query("""SELECT h.*,p.display_name FROM work_status_history h JOIN person p ON p.id=h.changed_by
                       WHERE h.work_item_id=%s ORDER BY h.changed_at DESC,h.id DESC""", (work_id,))
    assignments = query("""SELECT a.*,p.display_name FROM work_assignment a JOIN membership_period m ON m.id=a.membership_id
                           JOIN person p ON p.id=m.person_id WHERE a.work_item_id=%s ORDER BY assigned_at DESC,a.id DESC""", (work_id,))
    contributions = query("""SELECT a.*,p.display_name FROM work_contribution a JOIN membership_period m ON m.id=a.membership_id
                             JOIN person p ON p.id=m.person_id WHERE a.work_item_id=%s ORDER BY worked_at DESC,a.id DESC""", (work_id,))
    corrections = query("""SELECT a.*,p.display_name,op.display_name AS operator,rec.display_name AS recorder
                           FROM voided_work_contribution a JOIN membership_period m ON m.id=a.membership_id
                           JOIN person p ON p.id=m.person_id JOIN person op ON op.id=a.voided_by
                           JOIN person rec ON rec.id=a.recorded_by WHERE a.work_item_id=%s
                           ORDER BY a.voided_at DESC,a.id DESC""", (work_id,))
    model = listing(("时间", "操作者", "原状态", "新状态", "修订号"),
                    [row(h["changed_at"], h["display_name"], WORK_STATES.get(h["old_status"]),
                         badge(h["new_status"], WORK_STATES), h["lock_version"]) for h in history],
                    actions=actions, timeline=True, description=work["title"])
    model["related"] = [
        {"title": "指派历史", "columns": ["成员", "分配时间", "结束时间"], "rows": [
            row(a["display_name"], a["assigned_at"], a["ended_at"], actions=(
                [button("结束分配", "unassign", identifier=a["id"],
                        confirm="结束任务分配并保留已登记的参与记录。")]
                if manager and allowed("ASSIGN_WORK") and not published and a["ended_at"] is None else []
            )) for a in assignments]},
        {"title": "实际参与", "anchor": "contributions", "columns": ["记录", "人员", "身份", "工作时间", "分钟", "说明"], "rows": [
            row(a["id"], a["display_name"], PARTICIPATION[a["participation"]], a["worked_at"], a["minutes_spent"], a["note"],
                actions=[button("作废工时", "void-contribution", identifier=work_id, fields=[
                    field("entry", "", "hidden", value=a["id"]), field("reason", "作废原因", "textarea"),
                ], confirm=f"确认作废 {a['display_name']} 的 {a['minutes_spent']} 分钟工时？")]
                if manager and allowed("LOG_WORK_FOR_OTHERS") else [])
            for a in contributions]},
    ]
    if corrections:
        model["related"].append({"title": "已作废工时", "columns": ["记录", "人员", "工作时间", "分钟", "原说明",
                                "原登记人", "作废人", "作废时间", "原因"], "rows": [
            row(a["id"], a["display_name"], a["worked_at"], a["minutes_spent"], a["note"], a["recorder"],
                a["operator"], a["voided_at"], a["reason"]) for a in corrections]})
    return model


def save_campaign(action):
    require_permission("MANAGE_PROJECT")
    data = body()
    values = (text(data, "code", 40), text(data, "title", 180), date_time(data, "starts_at"),
              date_time(data, "ends_at", True), choices(data, "third", YES_NO) == "1")
    if values[3] and values[3] <= values[2]:
        abort(400, "结束时间须晚于开始时间。")
    if action == "create":
        invoke("sp_create_campaign", *values)
        return {"id": one("SELECT id FROM campaign WHERE code=%s AND created_by=%s", (values[0], actor()))["id"]}
    if action == "edit":
        key = number(data, "id")
        manage_campaign(key)
        with transaction():
            execute("""UPDATE campaign SET code=%s,title=%s,starts_at=%s,ends_at=%s,requires_third_review=%s
                       WHERE id=%s AND created_by=%s""", (*values, key, actor()))
            audit("WEB_CAMPAIGN_EDIT", "campaign", key)
        return {"id": key}
    abort(404)


def save_project(action):
    data = body()
    key = number(data, "id")
    if action == "create":
        manage_campaign(key)
        code = text(data, "code", 40)
        kind = choices(data, "kind", PROJECT_KINDS)
        delivery = choices(data, "delivery", {"REVIEWED", "WORK_ONLY"})
        if kind in ("ARTICLE", "VIDEO") and delivery != "REVIEWED":
            abort(400, "推文和视频须经审核后发布。")
        invoke("sp_create_project", key, code, text(data, "title", 180), kind, delivery, choices(data, "required", YES_NO) == "1")
        return {"id": one("SELECT id FROM project WHERE campaign_id=%s AND code=%s", (key, code))["id"]}
    if action == "route":
        manage_project(key)
        invoke("sp_set_review_route", key, choices(data, "stage", {"MINISTER", "CHIEF", "SECOND", "THIRD"}),
               number(data, "reviewer"))
        return {"id": key}
    abort(404)


def save_task(action):
    data = body()
    if action == "create":
        project = number(data, "project")
        manage_project(project)
        kind = choices(data, "kind", WORK_KINDS)
        mode = choices(data, "mode", {"MEMBER", "MINISTER"}) if kind == "VIDEO_EDIT" else None
        code = text(data, "code", 40)
        invoke("sp_create_work", project, code, text(data, "title", 180), kind, mode, choices(data, "required", YES_NO) == "1")
        return {"id": one("SELECT id FROM work_item WHERE project_id=%s AND code=%s", (project, code))["id"]}
    key = number(data, "id")
    if action == "unassign":
        require_permission("ASSIGN_WORK")
        work = one("SELECT work_item_id FROM work_assignment WHERE id=%s", (key,))
        if not work:
            abort(404)
        read_task(work["work_item_id"], managed=True)
        invoke("sp_end_work_assignment", key)
    elif action == "assign":
        require_permission("ASSIGN_WORK")
        read_task(key, managed=True)
        invoke("sp_assign_work", key, number(data, "membership"))
    elif action == "status":
        read_task(key, managed=True)
        invoke("sp_set_work_status", key, number(data, "version", minimum=0, maximum=2**32 - 1),
               choices(data, "status", WORK_STATES))
    elif action == "void-contribution":
        require_permission("LOG_WORK_FOR_OTHERS")
        read_task(key, managed=True)
        invoke("sp_void_contribution", key, number(data, "entry"), text(data, "reason", 500))
    elif action == "contribution":
        work = read_task(key)
        membership = number(data, "membership")
        owner = one("SELECT person_id FROM v_current_members WHERE membership_id=%s", (membership,))
        if not owner:
            abort(400, "选择当前在任的参与人员。")
        if owner["person_id"] == actor():
            require_permission("LOG_WORK")
        else:
            manage_project(work["project_id"], "LOG_WORK_FOR_OTHERS")
        worked = date_time(data, "worked_at", True) or one("SELECT CURRENT_TIMESTAMP(6) AS moment")["moment"]
        try:
            invoke("sp_log_contribution", key, membership, choices(data, "participation", PARTICIPATION), worked,
                   number(data, "minutes", maximum=65535), text(data, "note", 500, True))
        except MySQLError as exc:
            if exc.args[:2] != (1644, "This work item has a single contributor"):
                raise
            other = one("""SELECT a.id,a.minutes_spent,p.display_name FROM work_contribution a
                           JOIN membership_period m ON m.id=a.membership_id JOIN person p ON p.id=m.person_id
                           WHERE a.work_item_id=%s AND a.membership_id<>%s ORDER BY a.id LIMIT 1""", (key, membership))
            detail = f"已有{other['display_name']}的有效记录 #{other['id']}（{other['minutes_spent']} 分钟）。" if other else ""
            response = jsonify(error=f"此任务只允许一位实际参与人。{detail}如属误登，请由项目负责人在「实际参与」中作废对应记录。",
                               resolution={"href": f"/manage/task-history?id={key}#contributions", "label": "查看实际参与记录"})
            response.status_code = 409
            abort(response)
    else:
        abort(404)
    return {"id": key}
