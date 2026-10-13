#!/usr/bin/env bash
# 在 Linux / CI 上用 Docker 跑 OWABridgeCore 单元测试(macOS 目标依赖 AppKit/WebKit,无法在 Linux 编译)。
#   SWIFT_IMAGE 默认 swift:5.10-noble
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${SWIFT_IMAGE:-swift:5.10-noble}"
docker run --rm -v "$PWD":/src:ro "$IMAGE" bash -euc '
  cp -r /src /tmp/w && cd /tmp/w
  rm -rf Sources/OWABridge node_modules .build
  sed -i "/\.executable(/d" Package.swift
  perl -0pi -e "s/\s*\/\/ macOS menu-bar app.*?\n        \),//s" Package.swift
  swift test
'
