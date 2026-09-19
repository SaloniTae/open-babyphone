# Open Babyphone Internet Relay

The relay forwards already-encrypted Open Babyphone stream frames between one child
connection and one parent connection.

## Ubuntu 22 deployment

Install Node.js 20+ and git, then:

```bash
cd /opt
sudo git clone https://github.com/SaloniTae/open-babyphone.git
cd open-babyphone/relay
sudo npm install
sudo mkdir -p /etc/open-babyphone
openssl rand -hex 32 | sudo tee /etc/open-babyphone/relay-token
sudo chmod 600 /etc/open-babyphone/relay-token
```

Create a systemd service:

```bash
sudo tee /etc/systemd/system/open-babyphone-relay.service >/dev/null <<'EOF'
[Unit]
Description=Open Babyphone Internet Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/open-babyphone/relay
Environment=NODE_ENV=production
Environment=PORT=8080
EnvironmentFile=/etc/open-babyphone/relay.env
ExecStart=/usr/bin/node /opt/open-babyphone/relay/server.js
Restart=always
RestartSec=2
User=www-data
Group=www-data
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/open-babyphone

[Install]
WantedBy=multi-user.target
EOF
```

Create the environment file:

```bash
TOKEN="$(sudo cat /etc/open-babyphone/relay-token)"
sudo tee /etc/open-babyphone/relay.env >/dev/null <<EOF
RELAY_TOKEN=$TOKEN
MAX_CONNECTIONS_PER_SESSION=2
PORT=8080
EOF
sudo chmod 600 /etc/open-babyphone/relay.env
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now open-babyphone-relay
sudo systemctl status open-babyphone-relay --no-pager
```

Open TCP 8080 if you are testing the relay directly:

```bash
sudo ufw allow 8080/tcp
```

For production, put the relay behind a TLS endpoint and keep 8080 private.
