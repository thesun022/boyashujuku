import os
import re
import secrets
from pathlib import Path

import pymysql
import pytest
from playwright.sync_api import expect, sync_playwright

from boya_web import create_app
from boya_web.auth import token_digest
from boya_web.bootstrap import provision_account
from boya_web.db import connect


PASSWORD = os.environ.get("BOYA_QA_WEB_PASSWORD")
pytestmark = pytest.mark.skipif(
    not PASSWORD or os.environ.get("BOYA_DB_USER") != "boya_web_lab"
    or os.environ.get("BOYA_QA_DB_USER") != "boya_web_lab_owner",
    reason="需要由 tests.web_lab 创建独立 MySQL 实例",
)


@pytest.fixture(scope="module")
def app():
    return create_app({"TESTING": True})


@pytest.fixture
def sql():
    with connect("127.0.0.1", int(os.environ["BOYA_DB_PORT"]),
                 os.environ["BOYA_QA_DB_USER"], os.environ["BOYA_QA_DB_PASSWORD"],
                 "boya_media_center") as connection:
        with connection.cursor() as cursor:
            yield cursor


def csrf(response):
    return re.search(r'name="csrf_token" value="([^"]+)"', response.get_data(as_text=True))[1]


def login(client, username, password=None):
    return client.post("/login", data={
        "username": username, "password": PASSWORD if password is None else password,
        "csrf_token": csrf(client.get("/login")),
    })


def test_guest_and_csrf(app):
    client = app.test_client()
    assert client.get("/").location == "/login"
    assert client.get("/api/me").status_code == 401
    assert client.get("/api/tasks").status_code == 401
    assert client.post("/login", data={"username": "demo-writer", "password": PASSWORD}).status_code == 400
    assert client.post("/logout").status_code == 400
    assert client.get("/logout").status_code == 405


@pytest.mark.parametrize(("username", "title", "can_task", "can_review"), [
    ("demo-writer", "部员", True, False),
    ("demo-minister", "部长", True, True),
    ("demo-chief", "主编", True, True),
    ("demo-second", "二审人", False, True),
    ("demo-third", "三审人", False, True),
    ("demo-web-admin", "管理员", False, False),
])
def test_real_login_role_and_api_authority(app, username, title, can_task, can_review):
    client = app.test_client()
    response = login(client, username)
    assert response.status_code == 302 and response.location == "/"
    assert "HttpOnly" in response.headers["Set-Cookie"]
    assert "SameSite=Lax" in response.headers["Set-Cookie"]
    identity = client.get("/api/me").json
    assert identity["username"] == username
    assert title in identity["titles"]
    assert "password_hash" not in identity
    html = client.get("/").get_data(as_text=True)
    assert ('href="/tasks"' in html) == can_task
    assert ('href="/reviews"' in html) == can_review
    assert client.get("/api/tasks").status_code == (200 if can_task else 403)
    assert client.get("/api/reviews").status_code == (200 if can_review else 403)
    assert client.get("/tasks").status_code == (200 if can_task else 403)
    assert client.get("/reviews").status_code == (200 if can_review else 403)


def test_wrong_unknown_and_exited_accounts(app):
    for username, password in (("demo-writer", secrets.token_urlsafe(24)),
                               ("unknown-user", PASSWORD), ("demo-former", PASSWORD)):
        client = app.test_client()
        assert login(client, username, password).status_code == 401
        assert client.get("/api/me").status_code == 401


def test_duplicate_login_creates_independent_session_and_logout_revokes_token(app, sql):
    first, second = app.test_client(), app.test_client()
    assert login(first, "demo-writer").status_code == 302
    assert login(second, "demo-writer").status_code == 302
    old_cookie = first.get_cookie("boya_session").value
    with first.session_transaction() as flask_session:
        digest = token_digest(flask_session["auth_token"])
    sql.execute("SELECT COUNT(*) AS total FROM web_session WHERE token_hash=%s", (digest,))
    assert sql.fetchone()["total"] == 1
    assert first.post("/logout", data={"csrf_token": csrf(first.get("/"))}).location == "/login"
    sql.execute("SELECT COUNT(*) AS total FROM web_session WHERE token_hash=%s", (digest,))
    assert sql.fetchone()["total"] == 0
    first.set_cookie("boya_session", old_cookie)
    assert first.get("/api/me").status_code == 401
    assert second.get("/api/me").status_code == 200


def test_expired_session_requires_login(app, sql):
    client = app.test_client()
    assert login(client, "demo-writer").status_code == 302
    with client.session_transaction() as flask_session:
        digest = token_digest(flask_session["auth_token"])
    sql.execute(
        "UPDATE web_session SET created_at=UTC_TIMESTAMP(6)-INTERVAL 2 HOUR, "
        "expires_at=UTC_TIMESTAMP(6)-INTERVAL 1 HOUR WHERE token_hash=%s", (digest,),
    )
    assert client.get("/api/me").status_code == 401


def test_role_removal_takes_effect_on_next_request(app, sql):
    client = app.test_client()
    assert login(client, "demo-video").status_code == 302
    assert client.get("/api/tasks").status_code == 200
    sql.execute("SELECT id FROM account WHERE username=%s", ("demo-video",))
    account_id = sql.fetchone()["id"]
    sql.execute("DELETE FROM account_role WHERE account_id=%s AND role_code='CONTRIBUTOR'", (account_id,))
    try:
        assert client.get("/api/tasks").status_code == 403
        assert client.get("/api/me").json["permissions"] == []
    finally:
        sql.execute("INSERT INTO account_role(account_id,role_code) VALUES (%s,'CONTRIBUTOR')", (account_id,))
    assert client.get("/api/tasks").status_code == 200


