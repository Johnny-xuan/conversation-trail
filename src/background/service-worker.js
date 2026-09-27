const NATIVE_HOST_NAME = "com.johnny.conversation_trail_relay";
const STORAGE_KEY = "audioVisualizerEnabled";
const CHATGPT_URL_PATTERN = /^https:\/\/chatgpt\.com\//i;
const CHATGPT_QUERY_PATTERN = "https://chatgpt.com/*";

let enabled = false;
let preferenceRevision = 0;
let nativePort = null;
let captureState = "idle";
let controlError = "";
let controlMessage = "";
let lastChannels = [];
let lastFrameTimestamp = 0;
let chatGPTTabIds = new Set();
let tabRevision = 0;
let initializationPromise = null;
let tabScanPromise = null;
let storageWriteQueue = Promise.resolve();

function getControlState() {
  return {
    enabled,
    state: captureState,
    active: enabled && captureState === "active",
    error: controlError,
    message: controlMessage
  };
}

function getAudioState() {
  const active = enabled && captureState === "active";
  return {
    active,
    channels: active ? lastChannels : [],
    timestamp: active ? lastFrameTimestamp : 0
  };
}

async function notifyTab(tabId, payload) {
  try {
    await chrome.tabs.sendMessage(tabId, {
      type: "conversation-trail:audio-level",
      ...payload
    });
  } catch {
    // The page may be navigating or its content script may not be ready yet.
  }
}

function broadcastAudioState() {
  const payload = getAudioState();
  for (const tabId of chatGPTTabIds) {
    void notifyTab(tabId, payload);
  }
}

function getActionPresentation() {
  if (!enabled) {
    return {
      badge: "",
      color: "#737373",
      title: "开启 Conversation Trail 系统音频可视化"
    };
  }

  if (captureState === "active") {
    return {
      badge: "ON",
      color: "#525252",
      title: "Conversation Trail 系统音频可视化已开启"
    };
  }

  if (captureState === "permission-required") {
    return {
      badge: "?",
      color: "#d97706",
      title: controlMessage || "声浪已开启，等待 Local Audio Engine 系统音频权限"
    };
  }

  if (captureState === "error") {
    return {
      badge: "!",
      color: "#dc2626",
      title: `${controlError || "无法连接本机音频服务"}（声浪设置仍为开启）`
    };
  }

  return {
    badge: "…",
    color: "#737373",
    title: controlMessage || "声浪已开启，正在连接 macOS 系统音频"
  };
}

async function updateAction(tabId) {
  if (!Number.isInteger(tabId)) {
    return;
  }

  const presentation = getActionPresentation();
  try {
    await Promise.all([
      chrome.action.setBadgeBackgroundColor({ tabId, color: presentation.color }),
      chrome.action.setBadgeText({ tabId, text: presentation.badge }),
      chrome.action.setTitle({ tabId, title: presentation.title })
    ]);
  } catch {
    // The tab may have closed while its action state was being updated.
  }
}

async function resetAction(tabId) {
  try {
    await Promise.all([
      chrome.action.setBadgeText({ tabId, text: "" }),
      chrome.action.setTitle({
        tabId,
        title: "开启 Conversation Trail 系统音频可视化"
      })
    ]);
  } catch {
    // The tab may already be gone.
  }
}

function refreshActions() {
  for (const tabId of chatGPTTabIds) {
    void updateAction(tabId);
  }
}

function setConnectionState(state, error = "", message = "", clearAudio = false) {
  captureState = state;
  controlError = error;
  controlMessage = message;
  if (clearAudio) {
    lastChannels = [];
    lastFrameTimestamp = 0;
    broadcastAudioState();
  }
  refreshActions();
}

function disconnectNativePort(sendStop = true) {
  const port = nativePort;
  nativePort = null;
  if (!port) {
    return;
  }

  if (sendStop) {
    try {
      port.postMessage({ type: "stop" });
    } catch {
      // The native process may already have exited.
    }
  }
  try {
    port.disconnect();
  } catch {
    // The native process may already have exited.
  }
}

