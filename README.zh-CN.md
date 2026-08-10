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
  clang llvm libbpf-dev libclang-dev pkg-config cmake lua5.4 ripgrep
~~~

源码构建在 OpenWrt SDK 容器内完成。SDK 辅助脚本会安装 Rustup、锁定的 BPF nightly 工具链、锁定的 Rust feed 提交，以及 `bpf-linker` `0.10.4`：

~~~sh
rustup toolchain install nightly-2026-07-20 --profile minimal \
  --component rust-src
~~~

SDK 辅助脚本会使用下面的 SHA-256 下载并校验 eBPF linker：

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

构建任一 LuCI 页面需要 Node.js 22 和 npm。Rust 和 eBPF linker 会在 SDK 构建容器内安装并用于源码构建。

### OpenWrt 运行依赖

`honk` 软件包声明 `ca-bundle`、`ip-full`、`tc-full`、`nsenter`、`libstdcpp`、`jq`、`kmod-sched-core`、`kmod-sched-bpf`、`kmod-veth`、`v2ray-geoip` 和 `v2ray-geosite`。新版 LuCI 还需要 `luci-base`、`luci-compat`、`curl`；旧版 LuCI 需要 `luci-base` 和 `luci-compat`。目标内核需要提供 `CONFIG_BPF`、`CONFIG_BPF_SYSCALL`、`CONFIG_BPF_JIT`、`CONFIG_CGROUP_BPF`、`CONFIG_NET_CLS_BPF`、`CONFIG_NET_SCH_INGRESS`、`CONFIG_NET_CLS_ACT`、`CONFIG_NET_NS`、`CONFIG_VETH` 和 `CONFIG_DEBUG_INFO_BTF`。

GeoSite 与 GeoIP 由 OpenWrt 的 `v2ray-geosite`、`v2ray-geoip` 软件包安装到 `/usr/share/v2ray/geosite.dat`、`/usr/share/v2ray/geoip.dat`。Honk 在构建和运行期间均不下载、打包、修改或锁定 Geo 数据；用户可通过 OpenWrt 软件包管理器自行安装和更新这些数据包。

## 构建

### 构建 OpenWrt 软件包

将本仓库作为 feed 安装，或把软件包目录放入 buildroot，刷新 feed 并选择这些软件包：

~~~sh
./scripts/feeds update honk
./scripts/feeds install -a -p honk
make menuconfig
make package/honk/download V=s
make package/honk/compile V=s
make package/luci-app-honk/compile V=s
make package/luci-app-honk-legacy/compile V=s
~~~

`package/honk/compile` 始终从 GitHub 下载 `source.mk` 锁定的 Honk 上游归档，校验软件包哈希，应用 `honk/patches/`，使用锁定的 nightly 工具链构建 eBPF 对象，再为目标 OpenWrt 架构构建 `honk-core` 和 `honk-tool`。不再使用 `honk/files/bin` staging 目录，也不依赖二进制 Release。

### 单独构建 LuCI 前端

~~~sh
for app in luci-app-honk/ui luci-app-honk-legacy/ui; do
  (cd "$app" && npm ci && npm run typecheck && npm run build)
done
~~~

生成资源分别提交在 `luci-app-honk/root/www/luci-static/resources/honk/app/` 和 `luci-app-honk-legacy/root/www/luci-static/resources/honk-legacy/app/`。

发布软件包前运行仓库检查：

~~~sh
rustup toolchain install 1.97.1 --profile minimal
bash tests/run-tests.sh
git diff --check
~~~

没有可复用的主机工具缓存时，检查会使用 Rust `1.97.1` 从锁定归档构建 `honk-tool`，再执行 LuCI 契约校验。

### GitHub Actions

`Update Honk upstream` 每天检查上游 `main`。发现新提交后，它会下载提交归档、计算 SHA-256 和 Git tree、验证本仓库的全部补丁，然后创建或更新 `automation/honk-upstream` PR。也可以从 Actions 页面手动运行该工作流。补丁冲突会直接中止更新，保留当前可构建版本。

