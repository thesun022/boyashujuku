import base64
import io
import os
import pymysql
import pytest
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path
from threading import Barrier
from zipfile import ZIP_DEFLATED, ZipFile

from playwright.sync_api import expect, sync_playwright

from boya_web.db import get_db
from .test_web_auth import PASSWORD, app, csrf, login, pytestmark, sql


PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP1kAAAAASUVORK5CYII="
)


def word_document():
    buffer = io.BytesIO()
    with ZipFile(buffer, "w", ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
        """)
        archive.writestr("_rels/.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
        """)
        archive.writestr("word/document.xml", """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body><w:p><w:r><w:t>课程验收用虚构新闻稿</w:t></w:r></w:p></w:body>
            </w:document>
        """)
    return buffer.getvalue()


class Operator:
    def __init__(self, app, name, password=None):
        self.client = app.test_client()
        assert login(self.client, name, password).status_code == 302
        self.headers = {"X-CSRFToken": csrf(self.client.get("/"))}

    def read(self, module, status=200, **params):
        response = self.client.get("/api/manage/" + module, query_string=params)
        assert response.status_code == status, f"{module}: {response.status_code}: {response.json}"
        return response.json

    def write(self, module, action, expected=200, **data):
        response = self.client.post(f"/api/manage/{module}/{action}", json=data, headers=self.headers)
        assert response.status_code == expected, f"{module}/{action}: {response.status_code}: {response.json}"
        return response.json

    def upload(self, project, kind, title, content, filename, status=200):
        response = self.client.post("/api/manage/assets/upload", data={
            "project": str(project), "kind": kind, "title": title, "file": (io.BytesIO(content), filename),
        }, headers=self.headers)
        assert response.status_code == status, f"upload: {response.status_code}: {response.json}"
        return response.json


def campaign(manager, code, third="0"):
    return manager.write("campaigns", "create", code=code, title=code + " 演示活动",
                         starts_at="2026-10-25T08:30", ends_at="", third=third)["id"]


def project(manager, campaign_id, code, kind, delivery="REVIEWED"):
    return manager.write("projects", "create", id=campaign_id, code=code, title=code + " 演示项目",
                         kind=kind, delivery=delivery, required="1")["id"]


def task(manager, project_id, code, kind, mode="MEMBER"):
    return manager.write("tasks", "create", project=project_id, code=code, title=code + " 演示任务",
                         kind=kind, mode=mode, required="1")["id"]


def route(manager, project_id, stages):
    users = {"MINISTER": 1, "CHIEF": 2, "SECOND": 3, "THIRD": 4}
    for stage in stages:
        manager.write("projects", "route", id=project_id, stage=stage, reviewer=users[stage])


def work_record(user, work, membership, minutes=35, participation="PRIMARY"):
    return user.write("task-history", "contribution", id=work, membership=membership,
                      participation=participation, worked_at="", minutes=minutes, note="验收实际参与")


def test_member_history_roles_and_audit(app):
    manager, admin = Operator(app, "demo-minister"), Operator(app, "demo-web-admin")
    member = Operator(app, "demo-writer")
    member.read("people", status=403)
    assert member.client.get("/manage/people").status_code == 403
    manager.read("system", status=403)
    person = admin.write("people", "create", code="QA-WEB-FICTIONAL", name="虚构课程成员", contact="course.invalid")["id"]
    admin.write("people", "edit", id=person, code="QA-WEB-FICTIONAL", name="虚构课程成员乙", contact="")
    cohort = admin.write("people", "cohort", code="QA-COHORT", label="课程测试届", year=2024)["id"]
    membership = admin.write("people", "join", id=person, cohort=cohort, position="MEMBER", joined_at="")["id"]
    skill = admin.write("skills", "create", code="QA-EDIT", label="课程剪辑")["id"]
    admin.write("skills", "edit", id=skill, code="QA-EDIT", label="剪辑演示")
    admin.write("people", "skills", id=person, skills=[skill])
    admin.write("people", "position", id=membership, position="MINISTER")
    history = admin.read("member-history", id=person)
    assert {r["cells"][1] for r in history["rows"]} >= {"课程测试届", "部员", "部长"}
    assert admin.read("people", cohort=cohort, q="虚构课程成员乙")["total"] == 1
    role = admin.write("roles", "create", code="QA_REPORTER", label="验收记录员", permissions=["LOG_WORK"])["id"]
    admin.write("roles", "edit", id=role, label="验收新角色", permissions=["LOG_WORK", "REGISTER_ASSET"])
    account = admin.write("system", "create", person=person, username="qa-fictional-login", password=PASSWORD, roles=[role])["id"]
    current = Operator(app, "qa-fictional-login")
    assert current.client.get("/api/me").json["permissions"] == ["LOG_WORK", "REGISTER_ASSET"]
    admin.write("system", "roles", id=account, roles=[])
    assert current.client.get("/api/me").json["permissions"] == []
    admin.write("system", "edit", id=account, username="qa-fictional-login", password=PASSWORD)
    assert current.client.get("/api/me").status_code == 401
    current = Operator(app, "qa-fictional-login")
    admin.write("people", "exit", id=membership)
    assert current.client.get("/api/me").status_code == 401
    assert admin.read("people", state="EXITED", q="虚构课程成员乙")["total"] == 1
    joined_again = admin.write("people", "join", id=person, cohort=cohort, position="MEMBER")["id"]
    assert joined_again != membership
    assert admin.read("people", state="ACTIVE", q="虚构课程成员乙")["total"] == 1
    admin.write("system", "enable", id=account, enabled="1")
    assert Operator(app, "qa-fictional-login").client.get("/api/me").status_code == 200
    own_account = next(r for r in admin.read("system", q="demo-web-admin")["rows"])
    admin_id = own_account["actions"][0]["id"]
    admin.write("system", "roles", 409, id=admin_id, roles=[])
    assert admin.read("audit", action="WEB_POSITION_CHANGE")["total"] >= 1
    assert admin.read("backup")["notes"][0]["title"] == "完整备份"


