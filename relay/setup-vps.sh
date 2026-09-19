#!/usr/bin/env bash
set -Eeuo pipefail

# Open Babyphone relay - one-time Ubuntu VPS setup
# Existing software is checked first. Nothing is downloaded unless required.
# Node.js 20 is selected only for this service using nvm when available,
# otherwise the script installs/uses Node 20 without changing other apps.

DOMAIN="babyphone.duckdns.org"
APP_USER="babyphone-relay"
APP_DIR="/opt/open-babyphone-relay"
PORT="8338"
ACME_WEBROOT="/var/www/letsencrypt"
NGINX_SITE="/etc/nginx/sites-available/babyphone-relay"
SYSTEMD_UNIT="/etc/systemd/system/open-babyphone-relay.service"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "${EUID}" -eq 0 ] || die "Run this script as root."; }

echo "=== Open Babyphone relay VPS setup ==="
echo "Domain : ${DOMAIN}"
echo "Port   : ${PORT}"
echo

need_root

echo "[1/9] Checking existing software..."

have_cmd() { command -v "$1" >/dev/null 2>&1; }

if have_cmd node; then
  echo "System Node: $(node --version)"
else
  echo "System Node: not installed"
fi

if have_cmd nginx; then
  echo "nginx: $(nginx -v 2>&1)"
else
  echo "nginx: not installed"
fi

if have_cmd certbot; then
  echo "certbot: $(certbot --version 2>&1)"
else
  echo "certbot: not installed"
fi

echo
echo "[2/9] Selecting Node.js 20 only for this relay..."

NODE20_BIN=""

# Prefer nvm already installed for root.
if [ -s "/root/.nvm/nvm.sh" ]; then
  # shellcheck disable=SC1091
  source "/root/.nvm/nvm.sh"
  if nvm ls 20 >/dev/null 2>&1; then
    nvm use 20 >/dev/null
  else
    echo "Node 20 is not installed in root nvm; installing only that nvm version..."
    nvm install 20
    nvm use 20
  fi
  NODE20_BIN="$(nvm which 20)"
fi

# Otherwise look for an existing node 20 binary.
if [ -z "${NODE20_BIN}" ]; then
  while IFS= read -r candidate; do
    [ -x "${candidate}" ] || continue
    major="$("${candidate}" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
    if [ "${major}" = "20" ]; then
      NODE20_BIN="${candidate}"
      break
    fi
  done < <(find /usr/local/bin /usr/bin /opt /root -type f -name node 2>/dev/null | head -200)
fi

# Install nvm + Node 20 only if no existing Node 20 was found.
if [ -z "${NODE20_BIN}" ]; then
  echo "No existing Node 20 found. Installing nvm + Node 20..."
  export NVM_DIR="/root/.nvm"
  if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    apt-get update
    apt-get install -y curl ca-certificates
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  fi
  # shellcheck disable=SC1091
  source "${NVM_DIR}/nvm.sh"
  nvm install 20
  nvm use 20
  NODE20_BIN="$(nvm which 20)"
fi

[ -n "${NODE20_BIN}" ] || die "Could not find Node.js 20."
NODE20_DIR="$(dirname "${NODE20_BIN}")"
echo "Relay will use: ${NODE20_BIN}"
"${NODE20_BIN}" --version

echo
echo "[3/9] Checking/installing nginx and certbot only when absent..."

if ! have_cmd nginx || ! have_cmd certbot; then
  apt-get update
  if ! have_cmd nginx; then
    apt-get install -y nginx
  fi
  if ! have_cmd certbot; then
    apt-get install -y certbot
  fi
fi

echo
echo "[4/9] Creating dedicated relay account and directory..."

if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
else
  echo "User ${APP_USER} already exists; keeping it."
fi

mkdir -p "${APP_DIR}" "${ACME_WEBROOT}"
chown -R "${APP_USER}":"${APP_USER}" "${APP_DIR}"

echo
echo "[5/9] Writing relay application..."

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
echo "[6/9] Installing npm dependency only if it is missing..."

cd "${APP_DIR}"
if [ ! -d "${APP_DIR}/node_modules/ws" ]; then
  # Run npm with Node 20 specifically.
  export PATH="${NODE20_DIR}:${PATH}"
  if [ "${NODE20_BIN}" = "/usr/bin/node" ]; then
    echo "Using existing system Node 20."
  fi
  sudo -u "${APP_USER}" env PATH="${NODE20_DIR}:/usr/local/bin:/usr/bin:/bin" npm install --omit=dev
else
  echo "ws is already installed; skipping npm download."
fi

echo
echo "[7/9] Installing/updating systemd unit for the relay..."

NODE20_EXEC="${NODE20_BIN}"
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
ExecStart=${NODE20_EXEC} ${APP_DIR}/server.js
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
systemctl restart open-babyphone-relay.service

echo
echo "[8/9] Configuring nginx + Let's Encrypt..."

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

mkdir -p /etc/nginx/sites-enabled
ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/babyphone-relay
rm -f /etc/nginx/sites-enabled/default

nginx -t

# Certificate only if this exact certificate is missing.
if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  echo "Certificate for ${DOMAIN} is missing; requesting it now..."
  systemctl reload nginx
  certbot certonly --webroot -w "${ACME_WEBROOT}" -d "${DOMAIN}"     --agree-tos --register-unsafely-without-email --non-interactive
else
  echo "Existing Let's Encrypt certificate found; skipping certificate download."
fi

nginx -t
systemctl reload nginx

echo
echo "[9/9] Checking firewall without resetting existing rules..."

if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

echo
echo "=== Verification ==="
echo "Node used by relay:"
"${NODE20_BIN}" --version
echo
echo "Relay service:"
systemctl --no-pager --full status open-babyphone-relay.service || true
echo
echo "Local health:"
curl -fsS "http://127.0.0.1:${PORT}/healthz"
echo
echo "Public health:"
curl -fsS "https://${DOMAIN}/healthz"
echo
echo "WSS endpoint: wss://${DOMAIN}/relay"
echo "Local relay port: ${PORT}"
echo "Other applications using Node 18/other Node versions were not changed."
