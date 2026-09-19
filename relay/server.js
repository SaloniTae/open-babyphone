import http from "node:http";
import crypto from "node:crypto";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 8080);
const MAX_CONNECTIONS_PER_SESSION = Number(process.env.MAX_CONNECTIONS_PER_SESSION || 2);
const RELAY_TOKEN = process.env.RELAY_TOKEN || "";

const sessions = new Map();

function bad(ws, message) {
  try {
    ws.close(1008, message);
  } catch {}
}

function sessionFor(id) {
  let session = sessions.get(id);
  if (!session) {
    session = new Set();
    sessions.set(id, session);
  }
  return session;
}

function cleanup(id, ws) {
  const session = sessions.get(id);
  if (!session) return;
  session.delete(ws);
  if (session.size === 0) sessions.delete(id);
}

function authenticate(req, url) {
  if (RELAY_TOKEN && url.searchParams.get("token") !== RELAY_TOKEN) {
    return false;
  }
  return true;
}

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    res.end("ok\n");
    return;
  }

  res.writeHead(404);
  res.end();
});

const wss = new WebSocketServer({
  noServer: true,
  maxPayload: 128 * 1024
});

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url || "/", "http://localhost");

  if (url.pathname !== "/relay" || !authenticate(req, url)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const sessionId = url.searchParams.get("session");
  const role = url.searchParams.get("role");

  if (!sessionId || !/^[A-Za-z0-9_-]{8,128}$/.test(sessionId) ||
      (role !== "child" && role !== "parent")) {
    socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const session = sessionFor(sessionId);

  if (session.size >= MAX_CONNECTIONS_PER_SESSION) {
    socket.write("HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.sessionId = sessionId;
    ws.role = role;
    ws.connectionId = crypto.randomUUID();
    session.add(ws);

    ws.on("message", (data, isBinary) => {
      const peers = sessions.get(ws.sessionId);
      if (!peers) return;

      for (const peer of peers) {
        if (peer !== ws && peer.readyState === peer.OPEN) {
          peer.send(data, { binary: isBinary });
        }
      }
    });

    ws.on("close", () => cleanup(ws.sessionId, ws));
    ws.on("error", () => cleanup(ws.sessionId, ws));

    ws.send(JSON.stringify({
      type: "relay-ready",
      connectionId: ws.connectionId,
      role: ws.role
    }));
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Open Babyphone relay listening on 0.0.0.0:${PORT}`);
});
