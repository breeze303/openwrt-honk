# Honk OpenWrt Feed

English | [简体中文](README.zh-CN.md)

This repository packages [Honk](https://github.com/Glassyiris/honk), a Rust/eBPF transparent proxy engine, for OpenWrt together with a native LuCI management interface.

The feed contains two packages:

- honk: honk-core, honk-tool, the procd service, default configuration, eBPF assets, and runtime logging.
- luci-app-honk: the authenticated LuCI controller, RPC bridge, configuration editor, node and subscription management, runtime dashboard, traffic view, and logs.

The upstream source is pinned to commit 63e271065246bb68ecadf9ae53abecf748806ad3 (v0.0.1.beta.25). The package currently targets OpenWrt x86_64 and aarch64.

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
luci-app-honk/         LuCI package, RPC bridge, and dashboard source
honk/patches/          OpenWrt-specific upstream patches
locks/source.lock.json Source and patch digest lock file
tests/                 Focused packaging and integration checks
~~~

## Requirements

The package recipe supports x86_64 and aarch64 targets. The buildroot needs:

- OpenWrt buildroot and the packages feed Rust host support
- Rust nightly with rust-src
- bpf-linker, LLVM/libclang, CMake, and a target musl linker
- v2ray-geoip, v2ray-geosite, kmod-sched-core, kmod-sched-bpf, and kmod-veth

The build compiles the userspace binaries and the BTF-enabled eBPF object. It does not use prebuilt Honk binaries.

## Build

Install this checkout as an OpenWrt feed or place the package directories in the buildroot, then refresh feeds and select both packages:

~~~sh
./scripts/feeds update honk
./scripts/feeds install -a -p honk
make menuconfig
make package/honk/compile V=s
make package/luci-app-honk/compile V=s
~~~

For the dashboard source alone:

~~~sh
cd luci-app-honk/ui
npm ci
npm run build
~~~

The generated LuCI assets are committed below luci-app-honk/root/www/luci-static/resources/honk/app/.

### GitHub Actions

The `Build packages` workflow runs after package or dashboard changes are pushed to `master`, and can also be started manually from the Actions page. It builds:

- IPK packages for OpenWrt 24.10 on x86_64 and aarch64_generic.
- APK packages for OpenWrt 25.12 on x86_64 and aarch64_generic.

Each matrix job uploads `honk` and `luci-app-honk` as a workflow artifact. After all four builds pass, the workflow publishes the same files in a versioned GitHub Release. The architecture and SDK are appended to release filenames so LuCI's architecture-independent package is still easy to identify.

The separate `Build Honk binaries` workflow runs only when the pinned Honk source, OpenWrt patches, or its own build definition changes. It publishes versioned archives containing `honk-core`, `honk-tool`, a manifest, and checksums for all four architecture/SDK combinations. These archives are intended as the input for fast package-only builds that do not rebuild Rust after LuCI-only changes.

## Install

Build or download both packages, install honk first, then luci-app-honk. Use the package manager provided by the target image:

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

On first access, the LuCI bridge can migrate legacy loopback/UI settings, create an API secret, and persist the selected primary node. Save writes a validated configuration. Save & Apply validates, replaces the configuration atomically, restarts Honk, and restores the previous disk configuration if restart fails. Revision checks prevent one browser session from silently overwriting another.

## Runtime Paths

| Purpose | Path |
| --- | --- |
| Main configuration | /etc/honk/config.dae |
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

Honk owns its TC, namespace, route, and eBPF lifecycle. This feed does not install host iptables or nftables TPROXY rules.

## Development Checks

~~~sh
bash tests/run-tests.sh
git diff --check
cd luci-app-honk/ui && npm ci && npm run build
~~~

The package checks verify source and patch digests, shell/Lua syntax, RPC/menu manifests, generated assets, and the dashboard contracts used by the LuCI bridge.

## Upstream Documentation

- [Honk configuration guide](https://github.com/Glassyiris/honk/blob/main/doc/configuration.en.md)
- [Honk components guide](https://github.com/Glassyiris/honk/blob/main/doc/components.en.md)
- [Honk upstream repository](https://github.com/Glassyiris/honk)