def test_member_task_scope_filter_and_paging(app, sql):
    client = app.test_client()
    login(client, "demo-writer")
    result = client.get("/api/tasks?person_id=9").json
    assert [item["title"] for item in result["items"]] == ["撰写新闻稿"]
    own_work = result["items"][0]["work_id"]
    assert client.get(f"/api/tasks/{own_work}").json["title"] == "撰写新闻稿"
    sql.execute("SELECT id FROM work_item WHERE kind='VIDEO_EDIT' ORDER BY id LIMIT 1")
    another = sql.fetchone()["id"]
    assert client.get(f"/api/tasks/{another}").status_code == 404
    assert client.get("/api/tasks", query_string={"q": "新闻"}).json["items"][0]["work_id"] == own_work
    assert client.get("/api/tasks", query_string={"q": "字符 '%_ 测试"}).json["items"] == []
    assert client.get("/api/tasks?page=2").json["items"] == []
    assert client.get("/api/tasks?page=0").status_code == 400


def test_review_record_requires_assigned_reviewer(app):
    third = app.test_client()
    login(third, "demo-third")
    items = third.get("/api/reviews").json["items"]
    assert len(items) == 1 and items[0]["review_stage"] == "THIRD"
    review_id = items[0]["submission_id"]
    assert third.get(f"/api/reviews/{review_id}").status_code == 200
    for username in ("demo-second", "demo-chief", "demo-minister"):
        other = app.test_client()
        login(other, username)
        assert other.get(f"/api/reviews/{review_id}").status_code == 404
        assert not other.get("/api/reviews?reviewer_id=4").json["items"]


def test_deactivation_and_password_change_revoke_sessions(app, sql):
    with connect("127.0.0.1", int(os.environ["BOYA_DB_PORT"]), os.environ["BOYA_QA_DB_USER"],
                 os.environ["BOYA_QA_DB_PASSWORD"], "boya_media_center") as connection:
        provision_account(connection, person_code="QA-AUTH-LIFECYCLE", username="qa-lifecycle",
                          display_name="虚构生命周期测试", password=PASSWORD, role="CONTRIBUTOR")
        disabled = app.test_client()
        assert login(disabled, "qa-lifecycle").status_code == 302
        cookie = disabled.get_cookie("boya_session").value
        sql.execute("UPDATE account SET enabled=FALSE WHERE username=%s", ("qa-lifecycle",))
        assert disabled.get("/api/me").status_code == 401
        assert login(app.test_client(), "qa-lifecycle").status_code == 401
        sql.execute("UPDATE account SET enabled=TRUE WHERE username=%s", ("qa-lifecycle",))
        disabled.set_cookie("boya_session", cookie)
        assert disabled.get("/api/me").status_code == 401
        reset = app.test_client()
        assert login(reset, "qa-lifecycle").status_code == 302
        new_password = secrets.token_urlsafe(24)
        provision_account(connection, person_code="QA-AUTH-LIFECYCLE", username="qa-lifecycle",
                          password=new_password, reset_password=True)
        assert reset.get("/api/me").status_code == 401
        assert login(app.test_client(), "qa-lifecycle").status_code == 401
        assert login(app.test_client(), "qa-lifecycle", new_password).status_code == 302


def test_database_service_account_has_only_phase_one_access():
    with connect("127.0.0.1", int(os.environ["BOYA_DB_PORT"]), os.environ["BOYA_DB_USER"],
                 os.environ["BOYA_DB_PASSWORD"], "boya_media_center") as connection:
        with connection.cursor() as cursor:
            for statement in ("SELECT password_hash FROM account", "SELECT token_hash FROM web_session",
                              "DELETE FROM audit_log"):
                with pytest.raises(pymysql.MySQLError) as denied:
                    cursor.execute(statement)
                assert denied.value.args[0] in (1142, 1143)


def test_edge_browser_login_workbench_and_logout(live_app):
    artifacts = Path(os.environ["BOYA_QA_ARTIFACTS"])
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="msedge")
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        assert page.goto(live_app + "/login").status == 200
        expect(page.get_by_role("heading", name="账号登录")).to_be_visible()
        page.screenshot(path=artifacts / "login.png", animations="disabled")
        page.get_by_label("账号", exact=True).fill("demo-writer")
        page.get_by_label("密码", exact=True).fill(PASSWORD)
        page.get_by_role("button", name="登录", exact=True).click()
        expect(page.get_by_role("heading", name="工作台", exact=True)).to_be_visible()
        expect(page.get_by_role("navigation").get_by_text("待我审核")).to_have_count(0)
        page.get_by_role("navigation").get_by_text("我的任务").click()
        expect(page.get_by_role("cell", name="撰写新闻稿")).to_be_visible()
        page.screenshot(path=artifacts / "member-tasks.png", animations="disabled")
        page.get_by_role("searchbox").fill("不存在的任务")
        page.get_by_role("button", name="搜索").click()
        expect(page.get_by_role("status")).to_have_text("没有符合条件的记录。")
        page.get_by_role("button", name="退出登录").click()
        expect(page.get_by_role("heading", name="账号登录")).to_be_visible()
        assert page.request.get(live_app + "/api/me").status == 401
        browser.close()
