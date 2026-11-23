const panel = document.querySelector(".records");
const form = panel.querySelector("form");
const body = panel.querySelector("tbody");
const message = panel.querySelector(".records-message");
const previous = panel.querySelector('[data-page="previous"]');
const next = panel.querySelector('[data-page="next"]');
const pageNumber = panel.querySelector(".page-number");
const statusLabels = {
  TODO: "待处理", IN_PROGRESS: "进行中", BLOCKED: "受阻",
  DONE: "已完成", CANCELLED: "已取消",
  MINISTER: "部长初审", CHIEF: "主编审核", SECOND: "二审", THIRD: "三审",
};
let page = 1;
let activeRequest;

function textCell(row, value, status, href) {
  const cell = row.insertCell();
  if (status) {
    const label = document.createElement("span");
    label.className = "status-pill";
    label.dataset.status = status;
    label.textContent = statusLabels[status] || status;
    cell.append(label);
  } else if (href) {
    const link = document.createElement("a");
    link.href = href;
    link.textContent = value;
    cell.append(link);
  } else {
    cell.textContent = value;
  }
}

async function loadRecords() {
  activeRequest?.abort();
  activeRequest = new AbortController();
  const params = new URLSearchParams({ page, q: form.elements.q.value });
  body.replaceChildren();
  message.textContent = "正在读取数据…";
  previous.disabled = true;
  next.disabled = true;
  try {
    const response = await fetch(`${panel.dataset.endpoint}?${params}`, { signal: activeRequest.signal });
    if (response.status === 401) {
      location.assign("/login");
      return;
    }
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "读取失败，请稍后重试。");
    for (const item of data.items) {
      const row = body.insertRow();
      if (panel.dataset.category === "tasks") {
        textCell(row, item.title, null, `/manage/task-history?id=${item.work_id}`);
        textCell(row, item.project_title);
        textCell(row, null, item.status);
        textCell(row, item.updated_at.replace("T", " "));
      } else {
        textCell(row, item.project_title, null, `/manage/review-history?id=${item.submission_id}`);
        textCell(row, `第 ${item.version_no} 版`);
        textCell(row, null, item.review_stage);
        textCell(row, item.handed_at.replace("T", " "));
      }
    }
    message.textContent = data.items.length ? "" : "没有符合条件的记录。";
    pageNumber.textContent = `第 ${page} 页`;
    previous.disabled = page === 1;
    next.disabled = !data.has_next;
  } catch (error) {
    if (error.name !== "AbortError") {
      message.textContent = error.message;
      previous.disabled = page === 1;
    }
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  page = 1;
  loadRecords();
});
previous.addEventListener("click", () => { page -= 1; loadRecords(); });
next.addEventListener("click", () => { page += 1; loadRecords(); });
loadRecords();
