#!/bin/bash
# ============================================================================
#  diy-part2.sh —— 在 make defconfig 之后、正式编译之前执行
#  核心作用：把 OpenWrt 没有暴露成 CONFIG_KERNEL_* 的 eBPF/BTF 内核符号
#            直接注入 target 内核配置文件，让 eBPF 真正编进内核
# ============================================================================
set -e

TARGET_DIR="target/linux/mediatek/filogic"

# ----------------------------------------------------------------------------
# 1) 注入 eBPF / BTF 内核选项
#
#    背景：.config 里只能写 Config-kernel.in 声明过的 CONFIG_KERNEL_xxx；
#    而 CONFIG_BPF_SYSCALL / CONFIG_BPF_JIT / CONFIG_NET_CLS_BPF /
#    CONFIG_NET_ACT_BPF 这些并没有暴露，必须写进
#    target/linux/<target>/<subtarget>/config-<内核版本>，
#    该文件会被合并进内核 .config（后出现的值生效）。
# ----------------------------------------------------------------------------
KCFG="$(ls ${TARGET_DIR}/config-* 2>/dev/null | head -1)"
if [ -z "$KCFG" ]; then
  echo "::error::找不到 ${TARGET_DIR}/config-* 内核配置文件，脚本需要更新"
  exit 1
fi
echo "==> 注入 eBPF 内核选项到 $KCFG"

# 先删掉同名旧行，避免重复
for sym in BPF BPF_SYSCALL BPF_JIT BPF_EVENTS CGROUP_BPF BPF_STREAM_PARSER \
           NET_CLS_BPF NET_ACT_BPF NET_CLS_ACT NET_SCH_CLSACT NET_SCH_INGRESS \
           XDP_SOCKETS DEBUG_INFO DEBUG_INFO_BTF DEBUG_INFO_REDUCED \
           KPROBES KPROBE_EVENTS UPROBE_EVENTS IKCONFIG IKCONFIG_PROC; do
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
CONFIG_BPF_STREAM_PARSER=y
# BTF 依赖：DEBUG_INFO 打开、DEBUG_INFO_REDUCED 必须关闭，否则 CONFIG_DEBUG_INFO_BTF
# 会被内核 Kconfig 静默丢弃（eBPF CO-RE 就用不了，这是最常见的「配了不生效」原因）
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBE_EVENTS=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
EOF

echo "==> 注入完成，末尾内容："
tail -25 "$KCFG"

# ----------------------------------------------------------------------------
# 3) eBPF 相关的 kmod / 用户态工具：源码里真的有才加
#    这些包在 feeds 里不一定存在。写死在 .config 里有两个坏处：
#    ① 不存在 → 被 defconfig 静默丢弃，你以为装了其实没有；
#    ② 存在但编不过 → 3 小时的构建在最后一刻失败。
#    所以这里按存在性决定，并把结果打印出来。
# ----------------------------------------------------------------------------
echo "==> eBPF 工具/模块存在性检查"

add_pkg_if_exists() {
  local p="$1"
  if find package feeds -maxdepth 5 -type d -name "$p" 2>/dev/null | grep -q .; then
    if ! grep -q "^CONFIG_PACKAGE_${p}=" .config; then
      echo "CONFIG_PACKAGE_${p}=y" >> .config
    fi
    echo "  [+] $p  已加入"
  else
    echo "  [-] $p  源码/feeds 中没有，跳过"
  fi
}

for p in kmod-sched-bpf kmod-xdp-sockets-diag tc-bpf bpftool bpftool-full libbpf; do
  add_pkg_if_exists "$p"
done

# ----------------------------------------------------------------------------
# 4) 提醒：eBPF 程序与 MTK 硬件加速（HNAT/flow offloading）会互相抢包
#    编译时保留两者，运行时二选一即可。
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
# 5)（可选）个性化：取消注释即可生效
# ----------------------------------------------------------------------------
# 版本号后缀（LuCI 概览页会显示这个版本名）
# sed -i 's|^CONFIG_VERSION_NUMBER=.*|CONFIG_VERSION_NUMBER="r$(date +%Y%m%d)-ax6000"|' .config

# 自定义源码作者标识
# sed -i 's|^CONFIG_VERSION_CODE=.*|CONFIG_VERSION_CODE="$(date +%Y%m%d)"|' .config

echo "==> diy-part2: 完成"
