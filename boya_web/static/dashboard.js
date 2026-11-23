const dashboard = document.querySelector(".dashboard");
const metrics = dashboard.querySelector(".dashboard-metrics");
const notice = document.querySelector("#dashboard-message");
const updated = document.querySelector("#dashboard-updated");
const refresh = document.querySelector("#dashboard-refresh");
const cohort = document.querySelector("#cohort-filter");
const workloadPanel = document.querySelector("#workload-panel");
const workloadPlot = document.querySelector(".workload-plot");
const workloadDetails = document.querySelector(".workload-data");
const campaignPanel = document.querySelector("#campaign-panel");
const cameraPanel = document.querySelector("#camera-panel");
const numeric = new Intl.NumberFormat("zh-CN");
let currentChart;
let activeRequest;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function renderMetrics(data) {
  let visible = 0;
  for (const card of metrics.querySelectorAll("[data-metric]")) {
    const value = data[card.dataset.metric];
    card.hidden = value === null;
    if (!card.hidden) {
      card.querySelector("[data-value]").textContent = numeric.format(value);
      let href;
      if (card.dataset.metric === "pending_review_count") {
        href = data.single_review_href || "/reviews";
      } else if (card.dataset.metric === "pending_task_count") {
        href = value === 1 ? data.task_actions[0].href : "/manage/tasks?state=OPEN";
      } else if (card.dataset.metric === "active_campaign_count" && data.active_campaigns.length) {
        href = data.active_campaigns.length === 1 ? `/manage/projects?id=${data.active_campaigns[0].id}` : "#campaign-panel";
      }
      const heading = card.querySelector("h2");
      const title = heading.textContent;
      if (href) {
        const anchor = element("a", "metric-link", title);
        anchor.href = href;
        heading.replaceChildren(anchor);
      } else {
        heading.textContent = title;
      }
      visible += 1;
    }
  }
  metrics.hidden = visible === 0;
  const choices = data.cohorts || [];
  document.querySelector("#cohort-control").hidden = choices.length === 0;
  cohort.replaceChildren(...choices.map((item) => new Option(item.label, item.id)));
  if (choices.length && data.cohort_id === null) cohort.prepend(new Option("请选择", "", true, true));
  cohort.value = data.cohort_id || "";
  return visible;
}

function renderInbox(data) {
  function group(id, rows, visible, empty) {
    const group = document.getElementById(id);
    group.hidden = !visible;
    if (!visible) return;
    group.querySelector("ul").replaceChildren(...rows.map((item) => {
      const line = element("li", "inbox-entry");
      const text = element("div");
      text.append(element("strong", "", item.title), element("small", "", item.detail));
      const action = element("a", "btn btn-sm btn-outline-secondary", item.label);
      action.href = item.href;
      action.setAttribute("aria-label", `${item.label} · ${item.title} · ${item.detail}`);
      line.append(text, action);
      return line;
    }));
    if (!rows.length) group.querySelector("ul").append(element("li", "dashboard-message", empty));
  }
  const reviews = data.pending_review_count !== null || data.review_actions.length > 0;
  const tasks = data.pending_task_count !== null;
  group("review-inbox", data.review_actions, reviews, "暂无待审核或交接的作品。");
  group("task-inbox", data.task_actions || [], tasks, "暂无待处理任务。");
  document.getElementById("dashboard-inbox").hidden = !reviews && !tasks;
}

