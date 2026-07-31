# Honk OpenWrt feed

This feed packages the Honk Rust/eBPF engine and its LuCI integration as two
packages:

- `honk`: `honk-core`, `honk-tool`, the procd service, and the main config.
- `luci-app-honk`: authenticated configuration management plus a compact,
  native runtime console for the Honk Clash API.

The daemon source is pinned to commit
`63e271065246bb68ecadf9ae53abecf748806ad3` (`v0.0.1.beta.25`). The package
supports OpenWrt `x86_64` and `aarch64` targets.

## Build

Install this checkout into an OpenWrt buildroot as a feed or package directory,
refresh package indexes, and enable both packages:

```sh
./scripts/feeds update honk
./scripts/feeds install -a -p honk
make menuconfig
make package/honk/compile V=s
make package/luci-app-honk/compile V=s
```

The build host needs the OpenWrt Rust host package, nightly `rust-src`,
`bpf-linker`, LLVM/libclang, CMake, and a target musl linker. Package compilation
builds and embeds the BTF-enabled eBPF object; it does not use prebuilt Honk
binaries.

## Install and operate

Install `honk` first and then `luci-app-honk`. The service uses these paths:

- Main configuration: `/etc/honk/config.dae`
- Optional include directory: `/etc/honk/config.d/`
- UCI service setting: `/etc/config/honk`
- Service: `/etc/init.d/honk`
- Runtime log: `/tmp/honk/honk.log` (kept out of `logread`)

Validate and start from the shell:

```sh
honk-tool validate --config /etc/honk/config.dae --json
/etc/init.d/honk enable
/etc/init.d/honk start
```

LuCI appears under **Services → Honk**. The single-page interface provides
overview, proxy selection and testing, active connections, effective rules,
configuration, and logs without embedding a second dashboard. On first access,
LuCI migrates legacy loopback/UI settings, creates a random API secret, and
enables selector persistence. `Save` writes the validated configuration without
restarting the daemon. `Save & Apply` validates, replaces the file atomically,
restarts Honk, and restores the previous disk configuration if the restart
fails. Concurrent editor sessions are protected with configuration revision
checks.

The service launcher writes both stdout and stderr to the runtime log, so Honk
diagnostics do not flood the system log. Changing `global.log_level` through
LuCI is applied to the running tracing filter after a successful configuration
reload; an invalid level leaves the previous configuration and filter intact.

## Recovery

If an edited configuration prevents startup, inspect the bounded service log at
`/tmp/honk/honk.log`,
restore `/etc/honk/config.dae.last-good` when present, validate it, and restart:

```sh
cp /etc/honk/config.dae.last-good /etc/honk/config.dae
honk-tool validate --config /etc/honk/config.dae --json
/etc/init.d/honk restart
```

Honk owns its TC, namespace, route, and eBPF lifecycle. The package does not add
iptables or nftables transparent-proxy rules.

## Development checks

```sh
bash tests/run-tests.sh
cd luci-app-honk/ui && npm ci && npm run build
```

The runtime console is built from `luci-app-honk/ui/` and installed below
`/www/luci-static/resources/honk/app/`. Honk serves the same directory through
its optional `/ui/` compatibility route, so it never downloads an external UI.
