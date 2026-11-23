from datetime import date

from flask import abort, g

from .auth import hasher
from .dashboard import CAMERA_STATES
from .db import query
from .manage_common import (
    WORK_KINDS, actor, allowed, audit, badge, body, button, choices, date_time, execute, field,
    form_date, invoke, listing, number, one, option_rows, require_permission, required_row,
    row, select_field, selected, text, transaction,
)
from .media import clear_file
from .scopes import membership_options, owns, project_rows, read_project


SOURCES = {"OWNED": "自有", "PURCHASED": "购入", "BORROWED": "借入"}
DEVICE_INVENTORY = {"AVAILABLE": "可用", "MAINTENANCE": "维护中", "RETIRED": "退役"}
STAT_TYPES = {"person": "按人员", "cohort": "按届次", "kind": "按工作类型", "campaign": "按活动统计作品",
              "device": "按设备统计使用"}
ACTIVE = {"1": "启用", "0": "停用"}


def camera_fields(item=None):
    item = item or {}
    return [
        field("code", "设备编号", value=item.get("code")), field("name", "名称", value=item.get("name")),
        field("model", "型号", value=item.get("model")),
        select_field("source", "来源", SOURCES, value=item.get("source", "OWNED")),
        select_field("inventory", "设备状态", DEVICE_INVENTORY, value=item.get("inventory_status", "AVAILABLE")),
        field("borrowed_at", "向外借入时间", "datetime-local", value=form_date(item.get("borrowed_at")), required=False),
        field("due_back_at", "预计归还出借方", "datetime-local", value=form_date(item.get("due_back_at")), required=False),
    ]


def cameras(_arguments):
    require_permission("MANAGE_CAMERA")
    items = query("""SELECT e.*,v.current_status,v.current_user_name FROM equipment e
                     JOIN v_equipment_status v ON v.equipment_id=e.id ORDER BY e.code""")
    rows = []
    for item in items:
        actions = [
            button("使用与借还记录", href=f"/manage/camera-usage?id={item['id']}"),
            button("编辑", "edit", identifier=item["id"], fields=camera_fields(item)),
        ]
        if item["source"] == "BORROWED" and item["external_returned_at"] is None:
            actions.append(button("归还出借方", "return-external", identifier=item["id"],
                                  confirm="确认已将该相机归还给出借方？"))
        rows.append(row(item["code"], item["name"], item["model"], SOURCES[item["source"]],
                        badge(item["current_status"], CAMERA_STATES), item["current_user_name"],
                        item["due_back_at"], actions=actions))
    return listing(("编号", "名称", "型号", "来源", "状态", "当前使用人", "预计归还"), rows,
                   actions=[button("新增相机", "create", fields=camera_fields())])


def camera_usage(arguments):
    require_permission("MANAGE_CAMERA")
    key = number(arguments, "id")
    device = required_row("SELECT * FROM equipment WHERE id=%s", (key,))
    now = one("SELECT CURRENT_TIMESTAMP(6) AS now")["now"]
    rows = []
    for usage in query("""
        SELECT u.*,w.title,p.display_name FROM equipment_usage u JOIN work_item w ON w.id=u.work_item_id
        JOIN membership_period m ON m.id=u.membership_id JOIN person p ON p.id=m.person_id
        WHERE u.equipment_id=%s ORDER BY u.starts_at DESC,u.id DESC
    """, (key,)):
        actions = []
        if usage["cancelled_at"]:
            state = "已取消"
        elif usage["returned_at"]:
            state = "已归还"
        elif usage["checked_out_at"]:
            state = "归还逾期" if now >= usage["ends_at"] else "使用中"
            actions.append(button("归还相机", "return", identifier=usage["id"], confirm="确认相机已归还？"))
        else:
            state = "预约过期" if now >= usage["ends_at"] else "已预约"
            if usage["starts_at"] <= now < usage["ends_at"]:
                actions.append(button("签出相机", "checkout", identifier=usage["id"]))
            actions.append(button("取消预约", "cancel", identifier=usage["id"], confirm="确认取消此预约？"))
        rows.append(row(usage["title"], usage["display_name"], usage["starts_at"], usage["ends_at"],
                        usage["checked_out_at"], usage["returned_at"], state, actions=actions))
    work = option_rows("SELECT id,title AS label FROM work_item WHERE kind IN ('PHOTO','VIDEO_SHOOT') "
                       "AND status NOT IN ('DONE','CANCELLED') ORDER BY title")
    actions = []
    if work and device["inventory_status"] == "AVAILABLE" and device["external_returned_at"] is None:
        actions.append(button("预约相机", "reserve", identifier=key, fields=[
            select_field("work", "拍摄任务", work), select_field("membership", "使用人", membership_options()),
            field("starts_at", "开始时间", "datetime-local"), field("ends_at", "结束时间", "datetime-local"),
        ]))
    return listing(("任务", "使用人", "开始", "结束", "签出", "归还", "状态"), rows,
                   actions=actions, description=f"{device['code']} · {device['name']}")


