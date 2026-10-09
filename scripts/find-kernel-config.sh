#!/bin/bash
# ============================================================================
#  find-kernel-config.sh —— 定位 OpenWrt 编译产生的「内核」.config
#
#  为什么需要这个脚本：
#    上一轮 workflow 里写的是 `ls build_dir/target-*/linux-*/.config`，
#    少了 `linux-<版本>` 这一层（见 include/kernel.mk：
#      KERNEL_BUILD_DIR ?= $(BUILD_DIR)/linux-$(BOARD)_$(SUBTARGET)
#      LINUX_DIR        ?= $(KERNEL_BUILD_DIR)/linux-$(LINUX_VERSION)
#     内核 .config 位于 $(LINUX_DIR)/.config
#    ）结果路径取空 → grep 空字符串 → 校验静默失效，
#    还会打印出「未检测到 DEBUG_INFO_BTF」这种**假告警**。
#
#  本脚本用「路径 + 内容」双重判据，并且会把所有候选打印到 stderr 便于诊断。
#  成功：stdout 输出路径，退出码 0
#  失败：退出码 1
# ============================================================================
set -u

echo "[find-kernel-config] 开始探测内核 .config" >&2

# 内核 .config 的内容特征（OpenWrt 自己的 .config 不会有这些）
is_kernel_config() {
  local f="$1"
  [ -s "$f" ] || return 1
  # 必须含内核特有符号
  grep -qE '^CONFIG_(LOCALVERSION|INIT_ENV_ARG_LIMIT|HAVE_ARCH_|MODULES=|KERNEL_)[A-Z_]*=' "$f" 2>/dev/null || return 1
  # 不能是 OpenWrt 的 target 配置
  if grep -qE '^CONFIG_TARGET_(MEDIATEK|MULTI_PROFILE)' "$f" 2>/dev/null; then
    return 1
  fi
  return 0
}

# 优先级 1：$(LINUX_DIR)/.config  →  build_dir/target-*/linux-<board>_<sub>/linux-<ver>/.config
echo "[find-kernel-config] 候选（优先级 1，LINUX_DIR/.config）:" >&2
while IFS= read -r f; do
  [ -n "$f" ] || continue
  echo "    $f  size=$(wc -c < "$f" 2>/dev/null || echo '?')" >&2
  if is_kernel_config "$f"; then
    echo "[find-kernel-config] 命中: $f" >&2
    echo "$f"
    exit 0
  fi
done < <(find build_dir -maxdepth 5 -type f -path '*/linux-*/linux-*/.config' 2>/dev/null)

# 优先级 2：$(KERNEL_BUILD_DIR)/.config  →  build_dir/target-*/linux-<board>_<sub>/.config
echo "[find-kernel-config] 候选（优先级 2，KERNEL_BUILD_DIR/.config）:" >&2
while IFS= read -r f; do
  [ -n "$f" ] || continue
  echo "    $f  size=$(wc -c < "$f" 2>/dev/null || echo '?')" >&2
  if is_kernel_config "$f"; then
    echo "[find-kernel-config] 命中: $f" >&2
    echo "$f"
    exit 0
  fi
done < <(find build_dir -maxdepth 4 -type f -path '*/linux-*/.config' 2>/dev/null)

# 优先级 3：全 build_dir 兜底（用内容判据）
echo "[find-kernel-config] 候选（优先级 3，全 build_dir 兜底）:" >&2
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if is_kernel_config "$f"; then
    echo "[find-kernel-config] 命中(兜底): $f" >&2
    echo "$f"
    exit 0
  fi
done < <(find build_dir -maxdepth 6 -type f -name '.config' 2>/dev/null)

echo "[find-kernel-config] 失败：未找到任何符合内核特征的 .config" >&2
exit 1
