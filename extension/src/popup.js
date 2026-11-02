const browserAPI = typeof browser !== "undefined" ? browser : chrome;
const $ = (id) => document.getElementById(id);
const send = (msg) => browserAPI.runtime.sendMessage(msg);

const COLORS = {
  blue: "#3378f5", orange: "#f58f24", green: "#33ad61", purple: "#9461e6",
  teal: "#1f9fad", red: "#e64d4d", pink: "#eb66a3", grey: "#858a99",
};
const TILE_COLORS = Object.values(COLORS);
const tileColor = (s) => TILE_COLORS[[...s].reduce((a, c) => a + c.charCodeAt(0), 0) % TILE_COLORS.length];

const ICON = {
  user: '<svg viewBox="0 0 24 24"><circle cx="12" cy="8" r="4"/><path d="M4 20c1.5-3.5 4.5-5 8-5s6.5 1.5 8 5"/></svg>',
  key: '<svg viewBox="0 0 24 24"><circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M16 7l3 3"/></svg>',
  code: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/></svg>',
  chev: '<svg viewBox="0 0 24 24"><path d="m9 6 6 6-6 6"/></svg>',
  check: '<svg viewBox="0 0 24 24"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>',
  warn: '<svg viewBox="0 0 24 24"><path d="M12 4 3 20h18L12 4Z"/><path d="M12 10v4M12 17h.01"/></svg>',
  sync: '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 0 1-13.7 5.6L4 15.3M4 12a8 8 0 0 1 13.7-5.6L20 8.7"/><path d="M4 20v-4.7h4.7M20 4v4.7h-4.7"/></svg>',
  off: '<svg viewBox="0 0 24 24"><path d="M17.5 18H7a4 4 0 0 1-.6-7.96A5.5 5.5 0 0 1 17 8.5a4.75 4.75 0 0 1 .5 9.5Z"/><path d="m4 4 16 16"/></svg>',
};

let info = null;
let tabHost = "";
let siteItems = [];
let toastTimer = 0;
let searchTimer = 0;
let searchSeq = 0;

function toast(text, bad = false) {
  const t = $("toast");
  t.textContent = text;
  t.className = "toast" + (bad ? " bad" : "");
  t.hidden = !text;
  clearTimeout(toastTimer);
  if (text) toastTimer = setTimeout(() => { t.hidden = true; }, bad ? 5000 : 2600);
}

const MESSAGES = {
  origin_mismatch: "This login doesn’t match the page.",
  no_code: "This item has no one-time code.",
  no_username: "This item has no username.",
  no_password: "This item has no password.",
  no_content_script: "Reload the page, then try again.",
  no_tab: "No page to fill.",
  timeout: "Satchel didn’t answer in time.",
};
const explain = (e) => MESSAGES[e] || "Something went wrong (" + e + ").";

function ago(seconds) {
  const d = Math.max(0, Date.now() / 1000 - seconds);
  if (d < 5) return "just now";
  if (d < 60) return Math.floor(d) + " seconds ago";
  if (d < 3600) { const m = Math.floor(d / 60); return m + (m === 1 ? " minute ago" : " minutes ago"); }
  if (d < 86400) { const h = Math.floor(d / 3600); return h + (h === 1 ? " hour ago" : " hours ago"); }
  const n = Math.floor(d / 86400);
  return n + (n === 1 ? " day ago" : " days ago");
}

function paintHeader(state) {
  const w = info ? info.workspace : "Satchel";
  $("ws").textContent = w || "Satchel";
  const av = $("avatar");
  av.textContent = (w || "S").trim().slice(0, 1).toUpperCase() || "S";
  av.style.background = (info && COLORS[info.workspaceColor]) || COLORS.blue;
  $("pip").className = "pip " + (state === "ok" ? "ok" : state === "locked" ? "locked" : "off");
  $("stateText").textContent = state === "ok" ? "Unlocked" : state === "locked" ? "Locked" : "Not running";
}

function show(state) {
  $("locked").hidden = state !== "locked";
  $("offline").hidden = state !== "offline";
  $("unlocked").hidden = state !== "ok";
  $("foot").hidden = state === "offline";
  $("lock").hidden = state !== "ok";
  $("sync").hidden = state === "locked"; // the app drops its sync state while locked
  paintHeader(state);
}

