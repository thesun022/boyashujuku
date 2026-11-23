const section = document.querySelector("#management");
const statusMessage = document.querySelector("#section-status");
const searchForm = document.querySelector("#section-search");
const tableSlot = document.querySelector("#section-results");
const dialog = document.querySelector("#operation-dialog");
const operationForm = document.querySelector("#operation-form");
const operationFields = document.querySelector("#operation-fields");
const submit = document.querySelector("#operation-submit");
const filterSlot = document.querySelector("#section-filters");
const params = new URLSearchParams(location.search);
let operation;
let activeRequest;
let currentFields = [];

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function validHref(value) {
  return typeof value === "string" && (/^\/(?![/\\])/.test(value) || /^https:\/\//i.test(value));
}

function makeControl(field, value, prefix) {
  let input;
  if (field.options) {
    input = node("select", "form-select form-select-sm");
    input.multiple = field.kind === "multi";
    if (!input.multiple && !field.required) input.append(new Option("全部", ""));
    if (!input.multiple && field.required && value == null) {
      const placeholder = new Option("请选择", "", true, true);
      placeholder.disabled = true;
      input.append(placeholder);
    }
    for (const [id, label] of field.options) input.append(new Option(label, id));
    if (input.multiple) {
      const values = new Set((value || []).map(String));
      for (const option of input.options) option.selected = values.has(option.value);
      input.size = Math.min(7, Math.max(3, input.options.length));
    } else if (value != null) {
      input.value = String(value);
    }
  } else if (field.kind === "textarea") {
    input = node("textarea", "form-control form-control-sm");
    input.rows = 3;
    input.value = value ?? "";
  } else {
    input = node("input", "form-control form-control-sm");
    input.type = field.kind;
    if (field.kind === "file") {
      input.accept = ".docx,.jpg,.jpeg,.png,.gif,.webp,.mp4,.mov,.webm";
    } else {
      input.value = value ?? "";
    }
    if (field.kind === "password") input.autocomplete = "new-password";
    if (field.kind === "number") input.step = "1";
  }
  input.name = field.name;
  input.id = prefix + field.name;
  input.required = field.required;
  if (field.placeholder) input.placeholder = field.placeholder;
  if (field.kind === "hidden") return input;
  const wrapper = node("label", "management-field");
  wrapper.htmlFor = input.id;
  wrapper.append(node("span", "", field.label), input);
  return wrapper;
}

function writeCell(target, value) {
  if (typeof value !== "object" || !value) {
    target.textContent = value ?? "—";
  } else if (validHref(value.href)) {
    const anchor = node("a", "", value.text);
    anchor.href = value.href;
    if (value.href.startsWith("https://")) {
      anchor.target = "_blank";
      anchor.rel = "noopener noreferrer";
    }
    target.append(anchor);
  } else if (value.status) {
    const pill = node("span", "status-pill", value.text);
    pill.dataset.status = value.status;
    target.append(pill);
  } else {
    target.textContent = value.text;
  }
}

function openOperation(item) {
  operation = item;
  operationFields.replaceChildren(...item.fields.map((field) => makeControl(field, field.value, "operation-")));
  if (item.id !== null && item.id !== undefined) {
    operationFields.append(makeControl({name: "id", kind: "hidden"}, item.id, "operation-"));
  }
  document.querySelector("#operation-title").textContent = item.label;
  document.querySelector("#operation-error").textContent = "";
  submit.textContent = item.confirm ? "继续" : "保存";
  dialog.showModal();
}

function actionNode(item, style) {
  const prefix = `btn btn-sm ${style}`;
  if (item.href && validHref(item.href)) {
    const anchor = node("a", prefix, item.label);
    anchor.href = item.href;
    return anchor;
  }
  const control = node("button", prefix, item.label);
  control.type = "button";
  control.addEventListener("click", () => openOperation(item));
  return control;
}

function table(columns, rows, sortable = false) {
  if (!rows.length) return node("p", "management-empty", "暂无符合条件的记录。");
  const container = node("div", "table-responsive");
  const grid = node("table", "table align-middle management-table mb-0");
  const header = grid.createTHead().insertRow();
  const hasActions = rows.some((record) => record.actions.length);
  columns.forEach((label, index) => {
    const cell = node("th");
    cell.scope = "col";
    if (sortable) {
      const active = params.get("sort") === String(index);
      const descending = params.get("desc") === "1";
      const sorter = node("button", "sort-column", label + (active ? (descending ? " ↓" : " ↑") : ""));
      sorter.type = "button";
      sorter.setAttribute("aria-label", `按${label}排序`);
      cell.setAttribute("aria-sort", active ? (descending ? "descending" : "ascending") : "none");
      sorter.addEventListener("click", () => {
        params.set("sort", index);
        params.set("desc", active && !descending ? "1" : "0");
        params.set("page", "1");
        load();
      });
      cell.append(sorter);
    } else {
      cell.textContent = label;
    }
    header.append(cell);
  });
  if (hasActions) {
    const title = node("th", "", "操作");
    title.scope = "col";
    header.append(title);
  }
  const body = grid.createTBody();
  for (const record of rows) {
    const line = body.insertRow();
    record.cells.forEach((value) => writeCell(line.insertCell(), value));
    if (hasActions) {
      const controls = node("div", "row-actions");
      controls.append(...record.actions.map((item) => actionNode(item, "btn-outline-secondary")));
      line.insertCell().append(controls);
    }
  }
  container.append(grid);
  return container;
}

function timeline(columns, records) {
  if (!records.length) return node("p", "management-empty", "暂无历史记录。");
  const list = node("ol", "management-timeline");
  for (const record of records) {
    const item = node("li");
    for (const [index, value] of record.cells.entries()) {
      const line = node("div");
      line.append(node("span", "timeline-label", columns[index]));
      const valueNode = node("span", "timeline-value");
      writeCell(valueNode, value);
      line.append(valueNode);
      item.append(line);
    }
    for (const action of record.actions) item.append(actionNode(action, "btn-outline-secondary"));
    list.append(item);
  }
  return list;
}

function showData(model) {
  const description = document.querySelector("#section-description");
  description.hidden = !model.description;
  description.textContent = model.description || "";
  document.querySelector("#section-actions").replaceChildren(...model.actions.map(
    (item) => actionNode(item, item.action ? "btn-primary" : "btn-outline-secondary"),
  ));
  currentFields = model.filters;
  filterSlot.replaceChildren(...currentFields.map((field) => {
    return makeControl(field, params.has(field.name) ? params.get(field.name) : field.value, "filter-");
  }));
  searchForm.elements.q.value = params.get("q") || "";
  tableSlot.replaceChildren(model.timeline ? timeline(model.columns, model.rows) : table(model.columns, model.rows, true));
  const pageTotal = Math.max(1, Math.ceil(model.total / model.page_size));
  const pageBar = document.querySelector("#section-pagination");
  const previous = node("button", "btn btn-outline-secondary btn-sm", "上一页");
  const next = node("button", "btn btn-outline-secondary btn-sm", "下一页");
  previous.disabled = model.page <= 1;
  next.disabled = model.page >= pageTotal;
  for (const [control, offset] of [[previous, -1], [next, 1]]) {
    control.type = "button";
    control.addEventListener("click", () => {
      params.set("page", model.page + offset);
      load();
    });
  }
  pageBar.replaceChildren(previous, node("span", "", `第 ${model.page} / ${pageTotal} 页 · 共 ${model.total} 条`), next);
  const before = document.querySelector("#section-before");
  const after = document.querySelector("#section-related");
  before.hidden = !model.related_first;
  const related = model.related_first ? before : after;
  related.replaceChildren(...(model.related || []).map((records) => {
    const panel = node("section", "panel management-records related-records");
    if (records.anchor) {
      panel.id = records.anchor;
      panel.tabIndex = -1;
    }
    panel.append(node("h2", "", records.title), table(records.columns, records.rows));
    return panel;
  }));
  const notes = document.querySelector("#section-notes");
  notes.hidden = !model.notes?.length;
  notes.replaceChildren(...(model.notes || []).map((note) => {
    const card = node("article", "panel management-note");
    card.append(node("h2", "", note.title), node("p", "", note.text));
    return card;
  }));
  document.querySelector("#section-records").hidden = false;
}

async function checkedResponse(response) {
  if (response.status === 401) {
    location.assign(section.dataset.login);
    throw new Error("请重新登录。");
  }
  const data = await response.json();
  if (!response.ok) {
    const error = new Error(data.error || "操作失败，请重试。");
    error.status = response.status;
    error.resolution = data.resolution;
    throw error;
  }
  return data;
}

async function load(success = "") {
  activeRequest?.abort();
  activeRequest = new AbortController();
  statusMessage.textContent = "正在读取数据…";
  statusMessage.classList.remove("bad", "good");
  const url = `${section.dataset.url}?${params}`;
  try {
    const model = await checkedResponse(await fetch(url, { signal: activeRequest.signal }));
    history.replaceState(null, "", location.pathname + (params.size ? `?${params}` : "") + location.hash);
    showData(model);
    if (location.hash) document.getElementById(location.hash.slice(1))?.focus();
    statusMessage.textContent = success;
    statusMessage.classList.toggle("good", !!success);
  } catch (error) {
    if (error.name === "AbortError") return;
    statusMessage.textContent = error.message;
    statusMessage.classList.add("bad");
    if (error.status === 403 || error.status === 404) {
      document.querySelector("#section-actions").replaceChildren();
      document.querySelector("#section-records").hidden = true;
      document.querySelector("#section-before").replaceChildren();
      document.querySelector("#section-related").replaceChildren();
      document.querySelector("#section-notes").hidden = true;
    }
  }
}

searchForm.addEventListener("submit", (event) => {
  event.preventDefault();
  for (const name of ["q", ...currentFields.map((field) => field.name)]) {
    const value = searchForm.elements.namedItem(name).value.trim();
    if (value) params.set(name, value);
    else params.delete(name);
  }
  params.set("page", "1");
  load();
});

function closeOperation() {
  if (!submit.disabled) dialog.close();
}

document.querySelector("#operation-close").addEventListener("click", closeOperation);
document.querySelector("#operation-cancel").addEventListener("click", closeOperation);
dialog.addEventListener("cancel", (event) => { if (submit.disabled) event.preventDefault(); });
operationForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (operation.confirm && !window.confirm(operation.confirm)) return;
  const headers = {"X-CSRFToken": section.dataset.csrf};
  let payload;
  if (operation.fields.some((field) => field.kind === "file")) {
    payload = new FormData(operationForm);
  } else {
    const record = {};
    for (const input of operationFields.querySelectorAll("input,select,textarea")) {
      record[input.name] = input.multiple ? Array.from(input.selectedOptions, (option) => option.value) : input.value;
    }
    payload = JSON.stringify(record);
    headers["Content-Type"] = "application/json";
  }
  const errorSlot = document.querySelector("#operation-error");
  errorSlot.textContent = "";
  submit.disabled = true;
  const text = submit.textContent;
  submit.textContent = "处理中…";
  try {
    const response = await fetch(`${section.dataset.url}/${operation.action}`, {method: "POST", headers, body: payload});
    const data = await checkedResponse(response);
    dialog.close();
    load(data.message);
  } catch (error) {
    errorSlot.textContent = error.message;
    if (error.resolution && validHref(error.resolution.href)) {
      const link = node("a", "ms-2", error.resolution.label);
      link.href = error.resolution.href;
      link.addEventListener("click", () => {
        dialog.close();
        if (link.pathname === location.pathname && link.search === location.search) {
          document.getElementById(link.hash.slice(1))?.focus();
          load();
        }
      });
      errorSlot.append(link);
    }
  } finally {
    submit.disabled = false;
    submit.textContent = text;
  }
});

load();