def save_camera(action):
    require_permission("MANAGE_CAMERA")
    data = body()
    if action == "return-external":
        key = number(data, "id")
        with transaction():
            device = required_row("SELECT * FROM equipment WHERE id=%s FOR UPDATE", (key,))
            if device["source"] != "BORROWED" or device["external_returned_at"]:
                abort(409, "这台相机当前不需要向出借方归还。")
            if one("""SELECT id FROM equipment_usage WHERE equipment_id=%s AND cancelled_at IS NULL
                      AND returned_at IS NULL AND (checked_out_at IS NOT NULL OR ends_at>CURRENT_TIMESTAMP(6)) LIMIT 1""",
                   (key,)):
                abort(409, "请先归还当前使用中的设备并处理未结束的预约。")
            execute("UPDATE equipment SET external_returned_at=CURRENT_TIMESTAMP(6) WHERE id=%s", (key,))
            audit("WEB_CAMERA_RETURN_EXTERNAL", "equipment", key)
        return {"id": key}
    code, name, model = text(data, "code", 40), text(data, "name", 100), text(data, "model", 100)
    source = choices(data, "source", SOURCES)
    inventory = choices(data, "inventory", DEVICE_INVENTORY)
    borrowed, due = date_time(data, "borrowed_at", True), date_time(data, "due_back_at", True)
    if (source == "BORROWED" and (not borrowed or not due or due <= borrowed)) or (
        source != "BORROWED" and (borrowed or due)
    ):
        abort(400, "借入设备须登记有效的借入与归还时间，自有或购入设备请留空。")
    fields = code, name, model, source, inventory, borrowed, due
    with transaction():
        if action == "create":
            key = execute("""INSERT INTO equipment(code,name,model,source,inventory_status,borrowed_at,due_back_at)
                             VALUES (%s,%s,%s,%s,%s,%s,%s)""", fields)
        elif action == "edit":
            key = number(data, "id")
            existing = required_row("SELECT * FROM equipment WHERE id=%s FOR UPDATE", (key,))
            if existing["external_returned_at"] and source != "BORROWED":
                abort(409, "已归还外借设备的来源须保留。")
            if inventory != "AVAILABLE" and one("""SELECT id FROM equipment_usage WHERE equipment_id=%s
                    AND checked_out_at IS NOT NULL AND returned_at IS NULL LIMIT 1""", (key,)):
                abort(409, "请先归还设备，再修改库存状态。")
            execute("""UPDATE equipment SET code=%s,name=%s,model=%s,source=%s,inventory_status=%s,
                       borrowed_at=%s,due_back_at=%s WHERE id=%s""", (*fields, key))
        else:
            abort(404)
        audit("WEB_CAMERA_" + action.upper(), "equipment", key)
    return {"id": key}


