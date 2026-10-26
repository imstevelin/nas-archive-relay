#!/usr/bin/env bash
set -euo pipefail

# Public release installer. No application data or existing NAS shares are reset.
INSTALL_VERSION=latest
PORT=8743
DATA=/var/lib/nas-archive-relay
RELAY_NAME="$(hostname) NAS Relay"
BINARY=""
ENDPOINTS=()
while (($#)); do
  case "$1" in
    --version) INSTALL_VERSION="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --data) DATA="$2"; shift 2;;
    --name) RELAY_NAME="$2"; shift 2;;
    --endpoint) ENDPOINTS+=(--endpoint "$2"); shift 2;;
    --binary) BINARY="$2"; shift 2;;
    -h|--help) echo 'Usage: sudo bash install.sh [--name NAME] [--port 8743] [--endpoint https://HOST:PORT] [--binary PATH] [--version TAG]'; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ $EUID == 0 ]] || { echo 'Run this installer with sudo.' >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1024 && PORT<=65535)) || { echo 'Invalid port.' >&2; exit 1; }
[[ "$DATA" =~ ^/[A-Za-z0-9/._-]+$ && "$DATA" != / && "$DATA" != /var && "$DATA" != /etc && "$DATA" != /usr ]] || { echo 'Use an absolute state path below /var/lib or /srv.' >&2; exit 1; }
OS_ID="$(. /etc/os-release; printf %s "$ID")"
[[ "$OS_ID" == ubuntu ]] || { echo 'This installer supports Ubuntu Server 22.04 and later.' >&2; exit 1; }
command -v systemctl >/dev/null || { echo 'systemd is required.' >&2; exit 1; }
exec 9>/run/lock/nas-archive-relay-install.lock
flock -n 9 || { echo 'Another installer is running.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
apt-get update -qq
apt-get install -y -qq ca-certificates curl nfs-common cifs-utils
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [[ -z "$BINARY" ]]; then
  case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo 'Unsupported CPU architecture.' >&2; exit 1;; esac
  REPO="${NAS_RELAY_REPO:-imstevelin/nas-archive-relay}"
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 1
  if [[ "$INSTALL_VERSION" == latest ]]; then BASE="https://github.com/$REPO/releases/latest/download"; else
    [[ "$INSTALL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-A-Za-z0-9.]+)?$ ]] || { echo 'Invalid version.' >&2; exit 1; }
    BASE="https://github.com/$REPO/releases/download/$INSTALL_VERSION"
  fi
  FILE="nas-relay-linux-$ARCH"
  curl --fail --location --proto '=https' --tlsv1.2 "$BASE/$FILE" -o "$TMP/$FILE"
  curl --fail --location --proto '=https' --tlsv1.2 "$BASE/SHA256SUMS" -o "$TMP/SHA256SUMS"
  (cd "$TMP"; awk -v name="$FILE" '$2==name {print}' SHA256SUMS > selected.sha256; test -s selected.sha256; sha256sum --check selected.sha256)
  BINARY="$TMP/$FILE"
fi
test -f "$BINARY"
chmod 0755 "$BINARY"
"$BINARY" version
mkdir -p /usr/local/lib/nas-relay/backups
if [[ -f /usr/local/bin/nas-relay ]]; then cp -p /usr/local/bin/nas-relay "/usr/local/lib/nas-relay/backups/nas-relay-$(date -u +%Y%m%dT%H%M%SZ)"; fi
install -m 0755 "$BINARY" /usr/local/bin/nas-relay.new
mv /usr/local/bin/nas-relay.new /usr/local/bin/nas-relay
mkdir -p "$DATA"
chmod 0700 "$DATA"
/usr/local/bin/nas-relay init --data "$DATA" --name "$RELAY_NAME" --port "$PORT" "${ENDPOINTS[@]}"
cat >/etc/systemd/system/nas-archive-relay.service <<EOF
[Unit]
Description=NAS Archive Relay HTTPS service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nas-relay serve --data $DATA --listen :$PORT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
ReadWritePaths=$DATA
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nas-archive-relay.service
systemctl restart nas-archive-relay.service
for attempt in {1..20}; do
  if systemctl is-active --quiet nas-archive-relay.service; then break; fi
  sleep 1
done
systemctl is-active --quiet nas-archive-relay.service
echo "Installed. HTTPS port: $PORT. Service: nas-archive-relay.service"
echo "Additional client: sudo nas-relay client add --data $DATA --name 'Client name' --role client"
echo "Logs: sudo journalctl -u nas-archive-relay.service -f"
echo 'When a firewall is enabled, allow this port only from your LAN or private VPN.'
