include $(TOPDIR)/rules.mk

PKG_NAME:=honk
PKG_VERSION:=0.0.1.beta.25
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Honk OpenWrt feed

include $(CURDIR)/source.mk

PKG_BUILD_DIR:=$(BUILD_DIR)/honk-$(PKG_SOURCE_VERSION)
PKG_BUILD_PARALLEL:=1
PKG_USE_MIPS16:=0

include $(INCLUDE_DIR)/package.mk

define Package/honk
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Honk eBPF transparent proxy
	DEPENDS:=@(x86_64||aarch64)
	URL:=https://github.com/Glassyiris/honk
endef

define Package/honk/description
	Honk userspace and eBPF transparent proxy engine.
endef

define Build/Compile
	$(if $(filter-out x86_64 aarch64,$(ARCH)),$(error honk supports only x86_64 and aarch64))
	$(call Build/Compile/Default)
endef

define Package/honk/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/release-musl/honk-core $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/target/release-musl/honk-tool $(1)/usr/bin/
endef

$(eval $(call BuildPackage,honk))
