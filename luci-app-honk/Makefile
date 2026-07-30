include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-honk
PKG_VERSION:=0.0.1
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-honk
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI support for Honk
	DEPENDS:=+honk
endef

define Package/luci-app-honk/description
	LuCI package scaffold for the Honk transparent proxy.
endef

$(eval $(call BuildPackage,luci-app-honk))
