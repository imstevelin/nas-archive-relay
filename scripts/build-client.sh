#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
ARGS=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then ARGS+=(--arch arm64 --arch x86_64); fi
swift build --package-path client -c "$CONFIGURATION" "${ARGS[@]}"
BIN="$(swift build --package-path client -c "$CONFIGURATION" "${ARGS[@]}" --show-bin-path)"
APP="${OUTPUT_APP:-$PWD/dist/NAS Relay.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/Relay.iconset
cp "$BIN/NASRelay" "$APP/Contents/MacOS/NASRelay"
swift client/Icon.swift "$PWD/dist/Relay.iconset"
iconutil -c icns dist/Relay.iconset -o "$APP/Contents/Resources/AppIcon.icns"
NAS_RELAY_APP="$APP" python3 - <<'PY'
import os,plistlib
from pathlib import Path
info={'CFBundleIdentifier':'net.imstevelin.NASRelay','CFBundleName':'NAS Relay','CFBundleDisplayName':'NAS Relay',
 'CFBundleExecutable':'NASRelay','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.4.1','CFBundleVersion':'6',
 'CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,
 'NSLocalNetworkUsageDescription':'連接你設定的區域網路中繼伺服器，並選擇延遲最低的連線。',
 'NSDocumentsFolderUsageDescription':'讀取你選取的歸檔素材。','NSDesktopFolderUsageDescription':'讀取你選取的歸檔素材。',
 'NSDownloadsFolderUsageDescription':'讀取你選取的歸檔素材。',
 'NSRemovableVolumesUsageDescription':'讀取你選取的外接硬碟素材，以便歸檔並校驗。',
 'NSNetworkVolumesUsageDescription':'讀取你選取的網路磁碟素材，以便歸檔並校驗。',
 'NSAppTransportSecurity':{'NSAllowsArbitraryLoads':True}}
with (Path(os.environ['NAS_RELAY_APP'])/'Contents/Info.plist').open('wb') as f:plistlib.dump(info,f)
PY
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$APP" "${ZIP_OUTPUT:-$PWD/dist/NAS-Relay-macOS.zip}"
printf '%s\n' "$APP"
