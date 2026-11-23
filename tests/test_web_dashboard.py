import os
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

from .test_web_auth import PASSWORD, app, login, pytestmark, sql


def dashboard(client, query=""):
    response = client.get("/api/dashboard" + query)
    assert response.status_code == 200
    return response.json


def test_dashboard_requires_login(app):
    assert app.test_client().get("/api/dashboard").status_code == 401


def test_dashboard_counts_match_database(app, sql):
    client = app.test_client()
    assert login(client, "demo-minister").status_code == 302
    data = dashboard(client)
    sql.execute("SELECT COUNT(*) AS total FROM v_current_members")
    assert data["member_count"] == sql.fetchone()["total"] == 8
    assert data["cohort_id"] == "2" and data["cohort_member_count"] == 6
    assert data["active_campaign_count"] == 2
    assert data["pending_task_count"] == 1
    assert data["pending_review_count"] == 0
    assert data["published_count"] == 2
    assert data["workload_scope"] == "managed"
    sql.execute(
        """SELECT w.kind, COUNT(*) AS entries, SUM(c.minutes_spent) AS minutes
           FROM work_contribution c
           JOIN work_item w ON w.id = c.work_item_id
           JOIN project p ON p.id = w.project_id
           JOIN campaign g ON g.id = p.campaign_id
           WHERE p.created_by = 1 OR g.created_by = 1 GROUP BY w.kind"""
    )
    assert {r["type"]: (r["entries"], r["minutes"]) for r in data["workload"]} == {
        r["kind"]: (r["entries"], r["minutes"]) for r in sql.fetchall()
    }
    sql.execute("SELECT current_status, COUNT(*) AS total FROM v_equipment_status GROUP BY current_status")
    assert {r["status"]: r["total"] for r in data["cameras"]} == {
        r["current_status"]: r["total"] for r in sql.fetchall()
    }
    assert any(c["required"] == 3 and c["completed"] == 2 for c in data["active_campaigns"])


def test_cohort_selector_validates_and_defaults_to_latest_started_year(app, sql):
    client = app.test_client()
    login(client, "demo-web-admin")
    data = dashboard(client, "?cohort_id=1")
    assert data["member_count"] == 8 and data["cohort_member_count"] == 2
    assert data["active_campaign_count"] is None and data["workload"] is None and data["cameras"] is None
    assert client.get("/api/dashboard?cohort_id=999").status_code == 400
    assert client.get("/api/dashboard?cohort_id=18446744073709551616").status_code == 400
    sql.execute("INSERT INTO cohort(code,label,intake_year) VALUES ('QA-FUTURE','未来届次',YEAR(CURDATE())+2)")
    future_id = sql.lastrowid
    try:
        assert dashboard(client)["cohort_id"] == "2"
        assert dashboard(client, f"?cohort_id={future_id}")["cohort_member_count"] == 0
    finally:
        sql.execute("DELETE FROM cohort WHERE id=%s", (future_id,))


def test_member_and_reviewer_only_get_authorized_metrics(app):
    member = app.test_client()
    login(member, "demo-writer")
    data = dashboard(member, "?person_id=1")
    assert data["member_count"] is None and data["cohorts"] is None and data["cameras"] is None
    assert data["pending_review_count"] is None
    assert data["active_campaign_count"] == 0 and data["pending_task_count"] == 0 and data["published_count"] == 1
    assert data["workload_scope"] == "personal"
    assert data["workload"] == [{"type": "WRITING", "label": "新闻稿撰写", "minutes": 75, "entries": 1}]
    assert member.get("/api/dashboard?cohort_id=2").status_code == 403
    for username, pending in (("demo-second", 0), ("demo-third", 1)):
        reviewer = app.test_client()
        login(reviewer, username)
        data = dashboard(reviewer, "?reviewer_id=4")
        assert data["pending_review_count"] == pending
        for key in ("member_count", "active_campaign_count", "pending_task_count",
                    "published_count", "workload", "cameras"):
            assert data[key] is None


