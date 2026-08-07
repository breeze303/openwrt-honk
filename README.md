# Honk OpenWrt Feed

English | [简体中文](README.zh-CN.md)

This repository packages [Honk](https://github.com/Glassyiris/honk), a Rust/eBPF transparent proxy engine, for OpenWrt together with a native LuCI management interface.

The feed contains three packages:

- honk: honk-core, honk-tool, the procd service, default configuration, eBPF assets, and runtime logging.
- luci-app-honk: the new standalone LuCI controller, mode/DNS generator, node and device workflow, diagnostics, and dashboard.
- luci-app-honk-legacy: the preserved legacy LuCI dashboard for rollback and migration reference. It uses its own controller, ACL, menu, API, and static namespace.

Builds use the exact upstream commit recorded in `locks/source.lock.json`. The package currently targets OpenWrt x86_64 and aarch64. A scheduled workflow checks Honk `main` daily and opens an update PR for revisions that pass source, checksum, and patch validation.

## Screenshots

The dashboard is a single native LuCI page. It does not download or embed a second external dashboard.

| Overview | Configuration |
| --- | --- |
| ![Honk overview](docs/screenshots/overview.png) | ![Honk configuration](docs/screenshots/configuration.png) |

The layout also adapts to narrow screens:

![Honk mobile overview](docs/screenshots/mobile-overview.png)

## Features

- Rust/eBPF transparent proxy runtime managed by OpenWrt procd.
- Ordered routing rules with direct, proxy, block, group, and direct(must) actions.
- Rule, Global, and Direct runtime modes through the Clash-compatible API.
- Node import, editing, removal, connection testing, subscriptions, and selector groups.
- DNS upstream editing for UDP, TCP, TCP+UDP, TLS, HTTPS, H3, and QUIC.
- Separate DNS request and response routing configuration.
- Live traffic, connection, memory, node, rule, and service status views.
- Honk logs stored in /tmp/honk/honk.log instead of being forwarded to logread.
- Atomic save/apply flow with validation, revision checks, and restart rollback.

## Package Layout

~~~text
honk/                  OpenWrt recipe for the Honk engine and service
luci-app-honk/         New standalone LuCI package and dashboard source
luci-app-honk-legacy/  Preserved legacy LuCI package and dashboard source
honk/patches/          OpenWrt-specific upstream patches
locks/source.lock.json Source and patch digest lock file
tests/                 Focused packaging and integration checks
~~~

## Requirements

The package supports only x86_64 and aarch64 targets. The build dependencies below are host-side tools; the runtime dependencies are installed into the OpenWrt image.

### Host build dependencies

The commands below target Ubuntu/Debian. Other Linux distributions need equivalent packages:

~~~sh
sudo apt-get update
sudo apt-get install -y \
  git curl jq patch tar gzip zstd binutils \
  clang llvm libbpf-dev libclang-dev pkg-config cmake
~~~

The source build runs inside the OpenWrt SDK. The SDK helper installs Rustup, the pinned BPF nightly toolchain, the pinned Rust feed revision, and `bpf-linker` `0.10.4`:

~~~sh
rustup toolchain install nightly-2026-07-20 --profile minimal \
  --component rust-src
~~~

The SDK helper downloads and verifies the host eBPF linker with this SHA-256:

~~~sh
mkdir -p "$HOME/.cargo/bin"
curl --fail --location --retry 5 --retry-all-errors \
  -o /tmp/bpf-linker.tar.zst \
  https://github.com/aya-rs/bpf-linker/releases/download/v0.10.4/bpf-linker-x86_64-unknown-linux-musl.tar.zst
printf '%s  %s\n' \
  4dda77daab6c5f120a468e6d3ede2498f5bd47ece712172cfb7290176d93d015 \
  /tmp/bpf-linker.tar.zst | sha256sum -c -
tar --zstd -xf /tmp/bpf-linker.tar.zst -C "$HOME/.cargo/bin"
~~~

Building either LuCI dashboard requires Node.js 22 and npm. Rust and the eBPF linker are installed inside the SDK build container as part of the source build.

### OpenWrt runtime dependencies

The `honk` package declares `ca-bundle`, `ip-full`, `tc-full`, `nsenter`, `libstdcpp`, `jq`, `kmod-sched-core`, `kmod-sched-bpf`, and `kmod-veth`. The current LuCI package adds `luci-base`, `luci-compat`, and `curl`; the legacy package uses `luci-base` and `luci-compat`. The target kernel must provide `CONFIG_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT`, `CONFIG_CGROUP_BPF`, `CONFIG_NET_CLS_BPF`, `CONFIG_NET_SCH_INGRESS`, `CONFIG_NET_CLS_ACT`, `CONFIG_NET_NS`, `CONFIG_VETH`, and `CONFIG_DEBUG_INFO_BTF`.

GeoSite and GeoIP are provisioned from the exact inputs in `locks/geo.lock.json`. Honk owns `/usr/lib/honk` and `/usr/share/honk`; it has no runtime dependency on a target package manager's `v2ray-*` Geo data. To prepare the locked assets in a checkout:

~~~sh
mkdir -p .cache/dl
curl --fail --location -o .cache/dl/loyalsoldier-geosite-202607312254.dat \
  https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/202607312254/geosite.dat
curl --fail --location -o .cache/dl/v2fly-geoip-202607171233.dat \
  https://github.com/v2fly/geoip/releases/download/202607171233/geoip.dat
printf '%s  %s\n' \
  1f3a743e8e30152a870a1674792af3976361436dcb1f510a43c499d430f6b13f \
  .cache/dl/loyalsoldier-geosite-202607312254.dat | sha256sum -c -
printf '%s  %s\n' \
  b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a \
  .cache/dl/v2fly-geoip-202607171233.dat | sha256sum -c -
~~~

## Build

### Build OpenWrt packages

Install this checkout as an OpenWrt feed or place the package directories in the buildroot, refresh feeds, and select the packages:

~~~sh
./scripts/feeds update honk
./scripts/feeds install -a -p honk
make menuconfig
make package/honk/download V=s
make package/honk/compile V=s
make package/luci-app-honk/compile V=s
make package/luci-app-honk-legacy/compile V=s
~~~

`package/honk/compile` always downloads the locked upstream Honk archive from GitHub, verifies the package hash, applies `honk/patches/`, builds the eBPF object with the pinned nightly toolchain, and then builds `honk-core` and `honk-tool` for the selected OpenWrt target. There is no `honk/files/bin` staging directory and no binary Release dependency.

### Build the LuCI dashboards alone

~~~sh
for app in luci-app-honk/ui luci-app-honk-legacy/ui; do
  (cd "$app" && npm ci && npm run typecheck && npm run build)
done
~~~

The generated assets are committed below `luci-app-honk/root/www/luci-static/resources/honk/app/` and `luci-app-honk-legacy/root/www/luci-static/resources/honk-legacy/app/`.

Run the repository checks before publishing a package:

~~~sh
bash tests/run-tests.sh
git diff --check
~~~

### GitHub Actions

`Update Honk upstream` checks upstream `main` every day. When a new revision is available, it downloads the commit archive, calculates its SHA-256 and Git tree, validates every local patch, and creates or updates the `automation/honk-upstream` PR. It can also be run manually from the Actions page. Patch conflicts stop the refresh and retain the current buildable revision.

`Build packages` directly builds Honk from its locked upstream source in each OpenWrt SDK matrix job. The helper installs the pinned Rust host feed, nightly `rust-src`, and verified `bpf-linker` before invoking `package/honk/download` and `package/honk/compile`. The matrix builds:

- IPK packages for OpenWrt 24.10 on x86_64 and aarch64_generic.
- APK packages for OpenWrt 25.12 on x86_64 and aarch64_generic.

Each matrix job uploads the newly compiled `honk`, `luci-app-honk`, and `luci-app-honk-legacy` packages as workflow artifacts. After all four builds pass, the workflow publishes the packages in a versioned GitHub Release. The architecture and SDK are appended to release filenames so LuCI's architecture-independent packages are still easy to identify.

## Install

Build or download the engine and the LuCI packages, install honk first, then choose the new package. Keep the legacy package only when rollback/reference access is needed; the two LuCI packages have disjoint paths:

~~~sh
# apk-based OpenWrt snapshots
apk add ./honk-*.apk ./luci-app-honk-*.apk

# opkg-based images
opkg install honk-*.ipk luci-app-honk-*.ipk
~~~

The LuCI page is available at:

~~~text
/cgi-bin/luci/admin/services/honk
~~~

The new page is available at `/cgi-bin/luci/admin/services/honk`; the preserved package is isolated at `/cgi-bin/luci/admin/services/honk-legacy/`. The new controller reads and preserves existing node, subscription, experimental, and unknown sections while rebuilding only its managed mode sections. Each apply validates, backs up, atomically writes, restarts Honk, checks health, and restores the previous configuration on failure.

## Quick Setup and Geo Assets

Quick Setup is the first Honk view. It uses the existing subscription and node data and writes only the single `/etc/honk/config.dae` runtime configuration. The four presets are GFWList, China Direct, Global Proxy, and Direct. Each preview shows the selected source groups, discovered LAN/WAN devices, route/DNS projection, revision, and a server-generated candidate digest before an apply is accepted. The Advanced editor remains available; an advanced-owned configuration requires an explicit replacement confirmation.

The package ships the locked assets under Honk-owned paths:

| Asset | Locked input | Installed payload | Public loading path |
| --- | --- | --- | --- |
| GeoSite | Loyalsoldier release `202607312254`, SHA-256 `1f3a743e8e30152a870a1674792af3976361436dcb1f510a43c499d430f6b13f` | `/usr/lib/honk/geosite.dat` | `/usr/share/honk/geosite.dat` |
| GeoIP | V2Fly release `202607171233`, SHA-256 `b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a` | `/usr/lib/honk/geoip.dat` | `/usr/share/honk/geoip.dat` |

`/usr/share/honk/geo.lock.json` and `/run/honk/geo-assets.json` record provenance and the active receipt. The new Diagnostics page reports GeoSite and GeoIP files, hashes, labels, and the live receipt separately, and allows each URL to be edited before downloading one or both assets. Locked mode requires the pinned SHA-256; enabling custom Geo mode accepts format and label checks and reports `CUSTOM`. Downloads use a temporary file and atomic replacement and never touch `/usr/share/v2ray`; a running service needs an explicit restart after an update.

Quick mutations are handled by `/usr/libexec/honk/quick-transaction-worker`. It keeps the previous bytes in a root-only sidecar, records each durable stage, and restores the prior running or stopped state after a failed restart, subscription wait, or probe. A failed recovery is reported as `degraded` and remains visible for operator action. Direct can be applied without a proxy subscription, while proxy presets require a non-empty, validated source group and the Geo/DNS/interface gates. Geo download URLs and the custom-data policy are stored in `/etc/config/honk`.

## Runtime Paths

| Purpose | Path |
| --- | --- |
| Main configuration | /etc/honk/config.dae |
| Default template | /etc/honk/config.dae.default |
| Optional includes | /etc/honk/config.d/ |
| UCI service settings | /etc/config/honk |
| Init script | /etc/init.d/honk |
| Runtime log | /tmp/honk/honk.log |
| LuCI assets | /www/luci-static/resources/honk/app/ |

Validate and start from a shell:

~~~sh
honk-tool validate --config /etc/honk/config.dae --json
/etc/init.d/honk enable
/etc/init.d/honk start
~~~

`config.dae.default` is the complete package-provided Honk baseline and is not a conffile. The user-owned
`config.dae` is preserved across upgrades. If the active configuration is missing, the init script seeds it from
the template before running the normal `honk-tool validate` and Geo preflight. The LuCI Advanced page uses the same
template for its Restore defaults action, saves the current valid configuration as
`/etc/honk/config.dae.last-good`, and rolls back if replacement or reload fails.

The launcher writes Honk stdout and stderr to the runtime log. The init script does not configure procd stdout/stderr forwarding, so core output stays out of the system log.

## Routing

Honk evaluates routing rules from top to bottom. The first matching rule wins; fallback handles everything else. A typical split configuration is:

~~~dae
routing {
    dip(10.0.0.0/8, 172.16.0.0/12,
        192.168.0.0/16, 127.0.0.0/8) -> direct(must)
    dip(geoip: private) -> direct
    dip(geoip: cn) -> direct
    domain(geosite: cn) -> direct
    fallback: proxy
}
~~~

The proxy target can be a node or a group. A selector group can be populated from a subscription:

~~~dae
subscription {
    remote {
        url: 'https://example.invalid/subscribe'
        enabled: true
    }
}

group {
    proxy {
        filter: subscription('remote')
        policy: selector
        final: direct
    }
}
~~~

Rule mode follows the routing table. Global sends non-direct traffic to the selected primary node, while Direct sends non-must traffic directly. direct(must) and block decisions remain final across mode changes.

## DNS

DNS has its own upstream and request/response routing sections:

~~~dae
dns {
    upstream {
        local: 'udp://223.5.5.5:53'
        remote: 'https://dns.google/dns-query' -> proxy
    }
    routing {
        request {
            qname(geosite: cn) -> local
            fallback: remote
        }
        response {
            fallback: accept
        }
    }
}
~~~

Supported upstream prefixes are udp://, tcp://, tcp+udp://, tls://, https://, h3://, and quic://. The LuCI editor exposes the protocol, host, port, path, SNI, and outbound fields as form controls.

## Logs and Recovery

Inspect the bounded runtime log when a service action or node fails:

~~~sh
tail -n 200 /tmp/honk/honk.log
honk-tool validate --config /etc/honk/config.dae --json
~~~

If an applied configuration prevents startup, restore the last-good copy when present:

~~~sh
cp /etc/honk/config.dae.last-good /etc/honk/config.dae
honk-tool validate --config /etc/honk/config.dae --json
/etc/init.d/honk restart
~~~

Honk owns its TC, namespace, route, and eBPF lifecycle. Quick Setup does not create a second route model or configuration writer.

## Development Checks

~~~sh
bash tests/run-tests.sh
git diff --check
cd luci-app-honk/ui && npm ci && npm run build
~~~

The package checks verify source and patch digests, locked Geo payloads, shell/Lua syntax, RPC/menu manifests, generated assets, and the Quick Setup/transaction contracts used by the LuCI bridge.

## Upstream Documentation

- [Honk configuration guide](https://github.com/Glassyiris/honk/blob/main/doc/configuration.en.md)
- [Honk components guide](https://github.com/Glassyiris/honk/blob/main/doc/components.en.md)
- [Honk upstream repository](https://github.com/Glassyiris/honk)
