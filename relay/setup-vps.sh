#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="babyphone.duckdns.org"
APP_USER="babyphone-relay"
APP_DIR="/opt/open-babyphone-relay"
PORT="8338"
ACME_WEBROOT="/var/www/letsencrypt"
NGINX_SITE="/etc/nginx/sites-available/babyphone-relay"
SYSTEMD_UNIT="/etc/systemd/system/open-babyphone-relay.service"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "${EUID}" -eq 0 ] || die "Run this script as root."; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "=== Open Babyphone relay VPS setup ==="
echo "Domain : ${DOMAIN}"
echo "Port   : ${PORT}"
echo

need_root

echo "[1/9] Verifying existing ports and software..."
PORT80="$(ss -ltnp 2>/dev/null | grep -E ':(80)\b' || true)"
PORT443="$(ss -ltnp 2>/dev/null | grep -E ':(443)\b' || true)"
PORT8338="$(ss -ltnp 2>/dev/null | grep -E ':(8338)\b' || true)"

echo "80   : ${PORT80:-free}"
echo "443  : ${PORT443:-free}"
echo "8338 : ${PORT8338:-free}"

if [ -n "${PORT8338}" ]; then
  die "Port 8338 is already in use. Nothing changed."
fi

if [ -n "${PORT80}" ] && ! echo "${PORT80}" | grep -q 'nginx'; then
  die "Port 80 is occupied by a non-nginx process. Nothing changed."
fi

if [ -n "${PORT443}" ] && ! echo "${PORT443}" | grep -q 'nginx'; then
  die "Port 443 is occupied by a non-nginx process. Nothing changed."
fi

have_cmd nginx || die "nginx is not installed. Nothing downloaded."
have_cmd certbot || die "certbot is not installed. Nothing downloaded."

echo
echo "[2/9] Selecting existing Node.js 20 from nvm..."
NVM_DIR="/root/.nvm"
[ -s "${NVM_DIR}/nvm.sh" ] || die "nvm is not installed. Nothing downloaded."

# shellcheck disable=SC1091
source "${NVM_DIR}/nvm.sh"

NODE20_BIN="$(nvm which 20 2>/dev/null || true)"
[ -n "${NODE20_BIN}" ] && [ -x "${NODE20_BIN}" ] || die "Node.js 20 is not installed in nvm. Nothing downloaded. Run: nvm install 20"

NODE20_DIR="$(dirname "${NODE20_BIN}")"
echo "Using Node: ${NODE20_BIN}"
"${NODE20_BIN}" --version

echo
echo "[3/9] Verifying DNS..."
RESOLVED_IP="$(getent hosts "${DOMAIN}" | awk 'NR==1{print $1}')"
[ -n "${RESOLVED_IP}" ] || die "${DOMAIN} does not resolve."
echo "${DOMAIN} -> ${RESOLVED_IP}"

echo
echo "[4/9] Checking existing relay installation..."
mkdir -p "${APP_DIR}"
if id -u "${APP_USER}" >/dev/null 2>&1; then
  echo "Relay user already exists; keeping it."
else
  useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi
chown -R "${APP_USER}":"${APP_USER}" "${APP_DIR}"

echo
echo "[5/9] Installing relay application files..."
cat > "${APP_DIR}/package.json" <<'EOF'
{
  "name": "open-babyphone-relay",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": { "start": "node server.js" },
  "dependencies": { "ws": "^8.18.3" }
}
EOF

cat > "${APP_DIR}/server.js" <<'EOF'
import http from "node:http";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 8338);
const sessions = new Map();

function validSessionId(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{20,128}$/.test(value);
}

function cleanup(sessionId, ws) {
  const session = sessions.get(sessionId);
  if (!session) return;
  if (session.child === ws) session.child = null;
  if (session.parent === ws) session.parent = null;
  if (!session.child && !session.parent) sessions.delete(sessionId);
}

const server = http.createServer((req, res) => {
  if (req.url === "/healthz") {
    res.writeHead(200, {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store"
    });
    res.end("OK\n");
    return;
  }
  res.writeHead(404);
  res.end("Not found\n");
});