def test_assignment_history_and_camera_conflicts(app, sql):
    manager = Operator(app, "demo-minister")
    camera = manager.write("cameras", "create", code="QA-CAMERA", name="课程相机", model="测试型号",
                           source="PURCHASED", inventory="AVAILABLE", borrowed_at="", due_back_at="")["id"]
    cam = campaign(manager, "QA-TASK")
    manager.write("campaigns", "edit", id=cam, code="QA-TASK", title="多人参与演示",
                  starts_at="2026-10-25T08:00", ends_at="", third="0")
    pro = project(manager, cam, "PHOTO-TEAM", "PHOTO", "WORK_ONLY")
    work = task(manager, pro, "CAPTURE", "PHOTO")
    other = task(manager, pro, "CAPTURE-B", "PHOTO")
    for member in (7, 8):
        manager.write("task-history", "assign", id=work, membership=member)
    assert "在任" in manager.write("task-history", "assign", 409, id=work, membership=10)["error"]
    shooter = Operator(app, "demo-photo-a")
    stranger = Operator(app, "demo-photo-b")
    stranger.read("task-history", status=404, id=other)
    work_record(shooter, work, 7)
    work_record(stranger, work, 8, 47, "COLLABORATOR")
    manager.write("task-history", "status", id=work, version=0, status="IN_PROGRESS")
    assert "刷新" in manager.write("task-history", "status", 409, id=work, version=0, status="DONE")["error"]
    sql.execute("SELECT CURRENT_TIMESTAMP AS moment")
    now = sql.fetchone()["moment"]
    params = {"membership": 7, "starts_at": (now - timedelta(minutes=1)).isoformat(),
              "ends_at": (now + timedelta(minutes=30)).isoformat()}
    reservation = manager.write("camera-usage", "reserve", id=camera, work=work, **params)["id"]
    conflict = manager.write("camera-usage", "reserve", 409, id=camera, work=other, **params)
    assert "已有预约" in conflict["error"]
    manager.write("camera-usage", "checkout", id=reservation)
    assert manager.read("camera-usage", id=camera)["rows"][0]["cells"][-1] == "使用中"
    manager.write("camera-usage", "return", id=reservation)
    assert manager.read("camera-usage", id=camera)["rows"][0]["cells"][-1] == "已归还"
    borrowed = manager.write(
        "cameras", "create", code="QA-BORROWED", name="借入相机", model="测试型号", source="BORROWED",
        inventory="AVAILABLE", borrowed_at=(now - timedelta(days=1)).isoformat(),
        due_back_at=(now + timedelta(days=1)).isoformat(),
    )["id"]
    manager.write("cameras", "return-external", id=borrowed)
    assert manager.read("cameras", q="QA-BORROWED")["rows"][0]["cells"][4]["status"] == "RETURNED_TO_OWNER"
    manager.write("camera-usage", "reserve", 409, id=borrowed, work=work, **params)
    manager.write("task-history", "status", id=work, version=1, status="DONE")
    history = manager.read("task-history", id=work)
    assert history["timeline"] and len(history["related"][0]["rows"]) == 2
    assert len(history["related"][1]["rows"]) == 2
    assignment = history["related"][0]["rows"][0]["actions"][0]["id"]
    manager.write("task-history", "unassign", id=assignment)
    assert manager.read("task-history", id=work)["related"][0]["rows"][0]["cells"][-1] != "—"
    assert manager.read("statistics", group="device", q="QA-CAMERA")["rows"][0]["cells"][-3:] == ["1", "1", "1"]
    for group in ("person", "cohort", "kind", "campaign"):
        assert manager.read("statistics", group=group)["total"] > 0
    shooter.read("cameras", status=403)