`Build packages` 会在 OpenWrt SDK 矩阵中从源码构建全部 APK/IPK 变体。成功的 `main` 构建和手动构建会保存共享的 Cargo/Rustup/Rust feed/BPF 工具缓存，以及按 SDK 与目标架构隔离的 OpenWrt 下载和限制容量的 `sccache` 缓存。PR 只读取这些缓存而不写入。软件包构建目录和生成的 APK/IPK 不会进入缓存，因此每次运行仍会编译当前的 Honk 与 LuCI 源码。

`Build packages` 工作流在每个 OpenWrt SDK 矩阵任务中直接从锁定的上游源码构建 Honk。辅助脚本会安装锁定的 Rust host feed、nightly `rust-src` 和已校验的 `bpf-linker`，然后调用 `package/honk/download` 与 `package/honk/compile`。构建矩阵包括：

- OpenWrt 24.10：x86_64 和 aarch64_generic 的 IPK。
- OpenWrt 25.12：x86_64 和 aarch64_generic 的 APK。

每个矩阵任务都会上传刚刚编译出的 `honk`、`luci-app-honk` 和 `luci-app-honk-legacy` 三个工作流产物。四组构建全部通过后，软件包会发布到带版本号的 GitHub Release。发布文件名会追加架构和 SDK，便于区分 LuCI 的全架构软件包。

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

GeoSite 与 GeoIP 直接从 `/usr/share/v2ray` 读取。新版诊断页会分别显示文件存在状态、所属 OpenWrt 软件包、路径和文件大小；使用 OpenWrt 软件包管理器安装或更新 `v2ray-geosite`、`v2ray-geoip` 即可管理这些数据。

Quick mutation 由 `/usr/libexec/honk/quick-transaction-worker` 处理。它把旧配置字节保存到 root-only sidecar，记录每个可恢复阶段；重启、订阅等待或 probe 失败时恢复之前的运行或停止状态。恢复本身失败会明确标记为 `degraded`，等待运维处理。直连预设不要求代理订阅即可应用；其他预设必须有非空且已校验的源组，并通过 Geo、DNS、接口门禁。

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

## 运行数据

OpenWrt 软件包将 `global.data_dir` 设为 `/var/share/honk`，并使用
`udp://223.5.5.5:53` 作为代理服务器域名的直连 bootstrap 解析器。订阅响应缓存
保存在 `/var/share/honk/.sub`，目录和文件仅允许 root 访问。升级时服务启动
前会把 r21 之前的 `/etc/honk/.sub` 缓存迁移到新目录；全新安装不会再创建旧目录。

规则模式遵循 routing 表；全局模式将非直连流量发送到当前主节点；直连模式将非 must 流量直接发送。direct(must) 和 block 在模式切换时保持最终决定。

## DNS

DNS 有独立的上游、请求路由和响应路由：

~~~dae
dns {
	bind: 'tcp+udp://127.0.0.1:1053'
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

`dnsmasq_forwarding` 默认开启。Honk 在 `127.0.0.1:1053` 同时监听 TCP 和 UDP；启动器确认两种监听均就绪后，才临时写入 dnsmasq 的 `no-resolv` 和 `server=127.0.0.1#1053` 配置。这样路由器本机和 LAN 客户端的 DNS 都会进入 Honk 的 DNS 路由、缓存和上游选择链路，同时不会替换 `/etc/resolv.conf`。停止或核心异常退出时会删除临时配置并重启 dnsmasq；用户已有的域名专用 dnsmasq 规则保持不变。

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

检查脚本会校验源码和补丁摘要、OpenWrt Geo 软件包集成、Shell/Lua 语法、RPC/menu 清单、构建资源以及 LuCI 桥接使用的 Quick Setup/事务契约。

## 上游文档

- [Honk 配置文档](https://github.com/Glassyiris/honk/blob/main/doc/configuration.zh.md)
- [Honk 组件文档](https://github.com/Glassyiris/honk/blob/main/doc/components.zh.md)
- [Honk 上游仓库](https://github.com/Glassyiris/honk)
