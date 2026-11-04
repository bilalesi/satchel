// Satchel content script: runs in the top frame only, finds login fields, shows matches
// under the focused field, fills on click. Never auto-fills, never submits.
(() => {
  if (window.top !== window) return; // no iframes: credentials go to the page the user sees
  const browserAPI = typeof browser !== "undefined" ? browser : chrome;

  const PASSWORD_SELECTOR = 'input[type="password"]:not([disabled])';
  // "Show password" turns the input into type=text (Google: name="Passwd"); it is still the password field.
  const REVEALED_SELECTOR = 'input[type="text"]:not([disabled]):is([autocomplete*="password"], [name*="pass" i], [id*="pass" i])';
  const USERNAME_SELECTOR = 'input:not([type]), input[type="text"], input[type="email"], input[type="tel"]';

  // The visible password field in scope: a masked one first, else a revealed one.
  function passwordFieldIn(scope) {
    return Array.from(scope.querySelectorAll(PASSWORD_SELECTOR)).find(visible)
      || Array.from(scope.querySelectorAll(REVEALED_SELECTOR)).find(visible) || null;
  }

  let dropdown = null;
  let activeField = null;

  function visible(el) {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== "hidden";
  }

  // Composed parent: crosses shadow roots so a login field inside a web component is walked too.
  const parentOf = (n) => n.parentElement || n.getRootNode().host || null;

  // A field may open the menu only when the user can see it: real size, no transparent or
  // hidden ancestor (opacity is not inherited, so the field itself may report 1), and nothing
  // drawn over its centre. Stops a page that focuses a 1×1 invisible input under the cursor.
  function exposed(el) {
    const r = el.getBoundingClientRect();
    if (r.width < 24 || r.height < 10) return false;
    for (let n = el; n && n !== document.documentElement; n = parentOf(n)) {
      const cs = getComputedStyle(n);
      if (cs.display === "none" || cs.visibility === "hidden" || parseFloat(cs.opacity) < 0.5) return false;
      // filter: opacity(0), a heavy blur or an SVG filter, a mask or a blend mode hide an element that
      // still takes hits. Other filters (drop-shadow, brightness, grayscale) leave it readable.
      if (/\b(opacity|blur|url)\(/.test(cs.filter) || (cs.maskImage || "none") !== "none" || cs.mixBlendMode !== "normal") return false;
    }
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    for (let n = el; n; n = parentOf(n)) if (n === hit) return true;
    return false;
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
    return passwordFieldIn(user.form || document);
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
    const anyPassword = passwordFieldIn(document);
    if (otp && !anyPassword && cred.totp) { setValue(otp, cred.totp); otp.focus(); return; }
    let pw = anchor && anchor.type === "password" ? anchor : (anchor ? passwordFieldFor(anchor) : null);
    if (!pw) pw = anyPassword;
    const user = pw ? usernameFieldFor(pw) : (anchor || null);
    if (user && cred.username) setValue(user, cred.username);
    if (pw) { setValue(pw, cred.password); pw.focus(); }
    else if (user && !cred.username) setValue(user, cred.password);
    if (otp && cred.totp) setValue(otp, cred.totp);
  }

  let watch = null;
  let seen = null;
  // IntersectionObserver v2 (Chromium): the menu is painted unoccluded, undistorted. true, false, or
  // undefined where unsupported (Firefox) — then the checks in intact() are all there is.
  let boxVisible;

  // The browser's compositor says whether anything — a page popover in its own shadow root, a
  // filter, a transform — hides the menu; the DOM checks in intact() cannot see all of those.
  // ponytail: the observer reports no sooner than `delay` after a change, so an overlay shown
  // under 100 ms before the user's press is not caught; the observer cannot run faster.
  function watchVisibility(box) {
    boxVisible = undefined;
    if (!("isVisible" in IntersectionObserverEntry.prototype)) return;
    seen = new IntersectionObserver((entries) => {
      for (const e of entries) { boxVisible = e.isVisible; if (!e.isVisible) closeDropdown(); }
    }, { trackVisibility: true, delay: 100 });
    seen.observe(box);
  }

  function closeDropdown() {
    if (seen) { seen.disconnect(); seen = null; }
    if (watch) { watch.disconnect(); watch = null; }
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
    // The menu must sit in the top layer, where page content and ancestor styles cannot cover or
    // fade it. Without popovers (Firefox < 125) there is no in-page menu; the toolbar popup still fills.
    if (!("showPopover" in HTMLElement.prototype)) return;
    activeField = field;
    const host = document.createElement("div");
    // Inline !important beats any page stylesheet, so the page cannot fade, clip or move the
    // menu while it still takes clicks; a page script changing these attributes closes it (see watch).
    host.style.cssText = "all:initial!important;position:fixed!important;inset:0!important;width:0!important;height:0!important;" +
      "margin:0!important;padding:0!important;border:0!important;background:none!important;overflow:visible!important;" +
      "display:block!important;opacity:1!important;visibility:visible!important;pointer-events:auto!important;" +
      "transform:none!important;filter:none!important;clip-path:none!important;mask:none!important;";
    host.popover = "manual";
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
      b.addEventListener("mousedown", (e) => { if (!e.isTrusted) return; e.preventDefault(); browserAPI.runtime.sendMessage({ type: "unlock" }).then(() => refresh(field)); });
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
        row.addEventListener("mousedown", (e) => {
          // A real press, and the menu is what is under the pointer (the closed shadow root reports its host).
          if (!e.isTrusted || e.button !== 0) return;
          e.preventDefault();
          if (document.elementFromPoint(e.clientX, e.clientY) === host) pick(it.id, field);
        });
        row.addEventListener("mousemove", () => select(i));
        box.appendChild(row);
        rows.push({ el: row, id: it.id });
      });
      const foot = document.createElement("div");
      foot.className = "foot";
      const kbd = (k) => { const e = document.createElement("kbd"); e.textContent = k; return e; };
      const keys = document.createElement("span");
      keys.append(kbd("↑"), " ", kbd("↓"), " ", kbd("↵"));
      const esc = document.createElement("span");
      esc.append(kbd("Esc"), " closes");
      foot.append(keys, esc);
      box.appendChild(foot);
    }
    root.appendChild(style);
    root.appendChild(box);
    document.documentElement.appendChild(host);
    try { host.showPopover(); } catch {}
    dropdown = host;
    if (!host.matches(":popover-open")) { closeDropdown(); return; }
    // The page shares this DOM node: any change to its attributes (style, popover, …) is tampering.
    // Observer callbacks run as microtasks, so a page pointerdown handler that restores the style
    // still closes the menu before the mousedown that would pick.
    watch = new MutationObserver(closeDropdown);
    watch.observe(host, { attributes: true });
    watchVisibility(box);
  }

  // Checked right before a fill: the menu is ours, still open in the top layer, fully opaque,
  // and nothing the page put in the top layer after it can sit on top of it.
  function intact() {
    const host = dropdown;
    if (!host || !host.isConnected || !host.matches(":popover-open") || boxVisible === false) return false;
    const cs = getComputedStyle(host);
    if (cs.opacity !== "1" || cs.visibility !== "visible" || cs.filter !== "none" || cs.mixBlendMode !== "normal") return false;
    // ponytail: a top-layer element inside the page's own shadow root is not seen here; IntersectionObserver v2
    // (trackVisibility, Chromium only) would catch it if that ever matters.
    if (document.fullscreenElement) return false;
    return [...document.querySelectorAll(":popover-open, :modal")].every((n) => n === host);
  }

  async function pick(itemID, field) {
    if (!intact()) { closeDropdown(); return; }
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
    if (!(el instanceof HTMLInputElement) || !exposed(el)) return false;
    if (el.type === "password") return true;
    if (el.matches(OTP_SELECTOR)) return true;
    return el.matches(USERNAME_SELECTOR) && passwordFieldFor(el) !== null;
  }

  // Only real user input may open the dropdown or trigger a fill. isTrusted alone is not
  // enough: element.focus() from a page script fires a *trusted* focusin, so the field must
  // also be the one the user pressed, or focus must follow a Tab the user just pressed.
  let armed = null;
  let tabAt = -1;
  document.addEventListener("pointerdown", (e) => { if (e.isTrusted) armed = e.target; }, true);
  document.addEventListener("focusin", (e) => {
    if (!e.isTrusted) return;
    const byUser = e.target === armed || e.timeStamp - tabAt < 300;
    armed = null;
    if (!byUser) return;
    closeDropdown(); // the previous field's menu may cover this field, which would fail its exposure test
    if (isLoginField(e.target)) refresh(e.target);
  }, true);
  // Close when focus has really left: moving to another login field opens its own menu
  // before this timer fires, and that menu must stay.
  document.addEventListener("focusout", () => {
    setTimeout(() => { if (document.activeElement !== activeField) closeDropdown(); }, 150);
  }, true);
  // Arrow keys walk the list while it is open. Enter picks only after an arrow key (or Alt+Enter),
  // so typing a username and pressing Enter to submit the form still works.
  document.addEventListener("keydown", (e) => {
    if (!e.isTrusted) return;
    if (e.key === "Tab") tabAt = e.timeStamp;
    if (!dropdown) return;
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
      const pw = passwordFieldIn(document);
      const user = pw ? usernameFieldFor(pw) : null;
      sendResponse({ ok: true, username: user ? user.value : "", password: pw ? pw.value : "", title: document.title });
    }
    return false;
  });
})();