def save_camera_usage(action):
    require_permission("MANAGE_CAMERA")
    data = body()
    key = number(data, "id")
    if action == "reserve":
        required_row("SELECT id FROM equipment WHERE id=%s", (key,))
        work = number(data, "work")
        membership = number(data, "membership")
        required_row("SELECT membership_id FROM v_current_members WHERE membership_id=%s", (membership,))
        start, end = date_time(data, "starts_at"), date_time(data, "ends_at")
        if end <= start or end <= one("SELECT CURRENT_TIMESTAMP(6) AS moment")["moment"]:
            abort(400, "结束时间须晚于开始时间，且预约须尚未结束。")
        invoke("sp_reserve_camera", key, work, membership, start, end)
        result = one("""SELECT id FROM equipment_usage WHERE equipment_id=%s AND work_item_id=%s
                        AND membership_id=%s AND starts_at=%s AND ends_at=%s AND cancelled_at IS NULL
                        ORDER BY id DESC LIMIT 1""", (key, work, membership, start, end))
        return {"id": result["id"]}
    if action not in {"checkout", "return", "cancel"}:
        abort(404)
    required_row("SELECT id FROM equipment_usage WHERE id=%s", (key,))
    invoke("sp_change_camera_usage", key, action.upper())
    return {"id": key}


def stat_date(value):
    if not value:
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        abort(400, "请输入有效日期。")


def statistics(arguments):
    if not any(allowed(p) for p in ("LOG_WORK", "REVIEW", "MANAGE_MEMBER", "MANAGE_PROJECT", "MANAGE_CAMERA")):
        abort(403)
    modes = dict(STAT_TYPES)
    if not allowed("MANAGE_CAMERA"):
        modes.pop("device")
    group = choices(arguments, "group", modes) if arguments.get("group") else "person"
    start, end = stat_date(arguments.get("start")), stat_date(arguments.get("end"))
    if start and end and start > end:
        abort(400, "开始日期须早于或等于结束日期。")
    filters = [
        select_field("group", "统计口径", modes, value=group),
        field("start", "起始日期", "date", required=False), field("end", "截止日期", "date", required=False),
    ]
    dates = start, start, end, end
    if group == "device":
        items = query("""SELECT e.code,e.name, COUNT(u.id) AS booked,COUNT(u.checked_out_at) AS used,
                                COUNT(u.returned_at) AS returned
                         FROM equipment e LEFT JOIN equipment_usage u ON u.equipment_id=e.id AND u.cancelled_at IS NULL
                           AND (%s IS NULL OR DATE(u.starts_at)>=%s) AND (%s IS NULL OR DATE(u.starts_at)<=%s)
                         GROUP BY e.id ORDER BY used DESC,e.code""", dates)
        return listing(("设备", "名称", "预约次数", "实际使用", "已归还"),
                       [row(r["code"], r["name"], r["booked"], r["used"], r["returned"]) for r in items], filters=filters)
    if group == "campaign":
        scope = {p["id"] for p in project_rows()}
        count = {}
        for item in query("""SELECT c.title,c.id,p.id AS project_id, pub.id AS published
                             FROM campaign c JOIN project p ON p.campaign_id=c.id
                             LEFT JOIN submission s ON s.project_id=p.id
                             LEFT JOIN publication pub ON pub.submission_id=s.id
                             WHERE pub.id IS NOT NULL AND (%s IS NULL OR DATE(pub.published_at)>=%s)
                             AND (%s IS NULL OR DATE(pub.published_at)<=%s)""", dates):
            if item["project_id"] in scope:
                current = count.setdefault(item["id"], [item["title"], 0])
                current[1] += 1
        return listing(("活动", "已发布作品"), [row(*pair) for pair in count.values()], filters=filters)
    manager = allowed("MANAGE_PROJECT")
    global_members = allowed("MANAGE_MEMBER") and not manager
    scope = (actor(), global_members, manager, actor(), actor())
    key = {"person": "display_name", "cohort": "cohort_code", "kind": "work_type"}[group]
    items = query(f"""
        WITH actual AS (
          SELECT CONCAT(p.display_name,'（',p.person_code,'）') AS display_name,co.code AS cohort_code,
                 w.kind AS work_type, DATE(wc.worked_at) AS event_date,
                 wc.minutes_spent AS minutes, CONCAT('W-',w.id) AS work_key
          FROM work_contribution wc JOIN work_item w ON w.id=wc.work_item_id
          JOIN membership_period m ON m.id=wc.membership_id JOIN person p ON p.id=m.person_id
          JOIN cohort co ON co.id=m.cohort_id JOIN project pr ON pr.id=w.project_id JOIN campaign c ON c.id=pr.campaign_id
          WHERE p.id=%s OR %s OR (%s AND (pr.created_by=%s OR c.created_by=%s))
          UNION ALL
          SELECT CONCAT(p.display_name,'（',p.person_code,'）'),co.code,'REVIEW',DATE(r.reviewed_at),NULL,CONCAT('R-',r.id)
          FROM review_record r JOIN person p ON p.id=r.reviewer_id
          LEFT JOIN membership_period m ON m.id=r.membership_id LEFT JOIN cohort co ON co.id=m.cohort_id
          JOIN submission s ON s.id=r.submission_id JOIN project pr ON pr.id=s.project_id JOIN campaign c ON c.id=pr.campaign_id
          WHERE p.id=%s OR %s OR (%s AND (pr.created_by=%s OR c.created_by=%s))
        )
        SELECT {key} AS label,COUNT(*) AS entries,COUNT(DISTINCT work_key) AS participation,
               COALESCE(SUM(minutes),0) AS minutes
        FROM actual WHERE (%s IS NULL OR event_date>=%s) AND (%s IS NULL OR event_date<=%s)
        GROUP BY {key} ORDER BY minutes DESC,label
    """, (*scope, *scope, *dates))
    rows = [row(WORK_KINDS.get(r["label"], "审核") if group == "kind" else r["label"],
                r["entries"], r["participation"], r["minutes"]) for r in items]
    return listing(("成员／届次／类型", "实际记录数", "参与事项数", "投入分钟"), rows, filters=filters)