def test_shared_asset_deletion_and_file_limits(app, sql):
    manager, outsider = Operator(app, "demo-minister"), Operator(app, "demo-writer")
    cam = campaign(manager, "QA-MEDIA")
    first, second = (project(manager, cam, code, "PHOTO", "WORK_ONLY") for code in ("ONE", "TWO"))
    manager.upload(first, "PHOTO", "错误扩展", b"fake png", "photo.png", status=400)
    manager.upload(first, "WORD", "错误 Word", b"PK\x03\x04invalid", "draft.docx", status=400)
    video_limit = app.config["ASSET_MAX_BYTES"]
    app.config["ASSET_MAX_BYTES"] = 24
    try:
        manager.upload(first, "VIDEO_RAW", "超限视频", b"\x00\x00\x00\x20ftyp" + b"x" * 60,
                       "oversize.mp4", status=413)
    finally:
        app.config["ASSET_MAX_BYTES"] = video_limit
    asset = manager.upload(first, "PHOTO", "课程图片", PNG, "same.png")["id"]
    other = manager.upload(first, "PHOTO", "同名上传", PNG, "same.png")["id"]
    sql.execute("SELECT id,uri FROM asset WHERE id IN (%s,%s)", (asset, other))
    files = {f["id"]: Path(os.environ["BOYA_ASSET_ROOT"]) / f["uri"].removeprefix("files/") for f in sql.fetchall()}
    assert files[asset] != files[other] and files[asset].is_file() and files[other].is_file()
    assert outsider.client.get(f"/manage/file/{asset}/download").status_code == 404
    assert manager.client.get(f"/manage/file/{asset}/preview").data == PNG
    manager.write("assets", "attach", id=asset, project=second)
    assert manager.read("asset-references", id=asset)["total"] == 2
    assert manager.read("assets", campaign=cam, project=second, q="课程图片")["total"] == 1
    assert "引用" in manager.write("assets", "delete", 409, id=asset)["error"]
    manager.write("asset-references", "detach", id=asset, project=first)
    manager.write("assets", "delete", 409, id=asset)
    assert files[asset].is_file()
    manager.write("asset-references", "detach", id=asset, project=second)
    manager.write("assets", "delete", id=asset)
    assert not files[asset].exists() and files[other].is_file()


def test_two_web_operators_cannot_overwrite_the_same_task_version(app, sql):
    manager, admin = Operator(app, "demo-minister"), Operator(app, "demo-web-admin")
    person = admin.write("people", "create", code="QA-SECOND-MANAGER", name="虚构并发负责人")["id"]
    admin.write("system", "create", person=person, username="qa-second-manager", password=PASSWORD, roles=["MANAGER"])
    cam = campaign(manager, "QA-WEB-LOCK")
    pro = project(manager, cam, "LOCK", "PHOTO", "WORK_ONLY")
    work = task(manager, pro, "LOCK", "PHOTO")
    sql.execute("UPDATE campaign SET created_by=%s WHERE id=%s", (person, cam))
    ready = Barrier(2)

    def update(username, next_state):
        account = Operator(app, username)
        ready.wait(timeout=10)
        return account.client.post("/api/manage/task-history/status",
                                   json={"id": work, "version": 0, "status": next_state},
                                   headers=account.headers).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        a = executor.submit(update, "demo-minister", "IN_PROGRESS")
        b = executor.submit(update, "qa-second-manager", "BLOCKED")
        assert sorted([a.result(timeout=20), b.result(timeout=20)]) == [200, 409]
    sql.execute("SELECT lock_version FROM work_item WHERE id=%s", (work,))
    assert sql.fetchone()["lock_version"] == 1


