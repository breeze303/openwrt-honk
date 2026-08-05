<script setup lang="ts">
import { computed, nextTick, onMounted, ref } from "vue";
import {
  api,
  type ConfigModel,
  type DnsUpstream,
  type NodeTestResponse,
  type ParsedNode,
  type PreviewResponse,
  type StateResponse,
} from "./api";
import DnsTopology from "./components/DnsTopology.vue";

type Tab =
  | "overview"
  | "global"
  | "nodes"
  | "routing"
  | "dns"
  | "logs"
  | "advanced";
type OutboundTraffic = {
  id: number;
  txBytes?: string;
  rxBytes?: string;
  txBytesPerSecond?: string;
  rxBytesPerSecond?: string;
};
type TrafficStats = {
  ok?: boolean;
  available?: boolean;
  sampleMs?: number;
  overflow?: { tcp?: string; udp?: string };
  occupancy?: { live?: string; inserts?: string; deletes?: string };
  outbounds?: OutboundTraffic[];
};

const emptyModel = (): ConfigModel => ({
  global: {},
  nodes: [],
  groups: [],
  subscriptions: [],
  routing: { rules: [], fallback: "direct" },
  dns: {
    raw: "",
    upstreams: [],
    requestRules: [],
    requestFallback: "",
    responseRules: [],
    responseFallback: "accept",
  },
  experimental: { raw: "" },
  rawConfig: "",
});

const state = ref<StateResponse | null>(null);
const model = ref<ConfigModel>(emptyModel());
const advancedCode = ref("");
const activeTab = ref<Tab>("global");
const busy = ref(false);
const message = ref("");
const error = ref("");
const logs = ref("");
const traffic = ref<TrafficStats | null>(null);
const showPreview = ref(false);
const preview = ref<PreviewResponse | null>(null);
const nodeLink = ref("");
const nodeSearch = ref("");
const selectedNode = ref<ParsedNode | null>(null);
const nodeDraft = ref<ParsedNode | null>(null);
const nodeTest = ref<NodeTestResponse | null>(null);
const nodeBusy = ref(false);
const showSecrets = ref(false);
const testTarget = ref("cp.cloudflare.com:443");
const testUrl = ref("https://www.gstatic.com/generate_204");
const newRule = ref("");
const newDnsName = ref("");
const newDnsProtocol = ref("udp");
const newDnsHost = ref("");
const newDnsPort = ref(53);
const newDnsPath = ref("/dns-query");
const newDnsSni = ref("");
const newDnsOutbound = ref("direct");
const newGroupName = ref("");
const newGroupPolicy = ref("min_moving_avg");
const newGroupFinal = ref("direct");
const newGroupFilter = ref("");
const newGroupDefault = ref("");
const newSubscriptionName = ref("");
const newSubscriptionUrl = ref("");
const dnsRequestFallback = ref("");
const dnsResponseFallback = ref("accept");
const dnsRequestRules = ref<string[]>([]);
const dnsResponseRules = ref<string[]>([]);
const dnsRuleType = ref("qname");
const dnsRuleMatch = ref("suffix");
const dnsRuleValue = ref("");
const dnsRuleAction = ref("");
const dnsResponseSource = ref("");
const dnsResponseTarget = ref("");
const dnsEditingName = ref("");
const dnsEditor = ref<HTMLElement | null>(null);
const experimentalController = ref("0.0.0.0:9090");
const experimentalUi = ref("/www/luci-static/resources/honk-legacy/app");
const experimentalMode = ref("Rule");
const experimentalSecret = ref("");
const experimentalCacheEnabled = ref(true);
const experimentalCachePath = ref("/etc/honk/cache.db");
const experimentalCacheId = ref("");
const experimentalStoreFakeip = ref(false);
const experimentalStoreDns = ref(false);
const zh = true;
const text = zh
  ? {
      overview: "概览",
      nodes: "节点",
      routing: "路由",
      dns: "DNS",
      logs: "运行日志",
      advanced: "高级",
      globalSettings: "全局设置",
      globalHint: "透明代理、健康检查、解析和 TLS 参数",
      running: "运行中",
      stopped: "已停止",
      validate: "校验",
      save: "保存",
      apply: "保存并应用",
      start: "启动",
      stop: "停止",
      restart: "重启",
      reload: "重载",
      valid: "配置有效",
      saved: "已保存",
      applied: "已应用",
      config: "原始配置",
      traffic: "流量统计",
      unavailable: "暂不可用",
      download: "下载",
      upload: "上传",
      rate: "实时速率",
      total: "累计流量",
      active: "活动连接",
      overflow: "溢出",
      noTraffic: "等待流量数据",
      noLogs: "暂无日志",
      unsaved: "存在未应用修改",
      importNode: "导入分享链接",
      parse: "解析",
      add: "添加节点",
      edit: "编辑",
      remove: "删除",
      test: "测速",
      testing: "测试中",
      name: "名称",
      protocol: "协议",
      host: "服务器",
      port: "端口",
      sni: "SNI",
      password: "凭据",
      network: "传输",
      insecure: "跳过证书校验",
      saveNode: "保存节点",
      cancel: "取消",
      noNodes: "还没有节点",
      runtimeNodes: "运行时节点",
      runtimeNode: "订阅运行时",
      runtimeNodeHint: "订阅节点由 Honk 运行时提供，刷新服务后会自动同步。",
      refreshNodes: "刷新节点",
      search: "搜索节点",
      rules: "规则",
      fallback: "默认出口",
      addRule: "添加规则",
      removeRule: "删除规则",
      groups: "代理组",
      subscriptions: "订阅",
      noSubscriptions: "尚未添加订阅",
      upstreams: "DNS 上游",
      address: "地址",
      addDns: "添加上游",
      dnsProtocol: "协议前缀",
      dnsHost: "主机地址",
      dnsPort: "端口",
      dnsPath: "路径",
      dnsOutbound: "代理出口",
      dnsRequestRouting: "请求路由",
      dnsResponseRouting: "响应路由",
      dnsRequestFallback: "未命中请求规则",
      dnsResponseFallback: "未命中响应规则",
      dnsRuleType: "条件类型",
      dnsRuleMatch: "匹配方式",
      dnsRuleValue: "匹配值",
      dnsRuleAction: "动作",
      dnsAddRule: "添加规则",
      dnsRemoveRule: "删除",
      dnsRequery: "可选重新查询",
      dnsNoRules: "暂无图形化规则",
      dnsAdvancedHint: "复杂规则继续保留在高级配置中。",
      dnsProtocolHint: "DoQ 和 DoH3 当前仅支持直连。",
      dnsTopologyTitle: "DNS 路径",
      dnsTopologyHint: "按直连和代理区分 DNS 上游",
      dnsTopologyCountSuffix: " 个上游",
      dnsTopologyDirect: "直连",
      dnsTopologyProxy: "代理",
      dnsTopologyNoDirect: "暂无直连上游",
      dnsTopologyNoProxy: "暂无代理上游",
      dnsTopologyLan: "局域网 / DNS 请求",
      dnsTopologyLanDetail: "进入查询",
      dnsTopologyService: "Honk DNS",
      dnsTopologyServiceDetail: "路由与解析",
      dnsTopologyRequest: "请求路由",
      dnsTopologyResponse: "响应检查",
      dnsTopologyResponseDetail: "校验与重新查询",
      dnsTopologyResponseFallback: "响应回落",
      dnsTopologyFallback: "回落",
      dnsTopologyRules: "条规则",
      dnsTopologyNoRules: "暂无显式路由规则",
      dnsTopologyNoUpstreams: "添加 DNS 上游后，这里会绘制出站路径。",
      dnsTopologyEdit: "编辑 DNS 上游",
      dnsTopologyFallbackTag: "请求回落",
      dnsTopologyRoutedTag: "规则目标",
      dnsTopologyRequery: "重新查询",
      dnsTopologyAccept: "accept",
      controller: "Clash API 地址",
      ui: "外部面板目录",
      mode: "默认模式",
      secret: "API 密钥",
      previewTitle: "应用预览",
      confirm: "确认应用",
      close: "关闭",
      addGroup: "添加代理组",
      groupFilter: "节点过滤器",
      groupDefault: "选择器默认节点",
      allNodes: "全部节点",
      addSubscription: "添加订阅",
      changed: "将修改",
      additions: "新增",
      removals: "删除",
      parseCode: "从代码解析",
      advancedHint: "这里保留未建模字段、注释和自定义片段。",
      global: "全局设置",
      wanInterface: "WAN 接口",
      lanInterface: "LAN 接口",
      dialMode: "拨号模式",
      logLevel: "日志等级",
      checkInterval: "检测间隔",
      checkTolerance: "延迟容差",
      tcpTargets: "TCP 检测目标",
      tcpCheckMethod: "TCP 检测方法",
      udpTargets: "UDP DNS 检测目标",
      autoConfigKernel: "自动配置内核参数",
      nodeKicker: "节点管理",
      routingKicker: "路由设置",
      dnsKicker: "DNS 设置",
      logsKicker: "Honk 核心日志",
      experimental: "实验设置",
      dnsSection: "DNS 配置片段",
      dnsOptions: "DNS 运行选项",
      ipVersionPreference: "IP 版本偏好",
      optimisticCache: "启用乐观缓存",
      cacheTtl: "固定缓存 TTL（秒）",
      maxCacheSize: "最大缓存条目",
      refresh: "刷新",
      revealCredentials: "显示凭据",
      testTarget: "测试目标",
      testUrl: "测试地址",
      normal: "正常",
      busy: "处理中…",
      serviceStatus: "服务状态",
      confirmRemove: "确认删除这个节点吗？",
      retry: "重试",
      overviewKicker: "节点与流量",
      overviewHint: "实时连接概览",
      configured: "已配置",
      secure: "安全连接",
      manageNodes: "管理节点",
      live: "实时",
      passed: "通过",
      failed: "失败",
      serviceRequested: "操作已提交",
      domainMode: "域名",
      enhancedDomainMode: "增强域名",
      ipMode: "IP",
      debugLevel: "调试",
      infoLevel: "信息",
      warnLevel: "警告",
      errorLevel: "错误",
      direct: "直连",
      ruleMode: "规则",
      globalMode: "全局",
      directMode: "直连",
      minMovingAverage: "最低移动平均",
      roundRobin: "轮询",
      fixedFirst: "固定第一个",
      subscriptionUrl: "订阅地址",
      subscriptionKicker: "远程节点源",
      subscriptionHint: "支持 Base64、原始分享链接和 Clash YAML",
      subscriptionNameOptional: "名称（可选）",
      subscriptionLinkRequired: "订阅链接",
      invalidSubscription: "请输入有效的 HTTP/HTTPS 订阅链接。",
      duplicateSubscription: "这个订阅链接已经添加。",
      confirmRemoveSubscription: "确认移除这个订阅吗？",
      subscriptionAdded: "订阅已添加，保存并应用后开始拉取。",
      listenSettings: "监听与拦截",
      healthSettings: "健康检查",
      resolverSettings: "解析与拨号",
      tlsSettings: "TLS 与连接",
      tproxyPort: "透明代理端口",
      tproxyPortProtect: "保护透明代理端口",
      pprofPort: "pprof 端口",
      socketMark: "Socket 标记",
      waitNetwork: "跳过等待网络就绪",
      sniffingTimeout: "嗅探超时",
      tlsImplementation: "TLS 实现",
      tlsImitate: "TLS 指纹",
      tlsFragment: "拆分 TLS ClientHello",
      fragmentLength: "拆分长度",
      fragmentInterval: "拆分间隔",
      mptcp: "启用 MPTCP",
      bootstrapResolver: "节点解析器",
      fallbackResolver: "控制面备用 DNS",
      bandwidthTx: "发送带宽提示",
      bandwidthRx: "接收带宽提示",
      cacheSettings: "缓存文件",
      cacheEnabled: "启用持久化缓存",
      cachePath: "缓存路径",
      cacheId: "缓存命名空间",
      storeFakeip: "保存 FakeIP",
      storeDns: "保存 DNS 结果",
      enabled: "已启用",
      disabled: "已停用",
    }
  : {
      overview: "Overview",
      nodes: "Nodes",
      routing: "Routing",
      dns: "DNS",
      logs: "Logs",
      advanced: "Advanced",
      globalSettings: "Global settings",
      globalHint: "Transparent proxy, health checks, resolvers, and TLS",
      running: "Running",
      stopped: "Stopped",
      validate: "Validate",
      save: "Save",
      apply: "Save & Apply",
      start: "Start",
      stop: "Stop",
      restart: "Restart",
      reload: "Reload",
      valid: "Configuration is valid",
      saved: "Saved",
      applied: "Applied",
      config: "Raw configuration",
      traffic: "Traffic",
      unavailable: "Unavailable",
      download: "Download",
      upload: "Upload",
      rate: "Live rate",
      total: "Total",
      active: "Active flows",
      overflow: "Overflow",
      noTraffic: "Waiting for traffic data",
      noLogs: "No log entries",
      unsaved: "Unsaved changes",
      importNode: "Import share link",
      parse: "Parse",
      add: "Add node",
      edit: "Edit",
      remove: "Remove",
      test: "Test",
      testing: "Testing",
      name: "Name",
      protocol: "Protocol",
      host: "Server",
      port: "Port",
      sni: "SNI",
      password: "Credential",
      network: "Transport",
      insecure: "Skip certificate verification",
      saveNode: "Save node",
      cancel: "Cancel",
      noNodes: "No nodes yet",
      runtimeNodes: "Runtime nodes",
      runtimeNode: "Subscription runtime",
      runtimeNodeHint: "Subscription nodes are supplied by the Honk runtime and sync after refresh.",
      refreshNodes: "Refresh nodes",
      search: "Search nodes",
      rules: "Rules",
      fallback: "Default outbound",
      addRule: "Add rule",
      removeRule: "Remove rule",
      groups: "Groups",
      subscriptions: "Subscriptions",
      noSubscriptions: "No subscriptions added",
      upstreams: "DNS upstreams",
      address: "Address",
      addDns: "Add upstream",
      dnsProtocol: "Protocol prefix",
      dnsHost: "Host",
      dnsPort: "Port",
      dnsPath: "Path",
      dnsOutbound: "Outbound",
      dnsRequestRouting: "Request routing",
      dnsResponseRouting: "Response routing",
      dnsRequestFallback: "Request fallback",
      dnsResponseFallback: "Response fallback",
      dnsRuleType: "Condition type",
      dnsRuleMatch: "Match mode",
      dnsRuleValue: "Match value",
      dnsRuleAction: "Action",
      dnsAddRule: "Add rule",
      dnsRemoveRule: "Remove",
      dnsRequery: "Optional re-query",
      dnsNoRules: "No graphical rules",
      dnsAdvancedHint: "Complex rules remain available in Advanced configuration.",
      dnsProtocolHint: "DoQ and DoH3 currently support direct connections only.",
      dnsTopologyTitle: "DNS path",
      dnsTopologyHint: "DNS upstreams grouped by direct or proxy",
      dnsTopologyCountSuffix: " upstreams",
      dnsTopologyDirect: "Direct",
      dnsTopologyProxy: "Proxy",
      dnsTopologyNoDirect: "No direct upstream",
      dnsTopologyNoProxy: "No proxied upstream",
      dnsTopologyLan: "LAN / DNS request",
      dnsTopologyLanDetail: "Incoming query",
      dnsTopologyService: "Honk DNS",
      dnsTopologyServiceDetail: "Route and resolve",
      dnsTopologyRequest: "Request routing",
      dnsTopologyResponse: "Response check",
      dnsTopologyResponseDetail: "Validate and re-query",
      dnsTopologyResponseFallback: "Response fallback",
      dnsTopologyFallback: "Fallback",
      dnsTopologyRules: "rules",
      dnsTopologyNoRules: "No explicit routing rules",
      dnsTopologyNoUpstreams: "Add a DNS upstream to draw the outbound path.",
      dnsTopologyEdit: "Edit DNS upstream",
      dnsTopologyFallbackTag: "request fallback",
      dnsTopologyRoutedTag: "rule target",
      dnsTopologyRequery: "re-query",
      dnsTopologyAccept: "accept",
      controller: "Clash API controller",
      ui: "External UI",
      mode: "Default mode",
      secret: "API secret",
      previewTitle: "Apply preview",
      confirm: "Confirm apply",
      close: "Close",
      addGroup: "Add group",
      groupFilter: "Node filter",
      groupDefault: "Selector default",
      allNodes: "All nodes",
      addSubscription: "Add subscription",
      changed: "Changes",
      additions: "additions",
      removals: "removals",
      parseCode: "Parse code",
      advancedHint:
        "Unmodeled fields, comments, and custom fragments stay here.",
      global: "Global settings",
      wanInterface: "WAN interface",
      lanInterface: "LAN interface",
      dialMode: "Dial mode",
      logLevel: "Log level",
      checkInterval: "Check interval",
      checkTolerance: "Check tolerance",
      tcpTargets: "TCP check targets",
      tcpCheckMethod: "TCP check method",
      udpTargets: "UDP DNS targets",
      autoConfigKernel: "Auto-configure kernel parameters",
      nodeKicker: "Node management",
      routingKicker: "Routing settings",
      dnsKicker: "DNS settings",
      logsKicker: "Honk core log",
      experimental: "Experimental",
      dnsSection: "DNS configuration fragment",
      dnsOptions: "DNS runtime options",
      ipVersionPreference: "IP version preference",
      optimisticCache: "Enable optimistic cache",
      cacheTtl: "Fixed cache TTL (seconds)",
      maxCacheSize: "Maximum cache entries",
      refresh: "Refresh",
      revealCredentials: "Reveal credentials",
      testTarget: "Test target",
      testUrl: "Test URL",
      normal: "Normal",
      busy: "Working…",
      serviceStatus: "Service status",
      confirmRemove: "Delete this node?",
      retry: "Retry",
      overviewKicker: "Nodes and traffic",
      overviewHint: "Live connection overview",
      configured: "Configured",
      secure: "Secure connection",
      manageNodes: "Manage nodes",
      live: "Live",
      passed: "Passed",
      failed: "Failed",
      serviceRequested: "Requested",
      domainMode: "Domain",
      enhancedDomainMode: "Enhanced domain",
      ipMode: "IP",
      debugLevel: "Debug",
      infoLevel: "Info",
      warnLevel: "Warning",
      errorLevel: "Error",
      direct: "Direct",
      ruleMode: "Rule",
      globalMode: "Global",
      directMode: "Direct",
      minMovingAverage: "Minimum moving average",
      roundRobin: "Round robin",
      fixedFirst: "Fixed first",
      subscriptionUrl: "Subscription URL",
      subscriptionKicker: "Remote node source",
      subscriptionHint: "Base64, raw share links, and Clash YAML are supported",
      subscriptionNameOptional: "Name (optional)",
      subscriptionLinkRequired: "Subscription link",
      invalidSubscription: "Enter a valid HTTP/HTTPS subscription link.",
      duplicateSubscription: "This subscription link is already added.",
      confirmRemoveSubscription: "Remove this subscription?",
      subscriptionAdded: "Subscription added. Save and apply to start fetching.",
      listenSettings: "Listen & intercept",
      healthSettings: "Health checks",
      resolverSettings: "Resolve & dial",
      tlsSettings: "TLS & connection",
      tproxyPort: "Transparent proxy port",
      tproxyPortProtect: "Protect transparent proxy port",
      pprofPort: "pprof port",
      socketMark: "Socket mark",
      waitNetwork: "Skip network readiness wait",
      sniffingTimeout: "Sniffing timeout",
      tlsImplementation: "TLS implementation",
      tlsImitate: "TLS fingerprint",
      tlsFragment: "Fragment TLS ClientHello",
      fragmentLength: "Fragment length",
      fragmentInterval: "Fragment interval",
      mptcp: "Enable MPTCP",
      bootstrapResolver: "Node resolver",
      fallbackResolver: "Control-plane fallback DNS",
      bandwidthTx: "Upload hint",
      bandwidthRx: "Download hint",
      cacheSettings: "Cache file",
      cacheEnabled: "Enable persistent cache",
      cachePath: "Cache path",
      cacheId: "Cache namespace",
      storeFakeip: "Store FakeIP",
      storeDns: "Store DNS answers",
      enabled: "Enabled",
      disabled: "Disabled",
    };