def system_accounts(_arguments):
    require_permission("MANAGE_SYSTEM")
    roles = option_rows("SELECT code AS id,label FROM system_role ORDER BY label")
    unregistered = option_rows("""SELECT p.id,p.display_name AS label FROM person p LEFT JOIN account a ON a.person_id=p.id
                                  WHERE a.id IS NULL ORDER BY p.display_name""")
    rows = []
    for a in query("""SELECT a.id,a.username,a.enabled,p.display_name,
                        GROUP_CONCAT(ar.role_code ORDER BY ar.role_code) AS roles
                      FROM account a JOIN person p ON p.id=a.person_id LEFT JOIN account_role ar ON ar.account_id=a.id
                      GROUP BY a.id,p.display_name ORDER BY a.username"""):
        codes = (a["roles"] or "").split(",")
        actions = [
            button("编辑账号", "edit", identifier=a["id"], fields=[
                field("username", "登录名", value=a["username"]),
                field("password", "新密码（留空保留）", "password", required=False),
            ]),
            button("分配角色", "roles", identifier=a["id"], confirm="确认修改该账号的系统权限？", fields=[
                select_field("roles", "系统角色", roles, value=codes, required=False, multiple=True),
            ]),
        ]
        if a["id"] != g.identity.account_id:
            value = "0" if a["enabled"] else "1"
            actions.append(button("停用" if a["enabled"] else "启用", "enable", identifier=a["id"],
                                  fields=[field("enabled", "状态", "hidden", value=value)],
                                  confirm="确认修改账号状态？停用后现有会话会立即失效。"))
        rows.append(row(a["username"], a["display_name"], "、".join(label for code, label in roles if code in codes),
                        badge(str(a["enabled"]), ACTIVE), actions=actions))
    actions = [button("新建账号", "create", fields=[
        select_field("person", "人员", unregistered), field("username", "登录名"),
        field("password", "初始密码（至少 12 个字符）", "password"),
        select_field("roles", "系统角色", roles, multiple=True, required=False),
    ])] if unregistered else []
    actions.extend([button("角色权限", href="/manage/roles"), button("操作日志", href="/manage/audit"),
                    button("备份与恢复", href="/manage/backup")])
    return listing(("账号", "关联人员", "角色", "状态"), rows, actions=actions)


