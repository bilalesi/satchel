// Vault content script: runs in the top frame only, finds login fields, shows matches
// under the focused field, fills on click. Never auto-fills, never submits.
(() => {
  if (window.top !== window) return; // no iframes: credentials go to the page the user sees
  const browserAPI = typeof browser !== "undefined" ? browser : chrome;

  const PASSWORD_SELECTOR = 'input[type="password"]:not([disabled])';
  const USERNAME_SELECTOR = 'input:not([type]), input[type="text"], input[type="email"], input[type="tel"]';

  let dropdown = null;
  let activeField = null;

  function visible(el) {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== "hidden";
  }

  // Username = nearest visible text/email input before the password field in DOM order,
  // preferring the same form; falls back to autocomplete="username".
  function usernameFieldFor(pw) {
    const scope = pw.form || document;
    const named = scope.querySelector('input[autocomplete="username"], input[autocomplete="email"], input[name*="user" i], input[name*="email" i], input[id*="user" i], input[id*="email" i]');
    if (named && named !== pw && visible(named)) return named;
    const all = Array.from(scope.querySelectorAll(USERNAME_SELECTOR)).filter(visible);
    let best = null;
    for (const el of all) {
      if (el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) best = el;
    }
    return best;
  }

  function passwordFieldFor(user) {
    const scope = user.form || document;
    return Array.from(scope.querySelectorAll(PASSWORD_SELECTOR)).find(visible) || null;
  }

  // React/Vue track the native setter; dispatching input/change makes frameworks notice.
  function setValue(el, value) {
    const proto = Object.getPrototypeOf(el);
    const desc = Object.getOwnPropertyDescriptor(proto, "value") || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");
    if (desc && desc.set) desc.set.call(el, value); else el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function fillCredential(cred, anchor) {
    let pw = anchor && anchor.type === "password" ? anchor : (anchor ? passwordFieldFor(anchor) : null);
    if (!pw) pw = Array.from(document.querySelectorAll(PASSWORD_SELECTOR)).find(visible) || null;
    const user = pw ? usernameFieldFor(pw) : (anchor || null);
    if (user && cred.username) setValue(user, cred.username);
    if (pw) { setValue(pw, cred.password); pw.focus(); }
    else if (user && !cred.username) setValue(user, cred.password);
  }

  function closeDropdown() {
    if (dropdown) { dropdown.remove(); dropdown = null; }
    activeField = null;
  }

  function showDropdown(field, items, locked) {
    closeDropdown();
    activeField = field;
    const host = document.createElement("div");
    host.setAttribute("data-vault-dropdown", "");
    const root = host.attachShadow({ mode: "closed" });
    const r = field.getBoundingClientRect();
    const style = document.createElement("style");
    style.textContent = `
      .box { position: fixed; z-index: 2147483647; left: ${Math.round(r.left)}px; top: ${Math.round(r.bottom + 4)}px;
             min-width: ${Math.max(260, Math.round(r.width))}px; max-width: 360px; background: #fff; color: #111;
             border: 1px solid rgba(0,0,0,.1); border-radius: 12px; box-shadow: 0 8px 28px rgba(0,0,0,.14);
             font: 13px -apple-system, system-ui, sans-serif; overflow: hidden; }
      @media (prefers-color-scheme: dark) { .box { background: #1e1e20; color: #eee; border-color: rgba(255,255,255,.1); } }
      .row { display: flex; align-items: center; gap: 10px; padding: 8px 12px; cursor: pointer; }
      .row:hover, .row.sel { background: rgba(32,120,245,.12); }
      .tile { width: 24px; height: 24px; border-radius: 7px; background: #3378f5; color: #fff; display: grid; place-items: center; font-weight: 700; font-size: 12px; flex: none; }
      .t { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .s { opacity: .6; font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .foot { padding: 6px 12px; font-size: 11px; opacity: .55; border-top: 1px solid rgba(0,0,0,.06); display: flex; justify-content: space-between; }
      .btn { padding: 10px 12px; cursor: pointer; font-weight: 600; color: #3378f5; }
    `;
    const box = document.createElement("div");
    box.className = "box";
    if (locked) {
      const b = document.createElement("div");
      b.className = "btn";
      b.textContent = "Unlock Vault to fill…";
      b.addEventListener("mousedown", (e) => { e.preventDefault(); browserAPI.runtime.sendMessage({ type: "unlock" }).then(() => refresh(field)); });
      box.appendChild(b);
    } else {
      items.forEach((it, i) => {
        const row = document.createElement("div");
        row.className = "row" + (i === 0 ? " sel" : "");
        row.innerHTML = `<div class="tile">${(it.title || "?").slice(0, 1).toUpperCase()}</div><div><div class="t"></div><div class="s"></div></div>`;
        row.querySelector(".t").textContent = it.title;
        row.querySelector(".s").textContent = [it.username, it.host].filter(Boolean).join(" · ");
        row.addEventListener("mousedown", (e) => { e.preventDefault(); pick(it.id, field); });
        box.appendChild(row);
      });
      const foot = document.createElement("div");
      foot.className = "foot";
      foot.innerHTML = "<span>Vault</span><span>⌘⇧L fills the first</span>";
      box.appendChild(foot);
    }
    root.appendChild(style);
    root.appendChild(box);
    document.documentElement.appendChild(host);
    dropdown = host;
  }

  async function pick(itemID, field) {
    const r = await browserAPI.runtime.sendMessage({ type: "fill", itemID });
    closeDropdown();
    if (r && r.ok && r.credential) fillCredential(r.credential, field);
  }

  async function refresh(field) {
    const r = await browserAPI.runtime.sendMessage({ type: "match" });
    if (!r || !r.ok) { closeDropdown(); return; }
    if (r.locked) { showDropdown(field, [], true); return; }
    if (!r.items || r.items.length === 0) { closeDropdown(); return; }
    showDropdown(field, r.items, false);
  }

  function isLoginField(el) {
    if (!(el instanceof HTMLInputElement) || !visible(el)) return false;
    if (el.type === "password") return true;
    return el.matches(USERNAME_SELECTOR) && passwordFieldFor(el) !== null;
  }

  document.addEventListener("focusin", (e) => {
    if (isLoginField(e.target)) refresh(e.target);
  }, true);
  document.addEventListener("focusout", () => { setTimeout(closeDropdown, 150); }, true);
  document.addEventListener("keydown", (e) => {
    if (!dropdown) return;
    if (e.key === "Escape") { closeDropdown(); return; }
    if (e.key === "Enter" && e.altKey) {
      e.preventDefault();
      const first = dropdown.shadowRoot ? null : null; // shadow root is closed; re-query via message
      browserAPI.runtime.sendMessage({ type: "match" }).then((r) => { if (r && r.ok && r.items && r.items[0]) pick(r.items[0].id, activeField); });
      void first;
    }
  }, true);
  window.addEventListener("scroll", closeDropdown, true);
  window.addEventListener("resize", closeDropdown);

  browserAPI.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg.type === "fill-credential") {
      fillCredential(msg.credential, document.activeElement instanceof HTMLInputElement ? document.activeElement : null);
      sendResponse({ ok: true });
    } else if (msg.type === "read-form") {
      const pw = Array.from(document.querySelectorAll(PASSWORD_SELECTOR)).find(visible);
      const user = pw ? usernameFieldFor(pw) : null;
      sendResponse({ ok: true, username: user ? user.value : "", password: pw ? pw.value : "", title: document.title });
    }
    return false;
  });
})();
