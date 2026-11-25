import { spawn, spawnSync, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";

const edge = process.argv.includes("--edge");
const pagesOnly = process.argv.includes("--pages-only");
const browserAppID = edge ? "com.microsoft.edgemac" : "com.google.Chrome";
const browserName = edge ? "Microsoft Edge" : "Google Chrome";
const nativeProfile = edge ? "WORKANDPLAY_EDGE_USER_DATA_DIRECTORY" : "WORKANDPLAY_CHROME_USER_DATA_DIRECTORY";

const repo = process.cwd();
const directory = mkdtempSync(join(tmpdir(), "workandplay-smoke-"));
const appData = join(directory, "app");
const chromeData = join(directory, "chrome");
mkdirSync(appData);
const db = join(appData, "history.sqlite3");
const queried = sql => execFileSync("/usr/bin/sqlite3", ["-batch", "-cmd", ".timeout 1500", "-json", db, sql], { encoding: "utf8" });
const rule = (host, pathPrefix, category, kind) => ({id:randomUUID(), appID:"", host, pathPrefix, category, kind, windowContains:"", project:""});
function prefs(rest) {
  const value = { idleSeconds: 1, readingSeconds: 4, countVideo: true, paused: false,
    schedule:{weekdays:{},overrides:rest ? {[new Date().toLocaleDateString("en-CA")]:[{start:0,end:1440}]} : {}},
    rules:[rule("localhost", "/work", "work", "reading"), rule("localhost", "/movie", "entertainment", "interactive"),
      rule("127.0.0.1", "/rest", "entertainment", "interactive"),
      { ...rule("", "", "work", "interactive"), appID: "com.apple.Terminal" }] };
  const q = JSON.stringify(value).replaceAll("'", "''");
  queried(`CREATE TABLE IF NOT EXISTS preferences(id INTEGER PRIMARY KEY CHECK (id=1), json BLOB NOT NULL);
    INSERT INTO preferences VALUES (1, '${q}') ON CONFLICT(id) DO UPDATE SET json=excluded.json;`);
}

async function waitFor(description, check, limit = 12000) {
  const end = Date.now() + limit;
  while (Date.now() < end) {
    const result = await check();
    if (result) { console.log("PASS", description); return result; }
    await delay(250);
  }
  throw new Error(`Timed out: ${description}`);
}

const fixture = createServer((req, res) => {
  res.setHeader("content-type", "text/html; charset=utf-8");
  if (req.url.startsWith("/work")) {
    res.end('<!doctype html><title>browser-fixture-private-title</title><main style="height:8000px">Reading fixture</main>');
  } else {
    res.end(`<title>Motion fixture</title><video autoplay muted playsinline style="width:480px;height:270px"></video>
    <script>
    const canvas=document.createElement("canvas"); canvas.width=480; canvas.height=270;
    const ctx=canvas.getContext("2d"); let i=0;
    setInterval(()=>{ctx.fillStyle=i++%2 ? "#246" : "#268"; ctx.fillRect(0,0,480,270);},30);
    const video=document.querySelector("video"); video.srcObject=canvas.captureStream(24);
    video.play().catch(()=>{});
    </script>`);
  }
});
await new Promise(r => fixture.listen(0, "127.0.0.1", r));
const url = `http://localhost:${fixture.address().port}`;
const appPath = join(repo, "dist/WorkAndPlay.app/Contents/MacOS/WorkAndPlay");
const launchApp = () => spawn(appPath, [], {env:{...process.env,WORKANDPLAY_DATA_DIRECTORY:appData}, stdio:"ignore"});
const chromePath = `/Applications/${browserName}.app/Contents/MacOS/${browserName}`;
let app, chrome, browserPID;
function activate(pid) {
  return execFileSync("/usr/bin/swift", ["-e", `import AppKit; let a=NSRunningApplication(processIdentifier:${pid})!; _ = a.activate(); RunLoop.current.run(until: Date().addingTimeInterval(0.2)); print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)`], {encoding:"utf8"}).trim();
}
function closeTestWorkspace(pid) {
  execFileSync("/usr/bin/swift", ["-e", `
      import ApplicationServices
      let app = AXUIElementCreateApplication(${pid})
      var value: CFTypeRef?
      if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
         let windows = value as? [AXUIElement] {
          for window in windows {
              var button: CFTypeRef?
              if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
                 let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                  AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
              }
          }
      }
    `]);
}

try {
  if (spawnSync("/usr/bin/pgrep", ["-x", "WorkAndPlay"]).status === 0) {
    throw new Error("Quit WorkAndPlay before starting the isolated browser verification.");
  }
  execFileSync(join(repo, "scripts/install-chrome-host.sh"), [], {
    env: {...process.env, WORKANDPLAY_BROWSER: edge ? "edge" : "chrome", [nativeProfile]: chromeData}
  });
  prefs(false);
  app = launchApp();
  await waitFor("real macOS app and SQLite startup", () => {
    try { return queried("SELECT name FROM sqlite_master WHERE name='slice';").includes("slice"); } catch { return false; }
  });
  await delay(650);
  closeTestWorkspace(app.pid);
  chrome = spawn(chromePath, [`--user-data-dir=${chromeData}`, "--remote-debugging-pipe",
    "--enable-unsafe-extension-debugging", "--no-first-run", "--no-default-browser-check",
    "--disable-backgrounding-occluded-windows", "--autoplay-policy=no-user-gesture-required", "about:blank"],
    {stdio:["ignore","ignore","ignore","pipe","pipe"]});
  browserPID = chrome.pid;
  const pending = new Map();
  let next = 0, bytes = "";
  chrome.stdio[4].on("data", chunk => {
    bytes += chunk.toString();
    let end;
    while ((end = bytes.indexOf("\0")) >= 0) {
      const msg = JSON.parse(bytes.substring(0,end)); bytes = bytes.substring(end+1);
      if (!pending.has(msg.id)) continue;
      const {resolve,reject} = pending.get(msg.id); pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message)); else resolve(msg.result);
    }
  });
  function cdp(method, params={}, sessionId) {
    return new Promise((resolve,reject) => {
      const id=++next; pending.set(id,{resolve,reject});
      chrome.stdio[3].write(JSON.stringify({id, method, params, sessionId})+"\0");
      const timeout=setTimeout(()=>{if (pending.delete(id)) reject(new Error("Timeout "+method));},15000); timeout.unref();
    });
  }
  await cdp("Browser.getVersion");
  const {id} = await cdp("Extensions.loadUnpacked", {path:resolve("chrome-extension")});
  console.log("PASS extension loaded", id);
  const attached = async targetId => (await cdp("Target.attachToTarget", {targetId,flatten:true})).sessionId;
  const evaluate = async (session, expression) => (await cdp("Runtime.evaluate", {expression,returnByValue:true,awaitPromise:true},session)).result.value;
  const targets = async () => (await cdp("Target.getTargets")).targetInfos;
  const worker = await waitFor("MV3 worker startup", async () => (await targets()).find(t=>t.type==="service_worker" && t.url.endsWith("/worker.js")));
  const ws = await attached(worker.targetId);
  await waitFor(`real ${browserName} Native Messaging → app connection`, async () => evaluate(ws,"connected"));
  const page = await cdp("Target.createTarget", {url:"about:blank"});
  const ps = await attached(page.targetId);
  async function focusTestWindow() {
    await cdp("Page.bringToFront", {}, ps);
    await evaluate(ws, "chrome.windows.getLastFocused().then(w=>chrome.windows.update(w.id,{focused:true}))");
    return Number(activate(browserPID)) === browserPID;
  }
  await waitFor(`the isolated ${browserName} window gained macOS focus`, focusTestWindow);
  await cdp("Page.navigate", {url:url+"/work?ticket=fixture-query-secret#fixture-fragment"}, ps);
  let lastRefocus = 0;
  async function snapshot() {
    const result = await evaluate(ws, "ownedFocus && activeTab !== undefined ? chrome.tabs.sendMessage(activeTab,{type:'snapshot'},{frameId:0}).catch(()=>null) : null");
    if (result == null && Date.now() - lastRefocus > 1200) {
      lastRefocus = Date.now();
      await focusTestWindow();
    }
    return result;
  }
  await waitFor("verified foreground tab from content script", async () => (await snapshot())?.path === "/work");
  await evaluate(ps, "window.scrollTo(0,450); true");
  await delay(800);
  const afterProgrammaticScroll = await waitFor("content script remains reachable after programmatic scroll", snapshot);
  if (afterProgrammaticScroll.readingAt !== null) throw new Error("Script-initiated scroll renewed reading");
  if (afterProgrammaticScroll.interactionAt !== null) throw new Error("Script-initiated scroll was treated as foreground input");
  await cdp("Input.dispatchMouseEvent", {type:"mouseWheel",x:210,y:240,deltaX:0,deltaY:580}, ps);
  const firstReading = await waitFor("trusted scroll renews reading", async () => (await snapshot())?.readingAt);
  await waitFor("trusted foreground input is reported without keys or contents", async () => {
    const state = await snapshot();
    return Number.isFinite(state?.interactionAt) && Object.keys(state).sort().join(",") ===
      "document,host,interactionAt,path,readingAt,videoPlaying";
  });
  await delay(2200);
  await cdp("Input.dispatchMouseEvent", {type:"mouseWheel",x:210,y:240,deltaX:0,deltaY:580}, ps);
  const secondReading = await waitFor("same-page scroll renews the same reading", async () => {
    const at = (await snapshot())?.readingAt;
    return at > firstReading ? at : null;
  });
  await delay(1000);
  await cdp("Input.dispatchKeyEvent", {
    type: "keyDown", key: "PageDown", code: "PageDown", windowsVirtualKeyCode: 34
  }, ps);
  await cdp("Input.dispatchKeyEvent", {
    type: "keyUp", key: "PageDown", code: "PageDown", windowsVirtualKeyCode: 34
  }, ps);
  await waitFor("page navigation renews reading", async () => (await snapshot())?.readingAt > secondReading);
  await delay(1500);
  if (pagesOnly) {
    const {targetId} = await cdp("Target.createTarget", {url:edge ? "edge://version" : "chrome://version"});
    await cdp("Page.bringToFront", {}, await attached(targetId));
    await waitFor(`foreground reading recorded as work with ${browserName} identity`, () => {
      const report = queried(`SELECT COUNT(DISTINCT visit_id) AS visits, ROUND(SUM(end-start), 1) AS duration FROM slice
        WHERE app_id='${browserAppID}' AND host='localhost' AND bucket='regular' AND kind='reading';`);
      const site = JSON.parse(report)[0];
      return site.visits > 0 && site.duration > 0;
    });
    await cdp("Extensions.uninstall", {id});
  } else {
    await cdp("Page.navigate", {url:url+"/movie"}, ps);
    await focusTestWindow();
    await waitFor("foreground video is visibly playing", async () => {
      const state = await snapshot();
      return state?.path === "/movie" && state.videoPlaying;
    });
    await delay(3100);
    await evaluate(ps, "document.querySelector('video').pause(); true");
    await waitFor("paused video stops signalling", async () => (await snapshot())?.videoPlaying === false);
    const pauseObserved = Date.now() / 1000;
    await delay(2400);
    const resumeRequested = Date.now() / 1000;
    await evaluate(ps, "document.querySelector('video').play().then(()=>true)");
    await waitFor("foreground video resumes", async () => (await snapshot())?.videoPlaying);
    await delay(3100);
    const {targetId:restricted} = await cdp("Target.createTarget", {url:edge ? "edge://version" : "chrome://version"});
    const rs = await attached(restricted);
    await cdp("Page.bringToFront",{},rs);
    const readTotals = () => queried("SELECT bucket, ROUND(SUM(end-start),2) AS seconds FROM slice GROUP BY bucket;");
    try {
      await waitFor("reading and entertainment written with identifiable buckets", () => {
        const rows = JSON.parse(readTotals() || "[]");
        const lengths = Object.fromEntries(rows.map(row => [row.bucket, row.seconds]));
        return lengths.regular >= 2 && lengths.entertainment >= 2 ? lengths : null;
      });
    } catch (error) {
      console.log("Isolated fixture totals:", readTotals().trim() || "(none)");
      throw error;
    }
    const readEntertainment = () => queried("SELECT id,start,end FROM slice WHERE bucket='entertainment' ORDER BY start;");
    const first = await waitFor("real paused video creates a break in history", () => {
      const json = readEntertainment();
      const rows = JSON.parse(json || "[]");
      const recordedBefore = rows.some(row => row.start < pauseObserved);
      const recordedAfter = rows.some(row => row.end > resumeRequested + 0.5);
      const recordedDuring = rows.some(row => row.end > pauseObserved + 1.15 && row.start < resumeRequested - 0.15);
      if (recordedDuring) throw new Error("Video was logged during the pause");
      return recordedBefore && recordedAfter ? json : null;
    });
    await delay(5200);
    if (first !== readEntertainment()) throw new Error("Background video continued");
    console.log("PASS background playback and restricted Chrome page accrue no video time");
    const beforeRest = queried("SELECT id,start,end,bucket FROM slice;");
    const ended = once(app, "exit");
    app.kill();
    await ended;
    prefs(true);
    app = launchApp();
    await delay(650);
    closeTestWorkspace(app.pid);
    await focusTestWindow();
    await cdp("Page.navigate", {url:url.replace("localhost","127.0.0.1")+"/rest?ticket=private-rest-query"}, ps);
    await waitFor("real playing video in a rest period", async () => {
      const state = await snapshot();
      return state?.path === "/rest" && state.videoPlaying;
    });
    await delay(2600);
    await cdp("Page.bringToFront",{},rs);
    await delay(500);
    if (beforeRest !== queried("SELECT id,start,end,bucket FROM slice;")) throw new Error("Non-work rest activity reached SQLite");
    console.log("PASS real Chrome entertainment discarded during rest before writing history");
    await cdp("Extensions.uninstall",{id});
    await delay(3300);
    if (first !== readEntertainment()) throw new Error("Video changed after disconnect");
    console.log("PASS extension disconnect");
    const sensitive=["fixture-query-secret","fixture-fragment","browser-fixture-private-title","private-rest-query","/work","/movie","127.0.0.1"];
    const historyDump=queried("SELECT app_id, app_name, host, kind, category, bucket FROM slice;");
    for (const identifier of sensitive) if (historyDump.includes(identifier)) throw new Error("Private value in history");
    for (const identifier of sensitive.slice(0,4)) if (readFileSync(db).includes(identifier)) throw new Error("Private value in SQLite");
    console.log("PASS local history privacy");
  }
  await cdp("Browser.close").catch(()=>{});
} finally {
  const children = [app,chrome].filter(child => child && child.exitCode === null && child.signalCode === null);
  await Promise.all(children.map(child => {
    const exited = once(child,"exit");
    child.kill();
    return exited;
  }));
  fixture.close();
  rmSync(directory,{recursive:true,force:true});
}
