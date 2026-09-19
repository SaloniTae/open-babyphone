#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="babyphone.duckdns.org"
APP_USER="babyphone-relay"
APP_DIR="/opt/open-babyphone-relay"
PORT="8338"
ACME_WEBROOT="/var/www/letsencrypt"
NGINX_SITE="/etc/nginx/sites-available/babyphone-relay"
ACME_SITE="/etc/nginx/sites-available/babyphone-acme"
SYSTEMD_UNIT="/etc/systemd/system/open-babyphone-relay.service"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$EUID" -eq 0 ] || die "Run this script as root."; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "=== Open Babyphone relay one-time VPS setup ==="
need_root

echo "[1/10] Verifying existing services..."
PORT80="$(ss -ltnp 2>/dev/null | grep -E ':(80)\b' || true)"
PORT443="$(ss -ltnp 2>/dev/null | grep -E ':(443)\b' || true)"
PORT8338="$(ss -ltnp 2>/dev/null | grep -E ':(8338)\b' || true)"
[ -z "$PORT8338" ] || die "Port 8338 is already in use. Nothing changed."
[ -z "$PORT80" ] || echo "$PORT80" | grep -q nginx || die "Port 80 is occupied by a non-nginx process. Nothing changed."
[ -z "$PORT443" ] || echo "$PORT443" | grep -q nginx || die "Port 443 is occupied by a non-nginx process. Nothing changed."
have_cmd nginx || die "nginx is not installed. Nothing downloaded."
have_cmd certbot || die "certbot is not installed. Nothing downloaded."

echo "[2/10] Selecting existing Node.js 20 from nvm..."
NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] || die "nvm is not installed. Nothing downloaded."
# shellcheck disable=SC1091
source "$NVM_DIR/nvm.sh"
NODE20_BIN="$(nvm which 20 2>/dev/null || true)"
[ -x "$NODE20_BIN" ] || die "Node.js 20 is not installed in nvm. Nothing downloaded."
NODE20_HOME="$(cd "$(dirname "$NODE20_BIN")/.." && pwd)"
NODE20_DIR="$NODE20_HOME/bin"
echo "Using $NODE20_BIN"
echo "Node home: $NODE20_HOME"
"$NODE20_BIN" --version

echo "[3/10] Verifying DNS..."
RESOLVED_IP="$(getent hosts "$DOMAIN" | awk 'NR==1{print $1}')"
[ -n "$RESOLVED_IP" ] || die "$DOMAIN does not resolve."
echo "$DOMAIN -> $RESOLVED_IP"

echo "[4/10] Preparing ACME webroot..."
mkdir -p "$ACME_WEBROOT"

echo "[5/10] Preparing nginx ACME endpoint..."
if [ -e "$ACME_SITE" ]; then
  grep -q "server_name $DOMAIN;" "$ACME_SITE" || die "$ACME_SITE exists and is not recognized. Nothing changed."
else
  cat > "$ACME_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF
fi
ln -sf "$ACME_SITE" /etc/nginx/sites-enabled/babyphone-acme
nginx -t
systemctl reload nginx

echo "[6/10] Obtaining/checking TLS certificate..."
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  echo "Existing Babyphone certificate found; no certificate download."
else
  certbot certonly --webroot -w "$ACME_WEBROOT" --non-interactive --agree-tos --keep-until-expiring -d "$DOMAIN"
  [ -f "$CERT" ] && [ -f "$KEY" ] || die "Certbot did not create the expected certificate."
fi

echo "[7/10] Installing relay application..."
mkdir -p "$APP_DIR"
if id -u "$APP_USER" >/dev/null 2>&1; then
  echo "Existing relay user found; keeping it."
else
  useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi

cat > "$APP_DIR/package.json" <<'EOF'
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

cat > "$APP_DIR/server.js" <<'EOF'
import http from "node:http";
import { WebSocketServer } from "ws";

const PORT = Number(process.env.PORT || 8338);
const sessions = new Map();

const validSessionId = (value) =>
  typeof value === "string" && /^[A-Za-z0-9_-]{20,128}$/.test(value);

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
    if (peer?.readyState === 1) peer.send(data, { binary: true });
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

    if (!validSessionId(sessionId) || !["child", "parent"].includes(role)) {
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
  console.log(`Open Babyphone relay listening on 127.0.0.1:${PORT}`);
});
EOF

chown -R "$APP_USER:$APP_USER" "$APP_DIR"

echo "[8/10] Installing only missing npm dependency..."
NPM_CLI_JS=""
for candidate in \
  "$NODE20_HOME/lib/node_modules/npm/bin/npm-cli.js" \
  "$NODE20_HOME/node_modules/npm/bin/npm-cli.js"; do
  if [ -r "$candidate" ]; then
    NPM_CLI_JS="$candidate"
    break
  fi
done

if [ -d "$APP_DIR/node_modules/ws" ]; then
  echo "Existing ws dependency found; no npm download."
elif [ -n "$NPM_CLI_JS" ]; then
  echo "ws is missing; running npm CLI directly with Node 20..."
  "$NODE20_BIN" "$NPM_CLI_JS" --prefix "$APP_DIR" install --omit=dev
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
else
  die "Node 20 npm CLI was not found. Checked the standard nvm npm locations."
fi

cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Open Babyphone Internet Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
Environment=NODE_ENV=production
Environment=PORT=$PORT
Environment=PATH=$NODE20_DIR:/usr/local/bin:/usr/bin:/bin
ExecStart=$NODE20_BIN $APP_DIR/server.js
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "[9/10] Installing isolated nginx site..."
if [ -e "$NGINX_SITE" ]; then
  grep -q "server_name $DOMAIN;" "$NGINX_SITE" || die "$NGINX_SITE exists and is not recognized. Nothing changed."
fi

cat > "$NGINX_SITE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /healthz {
        proxy_pass http://127.0.0.1:$PORT/healthz;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    location /relay {
        proxy_pass http://127.0.0.1:$PORT;
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

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/babyphone-relay
nginx -t

echo "[10/10] Starting/reloading only Babyphone components..."
systemctl daemon-reload
systemctl enable open-babyphone-relay.service
systemctl restart open-babyphone-relay.service
systemctl reload nginx

echo
echo "=== Verification ==="
systemctl is-active --quiet open-babyphone-relay.service || {
  systemctl --no-pager --full status open-babyphone-relay.service || true
  exit 1
}
curl -fsS "http://127.0.0.1:$PORT/healthz"
echo
curl -fsS "https://$DOMAIN/healthz"
echo
"$NODE20_BIN" --version
echo
echo "READY"
echo "WSS endpoint: wss://$DOMAIN/relay"
echo "Node 18/default was not changed."