def test_article_rework_approval_and_publish(app, live_app, sql):
    manager, chief, teacher = (Operator(app, name) for name in ("demo-minister", "demo-chief", "demo-second"))
    layout, writer, third = (Operator(app, name) for name in ("demo-layout", "demo-writer", "demo-third"))
    cam = campaign(manager, "QA-ARTICLE")
    pro = project(manager, cam, "ARTICLE", "ARTICLE")
    video = project(manager, cam, "SIBLING", "VIDEO")
    edit = task(manager, video, "VIDEO-EDIT", "VIDEO_EDIT")
    route(manager, pro, ["MINISTER", "CHIEF", "SECOND"])
    draft, design = (task(manager, pro, code, kind) for code, kind in [("DRAFT", "WRITING"), ("LAYOUT", "LAYOUT")])
    manager.write("task-history", "assign", id=draft, membership=5)
    manager.write("task-history", "assign", id=design, membership=6)
    work_record(writer, draft, 5)
    work_record(layout, design, 6)
    word = writer.upload(pro, "WORD", "新闻原稿", word_document(), "原稿.docx")["id"]
    response = writer.client.get(f"/manage/file/{word}/preview")
    assert response.status_code == 200 and "课程验收用虚构新闻稿" in response.get_data(as_text=True)
    photo = layout.upload(pro, "PHOTO", "推文图片", PNG, "photo.png")["id"]
    original = layout.write("assets", "link", project=pro, kind="XIUMI_LINK", title="初版秀米",
                            url="https://example.invalid/xiumi/a")["id"]
    draft_url = layout.write("assets", "link", project=pro, kind="WECHAT_LINK", title="微信草稿",
                             url="https://example.invalid/wechat/b")["id"]
    first = layout.write("versions", "submit", id=pro, kind="XIUMI", assets=[word, photo, original], note="初版")["id"]
    manager.write("review-history", "review", id=first, decision="RETURNED", feedback="补充图片说明")
    assert any(item["label"] == "修改重提" and item["href"] == f"/manage/versions?id={pro}"
               for item in layout.client.get("/api/dashboard").json["review_actions"])
    revised = layout.write("versions", "submit", id=pro, kind="XIUMI", assets=[word, photo, original], note="补充完成")["id"]
    manager.write("review-history", "review", id=revised, decision="APPROVED", feedback="秀米合格")
    assert any(item["label"] == "提交微信草稿" and item["href"] == f"/manage/versions?id={pro}"
               for item in layout.client.get("/api/dashboard").json["review_actions"])
    wechat = layout.write("versions", "submit", id=pro, kind="WECHAT", assets=[draft_url], note="同步草稿")["id"]
    teacher.write("review-history", "review", 404, id=wechat, decision="APPROVED", feedback="非当前审核")
    chief.write("review-history", "review", id=wechat, decision="APPROVED", feedback="主编通过")
    teacher.write("review-history", "review", id=wechat, decision="RETURNED", feedback="老师要求更正署名")
    layout.write("versions", "submit", 409, id=pro, kind="XIUMI", assets=[word, photo, original])
    manager.write("review-history", "forward", id=wechat, note="转原排版人员修改")
    teacher_history = teacher.read("review-history", id=wechat)
    assert any("老师要求更正署名" in item["cells"][-1] for item in teacher_history["rows"])
    revision = layout.write("versions", "submit", id=pro, kind="XIUMI", assets=[word, photo, original], note="修正署名")["id"]
    manager.write("review-history", "review", id=revision, decision="APPROVED", feedback="排版重新通过")
    wechat = layout.write("versions", "submit", id=pro, kind="WECHAT", assets=[draft_url], note="同步修正版草稿")["id"]
    chief.write("review-history", "review", id=wechat, decision="APPROVED", feedback="主编复审通过")
    publish = {"id": wechat, "channel": "公众号", "url": "https://example.invalid/article/final"}
    chief.write("review-history", "publish", 409, **publish)
    sql.execute("SELECT status,lock_version FROM work_item WHERE project_id=%s", (pro,))
    assert all((r["status"], r["lock_version"]) == ("TODO", 0) for r in sql.fetchall())
    teacher.write("review-history", "review", id=wechat, decision="APPROVED", feedback="二审通过")
    third.read("review-history", status=404, id=wechat)
    manager.write("review-history", "publish", 403, **publish)
    with pytest.raises(pymysql.MySQLError, match="not the project publisher"):
        sql.execute("CALL sp_publish(1,%s,'公众号',%s)", (wechat, publish["url"]))
    assert "publish" not in [a["action"] for a in manager.read("review-history", id=wechat)["actions"]]
    dest = f"/manage/review-history?id={wechat}"
    assert any(r["href"] == dest and r["stage"] == "PUBLISH"
               for r in chief.client.get("/api/dashboard").json["review_actions"])
    assert not any(r["href"] == dest for r in manager.client.get("/api/dashboard").json["review_actions"])
    sql.execute("SELECT project_status FROM v_campaign_progress WHERE project_id=%s", (pro,))
    assert sql.fetchone()["project_status"] == "READY_TO_PUBLISH"
    missing = task(manager, pro, "PHOTO", "PHOTO")
    assert "PHOTO 演示任务" in chief.write("review-history", "publish", 409, **publish)["error"]
    work_record(manager, missing, 7)
    manager.write("task-history", "status", id=missing, version=0, status="BLOCKED")
    assert "受阻" in chief.write("review-history", "publish", 409, **publish)["error"]
    manager.write("task-history", "status", id=missing, version=1, status="IN_PROGRESS")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="msedge")
        editor = browser_session(browser, live_app, "demo-chief")
        editor.get_by_role("link", name="登记发布 · ARTICLE", exact=False).click()
        browser_operation(editor, "正式发布", {"channel": publish["channel"], "url": publish["url"]},
                          confirm=True, message="推文已登记发布，项目已完成。")
        expect(editor.get_by_role("link", name="公众号", exact=True)).to_have_attribute("href", publish["url"])
        browser.close()
    chief.write("review-history", "publish", 409, **publish)
    assert not any(r["href"] == dest for r in chief.client.get("/api/dashboard").json["review_actions"])
    sql.execute("SELECT published_by FROM publication WHERE submission_id=%s", (wechat,))
    assert sql.fetchone()["published_by"] == 2
    sql.execute("SELECT id,status,changed_by FROM work_item WHERE project_id=%s", (pro,))
    assert {(r["id"], r["status"], r["changed_by"]) for r in sql.fetchall()} == {
        (draft, "DONE", 2), (design, "DONE", 2), (missing, "DONE", 2)}
    sql.execute("SELECT status,lock_version FROM work_item WHERE id=%s", (edit,))
    assert sql.fetchone() == {"status": "TODO", "lock_version": 0}
    sql.execute("SELECT project_status,campaign_percent FROM v_campaign_progress WHERE project_id=%s", (pro,))
    assert sql.fetchone() == {"project_status": "PUBLISHED", "campaign_percent": 50}
    assert layout.read("versions", id=pro)["total"] == 5
    history = manager.read("review-history", id=first)
    assert any("补充图片说明" in row["cells"][-1] for row in history["rows"])
    assert manager.read("articles", q="ARTICLE")["total"] >= 1
    layout.write("assets", "delete", 409, id=photo)
    sql.execute("SELECT third_required FROM submission WHERE id=%s", (wechat,))
    assert sql.fetchone()["third_required"] == 0
    entry = int(manager.read("task-history", id=draft)["related"][1]["rows"][0]["cells"][0])
    manager.write("task-history", "void-contribution", id=draft, entry=entry, reason="发布后核对工时")
    sql.execute("SELECT status FROM work_item WHERE id=%s", (draft,))
    assert sql.fetchone()["status"] == "DONE"
    sql.execute("SELECT project_status FROM v_campaign_progress WHERE project_id=%s", (pro,))
    assert sql.fetchone()["project_status"] == "PUBLISHED"


