#!/bin/sh
set -eu

nonce=$1
stage=/tmp/honk-fixture-$nonce
client_ns=hk${nonce}c
services_ns=hk${nonce}s
lan_host=hk${nonce}lh
lan_peer=hk${nonce}ln
wan_host=hk${nonce}wh
wan_peer=hk${nonce}wn
nft_table=hk${nonce}
old_forward=0
dns_a_pid=
dns_b_pid=
proxy_pid=

mkdir -p "$stage"
old_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 0)

cleanup() {
	set +e
	/etc/init.d/honk stop >/dev/null 2>&1 || true
	[ -n "$dns_a_pid" ] && kill "$dns_a_pid" 2>/dev/null || true
	[ -n "$dns_b_pid" ] && kill "$dns_b_pid" 2>/dev/null || true
	[ -n "$proxy_pid" ] && kill "$proxy_pid" 2>/dev/null || true
	nft delete table inet "$nft_table" >/dev/null 2>&1 || true
	ip route del 223.5.5.5/32 via 198.18.20.2 dev "$wan_host" >/dev/null 2>&1 || true
	ip route del 8.8.8.8/32 via 198.18.20.2 dev "$wan_host" >/dev/null 2>&1 || true
	for ns in "$client_ns" "$services_ns"; do
		if ip netns list | grep -q "^$ns"; then
			for pid in $(ip netns pids "$ns" 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
			ip netns del "$ns" >/dev/null 2>&1 || true
		fi
	done
	ip link del "$lan_host" >/dev/null 2>&1 || true
	ip link del "$wan_host" >/dev/null 2>&1 || true
	sysctl -w net.ipv4.ip_forward="$old_forward" >/dev/null 2>&1 || true
	rm -rf "$stage"
}
trap cleanup EXIT INT TERM

for tool in ip nsenter nft dnsmasq microsocks jq; do
	command -v "$tool" >/dev/null 2>&1 || {
		jq -n --arg tool "$tool" '{schemaVersion:"honk.target-fixture.v1",status:"blocked",ok:false,reason:"FIXTURE_TOOL_MISSING",missing:$tool}'
		exit 2
	}
done

ip netns add "$client_ns"
ip netns add "$services_ns"
ip link add "$lan_host" type veth peer name "$lan_peer"
ip link set "$lan_peer" netns "$client_ns"
ip link add "$wan_host" type veth peer name "$wan_peer"
ip link set "$wan_peer" netns "$services_ns"

ip addr add 198.18.10.1/24 dev "$lan_host"
ip link set "$lan_host" up
ip addr add 198.18.20.1/24 dev "$wan_host"
ip link set "$wan_host" up
ip route add 223.5.5.5/32 via 198.18.20.2 dev "$wan_host"
ip route add 8.8.8.8/32 via 198.18.20.2 dev "$wan_host"
sysctl -w net.ipv4.ip_forward=1 >/dev/null

ip netns exec "$client_ns" ip link set lo up
ip netns exec "$client_ns" ip addr add 198.18.10.2/24 dev "$lan_peer"
ip netns exec "$client_ns" ip link set "$lan_peer" up
ip netns exec "$client_ns" ip route add default via 198.18.10.1
ip netns exec "$services_ns" ip link set lo up
ip netns exec "$services_ns" ip addr add 198.18.20.2/24 dev "$wan_peer"
ip netns exec "$services_ns" ip addr add 223.5.5.5/32 dev "$wan_peer"
ip netns exec "$services_ns" ip addr add 8.8.8.8/32 dev "$wan_peer"
ip netns exec "$services_ns" ip link set "$wan_peer" up
ip netns exec "$services_ns" ip route add default via 198.18.20.1

nft add table inet "$nft_table"
nft add chain inet "$nft_table" forward '{ type filter hook forward priority -100; policy accept; }'
nft add rule inet "$nft_table" forward iifname "$lan_host" oifname br-lan counter drop

ip netns exec "$services_ns" dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces --listen-address=223.5.5.5 --address=/#/198.18.20.2 --log-queries --log-facility="$stage/dns-aliyun.log" --pid-file="$stage/dns-aliyun.pid" >"$stage/dns-aliyun.stderr" 2>&1 &
dns_a_pid=$!
ip netns exec "$services_ns" dnsmasq --no-daemon --no-resolv --no-hosts --bind-interfaces --listen-address=8.8.8.8 --address=/#/198.18.20.2 --log-queries --log-facility="$stage/dns-google.log" --pid-file="$stage/dns-google.pid" >"$stage/dns-google.stderr" 2>&1 &
dns_b_pid=$!
ip netns exec "$services_ns" microsocks -i 198.18.20.2 -p 1080 -w 198.18.10.2 >"$stage/microsocks.log" 2>&1 &
proxy_pid=$!
sleep 1

ping_ok=false
dns_ok=false
socks_ok=false
set +e
ip netns exec "$client_ns" ping -c 1 -W 2 198.18.20.2 >"$stage/ping.log" 2>&1
[ "$?" -eq 0 ] && ping_ok=true
ip netns exec "$client_ns" busybox nslookup gfw-member.example 223.5.5.5 >"$stage/dns-query.log" 2>&1
[ "$?" -eq 0 ] && dns_ok=true
ip netns exec "$client_ns" nc -z -w 2 198.18.20.2 1080 >"$stage/socks-probe.log" 2>&1
[ "$?" -eq 0 ] && socks_ok=true
set -e

forward_drop=$(nft -j list chain inet "$nft_table" forward 2>/dev/null | jq '[.nftables[]?.rule?.counter?.packets // 0] | add // 0' 2>/dev/null || printf 0)
quick_discovery=$(ubus call network.interface dump 2>/dev/null | jq -c '[.interface[]? | select(.l3_device == "'"$lan_host"'" or .l3_device == "'"$wan_host"'")]' 2>/dev/null || printf '[]')
jq -n \
	--arg client "$client_ns" --arg services "$services_ns" --arg lan "$lan_host" --arg wan "$wan_host" \
	--argjson ping "$ping_ok" --argjson dns "$dns_ok" --argjson socks "$socks_ok" --argjson drops "$forward_drop" --argjson discovery "$quick_discovery" \
	'{schemaVersion:"honk.target-fixture.v1",status:"partial",ok:false,reason:"QUICK_DISCOVERY_REQUIRES_LOGICAL_INTERFACES",network:{clientNamespace:$client,servicesNamespace:$services,lanDevice:$lan,wanDevice:$wan,managementInterfaceExcluded:true},services:{dns:{aliyun:"223.5.5.5:53",google:"8.8.8.8:53",mockStarted:$dns},socks5:{address:"198.18.20.2:1080",mockStarted:$socks}},checks:{vethReachability:$ping,dnsMockReachability:$dns,socksMockReachability:$socks,forwardPublicDropCounter:$drops,quickDiscoveryMatches:$discovery},publicEgressGuard:{fixtureRuleInstalled:true,brLanDropCounter:$drops,publicEgressProven:false},quickApi:{status:"not-run",reason:"UBUS_LOGICAL_INTERFACES_NOT_EXPOSED"},cleanup:{automatic:true,managementInterfacePreserved:true}}'