function paintFooter() {
  const s = info && info.sync ? info.sync : { state: "off" };
  const ico = $("syncIco");
  const t = $("syncT");
  const sub = $("syncS");
  ico.className = "ico";
  if (s.state === "off") {
    ico.innerHTML = ICON.off;
    t.textContent = "Sync is off";
    sub.textContent = "This vault stays on this Mac";
  } else if (s.state === "syncing") {
    ico.innerHTML = ICON.sync;
    t.textContent = "Syncing…";
    sub.textContent = s.backend || "";
  } else if (s.state === "error") {
    ico.className = "ico bad";
    ico.innerHTML = ICON.warn;
    t.textContent = "Sync needs attention";
    sub.textContent = s.error || "Open settings to fix it";
  } else {
    ico.className = "ico ok";
    ico.innerHTML = ICON.check;
    t.textContent = "Secure sync";
    sub.textContent = (s.last ? "Last synced " + ago(s.last) : "Waiting for the first sync") + (s.backend ? " · " + s.backend : "");
  }
  const n = info && info.items != null ? info.items : null;
  $("count").textContent = n == null ? "" : n + (n === 1 ? " item" : " items") + (info.localOnly ? " · " + info.localOnly + " kept local" : "");

  const rot = info && info.rotate ? info.rotate : 0;
  $("health").hidden = rot === 0;
  if (rot) {
    $("rotateT").textContent = rot + (rot === 1 ? " password to rotate" : " passwords to rotate");
    $("rotateS").textContent = (info.rotateTitles || []).join(", ") + (rot > (info.rotateTitles || []).length ? "…" : "");
  }
}

function actBtn(icon, label, fn) {
  const b = document.createElement("button");
  b.className = "act";
  b.title = label;
  b.setAttribute("aria-label", label);
  b.innerHTML = ICON[icon];
  b.addEventListener("click", (e) => { e.stopPropagation(); fn(); });
  return b;
}

async function copy(itemID, field, done) {
  const r = await send({ type: "copy", itemID, field });
  if (r && r.ok && !r.locked) toast(done);
  else if (r && r.locked) await refresh();
  else toast(explain(r && r.error), true);
}

async function copyCode(itemID) {
  const c = await send({ type: "code", itemID });
  if (!c || !c.ok || !c.code) { toast(explain(c && c.error), true); return; }
  await send({ type: "copy", itemID, field: "totp" });
  toast("Code " + c.code.replace(/(\d{3})(?=\d)/, "$1 ") + " copied · valid " + (c.remaining || 0) + " s");
}

function row(it, mode) {
  const el = document.createElement("div");
  el.className = "cred";
  el.tabIndex = 0;
  el.setAttribute("role", "button");

  const tile = document.createElement("div");
  tile.className = "tile";
  tile.textContent = (it.title || "?").trim().slice(0, 1).toUpperCase();
  tile.style.background = tileColor(it.title || "?");

  const txt = document.createElement("div");
  txt.className = "txt";
  const t = document.createElement("span");
  t.className = "t";
  t.textContent = it.title;
  if (it.favorite) { const st = document.createElement("span"); st.className = "star"; st.textContent = "★"; t.appendChild(st); }
  const s = document.createElement("span");
  s.className = "s";
  s.textContent = [it.username, it.host || it.category].filter(Boolean).join(" · ");
  txt.append(t, s);

  const acts = document.createElement("div");
  acts.className = "acts";
  if (it.username) acts.appendChild(actBtn("user", "Copy username", () => copy(it.id, "username", "Username copied")));
  acts.appendChild(actBtn("key", "Copy password", () => copy(it.id, "password", "Password copied")));
  acts.appendChild(actBtn("code", "Copy one-time code", () => copyCode(it.id)));

  const chev = document.createElement("span");
  chev.className = "chev";
  chev.innerHTML = ICON.chev;

  el.append(tile, txt, acts, chev);
  const go = mode === "site" ? () => fill(it) : () => copy(it.id, "password", "Password copied");
  el.addEventListener("click", go);
  el.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go(); } });
  return el;
}

async function fill(it) {
  const f = await send({ type: "popup-fill", itemID: it.id });
  if (f && f.ok) window.close();
  else toast(explain(f && f.error), true);
}

function paintSite() {
  const box = $("site");
  box.replaceChildren(...siteItems.map((it) => row(it, "site")));
  box.hidden = siteItems.length === 0;
  $("none").hidden = siteItems.length > 0 || !tabHost;
  $("noneHost").textContent = tabHost;
  $("siteBlock").hidden = !tabHost;
  $("siteTitle").textContent = siteItems.length > 1 ? "Logins for this site" : siteItems.length ? "Login for this site" : "This site";
}

