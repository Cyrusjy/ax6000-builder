#!/bin/bash
# ============================================================================
#  diy-part2.sh —— 在 .config 就位之后、正式编译之前执行
#  核心作用：把 OpenWrt 没有暴露成 CONFIG_KERNEL_* 的 eBPF/BTF 内核符号
#            直接注入 target 内核配置文件，让 eBPF 真正编进内核
#
#  设计原则（上一轮踩过的坑）：
#   ① 内核符号分两层写：OpenWrt 的 .config（CONFIG_KERNEL_xxx）+ target 的
#      config-<ver>（CONFIG_xxx）。只写一层必然「看着配了其实没生效」。
#   ② 包是否真的存在，不靠猜，靠 make defconfig 之后回读 .config 实测。
#   ③ 最后一步必须自检，不通过就报 ::error:: 而不是 ::warning::，
#      避免「静默缺件」。
# ============================================================================
set -e

TARGET_DIR="target/linux/mediatek/filogic"

# ----------------------------------------------------------------------------
# 1) 注入 eBPF / BTF 内核符号到 target 内核 config
#
#    背景：.config 里只能写 Config-kernel.in 声明过的 CONFIG_KERNEL_xxx；
#    而 CONFIG_BPF_SYSCALL / CONFIG_BPF_JIT / CONFIG_NET_CLS_BPF /
#    CONFIG_NET_ACT_BPF 这些并没有暴露，必须写进
#    target/linux/<target>/<subtarget>/config-<内核版本>。
#    该文件由 OpenWrt 以「subtarget 层」合并进内核 .config，优先级最高。
# ----------------------------------------------------------------------------
KCFG="$(ls ${TARGET_DIR}/config-* 2>/dev/null | head -1)"
if [ -z "$KCFG" ]; then
  echo "::error::找不到 ${TARGET_DIR}/config-* 内核配置文件，脚本需要更新"
  exit 1
fi
echo "==> 注入 eBPF 内核选项到 $KCFG"

# 先删掉同名旧行，避免重复定义
# 注意：模式里的 [ =]/$ 保证 CONFIG_DEBUG_INFO 不会误删 CONFIG_DEBUG_INFO_BTF
for sym in BPF BPF_SYSCALL BPF_JIT BPF_EVENTS CGROUP_BPF BPF_STREAM_PARSER \
           NET_CLS_BPF NET_ACT_BPF NET_CLS_ACT NET_SCH_CLSACT NET_SCH_INGRESS \
           XDP_SOCKETS XDP_SOCKETS_DIAG DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_REDUCED \
           KPROBES KPROBE_EVENTS UPROBE_EVENTS IKCONFIG IKCONFIG_PROC \
           NETLINK_DIAG NFNETLINK_QUEUE NETFILTER_XT_TARGET_NFQUEUE; do
  sed -i -E "/^#? ?CONFIG_${sym}[ =]/d" "$KCFG"
done

cat >> "$KCFG" <<'EOF'
# ===== eBPF / BTF support (injected by ax6000-builder) =====
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_BPF_EVENTS=y
CONFIG_CGROUP_BPF=y
CONFIG_NET_CLS_BPF=y
CONFIG_NET_ACT_BPF=y
CONFIG_NET_CLS_ACT=y
CONFIG_NET_SCH_CLSACT=y
CONFIG_NET_SCH_INGRESS=y
CONFIG_XDP_SOCKETS=y
CONFIG_XDP_SOCKETS_DIAG=y
CONFIG_BPF_STREAM_PARSER=y
# BTF 的硬依赖：DEBUG_INFO 要开、DEBUG_INFO_REDUCED 必须关，
# 否则内核 Kconfig 会把 CONFIG_DEBUG_INFO_BTF 静默丢弃（eBPF CO-RE 直接废掉）
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBE_EVENTS=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
# ===== sing-box 1.14.3 内核模块依赖（injected by ax6000-builder）=====
# kmod-nft-queue 需要 CONFIG_NFNETLINK_QUEUE（=m 即可）
# kmod-netlink-diag 需要 CONFIG_NETLINK_DIAG（=m 即可）
# kmod-nfnetlink-queue 需要 CONFIG_NFNETLINK_QUEUE（=m 即可）
# sing-box ipk 还 depends kmod-nft-queue，后者 depends kmod-nfnetlink-queue
CONFIG_NETLINK_DIAG=m
CONFIG_NFNETLINK_QUEUE=m
CONFIG_NETFILTER_XT_TARGET_NFQUEUE=m
EOF

echo "==> 注入完成，$KCFG 末尾内容："
tail -25 "$KCFG"