def browser_session(browser, live_app, username):
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    page.on("dialog", lambda dialog: dialog.accept())
    page.goto(live_app + "/login")
    page.get_by_label("账号", exact=True).fill(username)
    page.get_by_label("密码", exact=True).fill(PASSWORD)
    page.get_by_role("button", name="登录", exact=True).click()
    expect(page.get_by_role("heading", name="工作台", exact=True)).to_be_visible()
    return page


def browser_operation(page, name, data, *, confirm=False, message="操作成功。"):
    page.get_by_role("button", name=name, exact=True).click()
    form = page.get_by_role("dialog")
    expect(form).to_be_visible()
    for key, value in data.items():
        field = form.locator(f'[name="{key}"]')
        if isinstance(value, dict):
            field.set_input_files(value)
        elif field.evaluate("node => node.tagName") == "SELECT":
            field.select_option([str(item) for item in value] if isinstance(value, list) else str(value))
        else:
            field.fill(str(value))
    with page.expect_response(lambda r: r.request.method == "POST" and "/api/manage/" in r.url) as saved:
        form.get_by_role("button", name="继续" if confirm else "保存", exact=True).click()
    response = saved.value
    assert response.ok, response.json()
    expect(form).to_be_hidden()
    expect(page.get_by_role("status")).to_have_text(message)
    return response.json()


def browser_video(page):
    return bytes(page.evaluate("""
        async () => {
          const canvas = document.createElement('canvas');
          canvas.width = 64;
          canvas.height = 48;
          const ctx = canvas.getContext('2d');
          const stream = canvas.captureStream(20);
          const recorder = new MediaRecorder(stream, {mimeType: 'video/webm;codecs=vp8'});
          const chunks = [];
          recorder.ondataavailable = e => chunks.push(e.data);
          const ready = new Promise(resolve => recorder.onstop = resolve);
          ctx.fillStyle = '#247989';
          ctx.fillRect(0, 0, 64, 48);
          recorder.start();
          let x = 0;
          const draw = setInterval(() => {
            ctx.fillStyle = '#e9efdf';
            ctx.fillRect(x++, 8, 12, 12);
          }, 50);
          await new Promise(resolve => setTimeout(resolve, 450));
          clearInterval(draw);
          recorder.stop();
          await ready;
          stream.getTracks().forEach(track => track.stop());
          const bytes = await new Blob(chunks, {type:'video/webm'}).arrayBuffer();
          return [...new Uint8Array(bytes)];
        }
    """))


