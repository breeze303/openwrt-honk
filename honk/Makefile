include $(TOPDIR)/rules.mk

PKG_NAME:=honk
PKG_VERSION:=0.0.1_git
PKG_RELEASE:=18
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Honk OpenWrt feed

include $(CURDIR)/source.mk
PKG_HASH:=$(PKG_MIRROR_HASH)

PKG_SOURCE_SUBDIR:=honk-$(PKG_SOURCE_VERSION)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_SOURCE_SUBDIR)
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

GEO_CACHE_DIR?=$(CURDIR)/../.cache/dl
GEO_LOCK?=$(CURDIR)/../locks/geo.lock.json
GEO_SITE_CACHE:=$(GEO_CACHE_DIR)/loyalsoldier-geosite-202607312254.dat
GEO_IP_CACHE:=$(GEO_CACHE_DIR)/v2fly-geoip-202607171233.dat

PKG_BUILD_DEPENDS:=rust/host

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

define Package/honk
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Honk eBPF transparent proxy
	DEPENDS:=@(x86_64||aarch64)
	DEPENDS+=+ca-bundle +ip-full +tc-full +nsenter +libstdcpp +jq
	DEPENDS+=+kmod-sched-core +kmod-sched-bpf +kmod-veth
	URL:=https://github.com/Glassyiris/honk
endef

define Package/honk/description
	Honk userspace and eBPF transparent proxy engine.
endef

define Package/honk/conffiles
/etc/config/honk
/etc/honk/config.dae
/etc/honk/config.d/
/etc/honk/subscriptions/
/etc/honk/.sub/
endef

RUST_TARGET:=$(RUSTC_TARGET_ARCH)
BPF_RUST_TOOLCHAIN?=nightly-2026-07-20
BPF_CARGO?=rustup run $(BPF_RUST_TOOLCHAIN) cargo
BPF_RUSTC?=$(shell rustup which --toolchain $(BPF_RUST_TOOLCHAIN) rustc 2>/dev/null)
HONK_CORE_BINARY:=$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/honk-core
HONK_TOOL_BINARY:=$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/honk-tool

define Build/Prepare
	$(call Build/Prepare/Default)
	$(if $(filter x86_64 aarch64,$(ARCH)),,$(error honk supports only x86_64 and aarch64))
	@test -f $(PKG_BUILD_DIR)/Cargo.toml
	@test -f $(GEO_LOCK)
	@test -f $(GEO_SITE_CACHE) && sha256sum $(GEO_SITE_CACHE) | cut -d ' ' -f 1 | grep -qx 1f3a743e8e30152a870a1674792af3976361436dcb1f510a43c499d430f6b13f
	@test -f $(GEO_IP_CACHE) && sha256sum $(GEO_IP_CACHE) | cut -d ' ' -f 1 | grep -qx b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a
endef

define Build/Compile
	$(if $(filter x86_64 aarch64,$(ARCH)),,$(error honk supports only x86_64 and aarch64))
	+cd $(PKG_BUILD_DIR)/crates/honk-ebpf && \
		CARGO_HOME=$(CARGO_HOME) \
		RUSTC=$(BPF_RUSTC) \
		RUSTUP_TOOLCHAIN=$(BPF_RUST_TOOLCHAIN) \
		$(BPF_CARGO) build --locked --release -Zbuild-std=core --target bpfel-unknown-none
	+cd $(PKG_BUILD_DIR) && \
		$(CARGO_PKG_CONFIG_VARS) \
		CC_$(subst -,_,$(RUST_TARGET))=$(TARGET_CC_NOCACHE) \
		CXX_$(subst -,_,$(RUST_TARGET))=$(TARGET_CXX_NOCACHE) \
		AR_$(subst -,_,$(RUST_TARGET))=$(TARGET_AR) \
		TARGET_CFLAGS="$(filter-out -fhonour-copts,$(TARGET_CFLAGS))" \
		BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(TOOLCHAIN_ROOT_DIR)" \
		cargo build --locked --release --target $(RUST_TARGET) \
			-p honk-core -p honk-tool --features honk-core/ebpf
endef

define Package/honk/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/libexec/honk $(1)/usr/lib/honk $(1)/usr/share/honk $(1)/etc/init.d $(1)/etc/config $(1)/etc/honk/config.d $(1)/etc/honk/subscriptions $(1)/etc/honk/.sub
	$(INSTALL_BIN) $(HONK_CORE_BINARY) $(1)/usr/bin/honk-core
	$(INSTALL_BIN) $(HONK_TOOL_BINARY) $(1)/usr/bin/honk-tool
	$(INSTALL_DATA) $(GEO_SITE_CACHE) $(1)/usr/lib/honk/geosite.dat
	$(INSTALL_DATA) $(GEO_IP_CACHE) $(1)/usr/lib/honk/geoip.dat
	ln -s /usr/lib/honk/geosite.dat $(1)/usr/share/honk/geosite.dat
	ln -s /usr/lib/honk/geoip.dat $(1)/usr/share/honk/geoip.dat
	$(INSTALL_DATA) $(GEO_LOCK) $(1)/usr/share/honk/geo.lock.json
	$(INSTALL_BIN) $(CURDIR)/files/honk.init $(1)/etc/init.d/honk
	$(INSTALL_BIN) $(CURDIR)/files/honk-launcher $(1)/usr/libexec/honk/honk-launcher
	$(INSTALL_BIN) $(CURDIR)/files/dnsmasq-integration $(1)/usr/libexec/honk/dnsmasq-integration
	$(INSTALL_BIN) $(CURDIR)/files/quick-transaction-worker $(1)/usr/libexec/honk/quick-transaction-worker
	$(INSTALL_BIN) $(CURDIR)/files/interface-discovery $(1)/usr/libexec/honk/interface-discovery
	$(INSTALL_CONF) $(CURDIR)/files/honk.config $(1)/etc/config/honk
	$(INSTALL_CONF) $(CURDIR)/files/config.dae $(1)/etc/honk/config.dae
	$(INSTALL_DATA) $(CURDIR)/files/config.dae.default $(1)/etc/honk/config.dae.default
endef

$(eval $(call BuildPackage,honk))
