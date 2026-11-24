#!/usr/bin/env bash
# APEX 9R one-line installer for a Linux VPS (Ubuntu/Debian).
#
#   curl -fsSL https://raw.githubusercontent.com/smallkhk/Porsh/claude/pensive-rubin-3oshi4/install.sh | sudo bash
#
# What it does (safe to re-run; re-running updates the app):
#   - installs git, Node.js 22 and Caddy if missing
#   - downloads the app to /opt/apex9r and runs it as a systemd service on 127.0.0.1
#   - serves it over HTTPS at  https://posh.<your-ip>.sslip.io  (free, no domain needed)
#   - if nginx already owns ports 80/443, it adds an nginx site + Let's Encrypt cert instead
#
# Options (env vars):  SUB=posh  DOMAIN=custom.host  PORT=8787  BRANCH=...
set -euo pipefail

REPO="https://github.com/smallkhk/Porsh.git"
BRANCH="${BRANCH:-claude/pensive-rubin-3oshi4}"
APP_DIR="/opt/apex9r"
PORT="${PORT:-8787}"
SUB="${SUB:-posh}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root:  curl -fsSL <link> | sudo bash"
command -v apt-get >/dev/null || die "This installer supports Ubuntu/Debian (apt). Use the Docker files in the repo instead."
export DEBIAN_FRONTEND=noninteractive

# ---------- address ----------
if [ -z "${DOMAIN:-}" ]; then
  IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || curl -4 -fsS --max-time 8 https://ifconfig.me || true)"
  [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not detect the public IPv4. Re-run with DOMAIN=posh.<ip>.sslip.io"
  DOMAIN="${SUB}.${IP}.sslip.io"
fi
say "Address: https://${DOMAIN}"

# ---------- packages ----------
say "Installing base packages"
apt-get update -qq
apt-get install -y -qq curl git ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https >/dev/null

NODE_MAJOR=0
command -v node >/dev/null && NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  say "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
say "Node $(node -v)"

# ---------- app ----------
if [ -d "$APP_DIR/.git" ]; then
  say "Updating app in $APP_DIR"
  git -C "$APP_DIR" fetch -q origin "$BRANCH"
  git -C "$APP_DIR" checkout -q -B "$BRANCH" FETCH_HEAD
else
  say "Downloading app to $APP_DIR"
  git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"
fi
cd "$APP_DIR"
npm ci --omit=dev --no-audit --no-fund --loglevel=error
id apex9r >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin apex9r

cat > /etc/systemd/system/apex9r.service <<EOF
[Unit]
Description=APEX 9R showroom + relay
After=network.target

[Service]
WorkingDirectory=${APP_DIR}
ExecStart=$(command -v node) server/server.js
Environment=PORT=${PORT} HOST=127.0.0.1 NODE_ENV=production
User=apex9r
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q apex9r
systemctl restart apex9r
for i in $(seq 1 20); do curl -fs "http://127.0.0.1:${PORT}/healthz" >/dev/null && break; sleep 0.5; done
curl -fs "http://127.0.0.1:${PORT}/healthz" >/dev/null || die "App did not start. See: journalctl -u apex9r -n 50"
say "App running on 127.0.0.1:${PORT}"

# ---------- HTTPS ----------
port_owner() { ss -ltnpH "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2; }
OWNER="$(port_owner 443)"; [ -z "$OWNER" ] && OWNER="$(port_owner 80)"

if [ "$OWNER" = "nginx" ]; then
  say "nginx is already running: adding a site for ${DOMAIN}"
  cat > /etc/nginx/sites-available/apex9r.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1h;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/apex9r.conf /etc/nginx/sites-enabled/apex9r.conf
  nginx -t -q && systemctl reload nginx
  apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect -q \
    || warn "Certificate request failed (rate limit or port 80 blocked). Site still works on http://${DOMAIN}"
elif [ -n "$OWNER" ] && [ "$OWNER" != "caddy" ]; then
  warn "Ports 80/443 are used by '${OWNER}'. Point it at http://127.0.0.1:${PORT} for ${DOMAIN} (WebSocket path /relay)."
else
  if ! command -v caddy >/dev/null; then
    say "Installing Caddy (automatic HTTPS)"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq && apt-get install -y -qq caddy >/dev/null
  fi
  # our own file; an existing Caddyfile only gets one import line added
  cat > /etc/caddy/apex9r.caddy <<EOF
${DOMAIN} {
	encode gzip zstd
	reverse_proxy 127.0.0.1:${PORT}
}
EOF
  grep -q 'import /etc/caddy/apex9r.caddy' /etc/caddy/Caddyfile 2>/dev/null || printf '\nimport /etc/caddy/apex9r.caddy\n' >> /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || die "Caddy config invalid: caddy validate --config /etc/caddy/Caddyfile"
  systemctl enable -q caddy
  systemctl reload caddy 2>/dev/null || systemctl restart caddy
fi

# ---------- firewall ----------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
fi

# ---------- check ----------
say "Waiting for the HTTPS certificate…"
OK=""
for i in $(seq 1 30); do
  if curl -fs --max-time 5 "https://${DOMAIN}/healthz" >/dev/null 2>&1; then OK=1; break; fi
  sleep 2
done
echo
if [ -n "$OK" ]; then
  printf '\033[1;32m  APEX 9R is live\033[0m\n\n'
else
  warn "HTTPS isn't answering yet (certificate can take a minute). If it never does, open ports 80 and 443 in your VPS provider's firewall."
  echo
fi
echo "  Viewer (iPad / laptop):  https://${DOMAIN}/"
echo "  Controller (iPhone):     https://${DOMAIN}/remote.html"
echo
echo "  Update later:  re-run the same command"
echo "  Logs:          journalctl -u apex9r -f"
echo