function handleNativeDisconnect(port) {
  const nativeError = chrome.runtime.lastError?.message || "";
  if (nativePort !== port) {
    return;
  }

  nativePort = null;
  if (!enabled || chatGPTTabIds.size === 0) {
    setConnectionState(
      "idle",
      "",
      enabled ? "声浪已开启；打开 ChatGPT 页面后将自动连接" : "",
      true
    );
    return;
  }

  const errorMessage = nativeError.toLowerCase().includes("not found")
    ? "未安装本地音频组件，请先安装下载包中的 Conversation Trail Audio.pkg，然后重试"
    : nativeError || "Conversation Trail relay 已断开";
  setConnectionState("error", errorMessage, errorMessage, true);
}

function handleNativeMessage(port, message) {
  if (nativePort !== port || !enabled || chatGPTTabIds.size === 0) {
    return;
  }

  if (
    message?.type === "relay-status"
    && (message.state === "launching" || message.state === "connecting")
  ) {
    const fallback = message.state === "launching"
      ? "正在启动 Local Audio Engine…"
      : "正在连接 Local Audio Engine…";
    setConnectionState("starting", "", message.message || fallback, true);
    return;
  }

  if (message?.type === "ready") {
    setConnectionState("starting", "", "正在启动系统音频流…", true);
    return;
  }

  if (message?.type === "audio-frame") {
    const stateChanged = captureState !== "active" || controlError || controlMessage;
    captureState = "active";
    controlError = "";
    controlMessage = "";
    lastChannels = Array.isArray(message.channels) ? message.channels : [];
    lastFrameTimestamp = Number(message.timestamp) || 0;
    if (stateChanged) {
      refreshActions();
    }
    broadcastAudioState();
    return;
  }

  if (message?.type === "engine-status") {
    if (message.state === "permission-required") {
      setConnectionState(
        "permission-required",
        "",
        message.message || "请在 Local Audio Engine 中允许系统音频录制",
        true
      );
    } else if (message.state === "streaming") {
      setConnectionState("active", "", message.message || "", false);
      broadcastAudioState();
    } else if (message.state === "error") {
      const errorMessage = message.message || "Local Audio Engine 无法读取系统音频";
      disconnectNativePort();
      setConnectionState("error", errorMessage, errorMessage, true);
    }
    return;
  }

  if (message?.type === "stopped") {
    disconnectNativePort(false);
    const errorMessage = "系统音频订阅已停止，请重试连接";
    setConnectionState("error", errorMessage, errorMessage, true);
    return;
  }

  if (message?.type === "error") {
    const errorMessage = message.message || "无法读取 macOS 系统音频";
    disconnectNativePort();
    setConnectionState("error", errorMessage, errorMessage, true);
  }
}

function startNativeConnection() {
  if (!enabled || chatGPTTabIds.size === 0 || nativePort) {
    return;
  }

  setConnectionState("starting", "", "正在连接 Local Audio Engine…", true);

  let port = null;
  try {
    if (typeof chrome.runtime.connectNative !== "function") {
      throw new Error("Chrome 尚未载入本机连接权限，请重新加载扩展后再试");
    }

    port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
    nativePort = port;
    port.onMessage.addListener(message => handleNativeMessage(port, message));
    port.onDisconnect.addListener(() => handleNativeDisconnect(port));
    port.postMessage({
      type: "start",
      clientId: "conversation-trail.chrome"
    });
  } catch (error) {
    if (nativePort === port) {
      nativePort = null;
    }
    try {
      port?.disconnect();
    } catch {
      // A partially-created port may already be disconnected.
    }
    const errorMessage = error?.message || "无法连接本机音频桥接器";
    setConnectionState("error", errorMessage, errorMessage, true);
  }
}

function pauseWithoutChatGPTTabs() {
  disconnectNativePort();
  setConnectionState(
    "idle",
    "",
    enabled ? "声浪已开启；打开 ChatGPT 页面后将自动连接" : "",
    true
  );
}

