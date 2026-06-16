// AI Detector companion — background service worker (MV3).
//
// A content script on an https page cannot POST to http://127.0.0.1 directly:
// it hits mixed-content blocking, Chrome's Private Network Access preflight, and
// CORS, and it has no host permission for the loopback address. The service
// worker does have the host permission and escapes the page's mixed-content
// rules, so ALL native I/O is relayed through here.
//
// The relay is deliberately stateless: the worker can be evicted when idle and
// cold-started on the next message, so everything it needs (the tab id, whether
// the tab is the active one) is derived from `sender` per message.

const NATIVE = "http://127.0.0.1:31337";
// Casual-abuse hardening only (any local process can reach the port). Must match
// ExtensionServer's expected token on the native side.
const TOKEN = "aicf-local-v1";

function post(path, body) {
  fetch(NATIVE + path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-AICF-Token": TOKEN },
    body: JSON.stringify(body),
  }).catch(() => { /* app not running — drop silently */ });
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  // layerKey ties a native overlay layer to this exact tab; the content script
  // cannot read its own tab id, so we stamp it here.
  const layerKey = sender.tab ? String(sender.tab.id) : "unknown";
  const focused = sender.tab ? !!sender.tab.active : false;

  switch (msg.type) {
    case "blocks":
      post("/blocks", {
        layerKey, focused,
        host: msg.host, url: msg.url,
        viewport: msg.viewport, blocks: msg.blocks,
      });
      break;
    case "clear":
      post("/clear", { layerKey, reason: msg.reason });
      break;
    case "fallback":
      post("/fallback", { layerKey, host: msg.host, reason: msg.reason });
      break;
    case "heartbeat":
      post("/heartbeat", { layerKey, focused, host: msg.host });
      break;
  }
  return false; // fire-and-forget; no async response
});

// Tab closed: backstop CLEAR (the content script's pagehide may not flush in time).
chrome.tabs.onRemoved.addListener((tabId) => {
  post("/clear", { layerKey: String(tabId), reason: "tab-closed" });
});
