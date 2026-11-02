const browserAPI = typeof browser !== "undefined" ? browser : chrome;
const $ = (id) => document.getElementById(id);

function send(msg) { return browserAPI.runtime.sendMessage(msg); }

function show(state) {
  $("locked").hidden = state !== "locked";
  $("offline").hidden = state !== "offline";
  $("matches").hidden = state !== "ok";
  $("dot").className = "dot " + (state === "ok" ? "ok" : state === "locked" ? "locked" : "off");
  $("status").textContent = state === "ok" ? "Unlocked" : state === "locked" ? "Locked" : "Not running";
}

function note(text) {
  const n = $("note");
  n.textContent = text;
  n.hidden = !text;
}

async function refresh() {
  const r = await send({ type: "match" });
  if (!r || !r.ok) { show("offline"); if (r && r.error === "no_top_frame") note("No page URL available for this tab."); return; }
  if (r.locked) { show("locked"); return; }
  show("ok");
  const list = $("list");
  list.innerHTML = "";
  const items = r.items || [];
  $("none").hidden = items.length > 0;
  for (const it of items) {
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `<div class="tile"></div><div><div class="t"></div><div class="s"></div></div><span class="fill">Fill</span>`;
    row.querySelector(".tile").textContent = (it.title || "?").slice(0, 1).toUpperCase();
    row.querySelector(".t").textContent = it.title;
    row.querySelector(".s").textContent = [it.username, it.host].filter(Boolean).join(" · ");
    row.addEventListener("click", async () => {
      const f = await send({ type: "popup-fill", itemID: it.id });
      if (f && f.ok) window.close(); else note(f && f.error === "origin_mismatch" ? "This item does not match the page." : "Could not fill: " + (f && f.error));
    });
    list.appendChild(row);
  }
}

$("unlock").addEventListener("click", async () => {
  $("unlock").disabled = true;
  await send({ type: "unlock" });
  $("unlock").disabled = false;
  refresh();
});

$("save").addEventListener("click", async () => {
  const form = await send({ type: "read-form" });
  if (!form || !form.ok) { note("Could not read the form on this page."); return; }
  if (!form.password) { note("Type the password on the page first, then click Save."); return; }
  const r = await send({ type: "save", username: form.username, password: form.password, title: "" });
  if (r && r.ok && !r.locked) { note("Saved to Satchel."); refresh(); }
  else if (r && r.locked) { show("locked"); }
  else note("Save failed: " + (r && r.error));
});

$("generate").addEventListener("click", async () => {
  const r = await send({ type: "generate" });
  if (r && r.ok && !r.locked) note("New password copied by Satchel; it clears after the vault's timer.");
  else if (r && r.locked) show("locked");
  else note("Satchel is not available.");
});

$("open").addEventListener("click", () => send({ type: "open" }));

refresh();
