#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../server"
mkdir -p ../dist
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags='-s -w' -o "../dist/nas-relay-linux-$arch" ./cmd/nas-relay
done
cd ../dist
shasum -a 256 nas-relay-linux-amd64 nas-relay-linux-arm64 >SHA256SUMS