# ----------------------------------------------------------------------------
# 2) 判断「包是否真实存在」——两种形态必须分开处理，否则一定误判
#     ① 普通包：源码树 / feeds 里有**同名目录**
#        例外：bpftool-minimal 这种带 BUILD_VARIANT 的，目录叫 bpftool
#     ② 内核模块包 kmod-xxx：**没有同名目录**，而是在某个包定义文件里用
#        `define KernelPackage/<去掉 kmod- 前缀的名字>` 声明，例如
#          package/kernel/linux/modules/netdevices.mk → KernelPackage/mediatek_hnat
#          package/mtk/drivers/mt_wifi/Makefile       → KernelPackage/mt_wifi
#        定义文件可能离包目录很远、文件名也不含关键词，必须扫全树，
#        不能只 grep package/kernel/（上一轮就是这样漏掉了 netdevices.mk）。
#
#     不过说到底这只是「初判」：真正的判定是 make defconfig 之后回读 .config。
# ----------------------------------------------------------------------------
echo "==> eBPF 工具/模块存在性初判（最终以 defconfig 回读为准）"

echo "  ---- 收集源码/feeds 里所有 KernelPackage 定义名（一次性）----"
KPKG_LIST="$(
  grep -rhsE --include='Makefile' --include='*.mk' \
      '^define KernelPackage/[A-Za-z0-9_.-]+' \
      package feeds target/linux 2>/dev/null \
  | sed -E 's|^define KernelPackage/([A-Za-z0-9_.-]+).*|\1|' \
  | sort -u
)"
echo "      共 $(printf '%s\n' "$KPKG_LIST" | grep -c . || true) 个 kmod 包定义"

# 用法：pkg_exists <包名> [源码目录名]
#   bpftool-minimal 这类「包名 ≠ 目录名」的，把目录名作为第 2 参传入
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

add_pkg_if_exists() {
  local p="$1"
  local dir="${2:-$1}"
  if pkg_exists "$p" "$dir"; then
    if ! grep -q "^CONFIG_PACKAGE_${p}=" .config; then
      echo "CONFIG_PACKAGE_${p}=y" >> .config
    fi
    echo "  [+] 候选加入: $p"
  else
    echo "  [-] 源码/feeds 中没有: $p"
  fi
}

# 说明：libbpf 的真实包名是 libbpf1（ABI 版本后缀），且它是 bpftool 的依赖，
#       选上 bpftool 后会自动带入，所以这里不单独写。
#       tc-bpf 在 25.12 的 feeds 里不存在，不要写。
add_pkg_if_exists kmod-sched-bpf
add_pkg_if_exists kmod-xdp-sockets-diag
add_pkg_if_exists bpftool-minimal bpftool

# sing-box 相关内核模块（已在 .config 里显式选了 kmod-nft-queue 等，
# 这里只做存在性初判，最终以 defconfig 回读为准）
echo "==> sing-box 内核模块存在性初判"
for kmod in nft-queue nfnetlink-queue netlink-diag; do
  if printf '%s\n' "$KPKG_LIST" | grep -qx -- "$kmod"; then
    echo "  [+] kmod-$kmod 存在"
  else
    echo "  [-] kmod-$kmod 未找到 KernelPackage 定义"
  fi
done

# sing-box 和 luci-app-homeproxy 的包存在性初判（feeds packages / luci）
for pkg in sing-box luci-app-homeproxy luci-i18n-homeproxy-zh-cn; do
  if find package feeds -maxdepth 5 -type d -name "$pkg" 2>/dev/null | grep -q .; then
    echo "  [+] $pkg 存在"
  else
    echo "  [-] $pkg 未找到同名目录（可能包名不同或在 feeds 里）"
  fi
done

# ----------------------------------------------------------------------------
# 3) make defconfig —— 解析依赖、把无效项丢弃
# ----------------------------------------------------------------------------
echo "==> make defconfig（第 1 次：解析候选包）"
make defconfig

# ----------------------------------------------------------------------------
# 4) defconfig 之后，强制确保 OpenWrt 侧的 eBPF 开关（二次保险）
#    Config-kernel.in 里 KERNEL_DEBUG_INFO_BTF 的 default y 带了 && BUILDBOT，
#    在 GitHub Actions 上不成立，所以必须显式置 y；这里再兜一次底。
# ----------------------------------------------------------------------------
ensure_sym_y() {
  local sym="$1"
  if grep -q "^CONFIG_KERNEL_${sym}=" .config; then
    sed -i "s|^CONFIG_KERNEL_${sym}=.*|CONFIG_KERNEL_${sym}=y|" .config
  elif grep -q "^# CONFIG_KERNEL_${sym} is not set" .config; then
    sed -i "s|^# CONFIG_KERNEL_${sym} is not set|CONFIG_KERNEL_${sym}=y|" .config
  else
    echo "CONFIG_KERNEL_${sym}=y" >> .config
  fi
}

