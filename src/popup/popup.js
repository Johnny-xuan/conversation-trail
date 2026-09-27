const toggle = document.querySelector("#audio-toggle");
const status = document.querySelector("#status");
const pageState = document.querySelector("#page-state");
const pageStateLabel = document.querySelector("#page-state-label");
const version = document.querySelector("#version");
const retry = document.querySelector("#retry-connection");
let currentTab = null;
let refreshTimer = 0;
let isUpdating = false;
let refreshVersion = 0;
let lastControlState = null;

function setStatus(message, tone = "neutral") {
  status.textContent = message;
  status.dataset.tone = tone;
}

function renderState(state = {}) {
  lastControlState = state;
  const enabled = Boolean(state.enabled);
  const isChatGPT = Boolean(currentTab?.url?.startsWith("https://chatgpt.com/"));
  toggle.checked = enabled;
  toggle.disabled = isUpdating;
  retry.disabled = isUpdating;
  retry.hidden = !enabled || !["error", "permission-required"].includes(state.state);
  retry.textContent = state.state === "permission-required" ? "继续授权" : "重新连接";
  pageState.dataset.active = String(isChatGPT);
  pageStateLabel.textContent = isChatGPT ? "当前页面为 ChatGPT" : "打开 ChatGPT 后显示轨迹";

  if (state.error) {
    setStatus(state.error, "error");
  } else if (!enabled) {
    setStatus("已关闭并记住设置。轨迹导航仍会正常工作。");
  } else if (state.state === "active") {
    setStatus("声浪已开启。刷新页面或重启 Chrome 后会自动恢复。", "active");
  } else if (state.state === "permission-required") {
    setStatus(state.message || "请在 Local Audio Engine 中允许系统音频访问，授权后会自动继续。", "waiting");
  } else if (state.state === "starting") {
    setStatus(state.message || "正在启动并连接 Local Audio Engine…", "waiting");
  } else {
    setStatus("已记住开启。打开 ChatGPT 页面后会自动连接。");
  }
}

async function getControlState() {
  const requestVersion = ++refreshVersion;
  const [[tab], state] = await Promise.all([
    chrome.tabs.query({ active: true, currentWindow: true }),
    chrome.runtime.sendMessage({
      target: "conversation-trail-background",
      type: "audio-visualizer:get-control-state"
    })
  ]);
  if (requestVersion !== refreshVersion || isUpdating) return;
  currentTab = tab || null;
  renderState(state);
}

function scheduleRefresh() {
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(async () => {
    if (!isUpdating) {
      await getControlState().catch(() => {});
    }
    scheduleRefresh();
  }, 500);
}

async function updateControl(message, progress) {
  refreshVersion += 1;
  isUpdating = true;
  toggle.disabled = true;
  retry.disabled = true;
  setStatus(progress, "waiting");
  try {
    renderState(await chrome.runtime.sendMessage({
      target: "conversation-trail-background",
      ...message
    }));
  } catch (error) {
    // A lost response must not turn a saved ON preference into an apparent OFF.
    try {
      renderState(await chrome.runtime.sendMessage({
        target: "conversation-trail-background",
        type: "audio-visualizer:get-control-state"
      }));
    } catch {
      if (lastControlState) renderState(lastControlState);
    }
    setStatus(error?.message || "无法确认开关状态，请重新打开扩展菜单。", "error");
  } finally {
    isUpdating = false;
    toggle.disabled = !lastControlState;
    retry.disabled = !lastControlState;
  }
}

toggle.addEventListener("change", () => {
  updateControl(
    { type: "audio-visualizer:set-enabled", enabled: toggle.checked },
    toggle.checked ? "正在保存设置并连接 Local Audio Engine…" : "正在关闭声浪并保存设置…"
  );
});

retry.addEventListener("click", () => {
  updateControl({ type: "audio-visualizer:retry" }, "正在重新连接 Local Audio Engine…");
});

if (
  globalThis.chrome?.tabs?.query
  && globalThis.chrome?.runtime?.sendMessage
) {
  version.textContent = `v${chrome.runtime.getManifest().version}`;
  getControlState().catch((error) => {
    toggle.disabled = true;
    setStatus(error?.message || "无法读取扩展状态。", "error");
  });
  scheduleRefresh();
} else {
  toggle.disabled = true;
  setStatus("请在 Chrome 扩展菜单中使用此开关。", "neutral");
}

window.addEventListener("unload", () => clearTimeout(refreshTimer));