function renderWorkload(data) {
  workloadPanel.hidden = data.workload === null;
  if (currentChart) {
    currentChart.destroy();
    currentChart = undefined;
  }
  if (workloadPanel.hidden) return;

  const rows = data.workload;
  document.querySelector("#workload-scope").textContent = data.workload_scope === "managed" ? "管理项目 · 累计分钟" : "本人贡献 · 累计分钟";
  document.querySelector("#workload-empty").hidden = rows.length > 0;
  workloadDetails.hidden = rows.length === 0;
  workloadPlot.hidden = rows.length === 0 || typeof Chart === "undefined";
  workloadDetails.querySelector("tbody").replaceChildren(...rows.map((entry) => {
    const row = element("tr");
    for (const value of [entry.label, numeric.format(entry.entries), numeric.format(entry.minutes)]) {
      row.append(element("td", "", value));
    }
    return row;
  }));
  if (workloadPlot.hidden) {
    if (rows.length) workloadDetails.open = true;
    return;
  }
  workloadPlot.style.height = `${Math.max(152, 42 * rows.length + 38)}px`;
  currentChart = new Chart(document.querySelector("#workload-chart"), {
    type: "bar",
    data: {
      labels: rows.map((row) => row.label),
      datasets: [{
        data: rows.map((row) => row.minutes), label: "分钟", backgroundColor: "#307787",
        hoverBackgroundColor: "#205c76", borderRadius: 5, maxBarThickness: 24,
      }],
    },
    options: {
      indexAxis: "y", responsive: true, maintainAspectRatio: false, animation: false,
      plugins: { legend: { display: false } },
      scales: {
        y: { grid: { display: false }, ticks: { color: "#324d59" } },
        x: { beginAtZero: true, ticks: { precision: 0, color: "#566575" }, grid: { color: "#e8eeee" } },
      },
    },
  });
}

function renderCampaigns(campaigns) {
  campaignPanel.hidden = campaigns === null;
  if (campaignPanel.hidden) return;
  document.querySelector("#campaign-empty").hidden = campaigns.length > 0;
  document.querySelector("#campaign-list").replaceChildren(...campaigns.map((item) => {
    const node = element("li", "campaign-item");
    const header = element("div", "campaign-item-heading");
    const detail = item.required ? `${item.completed}/${item.required}` : `${item.projects} 个项目`;
    const projectLink = element("a", "", item.title);
    projectLink.href = `/manage/projects?id=${item.id}`;
    header.append(projectLink, element("span", "", detail));
    node.append(header);
    if (item.required) {
      const progress = element("progress", "campaign-progress");
      progress.max = item.required;
      progress.value = item.completed;
      progress.setAttribute("aria-label", `${item.title}已完成 ${detail} 个必需项目`);
      node.append(progress);
    } else {
      node.append(element("p", "dashboard-caption", "无必需项目"));
    }
    return node;
  }));
}

function renderCameras(cameras) {
  cameraPanel.hidden = cameras === null;
  if (cameraPanel.hidden) return;
  document.querySelector("#camera-empty").hidden = cameras.length > 0;
  document.querySelector("#camera-total").textContent = `共 ${numeric.format(cameras.reduce((sum, entry) => sum + entry.total, 0))} 台`;
  document.querySelector("#camera-list").replaceChildren(...cameras.map((entry) => {
    const item = element("li", "camera-status");
    item.dataset.status = entry.status;
    item.append(element("span", "camera-dot"), element("span", "", entry.label),
                element("strong", "", numeric.format(entry.total)));
    return item;
  }));
}

async function loadDashboard() {
  activeRequest?.abort();
  const controller = new AbortController();
  activeRequest = controller;
  const url = new URL(dashboard.dataset.endpoint, location.origin);
  if (cohort.value) url.searchParams.set("cohort_id", cohort.value);
  notice.textContent = "正在读取工作台数据…";
  refresh.disabled = true;
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (response.status === 401) {
      location.assign(dashboard.dataset.login);
      return;
    }
    if (response.status === 403 && url.searchParams.has("cohort_id")) {
      cohort.value = "";
      return loadDashboard();
    }
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "读取失败，请稍后重试。");
    const visible = renderMetrics(data);
    renderInbox(data);
    renderWorkload(data);
    renderCampaigns(data.active_campaigns);
    renderCameras(data.cameras);
    updated.hidden = false;
    updated.textContent = `更新于 ${data.updated_at}（北京时间）`;
    notice.textContent = visible || data.cameras !== null ? "" : "当前账号暂无可查看的工作台指标。";
  } catch (error) {
    if (error.name !== "AbortError") notice.textContent = error.message || "读取失败，请稍后重试。";
  } finally {
    if (activeRequest === controller) refresh.disabled = false;
  }
}

refresh.addEventListener("click", loadDashboard);
cohort.addEventListener("change", loadDashboard);
loadDashboard();
