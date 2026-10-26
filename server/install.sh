#!/usr/bin/env bash
set -euo pipefail

# One-command interactive setup; --non-interactive retains scripted installation.
INSTALL_VERSION=latest
PORT=8743
DATA=/var/lib/nas-archive-relay
POINTER=/etc/nas-archive-relay/data-path
if [[ -f "$POINTER" ]]; then IFS= read -r DATA <"$POINTER"; fi
CURRENT_DATA="$DATA"
RELAY_NAME="$(hostname) NAS Relay"
BINARY=""
INTERACTIVE=auto
DATA_EXPLICIT=no
PORT_EXPLICIT=no
ENDPOINTS=()
while (($#)); do
  case "$1" in
    --version) INSTALL_VERSION="$2"; shift 2;;
    --port) PORT="$2"; PORT_EXPLICIT=yes; shift 2;;
    --data) DATA="$2"; DATA_EXPLICIT=yes; shift 2;;
    --name) RELAY_NAME="$2"; shift 2;;
    --endpoint) ENDPOINTS+=(--endpoint "$2"); shift 2;;
    --binary) BINARY="$2"; shift 2;;
    --interactive) INTERACTIVE=yes; shift;;
    --non-interactive) INTERACTIVE=no; shift;;
    -h|--help) echo 'Usage: curl -fsSL https://github.com/imstevelin/nas-archive-relay/releases/latest/download/install.sh | sudo bash'; echo 'Options: --interactive | --non-interactive [--name NAME] [--port 8743] [--data PATH] [--endpoint https://HOST:PORT] [--binary PATH] [--version TAG]'; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ $EUID == 0 ]] || { echo '請使用 sudo 執行安裝腳本。' >&2; exit 1; }
OS_ID="$(. /etc/os-release; printf %s "$ID")"
[[ "$OS_ID" == ubuntu ]] || { echo 'This installer supports Ubuntu Server 22.04 and later.' >&2; exit 1; }
command -v systemctl >/dev/null || { echo 'systemd is required.' >&2; exit 1; }
exec 9>/run/lock/nas-archive-relay-install.lock
flock -n 9 || { echo 'Another installer is running.' >&2; exit 1; }
if [[ "$INTERACTIVE" != no ]]; then
  if { exec 3<>/dev/tty; } 2>/dev/null; then INTERACTIVE=yes
  elif [[ "$INTERACTIVE" == yes ]]; then echo '互動安裝需要終端機；自動化請加 --non-interactive。' >&2; exit 1
  else INTERACTIVE=no; fi