def test_edge_reassigned_layout_can_correct_hours_and_submit_xiumi(app, live_app, sql):
    manager, writer, layout = (Operator(app, name) for name in ("demo-minister", "demo-writer", "demo-layout"))
    campaign_id = campaign(manager, "QA-BOOK")
    article = project(manager, campaign_id, "读书节推文", "ARTICLE")
    task(manager, article, "撰写读书节稿件", "WRITING")
    design = task(manager, article, "排版读书节推文", "LAYOUT")
    route(manager, article, ["MINISTER", "CHIEF", "SECOND"])
    manager.write("task-history", "assign", id=design, membership=5)
    before = writer.read("statistics", group="person")["rows"][0]["cells"]
    work_record(writer, design, 5, minutes=20)
    manager.write("task-history", "status", id=design, version=0, status="DONE")
    detail = manager.read("task-history", id=design)
    entry = int(detail["related"][1]["rows"][0]["cells"][0])
    manager.write("task-history", "unassign", id=detail["related"][0]["rows"][0]["actions"][0]["id"])
    manager.write("task-history", "assign", id=design, membership=6)
    word = layout.upload(article, "WORD", "读书节原稿", word_document(), "稿件.docx")["id"]
    photo = layout.upload(article, "PHOTO", "读书节配图", PNG, "配图.png")["id"]
    xiumi = layout.write("assets", "link", project=article, kind="XIUMI_LINK", title="读书节秀米",
                         url="https://example.invalid/book/xiumi")["id"]
    submit = dict(id=article, kind="XIUMI", assets=[word, photo, xiumi])
    layout.write("versions", "submit", 409, **submit)
    layout.write("task-history", "void-contribution", 403, id=design, entry=entry, reason="无权代办")
    manager.write("task-history", "void-contribution", 400, id=design, entry=entry, reason=" ")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="msedge")
        new_owner = browser_session(browser, live_app, "demo-layout")
        url = f"{live_app}/manage/task-history?id={design}"
        new_owner.goto(url)
        new_owner.get_by_role("button", name="登记实际参与").click()
        dialog = new_owner.get_by_role("dialog")
        dialog.get_by_label("参与身份").select_option("PRIMARY")
        dialog.get_by_label("投入分钟").fill("30")
        dialog.get_by_role("button", name="保存").click()
        expect(dialog.get_by_role("alert")).to_contain_text(f"#{entry}（20 分钟）")
        dialog.get_by_role("link", name="查看实际参与记录").click()
        expect(dialog).to_be_hidden()
        expect(new_owner.locator("#contributions")).to_be_in_viewport()
        expect(new_owner.get_by_role("button", name="作废工时")).to_have_count(0)
        owner = browser_session(browser, live_app, "demo-minister")
        owner.goto(url)
        browser_operation(owner, "作废工时", {"reason": "撰稿员误登排版工时"}, confirm=True)
        expect(owner.get_by_text("撰稿员误登排版工时", exact=True)).to_be_visible()
        manager.write("task-history", "void-contribution", 409, id=design, entry=entry, reason="重复操作")
        assert writer.read("statistics", group="person")["rows"][0]["cells"] == before
        assert "LAYOUT" not in {r["type"] for r in writer.client.get("/api/dashboard").json["workload"]}
        sql.execute("SELECT status FROM work_item WHERE id=%s", (design,))
        assert sql.fetchone()["status"] == "IN_PROGRESS"
        sql.execute("SELECT recorded_by,voided_by,minutes_spent FROM voided_work_contribution WHERE id=%s", (entry,))
        assert sql.fetchone() == {"recorded_by": 5, "voided_by": 1, "minutes_spent": 20}
        sql.execute("SELECT actor_id,detail->>'$.reason' AS reason FROM audit_log "
                    "WHERE action_code='WORK_CONTRIBUTION_VOID' AND entity_id=%s", (entry,))
        assert sql.fetchall() == [{"actor_id": 1, "reason": "撰稿员误登排版工时"}]
        browser_operation(new_owner, "登记实际参与", {"participation": "PRIMARY", "minutes": 30})
        new_owner.goto(f"{live_app}/manage/versions?id={article}")
        version = browser_operation(new_owner, "提交新版本", {"assets": [word, photo, xiumi]})["id"]
        owner.goto(live_app)
        expect(owner.get_by_role("link", name="审阅 · 读书节推文", exact=False)).to_be_visible()
        owner.screenshot(path=Path(os.environ["BOYA_QA_ARTIFACTS"]) / "workflow-inbox.png", animations="disabled")
        owner.get_by_role("link", name="审阅 · 读书节推文", exact=False).click()
        expect(owner).to_have_url(f"{live_app}/manage/review-history?id={version}")
        browser_operation(owner, "通过", {"feedback": "版式已核对"})
        browser.close()