const wss = new WebSocketServer({
  noServer: true,
  perMessageDeflate: false,
  maxPayload: 65536
});

wss.on("connection", (ws, _req, sessionId, role) => {
  let session = sessions.get(sessionId);
  if (!session) {
    session = { child: null, parent: null };
    sessions.set(sessionId, session);
  }

  if (session[role]) {
    ws.close(1008, "role already connected");
    return;
  }

  session[role] = ws;

  ws.on("message", (data, isBinary) => {
    if (!isBinary) return;
    const peer = role === "child" ? session.parent : session.child;
    if (peer && peer.readyState === 1) {
      peer.send(data, { binary: true });
    }
  });

  ws.on("close", () => cleanup(sessionId, ws));
  ws.on("error", () => cleanup(sessionId, ws));
});

server.on("upgrade", (req, socket, head) => {
  try {
    const url = new URL(req.url, "http://relay.invalid");

    if (url.pathname !== "/relay") {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }

    const sessionId = url.searchParams.get("session");
    const role = url.searchParams.get("role");

    if (!validSessionId(sessionId) || (role !== "child" && role !== "parent")) {
      socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req, sessionId, role);
    });
  } catch {
    socket.destroy();
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log("Open Babyphone relay listening on 127.0.0.1:" + PORT);
});
EOF

chown -R "${APP_USER}":"${APP_USER}" "${APP_DIR}"

echo
echo "[6/9] Checking npm dependency..."
cd "${APP_DIR}"

if [ -d "${APP_DIR}/node_modules/ws" ]; then
  echo "Existing ws dependency found; no npm download."
else
  echo "ws is missing; installing it with Node 20..."
  NPM_BIN="${NODE20_DIR}/npm"
  [ -x "${NPM_BIN}" ] || die "npm for Node 20 was not found at ${NPM_BIN}."
  sudo -u "${APP_USER}" env PATH="${NODE20_DIR}:/usr/local/bin:/usr/bin:/bin" "${NPM_BIN}" install --omit=dev
fi

echo
echo "[7/9] Installing relay systemd service..."
cat > "${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Open Babyphone Internet Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=NODE_ENV=production
Environment=PORT=${PORT}
Environment=PATH=${NODE20_DIR}:/usr/local/bin:/usr/bin:/bin
ExecStart=${NODE20_BIN} ${APP_DIR}/server.js
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable open-babyphone-relay.service

echo
echo "[8/9] Adding nginx configuration without touching other nginx sites..."
mkdir -p "${ACME_WEBROOT}" /etc/nginx/sites-enabled

# Refuse to replace a different pre-existing file.
if [ -e "${NGINX_SITE}" ] && ! grep -q 'server_name babyphone\.duckdns\.org;' "${NGINX_SITE}"; then
  die "${NGINX_SITE} already exists and is not recognized as the Babyphone config. Nothing changed."
fi

cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /healthz {
        proxy_pass http://127.0.0.1:${PORT}/healthz;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /relay {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/babyphone-relay

# Do not remove the existing default nginx site.
nginx -t

CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
if [ ! -f "${CERT}" ]; then
  echo
  echo "No existing Let's Encrypt certificate was found for ${DOMAIN}."
  echo "I am stopping before changing nginx/restarting services."
  echo "Next step will be certificate setup after checking your existing nginx configuration."
  exit 2
fi

echo
echo "[9/9] Starting only Babyphone relay and reloading nginx..."
systemctl restart open-babyphone-relay.service
systemctl reload nginx

echo
echo "=== Verification ==="
"${NODE20_BIN}" --version
echo "Local relay:"
curl -fsS "http://127.0.0.1:${PORT}/healthz"
echo
echo "Public relay:"
curl -fsS "https://${DOMAIN}/healthz"
echo
systemctl --no-pager --full status open-babyphone-relay.service

echo
echo "WSS endpoint: wss://${DOMAIN}/relay"
echo "Relay port: ${PORT}"
echo "Node 18 remains untouched."