function addChatGPTTab(tabId) {
  if (!Number.isInteger(tabId) || chatGPTTabIds.has(tabId)) {
    return;
  }

  chatGPTTabIds.add(tabId);
  void updateAction(tabId);
  if (enabled) {
    startNativeConnection();
  }
}

function removeChatGPTTab(tabId) {
  if (!chatGPTTabIds.delete(tabId)) {
    return false;
  }

  void resetAction(tabId);
  if (chatGPTTabIds.size === 0) {
    pauseWithoutChatGPTTabs();
  }
  return true;
}

function replaceChatGPTTabs(tabs) {
  const previousTabIds = chatGPTTabIds;
  const nextTabIds = new Set();
  for (const tab of tabs) {
    if (Number.isInteger(tab?.id) && CHATGPT_URL_PATTERN.test(tab.url || "")) {
      nextTabIds.add(tab.id);
    }
  }

  chatGPTTabIds = nextTabIds;
  for (const tabId of previousTabIds) {
    if (!nextTabIds.has(tabId)) {
      void resetAction(tabId);
    }
  }

  if (nextTabIds.size === 0) {
    pauseWithoutChatGPTTabs();
    return;
  }

  refreshActions();
  if (enabled) {
    startNativeConnection();
  }
  broadcastAudioState();
}

function requestTabScan() {
  if (tabScanPromise) {
    return tabScanPromise;
  }

  tabScanPromise = (async () => {
    while (true) {
      const revision = tabRevision;
      let tabs;
      try {
        tabs = await chrome.tabs.query({ url: CHATGPT_QUERY_PATTERN });
      } catch (error) {
        if (revision !== tabRevision) {
          continue;
        }
        if (enabled && chatGPTTabIds.size === 0) {
          const errorMessage = error?.message || "无法查找 ChatGPT 页面";
          setConnectionState("error", errorMessage, errorMessage, true);
        }
        return;
      }

      if (revision !== tabRevision) {
        continue;
      }
      replaceChatGPTTabs(Array.isArray(tabs) ? tabs : []);
      return;
    }
  })().finally(() => {
    tabScanPromise = null;
  });

  return tabScanPromise;
}

function persistPreference(value) {
  const update = storageWriteQueue
    .catch(() => {})
    .then(() => chrome.storage.local.set({ [STORAGE_KEY]: value }));
  storageWriteQueue = update;
  return update;
}

function initialize() {
  if (initializationPromise) {
    return initializationPromise;
  }

  const revision = preferenceRevision;
  initializationPromise = (async () => {
    try {
      const stored = await chrome.storage.local.get(STORAGE_KEY);
      if (revision === preferenceRevision) {
        enabled = stored[STORAGE_KEY] === true;
      }
    } catch (error) {
      if (revision === preferenceRevision) {
        const message = error?.message || "无法读取已保存的声浪设置，请重新加载扩展";
        setConnectionState("error", message, message, true);
        return;
      }
    }
    await requestTabScan();
  })();

  return initializationPromise;
}

async function setAudioEnabled(nextEnabled) {
  preferenceRevision += 1;
  enabled = nextEnabled;

  if (enabled) {
    controlError = "";
    controlMessage = "";
    if (chatGPTTabIds.size > 0) {
      startNativeConnection();
    } else {
      setConnectionState(
        "idle",
        "",
        "声浪已开启；打开 ChatGPT 页面后将自动连接",
        true
      );
    }
  } else {
    disconnectNativePort();
    setConnectionState("idle", "", "", true);
  }

  const persistence = persistPreference(enabled);
  if (enabled) {
    await Promise.all([persistence, requestTabScan()]);
  } else {
    await persistence;
  }
  return getControlState();
}