def string_selection(data, key):
    values = data.get(key, [])
    if not isinstance(values, list) or len(values) > 100 or any(not isinstance(item, str) or len(item) > 40 for item in values):
        abort(400, "角色或权限选项有误。")
    return set(values)


def password_hash(data, optional=False):
    value = data.get("password")
    if (value is None or value == "") and optional:
        return None
    if not isinstance(value, str) or len(value) < 12 or len(value) > 256:
        abort(400, "密码须为 12 至 256 个字符。")
    return hasher.hash(value)


def ensure_other_admin(account_id):
    if not one("""SELECT a.id FROM account a JOIN account_role ar ON ar.account_id=a.id
                  WHERE ar.role_code='SYSTEM_ADMIN' AND a.enabled=TRUE AND a.id<>%s LIMIT 1""", (account_id,)):
        abort(409, "至少保留一个启用的系统管理员。")


def assign_roles(account_id, roles):
    known = {r["code"] for r in query("SELECT code FROM system_role")}
    if not roles <= known:
        abort(400, "角色不存在。")
    old = {r["role_code"] for r in query("SELECT role_code FROM account_role WHERE account_id=%s", (account_id,))}
    if "SYSTEM_ADMIN" in old and "SYSTEM_ADMIN" not in roles:
        ensure_other_admin(account_id)
    for code in old - roles:
        execute("DELETE FROM account_role WHERE account_id=%s AND role_code=%s", (account_id, code))
    for code in roles - old:
        execute("INSERT INTO account_role(account_id,role_code) VALUES (%s,%s)", (account_id, code))


def save_account(action):
    require_permission("MANAGE_SYSTEM")
    data = body()
    with transaction():
        required_row("SELECT code FROM system_role WHERE code='SYSTEM_ADMIN' FOR UPDATE")
        if action == "create":
            person_id = number(data, "person")
            required_row("SELECT id FROM person WHERE id=%s", (person_id,))
            key = execute("INSERT INTO account(person_id,username,password_hash,enabled) VALUES (%s,%s,%s,TRUE)",
                          (person_id, text(data, "username", 80), password_hash(data)))
            assign_roles(key, string_selection(data, "roles"))
        else:
            key = number(data, "id")
            required_row("SELECT id FROM account WHERE id=%s FOR UPDATE", (key,))
            if action == "enable":
                enabled = choices(data, "enabled", ACTIVE) == "1"
                if not enabled and key == g.identity.account_id:
                    abort(409, "请由另一位管理员处理当前登录账号。")
                if not enabled and one("SELECT account_id FROM account_role WHERE account_id=%s AND role_code='SYSTEM_ADMIN'", (key,)):
                    ensure_other_admin(key)
                execute("UPDATE account SET enabled=%s WHERE id=%s", (enabled, key))
            elif action == "edit":
                username, encoded = text(data, "username", 80), password_hash(data, True)
                if encoded:
                    execute("UPDATE account SET username=%s,password_hash=%s WHERE id=%s", (username, encoded, key))
                else:
                    execute("UPDATE account SET username=%s WHERE id=%s", (username, key))
            elif action == "roles":
                assign_roles(key, string_selection(data, "roles"))
            else:
                abort(404)
        audit("WEB_ACCOUNT_" + action.upper(), "account", key)
    return {"id": key}


def role_list(_arguments):
    require_permission("MANAGE_SYSTEM")
    permissions = option_rows("SELECT code AS id,label FROM permission ORDER BY label")
    rows = []
    for role in query("SELECT code,label FROM system_role ORDER BY label"):
        current = [p["permission_code"] for p in query("SELECT permission_code FROM role_permission WHERE role_code=%s", (role["code"],))]
        actions = [button("调整权限", "edit", identifier=role["code"], fields=[
            field("label", "角色名称", value=role["label"]),
            select_field("permissions", "授权项", permissions, value=current, required=False, multiple=True),
        ], confirm="角色权限变更会影响已使用该角色的账号。")] if role["code"] != "SYSTEM_ADMIN" else []
        rows.append(row(role["code"], role["label"], "、".join(label for code, label in permissions if code in current), actions=actions))
    return listing(("角色代码", "名称", "权限"), rows, actions=[
        button("新增角色", "create", fields=[field("code", "角色代码"), field("label", "名称"),
                                          select_field("permissions", "授权项", permissions, required=False, multiple=True)]),
    ])


