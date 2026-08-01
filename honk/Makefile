include $(TOPDIR)/rules.mk

PKG_NAME:=honk
PKG_VERSION:=0.0.1_beta25
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Honk OpenWrt feed

include $(CURDIR)/source.mk
PKG_HASH:=$(PKG_MIRROR_HASH)

PKG_SOURCE_SUBDIR:=honk-$(PKG_SOURCE_VERSION)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_SOURCE_SUBDIR)
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

HONK_PREBUILT_DIR?=$(CURDIR)/files/bin
HONK_USE_PREBUILT:=$(if $(and $(wildcard $(HONK_PREBUILT_DIR)/honk-core),$(wildcard $(HONK_PREBUILT_DIR)/honk-tool)),1)

ifneq ($(HONK_USE_PREBUILT),1)
PKG_BUILD_DEPENDS:=rust/host
endif

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

define Package/honk
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Honk eBPF transparent proxy
	DEPENDS:=@(x86_64||aarch64)
	DEPENDS+=+ca-bundle +ip-full +tc-full +nsenter +libstdcpp
	DEPENDS+=+kmod-sched-core +kmod-sched-bpf +kmod-veth
	DEPENDS+=+v2ray-geoip +v2ray-geosite
	URL:=https://github.com/Glassyiris/honk
endef

define Package/honk/description
	Honk userspace and eBPF transparent proxy engine.
endef

define Package/honk/conffiles
/etc/config/honk
/etc/honk/config.dae
/etc/honk/config.d/
endef

RUST_TARGET:=$(RUSTC_TARGET_ARCH)
BPF_RUST_TOOLCHAIN?=nightly
BPF_CARGO?=rustup run $(BPF_RUST_TOOLCHAIN) cargo
BPF_RUSTC?=$(shell rustup which --toolchain $(BPF_RUST_TOOLCHAIN) rustc 2>/dev/null)
HONK_CORE_BINARY:=$(if $(filter 1,$(HONK_USE_PREBUILT)),$(HONK_PREBUILT_DIR)/honk-core,$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/honk-core)
HONK_TOOL_BINARY:=$(if $(filter 1,$(HONK_USE_PREBUILT)),$(HONK_PREBUILT_DIR)/honk-tool,$(PKG_BUILD_DIR)/target/$(RUST_TARGET)/release/honk-tool)

define Build/Prepare
	$(call Build/Prepare/Default)
	$(if $(filter x86_64 aarch64,$(ARCH)),,$(error honk supports only x86_64 and aarch64))
	@test -f $(PKG_BUILD_DIR)/Cargo.toml
endef

ifeq ($(HONK_USE_PREBUILT),1)
define Build/Compile
	@test -x $(HONK_CORE_BINARY)
	@test -x $(HONK_TOOL_BINARY)
endef
else
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
endif

define Package/honk/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/libexec/honk $(1)/etc/init.d $(1)/etc/config $(1)/etc/honk/config.d
	$(INSTALL_BIN) $(HONK_CORE_BINARY) $(1)/usr/bin/honk-core
	$(INSTALL_BIN) $(HONK_TOOL_BINARY) $(1)/usr/bin/honk-tool
	$(INSTALL_BIN) $(CURDIR)/files/honk.init $(1)/etc/init.d/honk
	$(INSTALL_BIN) $(CURDIR)/files/honk-launcher $(1)/usr/libexec/honk/honk-launcher
	$(INSTALL_CONF) $(CURDIR)/files/honk.config $(1)/etc/config/honk
	$(INSTALL_CONF) $(CURDIR)/files/config.dae $(1)/etc/honk/config.dae
endef

$(eval $(call BuildPackage,honk))