for s in DEBUG_INFO DEBUG_INFO_BTF BPF_EVENTS CGROUP_BPF XDP_SOCKETS KPROBES KALLSYMS; do
  ensure_sym_y "$s"
done

# DEBUG_INFO_REDUCED 必须是 n（BTF 的硬依赖）。它的 default 在非 BUILDBOT 环境下是 y，
# 所以这里显式挡掉，否则内核 Kconfig 会把 DEBUG_INFO_BTF 静默关掉。
if grep -q "^CONFIG_KERNEL_DEBUG_INFO_REDUCED=" .config; then
  sed -i 's|^CONFIG_KERNEL_DEBUG_INFO_REDUCED=.*|# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set|' .config
else
  echo "# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set" >> .config
fi

echo "==> make defconfig（第 2 次：固化 eBPF 开关）"
make defconfig

# ----------------------------------------------------------------------------
# 5) 自检：回读 .config，确认关键项真的生效；不通过就报错（不是警告）
# ----------------------------------------------------------------------------
echo
echo "==================== eBPF 配置自检 ===================="
FAIL=0

check_y() {
  if grep -q "^CONFIG_${1}=y" .config; then
    echo "  [OK]   CONFIG_${1}=y"
  else
    echo "  [FAIL] CONFIG_${1} 未生效"
    FAIL=1
  fi
}
check_n() {
  if grep -q "^CONFIG_KERNEL_${1}=" .config; then
    echo "  [FAIL] CONFIG_KERNEL_${1} 竟然是 y（BTF 会被内核丢弃）"
    FAIL=1
  else
    echo "  [OK]   CONFIG_KERNEL_${1} 未启用"
  fi
}

check_y KERNEL_DEBUG_INFO
check_y KERNEL_DEBUG_INFO_BTF
check_y KERNEL_BPF_EVENTS
check_y KERNEL_CGROUP_BPF
check_y KERNEL_XDP_SOCKETS
check_y KERNEL_KPROBES
check_y KERNEL_KALLSYMS
check_n DEBUG_INFO_REDUCED

echo
echo "  ---- 内核构建工具 pahole（BTF 生成必须） ----"
if grep -q "^CONFIG_DWARVES=y" .config; then
  echo "  [OK]   CONFIG_DWARVES=y（tools/dwarves 会被编译）"
else
  echo "  [WARN] CONFIG_DWARVES 未开启；KERNEL_DEBUG_INFO_BTF 理论上会 select 它，"
  echo "         若最终内核 .config 里 DEBUG_INFO_BTF 没生效，这里是首要排查点"
fi

echo
echo "  ---- eBPF 相关包（defconfig 后的真实状态） ----"
for p in kmod-sched-bpf kmod-xdp-sockets-diag bpftool-minimal bpftool libbpf1 libbpf; do
  if grep -q "^CONFIG_PACKAGE_${p}=y" .config; then
    echo "  [OK]   $p"
  else
    echo "  [--]   $p  （未选中 / 包名不存在，属正常）"
  fi
done

echo
echo "  ---- sing-box 相关包（defconfig 后的真实状态） ----"
for p in sing-box luci-app-homeproxy kmod-nft-queue kmod-nfnetlink-queue kmod-netlink-diag; do
  if grep -q "^CONFIG_PACKAGE_${p}=y" .config; then
    echo "  [OK]   $p"
  else
    echo "  [FAIL] $p  （未选中 —— 这是 sing-box 的依赖，必须生效）"
    FAIL=1
  fi
done
echo "======================================================"

if [ "$FAIL" = "1" ]; then
  echo "::error::eBPF/BTF 关键内核开关未生效，请检查上面的 [FAIL] 行"
  exit 1
fi

# ----------------------------------------------------------------------------
# 6) 提醒：eBPF 程序与 MTK 硬件加速（HNAT/flow offloading）会互相抢包
# ----------------------------------------------------------------------------
cat <<'NOTE'

  ┌──────────────────────────────────────────────────────────────────────┐
  │ 注意：本固件同时带 ① MTK HNAT/WARP 硬件加速 ② eBPF 内核能力          │
  │ 运行时不要同时用：跑 eBPF 程序（如 dae / einat / tc-bpf）前，先在     │
  │ LuCI → 网络 → TurboACC / 防火墙 里关掉 Flow Offloading，否则          │
  │ eBPF 抓到的包可能已经被硬件卸载走了。                                 │
  └──────────────────────────────────────────────────────────────────────┘
NOTE

# ----------------------------------------------------------------------------
# 7)（可选）个性化：取消注释即可生效
# ----------------------------------------------------------------------------
# 版本号后缀（LuCI 概览页会显示这个版本名）
# sed -i 's|^CONFIG_VERSION_NUMBER=.*|CONFIG_VERSION_NUMBER="r$(date +%Y%m%d)-ax6000"|' .config

echo "==> diy-part2: 完成"
