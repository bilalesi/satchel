// Satchel content script: runs in the top frame only, finds login fields, shows matches
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

  const OTP_SELECTOR = 'input[autocomplete="one-time-code"], input[name*="otp" i], input[id*="otp" i], input[name*="totp" i], input[name*="2fa" i], input[id*="2fa" i], input[name*="verification" i], input[name*="code" i][maxlength="6"]';

  function fillCredential(cred, anchor) {
    // A page that only shows a one-time-code field (second step of a login) gets the code.
    const otp = Array.from(document.querySelectorAll(OTP_SELECTOR)).find(visible) || null;
    const anyPassword = Array.from(document.querySelectorAll(PASSWORD_SELECTOR)).find(visible) || null;
    if (otp && !anyPassword && cred.totp) { setValue(otp, cred.totp); otp.focus(); return; }
    let pw = anchor && anchor.type === "password" ? anchor : (anchor ? passwordFieldFor(anchor) : null);
    if (!pw) pw = anyPassword;
    const user = pw ? usernameFieldFor(pw) : (anchor || null);
    if (user && cred.username) setValue(user, cred.username);
    if (pw) { setValue(pw, cred.password); pw.focus(); }
    else if (user && !cred.username) setValue(user, cred.password);
    if (otp && cred.totp) setValue(otp, cred.totp);
  }

  function closeDropdown() {
    if (dropdown) { dropdown.remove(); dropdown = null; }
    activeField = null;
    navigated = false;
  }

  const TILES = ["#3378f5", "#f58f24", "#33ad61", "#9461e6", "#1f9fad", "#e64d4d", "#eb66a3", "#858a99"];
  const tileFor = (t) => TILES[[...t].reduce((a, c) => a + c.charCodeAt(0), 0) % TILES.length];
  let rows = [];
  let selIndex = 0;
  let navigated = false;

  function select(i) {
    if (!rows.length) return;
    selIndex = (i + rows.length) % rows.length;
    rows.forEach((r, n) => r.el.classList.toggle("sel", n === selIndex));
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
      :host { all: initial; }
      .box { position: fixed; z-index: 2147483647; left: ${Math.round(r.left)}px; top: ${Math.round(r.bottom + 6)}px;
             min-width: ${Math.max(280, Math.round(r.width))}px; max-width: 380px; padding: 6px;
             background: #fff; color: #15171a; border: 1px solid rgba(20,24,30,.08); border-radius: 20px;
             box-shadow: 0 12px 32px rgba(20,24,30,.18), 0 2px 6px rgba(20,24,30,.08);
             font: 13px/1.35 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
      @media (prefers-color-scheme: dark) { .box { background: #232427; color: #f1f2f4; border-color: rgba(255,255,255,.1); box-shadow: 0 12px 32px rgba(0,0,0,.5); } }
      .head { padding: 4px 8px 6px; font-size: 11px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: #8a9099; }
      .row { display: flex; align-items: center; gap: 10px; padding: 8px 12px 8px 8px; border-radius: 999px; cursor: pointer; }
      .row:hover, .row.sel { background: rgba(20,24,30,.06); }
      @media (prefers-color-scheme: dark) { .row:hover, .row.sel { background: rgba(255,255,255,.08); } }
      .tile { width: 30px; height: 30px; border-radius: 50%; color: #fff; display: grid; place-items: center; font-weight: 700; font-size: 13px; flex: none; }
      .txt { min-width: 0; flex: 1; }
      .t { font-weight: 600; font-size: 13.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .s { color: #5d636b; font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      @media (prefers-color-scheme: dark) { .s { color: #a4a9b1; } }
      .fill { flex: none; font-size: 11px; font-weight: 600; color: #3378f5; opacity: 0; }
      .row:hover .fill, .row.sel .fill { opacity: 1; }
      .foot { display: flex; justify-content: space-between; padding: 6px 8px 2px; margin-top: 4px; border-top: 1px solid rgba(20,24,30,.07); font-size: 11px; color: #8a9099; }
      @media (prefers-color-scheme: dark) { .foot { border-color: rgba(255,255,255,.08); } }
      kbd { font: 10.5px ui-monospace, Menlo, monospace; padding: 0 4px; border: 1px solid rgba(128,128,128,.35); border-radius: 999px; }
      .lock { padding: 10px 14px; cursor: pointer; border-radius: 999px; font-weight: 600; color: #3378f5; }
      .lock:hover { background: rgba(51,120,245,.1); }
    `;
    const box = document.createElement("div");
    box.className = "box";
    const head = document.createElement("div");
    head.className = "head";
    head.textContent = "Satchel";
    box.appendChild(head);
    rows = [];
    selIndex = 0;
    if (locked) {
      const b = document.createElement("div");
      b.className = "lock";
      b.textContent = "Unlock Satchel to fill…";
      b.addEventListener("mousedown", (e) => { e.preventDefault(); browserAPI.runtime.sendMessage({ type: "unlock" }).then(() => refresh(field)); });
      box.appendChild(b);
    } else {
      items.forEach((it, i) => {
        const row = document.createElement("div");
        row.className = "row" + (i === 0 ? " sel" : "");
        const tile = document.createElement("div");
        tile.className = "tile";
        tile.textContent = (it.title || "?").trim().slice(0, 1).toUpperCase();
        tile.style.background = tileFor(it.title || "?");
        const txt = document.createElement("div");
        txt.className = "txt";
        const t = document.createElement("div");
        t.className = "t";
        t.textContent = it.title;
        const s = document.createElement("div");
        s.className = "s";
        s.textContent = [it.username, it.host].filter(Boolean).join(" · ");
        txt.append(t, s);
        const fill = document.createElement("span");
        fill.className = "fill";
        fill.textContent = "Fill";
        row.append(tile, txt, fill);
        row.addEventListener("mousedown", (e) => { e.preventDefault(); pick(it.id, field); });
        row.addEventListener("mousemove", () => select(i));
        box.appendChild(row);
        rows.push({ el: row, id: it.id });
      });
      const foot = document.createElement("div");
      foot.className = "foot";
      foot.innerHTML = "<span><kbd>↑</kbd> <kbd>↓</kbd> <kbd>↵</kbd></span><span><kbd>Esc</kbd> closes</span>";
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
    if (el.matches(OTP_SELECTOR)) return true;
    return el.matches(USERNAME_SELECTOR) && passwordFieldFor(el) !== null;
  }

  // Only real user input may open the dropdown or trigger a fill: a page script can
  // dispatch synthetic events, and those carry isTrusted === false.
  document.addEventListener("focusin", (e) => {
    if (!e.isTrusted) return;
    if (isLoginField(e.target)) refresh(e.target);
  }, true);
  document.addEventListener("focusout", () => { setTimeout(closeDropdown, 150); }, true);
  // Arrow keys walk the list while it is open. Enter picks only after an arrow key (or Alt+Enter),
  // so typing a username and pressing Enter to submit the form still works.
  document.addEventListener("keydown", (e) => {
    if (!e.isTrusted || !dropdown) return;
    if (e.key === "Escape") { closeDropdown(); return; }
    if (!rows.length) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      navigated = true;
      select(selIndex + (e.key === "ArrowDown" ? 1 : -1));
    } else if (e.key === "Enter" && (navigated || e.altKey)) {
      e.preventDefault();
      pick(rows[selIndex].id, activeField);
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