def test_manager_refresh_excludes_project_outside_ownership(app, sql):
    client = app.test_client()
    login(client, "demo-minister")
    initial = dashboard(client)
    sql.execute(
        """SELECT c.id AS campaign_id, p.id AS project_id
           FROM campaign c JOIN project p ON p.campaign_id = c.id
           WHERE c.code='SPORTS-2026' AND p.code='VIDEO'"""
    )
    row = sql.fetchone()
    sql.execute("UPDATE campaign SET created_by=2 WHERE id=%s", (row["campaign_id"],))
    sql.execute("UPDATE project SET created_by=2 WHERE id=%s", (row["project_id"],))
    try:
        changed = dashboard(client)
        assert changed["active_campaign_count"] == initial["active_campaign_count"] - 1
        assert changed["pending_task_count"] == initial["pending_task_count"] - 1
        assert sum(w["minutes"] for w in changed["workload"]) < sum(w["minutes"] for w in initial["workload"])
        assert changed["published_count"] == initial["published_count"]
    finally:
        sql.execute("UPDATE project SET created_by=1 WHERE id=%s", (row["project_id"],))
        sql.execute("UPDATE campaign SET created_by=1 WHERE id=%s", (row["campaign_id"],))


def test_dashboard_reads_live_camera_status(app, sql):
    client = app.test_client()
    login(client, "demo-minister")
    before = {r["status"]: r["total"] for r in dashboard(client)["cameras"]}
    sql.execute("UPDATE equipment SET inventory_status='MAINTENANCE' WHERE code='CAM-DEMO-01'")
    try:
        after = {r["status"]: r["total"] for r in dashboard(client)["cameras"]}
        assert after.get("AVAILABLE", 0) == before["AVAILABLE"] - 1
        assert after["MAINTENANCE"] == before.get("MAINTENANCE", 0) + 1
    finally:
        sql.execute("UPDATE equipment SET inventory_status='AVAILABLE' WHERE code='CAM-DEMO-01'")


def test_edge_dashboard_renders_charts_filters_and_role_scope(live_app):
    artifacts = Path(os.environ["BOYA_QA_ARTIFACTS"])
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="msedge")
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        page.goto(live_app + "/login")
        page.get_by_label("账号", exact=True).fill("demo-minister")
        page.get_by_label("密码", exact=True).fill(PASSWORD)
        page.get_by_role("button", name="登录", exact=True).click()
        count = page.locator('[data-metric="member_count"] [data-value]')
        expect(count).to_have_text("8")
        current_cohort = page.locator('[data-metric="cohort_member_count"] [data-value]')
        expect(current_cohort).to_have_text("6")
        expect(page.get_by_role("img", name="各工作类型累计投入分钟")).to_be_visible()
        page.wait_for_function("Chart.getChart('workload-chart').data.datasets[0].data.length > 1")
        api = page.request.get(live_app + "/api/dashboard").json()
        assert page.evaluate("Chart.getChart('workload-chart').data.datasets[0].data") == [
            row["minutes"] for row in api["workload"]
        ]
        expect(page.get_by_role("heading", name="相机状态")).to_be_visible()
        expect(page.get_by_text("2026 年学院运动会宣传", exact=True)).to_be_visible()
        page.screenshot(path=artifacts / "dashboard-manager.png", animations="disabled")
        page.get_by_label("统计届次").select_option("1")
        expect(current_cohort).to_have_text("2")
        page.get_by_role("button", name="刷新数据").click()
        expect(current_cohort).to_have_text("2")
        page.get_by_text("查看数据", exact=True).click()
        expect(page.get_by_role("cell", name="视频剪辑", exact=True)).to_be_visible()
        page.locator('[data-metric="pending_task_count"]').get_by_role("link").click()
        expect(page.get_by_role("heading", name="任务详情与历史")).to_be_visible()
        expect(page.get_by_role("button", name="登记实际参与")).to_be_visible()
        page.get_by_role("button", name="退出登录").click()
        page.get_by_label("账号", exact=True).fill("demo-third")
        page.get_by_label("密码", exact=True).fill(PASSWORD)
        page.get_by_role("button", name="登录", exact=True).click()
        expect(page.locator('[data-metric="pending_review_count"] [data-value]')).to_have_text("1")
        expect(page.locator('[data-metric="member_count"]')).to_be_hidden()
        expect(page.locator("#camera-panel")).to_be_hidden()
        page.locator('[data-metric="pending_review_count"]').get_by_role("link").click()
        expect(page.get_by_role("button", name="通过", exact=True)).to_be_visible()
        expect(page.get_by_role("button", name="退回", exact=True)).to_be_visible()
        browser.close()
