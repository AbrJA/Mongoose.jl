const API     = "http://localhost:9000";
const WS_URL  = "ws://localhost:9000/ws/chat";
let   API_KEY    = "demo-key-1234";
let   BEARER_TOKEN = "";

function applyAuth() {
  API_KEY      = document.getElementById("apiKeyInput").value.trim();
  BEARER_TOKEN = document.getElementById("bearerInput").value.trim();
  const status = document.getElementById("apiKeyStatus");
  if (API_KEY && BEARER_TOKEN) {
    status.textContent = "key + bearer";
    status.className   = "badge badge-on";
  } else if (API_KEY) {
    status.textContent = "key: " + API_KEY;
    status.className   = "badge badge-on";
  } else if (BEARER_TOKEN) {
    status.textContent = "bearer set";
    status.className   = "badge badge-on";
  } else {
    status.textContent = "(none)";
    status.className   = "badge badge-off";
  }
}

// keep old name working just in case
const applyApiKey = applyAuth;

// ── Element refs ──────────────────────────────────────────────────────────
const pingOut     = () => document.getElementById("ping-output");
const restOut     = () => document.getElementById("rest-output");
const downloadOut = () => document.getElementById("download-output");
const wsOut       = () => document.getElementById("ws-output");
const wsStatus    = () => document.getElementById("ws-status");
const metricsOut  = () => document.getElementById("metrics-output");
const wsInput     = () => document.getElementById("ws-input");

let socket = null;

// ── Helpers ───────────────────────────────────────────────────────────────
async function apiFetch(path, opts = {}, outputEl = restOut()) {
  try {
    const authHeaders = {};
    if (API_KEY)      authHeaders["X-API-Key"]     = API_KEY;
    if (BEARER_TOKEN) authHeaders["Authorization"] = "Bearer " + BEARER_TOKEN;
    const res = await fetch(API + path, {
      headers: { "Content-Type": "application/json", ...authHeaders, ...opts.headers },
      ...opts,
    });
    const text = await res.text();
    let body;
    try { body = JSON.parse(text); } catch { body = text; }
    outputEl.textContent = `${res.status} ${res.statusText}\n\n${JSON.stringify(body, null, 2)}`;
    return res;
  } catch (e) {
    outputEl.textContent = "Network error: " + e.message;
  }
}

function log(el, msg) {
  el.textContent = msg + "\n" + el.textContent.slice(0, 4000);
}

function _authHeaders() {
  const h = {};
  if (API_KEY)      h["X-API-Key"]     = API_KEY;
  if (BEARER_TOKEN) h["Authorization"] = "Bearer " + BEARER_TOKEN;
  return h;
}

// ── Health & Ping ─────────────────────────────────────────────────────────
function ping()        { apiFetch("/api/ping",  {}, pingOut()); }
function checkHealth() {
  fetch(API + "/healthz")
    .then(r => r.text().then(t => pingOut().textContent = `${r.status}\n${t}`))
    .catch(e => pingOut().textContent = "Error: " + e.message);
}

// ── CRUD ──────────────────────────────────────────────────────────────────
function getUsers()          { apiFetch("/api/users"); }
function getUsersFiltered()  { apiFetch("/api/users?role=admin"); }
function getUsersLimited()   { apiFetch("/api/users?limit=2"); }
function getUser(id)         { apiFetch(`/api/users/${id}`); }
function createUser() {
  apiFetch("/api/users", {
    method: "POST",
    body: JSON.stringify({ name: "New User", email: "new@example.com", role: "user" }),
  });
}
function updateUser(id) {
  apiFetch(`/api/users/${id}`, {
    method: "PUT",
    body: JSON.stringify({ name: "Updated Name" }),
  });
}
function deleteUser(id) { apiFetch(`/api/users/${id}`, { method: "DELETE" }); }

