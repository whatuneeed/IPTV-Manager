include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI IPTV Manager - IPTV playlist and EPG management
LUCI_DEPENDS:=+uhttpd +gzip +wget-ssl +curl
LUCI_PKGARCH:=all
PKG_VERSION:=3.11
PKG_RELEASE:=1
PKG_LICENSE:=MIT

# LuCI JS (OpenWrt 24+)
define Package/luci-app-iptv-manager/conffiles
/etc/config/iptv
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
