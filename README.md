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

The standalone Honk binary builder additionally requires Rustup, Rust stable `1.97.1`, Rust nightly `nightly-2026-07-27` with `rust-src` and `llvm-tools`, Zig `0.14.1`, and `bpf-linker` `0.10.4`:

~~~sh
rustup toolchain install 1.97.1 --profile minimal \
  --target x86_64-unknown-linux-musl
rustup toolchain install nightly-2026-07-27 --profile minimal \
  --component rust-src --component llvm-tools
~~~

Install the aarch64 Rust target instead when building aarch64. The CI workflow downloads and verifies the eBPF linker as follows; use the same SHA-256 when installing it locally:

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

Building either LuCI dashboard requires Node.js 22 and npm. The package path itself does not install Rust when prebuilt Honk binaries are used.

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

When no binaries are staged under `honk/files/bin/`, the package recipe enters its source-build fallback. That path needs the OpenWrt Rust host package and the SDK's configured Rust/nightly toolchain; it is separate from the standalone Linux builder described below.

## Build

### Build Honk binaries from source

The standalone builder downloads the locked upstream archive, verifies its SHA-256, applies the local OpenWrt patch series, builds the eBPF object, and produces static musl binaries. Select one supported architecture:

~~~sh
export PACKAGE_ARCH=x86_64
export RUST_TARGET=x86_64-unknown-linux-musl
export RUST_STABLE_TOOLCHAIN=1.97.1
export BPF_RUST_TOOLCHAIN=nightly-2026-07-27
export ARTIFACTS_DIR="$PWD/.binary-output"
bash .github/scripts/build-honk-binaries.sh
~~~

For aarch64 use `PACKAGE_ARCH=aarch64` and `RUST_TARGET=aarch64-unknown-linux-musl`. Before compiling the OpenWrt package, stage the two executables so the package uses the prebuilt path:

~~~sh
install -d honk/files/bin
install -m 0755 .binary-output/honk-core .binary-output/honk-tool honk/files/bin/
~~~

### Build OpenWrt packages

When a matching binary Release already exists, download and verify it before running the fast package build. GitHub Actions performs this step automatically; locally, run one of:

~~~sh
PACKAGE_ARCH=x86_64 .github/scripts/download-honk-binaries.sh
PACKAGE_ARCH=aarch64 .github/scripts/download-honk-binaries.sh
~~~

Then install this checkout as an OpenWrt feed or place the package directories in the buildroot, refresh feeds, and select both packages:

~~~sh
./scripts/feeds update honk
./scripts/feeds install -a -p honk
make menuconfig
make package/honk/compile V=s
make package/luci-app-honk/compile V=s
make package/luci-app-honk-legacy/compile V=s
~~~

The SDK path only packages staged Honk binaries and does not compile Rust or eBPF. If both `honk-core` and `honk-tool` are absent from `honk/files/bin/`, OpenWrt falls back to its Rust package toolchain instead.

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

The `Build Honk binaries` workflow compiles Honk directly on standard Linux runners. Its two parallel jobs use Zig to cross-compile static musl binaries for x86_64 and aarch64; no OpenWrt SDK is involved. Each architecture archive contains `honk-core`, `honk-tool`, a manifest, and checksums.

After a binary release succeeds, `Build packages` downloads and verifies the matching archive, then starts the OpenWrt SDK matrix. LuCI-only changes reuse the existing binary release. The matrix builds:

- IPK packages for OpenWrt 24.10 on x86_64 and aarch64_generic.
- APK packages for OpenWrt 25.12 on x86_64 and aarch64_generic.

Each matrix job only packages the staged binaries, service files, and LuCI assets; it does not compile Rust or eBPF. It uploads `honk`, `luci-app-honk`, and `luci-app-honk-legacy` as workflow artifacts. After all four builds pass, the workflow publishes the same files in a versioned GitHub Release. The architecture and SDK are appended to release filenames so LuCI's architecture-independent packages are still easy to identify.

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

`/usr/share/honk/geo.lock.json` and `/run/honk/geo-assets.json` record provenance and the active receipt. A V2Fly or custom GeoSite path, a missing label, or a hash mismatch disables only presets that need the locked GeoSite. The confirmation-based Geo repair command recreates the Honk-owned symlink after verifying the packaged payload; it does not touch `/usr/share/v2ray` or download rules. A service restart is still required before the live receipt re-opens those presets.

Quick mutations are handled by `/usr/libexec/honk/quick-transaction-worker`. It keeps the previous bytes in a root-only sidecar, records each durable stage, and restores the prior running or stopped state after a failed restart, subscription wait, or probe. A failed recovery is reported as `degraded` and remains visible for operator action. Direct can be applied without a proxy subscription, while proxy presets require a non-empty, validated source group and the Geo/DNS/interface gates. Geo data is updated by changing the lock and package inputs, not through an online LuCI action.

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
