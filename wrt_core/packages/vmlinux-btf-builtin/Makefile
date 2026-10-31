# SPDX-License-Identifier: GPL-3.0-or-later
# Compatible with daeuniverse/openwrt-packages' vmlinux-btf-builtin provider.
# No external BTF blob, proxy binary, configuration, service or dashboard.

include $(TOPDIR)/rules.mk

PKG_NAME:=vmlinux-btf-builtin
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/vmlinux-btf-builtin
  SECTION:=kernel
  CATEGORY:=Kernel
  TITLE:=Dependency marker for built-in kernel BTF
  PKGARCH:=all
  PROVIDES:=@vmlinux-btf
  DEFAULT_VARIANT:=1
endef

define Package/vmlinux-btf-builtin/description
 Satisfies the vmlinux-btf dependency using this firmware's built-in kernel BTF.
endef

define Package/vmlinux-btf-builtin/preinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
[ -e /sys/kernel/btf/vmlinux ] && exit 0
echo "This package requires kernel BTF at /sys/kernel/btf/vmlinux." >&2
exit 1
endef

define Build/Compile
endef

define Package/vmlinux-btf-builtin/install
	true
endef

$(eval $(call BuildPackage,vmlinux-btf-builtin))
