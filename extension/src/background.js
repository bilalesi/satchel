// Satchel extension background: the only part that talks to the native host.
// Content scripts and the popup send messages here; the page's own URL claims are never
// trusted, only sender.tab.url from the browser, and only for the top frame.

const HOST = "com.bilalesi.satchel";
const browserAPI = typeof browser !== "undefined" ? browser : chrome;

let port = null;
let nextID = 1;
const pending = new Map(); // id → {resolve, reject, timer}

function connect() {
  if (port) return port;
  port = browserAPI.runtime.connectNative(HOST);
  port.onMessage.addListener((msg) => {
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    clearTimeout(p.timer);
    p.resolve(msg);
  });
  port.onDisconnect.addListener(() => {
    const err = browserAPI.runtime.lastError ? browserAPI.runtime.lastError.message : "host disconnected";
    port = null;
    for (const [, p] of pending) { clearTimeout(p.timer); p.resolve({ ok: false, error: "app_not_running", detail: err }); }
    pending.clear();
  });
  return port;
}

function call(type, fields = {}, timeoutMs = 20000) {
  return new Promise((resolve) => {
    const id = nextID++;
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ ok: false, error: "timeout" });
    }, timeoutMs);
    pending.set(id, { resolve, timer });
    try {
      connect().postMessage({ id, type, ...fields });
    } catch (e) {
      clearTimeout(timer);
      pending.delete(id);
      resolve({ ok: false, error: "app_not_running", detail: String(e) });
    }
  });
}

// Only the top frame of the sender's own tab may ask about or fill credentials.
function topFrameURL(sender) {
  if (!sender.tab || sender.frameId !== 0) return null;
  return sender.tab.url || null;
}

async function activeTabURL() {
  const [tab] = await browserAPI.tabs.query({ active: true, currentWindow: true });
  return tab ? { id: tab.id, url: tab.url } : { id: null, url: null };
}

browserAPI.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    switch (msg.type) {
      case "status":
        return call("status");
      case "unlock":
        return call("unlock", {}, 120000); // Touch ID prompt may take a while
      case "generate":
        return call("generate");
      case "open":
        return call("open", { target: msg.target });
      // The rest are for the popup only (no sender.tab): a page's content script never gets them.
      case "search":
      case "copy":
      case "code":
      case "lock":
        if (sender.tab) return { ok: false, error: "popup_only" };
        return call(msg.type, { query: msg.query, limit: msg.limit, itemID: msg.itemID, field: msg.field });
      case "match": {
        // From a content script: its own top-frame URL. From the popup: the active tab.
        const url = sender.tab ? topFrameURL(sender) : (await activeTabURL()).url;
        if (!url) return { ok: false, error: "no_top_frame" };
        return call("match", { url });
      }
      case "fill": {
        const url = sender.tab ? topFrameURL(sender) : (await activeTabURL()).url;
        if (!url) return { ok: false, error: "no_top_frame" };
        return call("fill", { url, itemID: msg.itemID });
      }
      case "save": {
        const url = sender.tab ? topFrameURL(sender) : (await activeTabURL()).url;
        if (!url) return { ok: false, error: "no_top_frame" };
        return call("save", { url, username: msg.username, password: msg.password, title: msg.title });
      }
      case "popup-fill": {
        // Popup asked to fill item X into the active tab's top frame.
        const tab = await activeTabURL();
        if (!tab.id || !tab.url) return { ok: false, error: "no_tab" };
        const r = await call("fill", { url: tab.url, itemID: msg.itemID });
        if (!r.ok || !r.credential) return r;
        await browserAPI.tabs.sendMessage(tab.id, { type: "fill-credential", credential: r.credential }, { frameId: 0 });
        return { ok: true };
      }
      case "read-form": {
        const tab = await activeTabURL();
        if (!tab.id) return { ok: false, error: "no_tab" };
        try { return await browserAPI.tabs.sendMessage(tab.id, { type: "read-form" }, { frameId: 0 }); }
        catch (e) { return { ok: false, error: "no_content_script" }; }
      }
      default:
        return { ok: false, error: "unknown_message" };
    }
  })().then(sendResponse, (e) => sendResponse({ ok: false, error: String(e) }));
  return true; // async response
});

// ⌘⇧L: fill the best match into the active tab.
browserAPI.commands.onCommand.addListener(async (command) => {
  if (command !== "fill-first") return;
  const tab = await activeTabURL();
  if (!tab.id || !tab.url) return;
  const m = await call("match", { url: tab.url });
  if (!m.ok || !m.items || m.items.length === 0) return;
  const r = await call("fill", { url: tab.url, itemID: m.items[0].id });
  if (r.ok && r.credential) {
    browserAPI.tabs.sendMessage(tab.id, { type: "fill-credential", credential: r.credential }, { frameId: 0 }).catch(() => {});
  }
});
