const hostName = "local.workandplay.chrome";
let port;
let session;
let sequence;
let generation = 0;
let sampling = false;
let activeTab;
let connected = false;
let ownedFocus = false;
let pageAvailable = false;

function connect() {
  if (port) return;
  const connection = chrome.runtime.connectNative(hostName);
  port = connection;
  session = crypto.randomUUID();
  sequence = 0;
  connection.onMessage.addListener(reply => {
    if (port === connection) connected = reply.connected === true;
  });
  connection.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (port === connection) {
      port = undefined;
      connected = false;
    }
  });
}

function send(page, focused) {
  connect();
  try {
    port.postMessage({ version: 1, session, sequence: ++sequence, sentAt: Date.now(), page, focused });
  } catch {
    port = undefined;
    connected = false;
  }
}

async function sample() {
  if (sampling) return;
  sampling = true;
  const before = generation;
  let page = null;
  let focused = false;
  try {
    const window = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
    if (window.focused && !window.incognito && window.state !== "minimized") {
      focused = true;
      const [tab] = await chrome.tabs.query({ active: true, windowId: window.id });
      if (before === generation) activeTab = tab?.id;
      if (tab?.id !== undefined && !tab.discarded && tab.status !== "loading") {
        const snapshot = await chrome.tabs.sendMessage(tab.id, { type: "snapshot" }, { frameId: 0 });
        if (snapshot) page = { tab: tab.id, ...snapshot };
      }
    }
  } catch {
    // Restricted pages and withheld site access produce desktop-only coverage.
  } finally {
    sampling = false;
    if (before === generation) {
      ownedFocus = focused;
      pageAvailable = page !== null;
      send(page, focused);
    } else {
      void sample();
    }
  }
}

function invalidate() {
  generation++;
  activeTab = undefined;
  pageAvailable = false;
  if (ownedFocus) send(null, true);
  void sample();
}

chrome.windows.onFocusChanged.addListener(invalidate);
chrome.tabs.onActivated.addListener(invalidate);
chrome.tabs.onRemoved.addListener(id => { if (id === activeTab) invalidate(); });
chrome.tabs.onUpdated.addListener((id, change) => {
  if (id !== activeTab) return;
  if (change.status === "loading" || change.discarded) invalidate();
  else if (change.status === "complete") void sample();
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type === "page-signal" && sender.frameId === 0 && sender.tab?.id === activeTab) {
    void sample();
  } else if (message.type === "status" && sender.url === chrome.runtime.getURL("popup.html")) {
    void sample();
    reply({ connected, pageAvailable });
  }
});
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === "reconnect") void sample(); });
void chrome.alarms.create("reconnect", { periodInMinutes: 0.5 });
setInterval(sample, 1000);
void sample();