async function retryAudioConnection() {
  await initialize();
  if (!enabled) {
    return getControlState();
  }

  disconnectNativePort();
  if (chatGPTTabIds.size > 0) {
    setConnectionState("starting", "", "正在重新连接 Local Audio Engine…", true);
  } else {
    setConnectionState(
      "idle",
      "",
      "声浪已开启；打开 ChatGPT 页面后将自动连接",
      true
    );
  }

  await requestTabScan();
  if (enabled && chatGPTTabIds.size > 0) {
    startNativeConnection();
  }
  return getControlState();
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.target !== "conversation-trail-background" || sender.id !== chrome.runtime.id) {
    return false;
  }

  const fromExtensionPage = sender.url?.startsWith(chrome.runtime.getURL(""));

  if (message.type === "audio-visualizer:get-state") {
    if (!Number.isInteger(sender.tab?.id) || !CHATGPT_URL_PATTERN.test(sender.tab.url || "")) {
      sendResponse({ active: false, channels: [], timestamp: 0 });
      return false;
    }

    initialize().then(async () => {
      if (!chatGPTTabIds.has(sender.tab.id)) {
        // The sending document may have closed while preferences were loading.
        // Discover current tabs instead of reviving its stale sender identity.
        await requestTabScan();
      }
      sendResponse(chatGPTTabIds.has(sender.tab.id)
        ? getAudioState()
        : { active: false, channels: [], timestamp: 0 });
    }).catch(() => {
      sendResponse({ active: false, channels: [], timestamp: 0 });
    });
    return true;
  }

  if (message.type === "audio-visualizer:get-control-state") {
    if (!fromExtensionPage) {
      return false;
    }
    initialize().then(() => sendResponse(getControlState())).catch((error) => {
      const errorMessage = error?.message || "无法读取系统音频声浪状态";
      sendResponse({
        ...getControlState(),
        error: errorMessage,
        message: errorMessage
      });
    });
    return true;
  }

  if (message.type === "audio-visualizer:set-enabled") {
    if (!fromExtensionPage || typeof message.enabled !== "boolean") {
      return false;
    }
    setAudioEnabled(message.enabled).then(sendResponse).catch((error) => {
      const errorMessage = error?.message || "无法更新系统音频声浪状态";
      sendResponse({
        ...getControlState(),
        error: errorMessage,
        message: errorMessage
      });
    });
    return true;
  }

  if (message.type === "audio-visualizer:retry") {
    if (!fromExtensionPage) {
      return false;
    }
    retryAudioConnection().then(sendResponse).catch((error) => {
      const errorMessage = error?.message || "无法重新连接系统音频";
      sendResponse({
        ...getControlState(),
        error: errorMessage,
        message: errorMessage
      });
    });
    return true;
  }

  return false;
});

chrome.tabs.onCreated.addListener((tab) => {
  tabRevision += 1;
  const url = tab.url || tab.pendingUrl || "";
  if (CHATGPT_URL_PATTERN.test(url)) {
    addChatGPTTab(tab.id);
  }
  void requestTabScan();
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const url = changeInfo.url || tab?.url || "";
  const wasChatGPTTab = chatGPTTabIds.has(tabId);
  const isChatGPTTab = CHATGPT_URL_PATTERN.test(url);
  if (!wasChatGPTTab && !isChatGPTTab) {
    return;
  }

  tabRevision += 1;
  if (isChatGPTTab) {
    addChatGPTTab(tabId);
  } else if (changeInfo.url || changeInfo.status === "loading") {
    removeChatGPTTab(tabId);
  }
  void requestTabScan();
});

chrome.tabs.onRemoved.addListener((tabId) => {
  tabRevision += 1;
  removeChatGPTTab(tabId);
});

chrome.tabs.onReplaced.addListener(() => {
  tabRevision += 1;
  void requestTabScan();
});

chrome.runtime.onStartup.addListener(() => {
  void initialize();
});

chrome.runtime.onSuspend.addListener(() => {
  disconnectNativePort();
  captureState = "idle";
  controlError = "";
  controlMessage = "";
  lastChannels = [];
  lastFrameTimestamp = 0;
});

void initialize();
