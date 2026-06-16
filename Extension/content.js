// AI Detector companion — DOM text source.
//
// This script is the BROWSER text source for the native macOS app. It never
// mutates the page and never draws anything (highlighting stays 100% native).
// Each coalesced tick it walks the visible DOM for paragraph-grained text,
// attaches each block's viewport rect (getBoundingClientRect, CSS px), and
// relays the batch to the background service worker, which forwards it to the
// native app on 127.0.0.1:31337. The native side maps the viewport rects to
// screen coordinates (via the page's AXWebArea frame) and paints the overlay.
//
// Why this exists: reading web text through Accessibility is slow (Chromium
// builds its a11y tree lazily, costing a ~2s nudge+retry before the first
// highlight) and gives the native overlay no signal when a tab switches or the
// page navigates, so highlights go stale. Feeding the DOM directly is instant
// and lets us send an explicit CLEAR the moment the content under a highlight
// goes away (tab hidden, page unload, SPA route change).
(() => {
  "use strict";

  const MIN_CHARS = 24;        // per-block floor; the native model does the real cut
  const MIN_PX = 8;            // ignore collapsed / hairline boxes
  const RECT_EPS = 2;          // px a rect must move before we re-push
  const HEARTBEAT_MS = 3000;   // keep the native AX-suppression gate warm

  // Elements that never hold readable prose, pruned as whole subtrees.
  const SKIP_TAGS = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "SVG", "CANVAS", "IFRAME", "TEXTAREA",
    "INPUT", "SELECT", "BUTTON", "CODE", "PRE", "FIGURE", "VIDEO", "AUDIO",
  ]);
  // Chrome / navigation regions whose text is not document content. NOTE: we
  // deliberately do NOT skip <header>/<aside>/[role=complementary] — those wrap
  // legitimate prose (standfirst, pull-quotes, sidebars of article text), and
  // excluding their whole subtree dropped real content.
  const SKIP_SEL =
    '[aria-hidden="true"],[hidden],nav,footer,' +
    '[role="navigation"],[role="banner"],[role="contentinfo"]';

  let lastIds = new Set();
  let lastRects = new Map();   // id -> {x,y,w,h}
  let rafPending = false;
  let idleTimer = 0;
  let seq = 0;
  let mode = "own";           // "own" = we feed this page; "fallback" = let native AX/OCR handle it
  let fellBackForRoute = "";
  let heartbeatPausedUntil = 0;   // suppress heartbeats briefly after a CLEAR

  // FNV-1a over normalized text → stable id (identical text ⇒ identical id, so
  // the native overlay repositions a panel in place instead of recreating it).
  function hashId(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = (h * 0x01000193) >>> 0;
    }
    return "b" + h.toString(36);
  }
  const norm = (s) => s.replace(/\s+/g, " ").trim();

  function isVisible(cs) {
    return !(
      cs.display === "none" ||
      cs.visibility === "hidden" ||
      cs.visibility === "collapse" ||
      parseFloat(cs.opacity) === 0
    );
  }
  function inViewport(r) {
    return (
      r.bottom > 0 && r.top < innerHeight &&
      r.right > 0 && r.left < innerWidth &&
      r.width >= MIN_PX && r.height >= MIN_PX
    );
  }
  // A block-level element that DIRECTLY owns visible text — paragraph grain,
  // not its wrapping container and not its inline children.
  function ownsText(el) {
    for (const n of el.childNodes) {
      if (n.nodeType === 3 && n.nodeValue.trim().length) return true;
    }
    return false;
  }

  function extract() {
    const blocks = [];
    const seen = new Set();
    const root = document.body;
    if (!root) return blocks;

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
      acceptNode(el) {
        if (SKIP_TAGS.has(el.tagName)) return NodeFilter.FILTER_REJECT; // prune subtree
        if (el.closest(SKIP_SEL)) return NodeFilter.FILTER_REJECT;
        const cs = getComputedStyle(el);
        if (!isVisible(cs)) return NodeFilter.FILTER_REJECT;            // display:none prunes subtree
        const d = cs.display;
        const blockish =
          d === "block" || d === "list-item" || d === "table-cell" || d === "flow-root";
        return blockish && ownsText(el)
          ? NodeFilter.FILTER_ACCEPT
          : NodeFilter.FILTER_SKIP;
      },
    });

    for (let el = walker.nextNode(); el; el = walker.nextNode()) {
      const r = el.getBoundingClientRect();
      if (!inViewport(r)) continue;
      // innerText (not textContent): respects visibility, and the rect/viewport
      // gate above already forced layout so this read is cheap.
      const text = norm(el.innerText || "");
      if (text.length < MIN_CHARS) continue;
      const id = hashId(text);
      if (seen.has(id)) continue;   // drop repeated boilerplate within one pass
      seen.add(id);
      blocks.push({
        id,
        text,
        rect: {
          x: +r.left.toFixed(1),
          y: +r.top.toFixed(1),
          w: +r.width.toFixed(1),
          h: +r.height.toFixed(1),
        },
      });
    }
    return blocks;
  }

  // Google Docs / Slides and other <canvas>-rendered editors paint glyphs to a
  // canvas, so the DOM has no laid-out paragraph text. We must NOT send an empty
  // payload there (that would tell native to clear and the page would show
  // nothing despite visible text). Instead, signal native to keep its own
  // Accessibility path for this surface.
  function isCanvasEditor() {
    if (document.querySelector(".kix-appview,.kix-page,.docs-texteventtarget-iframe")) {
      return true; // Google Docs
    }
    if (!document.querySelector("canvas")) return false;
    return norm(document.body ? document.body.innerText : "").length < 40;
  }

  // When the DOM walk yields nothing, decide between a genuinely empty page (send
  // [] so native clears) and content we can't reach (send a fallback so the
  // native AX/OCR path tries instead of blanking the page). The latter covers
  // canvas editors (Google Docs) and pages whose text lives in shadow DOM or
  // cross-origin iframes a light top-frame walk can't see.
  function shouldFallbackToAX() {
    if (isCanvasEditor()) return true;
    const bodyLen = document.body ? norm(document.body.innerText).length : 0;
    return bodyLen > 400;
  }

  function viewport() {
    return {
      innerWidth, innerHeight,
      outerWidth, outerHeight,
      screenX, screenY,          // window position; feeds the native screen-estimate fallback
      scrollX, scrollY,          // staleness only — rects are already viewport-relative
      dpr: devicePixelRatio,     // diagnostic only; NOT used in the native transform
      captureSeq: ++seq,
    };
  }

  function changed(blocks) {
    if (blocks.length !== lastIds.size) return true;
    for (const b of blocks) {
      if (!lastIds.has(b.id)) return true;
      const p = lastRects.get(b.id);
      if (!p ||
          Math.abs(p.x - b.rect.x) > RECT_EPS || Math.abs(p.y - b.rect.y) > RECT_EPS ||
          Math.abs(p.w - b.rect.w) > RECT_EPS || Math.abs(p.h - b.rect.h) > RECT_EPS) {
        return true;
      }
    }
    return false;
  }

  function send(msg) {
    // Swallow both a synchronous throw and a promise rejection (worker asleep /
    // app not running) so an unhandled rejection never surfaces on the page.
    try {
      const p = chrome.runtime.sendMessage(msg);
      if (p && p.catch) p.catch(() => {});
    } catch (_) { /* extension context gone */ }
  }

  function pushNow() {
    if (document.visibilityState !== "visible") return;
    if (checkRoute()) return;   // route changed: layer cleared + re-extract scheduled

    const blocks = extract();

    // Nothing extractable. If the page is a canvas editor or clearly has text the
    // light-DOM walk can't reach, hand back to native AX/OCR instead of blanking
    // it; otherwise fall through and send [] so native clears a genuinely empty page.
    if (blocks.length === 0 && shouldFallbackToAX()) {
      mode = "fallback";
      if (fellBackForRoute !== location.href) {
        fellBackForRoute = location.href;
        send({ type: "fallback", reason: "no-dom-text", host: location.hostname });
      }
      return;
    }
    mode = "own";

    if (!changed(blocks)) return;          // suppress redundant scroll/mutation spam
    lastIds = new Set(blocks.map((b) => b.id));
    lastRects = new Map(blocks.map((b) => [b.id, b.rect]));
    send({
      type: "blocks",
      host: location.hostname,
      url: location.href,
      viewport: viewport(),
      blocks,                              // may be [] → native clears the layer (legit empty page)
    });
  }

  // Coalesce every trigger into at most one push per animation frame, plus a
  // trailing flush once things settle.
  function schedule() {
    if (!rafPending) {
      rafPending = true;
      requestAnimationFrame(() => { rafPending = false; pushNow(); });
    }
    clearTimeout(idleTimer);
    idleTimer = setTimeout(pushNow, 120);
  }

  function clear(reason) {
    lastIds = new Set();
    lastRects.clear();
    // Don't let a heartbeat racing right behind this CLEAR re-warm the native
    // AX-suppression gate for a surface we just relinquished.
    heartbeatPausedUntil = Date.now() + 1500;
    send({ type: "clear", reason });
  }

  // ---- triggers ----
  addEventListener("scroll", schedule, { passive: true, capture: true });
  new ResizeObserver(schedule).observe(document.documentElement);
  new MutationObserver(() => {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(pushNow, 250);   // let DOM churn settle
  }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });

  // SPA navigation. A content script runs in an ISOLATED world, so it cannot
  // intercept the page's own history.pushState. But popstate/hashchange DO fire
  // here, and a pushState route change swaps DOM (firing our MutationObserver),
  // so we also detect href changes lazily on each tick (checkRoute, called at
  // the top of pushNow). The old layer is wrong the instant the route changes.
  let lastHref = location.href;
  function onRouteChange() {
    lastHref = location.href;
    fellBackForRoute = "";
    clear("route");
    setTimeout(pushNow, 300);   // re-extract once the new view paints
  }
  function checkRoute() {
    if (location.href !== lastHref) { onRouteChange(); return true; }
    return false;
  }
  addEventListener("popstate", checkRoute);
  addEventListener("hashchange", checkRoute);
  // Window regained focus (returned to this browser): re-post so the native
  // AX-suppression gate re-warms before the slow AX path can wake up.
  addEventListener("focus", schedule);

  // Tab backgrounded / page closing: clear this tab's highlights so they can't
  // float over whatever tab or app is now in front. This is the stale-highlight fix.
  addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") clear("hidden");
    else schedule();
  });
  addEventListener("pagehide", () => clear("unload"));
  addEventListener("beforeunload", () => clear("unload"));

  // Heartbeat: while we own a visible page, keep the native AX-suppression gate
  // warm even when nothing changes (a static covered page must not let the slow
  // AX path wake up and repaint). Skipped in fallback mode so canvas editors
  // hand back to native AX.
  setInterval(() => {
    if (mode === "own" && document.visibilityState === "visible" &&
        Date.now() >= heartbeatPausedUntil) {
      send({ type: "heartbeat", host: location.hostname });
    }
  }, HEARTBEAT_MS);

  pushNow(); // initial
})();