def save_role(action):
    require_permission("MANAGE_SYSTEM")
    data = body()
    code = text(data, "code" if action == "create" else "id", 40).upper()
    if code == "SYSTEM_ADMIN" or not code.replace("_", "").isascii() or not code.replace("_", "").isalnum():
        abort(400, "请输入有效的角色代码，系统管理员角色受保护。")
    label = text(data, "label", 80)
    chosen = string_selection(data, "permissions")
    if not chosen <= {p["code"] for p in query("SELECT code FROM permission")}:
        abort(400, "权限项不存在。")
    with transaction():
        if action == "create":
            execute("INSERT INTO system_role(code,label) VALUES (%s,%s)", (code, label))
        elif action == "edit":
            required_row("SELECT code FROM system_role WHERE code=%s FOR UPDATE", (code,))
            execute("UPDATE system_role SET label=%s WHERE code=%s", (label, code))
        else:
            abort(404)
        old = {p["permission_code"] for p in query("SELECT permission_code FROM role_permission WHERE role_code=%s", (code,))}
        for permission in old - chosen:
            execute("DELETE FROM role_permission WHERE role_code=%s AND permission_code=%s", (code, permission))
        for permission in chosen - old:
            execute("INSERT INTO role_permission(role_code,permission_code) VALUES (%s,%s)", (code, permission))
        audit("WEB_ROLE_" + action.upper(), "system_role", 0, {"code": code})
    return {"id": code}


def audit_list(arguments):
    require_permission("MANAGE_SYSTEM")
    action = text(arguments, "action", 48, True)
    rows = query("""SELECT a.*,p.display_name FROM audit_log a LEFT JOIN person p ON p.id=a.actor_id
                    WHERE (%s IS NULL OR a.action_code=%s) ORDER BY a.occurred_at DESC,a.id DESC""", (action, action))
    filters = option_rows("SELECT DISTINCT action_code AS id,action_code AS label FROM audit_log ORDER BY action_code")
    return listing(("时间", "操作者", "操作", "记录类别", "记录编号"),
                   [row(r["occurred_at"], r["display_name"] or "数据库维护", r["action_code"], r["entity_type"], r["entity_id"])
                    for r in rows], filters=[select_field("action", "动作", filters, required=False)])


def backups(_arguments):
    require_permission("MANAGE_SYSTEM")
    rows = query("SELECT storage_key,queued_at FROM web_file_cleanup ORDER BY queued_at")
    model = listing(("待清理文件", "排队时间"), [row(item["storage_key"], item["queued_at"], actions=[
        button("重试清理", "cleanup", identifier=item["storage_key"], confirm="只有已解除引用的文件会被清理。"),
    ]) for item in rows], description="MySQL 与素材目录分别备份。先在独立实例校验恢复结果，再安排正式库恢复。")
    model["notes"] = [
        {"title": "完整备份", "text": "在受控 PowerShell 7 会话使用 database/New-BoyaBackup.ps1，传入独立的备份目录和素材目录。保留已校验的清单及 Binlog 连续归档。"},
        {"title": "恢复演练", "text": "用 database/Restore-BoyaBackup.ps1 将备份恢复到同版本的隔离实例。必要时按快照位置回放 Binlog，然后校对行数、发布状态和素材校验值。"},
    ]
    return model


def cleanup_file(action):
    require_permission("MANAGE_SYSTEM")
    if action != "cleanup":
        abort(404)
    key = text(body(), "id", 64)
    required_row("SELECT storage_key FROM web_file_cleanup WHERE storage_key=%s", (key,))
    if not clear_file(key):
        abort(409, "文件当前不可清理，可稍后重试。")
    audit("WEB_FILE_CLEANUP", "asset", 0, {"key": key})
    return {}
