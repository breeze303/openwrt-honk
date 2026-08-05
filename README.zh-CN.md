# Honk OpenWrt Feed

[English](README.md) | 简体中文

本仓库将 [Honk](https://github.com/Glassyiris/honk) Rust/eBPF 透明代理引擎打包为 OpenWrt 软件包，并提供原生 LuCI 管理界面。

包含三个软件包：

- honk：honk-core、honk-tool、procd 服务、默认配置、eBPF 资源和运行日志。
- luci-app-honk：新版独立 LuCI 控制器、模式/DNS 生成器、节点与设备规则、诊断和前端页面。
- luci-app-honk-legacy：保留的旧版 LuCI 页面，用于回滚和迁移参考，拥有独立控制器、ACL、菜单、API 和静态资源命名空间。

构建使用 `locks/source.lock.json` 中记录的上游提交，当前支持 OpenWrt x86_64 和 aarch64。定时工作流每天检查 Honk `main`，并为通过源码、哈希和补丁验证的新提交创建更新 PR。

## 界面展示

管理界面是原生 LuCI 单页应用，不会下载或嵌入第二套外部面板。

| 概览 | 配置 |
| --- | --- |
| ![Honk 概览](docs/screenshots/overview.png) | ![Honk 配置](docs/screenshots/configuration.png) |

移动端会自动切换为窄屏布局：

![Honk 移动端概览](docs/screenshots/mobile-overview.png)

## 功能

- 由 OpenWrt procd 管理的 Rust/eBPF 透明代理运行时。
- 按顺序匹配 routing 规则，支持直连、代理、阻断、节点组和 direct(must)。
- 通过 Clash 兼容 API 提供规则、全局、直连三种运行模式。
- 节点导入、编辑、删除、连接测试、订阅和选择器分组。
- 支持 UDP、TCP、TCP+UDP、TLS、HTTPS、H3、QUIC DNS 上游。
- 独立的 DNS 请求路由和响应路由配置。
- 实时流量、连接、内存、节点、规则和服务状态。
- Honk 日志写入 /tmp/honk/honk.log，不转发到 logread。
- 保存/应用流程包含配置校验、版本检查、原子替换和重启回滚。

## 目录结构

~~~text
honk/                  Honk 引擎和服务的 OpenWrt 配方
luci-app-honk/         新版独立 LuCI 软件包和前端源码
luci-app-honk-legacy/  保留的旧版 LuCI 软件包和前端源码
honk/patches/          OpenWrt 专用上游补丁
locks/source.lock.json 源码和补丁摘要锁定文件
tests/                 打包和集成检查
~~~

## 构建要求

软件包只支持 x86_64 和 aarch64。下面的构建依赖安装在宿主机，运行依赖则安装到 OpenWrt 固件中。

### 宿主机构建依赖

以下命令以 Ubuntu/Debian 为例，其他 Linux 发行版需要提供等价的软件包：

~~~sh
sudo apt-get update
sudo apt-get install -y \
  git curl jq patch tar gzip zstd binutils \
  clang llvm libbpf-dev libclang-dev pkg-config cmake
~~~

独立 Honk 二进制构建还需要 Rustup、Rust stable `1.97.1`、带 `rust-src` 和 `llvm-tools` 的 `nightly-2026-07-27`、Zig `0.14.1` 以及 `bpf-linker` `0.10.4`：

~~~sh
rustup toolchain install 1.97.1 --profile minimal \
  --target x86_64-unknown-linux-musl
rustup toolchain install nightly-2026-07-27 --profile minimal \
  --component rust-src --component llvm-tools
~~~

构建 aarch64 时将 Rust target 换成对应的 aarch64 target。CI 会按下面的方式下载并校验 eBPF linker，本地安装也应使用相同 SHA-256：

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

构建任一 LuCI 页面需要 Node.js 22 和 npm。使用预编译 Honk 二进制的 SDK 打包路径不需要在 SDK 容器中安装 Rust。

### OpenWrt 运行依赖

`honk` 软件包声明 `ca-bundle`、`ip-full`、`tc-full`、`nsenter`、`libstdcpp`、`jq`、`kmod-sched-core`、`kmod-sched-bpf` 和 `kmod-veth`。新版 LuCI 还需要 `luci-base`、`luci-compat`、`curl`；旧版 LuCI 需要 `luci-base` 和 `luci-compat`。目标内核需要提供 `CONFIG_BPF`、`CONFIG_BPF_SYSCALL`、`CONFIG_BPF_JIT`、`CONFIG_CGROUP_BPF`、`CONFIG_NET_CLS_BPF`、`CONFIG_NET_SCH_INGRESS`、`CONFIG_NET_CLS_ACT`、`CONFIG_NET_NS`、`CONFIG_VETH` 和 `CONFIG_DEBUG_INFO_BTF`。

GeoSite、GeoIP 只使用 `locks/geo.lock.json` 中的精确输入。Honk 自己拥有 `/usr/lib/honk` 和 `/usr/share/honk`，不依赖目标包管理器提供的 `v2ray-*` Geo 包。在源码检出目录准备锁定资源：

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

`honk/files/bin/` 中没有两个成品时，软件包配方会进入源码构建 fallback。该路径需要 OpenWrt Rust host 软件包和 SDK 自己配置的 Rust/nightly 工具链，与下面的独立 Linux 主机构建路径不同。

## 构建

### 从源码构建 Honk 二进制

独立构建脚本会下载锁定的上游归档、校验 SHA-256、应用 OpenWrt 补丁、构建 eBPF 对象，并生成静态 musl 二进制。选择一个支持的架构：

~~~sh
export PACKAGE_ARCH=x86_64
export RUST_TARGET=x86_64-unknown-linux-musl
export RUST_STABLE_TOOLCHAIN=1.97.1
export BPF_RUST_TOOLCHAIN=nightly-2026-07-27
export ARTIFACTS_DIR="$PWD/.binary-output"
bash .github/scripts/build-honk-binaries.sh
~~~

aarch64 使用 `PACKAGE_ARCH=aarch64` 和 `RUST_TARGET=aarch64-unknown-linux-musl`。编译 OpenWrt 软件包前将两个成品放入预编译目录：

~~~sh
install -d honk/files/bin
install -m 0755 .binary-output/honk-core .binary-output/honk-tool honk/files/bin/
~~~

### 构建 OpenWrt 软件包

如果已有匹配的二进制 Release，先下载并校验对应架构的成品。GitHub Actions 会自动执行；本地可以运行：

~~~sh
PACKAGE_ARCH=x86_64 .github/scripts/download-honk-binaries.sh
PACKAGE_ARCH=aarch64 .github/scripts/download-honk-binaries.sh
~~~

然后将本仓库作为 feed 安装，或把软件包目录放入 buildroot，刷新 feed 并在 menuconfig 中选择两个软件包：

~~~sh
./scripts/feeds update honk
./scripts/feeds install -a -p honk
make menuconfig
make package/honk/compile V=s
make package/luci-app-honk/compile V=s
make package/luci-app-honk-legacy/compile V=s
~~~

SDK 路径只封装已放入目录的 Honk 二进制，不编译 Rust 或 eBPF。如果 `honk/files/bin/` 中缺少 `honk-core` 或 `honk-tool`，OpenWrt 会自动切换到 Rust package toolchain 的源码 fallback。

### 单独构建 LuCI 前端

~~~sh
for app in luci-app-honk/ui luci-app-honk-legacy/ui; do
  (cd "$app" && npm ci && npm run typecheck && npm run build)
done
~~~

生成资源分别提交在 `luci-app-honk/root/www/luci-static/resources/honk/app/` 和 `luci-app-honk-legacy/root/www/luci-static/resources/honk-legacy/app/`。

发布软件包前运行仓库检查：

~~~sh
bash tests/run-tests.sh
git diff --check
~~~

### GitHub Actions

`Update Honk upstream` 每天检查上游 `main`。发现新提交后，它会下载提交归档、计算 SHA-256 和 Git tree、验证本仓库的全部补丁，然后创建或更新 `automation/honk-upstream` PR。也可以从 Actions 页面手动运行该工作流。补丁冲突会直接中止更新，保留当前可构建版本。

`Build Honk binaries` 工作流直接在标准 Linux Runner 上编译 Honk。两个并行任务通过 Zig 分别生成 x86_64 和 aarch64 的静态 musl 成品，全程不使用 OpenWrt SDK。每个架构归档包含 `honk-core`、`honk-tool`、构建清单和校验文件。

二进制发布成功后，`Build packages` 会下载并校验对应归档，再启动 OpenWrt SDK 矩阵。只修改 LuCI 时会复用现有二进制发布。构建矩阵包括：

- OpenWrt 24.10：x86_64 和 aarch64_generic 的 IPK。
- OpenWrt 25.12：x86_64 和 aarch64_generic 的 APK。

每个矩阵任务只封装已下载的二进制、服务文件和 LuCI 资源，不再编译 Rust 或 eBPF，并上传 `honk`、`luci-app-honk` 和 `luci-app-honk-legacy` 三个工作流产物。四组构建全部通过后，同一批文件会发布到带版本号的 GitHub Release。发布文件名会追加架构和 SDK，便于区分 LuCI 的全架构软件包。

## 安装

先安装 honk，再安装新版 luci-app-honk。只有需要回滚或参考旧页面时才安装 luci-app-honk-legacy；两者路径完全隔离。根据目标系统使用对应的软件包管理器：

~~~sh
# 使用 apk 的 OpenWrt snapshot
apk add ./honk-*.apk ./luci-app-honk-*.apk

# 使用 opkg 的系统
opkg install honk-*.ipk luci-app-honk-*.ipk
~~~

LuCI 页面地址：

~~~text
/cgi-bin/luci/admin/services/honk
~~~

新版页面地址为 `/cgi-bin/luci/admin/services/honk`，旧版页面地址为 `/cgi-bin/luci/admin/services/honk-legacy/`。新版控制器会保留现有节点、订阅、experimental 和未知 section，只重建自己管理的模式 section。每次应用都会校验、备份、原子写入、重启、健康检查，失败时恢复上一份配置。

## Quick Setup 与 Geo 资产

Quick Setup 永远是 Honk 的首个页面。它复用现有订阅和节点数据，只写入唯一的 `/etc/honk/config.dae` 运行配置。四个预设为 GFWList、中国直连、全局代理和直连。每次预览都会展示选中的源组、发现到的 LAN/WAN 设备、路由/DNS 投影、版本以及服务端生成的候选摘要，确认后才允许应用。高级编辑器仍然保留；高级配置被识别为用户拥有时，替换必须显式确认。

软件包把锁定资产安装在 Honk 自己拥有的路径：

| 资产 | 锁定输入 | 安装 payload | 对外加载路径 |
| --- | --- | --- | --- |
| GeoSite | Loyalsoldier release `202607312254`，SHA-256 `1f3a743e8e30152a870a1674792af3976361436dcb1f510a43c499d430f6b13f` | `/usr/lib/honk/geosite.dat` | `/usr/share/honk/geosite.dat` |
| GeoIP | V2Fly release `202607171233`，SHA-256 `b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a` | `/usr/lib/honk/geoip.dat` | `/usr/share/honk/geoip.dat` |

`/usr/share/honk/geo.lock.json` 和 `/run/honk/geo-assets.json` 记录来源与生效 receipt。检测到 V2Fly/custom GeoSite 路径、标签缺失或哈希不匹配时，只会禁用依赖锁定 GeoSite 的预设。需要确认的 Geo 修复操作会先验证包内 payload，再重建 Honk 自己拥有的 symlink；不会触碰 `/usr/share/v2ray`，也不会下载规则。修复后仍需显式重启服务，直到 live receipt 匹配才重新开放这些预设。

Quick mutation 由 `/usr/libexec/honk/quick-transaction-worker` 处理。它把旧配置字节保存到 root-only sidecar，记录每个可恢复阶段；重启、订阅等待或 probe 失败时恢复之前的运行或停止状态。恢复本身失败会明确标记为 `degraded`，等待运维处理。直连预设不要求代理订阅即可应用；其他预设必须有非空且已校验的源组，并通过 Geo、DNS、接口门禁。Geo 数据通过更新 lock 与软件包输入升级，不提供在线 LuCI 更新入口。

## 运行路径

| 用途 | 路径 |
| --- | --- |
| 主配置 | /etc/honk/config.dae |
| 默认模板 | /etc/honk/config.dae.default |
| 可选配置片段 | /etc/honk/config.d/ |
| UCI 服务设置 | /etc/config/honk |
| init 脚本 | /etc/init.d/honk |
| 运行日志 | /tmp/honk/honk.log |
| LuCI 资源 | /www/luci-static/resources/honk/app/ |

命令行校验和启动：

~~~sh
honk-tool validate --config /etc/honk/config.dae --json
/etc/init.d/honk enable
/etc/init.d/honk start
~~~

`config.dae.default` 是软件包提供的完整 Honk 基线，不作为 conffile；`config.dae` 是用户实际配置，
升级时不会被覆盖。实际配置缺失时，init 脚本会先从默认模板初始化，再执行同样的 `honk-tool validate`
和 Geo 资源预检。LuCI 高级设置页的「恢复默认配置」也使用这份模板，恢复前会把当前有效配置保存到
`/etc/honk/config.dae.last-good`，原子替换失败或重载失败时自动回滚。

启动器会将 Honk 的标准输出和标准错误写入运行日志。init 脚本不设置 procd stdout/stderr 转发，因此核心日志不会进入系统日志。

## 分流

Honk 按从上到下的顺序匹配 routing 规则，第一条命中的规则生效，未命中时使用 fallback：

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

proxy 可以是单个节点或节点组。订阅可用于填充 selector 分组：

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

规则模式遵循 routing 表；全局模式将非直连流量发送到当前主节点；直连模式将非 must 流量直接发送。direct(must) 和 block 在模式切换时保持最终决定。

## DNS

DNS 有独立的上游、请求路由和响应路由：

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

支持的上游协议前缀为 udp://、tcp://、tcp+udp://、tls://、https://、h3:// 和 quic://。LuCI 表单可以编辑协议、主机、端口、路径、SNI 和出口。

## 日志与恢复

服务或节点异常时查看运行日志：

~~~sh
tail -n 200 /tmp/honk/honk.log
honk-tool validate --config /etc/honk/config.dae --json
~~~

应用后的配置导致服务启动失败时，可在备份存在的情况下恢复：

~~~sh
cp /etc/honk/config.dae.last-good /etc/honk/config.dae
honk-tool validate --config /etc/honk/config.dae --json
/etc/init.d/honk restart
~~~

Honk 自己管理 TC、namespace、路由和 eBPF 生命周期。Quick Setup 不创建第二套路由模型或配置写入器。

## 开发检查

~~~sh
bash tests/run-tests.sh
git diff --check
cd luci-app-honk/ui && npm ci && npm run build
~~~

检查脚本会校验源码和补丁摘要、锁定 Geo payload、Shell/Lua 语法、RPC/menu 清单、构建资源以及 LuCI 桥接使用的 Quick Setup/事务契约。

## 上游文档

- [Honk 配置文档](https://github.com/Glassyiris/honk/blob/main/doc/configuration.zh.md)
- [Honk 组件文档](https://github.com/Glassyiris/honk/blob/main/doc/components.zh.md)
- [Honk 上游仓库](https://github.com/Glassyiris/honk)
