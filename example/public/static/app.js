const API = "http://localhost:9000";
const WS_URL = "ws://localhost:9000/ws/chat";
const API_KEY = "demo-key-1234";

const restOut    = document.getElementById("rest-output");
const wsOut      = document.getElementById("ws-output");
const metricsOut = document.getElementById("metrics-output");
const wsInput    = document.getElementById("ws-input");

let socket = null;

async function apiFetch(path, opts = {}) {
  try {
    const res = await fetch(API + path, {
      headers: { "X-API-Key": API_KEY, "Content-Type": "application/json", ...opts.headers },
      ...opts,
    });
    const text = await res.text();
    let body;
    try { body = JSON.parse(text); } catch { body = text; }
    restOut.textContent = `${res.status} ${res.statusText}\n\n${JSON.stringify(body, null, 2)}`;
  } catch (e) {
    restOut.textContent = "Error: " + e.message;
  }
}

function ping()         { apiFetch("/api/ping"); }
function getUsers()     { apiFetch("/api/users"); }
function getUser(id)    { apiFetch(`/api/users/${id}`); }
function createUser()   { apiFetch("/api/users", { method: "POST", body: JSON.stringify({ name: "Alice", email: "alice@example.com", role: "user" }) }); }
function updateUser(id) { apiFetch(`/api/users/${id}`, { method: "PUT", body: JSON.stringify({ name: "Alice Updated" }) }); }
function deleteUser(id) { apiFetch(`/api/users/${id}`, { method: "DELETE" }); }

async function getMetrics() {
  try {
    const res = await fetch(API + "/metrics");
    const text = await res.text();
    metricsOut.textContent = text;
  } catch (e) {
    metricsOut.textContent = "Error: " + e.message;
  }
}

function wsConnect() {
  if (socket) return;
  socket = new WebSocket(WS_URL);
  socket.onopen  = () => log("ws", "✅ Connected");
  socket.onclose = () => { log("ws", "❌ Disconnected"); socket = null; };
  socket.onerror = (e) => log("ws", "⚠ Error: " + e);
  socket.onmessage = (e) => log("ws", "← " + e.data);
}
function wsDisconnect() { if (socket) socket.close(); }
function wsSend() {
  if (!socket || socket.readyState !== WebSocket.OPEN) { log("ws", "Not connected."); return; }
  const msg = wsInput.value.trim();
  if (!msg) return;
  socket.send(msg);
  log("ws", "→ " + msg);
  wsInput.value = "";
}
wsInput.addEventListener("keydown", e => { if (e.key === "Enter") wsSend(); });

function log(target, msg) {
  const el = target === "ws" ? wsOut : restOut;
  el.textContent = msg + "\n" + el.textContent;
}