fi
ask() {
  local answer
  printf '%s [%s]: ' "$1" "$2" >&3
  IFS= read -r answer <&3 || { echo '安裝已取消。' >&2; exit 1; }
  REPLY="${answer:-$2}"
}
normalize_data() {
  [[ "$1" == /* && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *'"'* && "$1" != *'\'* && "$1" != *'%'* && "$1" != *'$'* && "$1" != *':'* ]] || { echo '請使用絕對目錄；不支援換行、引號、反斜線、%、$、:。' >&2; exit 1; }
  DATA="$(realpath -m -- "$1")"
  case "$DATA" in /|/etc|/usr|/var|/srv|/mnt|/media|/home|/root|/run|/proc|/sys|/dev|/etc/*|/usr/*|/proc/*|/sys/*|/dev/*) echo '請選擇專用的服務資料子目錄。' >&2; exit 1;; esac
}
normalize_data "$DATA"
CURRENT_DATA="$(realpath -m -- "$CURRENT_DATA")"
if [[ -f "$CURRENT_DATA/config.json" && "$DATA" != "$CURRENT_DATA" ]]; then
  echo "現有任務位於 $CURRENT_DATA；升級不會改用空目錄。請先完成任務並另行搬移整個服務資料。" >&2; exit 1
fi
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
if [[ -f "$DATA/config.json" ]]; then
  RELAY_NAME="$("$BINARY" info --data "$DATA" --field name)"
  mapfile -t SAVED_ENDPOINTS < <("$BINARY" info --data "$DATA" --field endpoints)
  SAVED_PORT="$(systemctl show nas-archive-relay.service -p ExecStart --value 2>/dev/null | sed -n 's/.*--listen :\([0-9][0-9]*\).*/\1/p')"
  if [[ -n "$SAVED_PORT" ]]; then
    if [[ "$PORT_EXPLICIT" == yes && "$PORT" != "$SAVED_PORT" ]]; then echo '升級會保留現有服務埠號，請先另行更新連線與憑證。' >&2; exit 1; fi
    PORT="$SAVED_PORT"
  fi
  ENDPOINTS=(); for endpoint in "${SAVED_ENDPOINTS[@]}"; do ENDPOINTS+=(--endpoint "$endpoint"); done
  if [[ "$INTERACTIVE" == yes ]]; then
    printf '\n偵測到現有服務：%s\n資料位置：%s\n升級會保留端點、暫存、憑證及任務，不會重新初始化。\n' "$RELAY_NAME" "$DATA" >&3
    ask '繼續升級？Y/n' Y
    [[ "$REPLY" == Y || "$REPLY" == y ]] || exit 0
  fi
elif [[ "$INTERACTIVE" == yes ]]; then
  printf '\nNAS Relay 安裝設定\n' >&3
  ask '伺服器顯示名稱' "$RELAY_NAME"; RELAY_NAME="$REPLY"
  ask 'HTTPS 服務埠號' "$PORT"; PORT="$REPLY"
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1024 && PORT<=65535)) || { echo 'Invalid port.' >&2; exit 1; }
  printf '\n選擇暫存與服務資料位置（也會存放設定及工作紀錄）：\n1) 自動指定：%s\n' "$DATA" >&3
  MOUNTS=()
  while IFS= read -r mount; do
    mount="$(printf '%b' "$mount")"
    [[ -n "$mount" && "$mount" != / && "$mount" != /boot* ]] || continue
    [[ -d "$mount" ]] || continue
    duplicate=no; for existing in "${MOUNTS[@]}"; do [[ "$existing" == "$mount" ]] && duplicate=yes; done
    [[ "$duplicate" == no ]] && MOUNTS+=("$mount")
  done < <(lsblk -nrpo MOUNTPOINT 2>/dev/null || true)
  for i in "${!MOUNTS[@]}"; do printf '%s) 已掛載磁碟：%s（建立 nas-archive-relay 子目錄）\n' "$((i+2))" "${MOUNTS[$i]}" >&3; done
  printf 'C) 自訂目錄（包含空白與中文皆可）\n' >&3
  ask '輸入編號或 C；也可直接輸入絕對路徑' 1
  choice="$REPLY"
  if [[ "$choice" == [Cc] ]]; then ask '資料目錄絕對路徑' "$DATA"; DATA="$REPLY"
  elif [[ "$choice" == /* ]]; then DATA="$choice"
  elif [[ "$choice" == 1 ]]; then :
  elif [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=2 && choice<=${#MOUNTS[@]}+1)); then DATA="${MOUNTS[$((choice-2))]}/nas-archive-relay"
  else echo '無效的磁碟選擇。' >&2; exit 1; fi
  normalize_data "$DATA"
  [[ ! -f "$DATA/config.json" ]] || { echo '此位置已有服務資料；請使用 --data 指定它進行升級。' >&2; exit 1; }
  printf '\n偵測到的可用連線位址（通常區網及 VPN 位址都可保留）：\n' >&3
  mapfile -t AVAILABLE < <("$BINARY" discover --port "$PORT")
  for i in "${!AVAILABLE[@]}"; do printf '%s) %s\n' "$((i+1))" "${AVAILABLE[$i]}" >&3; done
  ask '保留全部請按 Enter；或輸入編號（逗號分隔），C 僅使用自訂位址' A
  choice="$REPLY"; ENDPOINTS=()
  if [[ "$choice" == [Aa] ]]; then for endpoint in "${AVAILABLE[@]}"; do ENDPOINTS+=(--endpoint "$endpoint"); done
  elif [[ "$choice" != [Cc] ]]; then
    IFS=',' read -r -a CHOICES <<<"$choice"
    for index in "${CHOICES[@]}"; do
      index="${index// /}"
      [[ "$index" =~ ^[0-9]+$ ]] && ((index>=1 && index<=${#AVAILABLE[@]})) || { echo '無效的位址選擇。' >&2; exit 1; }
      ENDPOINTS+=(--endpoint "${AVAILABLE[$((index-1))]}")
    done
  fi
  ask '其他 HTTPS 位址（空白分隔；例如 https://nas.example.com:8743；Enter 略過）' ''
  if [[ -n "$REPLY" ]]; then read -r -a CUSTOM <<<"$REPLY"; for endpoint in "${CUSTOM[@]}"; do ENDPOINTS+=(--endpoint "$endpoint"); done; fi
  ((${#ENDPOINTS[@]}>0)) || { echo '請至少選擇一個連線位址。' >&2; exit 1; }
  printf '\n名稱：%s\n埠號：%s\n資料位置：%s\n' "$RELAY_NAME" "$PORT" "$DATA" >&3
  printf '連線位址：\n' >&3; for ((i=1;i<${#ENDPOINTS[@]};i+=2)); do printf '  %s\n' "${ENDPOINTS[$i]}" >&3; done
  ask '開始安裝？Y/n' Y
  [[ "$REPLY" == Y || "$REPLY" == y ]] || exit 0
fi
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1024 && PORT<=65535)) || { echo 'Invalid port.' >&2; exit 1; }
normalize_data "$DATA"
if [[ -d "$DATA" && ! -f "$DATA/config.json" && -n "$(find "$DATA" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "此目錄已有其他資料，請選擇專用的空子目錄。" >&2; exit 1
fi
"$BINARY" init --data "$DATA" --name "$RELAY_NAME" --port "$PORT" "${ENDPOINTS[@]}"
mkdir -p /usr/local/lib/nas-relay/backups
if [[ -f /usr/local/bin/nas-relay ]]; then cp -p /usr/local/bin/nas-relay "/usr/local/lib/nas-relay/backups/nas-relay-$(date -u +%Y%m%dT%H%M%SZ)"; fi
install -m 0755 "$BINARY" /usr/local/bin/nas-relay.new
mv /usr/local/bin/nas-relay.new /usr/local/bin/nas-relay
mkdir -p /etc/nas-archive-relay
chmod 0700 /etc/nas-archive-relay
printf '%s\n' "$DATA" >/etc/nas-archive-relay/data-path.new
chmod 0600 /etc/nas-archive-relay/data-path.new
mv /etc/nas-archive-relay/data-path.new "$POINTER"
MOUNT_POINT="$(printf '%b' "$(findmnt -n -o TARGET -T "$DATA")")"
[[ -n "$MOUNT_POINT" && "$MOUNT_POINT" != *'"'* && "$MOUNT_POINT" != *'%'* ]] || { echo 'Cannot determine storage mount.' >&2; exit 1; }
HOME_POLICY=yes
BIND_DATA="BindPaths=\"$DATA\""
case "$DATA" in /home/*|/root/*|/run/user/*) HOME_POLICY=tmpfs; BIND_DATA="BindPaths=\"$DATA\"";; esac
cat >/etc/systemd/system/nas-archive-relay.service <<EOF_UNIT
[Unit]
Description=NAS Archive Relay HTTPS service
Wants=network-online.target
After=network-online.target
RequiresMountsFor="$DATA"
ConditionPathIsMountPoint="$MOUNT_POINT"

[Service]
Type=simple
ExecStart=/usr/local/bin/nas-relay serve --data "$DATA" --listen :$PORT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=$HOME_POLICY
$BIND_DATA
PrivateTmp=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
ReadWritePaths="$DATA"
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl enable nas-archive-relay.service
systemctl restart nas-archive-relay.service
for attempt in {1..20}; do
  if systemctl is-active --quiet nas-archive-relay.service; then break; fi
  sleep 1
done
systemctl is-active --quiet nas-archive-relay.service
echo "Installed. HTTPS port: $PORT. Data: $DATA"
echo "Additional client: sudo nas-relay client add --name 'Client name' --role client"
echo 'Logs: sudo journalctl -u nas-archive-relay.service -f'
echo 'When a firewall is enabled, allow this port only from your LAN or private VPN.'
