include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI IPTV Manager - IPTV playlist, EPG and catchup management
LUCI_DEPENDS:=+uhttpd +gzip +wget-ssl +curl +libopenssl +busybox
LUCI_PKGARCH:=all
PKG_VERSION:=3.21
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=IPTV Manager Project

# Config files
define Package/luci-app-iptv-manager/conffiles
/etc/config/iptv
endef

# Post-installation script
define Package/luci-app-iptv-manager/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
    # Enable uhttpd
    /etc/init.d/uhttpd enable 2>/dev/null || true
    # Copy srv.cgi to CGI dir
    if [ -f /www/luci-static/resources/view/iptv-manager/srv.cgi ]; then
        mkdir -p /www/cgi-bin
        cp /www/luci-static/resources/view/iptv-manager/srv.cgi /www/cgi-bin/srv.cgi
        chmod 755 /www/cgi-bin/srv.cgi
    fi
    # Run uci-defaults
    ( . /etc/uci-defaults/99-luci-iptv-manager ) && rm -f /etc/uci-defaults/99-luci-iptv-manager
    # Create symlink for CLI access
    ln -sf /usr/share/iptv-manager/IPTV-Manager.sh /usr/bin/iptv 2>/dev/null
    # Restart rpcd
    /etc/init.d/rpcd restart 2>/dev/null || true
}
exit 0
endef

# Cleanup on remove
define Package/luci-app-iptv-manager/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
    rm -f /www/cgi-bin/srv.cgi /www/cgi-bin/srv.html
    rm -f /usr/bin/iptv
    /etc/init.d/rpcd restart 2>/dev/null || true
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
