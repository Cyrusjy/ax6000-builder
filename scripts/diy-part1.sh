#!/bin/bash
# ============================================================================
#  diy-part1.sh —— 在 feeds update/install 之后、应用 .config 之前执行
#  用途：feeds 加速、包预检（提前 5 分钟发现缺包，而不是白编 3 小时后报错）
# ============================================================================
set -e

echo "==> diy-part1: 开始"

# ----------------------------------------------------------------------------
# 1) （可选）国内网络加速：把 feeds 换成 GitHub 代理镜像
#    GitHub Actions 的 runner 在国外，不需要；
#    本机 / WSL 编译时执行：FEEDS_MIRROR=1 bash scripts/diy-part1.sh
# ----------------------------------------------------------------------------
if [ "${FEEDS_MIRROR:-0}" = "1" ]; then
  echo "==> 启用 feed 镜像加速（ghfast.top）"
  sed -i -E 's#(https://github\.com/)#https://ghfast.top/\1#g' feeds.conf.default
  ./scripts/feeds update -a
  ./scripts/feeds install -a
fi

echo "==> 当前 feeds："
grep -E '^src-git' feeds.conf.default || true

# ----------------------------------------------------------------------------
# 2) 预检：确认要用的包在源码树 / feeds 里真的存在
#    make defconfig 对不存在的包是「静默丢弃」，不预检的话你会在固件里
#    发现插件莫名消失。这里主动报出来。
#
#    注意：这只是「初判」。权威判定由 diy-part2.sh 在 make defconfig 之后
#    回读 .config 完成（那时 Kconfig 已经把所有依赖和无效项处理干净）。
# ----------------------------------------------------------------------------
echo "==> 包预检（初判）"
MISSING=0

# ---------------------------------------------------------------------------
# 判断包是否存在。两种形态必须分开处理，否则一定误判（两种都实测踩过）：
#
#   ① 普通包：源码树 / feeds 里有**同名目录**
#      如 feeds/packages/net/smartdns、package/mtk/applications/luci-app-eqos-mtk
#      例外：bpftool-minimal 这种带 BUILD_VARIANT 的，目录叫 bpftool
#
#   ② 内核模块包 kmod-xxx：**没有同名目录**，而是在某个包定义文件里用
#      `define KernelPackage/<去掉 kmod- 前缀的名字>` 声明，例如
#        package/kernel/linux/modules/netdevices.mk → KernelPackage/mediatek_hnat
#        package/mtk/drivers/mt_wifi/Makefile       → KernelPackage/mt_wifi
#      注意：定义文件可能离包目录很远、文件名也不含关键词，
#      所以必须扫全树，不能只 grep package/kernel/
#      （上一轮就是因为只扫了 netsupport.mk 而漏掉了 netdevices.mk 里的 hnat）
# ---------------------------------------------------------------------------
echo "==> 收集源码/feeds 里所有 KernelPackage 定义名（一次性，避免重复扫描）"
KPKG_LIST="$(
  grep -rhsE --include='Makefile' --include='*.mk' \
      '^define KernelPackage/[A-Za-z0-9_.-]+' \
      package feeds target/linux 2>/dev/null \
  | sed -E 's|^define KernelPackage/([A-Za-z0-9_.-]+).*|\1|' \
  | sort -u
)"
echo "    共 $(printf '%s\n' "$KPKG_LIST" | grep -c . || true) 个 kmod 包定义"

# pkg_exists <包名> [源码目录名]
#   bpftool-minimal 这类「包名 ≠ 目录名」的把目录名作为第 2 参传入
pkg_exists() {
  local p="$1" dir="${2:-$1}" base="${p#kmod-}"

  if [ "${p#kmod-}" != "$p" ]; then
    # kmod 包：只有 KernelPackage 声明这一种来源
    if [ -n "$KPKG_LIST" ] && printf '%s\n' "$KPKG_LIST" | grep -qx -- "$base"; then
      return 0
    fi
    return 1
  fi

  # 普通包：同名目录（或显式指定的目录名）
  find package feeds -maxdepth 5 -type d -name "$dir" 2>/dev/null | grep -q . && return 0
  return 1
}

# check_pkg <包名> [源码目录名]
#   bpftool-minimal 这类「包名 ≠ 目录名」的把目录名作为第 2 参传入
check_pkg() {
  local p="$1"
  if pkg_exists "$p" "${2:-$1}"; then
    echo "  [ok]   $p"
  else
    echo "  [WARN] $p —— 源码/feeds 中未找到，编译时会被丢弃"
    MISSING=1
  fi
}

check_pkg smartdns
check_pkg luci-app-smartdns
check_pkg luci-app-eqos-mtk
check_pkg luci-app-mtwifi-cfg
check_pkg luci-app-turboacc-mtk
check_pkg kmod-mt_wifi
check_pkg kmod-mediatek_hnat
check_pkg kmod-warp
check_pkg kmod-sched-bpf
check_pkg kmod-xdp-sockets-diag
check_pkg bpftool-minimal bpftool

if [ "$MISSING" = "1" ]; then
  echo "::warning::部分包不存在（见上面 [WARN]）。固件仍会编译，但不会有这些插件。"
  echo "           这些包通常是 feeds 分支里没有，可自行添加第三方 feed"
  echo "           （见 README「增加第三方插件源」）。最终以 diy-part2 的实测结果为准。"
fi

# ----------------------------------------------------------------------------
# 3) 兜底：本仓库无线走 MTK 闭源驱动（mt_wifi），不要同时选 mac80211 的
#    mt76 系列 LuCI 应用，否则会出现「无线设置界面打架 / 无线起不来」
# ----------------------------------------------------------------------------
# 如需强制清理，取消下面注释：
# rm -rf feeds/luci/applications/luci-app-mt76* 2>/dev/null || true

echo "==> diy-part1: 完成"
