#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

test -s "$ROOT/honk/files/config.dae"
test -s "$ROOT/honk/files/config.dae.default"
cmp -s "$ROOT/honk/files/config.dae" "$ROOT/honk/files/config.dae.default"
grep -q 'config.dae.default' "$ROOT/honk/Makefile"
grep -q 'ensure_config' "$ROOT/honk/files/honk.init"
grep -q 'M.DEFAULT_CONFIG' "$ROOT/luci-app-honk/luasrc/model/config.lua"
grep -q 'function M.default_config' "$ROOT/luci-app-honk/luasrc/model/service.lua"
grep -q 'function M.reset_config' "$ROOT/luci-app-honk/luasrc/model/service.lua"
grep -q 'default_config' "$ROOT/luci-app-honk/luasrc/controller/honk.lua"
grep -q 'reset_config' "$ROOT/luci-app-honk/luasrc/controller/honk.lua"
grep -q 'api_default_config' "$ROOT/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json"
grep -q 'api_reset_config' "$ROOT/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json"
grep -q '/etc/honk/config.dae.default' "$ROOT/luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json"

printf '%s\n' 'PASS: default template, seed path, API wiring, and ACL contract'
