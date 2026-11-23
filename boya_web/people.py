from flask import abort

from .db import query
from .manage_common import (
    audit, badge, body, button, choices, date_time, execute, field, invoke,
    listing, number, one, option_rows, require_permission, required_row, row, select_field, selected, text, transaction,
    WORK_KINDS,
)


POSITIONS = {"CHIEF": "主编", "MINISTER": "部长", "MEMBER": "部员"}
MEMBER_STATES = {"ACTIVE": "在任", "EXITED": "已退出", "NONE": "未加入"}


def roster(arguments):
    require_permission("MANAGE_MEMBER")
    cohort_options = option_rows("SELECT id,label FROM cohort ORDER BY intake_year DESC,id DESC")
    skills = option_rows("SELECT id,label FROM skill ORDER BY label")
    members = query("""
        WITH entries AS (
          SELECT m.*, ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY joined_at DESC,id DESC) AS rn
          FROM membership_period m
        )
        SELECT p.id,p.person_code,p.display_name,p.contact,m.id AS membership_id,m.cohort_id,c.label AS cohort,
               m.left_at,cm.position_code,
               CASE WHEN m.id IS NULL THEN 'NONE' WHEN m.left_at IS NULL THEN 'ACTIVE' ELSE 'EXITED' END AS state
        FROM person p LEFT JOIN entries m ON m.person_id=p.id AND m.rn=1
        LEFT JOIN cohort c ON c.id=m.cohort_id LEFT JOIN v_current_members cm ON cm.person_id=p.id
        ORDER BY p.id DESC
    """)
    if arguments.get("cohort"):
        cohort_id = number(arguments, "cohort")
        matching = {r["person_id"] for r in query("SELECT person_id FROM membership_period WHERE cohort_id=%s", (cohort_id,))}
        members = [item for item in members if item["id"] in matching]
    if arguments.get("state"):
        state = choices(arguments, "state", MEMBER_STATES)
        members = [item for item in members if item["state"] == state]
    person_skills = {}
    for item in query("SELECT person_id,skill_id FROM person_skill"):
        person_skills.setdefault(item["person_id"], []).append(item["skill_id"])

    rows = []
    for person in members:
        person_id = person["id"]
        actions = [
            button("履历与工作量", href=f"/manage/member-history?id={person_id}"),
            button("编辑", "edit", identifier=person_id, fields=person_fields(person)),
            button("技能", "skills", identifier=person_id, fields=[
                select_field("skills", "已掌握技能", skills, value=person_skills.get(person_id, []),
                             required=False, multiple=True),
            ]),
        ]
        if person["state"] == "ACTIVE":
            actions.extend([
                button("调整职务", "position", identifier=person["membership_id"], fields=[
                    select_field("position", "新职务", POSITIONS, value=person["position_code"]),
                ]),
                button("办理退出", "exit", identifier=person["membership_id"],
                       confirm="办理退出后账号会停用，个人履历和成果仍可查询。"),
            ])
        else:
            actions.append(button("登记加入", "join", identifier=person_id,
                                  fields=join_fields(cohort_options)))
        rows.append(row(person["person_code"], person["display_name"], person["cohort"],
                        POSITIONS.get(person["position_code"]), badge(person["state"], MEMBER_STATES), actions=actions))
    return listing(
        ("人员编号", "姓名", "最近届次", "现任职务", "状态"), rows,
        actions=[
            button("新增人员", "create", fields=person_fields()),
            button("新增届次", "cohort", fields=[
                field("code", "届次编号"), field("label", "届次名称"), field("year", "入届年份", "number"),
            ]),
            button("技能字典", href="/manage/skills"),
        ],
        filters=[select_field("cohort", "历史届次", cohort_options, required=False),
                 select_field("state", "成员状态", MEMBER_STATES, required=False)],
    )


def person_fields(values=None):
    values = values or {}
    return [
        field("code", "人员编号", value=values.get("person_code")),
        field("name", "姓名", value=values.get("display_name")),
        field("contact", "联系方式", value=values.get("contact"), required=False),
    ]


def join_fields(cohorts):
    return [
        select_field("cohort", "届次", cohorts),
        select_field("position", "初始职务", POSITIONS, value="MEMBER"),
        field("joined_at", "加入时间（北京时间）", "datetime-local", required=False),
    ]


def member_history(arguments):
    require_permission("MANAGE_MEMBER")
    person_id = number(arguments, "id")
    person = required_row("SELECT display_name FROM person WHERE id=%s", (person_id,))
    rows = [
        (m["joined_at"], row("成员任期", m["label"], m["joined_at"], m["left_at"]))
        for m in query("SELECT c.label,m.joined_at,m.left_at FROM membership_period m "
                       "JOIN cohort c ON c.id=m.cohort_id WHERE m.person_id=%s", (person_id,))
    ]
    rows.extend(
        (m["starts_at"], row("职务变更", POSITIONS[m["position_code"]], m["starts_at"], m["ends_at"]))
        for m in query("SELECT mp.* FROM membership_position mp JOIN membership_period m "
                       "ON m.id=mp.membership_id WHERE m.person_id=%s", (person_id,))
    )
    workload = query("""SELECT work_type,work_date,cohort_code, SUM(entry_count) AS entries,
                               SUM(minutes_spent) AS minutes FROM v_member_workload
                       WHERE person_id=%s GROUP BY work_type,work_date,cohort_code ORDER BY work_date DESC""", (person_id,))
    model = listing(("类别", "内容", "开始时间", "结束时间"),
                    [event for _, event in sorted(rows, key=lambda item: item[0], reverse=True)],
                    timeline=True, description=person["display_name"])
    model["related"] = [{"title": "工作量历史", "columns": ["日期", "届次", "类型", "次数", "分钟"],
                         "rows": [row(w["work_date"], w["cohort_code"], WORK_KINDS.get(w["work_type"], "审核"),
                                      w["entries"], w["minutes"]) for w in workload]}]
    return model