// ── Binary image ──────────────────────────────────────────────────────────
async function fetchImage() {
  const r = document.getElementById("imgR").value || 128;
  const g = document.getElementById("imgG").value || 64;
  const b = document.getElementById("imgB").value || 200;
  const url = `${API}/api/image?r=${r}&g=${g}&b=${b}`;
  const status = document.getElementById("img-status");
  const img    = document.getElementById("img-preview");

  status.textContent = "Fetching...";
  try {
    const res = await fetch(url, { headers: _authHeaders() });
    if (!res.ok) { status.textContent = `Error ${res.status}`; return; }
    const blob = await res.blob();
    // Set onerror BEFORE src so it's in place if decoding fails synchronously
    img.onerror = () => { status.textContent = `✗ PNG decode failed (${blob.size} bytes)`; };
    img.onload  = () => { status.textContent = `✓ ${res.status}  ${blob.size} bytes  r=${r} g=${g} b=${b}`; };
    img.src = URL.createObjectURL(blob);
    img.style.display = "block";
  } catch (e) {
    status.textContent = "Error: " + e.message;
  }
}

// ── File download ─────────────────────────────────────────────────────────
async function downloadCSV() {
  const out = downloadOut();
  out.textContent = "Fetching...";
  try {
    const res = await fetch(API + "/api/download", { headers: _authHeaders() });
    if (!res.ok) { out.textContent = `Error ${res.status}`; return; }
    const text = await res.text();
    out.textContent = text;
    // Trigger browser download
    const blob = new Blob([text], { type: "text/csv" });
    const link = document.getElementById("csv-link");
    link.href = URL.createObjectURL(blob);
    link.download = "users.csv";
    link.style.display = "inline";
    link.textContent = " ↓ Save file";
    link.click();
  } catch (e) {
    out.textContent = "Error: " + e.message;
  }
}

// ── WebSocket ─────────────────────────────────────────────────────────────
function wsConnect() {
  if (socket) return;
  socket = new WebSocket(WS_URL);
  socket.onopen = () => {
    wsStatus().textContent = "Connected";
    wsStatus().className = "badge badge-on";
    log(wsOut(), "✅ Connected");
  };
  socket.onclose = () => {
    wsStatus().textContent = "Disconnected";
    wsStatus().className = "badge badge-off";
    log(wsOut(), "❌ Disconnected");
    socket = null;
  };
  socket.onerror = () => log(wsOut(), "⚠ WebSocket error");
  socket.onmessage = (e) => log(wsOut(), "← " + e.data);
}

function wsDisconnect() {
  if (socket) socket.close();
}

function wsSend() {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    log(wsOut(), "Not connected.");
    return;
  }
  const msg = wsInput().value.trim();
  if (!msg) return;
  socket.send(msg);
  log(wsOut(), "→ " + msg);
  wsInput().value = "";
}

document.addEventListener("DOMContentLoaded", () => {
  wsInput().addEventListener("keydown", e => { if (e.key === "Enter") wsSend(); });
});

// ── Protected files (auth-gated binary response via /api/protected) ──────────
//
// Unlike serve_dir!, which serves files at the C level before any middleware
// runs, these routes go through the full Julia middleware pipeline (AnyAuth
// checks the X-API-Key / Bearer token).  The handler reads the file into
// Vector{UInt8} and returns it; _send! writes the complete HTTP frame with
// mg_send, preserving every byte including any 0x00s in binaries.
//
// Consequence: the fetch() call below must include auth headers.  If you
// remove the API key / bearer token and click "Refresh list" you get 401.

