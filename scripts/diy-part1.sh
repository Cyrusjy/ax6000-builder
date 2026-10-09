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
# ----------------------------------------------------------------------------
echo "==> 包预检"
MISSING=0
check_pkg() {
  local p="$1"
  if find package feeds -maxdepth 5 -type d -name "$p" 2>/dev/null | grep -q .; then
    echo "  [ok]   $p"
  else
    echo "  [WARN] $p —— 源码/feeds 中未找到，编译时会被丢弃"
    MISSING=1
  fi
}

for p in \
  smartdns luci-app-smartdns \
  luci-app-eqos-mtk luci-app-mtwifi-cfg luci-app-turboacc-mtk \
  kmod-mt_wifi kmod-mediatek_hnat kmod-warp \
  kmod-sched-bpf tc-bpf bpftool ; do
  check_pkg "$p"
done

if [ "$MISSING" = "1" ]; then
  echo "::warning::部分包不存在（见上面 [WARN]）。固件仍会编译，但不会有这些插件。"
  echo "           smartdns / bpftool 这类包若缺失，通常是 feeds 分支里没有，"
  echo "           可以自行添加第三方 feed（见 README「增加第三方插件源」）。"
fi

# ----------------------------------------------------------------------------
# 3) 兜底：本仓库无线走 MTK 闭源驱动（mt_wifi），不要同时选 mac80211 的
#    mt76 系列 LuCI 应用，否则会出现「无线设置界面打架 / 无线起不来」
# ----------------------------------------------------------------------------
# 如需强制清理，取消下面注释：
# rm -rf feeds/luci/applications/luci-app-mt76* 2>/dev/null || true

echo "==> diy-part1: 完成"
