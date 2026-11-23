import hashlib
import json
import re
from pathlib import Path
from uuid import uuid4
from xml.etree import ElementTree
from zipfile import BadZipFile, ZipFile

from flask import abort, current_app, render_template, request, send_file
from pymysql import MySQLError

from .db import call, query
from .manage_common import (
    PROJECT_KINDS, PROJECT_STATES, STAGES, actor, allowed, audit, badge, body, button, choices, execute, field,
    https_link, invoke, link, listing, number, one, require_permission, required_row,
    row, select_field, selected, text, transaction,
)
from .scopes import manage_project, owns, project_rows, read_project


ASSET_KINDS = {"WORD": "Word 原稿", "PHOTO": "图片", "VIDEO_RAW": "原始视频",
               "VIDEO_FINAL": "视频成片", "XIUMI_LINK": "秀米预览", "WECHAT_LINK": "微信草稿", "OTHER": "其他"}
FILE_TYPES = {
    ".docx": ("WORD", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    ".png": ("PHOTO", "image/png"), ".jpeg": ("PHOTO", "image/jpeg"), ".jpg": ("PHOTO", "image/jpeg"),
    ".gif": ("PHOTO", "image/gif"), ".webp": ("PHOTO", "image/webp"), ".mp4": ("VIDEO", "video/mp4"),
    ".mov": ("VIDEO", "video/quicktime"), ".webm": ("VIDEO", "video/webm"),
}
VERSION_KINDS = {"XIUMI": "秀米排版预览", "WECHAT": "公众号草稿预览", "VIDEO": "视频成片", "GENERIC": "其他成果"}
DECISIONS = {"APPROVED": "通过", "RETURNED": "退回"}
STORAGE_KEY = re.compile(r"^[0-9a-f]{32}\.(?:docx|png|jpe?g|gif|webp|mp4|mov|webm)$")


def team_access(project):
    return owns(project) or one("""
        SELECT 1 AS found FROM work_item w
        WHERE w.project_id=%s AND (
          EXISTS (SELECT 1 FROM v_web_assigned_tasks a WHERE a.work_id=w.id AND a.person_id=%s)
          OR EXISTS (SELECT 1 FROM work_contribution a JOIN membership_period m ON m.id=a.membership_id
                     WHERE a.work_item_id=w.id AND m.person_id=%s))
        LIMIT 1
    """, (project["id"], actor(), actor())) is not None


def open_project(project):
    return one("""SELECT p.id FROM publication p JOIN submission s ON s.id=p.submission_id
                  WHERE s.project_id=%s""", (project["id"],)) is None


def may_upload(project):
    return allowed("REGISTER_ASSET") and team_access(project) and open_project(project)


def submission_visible(item, project):
    if team_access(project) or item["submitted_by"] == actor():
        return True
    return one("""
        SELECT 1 AS found
        WHERE EXISTS (SELECT 1 FROM handover_record WHERE submission_id=%s AND to_person_id=%s)
           OR EXISTS (SELECT 1 FROM review_record WHERE submission_id=%s AND reviewer_id=%s)
    """, (item["id"], actor(), item["id"], actor())) is not None


def read_submission(submission_id):
    item = required_row("SELECT * FROM submission WHERE id=%s", (submission_id,))
    project = read_project(item["project_id"])
    if not submission_visible(item, project):
        abort(404)
    return item, project


def can_read_asset(asset, projects=None):
    if asset["creator_id"] == actor():
        return True
    links = {r["project_id"] for r in query("SELECT project_id FROM project_asset WHERE asset_id=%s", (asset["id"],))}
    bound = query("SELECT s.* FROM submission_asset sa JOIN submission s ON s.id=sa.submission_id WHERE sa.asset_id=%s",
                  (asset["id"],))
    if projects is None:
        projects = {p["id"]: p for p in project_rows()}
    return any(i in projects and team_access(projects[i]) for i in links) or any(
        s["project_id"] in projects and submission_visible(s, projects[s["project_id"]]) for s in bound
    )


def root_path():
    root = Path(current_app.config["ASSET_ROOT"]).resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def stored_path(uri):
    if not uri.startswith("files/"):
        return None
    root = root_path()
    path = (root / uri.removeprefix("files/")).resolve()
    return path if path.is_relative_to(root) else None


def asset_link(asset):
    uri = asset["uri"]
    if asset["kind"] in {"XIUMI_LINK", "WECHAT_LINK"}:
        return link(asset["title"], uri) if uri.startswith("https://") else asset["title"]
    path = stored_path(uri)
    if path and path.is_file():
        return link(asset["title"], f"/manage/file/{asset['id']}/preview")
    return asset["title"]


def asset_options(project_id):
    return [(a["id"], f"{a['title']} · {ASSET_KINDS[a['kind']]}") for a in query(
        """SELECT a.id,a.title,a.kind FROM project_asset pa JOIN asset a ON a.id=pa.asset_id
           WHERE pa.project_id=%s ORDER BY a.id DESC""", (project_id,),
    )]


def asset_list(arguments):
    selected_project = number(arguments, "project", optional=True)
    selected_campaign = number(arguments, "campaign", optional=True)
    if selected_project:
        read_project(selected_project)
    projects = project_rows()
    campaigns = {p["campaign_id"]: p["campaign_title"] for p in projects}
    if selected_campaign and selected_campaign not in campaigns:
        abort(404)
    scoped = [p for p in projects if not selected_campaign or p["campaign_id"] == selected_campaign]
    project_choices = [(p["id"], f"{p['campaign_title']} · {p['title']}") for p in scoped]
    selectable = [(p["id"], label) for p, (_, label) in zip(scoped, project_choices) if may_upload(p)]
    project_map = {p["id"]: p for p in projects}
    selected_kind = choices(arguments, "kind", ASSET_KINDS) if arguments.get("kind") else None
    assets = query("""SELECT a.*,u.display_name AS creator FROM asset a
                      JOIN person u ON u.id=a.creator_id
                      WHERE (%s IS NULL OR EXISTS (SELECT 1 FROM project_asset pa WHERE pa.asset_id=a.id
                        AND pa.project_id=%s)) ORDER BY a.id DESC""", (selected_project, selected_project))
    rows = []
    for asset in assets:
        if selected_kind and asset["kind"] != selected_kind:
            continue
        if not can_read_asset(asset, project_map):
            continue
        key = asset["id"]
        projects_using = query("""SELECT p.id,p.title,c.title AS campaign_title FROM project_asset pa
                                   JOIN project p ON p.id=pa.project_id JOIN campaign c ON c.id=p.campaign_id
                                   WHERE pa.asset_id=%s ORDER BY p.id""", (key,))
        if selected_campaign and not any(p["id"] in project_map
                                         and project_map[p["id"]]["campaign_id"] == selected_campaign
                                         for p in projects_using):
            continue
        project_names = "、".join(f"{p['campaign_title']}／{p['title']}" for p in projects_using if p["id"] in project_map)
        actions = [button("引用详情", href=f"/manage/asset-references?id={key}")]
        path = stored_path(asset["uri"])
        if path and path.is_file():
            actions.append(button("下载", href=f"/manage/file/{key}/download"))
        if asset["creator_id"] == actor() and allowed("REGISTER_ASSET"):
            if selectable:
                actions.append(button("关联项目", "attach", identifier=key, fields=[select_field("project", "目标项目", selectable)]))
            actions.append(button("删除素材", "delete", identifier=key, confirm="确认删除素材？存在项目或历史版本引用时会被拦截。"))
        rows.append(row(asset_link(asset), ASSET_KINDS[asset["kind"]], project_names, asset["creator"],
                        asset["created_at"], actions=actions))
    actions = []
    if selectable:
        actions = [
            button("上传文件", "upload", fields=[
                select_field("project", "项目", selectable, value=selected_project),
                select_field("kind", "文件类别", {k: ASSET_KINDS[k] for k in ("WORD", "PHOTO", "VIDEO_RAW", "VIDEO_FINAL")}),
                field("title", "素材名称"), field("file", "选择文件", "file"),
            ]),
            button("登记预览链接", "link", fields=[
                select_field("project", "项目", selectable, value=selected_project),
                select_field("kind", "链接类型", {k: ASSET_KINDS[k] for k in ("XIUMI_LINK", "WECHAT_LINK")}),
                field("title", "链接名称"), field("url", "HTTPS 预览地址", "url"),
            ]),
        ]
    return listing(("素材", "类型", "关联项目", "登记人", "登记时间"), rows, actions=actions,
                   filters=[select_field("campaign", "活动", campaigns, required=False),
                            select_field("project", "项目", project_choices, required=False),
                            select_field("kind", "素材类型", ASSET_KINDS, required=False)])


def asset_references(arguments):
    key = number(arguments, "id")
    asset = required_row("SELECT * FROM asset WHERE id=%s", (key,))
    if not can_read_asset(asset):
        abort(404)
    projects = {p["id"]: p for p in project_rows()}
    refs = query("SELECT project_id FROM project_asset WHERE asset_id=%s", (key,))
    rows = []
    for ref in refs:
        project = projects.get(ref["project_id"])
        if project:
            editable = open_project(project) and (owns(project) or (may_upload(project) and asset["creator_id"] == actor()))
            rows.append(row("项目引用", project["title"], "—", actions=[
                button("解除关联", "detach", identifier=key, fields=[field("project", "项目", "hidden", value=project["id"])],
                       confirm="仅解除此项目的素材关联。已提交版本的历史引用会保留。"),
            ] if editable else []))
    for version in query("""SELECT s.* FROM submission s JOIN submission_asset sa ON sa.submission_id=s.id
                            WHERE sa.asset_id=%s ORDER BY s.id DESC""", (key,)):
        project = projects.get(version["project_id"])
        if project and submission_visible(version, project):
            rows.append(row("版本引用", project["title"], version["version_no"], actions=[
                button("审核时间线", href=f"/manage/review-history?id={version['id']}"),
            ]))
    return listing(("引用类型", "项目", "版本"), rows, description=asset["title"])


def matches_header(suffix, payload):
    if suffix == ".docx":
        return payload.startswith(b"PK\x03\x04")
    if suffix == ".png":
        return payload.startswith(b"\x89PNG\r\n\x1a\n")
    if suffix in {".jpg", ".jpeg"}:
        return payload.startswith(b"\xff\xd8\xff")
    if suffix == ".gif":
        return payload.startswith((b"GIF87a", b"GIF89a"))
    if suffix == ".webp":
        return payload[:4] == b"RIFF" and payload[8:12] == b"WEBP"
    if suffix == ".webm":
        return payload.startswith(b"\x1a\x45\xdf\xa3")
    return payload[4:8] == b"ftyp"


def docx_text(path):
    with ZipFile(path) as archive:
        if "[Content_Types].xml" not in archive.namelist():
            raise ValueError("Invalid Word package")
        document = archive.getinfo("word/document.xml")
        if document.file_size > 2 * 1024 * 1024:
            raise ValueError("Word text XML is too large")
        content = archive.read(document)
    if b"<!DOCTYPE" in content or b"<!ENTITY" in content:
        raise ValueError("Word XML declaration is not allowed")
    root = ElementTree.fromstring(content)
    ns = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    return ["".join(part.text or "" for part in block.iter(ns + "t")) for block in root.iter(ns + "p")]


def save_upload(project_id, kind, title):
    storage = request.files.get("file")
    if not storage or not storage.filename:
        abort(400, "请选择要上传的文件。")
    suffix = Path(storage.filename).suffix.lower()
    declared = FILE_TYPES.get(suffix)
    if not declared or declared[0] != ("VIDEO" if kind.startswith("VIDEO") else kind):
        abort(400, "文件格式和素材类型不匹配。支持 DOCX、JPEG、PNG、GIF、WEBP、MP4、MOV、WebM。")
    first = storage.stream.read(32)
    if not matches_header(suffix, first):
        abort(400, "文件内容与扩展名不符合。")
    limit = current_app.config["ASSET_MAX_BYTES"] if kind.startswith("VIDEO") else 20 * 1024 * 1024
    stored = root_path() / (uuid4().hex + suffix)
    digest = hashlib.sha256()
    try:
        with stored.open("xb") as output:
            chunk = first
            total = 0
            while chunk:
                total += len(chunk)
                if total > limit:
                    abort(413, "文件超过该类型的上传限制。")
                output.write(chunk)
                digest.update(chunk)
                chunk = storage.stream.read(1024 * 1024)
        if suffix == ".docx":
            docx_text(stored)
    except (BadZipFile, ValueError, KeyError, ElementTree.ParseError):
        stored.unlink(missing_ok=True)
        abort(400, "Word 文档格式无效，或正文超过预览限制。")
    except Exception:
        stored.unlink(missing_ok=True)
        raise
    try:
        return invoke("sp_register_asset", project_id, kind, title, "files/" + stored.name, digest.hexdigest(), output=True)
    except MySQLError as error:
        # On transport failure the server may already have committed. Retain the file for reconciliation.
        if error.args[0] > 0 and error.args[0] not in {2006, 2013, 2055}:
            stored.unlink(missing_ok=True)
        raise


def clear_file(key):
    if not STORAGE_KEY.fullmatch(key):
        return False
    path = stored_path("files/" + key)
    if not path:
        return False
    try:
        path.unlink(missing_ok=True)
    except OSError:
        return False
    execute("DELETE FROM web_file_cleanup WHERE storage_key=%s", (key,))
    return True


def save_asset(action):
    require_permission("REGISTER_ASSET")
    data = body()
    if action in {"upload", "link"}:
        project_id = number(data, "project")
        if not may_upload(read_project(project_id)):
            abort(403, "仅项目参与者可为未发布项目登记素材。")
        title = text(data, "title", 180)
        if action == "link":
            kind = choices(data, "kind", {"XIUMI_LINK", "WECHAT_LINK"})
            return {"id": invoke("sp_register_asset", project_id, kind, title, https_link(data), None, output=True)}
        kind = choices(data, "kind", {"WORD", "PHOTO", "VIDEO_RAW", "VIDEO_FINAL"})
        return {"id": save_upload(project_id, kind, title)}
    asset_id = number(data, "id")
    pending_cleanup = None
    with transaction():
        if action in {"attach", "detach"}:
            project_id = number(data, "project")
            project = read_project(project_id)
            call("boya_lock_project", (project_id,))
        asset = required_row("SELECT * FROM asset WHERE id=%s FOR UPDATE", (asset_id,))
        own = asset["creator_id"] == actor()
        if action == "attach":
            if not own or not may_upload(project):
                abort(403, "只能将本人登记的素材关联到有权限的项目。")
            execute("INSERT INTO project_asset(project_id,asset_id) VALUES (%s,%s)", (project_id, asset_id))
            audit("WEB_ASSET_LINK", "asset", asset_id, {"project_id": project_id})
        elif action == "detach":
            if not owns(project) and not (own and may_upload(project)):
                abort(403)
            if one("""SELECT 1 AS found FROM submission_asset sa JOIN submission s ON s.id=sa.submission_id
                      WHERE sa.asset_id=%s AND s.project_id=%s LIMIT 1""", (asset_id, project_id)):
                abort(409, "此素材已进入当前项目的历史版本，关联须保留。")
            execute("DELETE FROM project_asset WHERE project_id=%s AND asset_id=%s", (project_id, asset_id))
            audit("WEB_ASSET_UNLINK", "asset", asset_id, {"project_id": project_id})
        elif action == "delete":
            if not own:
                abort(403)
            if one("""SELECT 1 AS found FROM project_asset WHERE asset_id=%s
                      UNION ALL SELECT 1 FROM submission_asset WHERE asset_id=%s LIMIT 1""", (asset_id, asset_id)):
                abort(409, "素材仍被项目或历史版本引用，不能删除。")
            key = asset["uri"].removeprefix("files/")
            if STORAGE_KEY.fullmatch(key) and not one(
                "SELECT id FROM asset WHERE uri=%s AND id<>%s LIMIT 1", (asset["uri"], asset_id)
            ):
                execute("INSERT INTO web_file_cleanup(storage_key) VALUES (%s)", (key,))
                pending_cleanup = key
            execute("DELETE FROM asset WHERE id=%s", (asset_id,))
            audit("WEB_ASSET_DELETE", "asset", asset_id)
        else:
            abort(404)
    if pending_cleanup and not clear_file(pending_cleanup):
        return {"id": asset_id, "message": "元数据已删除，剩余文件会在管理员重试清理后移除。"}
    return {"id": asset_id}


def serve_asset(asset_id, mode):
    asset = required_row("SELECT * FROM asset WHERE id=%s", (asset_id,))
    if not can_read_asset(asset):
        abort(404)
    filepath = stored_path(asset["uri"])
    if not filepath or not filepath.is_file():
        abort(404, "文件尚未放入服务器素材目录。")
    file_type = FILE_TYPES.get(filepath.suffix.lower())
    if not file_type or mode not in {"preview", "download"}:
        abort(404)
    if mode == "download":
        filename = asset["title"].replace("/", "_").replace("\\", "_").replace("\r", "").replace("\n", "")
        return send_file(filepath, mimetype=file_type[1], download_name=filename + filepath.suffix, as_attachment=True)
    if file_type[0] == "WORD":
        try:
            paragraphs = docx_text(filepath)
        except (BadZipFile, ValueError, KeyError, ElementTree.ParseError):
            abort(400, "此 Word 文件无法预览，可下载原件。")
        return render_template("file_preview.html", title=asset["title"], paragraphs=paragraphs, asset_id=asset_id)
    return send_file(filepath, mimetype=file_type[1], conditional=True)


def production_list(kind):
    states = {r["project_id"]: r["project_status"] for r in query(
        "SELECT project_id,project_status FROM v_campaign_progress WHERE project_kind=%s", (kind,),
    )}
    rows = [row(p["title"], p["campaign_title"], PROJECT_KINDS[kind],
                badge(states[p["id"]], PROJECT_STATES), actions=[
        button("版本与发布", href=f"/manage/versions?id={p['id']}"),
        *([button("项目任务", href=f"/manage/tasks?project={p['id']}")] if allowed("LOG_WORK") or owns(p) else []),
    ]) for p in project_rows(kind)]
    return listing(("项目", "活动", "类型", "进度"), rows)


def versions(arguments):
    project_id = number(arguments, "id")
    project = read_project(project_id)
    rows = []
    items = query("""SELECT s.*,u.display_name,p.url,p.channel,
                      (SELECT h.to_stage FROM handover_record h WHERE h.submission_id=s.id ORDER BY h.id DESC LIMIT 1) AS stage,
                      (SELECT h.to_person_id FROM handover_record h WHERE h.submission_id=s.id ORDER BY h.id DESC LIMIT 1) AS recipient
                      FROM submission s JOIN person u ON u.id=s.submitted_by LEFT JOIN publication p ON p.submission_id=s.id
                      WHERE s.project_id=%s ORDER BY s.version_no DESC""", (project_id,))
    for item in items:
        if submission_visible(item, project):
            rows.append(row(item["version_no"], VERSION_KINDS[item["kind"]], item["display_name"],
                            "已发布" if item["url"] else STAGES.get(item["stage"], "已提交"), item["submitted_at"],
                            link(item["channel"], item["url"]) if item["url"] else None,
                            actions=[button("查看版本及审核", href=f"/manage/review-history?id={item['id']}")]))
    actions = []
    if allowed("SUBMIT") and team_access(project) and open_project(project) and project["delivery_mode"] == "REVIEWED":
        current = items[0] if items else None
        if not current or (current["recipient"] == actor() and current["submitted_by"] == actor()
                           and current["stage"] in {"REWORK", "WECHAT_DRAFT"}):
            kind = ("WECHAT" if current and current["stage"] == "WECHAT_DRAFT" else "XIUMI") if project["kind"] == "ARTICLE" else (
                "VIDEO" if project["kind"] == "VIDEO" else "GENERIC"
            )
            actions.append(button("提交新版本", "submit", identifier=project_id, fields=[
                select_field("kind", "提交类型", {kind: VERSION_KINDS[kind]}, value=kind),
                select_field("assets", "绑定素材（可多选）", asset_options(project_id), multiple=True),
                field("note", "提交说明", "textarea", required=False),
            ]))
    if team_access(project):
        actions.append(button("项目素材", href=f"/manage/assets?project={project_id}"))
    return listing(("版本", "类型", "提交者", "审核进度", "提交时间", "发布"), rows,
                   actions=actions, description=project["title"])


def can_publish(project_id):
    return allowed("PUBLISH") and one("SELECT 1 FROM v_project_publishers WHERE project_id=%s AND person_id=%s",
                                      (project_id, actor())) is not None


def pending_deliveries(*, limit=None):
    items = query("""
        SELECT r.project_title AS title,r.version_no,r.review_stage AS stage,r.handed_at,r.submission_id,
               r.project_id,0 AS author_action
        FROM v_pending_reviews r WHERE %s AND r.reviewer_id=%s
        UNION ALL
        SELECT p.title,s.version_no,h.to_stage,h.handed_at,s.id,p.id,
               (h.to_stage IN ('REWORK','WECHAT_DRAFT') AND h.to_person_id=s.submitted_by)
        FROM handover_record h JOIN submission s ON s.id=h.submission_id JOIN project p ON p.id=s.project_id
        WHERE ((h.to_stage='PUBLISH' AND EXISTS (SELECT 1 FROM v_project_publishers pub
                  WHERE pub.project_id=p.id AND pub.person_id=%s))
               OR (h.to_person_id=%s AND (
                   (h.to_stage='REWORK' AND %s AND s.submitted_by<>h.to_person_id)
                   OR (h.to_stage IN ('REWORK','WECHAT_DRAFT') AND %s AND s.submitted_by=h.to_person_id))))
          AND NOT EXISTS (SELECT 1 FROM handover_record newer WHERE newer.submission_id=s.id AND newer.id>h.id)
          AND NOT EXISTS (SELECT 1 FROM submission newer WHERE newer.previous_id=s.id)
          AND NOT EXISTS (SELECT 1 FROM publication WHERE submission_id=s.id)
        ORDER BY handed_at,submission_id
    """ + (" LIMIT %s" if limit else ""), (allowed("REVIEW"), actor(), actor(), actor(), allowed("ASSIGN_WORK"), allowed("SUBMIT"),
                                           *((limit,) if limit else ())))
    for item in items:
        item["label"] = {"PUBLISH": "登记发布", "REWORK": "转交修改"}.get(item["stage"], "审阅")
        item["href"] = f"/manage/review-history?id={item['submission_id']}"
        if item["author_action"]:
            item["label"] = "提交微信草稿" if item["stage"] == "WECHAT_DRAFT" else "修改重提"
            item["href"] = f"/manage/versions?id={item['project_id']}"
    return items


def review_center(_arguments):
    if not any(allowed(p) for p in ("REVIEW", "ASSIGN_WORK", "PUBLISH", "SUBMIT")):
        abort(403)
    rows = [row(item["title"], item["version_no"], badge(item["stage"], STAGES), item["handed_at"],
                actions=[button(item["label"], href=item["href"])]) for item in pending_deliveries()]
    history = query("""SELECT r.*,s.version_no,p.title FROM review_record r
                       JOIN submission s ON s.id=r.submission_id JOIN project p ON p.id=s.project_id
                       WHERE r.reviewer_id=%s ORDER BY reviewed_at DESC,r.id DESC""", (actor(),))
    model = listing(("项目", "版本", "阶段", "交接时间"), rows)
    model["related"] = [{"title": "我的审核历史", "columns": ["项目", "版本", "阶段", "结果", "意见", "时间"],
                         "rows": [row(h["title"], h["version_no"], STAGES[h["stage"]],
                                      badge(h["decision"], DECISIONS), h["feedback"], h["reviewed_at"],
                                      actions=[button("查看版本", href=f"/manage/review-history?id={h['submission_id']}")])
                                  for h in history]}]
    return model


def review_history(arguments):
    key = number(arguments, "id")
    item, project = read_submission(key)
    latest = one("SELECT id FROM submission WHERE project_id=%s ORDER BY version_no DESC LIMIT 1", (project["id"],))["id"] == key
    current = one("SELECT * FROM handover_record WHERE submission_id=%s ORDER BY id DESC LIMIT 1", (key,))
    pub = one("""SELECT pub.*,p.display_name AS publisher FROM publication pub JOIN person p ON p.id=pub.published_by
                 WHERE pub.submission_id=%s""", (key,))
    actions = [button("返回项目版本", href=f"/manage/versions?id={project['id']}")]
    if latest and current and not pub:
        stage, recipient = current["to_stage"], current["to_person_id"]
        if allowed("REVIEW") and one("SELECT submission_id FROM v_pending_reviews WHERE submission_id=%s AND reviewer_id=%s", (key, actor())):
            for result, label in DECISIONS.items():
                actions.append(button(label, "review", identifier=key, fields=[
                    field("decision", "结论", "hidden", value=result), field("feedback", "审核意见", "textarea"),
                ], confirm="确认退回该版本给上一环节处理？" if result == "RETURNED" else None))
        if stage == "REWORK" and recipient == actor() and item["submitted_by"] != actor() and allowed("ASSIGN_WORK"):
            actions.append(button("转交原提交人", "forward", identifier=key,
                                  fields=[field("note", "修改要求", "textarea")]))
        if stage == "PUBLISH" and can_publish(project["id"]):
            actions.append(button("正式发布", "publish", identifier=key, fields=[
                field("channel", "发布渠道"), field("url", "作品链接", "url"),
            ], confirm=("确认已在公众号发布，并按此链接结清推文必做任务？" if project["kind"] == "ARTICLE"
                        else "核对作品链接后确认正式发布。")))
    events = [(item["submitted_at"], row(item["submitted_at"], "提交版本", item["note"]))]
    events.extend((r["reviewed_at"], row(r["reviewed_at"], f"{STAGES[r['stage']]} · {r['display_name']}",
                                        f"{DECISIONS[r['decision']]}：{r['feedback']}")) for r in query("""
        SELECT r.*,p.display_name FROM review_record r JOIN person p ON p.id=r.reviewer_id WHERE r.submission_id=%s
    """, (key,)))
    events.extend((h["handed_at"], row(h["handed_at"], f"交接至{STAGES[h['to_stage']]}",
                                      f"{h['sender']} → {h['recipient'] or '发布'}" + (f" · {h['note']}" if h["note"] else "")))
                  for h in query("""SELECT h.*,f.display_name AS sender,t.display_name AS recipient FROM handover_record h
                                    JOIN person f ON f.id=h.from_person_id LEFT JOIN person t ON t.id=h.to_person_id
                                    WHERE h.submission_id=%s""", (key,)))
    if pub:
        events.append((pub["published_at"], row(pub["published_at"], f"正式发布 · {pub['publisher']}", link(pub["channel"], pub["url"]))))
    media = query("""SELECT a.* FROM submission_asset sa JOIN asset a ON a.id=sa.asset_id WHERE sa.submission_id=%s""", (key,))
    model = listing(("时间", "环节", "记录"), [r for _, r in sorted(events, key=lambda pair: pair[0], reverse=True)],
                    actions=actions, timeline=True, description=f"{project['title']} · 第 {item['version_no']} 版")
    model["related"] = [{"title": "本版素材与预览", "columns": ["素材", "类型"],
                         "rows": [row(asset_link(asset), ASSET_KINDS[asset["kind"]]) for asset in media]}]
    model["related_first"] = True
    return model


def save_version(action):
    data = body()
    key = number(data, "id")
    if action == "submit":
        require_permission("SUBMIT")
        if not team_access(read_project(key)):
            abort(403)
        assets = selected(data, "assets")
        if not assets:
            abort(400, "至少选择一项本项目素材。")
        result = invoke("sp_submit", key, choices(data, "kind", VERSION_KINDS), json.dumps(assets),
                        text(data, "note", 500, True), output=True)
        return {"id": result}
    item, project = read_submission(key)
    if action == "review":
        require_permission("REVIEW")
        required_row("SELECT submission_id FROM v_pending_reviews WHERE submission_id=%s AND reviewer_id=%s", (key, actor()))
        invoke("sp_review_submission", key, choices(data, "decision", DECISIONS), text(data, "feedback", 1000))
    elif action == "forward":
        require_permission("ASSIGN_WORK")
        invoke("sp_forward_rework", key, text(data, "note", 500))
    elif action == "publish":
        if not can_publish(project["id"]):
            abort(403, "推文须由本项目指定的在任主编发布。" if project["kind"] == "ARTICLE" else "没有此项目的发布权限。")
        invoke("sp_publish", key, text(data, "channel", 60), https_link(data))
        if project["kind"] == "ARTICLE":
            return {"id": key, "message": "推文已登记发布，项目已完成。"}
    else:
        abort(404)
    return {"id": item["id"]}
