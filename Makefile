# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=The modern ImmortalWrt proxy platform for ARM64/AMD64
LUCI_PKGARCH:=all
LUCI_DEPENDS:= \
	+sing-box \
	+firewall4 \
	+kmod-nft-tproxy

PKG_NAME:=luci-app-homeproxy-ce
LUCI_PKG_CONFIG:=homeproxy-ce

define Package/luci-app-homeproxy-ce/conffiles
/etc/config/homeproxy-ce
/etc/homeproxy-ce/certs/
/etc/homeproxy-ce/ruleset/
/etc/homeproxy-ce/resources/direct_list.txt
/etc/homeproxy-ce/resources/proxy_list.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
