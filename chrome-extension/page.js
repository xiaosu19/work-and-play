(() => {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  const documentID = [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
  const navigationKeys = new Set(["PageDown", "PageUp", "Home", "End", "ArrowDown", "ArrowUp", "Space"]);
  const scrollPositions = new WeakMap();
  const playback = new WeakMap();
  function rememberScrollRoot() {
    const root = document.scrollingElement;
    if (root && !scrollPositions.has(root)) scrollPositions.set(root, root.scrollTop);
  }
  rememberScrollRoot();
  document.addEventListener("DOMContentLoaded", rememberScrollRoot, { once: true });
  let path = location.pathname;
  let readingAt = null;
  let interactionAt = null;
  let intentUntil = 0;
  let pendingIntent;
  let lastScrollAt = 0;
  let watchingVideo = false;

  function notify(type = "page-signal") {
    void chrome.runtime.sendMessage({ type }).catch(() => {});
  }

  function syncPath() {
    if (path === location.pathname) return;
    path = location.pathname;
    readingAt = null;
    interactionAt = null;
    lastScrollAt = 0;
  }

  function recordInteraction(event) {
    if (!event.isTrusted || document.visibilityState !== "visible" || !document.hasFocus()) return;
    syncPath();
    const now = Date.now();
    if (interactionAt === null || now - interactionAt >= 250) {
      interactionAt = now;
      notify();
    }
  }

  for (const type of ["pointerdown", "keydown", "wheel", "touchstart"]) {
    addEventListener(type, recordInteraction, { capture: true, passive: true });
  }
  addEventListener("blur", () => { interactionAt = null; });
  addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") interactionAt = null;
  });

  function read() {
    if (document.visibilityState !== "visible") return;
    syncPath();
    readingAt = Date.now();
    notify();
  }

  function markIntent() {
    if (performance.now() > intentUntil) pendingIntent = undefined;
    intentUntil = performance.now() + 700;
  }

  for (const type of ["wheel", "touchstart", "touchmove", "pointerdown"]) {
    addEventListener(type, event => {
      if (event.isTrusted) {
        markIntent();
        const scroller = scrollContainer(event.target);
        if (scroller && !scrollPositions.has(scroller)) scrollPositions.set(scroller, scroller.scrollTop);
        pendingIntent = scroller;
      }
    }, { capture: true, passive: true });
  }

  function scrollContainer(target) {
    for (let element = target instanceof Element ? target : null; element; element = element.parentElement) {
      if (element.scrollHeight > element.clientHeight && /auto|scroll/.test(getComputedStyle(element).overflowY)) return element;
    }
    return document.scrollingElement;
  }

  addEventListener("keydown", event => {
    if (!event.isTrusted || !navigationKeys.has(event.code) || event.altKey || event.metaKey || event.ctrlKey
        || event.target?.closest?.("input, textarea, select, button, [contenteditable]")) return;
    markIntent();
    // Page navigation keys can also turn pages in readers without a scrolling container.
    if (!event.repeat && (event.code === "PageUp" || event.code === "PageDown")) read();
  }, true);

  addEventListener("click", event => {
    if (!event.isTrusted) return;
    const control = event.target?.closest?.("a, button, [role=button]");
    const label = control?.getAttribute("aria-label") || control?.getAttribute("title") || "";
    if (control?.rel === "next" || control?.rel === "prev"
        || /^(next page|previous page|下一页|上一页|翻到下一页|翻到上一页)$/i.test(label.trim())) read();
  }, true);

  addEventListener("scroll", event => {
    if (!event.isTrusted || document.visibilityState !== "visible") return;
    const scroller = event.target === document ? document.scrollingElement : event.target;
    if (!(scroller instanceof Element)) return;
    const top = scroller.scrollTop;
    const anchor = scrollPositions.get(scroller);
    const hadIntent = performance.now() <= intentUntil
      && (!pendingIntent || scroller === pendingIntent || scroller.contains(pendingIntent));
    // Chrome may apply the first compositor scroll before its passive wheel listener runs.
    if (anchor === undefined || !hadIntent) {
      scrollPositions.set(scroller, top);
      return;
    }
    if (Math.abs(top - anchor) >= 64 && performance.now() - lastScrollAt >= 250) {
      lastScrollAt = performance.now();
      scrollPositions.set(scroller, top);
      read();
    }
  }, { capture: true, passive: true });

  function playingVideo() {
    if (document.visibilityState !== "visible") return false;
    return Array.from(document.querySelectorAll("video")).some(video => {
      const rect = video.getBoundingClientRect();
      const style = getComputedStyle(video);
      const visible = (video.checkVisibility?.({ opacityProperty: true, visibilityProperty: true }) ?? true)
        && rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.bottom > 0
        && rect.left < innerWidth && rect.top < innerHeight && style.visibility === "visible"
        && Number(style.opacity) > 0;
      if (!visible || video.paused || video.ended || video.seeking || video.readyState < 3 || video.playbackRate <= 0) {
        playback.delete(video);
        return false;
      }
      const now = performance.now();
      const last = playback.get(video);
      const advanced = last && video.currentTime > last.time;
      const advancedAt = advanced ? now : last?.advancedAt;
      playback.set(video, { time: video.currentTime, advancedAt });
      return advancedAt !== undefined && now - advancedAt < 1500;
    });
  }

  for (const type of ["play", "playing", "pause", "ended", "waiting", "seeking", "visibilitychange"]) {
    addEventListener(type, () => {
      if (type === "visibilitychange" || watchingVideo || type === "playing") notify();
    }, true);
  }

  chrome.runtime.onMessage.addListener((message, sender, reply) => {
    if (sender.id !== chrome.runtime.id || message.type !== "snapshot") return;
    if (document.visibilityState !== "visible") {
      reply(null);
      return;
    }
    syncPath();
    const host = location.hostname.toLowerCase();
    const videoPlaying = playingVideo();
    watchingVideo = videoPlaying;
    if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/.test(host) || new TextEncoder().encode(path).length > 2048) {
      reply(null);
      return;
    }
    reply({ document: documentID, host, path, readingAt, interactionAt, videoPlaying });
  });
  notify("page-ready");
})();