def test_concurrent_correction_and_manager_scope(app, sql):
    manager = Operator(app, "demo-minister")
    cam = campaign(manager, "QA-CORRECTION")
    pro = project(manager, cam, "PHOTO", "PHOTO", "WORK_ONLY")
    key = task(manager, pro, "PHOTO", "PHOTO")
    work_record(manager, key, 7)
    entry = int(manager.read("task-history", id=key)["related"][1]["rows"][0]["cells"][0])
    sql.execute("UPDATE project SET created_by=2 WHERE id=%s", (pro,))
    sql.execute("UPDATE campaign SET created_by=2 WHERE id=%s", (cam,))
    try:
        with pytest.raises(pymysql.MySQLError, match="Correction requires project manager"):
            sql.execute("CALL sp_void_contribution(1,%s,%s,'scope')", (key, entry))
    finally:
        sql.execute("UPDATE project SET created_by=1 WHERE id=%s", (pro,))
        sql.execute("UPDATE campaign SET created_by=1 WHERE id=%s", (cam,))
    reason = "历史登记复核"
    ready = Barrier(2)

    def correct():
        operator = Operator(app, "demo-minister")
        ready.wait(timeout=10)
        return operator.client.post("/api/manage/task-history/void-contribution",
                                    json={"id": key, "entry": entry, "reason": reason}, headers=operator.headers).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        requests = [pool.submit(correct) for _ in range(2)]
        assert sorted(request.result(timeout=20) for request in requests) == [200, 409]
    history = manager.read("task-history", id=key)["related"]
    assert not history[1]["rows"] and history[2]["rows"][0]["cells"][-1] == reason


def test_workflow_migration_archive_constraints_and_publisher_view(app, sql):
    sql.execute("""SELECT column_name AS col,referenced_table_name AS target FROM information_schema.key_column_usage
                   WHERE table_schema=DATABASE() AND table_name='voided_work_contribution'""")
    assert {r["col"]: r["target"] for r in sql.fetchall()} == {
        "id": None, "work_item_id": "work_item", "membership_id": "membership_period",
        "recorded_by": "person", "voided_by": "person"}
    sql.execute("SHOW INDEX FROM voided_work_contribution")
    assert {(r["Column_name"], r["Non_unique"]) for r in sql.fetchall()} == {
        ("id", 0), ("work_item_id", 1), ("membership_id", 1), ("recorded_by", 1), ("voided_by", 1)}
    sql.execute("SELECT id,work_item_id,membership_id,recorded_by FROM work_contribution ORDER BY id LIMIT 1")
    source = sql.fetchone()
    record = {**source, "minutes": 20, "voided_by": 1, "reason": "约束验收"}
    insert = """INSERT INTO voided_work_contribution
                (id,work_item_id,membership_id,recorded_by,participation,worked_at,minutes_spent,voided_by,reason)
                VALUES (%(id)s,%(work_item_id)s,%(membership_id)s,%(recorded_by)s,
                        'PRIMARY',NOW(),%(minutes)s,%(voided_by)s,%(reason)s)"""
    sql.execute("START TRANSACTION")
    try:
        for field in ("work_item_id", "membership_id", "recorded_by", "voided_by", "minutes", "reason"):
            with pytest.raises(pymysql.MySQLError) as error:
                sql.execute(insert, {**record, field: " " if field == "reason" else 0})
            # MySQL can suppress FK details for a test account without REFERENCES.
            assert error.value.args[0] in ((3819,) if field in ("minutes", "reason") else (1216, 1452))
        sql.execute(insert, record)
        with pytest.raises(pymysql.IntegrityError) as duplicate:
            sql.execute(insert, record)
        assert duplicate.value.args[0] == 1062
        view = """SELECT person_id FROM v_project_publishers WHERE project_id=(
                    SELECT p.id FROM project p JOIN campaign c ON c.id=p.campaign_id
                    WHERE c.code='SPORTS-2026' AND p.code='ARTICLE')"""
        sql.execute(view)
        assert sql.fetchall() == [{"person_id": 2}]
        sql.execute("""UPDATE membership_position SET ends_at=NOW(6)
                       WHERE membership_id=2 AND position_code='CHIEF' AND ends_at IS NULL""")
        sql.execute(view)
        assert not sql.fetchall()
    finally:
        sql.execute("ROLLBACK")
    with app.app_context(), get_db().cursor() as web:
        for statement in ("DELETE FROM voided_work_contribution WHERE 1=0",
                          "UPDATE voided_work_contribution SET reason='x' WHERE 1=0"):
            with pytest.raises(pymysql.MySQLError) as denied:
                web.execute(statement)
            assert denied.value.args[0] == 1142