def skill_list(_arguments):
    require_permission("MANAGE_MEMBER")
    rows = [row(s["code"], s["label"], actions=[
        button("编辑", "edit", identifier=s["id"], fields=[
            field("code", "技能编号", value=s["code"]), field("label", "技能名称", value=s["label"]),
        ]),
    ]) for s in query("SELECT id,code,label FROM skill ORDER BY label")]
    return listing(("编号", "名称"), rows,
                   actions=[button("新增技能", "create", fields=[field("code", "技能编号"), field("label", "技能名称")])])


def save_member(action):
    require_permission("MANAGE_MEMBER")
    data = body()
    if action == "exit":
        invoke("sp_exit_member", number(data, "id"))
        return {}
    with transaction():
        if action in {"create", "edit"}:
            values = (text(data, "code", 40), text(data, "name", 100), text(data, "contact", 160, True))
            if action == "create":
                key = execute("INSERT INTO person(person_code,display_name,contact) VALUES (%s,%s,%s)", values)
            else:
                key = number(data, "id")
                required_row("SELECT id FROM person WHERE id=%s FOR UPDATE", (key,))
                execute("UPDATE person SET person_code=%s,display_name=%s,contact=%s WHERE id=%s", (*values, key))
            audit("WEB_PERSON_" + action.upper(), "person", key)
        elif action == "cohort":
            key = execute("INSERT INTO cohort(code,label,intake_year) VALUES (%s,%s,%s)",
                          (text(data, "code", 20), text(data, "label", 80), number(data, "year", minimum=1900, maximum=9999)))
            audit("WEB_COHORT_CREATE", "cohort", key)
        elif action == "join":
            person_id = number(data, "id")
            joined_at = date_time(data, "joined_at", True)
            key = execute("""INSERT INTO membership_period(person_id,cohort_id,joined_at)
                             VALUES (%s,%s,COALESCE(%s,CURRENT_TIMESTAMP(6)))""",
                          (person_id, number(data, "cohort"), joined_at))
            start = required_row("SELECT joined_at FROM membership_period WHERE id=%s", (key,))["joined_at"]
            execute("INSERT INTO membership_position(membership_id,position_code,starts_at) VALUES (%s,%s,%s)",
                    (key, choices(data, "position", POSITIONS), start))
            audit("WEB_MEMBERSHIP_JOIN", "membership_period", key)
        elif action == "position":
            key = number(data, "id")
            required_row("SELECT id FROM membership_period WHERE id=%s AND left_at IS NULL FOR UPDATE", (key,))
            current = one("SELECT id,position_code FROM membership_position WHERE membership_id=%s AND ends_at IS NULL", (key,))
            new = choices(data, "position", POSITIONS)
            if current and current["position_code"] == new:
                abort(409, "成员当前已担任该职务。")
            change = one("SELECT CURRENT_TIMESTAMP(6) AS moment")["moment"]
            if current:
                execute("UPDATE membership_position SET ends_at=%s WHERE id=%s", (change, current["id"]))
            execute("INSERT INTO membership_position(membership_id,position_code,starts_at) VALUES (%s,%s,%s)", (key, new, change))
            audit("WEB_POSITION_CHANGE", "membership_period", key, {"position": new})
        elif action == "skills":
            key = number(data, "id")
            required_row("SELECT id FROM person WHERE id=%s FOR UPDATE", (key,))
            values = selected(data, "skills")
            execute("DELETE FROM person_skill WHERE person_id=%s", (key,))
            for skill in values:
                execute("INSERT INTO person_skill(person_id,skill_id) VALUES (%s,%s)", (key, skill))
            audit("WEB_SKILL_ASSIGN", "person", key)
        else:
            abort(404)
    return {"id": key}


def save_skill(action):
    require_permission("MANAGE_MEMBER")
    data = body()
    values = (text(data, "code", 40), text(data, "label", 60))
    with transaction():
        if action == "create":
            key = execute("INSERT INTO skill(code,label) VALUES (%s,%s)", values)
        elif action == "edit":
            key = number(data, "id")
            required_row("SELECT id FROM skill WHERE id=%s", (key,))
            execute("UPDATE skill SET code=%s,label=%s WHERE id=%s", (*values, key))
        else:
            abort(404)
        audit("WEB_SKILL_" + action.upper(), "skill", key)
    return {"id": key}
