const hostName = "local.workandplay.chrome";
let port;
let session;
let sequence;
let generation = 0;
let sampling = false;
let sampleRequested = false;
let activeTab;
let connected = false;
let ownedFocus = false;
let pageAvailable = false;
let lastPermitRequest = 0;
let permitRequest;
const loadingDocuments = new Map();

function connect() {
  if (port) return;
  const connection = chrome.runtime.connectNative(hostName);
  port = connection;
  session = crypto.randomUUID();
  sequence = 0;
  connection.onMessage.addListener(reply => {
    if (port !== connection) return;
    connected = reply.connected === true;
    const request = permitRequest;
    if (!request || request.sequence !== reply.sequence) return;
    permitRequest = undefined;
    if (request.generation !== generation || request.tab !== activeTab || Date.now() - request.at > 500) return;
    void chrome.tabs.sendMessage(request.tab, {
      type: "work-permit", document: request.document, host: request.host, path: request.path,
      permit: reply.permit || null
    }, { frameId: 0 }).catch(() => {});
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
    const sentAt = Date.now();
    const workPermitRequested = !!page && (sentAt - lastPermitRequest >= 900 || !!page.workSignals?.length);
    const nextSequence = ++sequence;
    if (workPermitRequested) {
      lastPermitRequest = sentAt;
      permitRequest = { sequence: nextSequence, tab: page.tab, document: page.document,
        host: page.host, path: page.path, generation, at: sentAt };
    }
    port.postMessage({ version: 1, session, sequence: nextSequence, sentAt, page, focused, workPermitRequested });
  } catch {
    port = undefined;
    connected = false;
  }
}

async function sample() {
  if (sampling) {
    sampleRequested = true;
    return;
  }
  sampling = true;
  sampleRequested = false;
  const before = generation;
  let page = null;
  let focused = false;
  try {
    const window = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
    if (window.focused && !window.incognito && window.state !== "minimized") {
      focused = true;
      const [tab] = await chrome.tabs.query({ active: true, windowId: window.id });
      if (before === generation) activeTab = tab?.id;
      if (tab?.id !== undefined && !tab.discarded) {
        const target = snapshotTarget(tab);
        const snapshot = target && await chrome.tabs.sendMessage(tab.id, { type: "snapshot" }, target);
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
    }
    if (sampleRequested || before !== generation) void sample();
  }
}

function snapshotTarget(tab) {
  if (tab.status !== "loading") return { frameId: 0 };
  // During navigation, only ask the committed document that reported it was ready.
  const documentId = loadingDocuments.get(tab.id);
  return documentId === undefined ? null : { documentId };
}

function invalidate() {
  generation++;
  activeTab = undefined;
  pageAvailable = false;
  permitRequest = undefined;
  lastPermitRequest = 0;
  if (ownedFocus) send(null, true);
  void sample();
}

chrome.windows.onFocusChanged.addListener(invalidate);
chrome.tabs.onActivated.addListener(invalidate);
chrome.tabs.onRemoved.addListener(id => {
  loadingDocuments.delete(id);
  if (id === activeTab) invalidate();
});
chrome.tabs.onUpdated.addListener((id, change) => {
  if (change.status || change.discarded) loadingDocuments.delete(id);
  if (id !== activeTab) return;
  if (change.status === "loading" || change.discarded) invalidate();
  else if (change.status === "complete") void sample();
});
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type === "page-ready" && sender.frameId === 0 && sender.tab?.id !== undefined
      && sender.tab.active && !sender.tab.incognito) {
    if (sender.tab.status === "loading" && sender.documentLifecycle === "active" && sender.documentId) {
      loadingDocuments.set(sender.tab.id, sender.documentId);
    }
    void sample();
  } else if (message.type === "page-signal" && sender.frameId === 0 && sender.tab?.id === activeTab) {
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
