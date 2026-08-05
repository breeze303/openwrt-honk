# Honk 网络接口自动检测与拨号模式计划

状态：已完成
保存时间：2026-08-04

## 目标

1. 在 Honk LuCI 页面展示可用的实际三层网络设备，并允许用户分别选择 LAN/WAN。
2. 保持默认配置中的 `lan_interface: auto`、`wan_interface: auto`，首次启动仅在配置仍为原始默认模板时尝试自动解析。
3. 在 LuCI 中提供四种拨号模式：`ip`、`domain`、`domain+`、`domain++`，并保留配置文件中其他字段和未知内容。
4. 不修改上游 `honk/` Rust/eBPF 源码；功能放在 `openwrt-honk` 的补丁、init、LuCI 和外围脚本中。
5. 编译后部署到测试虚拟机 `root@192.168.1.230:2222`，验证页面 API、配置持久化和服务运行状态。

## 实施步骤

### 1. 网络发现模型

- 新增 LuCI Lua 网络模型，调用：
  - `network.interface` 的 `dump`
  - `network.device` 的 `status`
- 返回每个接口的逻辑名、实际 L3 设备名、设备类型、地址、是否在线、默认路由及 metric。
- 推荐规则：
  - LAN：优先选择逻辑接口 `lan` 且拥有地址的实际 L3 设备。
  - WAN：选择 metric 最低且状态正常的默认路由设备。
  - LAN/WAN 缺失、候选不安全或二者相同时标记 `ambiguous`，保留 `auto` 并要求用户显式选择。
- API 返回当前配置、推荐值、候选列表、原因码和配置 revision。

### 2. 首次启动自动解析

- 安装 `/usr/libexec/honk/interface-discovery` 辅助脚本，并由 `honk.init` 调用。
- 只有活动配置与 `/etc/honk/config.dae.default` 完全一致时才执行自动写入。
- 成功发现不同的 LAN/WAN 实际设备后，仅替换 global 段的 `lan_interface`/`wan_interface`，先通过 `honk-tool validate` 再原子替换。
- 歧义或发现失败时不改变配置，继续使用 `auto`，写入 `/run/honk/interface-discovery.json` 并记录 warning。
- 用户已经修改过的活动配置保持原样，不被包升级或服务重启覆盖。

### 3. LuCI API 与权限

- 增加 GET `network_interfaces`。
- 增加 POST `apply_interfaces`，包含：
  - `lanDevice`
  - `wanDevice`
  - `dialMode`
  - `expectedRevision`
- 使用现有的校验、锁、备份、原子写入、服务切换和回滚事务。
- 校验设备必须来自当前发现结果、处于可用状态且 LAN/WAN 不相同。
- `dialMode` 仅允许 `ip`、`domain`、`domain+`、`domain++`。
- ACL 增加只读权限：
  - `network.interface: dump`
  - `network.device: status`
- 菜单 JSON 增加两个 API 路由。

### 4. LuCI 页面

- 在 Advanced 页面新增“网络接口绑定”区域：刷新发现、LAN 下拉框、WAN 下拉框、候选设备信息、歧义警告、应用按钮。
- 新增拨号模式下拉框及四种模式的中文说明：
  - `ip`：简单 IP 路由，不嗅探。
  - `domain`：默认模式，嗅探并校验目的 IP。
  - `domain+`：DNS 不经过 Honk 时使用。
  - `domain++`：强制嗅探并按 SNI/Host 重路由。
- 应用时使用 revision guard，成功后刷新当前配置和服务状态。
- 采用响应式两列布局，移动端降为单列；不引入节点行高缩放按钮。
- 补齐中英文 i18n 文案，并重新生成提交后的 LuCI 静态资源。

### 5. 测试、构建与部署

- 增加网络发现、默认模板保护、拨号模式白名单和 API 路由契约测试。
- 执行：
  - Lua 语法检查
  - JSON 解析检查
  - `git diff --check`
  - LuCI `npm run typecheck`
  - LuCI `npm run build`
  - 现有 `tests/test-default-config.sh`
  - 现有 LuCI/init/事务测试
- 使用 ImmortalWrt SDK 编译 Honk 与 LuCI APK。
- 上传并安装到：`192.168.1.230:2222`，用户 `root`，临时密码记录在项目运维记录中。
- 远端验证：
  - API 返回网络候选和当前值。
  - 自定义配置的 SHA 在重启/重装后保持不变。
  - 默认模板场景可自动解析或按歧义规则保留 `auto`。
  - 应用 LAN/WAN/拨号模式后服务重载成功且配置可读。