async function refresh() {
  let r = await send({ type: "match" });
  if (r && !r.ok && r.error === "no_top_frame") { tabHost = ""; r = await send({ type: "status" }); }
  else if (r && r.ok) tabHost = await hostOfActiveTab();
  if (!r || !r.ok) { info = null; show("offline"); return; }
  info = r.info || null;
  if (r.locked) { show("locked"); paintFooter(); return; }
  siteItems = r.items || [];
  show("ok");
  paintSite();
  paintFooter();
  $("actions").hidden = !tabHost;
}

async function hostOfActiveTab() {
  try {
    const [tab] = await browserAPI.tabs.query({ active: true, currentWindow: true });
    return tab && tab.url && /^https?:/.test(tab.url) ? new URL(tab.url).hostname.replace(/^www\./, "") : "";
  } catch { return ""; }
}

// search ---------------------------------------------------------------------------------------
function onSearch() {
  clearTimeout(searchTimer);
  const q = $("q").value.trim();
  if (!q) { $("resultsBlock").hidden = true; $("siteBlock").hidden = !tabHost; $("actions").hidden = !tabHost; paintFooter(); return; }
  searchTimer = setTimeout(async () => {
    const seq = ++searchSeq;
    const r = await send({ type: "search", query: q, limit: 8 });
    if (seq !== searchSeq) return;
    if (!r || !r.ok) return;
    if (r.locked) { await refresh(); return; }
    const items = r.items || [];
    $("results").replaceChildren(...items.map((it) => row(it, "result")));
    $("results").hidden = items.length === 0;
    $("noResults").hidden = items.length > 0;
    $("resultsBlock").hidden = false;
    $("siteBlock").hidden = true;
    $("actions").hidden = true;
    $("health").hidden = true;
    select(0);
  }, 110);
}

function visibleRows() { return [...document.querySelectorAll("#unlocked .cred")].filter((r) => r.offsetParent); }
function select(i) {
  const rows = visibleRows();
  rows.forEach((r, n) => r.classList.toggle("sel", n === i));
  if (rows[i]) rows[i].scrollIntoView({ block: "nearest" });
}
function selected() { return visibleRows().findIndex((r) => r.classList.contains("sel")); }

document.addEventListener("keydown", (e) => {
  if ($("unlocked").hidden) return;
  const input = $("q");
  if (e.key === "/" && document.activeElement !== input) { e.preventDefault(); input.focus(); return; }
  const rows = visibleRows();
  if (e.key === "ArrowDown") { e.preventDefault(); select(Math.min(rows.length - 1, selected() + 1)); }
  else if (e.key === "ArrowUp") { e.preventDefault(); select(Math.max(0, selected() - 1)); }
  else if (e.key === "Enter" && document.activeElement === input) { const r = rows[Math.max(0, selected())]; if (r) r.click(); }
  else if (e.key === "Escape" && input.value) { input.value = ""; onSearch(); }
});
$("q").addEventListener("input", onSearch);

// buttons --------------------------------------------------------------------------------------
$("unlock").addEventListener("click", async () => {
  $("unlock").disabled = true;
  await send({ type: "unlock" });
  $("unlock").disabled = false;
  refresh();
});
$("retry").addEventListener("click", refresh);
$("open").addEventListener("click", () => { send({ type: "open" }); window.close(); });
$("lock").addEventListener("click", async () => { await send({ type: "lock" }); refresh(); });
$("rotate").addEventListener("click", () => { send({ type: "open" }); window.close(); });
$("sync").addEventListener("click", () => { send({ type: "open", target: "settings:sync" }); window.close(); });

$("save").addEventListener("click", async () => {
  const form = await send({ type: "read-form" });
  if (!form || !form.ok) { toast(form && form.error === "no_content_script" ? explain(form.error) : "Could not read the form on this page.", true); return; }
  if (!form.password) { toast("Type the password on the page first, then save.", true); return; }
  const r = await send({ type: "save", username: form.username, password: form.password, title: "" });
  if (r && r.ok && !r.locked) { toast("Saved to Satchel."); refresh(); }
  else if (r && r.locked) refresh();
  else toast("Save failed: " + (r && r.error), true);
});

$("generate").addEventListener("click", async () => {
  const r = await send({ type: "generate" });
  if (r && r.ok && !r.locked) toast("New password copied. It clears on the vault’s timer.");
  else if (r && r.locked) refresh();
  else toast("Satchel isn’t available.", true);
});

refresh();