def test_edge_video_flow_assignment_upload_rework_third_review_and_publish(app, live_app, sql):
    organizer = Operator(app, "demo-minister")
    campaign_id = campaign(organizer, "QA-EDGE", third="1")
    project_id = project(organizer, campaign_id, "SOLO", "VIDEO")
    route(organizer, project_id, ["CHIEF", "SECOND", "THIRD"])
    work = task(organizer, project_id, "EDIT-SOLO", "VIDEO_EDIT", "MINISTER")
    artifacts = Path(os.environ["BOYA_QA_ARTIFACTS"])
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="msedge")
        minister = browser_session(browser, live_app, "demo-minister")
        minister.goto(f"{live_app}/manage/task-history?id={work}")
        expect(minister.get_by_text("EDIT-SOLO 演示任务", exact=True)).to_be_visible()
        browser_operation(minister, "分配人员", {"membership": 1})
        browser_operation(minister, "登记实际参与", {"membership": 1, "participation": "PRIMARY", "minutes": 53})
        browser_operation(minister, "修改状态", {"status": "DONE"})
        minister.goto(f"{live_app}/manage/assets?project={project_id}")
        video = browser_video(minister)
        asset = browser_operation(minister, "上传文件", {
            "project": project_id, "kind": "VIDEO_FINAL", "title": "验收视频成片",
            "file": {"name": "course.webm", "mimeType": "video/webm", "buffer": video},
        })["id"]
        response = minister.request.get(f"{live_app}/manage/file/{asset}/preview", headers={"Range": "bytes=0-31"})
        assert response.status == 206 and response.body() == video[:32]
        minister.goto(f"{live_app}/manage/versions?id={project_id}")
        initial = browser_operation(minister, "提交新版本", {"assets": [asset], "note": "部长独剪首版"})["id"]
        sql.execute("SELECT start_stage FROM submission WHERE id=%s", (initial,))
        assert sql.fetchone()["start_stage"] == "CHIEF"
        minister.goto(f"{live_app}/manage/review-history?id={initial}")
        expect(minister.get_by_text("交接至主编审核", exact=True)).to_be_visible()
        expect(minister.get_by_role("button", name="通过", exact=True)).to_have_count(0)
        organizer.write("review-history", "review", 404, id=initial, decision="APPROVED", feedback="越权自审")
        chief = browser_session(browser, live_app, "demo-chief")
        chief.get_by_role("link", name="审阅 · SOLO", exact=False).click()
        browser_operation(chief, "退回", {"feedback": "补充片尾署名"}, confirm=True)
        minister.goto(f"{live_app}/manage/versions?id={project_id}")
        revised = browser_operation(minister, "提交新版本", {"assets": [asset], "note": "补充署名后重新提交"})["id"]
        chief.goto(f"{live_app}/manage/review-history?id={revised}")
        browser_operation(chief, "通过", {"feedback": "主编通过"})
        teacher = browser_session(browser, live_app, "demo-second")
        teacher.goto(f"{live_app}/manage/review-history?id={revised}")
        browser_operation(teacher, "通过", {"feedback": "二审通过，交三审"})
        third = browser_session(browser, live_app, "demo-third")
        third.goto(f"{live_app}/manage/review-history?id={revised}")
        expect(third.get_by_text("交接至三审", exact=True)).to_be_visible()
        expect(third.get_by_role("link", name="验收视频成片", exact=True)).to_be_visible()
        third.screenshot(path=artifacts / "review-third.png", animations="disabled")
        browser_operation(third, "通过", {"feedback": "三审通过"})
        minister.goto(f"{live_app}/manage/review-history?id={revised}")
        browser_operation(minister, "正式发布", {"channel": "视频号", "url": "https://example.invalid/edge/final"}, confirm=True)
        expect(minister.get_by_role("link", name="视频号", exact=True)).to_be_visible()
        minister.screenshot(path=artifacts / "released-video.png", animations="disabled")
        dashboard = minister.request.get(live_app + "/api/dashboard").json()
        assert dashboard["published_count"] >= 4
        browser.close()


def test_edge_roster_form_search_and_navigation(live_app):
    artifacts = Path(os.environ["BOYA_QA_ARTIFACTS"])
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="msedge")
        page = browser_session(browser, live_app, "demo-web-admin")
        page.get_by_role("navigation").get_by_text("人员管理", exact=True).click()
        browser_operation(page, "新增人员", {"code": "QA-EDGE-ROSTER", "name": "浏览器新增成员", "contact": ""})
        page.get_by_role("searchbox").fill("浏览器新增成员")
        page.get_by_role("button", name="查询").click()
        expect(page.get_by_role("cell", name="浏览器新增成员", exact=True)).to_be_visible()
        added = page.get_by_role("row").filter(has_text="浏览器新增成员")
        added.get_by_role("button", name="登记加入").click()
        expect(page.get_by_role("dialog", name="登记加入").get_by_role("combobox", name="届次", exact=True)).to_be_visible()
        page.get_by_role("button", name="取消", exact=True).click()
        page.get_by_role("searchbox").fill("")
        page.get_by_role("button", name="查询").click()
        expect(page.get_by_role("cell", name="浏览器新增成员", exact=True)).to_be_visible()
        expect(page.get_by_role("cell", name="示例主编", exact=True)).to_be_visible()
        page.screenshot(path=artifacts / "members-management.png", animations="disabled")
        page.get_by_role("navigation").get_by_text("系统管理", exact=True).click()
        expect(page.get_by_role("link", name="角色权限", exact=True)).to_be_visible()
        page.get_by_role("link", name="备份与恢复", exact=True).click()
        expect(page.get_by_role("heading", name="完整备份", exact=True)).to_be_visible()
        browser.close()