## 验收条件

- 上游 `honk/` 源码无本地功能改动。
- 默认配置未被静默覆盖；自定义配置不会被首次启动逻辑改写。
- LuCI 能分别选择实际 L3 设备并保存四种拨号模式。
- 检测歧义时有明确提示，且不会写入错误接口。
- 编译、测试、部署和远端运行检查全部完成，并记录结果。

## 执行记录

- LuCI `npm run typecheck`、Vite build、Lua/JSON 语法检查、网络发现与事务契约测试均通过。
- ImmortalWrt x86_64 SDK 成功生成 Honk 与 LuCI APK；SDK 中既有的缺失依赖和内核包告警未阻断目标包。
- 虚拟机 `root@192.168.1.230:2222` 已安装最终 APK。实际发现结果为 LAN `br-lan`、WAN `eth1`，候选列表排除了 `lo`。
- 最终 APK SHA256：`honk`=`af5f10444a49bcacf752edb725982fd7c9017213034be97509630d3233ffdeb5`，`luci-app-honk`=`9af007c4e393e2bfff8f7d58abc1d9b10ded341f72dc2141897a658c01a89a96`。
- 自定义配置安装前后及重启后 SHA 均为 `685d17824dbf8b1ec213c1e65a9f78f9493430ff7b6f0a34ac3d38f2cc2ce6de`；默认模板临时副本可自动解析并通过 `honk-tool validate`。
- 首次部署发现模型文件名 `network.lua` 会覆盖系统 `luci-compat` 文件，已改为 `honk_network.lua`，并确认远端无 `/usr/lib/lua/luci/model/network.lua` 残留。
- 追加修复完整配置同步：接口应用响应返回已提交配置，完整配置应用前同步 LAN/WAN/拨号模式；事务回归测试通过。后续修正刷新顺序，确保接口响应不会被状态刷新覆盖；最终 LuCI APK SHA256：`994ef45c38f871915f7923a76d9c72e2bd9c80d6873f62fbba4c945a2759245b`，已部署并确认远端服务仍为 `running`。
- 高级设置拆分为“全局设置”和“完整配置”两个子页面，分别使用 `#/advanced/global` 与 `#/advanced/config`；完整配置存在未保存修改时切换会提示并重新加载。LuCI typecheck、build、契约测试及 SDK 编译通过；本次 APK SHA256：`a6acb083e61877c7e8f09a913ff44a9a794dcd8d4b38fb8b8d05ded5231f49a8`，已部署到测试虚拟机并确认服务为 `running`。
- 修复接口应用重复追加 `lan_interface`、`wan_interface`、`dial_mode` 的问题：Lua/前端同步现在会替换并去重全局键，重复应用回归测试通过；已清理虚拟机历史重复配置并保留最后一次选择，修复版 APK SHA256：`44535fcd8d0eb53b8db9878307c055b4dcc979d312643ec10d3c12cdba667243`。
- 修复 Clash API 关闭时报 HTML 404 的问题：补注册 `toggle_clash_api` LuCI 路由，并为前端非 JSON 响应增加 HTTP 错误兜底；LuCI typecheck、build、契约测试通过，修复版 APK SHA256：`a93141c6611017df89e4b18fbe8822857a736d6f7622959200f5a72218d1d6db`，已部署并确认远端服务为 `running`。
- 保留订阅 endpoint identity 告警原级别，用于暴露持续发生的订阅/节点问题；同时为 Honk 日志增加路由器本地时区计时器，并在 LuCI 展示层将历史 `Z` 时间戳转换为本地带时区偏移的时间。
- 重新编译并部署本地时区修复版 Honk：`honk` APK SHA256 为 `653b50fe9ec93ccf8f708df7e35776154a535ef89c810fadf44d0a5e57e66b4e`；LuCI 时间展示修正版 APK SHA256 为 `1239fa7b508f2ee3bbd08fb9f16c5cb4e272efdc0f60849b3d58e10c461c238e`。虚拟机 `192.168.1.230:2222` 保持现有配置，服务状态为 `running`，新产生的重复 endpoint 日志已显示为 `+08:00`。