const tabs: Array<{ id: Tab; label: string }> = [
  { id: "global", label: text.globalSettings },
  { id: "routing", label: text.routing },
  { id: "dns", label: text.dns },
  { id: "advanced", label: text.advanced },
];

const dirty = computed(
  () => state.value !== null && advancedCode.value !== state.value.config,
);
function globalValue(key: string, fallback = ""): string {
  return model.value.global[key] ?? fallback;
}
function globalBoolean(key: string, fallback = false): boolean {
  const value = model.value.global[key];
  return value === undefined ? fallback : value === "true";
}
function dnsValue(key: string, fallback = ""): string {
  return readNested(model.value.dns.raw, key) || fallback;
}
function dnsBoolean(key: string, fallback = false): boolean {
  const value = readNested(model.value.dns.raw, key);
  return value === "" ? fallback : value === "true";
}
const visibleNodes = computed(() => {
  const needle = nodeSearch.value.trim().toLowerCase();
  if (!needle) return model.value.nodes;
  return model.value.nodes.filter((node) =>
    `${node.name} ${node.protocol} ${node.host}`.toLowerCase().includes(needle),
  );
});
const outbounds = computed(() => [
  "direct",
  ...model.value.nodes.map((node) => node.name),
  ...model.value.groups.map((group) => group.name).filter(Boolean),
]);
const numberValue = (value: unknown): number => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};
const formatBytes = (value: number): string => {
  if (value < 1024) return `${Math.round(value)} B`;
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let current = value;
  let index = -1;
  do {
    current /= 1024;
    index += 1;
  } while (current >= 1024 && index < units.length - 1);
  return `${current >= 10 ? current.toFixed(0) : current.toFixed(1)} ${units[index]}`;
};
const trafficSummary = computed(() => {
  const stats = traffic.value;
  const rows = stats?.outbounds || [];
  const upload = rows.reduce(
    (total, item) => total + numberValue(item.txBytes),
    0,
  );
  const download = rows.reduce(
    (total, item) => total + numberValue(item.rxBytes),
    0,
  );
  const uploadRate = rows.reduce(
    (total, item) => total + numberValue(item.txBytesPerSecond),
    0,
  );
  const downloadRate = rows.reduce(
    (total, item) => total + numberValue(item.rxBytesPerSecond),
    0,
  );
  const max = Math.max(
    ...rows.map(
      (item) => numberValue(item.txBytes) + numberValue(item.rxBytes),
    ),
    0,
  );
  return {
    upload,
    download,
    uploadRate,
    downloadRate,
    total: upload + download,
    active: numberValue(stats?.occupancy?.live),
    overflow:
      numberValue(stats?.overflow?.tcp) + numberValue(stats?.overflow?.udp),
    rows: rows.map((item) => {
      const total = numberValue(item.txBytes) + numberValue(item.rxBytes);
      return {
        id: item.id,
        label:
          item.id === 0
            ? text.direct
            : `${zh ? "出口" : "Outbound"} #${item.id}`,
        total,
        upload: numberValue(item.txBytes),
        download: numberValue(item.rxBytes),
        width: max > 0 ? Math.max(5, Math.round((total / max) * 100)) : 0,
      };
    }),
  };
});
const displayLogs = computed(() =>
  logs.value.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, ""),
);

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}
const dnsProtocols = ["udp", "tcp", "tcp+udp", "tls", "https", "h3", "quic"];
const dnsDefaultPorts: Record<string, number> = {
  udp: 53,
  tcp: 53,
  "tcp+udp": 53,
  tls: 853,
  https: 443,
  h3: 443,
  quic: 853,
};
function dnsProtocolLabel(protocol: string): string {
  return `${protocol}://`;
}
function dnsSupportsPath(protocol: string): boolean {
  return protocol === "https" || protocol === "h3";
}
function dnsDirectOnly(protocol: string): boolean {
  return protocol === "h3" || protocol === "quic";
}
function dnsUri(upstream: DnsUpstream): string {
  const host = upstream.host.includes(":") && !upstream.host.startsWith("[")
    ? `[${upstream.host}]`
    : upstream.host;
  const path = dnsSupportsPath(upstream.protocol) ? (upstream.path || "/dns-query") : "";
  const query = { ...(upstream.query || {}) };
  delete query.sni;
  delete query.tls_server_name;
  if (upstream.sni) query.tls_server_name = upstream.sni;
  else delete query.tls_server_name;
  const params = new URLSearchParams(query).toString();
  return `${upstream.protocol}://${host}:${upstream.port}${path}${params ? `?${params}` : ""}`;
}
function dnsRouteBody(): string {
  const request = [
    ...dnsRequestRules.value.map((rule) => `            ${rule}`),
    `            fallback: ${dnsRequestFallback.value || "reject"}`,
  ].join("\n");
  const response = [
    ...dnsResponseRules.value.map((rule) => `            ${rule}`),
    `            fallback: ${dnsResponseFallback.value || "accept"}`,
  ].join("\n");
  return `        request {\n${request}\n        }\n        response {\n${response}\n        }\n`;
}
function replaceDnsSubsection(source: string, name: string, body: string): string {
  const dns = blockBounds(source, "dns");
  const replacement = `    ${name} {\n${body.trimEnd()}\n    }`;
  if (!dns) return `${source.trimEnd()}\n\ndns {\n${replacement}\n}\n`;
  const dnsBody = source.slice(dns.open + 1, dns.close);
  const nested = blockBounds(dnsBody, name);
  const nestedStart = nested ? dnsBody.lastIndexOf(name, nested.open) : -1;
  const lineStart = nestedStart >= 0 ? dnsBody.lastIndexOf("\n", nestedStart) + 1 : -1;
  const nextBody = nested
    ? `${dnsBody.slice(0, lineStart)}${replacement}${dnsBody.slice(nested.close + 1)}`
    : `${dnsBody.trimEnd()}\n\n${replacement}\n`;
  return source.slice(0, dns.open + 1) + nextBody + source.slice(dns.close);
}
function syncDnsRaw() {
  const bounds = blockBounds(advancedCode.value, "dns");
  model.value.dns.raw = bounds
    ? advancedCode.value.slice(bounds.open + 1, bounds.close)
    : "";
}
function rebuildDnsSections() {
  let next = advancedCode.value;
  const upstreamBody = model.value.dns.upstreams
    .map((upstream) => `        ${upstream.name}: '${dnsUri(upstream).split("'").join("\\'")}'${upstream.outbound ? ` -> ${upstream.outbound}` : ""}`)
    .join("\n");
  next = replaceDnsSubsection(next, "upstream", upstreamBody || "        # Add a DNS upstream from this page.");
  next = replaceDnsSubsection(next, "routing", dnsRouteBody());
  advancedCode.value = next;
  syncDnsRaw();
}
function quote(value: string): string {
  if (/^(true|false|[0-9]+(?:ms|s)?)$/.test(value) || /^[\w+.-]+$/.test(value))
    return value;
  return `'${value.split("'").join("\\'")}'`;
}
function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function blockBounds(
  source: string,
  name: string,
): { open: number; close: number } | null {
  const match = new RegExp(`\\b${escapeRegExp(name)}\\s*\\{`).exec(source);
  if (!match || match.index < 0) return null;
  const open = source.indexOf("{", match.index);
  let depth = 0;
  let quoteChar = "";
  let comment = false;
  let escaped = false;
  for (let index = open; index < source.length; index += 1) {
    const char = source[index];
    if (comment) {
      if (char === "\n") comment = false;
      continue;
    }
    if (quoteChar) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === quoteChar) quoteChar = "";
      continue;
    }
    if (char === "#") {
      comment = true;
      continue;
    }
    if (char === "'" || char === '"') {
      quoteChar = char;
      continue;
    }
    if (char === "{") depth += 1;
    if (char === "}" && --depth === 0) return { open, close: index };
  }
  return null;
}
function replaceSectionKey(
  source: string,
  section: string,
  key: string,
  value: string,
): string {
  const bounds = blockBounds(source, section);
  if (!bounds)
    return `${source.trimEnd()}\n\n${section} {\n    ${key}: ${quote(value)}\n}\n`;
  const body = source.slice(bounds.open + 1, bounds.close);
  const line = new RegExp(
    `(^|\\n)([ \\t]*)${escapeRegExp(key)}\\s*:\\s*[^\\n#]*`,
    "m",
  );
  const formatted = `${key}: ${quote(value)}`;
  const nextBody = line.test(body)
    ? body.replace(
        line,
        (_all, prefix, indent) => `${prefix}${indent || "    "}${formatted}`,
      )
    : `${body.trimEnd()}\n    ${formatted}\n`;
  return (
    source.slice(0, bounds.open + 1) + nextBody + source.slice(bounds.close)
  );
}
function removeSectionKey(source: string, section: string, key: string): string {
  const bounds = blockBounds(source, section);
  if (!bounds) return source;
  const body = source.slice(bounds.open + 1, bounds.close);
  const line = new RegExp(`\\n?[ \\t]*${escapeRegExp(key)}\\s*:[^\\n#]*(?:\\n|$)`, "m");
  return source.slice(0, bounds.open + 1) + body.replace(line, "\n") + source.slice(bounds.close);
}
function replaceGlobalKey(source: string, key: string, value: string): string {
  return replaceSectionKey(source, "global", key, value);
}
function replaceNestedKey(
  source: string,
  section: string,
  nested: string,
  key: string,
  value: string,
): string {
  const outer = blockBounds(source, section);
  if (!outer)
    return `${source.trimEnd()}\n\n${section} {\n    ${nested} {\n        ${key}: ${quote(value)}\n    }\n}\n`;
  const outerBody = source.slice(outer.open + 1, outer.close);
  const inner = blockBounds(outerBody, nested);
  if (!inner) {
    const nextOuter = `${outerBody.trimEnd()}\n    ${nested} {\n        ${key}: ${quote(value)}\n    }\n`;
    return (
      source.slice(0, outer.open + 1) + nextOuter + source.slice(outer.close)
    );
  }
  const body = outerBody.slice(inner.open + 1, inner.close);
  const line = new RegExp(
    `(^|\\n)([ \\t]*)${escapeRegExp(key)}\\s*:\\s*[^\\n#]*`,
    "m",
  );
  const formatted = `${key}: ${quote(value)}`;
  const next = line.test(body)
    ? body.replace(
        line,
        (_all, prefix, indent) =>
          `${prefix}${indent || "        "}${formatted}`,
      )
    : `${body.trimEnd()}\n        ${formatted}\n`;
  const nextOuter =
    outerBody.slice(0, inner.open + 1) + next + outerBody.slice(inner.close);
  return (
    source.slice(0, outer.open + 1) + nextOuter + source.slice(outer.close)
  );
}
function replaceNodeEntry(
  source: string,
  oldName: string,
  node: ParsedNode,
): string {
  const bounds = blockBounds(source, "node");
  const lineText = `    ${node.name}: '${node.raw.split("'").join("\\'")}'`;
  if (!bounds) return `${source.trimEnd()}\n\nnode {\n${lineText}\n}\n`;
  const body = source.slice(bounds.open + 1, bounds.close);
  const line = new RegExp(
    `(^|\\n)([ \\t]*)${escapeRegExp(oldName)}\\s*:\\s*[^\\n#]*`,
    "m",
  );
  const nextBody = line.test(body)
    ? body.replace(line, (_all, prefix) => `${prefix}${lineText}`)
    : `${body.trimEnd()}\n${lineText}\n`;
  return (
    source.slice(0, bounds.open + 1) + nextBody + source.slice(bounds.close)
  );
}
function removeNodeEntry(source: string, name: string): string {
  const bounds = blockBounds(source, "node");
  if (!bounds) return source;
  const body = source.slice(bounds.open + 1, bounds.close);
  const line = new RegExp(
    `\\n?[ \\t]*${escapeRegExp(name)}\\s*:\\s*[^\\n#]*(?:\\n|$)`,
    "m",
  );
  const nextBody = body.replace(line, "\n");
  return (
    source.slice(0, bounds.open + 1) + nextBody + source.slice(bounds.close)
  );
}
function removeNamedEntry(source: string, section: string, name: string): string {
  const bounds = blockBounds(source, section);
  if (!bounds) return source;
  const body = source.slice(bounds.open + 1, bounds.close);
  const line = new RegExp(
    `\\n?[ \\t]*${escapeRegExp(name)}\\s*:\\s*[^\\n#]*(?:\\n|$)`,
    "m",
  );
  const nextBody = body.replace(line, "\n");
  return (
    source.slice(0, bounds.open + 1) + nextBody + source.slice(bounds.close)
  );
}
function updateNodeLink(node: ParsedNode): string {
  const [beforeHash, hash = ""] = node.raw.split("#", 2);
  const [beforeQuery, query = ""] = beforeHash.split("?", 2);
  const schemeMatch = beforeQuery.match(/^([\w+.-]+):\/\//);
  if (!schemeMatch) return node.raw;
  const scheme = node.protocol || schemeMatch[1];
  const authority = beforeQuery.slice(schemeMatch[0].length);
  const at = authority.lastIndexOf("@");
  let credential = at >= 0 ? authority.slice(0, at) : "";
  if (scheme.toLowerCase() === "anytls" && node.password)
    credential = encodeURIComponent(node.password);
  const params = new URLSearchParams(query);
  if (node.sni) params.set("sni", node.sni);
  else params.delete("sni");
  if (node.network) params.set("type", node.network);
  else params.delete("type");
  if (node.insecure) {
    params.set("insecure", "1");
    params.set("allowInsecure", "1");
  } else {
    params.delete("insecure");
    params.delete("allowInsecure");
  }
  const auth = credential ? `${credential}@` : "";
  const suffix = params.toString();
  return `${scheme}://${auth}${node.host}:${node.port}${suffix ? `?${suffix}` : ""}${hash ? `#${hash}` : ""}`;
}
function saveGlobal(key: string, event: Event) {
  const target = event.target as HTMLInputElement | HTMLSelectElement;
  const value =
    target instanceof HTMLInputElement && target.type === "checkbox"
      ? String(target.checked)
      : target.value;
  model.value.global[key] = value;
  advancedCode.value = replaceGlobalKey(advancedCode.value, key, value);
}
function updateDnsOption(key: string, event: Event) {
  const target = event.target as HTMLInputElement | HTMLSelectElement;
  const value =
    target instanceof HTMLInputElement && target.type === "checkbox"
      ? String(target.checked)
      : target.value;
  advancedCode.value = replaceSectionKey(
    advancedCode.value,
    "dns",
    key,
    value,
  );
  syncDnsRaw();
}
function updateDnsIpVersion(event: Event) {
  const value = (event.target as HTMLSelectElement).value;
  advancedCode.value = value === "both"
    ? removeSectionKey(advancedCode.value, "dns", "ipversion_prefer")
    : replaceSectionKey(advancedCode.value, "dns", "ipversion_prefer", value);
  syncDnsRaw();
}
function syncExperimental(key: string, value: string) {
  advancedCode.value = replaceNestedKey(
    advancedCode.value,
    "experimental",
    "clash_api",
    key,
    value,
  );
}
function syncCache(key: string, value: string) {
  advancedCode.value = replaceNestedKey(
    advancedCode.value,
    "experimental",
    "cache_file",
    key,
    value,
  );
}
function normalizeModel(input: ConfigModel): ConfigModel {
  const next = input;
  next.nodes = Array.isArray(next.nodes) ? next.nodes : [];
  next.groups = Array.isArray(next.groups) ? next.groups : [];
  next.subscriptions = Array.isArray(next.subscriptions)
    ? next.subscriptions
    : [];
  next.routing = next.routing || { rules: [], fallback: "direct" };
  next.routing.rules = Array.isArray(next.routing.rules)
    ? next.routing.rules
    : [];
  next.dns = next.dns || { raw: "", upstreams: [] };
  next.dns.upstreams = Array.isArray(next.dns.upstreams)
    ? next.dns.upstreams
    : [];
  next.dns.requestRules = Array.isArray(next.dns.requestRules)
    ? next.dns.requestRules
    : [];
  next.dns.requestFallback = next.dns.requestFallback || "";
  next.dns.responseRules = Array.isArray(next.dns.responseRules)
    ? next.dns.responseRules
    : [];
  next.dns.responseFallback = next.dns.responseFallback || "accept";
  next.global = next.global || {};
  next.experimental = next.experimental || { raw: "" };
  return next;
}

async function load() {
  try {
    const keepEditor =
      state.value !== null && advancedCode.value !== state.value.config;
    const next = await api.state();
    state.value = next;
    if (!keepEditor) advancedCode.value = next.config;
    const current = await api.model();
    model.value = normalizeModel(current.model);
    if (!keepEditor) advancedCode.value = current.model.rawConfig;
    const global = current.model.global;
    experimentalController.value =
      readNested(current.model.experimental.raw, "external_controller") ||
      experimentalController.value;
    experimentalUi.value =
      readNested(current.model.experimental.raw, "external_ui") ||
      experimentalUi.value;
    experimentalMode.value =
      readNested(current.model.experimental.raw, "default_mode") ||
      experimentalMode.value;
    experimentalSecret.value =
      readNested(current.model.experimental.raw, "secret") || "";
    experimentalCacheEnabled.value =
      readNested(current.model.experimental.raw, "enabled") === "true";
    experimentalCachePath.value =
      readNested(current.model.experimental.raw, "path") ||
      "/etc/honk/cache.db";
    experimentalCacheId.value =
      readNested(current.model.experimental.raw, "cache_id") || "";
    experimentalStoreFakeip.value =
      readNested(current.model.experimental.raw, "store_fakeip") === "true";
    experimentalStoreDns.value =
      readNested(current.model.experimental.raw, "store_dns") === "true";
    dnsRequestFallback.value = current.model.dns.requestFallback || "";
    dnsResponseFallback.value = current.model.dns.responseFallback || "accept";
    dnsRequestRules.value = [...current.model.dns.requestRules];
    dnsResponseRules.value = [...current.model.dns.responseRules];
    const requery = dnsResponseRules.value.find((rule) => /^upstream\(/.test(rule));
    const match = requery?.match(/^upstream\(([^)]+)\)\s*->\s*(\S+)/);
    dnsResponseSource.value = match?.[1] || "";
    dnsResponseTarget.value = match?.[2] || "";
    void global;
    message.value = "";
  } catch (reason) {
    error.value = (reason as Error).message;
  }
}

async function mergeRuntimeNodes() {
  try {
    const runtime = await api.runtimeNodes();
    if (!runtime.available || !Array.isArray(runtime.nodes)) return;
    const configuredNodes = model.value.nodes.filter((node) => !node.runtime);
    const configured = new Set(configuredNodes.map((node) => node.name));
    model.value.nodes = [
      ...configuredNodes,
      ...runtime.nodes.filter((node) => !configured.has(node.name)),
    ];
  } catch {
    // The dashboard remains usable when the daemon or Clash API is stopped.
  }
}
function readNested(raw: string, key: string): string {
  const match = new RegExp(
    `(?:^|\\n)\\s*${escapeRegExp(key)}\\s*:\\s*([^\\n#]+)`,
  ).exec(raw);
  return match ? match[1].trim().replace(/^['"]|['"]$/g, "") : "";
}
async function refreshDetails() {
  try {
    logs.value = (await api.logs()).lines;
    traffic.value = (await api.traffic()) as TrafficStats;
  } catch (reason) {
    error.value = (reason as Error).message;
  }
}
async function refreshAll() {
  error.value = "";
  await load();
}
async function run(action: () => Promise<unknown>, success: string) {
  busy.value = true;
  error.value = "";
  message.value = "";
  try {
    await action();
    await load();
    message.value = success;
  } catch (reason) {
    error.value = (reason as Error).message;
  } finally {
    busy.value = false;
  }
}
function validate() {
  return run(() => api.validate(advancedCode.value), text.valid);
}
function save() {
  return run(
    () => api.save(advancedCode.value, state.value?.diskRevision || ""),
    text.saved,
  );
}
async function beginApply() {
  busy.value = true;
  error.value = "";
  message.value = "";
  try {
    preview.value = await api.preview(advancedCode.value);
    showPreview.value = true;
  } catch (reason) {
    error.value = (reason as Error).message;
  } finally {
    busy.value = false;
  }
}
async function confirmApply() {
  showPreview.value = false;
  await run(
    () => api.modelApply(advancedCode.value, state.value?.diskRevision || ""),
    text.applied,
  );
}
function service(action: string) {
  const labels: Record<string, string> = {
    start: text.start,
    stop: text.stop,
    restart: text.restart,
    reload: text.reload,
  };
  return run(
    () => api.service(action),
    `${labels[action] || action} · ${text.serviceRequested}`,
  );
}
async function parseAdvanced() {
  busy.value = true;
  error.value = "";
  try {
    const result = await api.modelParse(advancedCode.value);
    model.value = normalizeModel(result.model);
    message.value = text.valid;
  } catch (reason) {
    error.value = (reason as Error).message;
  } finally {
    busy.value = false;
  }
}
async function importNode() {
  if (!nodeLink.value.trim()) return;
  nodeBusy.value = true;
  error.value = "";
  try {
    const result = await api.parseNode(nodeLink.value.trim());
    const node = result.node;
    node.raw = nodeLink.value.trim();
    const existing = model.value.nodes.find((item) => item.name === node.name);
    if (existing)
      advancedCode.value = replaceNodeEntry(
        advancedCode.value,
        existing.name,
        node,
      );
    else {
      model.value.nodes.push(node);
      advancedCode.value = replaceNodeEntry(
        advancedCode.value,
        "__missing__",
        node,
      );
    }
    nodeLink.value = "";
    message.value = text.saved;
  } catch (reason) {
    error.value = (reason as Error).message;
  } finally {
    nodeBusy.value = false;
  }
}
function editNode(node: ParsedNode) {
  selectedNode.value = node;
  nodeDraft.value = clone(node);
  nodeTest.value = null;
}
function saveNode() {
  if (!nodeDraft.value || !selectedNode.value) return;
  const oldName = selectedNode.value.name;
  const next = clone(nodeDraft.value);
  next.raw = updateNodeLink(next);
  model.value.nodes = model.value.nodes.map((node) =>
    node === selectedNode.value ? next : node,
  );
  advancedCode.value = replaceNodeEntry(advancedCode.value, oldName, next);
  selectedNode.value = null;
  nodeDraft.value = null;
  message.value = text.saved;
}
function deleteNode(node: ParsedNode) {
  if (!window.confirm(`${text.confirmRemove}\n${node.name}`)) return;
  model.value.nodes = model.value.nodes.filter((item) => item !== node);
  advancedCode.value = removeNodeEntry(advancedCode.value, node.name);
  if (selectedNode.value === node) {
    selectedNode.value = null;
    nodeDraft.value = null;
  }
}
async function testNode(node: ParsedNode) {
  if (!node.raw) {
    error.value = zh
      ? "运行时订阅节点没有可编辑的分享链接，请在订阅源中管理。"
      : "Runtime subscription nodes do not expose an editable share link.";
    return;
  }
  nodeBusy.value = true;
  nodeTest.value = null;
  error.value = "";
  try {
    nodeTest.value = await api.testNode(node.raw, {
      target: testTarget.value,
      url: testUrl.value,
      timeout: 8,
    });
  } catch (reason) {
    error.value = (reason as Error).message;
  } finally {
    nodeBusy.value = false;
  }
}
function addRule() {
  const rule = newRule.value.trim();
  if (!rule) return;
  model.value.routing.rules.push(rule);
  newRule.value = "";
  const bounds = blockBounds(advancedCode.value, "routing");
  if (bounds)
    advancedCode.value =
      advancedCode.value.slice(0, bounds.close) +
      `\n    ${rule}\n` +
      advancedCode.value.slice(bounds.close);
}
function removeRule(rule: string) {
  model.value.routing.rules = model.value.routing.rules.filter(
    (item) => item !== rule,
  );
  const bounds = blockBounds(advancedCode.value, "routing");
  if (!bounds) return;
  const body = advancedCode.value.slice(bounds.open + 1, bounds.close);
  advancedCode.value =
    advancedCode.value.slice(0, bounds.open + 1) +
    body.replace(new RegExp(`\\n?\\s*${escapeRegExp(rule)}\\s*\\n?`), "\n") +
    advancedCode.value.slice(bounds.close);
}
function updateFallback(event: Event) {
  const value = (event.target as HTMLSelectElement).value;
  model.value.routing.fallback = value;
  const bounds = blockBounds(advancedCode.value, "routing");
  if (!bounds) return;
  const body = advancedCode.value.slice(bounds.open + 1, bounds.close);
  const line = /(^|\n)\s*fallback\s*:\s*[^\n#]*/m;
  const next = line.test(body)
    ? body.replace(line, (_all, prefix) => `${prefix}    fallback: ${value}`)
    : `${body.trimEnd()}\n    fallback: ${value}\n`;
  advancedCode.value =
    advancedCode.value.slice(0, bounds.open + 1) +
    next +
    advancedCode.value.slice(bounds.close);
}
function addGroup() {
  const name = newGroupName.value.trim();
  if (!name) return;
  const policy = newGroupPolicy.value || "min_moving_avg";
  const final = newGroupFinal.value || "direct";
  const filter = newGroupFilter.value.trim();
  const defaultMember = newGroupDefault.value.trim();
  model.value.groups.push({
    name,
    policy,
    final,
    filter,
    default: defaultMember,
    raw: `\n        ${filter ? `filter: ${filter}\n        ` : ""}${policy ? `policy: ${policy}\n        ` : ""}${defaultMember ? `default: ${quote(defaultMember)}\n        ` : ""}final: ${final}\n    `,
  });
  const block = `    ${name} {\n${filter ? `        filter: ${filter}\n` : ""}        policy: ${policy}\n${defaultMember ? `        default: ${quote(defaultMember)}\n` : ""}        final: ${final}\n    }\n`;
  const bounds = blockBounds(advancedCode.value, "group");
  advancedCode.value = bounds
    ? advancedCode.value.slice(0, bounds.close) +
      `\n${block}` +
      advancedCode.value.slice(bounds.close)
    : `${advancedCode.value.trimEnd()}\n\ngroup {\n${block}}\n`;
  newGroupName.value = "";
  newGroupFilter.value = "";
  newGroupDefault.value = "";
}
function addSubscription() {
  const url = newSubscriptionUrl.value.trim();
  error.value = "";
  message.value = "";
  if (!/^https?:\/\//i.test(url)) {
    error.value = text.invalidSubscription;
    return;
  }
  if (model.value.subscriptions.some((subscription) => subscription.url === url)) {
    error.value = text.duplicateSubscription;
    return;
  }
  let name = newSubscriptionName.value.trim();
  if (!name) {
    try {
      name = new URL(url).hostname.replace(/^www\./i, "") || "subscription";
    } catch {
      name = `subscription-${model.value.subscriptions.length + 1}`;
    }
  }
  name = name.replace(/[^\w.-]+/g, "-").replace(/^-+|-+$/g, "") || "subscription";
  model.value.subscriptions.push({ name, url });
  const entry = `    ${name}: '${url.split("'").join("\\'")}'\n`;
  const bounds = blockBounds(advancedCode.value, "subscription");
  advancedCode.value = bounds
    ? advancedCode.value.slice(0, bounds.close) +
      `\n${entry}` +
      advancedCode.value.slice(bounds.close)
    : `${advancedCode.value.trimEnd()}\n\nsubscription {\n${entry}}\n`;
  newSubscriptionName.value = "";
  newSubscriptionUrl.value = "";
  message.value = text.subscriptionAdded;
}
function removeSubscription(subscription: { name: string; url: string }) {
  if (!window.confirm(`${text.confirmRemoveSubscription}\n${subscription.name}`)) return;
  model.value.subscriptions = model.value.subscriptions.filter(
    (item) => item !== subscription,
  );
  advancedCode.value = removeNamedEntry(
    advancedCode.value,
    "subscription",
    subscription.name,
  );
}
function resetDnsForm() {
  newDnsName.value = "";
  newDnsProtocol.value = "udp";
  newDnsHost.value = "";
  newDnsPort.value = 53;
  newDnsPath.value = "/dns-query";
  newDnsSni.value = "";
  newDnsOutbound.value = "direct";
  dnsEditingName.value = "";
}
function updateDnsProtocol() {
  newDnsPort.value = dnsDefaultPorts[newDnsProtocol.value] || 53;
  if (dnsDirectOnly(newDnsProtocol.value)) newDnsOutbound.value = "direct";
}
function editDns(name: string) {
  const upstream = model.value.dns.upstreams.find((item) => item.name === name);
  if (!upstream) return;
  newDnsName.value = upstream.name;
  newDnsProtocol.value = upstream.protocol || "udp";
  newDnsHost.value = upstream.host;
  newDnsPort.value = upstream.port;
  newDnsPath.value = upstream.path || "/dns-query";
  newDnsSni.value = upstream.sni || "";
  newDnsOutbound.value = upstream.outbound || "direct";
  dnsEditingName.value = name;
}
function editDnsFromTopology(name: string) {
  editDns(name);
  void nextTick(() => {
    dnsEditor.value?.scrollIntoView({ behavior: "smooth", block: "start" });
  });
}
function saveDns() {
  const name = newDnsName.value.trim();
  const host = newDnsHost.value.trim();
  const port = Number(newDnsPort.value);
  if (!/^[A-Za-z0-9_.-]+$/.test(name)) {
    error.value = "DNS 名称只能包含字母、数字、下划线、点和短横线。";
    return;
  }
  if (!host || /[\s/]/.test(host) || !Number.isInteger(port) || port < 1 || port > 65535) {
    error.value = "请输入有效的 DNS 主机地址和端口。";
    return;
  }
  if (!dnsProtocols.includes(newDnsProtocol.value)) return;
  if (dnsDirectOnly(newDnsProtocol.value) && newDnsOutbound.value !== "direct") {
    error.value = text.dnsProtocolHint;
    return;
  }
  if (model.value.dns.upstreams.some((item) => item.name === name && item.name !== dnsEditingName.value)) {
    error.value = "这个 DNS 名称已经存在。";
    return;
  }
  const upstream: DnsUpstream = {
    name,
    value: "",
    protocol: newDnsProtocol.value,
    host,
    port,
    path: dnsSupportsPath(newDnsProtocol.value) ? (newDnsPath.value.trim() || "/dns-query") : undefined,
    sni: newDnsSni.value.trim() || undefined,
    outbound: newDnsOutbound.value === "direct" ? undefined : newDnsOutbound.value,
  };
  upstream.value = dnsUri(upstream);
  const index = model.value.dns.upstreams.findIndex((item) => item.name === dnsEditingName.value);
  if (index >= 0) model.value.dns.upstreams[index] = upstream;
  else model.value.dns.upstreams.push(upstream);
  rebuildDnsSections();
  resetDnsForm();
  error.value = "";
}
function removeDns(name: string) {
  model.value.dns.upstreams = model.value.dns.upstreams.filter((item) => item.name !== name);
  if (dnsRequestFallback.value === name) dnsRequestFallback.value = "";
  dnsRequestRules.value = dnsRequestRules.value.filter((rule) => !rule.endsWith(`-> ${name}`));
  if (dnsResponseSource.value === name) dnsResponseSource.value = "";
  if (dnsResponseTarget.value === name) dnsResponseTarget.value = "";
  dnsResponseRules.value = dnsResponseRules.value.filter((rule) => !rule.includes(name));
  rebuildDnsSections();
}
function updateDnsRequestFallback(event: Event) {
  dnsRequestFallback.value = (event.target as HTMLSelectElement).value;
  rebuildDnsSections();
}
function updateDnsResponseFallback(event: Event) {
  dnsResponseFallback.value = (event.target as HTMLSelectElement).value;
  rebuildDnsSections();
}
function addDnsRequestRule() {
  const value = dnsRuleValue.value.trim();
  if (!value) return;
  const condition = dnsRuleType.value === "qtype"
    ? `qtype(${value})`
    : `qname(${dnsRuleMatch.value}: ${value})`;
  const action = dnsRuleAction.value || model.value.dns.upstreams[0]?.name || "reject";
  dnsRequestRules.value.push(`${condition} -> ${action}`);
  dnsRuleValue.value = "";
  rebuildDnsSections();
}
function removeDnsRequestRule(index: number) {
  dnsRequestRules.value.splice(index, 1);
  rebuildDnsSections();
}
function updateDnsResponseRequery() {
  dnsResponseRules.value = dnsResponseRules.value.filter((rule) => !/^upstream\(/.test(rule));
  if (dnsResponseSource.value && dnsResponseTarget.value) {
    dnsResponseRules.value.unshift(`upstream(${dnsResponseSource.value}) -> ${dnsResponseTarget.value}`);
  }
  rebuildDnsSections();
}
function updateExperimental(
  key: string,
  value: string,
  target: "controller" | "ui" | "mode" | "secret",
) {
  if (target === "controller") experimentalController.value = value;
  if (target === "ui") experimentalUi.value = value;
  if (target === "mode") experimentalMode.value = value;
  if (target === "secret") experimentalSecret.value = value;
  syncExperimental(key, value);
}
function updateCache(key: string, event: Event) {
  const target = event.target as HTMLInputElement;
  const value =
    target.type === "checkbox" ? String(target.checked) : target.value;
  if (key === "enabled") experimentalCacheEnabled.value = value === "true";
  if (key === "path") experimentalCachePath.value = value;
  if (key === "cache_id") experimentalCacheId.value = value;
  if (key === "store_fakeip") experimentalStoreFakeip.value = value === "true";
  if (key === "store_dns") experimentalStoreDns.value = value === "true";
  syncCache(key, value);
}

onMounted(async () => {
  await refreshAll();
});
</script>

<template>
  <section class="config-view">
    <section class="toolbar" :aria-busy="busy">
      <div class="toolbar-group config-actions">
        <button :disabled="busy" @click="validate">{{ text.validate }}</button
        ><button :disabled="busy" @click="save">{{ text.save }}</button
        ><button class="primary" :disabled="busy" @click="beginApply">
          {{ text.apply }}
        </button>
      </div>
      <span class="toolbar-space" />
      <span v-if="busy" class="busy-note" aria-live="polite">{{
        text.busy
      }}</span
      ><span v-if="dirty || state?.dirty" class="dirty">{{
        text.unsaved
      }}</span>
    </section>
    <p v-if="message" class="notice" role="status" aria-live="polite">
      {{ message }}
    </p>
    <p v-if="error" class="error" role="alert">
      <span>{{ error }}</span>
      <button @click="refreshAll">{{ text.retry }}</button>
    </p>
    <nav class="tabs" :aria-label="text.config">
      <button
        v-for="tab in tabs"
        :key="tab.id"
        :class="{ active: activeTab === tab.id }"
        @click="activeTab = tab.id"
      >
        {{ tab.label
        }}<span v-if="tab.id === 'nodes'" class="count">{{
          model.nodes.length
        }}</span>
      </button>
    </nav>

    <section v-if="activeTab === 'overview'" class="overview-shell">
      <section class="glass-card overview-nodes">
        <section class="overview-heading">
          <div>
            <p class="kicker">{{ text.overviewKicker }}</p>
            <h2>{{ text.overview }}</h2>
            <p class="overview-hint">{{ text.overviewHint }}</p>
          </div>
          <span class="metric">{{ model.nodes.length }} {{ text.nodes }}</span>
        </section>
        <div v-if="model.nodes.length" class="overview-node-grid">
          <article
            v-for="node in model.nodes"
            :key="node.name"
            class="overview-node-card"
          >
            <div class="node-card-top">
              <span class="protocol">{{ node.protocol }}</span>
              <span class="node-state"><i />{{ node.runtime ? text.runtimeNode : text.configured }}</span>
            </div>
            <h3>{{ node.name }}</h3>
            <p class="node-address">{{ node.runtime ? text.runtimeNodes : `${node.host}:${node.port}` }}</p>
            <div class="node-card-meta">
              <span>{{ node.runtime ? (node.runtimeType || text.runtimeNode) : (node.network || "tcp") }}</span>
              <span v-if="node.tls" class="secure">{{ text.secure }}</span>
            </div>
            <div class="node-card-footer">
              <span v-if="node.sni" class="node-sni"
                >{{ text.sni }} {{ node.sni }}</span
              >
              <button class="link-button" @click="activeTab = 'nodes'">
                {{ text.manageNodes }} →
              </button>
            </div>
          </article>
        </div>
        <div v-else class="overview-empty">
          <p>{{ text.noNodes }}</p>
          <button class="primary" @click="activeTab = 'nodes'">
            {{ text.add }}
          </button>
        </div>
      </section>
      <aside class="glass-card traffic-panel overview-traffic">
        <div class="panel-title">
          <div>
            <p class="kicker">{{ text.traffic }}</p>
            <h2>{{ text.traffic }}</h2>
          </div>
          <span class="live-status"><i />{{ text.live }}</span>
        </div>
        <div v-if="traffic?.available" class="traffic-body">
          <div class="traffic-metrics">
            <div class="traffic-metric down">
              <span>{{ text.download }}</span
              ><strong>{{ formatBytes(trafficSummary.download) }}</strong
              ><small
                >{{ text.rate }}
                {{ formatBytes(trafficSummary.downloadRate) }}/s</small
              >
            </div>
            <div class="traffic-metric up">
              <span>{{ text.upload }}</span
              ><strong>{{ formatBytes(trafficSummary.upload) }}</strong
              ><small
                >{{ text.rate }}
                {{ formatBytes(trafficSummary.uploadRate) }}/s</small
              >
            </div>
            <div class="traffic-metric">
              <span>{{ text.active }}</span
              ><strong>{{ trafficSummary.active }}</strong
              ><small
                >{{ text.total }} {{ formatBytes(trafficSummary.total) }}</small
              >
            </div>
            <div
              class="traffic-metric"
              :class="{ warning: trafficSummary.overflow > 0 }"
            >
              <span>{{ text.overflow }}</span
              ><strong>{{ trafficSummary.overflow }}</strong
              ><small>{{
                trafficSummary.overflow > 0 ? "TCP / UDP" : text.normal
              }}</small>
            </div>
          </div>
          <div class="outbound-chart">
            <div
              v-for="outbound in trafficSummary.rows"
              :key="outbound.id"
              class="outbound-row"
            >
              <div class="outbound-label">
                <span>{{ outbound.label }}</span
                ><strong>{{ formatBytes(outbound.total) }}</strong>
              </div>
              <div class="outbound-track">
                <i :style="{ width: `${outbound.width}%` }" />
              </div>
              <div class="outbound-detail">
                <span
                  >{{ text.download }}
                  {{ formatBytes(outbound.download) }}</span
                ><span
                  >{{ text.upload }} {{ formatBytes(outbound.upload) }}</span
                >
              </div>
            </div>
            <p v-if="!trafficSummary.rows.length" class="traffic-empty">
              {{ text.noTraffic }}
            </p>
          </div>
        </div>
        <p v-else class="traffic-empty">{{ text.unavailable }}</p>
      </aside>
    </section>

    <section v-else-if="activeTab === 'global'" class="section-stack settings-page">
      <section class="section-head">
        <div>
          <p class="kicker">{{ text.globalSettings }}</p>
          <h2>{{ text.globalSettings }}</h2>
          <p class="hint">{{ text.globalHint }}</p>
        </div>
      </section>
      <div class="settings-grid">
        <section class="panel settings-panel">
          <div class="panel-title">
            <div>
              <p class="kicker">01</p>
              <h2>{{ text.listenSettings }}</h2>
            </div>
          </div>
          <div class="form-grid">
            <label>
              <span>{{ text.wanInterface }}</span>
              <input
                :value="globalValue('wan_interface', 'auto')"
                @change="saveGlobal('wan_interface', $event)"
              />
            </label>
            <label>
              <span>{{ text.lanInterface }}</span>
              <input
                :value="globalValue('lan_interface')"
                @change="saveGlobal('lan_interface', $event)"
              />
            </label>
            <label>
              <span>{{ text.tproxyPort }}</span>
              <input
                :value="globalValue('tproxy_port', '12345')"
                type="number"
                min="1"
                max="65535"
                @change="saveGlobal('tproxy_port', $event)"
              />
            </label>
            <label>
              <span>{{ text.pprofPort }}</span>
              <input
                :value="globalValue('pprof_port', '0')"
                type="number"
                min="0"
                max="65535"
                @change="saveGlobal('pprof_port', $event)"
              />
            </label>
            <label>
              <span>{{ text.socketMark }}</span>
              <input
                :value="globalValue('so_mark_from_dae', '0')"
                @change="saveGlobal('so_mark_from_dae', $event)"
              />
            </label>
            <label class="check wide">
              <input
                :checked="globalBoolean('tproxy_port_protect', true)"
                type="checkbox"
                @change="saveGlobal('tproxy_port_protect', $event)"
              />
              {{ text.tproxyPortProtect }}
            </label>
          </div>
        </section>

        <section class="panel settings-panel">
          <div class="panel-title">
            <div>
              <p class="kicker">02</p>
              <h2>{{ text.healthSettings }}</h2>
            </div>
          </div>
          <div class="form-grid">
            <label>
              <span>{{ text.logLevel }}</span>
              <select
                :value="globalValue('log_level', 'info')"
                @change="saveGlobal('log_level', $event)"
              >
                <option value="trace">trace</option>
                <option value="debug">{{ text.debugLevel }}</option>
                <option value="info">{{ text.infoLevel }}</option>
                <option value="warn">{{ text.warnLevel }}</option>
                <option value="error">{{ text.errorLevel }}</option>
              </select>
            </label>
            <label>
              <span>{{ text.checkInterval }}</span>
              <input
                :value="globalValue('check_interval', '30s')"
                placeholder="30s"
                @change="saveGlobal('check_interval', $event)"
              />
            </label>
            <label>
              <span>{{ text.checkTolerance }}</span>
              <input
                :value="globalValue('check_tolerance', '50ms')"
                placeholder="50ms"
                @change="saveGlobal('check_tolerance', $event)"
              />
            </label>
            <label>
              <span>{{ text.tcpTargets }}</span>
              <input
                :value="globalValue('tcp_check_url')"
                @change="saveGlobal('tcp_check_url', $event)"
              />
            </label>
            <label>
              <span>{{ text.tcpCheckMethod }}</span>
              <select
                :value="globalValue('tcp_check_http_method', 'HEAD')"
                @change="saveGlobal('tcp_check_http_method', $event)"
              >
                <option value="HEAD">HEAD</option>
                <option value="GET">GET</option>
              </select>
            </label>
            <label class="wide">
              <span>{{ text.udpTargets }}</span>
              <input
                :value="globalValue('udp_check_dns')"
                @change="saveGlobal('udp_check_dns', $event)"
              />
            </label>
            <label class="check">
              <input
                :checked="globalBoolean('auto_config_kernel_parameter', false)"
                type="checkbox"
                @change="saveGlobal('auto_config_kernel_parameter', $event)"
              />
              {{ text.autoConfigKernel }}
            </label>
            <label class="check">
              <input
                :checked="globalBoolean('disable_waiting_network', false)"
                type="checkbox"
                @change="saveGlobal('disable_waiting_network', $event)"
              />
              {{ text.waitNetwork }}
            </label>
          </div>
        </section>

        <section class="panel settings-panel">
          <div class="panel-title">
            <div>
              <p class="kicker">03</p>
              <h2>{{ text.resolverSettings }}</h2>
            </div>
          </div>
          <div class="form-grid">
            <label>
              <span>{{ text.dialMode }}</span>
              <select
                :value="globalValue('dial_mode', 'domain')"
                @change="saveGlobal('dial_mode', $event)"
              >
                <option value="ip">{{ text.ipMode }}</option>
                <option value="domain">{{ text.domainMode }}</option>
                <option value="domain+">{{ text.enhancedDomainMode }}</option>
                <option value="domain++">domain++</option>
              </select>
            </label>
            <label>
              <span>{{ text.sniffingTimeout }}</span>
              <input
                :value="globalValue('sniffing_timeout', '30ms')"
                placeholder="30ms"
                @change="saveGlobal('sniffing_timeout', $event)"
              />
            </label>
            <label class="wide">
              <span>{{ text.bootstrapResolver }}</span>
              <input
                :value="globalValue('bootstrap_resolver')"
                placeholder="223.5.5.5:53"
                @change="saveGlobal('bootstrap_resolver', $event)"
              />
            </label>
            <label class="wide">
              <span>{{ text.fallbackResolver }}</span>
              <input
                :value="globalValue('fallback_resolver', '8.8.8.8:53')"
                @change="saveGlobal('fallback_resolver', $event)"
              />
            </label>
            <label>
              <span>{{ text.bandwidthTx }}</span>
              <input
                :value="globalValue('bandwidth_max_tx')"
                placeholder="200 mbps"
                @change="saveGlobal('bandwidth_max_tx', $event)"
              />
            </label>
            <label>
              <span>{{ text.bandwidthRx }}</span>
              <input
                :value="globalValue('bandwidth_max_rx')"
                placeholder="200 mbps"
                @change="saveGlobal('bandwidth_max_rx', $event)"
              />
            </label>
          </div>
        </section>

        <section class="panel settings-panel">
          <div class="panel-title">
            <div>
              <p class="kicker">04</p>
              <h2>{{ text.tlsSettings }}</h2>
            </div>
          </div>
          <div class="form-grid">
            <label>
              <span>{{ text.tlsImplementation }}</span>
              <select
                :value="globalValue('tls_implementation', 'tls')"
                @change="saveGlobal('tls_implementation', $event)"
              >
                <option value="tls">tls</option>
                <option value="utls">utls</option>
              </select>
            </label>
            <label>
              <span>{{ text.tlsImitate }}</span>
              <input
                :value="globalValue('utls_imitate', 'chrome_auto')"
                @change="saveGlobal('utls_imitate', $event)"
              />
            </label>
            <label class="check">
              <input
                :checked="globalBoolean('allow_insecure', false)"
                type="checkbox"
                @change="saveGlobal('allow_insecure', $event)"
              />
              {{ text.insecure }}
            </label>
            <label class="check">
              <input
                :checked="globalBoolean('tls_fragment', false)"
                type="checkbox"
                @change="saveGlobal('tls_fragment', $event)"
              />
              {{ text.tlsFragment }}
            </label>
            <label>
              <span>{{ text.fragmentLength }}</span>
              <input
                :value="globalValue('tls_fragment_length')"
                placeholder="100-200"
                @change="saveGlobal('tls_fragment_length', $event)"
              />
            </label>
            <label>
              <span>{{ text.fragmentInterval }}</span>
              <input
                :value="globalValue('tls_fragment_interval')"
                placeholder="10-20"
                @change="saveGlobal('tls_fragment_interval', $event)"
              />
            </label>
            <label class="check wide">
              <input
                :checked="globalBoolean('mptcp', false)"
                type="checkbox"
                @change="saveGlobal('mptcp', $event)"
              />
              {{ text.mptcp }}
            </label>
          </div>
        </section>
      </div>
    </section>

    <section v-else-if="activeTab === 'nodes'" class="section-stack">
      <section class="import-box">
        <div class="section-head">
          <div>
            <p class="kicker">{{ text.nodeKicker }}</p>
            <h2>{{ text.importNode }}</h2>
          </div>
          <span class="hint"
            >ss / trojan / anytls / vmess / vless / hysteria2</span
          >
        </div>
        <div class="import-row">
          <input
            v-model="nodeLink"
            :placeholder="
              zh
                ? '粘贴分享链接，解析后加入配置'
                : 'Paste a share link to parse and add'
            "
            @keyup.enter="importNode"
          /><button
            class="primary"
            :disabled="nodeBusy || !nodeLink.trim()"
            @click="importNode"
          >
            {{ nodeBusy ? text.testing : text.parse }}
          </button>
        </div>
      </section>
      <section class="node-tools">
        <input v-model="nodeSearch" :placeholder="text.search" /><label
          class="check"
          ><input v-model="showSecrets" type="checkbox" />
          {{ text.revealCredentials }}</label
        >
        <div class="probe-options">
          <label
            ><span>{{ text.testTarget }}</span
            ><input
              v-model="testTarget"
              :placeholder="zh ? '主机:端口' : 'host:port'"
          /></label>
          <label
            ><span>{{ text.testUrl }}</span
            ><input
              v-model="testUrl"
              type="url"
              :placeholder="zh ? 'HTTP 检测地址' : 'HTTP check URL'"
          /></label>
        </div>
        <button class="secondary" @click="mergeRuntimeNodes">{{ text.refreshNodes }}</button>
      </section>
      <p class="runtime-node-hint"><i />{{ text.runtimeNodeHint }}</p>
      <section v-if="visibleNodes.length" class="node-list">
        <article v-for="node in visibleNodes" :key="node.name" class="node-row">
          <div class="node-main">
            <span class="protocol">{{ node.protocol }}</span>
            <div>
              <h3>{{ node.name }}</h3>
            <p>
                {{ node.runtime ? text.runtimeNodes : `${node.host}:${node.port}` }}
                <span v-if="node.sni">· SNI {{ node.sni }}</span>
              </p>
            </div>
          </div>
          <div class="node-meta">
            <span>{{ node.runtime ? (node.runtimeType || text.runtimeNode) : (node.network || "tcp") }}</span
            ><span v-if="node.tls" class="secure">TLS</span
            ><code v-if="node.password && showSecrets">{{ node.password }}</code
            ><code v-else-if="node.password">••••••••</code>
          </div>
          <div class="node-actions">
            <button v-if="node.raw" @click="testNode(node)">
              {{ nodeBusy ? text.testing : text.test }}</button
            ><button v-if="node.raw" @click="editNode(node)">{{ text.edit }}</button
            ><button v-if="node.raw" class="danger-text" @click="deleteNode(node)">
              {{ text.remove }}
            </button>
          </div>
        </article>
      </section>
      <p v-else class="empty">{{ text.noNodes }}</p>
      <section
        v-if="nodeTest"
        class="test-result"
        :class="{ failed: !nodeTest.passed }"
      >
        <strong
          >{{ nodeTest.passed ? text.passed : text.failed }} ·
          {{ nodeTest.node.name }}</strong
        ><span>{{ nodeTest.summary }}</span>
        <pre>{{ nodeTest.output }}</pre>
      </section>
      <section class="panel subscription-panel">
        <div class="panel-title subscription-title">
          <div>
            <p class="kicker">{{ text.subscriptionKicker }}</p>
            <h2>{{ text.subscriptions }}</h2>
          </div>
          <span class="hint">{{ text.subscriptionHint }}</span>
        </div>
        <div v-if="model.subscriptions.length" class="subscription-list">
          <div
            v-for="subscription in model.subscriptions"
            :key="subscription.name"
            class="compact-row subscription-row"
          >
            <div class="subscription-main">
              <strong>{{ subscription.name }}</strong>
              <span class="truncate">{{ subscription.url }}</span>
            </div>
            <button
              class="danger-text"
              @click="removeSubscription(subscription)"
            >
              {{ text.remove }}
            </button>
          </div>
        </div>
        <p v-else class="empty small">{{ text.noSubscriptions }}</p>
        <div class="subscription-add">
          <label>
            <span>{{ text.subscriptionNameOptional }}</span>
            <input
              v-model="newSubscriptionName"
              :placeholder="zh ? '留空自动使用域名' : 'Leave empty to use hostname'"
            />
          </label>
          <label class="wide">
            <span>{{ text.subscriptionLinkRequired }}</span>
            <input
              v-model="newSubscriptionUrl"
              type="url"
              placeholder="https://example.com/subscription"
              @keyup.enter="addSubscription"
            />
          </label>
          <button
            class="primary"
            :disabled="!newSubscriptionUrl.trim()"
            @click="addSubscription"
          >
            {{ text.addSubscription }}
          </button>
        </div>
      </section>
      <section v-if="nodeDraft" class="modal-backdrop">
        <div class="modal">
          <div class="panel-title">
            <h2>{{ text.edit }} · {{ selectedNode?.name }}</h2>
            <button
              class="icon-button"
              @click="
                nodeDraft = null;
                selectedNode = null;
              "
            >
              ×
            </button>
          </div>
          <div class="form-grid">
            <label
              ><span>{{ text.name }}</span
              ><input v-model="nodeDraft.name" /></label
            ><label
              ><span>{{ text.protocol }}</span
              ><input v-model="nodeDraft.protocol" /></label
            ><label
              ><span>{{ text.host }}</span
              ><input v-model="nodeDraft.host" /></label
            ><label
              ><span>{{ text.port }}</span
              ><input v-model.number="nodeDraft.port" type="number" /></label
            ><label
              ><span>{{ text.sni }}</span
              ><input v-model="nodeDraft.sni" /></label
            ><label
              ><span>{{ text.network }}</span
              ><input v-model="nodeDraft.network" /></label
            ><label class="wide"
              ><span>{{ text.password }}</span
              ><input
                v-model="nodeDraft.password"
                :type="showSecrets ? 'text' : 'password'" /></label
            ><label class="check wide"
              ><input v-model="nodeDraft.insecure" type="checkbox" />
              {{ text.insecure }}</label
            >
          </div>
          <div class="modal-actions">
            <button
              @click="
                nodeDraft = null;
                selectedNode = null;
              "
            >
              {{ text.cancel }}</button
            ><button class="primary" @click="saveNode">
              {{ text.saveNode }}
            </button>
          </div>
        </div>
      </section>
    </section>

    <section v-else-if="activeTab === 'routing'" class="section-stack">
      <section class="section-head">
        <div>
          <p class="kicker">{{ text.routingKicker }}</p>
          <h2>{{ text.rules }}</h2>
        </div>
        <label class="inline-control"
          ><span>{{ text.fallback }}</span
          ><select :value="model.routing.fallback" @change="updateFallback">
            <option v-for="outbound in outbounds" :key="outbound">
              {{ outbound === "direct" ? text.direct : outbound }}
            </option>
          </select></label
        >
      </section>
      <div class="rule-add">
        <input
          v-model="newRule"
          placeholder="domain(suffix:example.com) -> proxy"
          @keyup.enter="addRule"
        /><button class="primary" @click="addRule">{{ text.addRule }}</button>
      </div>
      <div class="rule-list">
        <div
          v-for="(rule, index) in model.routing.rules"
          :key="`${rule}-${index}`"
          class="rule-row"
        >
          <code>{{ String(index + 1).padStart(2, "0") }}</code
          ><span>{{ rule }}</span
          ><button class="danger-text" @click="removeRule(rule)">
            {{ text.removeRule }}
          </button>
        </div>
      </div>
      <div class="split-panels">
        <div class="panel">
          <div class="panel-title">
            <h2>{{ text.groups }}</h2>
          </div>
          <div
            v-for="group in model.groups"
            :key="group.name"
            class="compact-row"
          >
            <strong>{{ group.name }}</strong
            ><span>{{ group.filter || text.allNodes }}</span
            ><span>{{ group.policy || "min_moving_avg" }}</span
            ><code v-if="group.default">{{ group.default }}</code
            ><code>{{ group.final || "direct" }}</code>
          </div>
          <p v-if="!model.groups.length" class="empty small">-</p>
          <div class="small-add group-add">
            <input v-model="newGroupName" :placeholder="text.name" /><input
              v-model="newGroupFilter"
              :placeholder="text.groupFilter"
            /><select
              v-model="newGroupPolicy"
            >
              <option value="min_moving_avg">
                {{ text.minMovingAverage }}
              </option>
              <option value="roundrobin">{{ text.roundRobin }}</option>
              <option value="fixed(0)">{{ text.fixedFirst }}</option></select
            ><select v-model="newGroupDefault">
              <option value="">{{ text.groupDefault }}</option>
              <option v-for="outbound in outbounds" :key="`default-${outbound}`">
                {{ outbound === "direct" ? text.direct : outbound }}
              </option></select
            ><select v-model="newGroupFinal">
              <option v-for="outbound in outbounds" :key="outbound">
                {{ outbound === "direct" ? text.direct : outbound }}
              </option></select
            ><button @click="addGroup">{{ text.addGroup }}</button>
          </div>
        </div>
      </div>
    </section>

    <section v-else-if="activeTab === 'dns'" class="section-stack dns-page">
      <section class="section-head">
        <div>
          <p class="kicker">{{ text.dnsKicker }}</p>
          <h2>{{ text.upstreams }}</h2>
          <p class="hint">{{ text.dnsProtocolHint }}</p>
        </div>
      </section>

      <DnsTopology
        :upstreams="model.dns.upstreams"
        :labels="{
          title: text.dnsTopologyTitle,
          hint: text.dnsTopologyHint,
          countSuffix: text.dnsTopologyCountSuffix,
          lan: text.dnsTopologyLan,
          lanDetail: text.dnsTopologyLanDetail,
          service: text.dnsTopologyService,
          serviceDetail: text.dnsTopologyServiceDetail,
          direct: text.dnsTopologyDirect,
          proxy: text.dnsTopologyProxy,
          noDirect: text.dnsTopologyNoDirect,
          noProxy: text.dnsTopologyNoProxy,
          noUpstreams: text.dnsTopologyNoUpstreams,
          edit: text.dnsTopologyEdit,
        }"
        @edit="editDnsFromTopology"
      />

      <section ref="dnsEditor" class="panel dns-editor">
        <div class="panel-title"><h2>{{ dnsEditingName ? text.edit : text.addDns }}</h2></div>
        <div class="form-grid dns-form-grid">
          <label><span>{{ text.name }}</span><input v-model="newDnsName" placeholder="cloudflare" /></label>
          <label><span>{{ text.dnsProtocol }}</span><select v-model="newDnsProtocol" @change="updateDnsProtocol"><option v-for="protocol in dnsProtocols" :key="protocol" :value="protocol">{{ dnsProtocolLabel(protocol) }}</option></select></label>
          <label><span>{{ text.dnsHost }}</span><input v-model="newDnsHost" placeholder="1.1.1.1" /></label>
          <label><span>{{ text.dnsPort }}</span><input v-model.number="newDnsPort" type="number" min="1" max="65535" placeholder="53" /></label>
          <label v-if="dnsSupportsPath(newDnsProtocol)"><span>{{ text.dnsPath }}</span><input v-model="newDnsPath" placeholder="/dns-query" /></label>
          <label><span>{{ text.sni }}</span><input v-model="newDnsSni" placeholder="可选" /></label>
          <label class="wide"><span>{{ text.dnsOutbound }}</span><select v-model="newDnsOutbound" :disabled="dnsDirectOnly(newDnsProtocol)"><option value="direct">{{ text.direct }}</option><option v-for="outbound in outbounds.filter(item => item !== 'direct')" :key="outbound" :value="outbound">{{ outbound }}</option></select></label>
        </div>
        <div class="form-actions"><button class="primary" @click="saveDns">{{ dnsEditingName ? text.save : text.addDns }}</button><button v-if="dnsEditingName" @click="resetDnsForm">{{ text.cancel }}</button></div>
      </section>

      <section class="panel dns-list">
        <div v-for="upstream in model.dns.upstreams" :key="upstream.name" class="compact-row dns-upstream-row">
          <div class="dns-upstream-copy"><strong>{{ upstream.name }}</strong><code>{{ dnsUri(upstream) }}</code><small>{{ upstream.outbound || text.direct }}</small></div>
          <div class="row-actions"><button class="icon-button" :title="text.edit" :aria-label="text.edit" @click="editDns(upstream.name)">✎</button><button class="icon-button danger" :title="text.remove" :aria-label="text.remove" @click="removeDns(upstream.name)">×</button></div>
        </div>
        <p v-if="!model.dns.upstreams.length" class="empty">{{ text.unavailable }}</p>
      </section>

      <section class="panel dns-routing-panel">
        <div class="panel-title"><div><h2>{{ text.dnsRequestRouting }}</h2><p class="hint">qname / qtype 规则按从上到下匹配。</p></div></div>
        <div class="form-grid">
          <label><span>{{ text.dnsRequestFallback }}</span><select :value="dnsRequestFallback || 'reject'" @change="updateDnsRequestFallback"><option v-for="upstream in model.dns.upstreams" :key="`request-fallback-${upstream.name}`" :value="upstream.name">{{ upstream.name }}</option><option value="reject">reject</option><option value="asis">asis</option></select></label>
          <label><span>{{ text.dnsRuleType }}</span><select v-model="dnsRuleType"><option value="qname">qname</option><option value="qtype">qtype</option></select></label>
          <label v-if="dnsRuleType === 'qname'"><span>{{ text.dnsRuleMatch }}</span><select v-model="dnsRuleMatch"><option value="suffix">suffix</option><option value="keyword">keyword</option><option value="full">full</option><option value="regex">regex</option><option value="geosite">geosite</option></select></label>
          <label><span>{{ text.dnsRuleValue }}</span><input v-model="dnsRuleValue" :placeholder="dnsRuleType === 'qtype' ? 'a, aaaa' : 'google.com'" @keyup.enter="addDnsRequestRule" /></label>
          <label><span>{{ text.dnsRuleAction }}</span><select v-model="dnsRuleAction"><option v-for="upstream in model.dns.upstreams" :key="`request-action-${upstream.name}`" :value="upstream.name">{{ upstream.name }}</option><option value="reject">reject</option><option value="asis">asis</option></select></label>
        </div>
        <div class="form-actions"><button class="primary" @click="addDnsRequestRule">{{ text.dnsAddRule }}</button></div>
        <div class="dns-rule-list"><div v-for="(rule, index) in dnsRequestRules" :key="`${rule}-${index}`" class="compact-row"><code>{{ rule }}</code><button class="icon-button danger" :title="text.dnsRemoveRule" :aria-label="text.dnsRemoveRule" @click="removeDnsRequestRule(index)">×</button></div><p v-if="!dnsRequestRules.length" class="empty">{{ text.dnsNoRules }}</p></div>
      </section>

      <section class="panel dns-routing-panel">
        <div class="panel-title"><div><h2>{{ text.dnsResponseRouting }}</h2><p class="hint">{{ text.dnsAdvancedHint }}</p></div></div>
        <div class="form-grid">
          <label><span>{{ text.dnsResponseFallback }}</span><select :value="dnsResponseFallback" @change="updateDnsResponseFallback"><option value="accept">accept</option><option value="reject">reject</option></select></label>
          <label><span>{{ text.dnsRequery }} · {{ text.dnsRuleValue }}</span><select v-model="dnsResponseSource" @change="updateDnsResponseRequery"><option value="">{{ text.unavailable }}</option><option v-for="upstream in model.dns.upstreams" :key="`response-source-${upstream.name}`" :value="upstream.name">{{ upstream.name }}</option></select></label>
          <label><span>{{ text.dnsRuleAction }}</span><select v-model="dnsResponseTarget" @change="updateDnsResponseRequery"><option value="">{{ text.unavailable }}</option><option v-for="upstream in model.dns.upstreams" :key="`response-target-${upstream.name}`" :value="upstream.name">{{ upstream.name }}</option></select></label>
        </div>
        <div class="dns-rule-list"><div v-for="rule in dnsResponseRules" :key="rule" class="compact-row"><code>{{ rule }}</code></div><p v-if="!dnsResponseRules.length" class="empty">{{ text.dnsNoRules }}</p></div>
      </section>

      <section class="panel dns-options-panel">
        <div class="panel-title"><h2>{{ text.dnsOptions }}</h2></div>
        <div class="form-grid">
          <label><span>{{ text.ipVersionPreference }}</span><select :value="dnsValue('ipversion_prefer', '') || 'both'" @change="updateDnsIpVersion"><option value="both">自动（IPv4 + IPv6）</option><option value="4">IPv4</option><option value="6">IPv6</option></select></label>
          <label><span>{{ text.cacheTtl }}</span><input :value="dnsValue('optimistic_cache_ttl', '600')" type="number" min="0" @change="updateDnsOption('optimistic_cache_ttl', $event)" /></label>
          <label><span>{{ text.maxCacheSize }}</span><input :value="dnsValue('max_cache_size', '10000')" type="number" min="1" @change="updateDnsOption('max_cache_size', $event)" /></label>
          <label class="check"><input :checked="dnsBoolean('optimistic_cache', true)" type="checkbox" @change="updateDnsOption('optimistic_cache', $event)" />{{ text.optimisticCache }}</label>
        </div>
      </section>
      <details class="panel dns-raw"><summary>{{ text.dnsSection }}</summary><pre>{{ model.dns.raw || text.unavailable }}</pre></details>
    </section>

    <section v-else-if="activeTab === 'logs'" class="section-stack logs-page">
      <section class="section-head">
        <div>
          <p class="kicker">{{ text.logsKicker }}</p>
          <h2>{{ text.logs }}</h2>
        </div>
        <button :disabled="busy" @click="refreshDetails">
          {{ text.refresh }}
        </button>
      </section>
      <section class="panel log-panel">
        <pre class="log-stream">{{ displayLogs || text.noLogs }}</pre>
      </section>
    </section>

    <section v-else-if="activeTab === 'advanced'" class="section-stack">
      <section class="section-head">
        <div>
          <p class="kicker">{{ text.experimental }}</p>
          <h2>{{ text.advanced }}</h2>
          <p class="hint">{{ text.advancedHint }}</p>
        </div>
        <button @click="parseAdvanced">{{ text.parseCode }}</button>
      </section>
      <div class="form-grid experimental-form">
        <label
          ><span>{{ text.controller }}</span
          ><input
            :value="experimentalController"
            @change="
              updateExperimental(
                'external_controller',
                ($event.target as HTMLInputElement).value,
                'controller',
              )
            " /></label
        ><label
          ><span>{{ text.ui }}</span
          ><input
            :value="experimentalUi"
            @change="
              updateExperimental(
                'external_ui',
                ($event.target as HTMLInputElement).value,
                'ui',
              )
            " /></label
        ><label
          ><span>{{ text.mode }}</span
          ><select
            :value="experimentalMode"
            @change="
              updateExperimental(
                'default_mode',
                ($event.target as HTMLSelectElement).value,
                'mode',
              )
            "
          >
            <option value="Rule">{{ text.ruleMode }}</option>
            <option value="Global">{{ text.globalMode }}</option>
            <option value="Direct">{{ text.directMode }}</option>
          </select></label
        ><label
          ><span>{{ text.secret }}</span
          ><input
            :value="experimentalSecret"
            :type="showSecrets ? 'text' : 'password'"
            @change="
              updateExperimental(
                'secret',
                ($event.target as HTMLInputElement).value,
                'secret',
              )
            "
        /></label>
      </div>
      <section class="panel cache-panel">
        <div class="panel-title">
          <div>
            <p class="kicker">cache_file</p>
            <h2>{{ text.cacheSettings }}</h2>
          </div>
        </div>
        <div class="form-grid">
          <label class="check">
            <input
              :checked="experimentalCacheEnabled"
              type="checkbox"
              @change="updateCache('enabled', $event)"
            />
            {{ text.cacheEnabled }}
          </label>
          <label class="check">
            <input
              :checked="experimentalStoreDns"
              type="checkbox"
              @change="updateCache('store_dns', $event)"
            />
            {{ text.storeDns }}
          </label>
          <label class="check">
            <input
              :checked="experimentalStoreFakeip"
              type="checkbox"
              @change="updateCache('store_fakeip', $event)"
            />
            {{ text.storeFakeip }}
          </label>
          <label>
            <span>{{ text.cachePath }}</span>
            <input
              :value="experimentalCachePath"
              @change="updateCache('path', $event)"
            />
          </label>
          <label>
            <span>{{ text.cacheId }}</span>
            <input
              :value="experimentalCacheId"
              @change="updateCache('cache_id', $event)"
            />
          </label>
        </div>
      </section>
      <div class="code-editor">
        <div class="panel-title">
          <h2>{{ text.config }}</h2>
          <span class="hint">DAE</span>
        </div>
        <textarea
          v-model="advancedCode"
          spellcheck="false"
          autocomplete="off"
        />
      </div>
    </section>

    <section v-if="showPreview && preview" class="modal-backdrop">
      <div class="modal preview-modal">
        <div class="panel-title">
          <h2>{{ text.previewTitle }}</h2>
          <button class="icon-button" @click="showPreview = false">×</button>
        </div>
        <p class="preview-summary">
          {{ preview.changed ? text.changed : text.valid }} ·
          <strong>{{ preview.additions }}</strong> {{ text.additions }} ·
          <strong>{{ preview.removals }}</strong> {{ text.removals }}
        </p>
        <pre class="diff">{{ preview.diff || text.valid }}</pre>
        <div class="modal-actions">
          <button @click="showPreview = false">{{ text.close }}</button
          ><button
            class="primary"
            :disabled="!preview.valid || !preview.changed"
            @click="confirmApply"
          >
            {{ text.confirm }}
          </button>
        </div>
      </div>
    </section>
  </section>
</template>