async function listProtected() {
  const listEl    = document.getElementById("asset-list");
  const statusEl  = document.getElementById("asset-status");
  const previewEl = document.getElementById("asset-preview");
  listEl.innerHTML = "Loading…";
  previewEl.innerHTML = "";
  statusEl.textContent = "";
  try {
    const res  = await fetch(API + "/api/protected", { headers: _authHeaders() });
    if (!res.ok) {
      listEl.innerHTML = `<em style='color:#e44'>Error ${res.status} — check your API key / bearer token</em>`;
      return;
    }
    const data = await res.json();
    if (!data.files || data.files.length === 0) {
      listEl.innerHTML = "<em style='color:#888'>No files found in example/public/assets/</em>";
      return;
    }
    listEl.innerHTML = data.files.map(f => {
      const ext   = f.split(".").pop().toLowerCase();
      const isImg = ["png","jpg","jpeg","gif","webp"].includes(ext);
      const isPdf = ext === "pdf";
      return `<div class="asset-row">
        <span class="asset-name">${f}</span>
        ${isImg ? `<button onclick="viewProtectedImage('${f}')">View</button>` : ""}
        ${isPdf ? `<button onclick="viewProtectedPdf('${f}')">Open PDF</button>` : ""}
        <button onclick="downloadProtected('${f}')">Download</button>
      </div>`;
    }).join("");
  } catch (e) {
    listEl.innerHTML = "Error: " + e.message;
  }
}

// Fetch image through the Julia binary route, create a blob URL, show inline.
// This is the key demo: the response body is a Vector{UInt8} sent via mg_send.
async function viewProtectedImage(name) {
  const previewEl = document.getElementById("asset-preview");
  const statusEl  = document.getElementById("asset-status");
  statusEl.textContent = `Fetching ${name} via /api/protected/${name}…`;
  previewEl.innerHTML = "";
  try {
    const res = await fetch(`${API}/api/protected/${encodeURIComponent(name)}`, {
      headers: _authHeaders(),
    });
    if (!res.ok) { statusEl.textContent = `✗ ${res.status} — check auth`; return; }
    const blob = await res.blob();
    const img  = document.createElement("img");
    img.style  = "max-width:100%;border-radius:4px;margin-top:0.5rem";
    img.onload  = () => { statusEl.textContent = `✓ ${name}  (${blob.size} bytes, via mg_send)`; };
    img.onerror = () => { statusEl.textContent = `✗ Browser could not decode ${name}`; };
    img.src = URL.createObjectURL(blob);
    previewEl.appendChild(img);
  } catch (e) {
    statusEl.textContent = "Error: " + e.message;
  }
}

async function viewProtectedPdf(name) {
  const previewEl = document.getElementById("asset-preview");
  const statusEl  = document.getElementById("asset-status");
  statusEl.textContent = `Fetching ${name}…`;
  previewEl.innerHTML = "";
  try {
    const res = await fetch(`${API}/api/protected/${encodeURIComponent(name)}`, {
      headers: _authHeaders(),
    });
    if (!res.ok) { statusEl.textContent = `✗ ${res.status} — check auth`; return; }
    const blob = await res.blob();
    const url  = URL.createObjectURL(blob);
    previewEl.innerHTML =
      `<iframe src="${url}" style="width:100%;height:600px;border:none;border-radius:4px;margin-top:0.5rem"></iframe>`;
    statusEl.textContent = `✓ ${name}  (${blob.size} bytes, via mg_send)`;
  } catch (e) {
    statusEl.textContent = "Error: " + e.message;
  }
}

async function downloadProtected(name) {
  const statusEl = document.getElementById("asset-status");
  statusEl.textContent = `Downloading ${name}…`;
  try {
    const res = await fetch(
      `${API}/api/protected/${encodeURIComponent(name)}?download=true`,
      { headers: _authHeaders() },
    );
    if (!res.ok) { statusEl.textContent = `✗ ${res.status} — check auth`; return; }
    const blob = await res.blob();
    const a    = document.createElement("a");
    a.href     = URL.createObjectURL(blob);
    a.download = name;
    a.click();
    statusEl.textContent = `⬇ Saved ${name}  (${blob.size} bytes)`;
  } catch (e) {
    statusEl.textContent = "Error: " + e.message;
  }
}

// ── Metrics ───────────────────────────────────────────────────────────────
async function getMetrics() {
  try {
    const res = await fetch(API + "/metrics");
    metricsOut().textContent = await res.text();
  } catch (e) {
    metricsOut().textContent = "Error: " + e.message;
  }
}
