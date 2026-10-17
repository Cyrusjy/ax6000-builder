# 红米 AX6000 自编译固件（ImmortalWrt 25.12 + MTK 闭源驱动）

用 GitHub Actions 云端编译 **chasey-dev/immortalwrt-mt798x-rebase**（`25.12` 分支）源码，
产出红米 AX6000（RB06 / MT7986A）可刷固件。不用本机装 Linux、不吃本机资源。

## 这个仓库是什么

一个「编译器仓库」——只放配置和脚本，不放源码。编译时由 Actions 现拉上游源码
（浅克隆，约 1 分钟），所以：

- 不需要 fork 那个 7 万多 commit 的上游仓库，省磁盘、省时间
- 上游更新后直接重跑 workflow 即可，不用同步 fork
- 你的个人定制（插件、默认设置）都在本仓库里，干净可回溯

```
本仓库                        上游源码（编译时临时克隆）
├── .github/workflows/  ──┐
├── config/  .config      ├──► immortalwrt/  ──► make ──► 固件 + Release
├── scripts/ diy 脚本     │
└── files/  uci-defaults ─┘
```

## 固件包含什么

| 项目 | 内容 |
| --- | --- |
| 基线 | ImmortalWrt `25.12`（内核 6.12） + MTK OpenWrt Feeds 补丁 |
| 无线 | **MTK 原厂闭源驱动** `mt_wifi` 7.6.7.3（固件 `mt7986-fw-20260601`），SKU=AX6000，Archer 面板走 `luci-app-mtwifi-cfg` |
| 硬件加速 | `kmod-mediatek_hnat`（有线/无线 HNAT）、`kmod-warp`、`luci-app-turboacc-mtk`、`luci-app-eqos-mtk`（你指定的 QoS） |
| eBPF | **内核实测开启** `BPF_SYSCALL / BPF_JIT / BPF_EVENTS / CGROUP_BPF / NET_CLS_BPF / NET_ACT_BPF / XDP_SOCKETS / DEBUG_INFO_BTF`；用户态带 `kmod-sched-bpf`、`kmod-xdp-sockets-diag`、`bpftool-minimal`、`libbpf1` |
| DNS | `smartdns` + `luci-app-smartdns`（你指定的） |
| 其它 | UPnP、zram-swap、TCP BBR、argon 主题、openssh sftp、htop、tcpdump、nano |

分区布局（profile）默认编 **`xiaomi_redmi-router-ax6000-mtkuboot`**，也就是
**MTK / 不死 U-Boot 大分区**那一套（bl-mt798x 的 `fip-fixed-parts`）。
另外两个 profile 也可在手动触发时选：`-ubootmod`（官方 OpenWrt U-Boot）、`-stock`（原厂布局）。

---

## 一、三步跑起来

### 1. 建一个仓库

GitHub 上新建仓库，名字随意（例如 `ax6000-builder`）。

> ⚠️ 建议设为 **Public**：私有仓库的 Actions 每月只有 2000 分钟，本编译一次约
> 约 100–160 分钟（实测首次 96 分钟），私有仓一个月只能编 12 次左右。公开仓库 Actions 时长不限。

### 2. 上传本目录

在 `ax6000-builder` 目录下执行（把 `<你的用户名>/<仓库名>` 换成实际的）：

```bash
cd ax6000-builder
git init -b main
git add .
git commit -m "init: AX6000 builder"
git remote add origin https://github.com/<你的用户名>/ax6000-builder.git
git push -u origin main
```

> 上传后到 GitHub 仓库页确认脚本的可执行位没丢；workflow 里已经会自动
> `chmod +x scripts/*.sh files/etc/uci-defaults/*`，所以即使 Windows 上传后
> 权限位丢失也不影响。

### 3. 触发编译

仓库页 → **Actions** → 左侧 **Build Redmi AX6000 Firmware** → **Run workflow**：

| 输入项 | 填什么 |
| --- | --- |
| `source_repo` | 默认 `chasey-dev/immortalwrt-mt798x-rebase`，不用改 |
| `source_ref` | 默认 `25.12` |
| `profile` | 默认 `xiaomi_redmi-router-ax6000-mtkuboot`（按你手上的 U-Boot 布局选） |
| `make_jobs` | 留空即可（自动用满 4 核） |

点 **Run workflow**，然后去喝杯茶——**首次全量编译实测 96 分钟**（免费 runner 4 核；
开启 eBPF/BTF 后要额外生成调试信息，预计 110–160 分钟）。编译完成会：

1. 在 **Releases** 里自动生成一个 tag，附上全部固件镜像
2. 在 **Artifacts** 里保留 30 天

第二次编译因为有 `dl/` 和 ccache 缓存，通常能快 30–50%。

---

## 二、编译产物怎么理解

跑完后看 `bin/targets/mediatek/filogic/`（Release 里也是这些文件）：

| 文件 | 用途 |
| --- | --- |
| `...-mtkuboot-squashfs-sysupgrade.bin` | **日常刷机 / 升级**，在不死 U-Boot 页面选 mtkuboot 布局上传，或系统内 `sysupgrade` |
| `...-mtkuboot-initramfs-kernel.bin` | 内存救援镜像（不写 flash，重启即消失），变砖时用 |
| `...-mtkuboot-squashfs-*.bin` | 首次安装用镜像（若产出） |
| `sha256sums` / `profiles.json` | 校验值 / 设备信息 |
| **`build-info.txt`** | 本次构建总结：内核 eBPF 的**实测**状态、产物清单、校验和 |
| **`kernel-config.txt`** | **内核 `.config` 全文** —— 判断 eBPF/BTF 是否真编进内核的最终证据 |
| **`precheck.txt`** | 编译前的配置核对结果（哪些包真正被选中） |

> 📎 上面三个文件就是「不用翻 Actions 日志」的原因：所有关键结论都在里面。

文件名里的三段才是关键：

```
immortalwrt- mediatek-filogic- xiaomi_redmi-router-ax6000- mtkuboot -squashfs-sysupgrade.bin
  系统名          平台            机型（必须完全匹配）      分区布局      用途
```

> **布局必须和 U-Boot 一致，刷错必砖**：
> `stock` = 原厂分区（没换 U-Boot）；`mtkuboot` = MTK/不死 U-Boot 大分区（110MB 那套）；
> `ubootmod` = 官方 OpenWrt U-Boot（需先刷 `.fip`，122.5MB UBI）。

---

## 三、刷机流程（mtkuboot 布局）

> ⚠️ **刷机有变砖风险**。以下步骤请逐条核对，别跳步。

**第 0 步：备份原厂分区（强烈建议）**

```bash
# SSH 进原厂固件后
cat /proc/mtd
for i in $(seq 0 20); do
  dd if=/dev/mtd$i of=/tmp/mtd$i.bin 2>/dev/null && echo "mtd$i ok"
done
# 用 scp 把 /tmp/mtd*.bin 拉回电脑保存
```

**第 1 步：拿到不死 U-Boot（已刷过就跳过）**

- 原厂固件先用 `xmir-patcher` 永久开启 SSH（`http://192.168.31.1`，root）
- 用 [hanwckf/bl-mt798x](https://github.com/hanwckf/bl-mt798x/releases) 的
  `mt7986_redmi_ax6000-fip-fixed-parts*.bin`，上传到路由器 `/tmp`，然后：

```bash
mtd erase FIP
mtd write /tmp/mt7986_redmi_ax6000-fip-fixed-parts.bin FIP
mtd verify /tmp/mt7986_redmi_ax6000-fip-fixed-parts.bin FIP
```

**第 2 步：进 U-Boot 恢复页面**

断电路由器 → 网线插 LAN 口 → 电脑网卡设静态 `192.168.31.100 / 255.255.255.0`
→ **用卡针按住 Reset（不是 Mesh 键）15 秒以上再上电**，等指示灯闪烁后松开
→ 浏览器打开 `http://192.168.31.1/index.html`

**第 3 步：烧固件**

在 U-Boot 页面里选 **mtkuboot 布局**（有下拉/单选项），上传本仓库编出来的
`...-mtkuboot-squashfs-sysupgrade.bin`，等待写入完成（约 1–2 分钟，中途**绝对不能断电**）。

**第 4 步：首次进入系统**

- 网卡改回自动获取 IP
- 访问 `http://192.168.1.1`（ImmortalWrt 默认地址）
- 用户名 `root`，**密码为空** → 进去第一件事就是设置密码

**以后升级**：LuCI → 系统 → 备份/刷写固件 → 上传新的 `-mtkuboot-squashfs-sysupgrade.bin`
（不勾「保留配置」可以彻底重置），或在 SSH 里 `sysupgrade -n /tmp/新固件.bin`。

---

## 四、改配置 / 加插件

### 换设备布局
手动触发 workflow 时改 `profile` 下拉框即可，三个布局共享同一份 `.config`。

### 加、删插件
编辑 `config/ax6000-mtkuboot.config`，照着格式加一行：

```
CONFIG_PACKAGE_luci-app-adguardhome=y
CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y
```

包名必须和源码/feeds 里的目录名一致（**区分大小写，用下划线**）。
不确定包名时，先在 workflow 日志里看 `包预检` 那一段，或本地执行：

```bash
./scripts/feeds list | grep -i 关键词      # 列出 feed 里的包
make menuconfig                            # 图形界面选，最直观
```

> `make defconfig` 对不存在的包是**静默丢弃**。所以：
> - 编译前，`打印最终关键配置` 这一步会把 `[y]` / `[ ]` 清单**直接渲染到 Actions 运行页面的摘要里**，不用翻日志；
> - 同时落成 `precheck.txt`，编完跟固件一起发布。
> 另外 `diy-part2.sh` 会在 `make defconfig` **之后**回读 `.config` 做自检，
> 关键 eBPF 开关没生效就直接让构建失败 —— 不会出现「编完了才发现插件没进去」。

### 加第三方插件源（如 passwall / openclash）
在 `scripts/diy-part1.sh` 里加一行，例如：

```bash
sed -i '1i src-git kenzo https://github.com/kenzok8/openwrt-packages' feeds.conf.default
sed -i '2i src-git small https://github.com/kenzok8/small' feeds.conf.default
```

然后在 `.config` 里打开对应 `CONFIG_PACKAGE_xxx=y`。
（注意：第三方包版本和 25.12 不一定兼容，报错时看 `编译失败时输出错误日志` 那一步的日志。）

### 改默认 IP / 主机名 / NTP
编辑 `files/etc/uci-defaults/99-ax6000-custom`，这是首次启动执行一次的脚本。

---

## 五、本地 / WSL2 编译（备用方案）

云编译排队太久、或者要反复调试时用本机：

```bash
# WSL2 里（Ubuntu 24.04），先把 Windows 路径从 PATH 里去掉，否则会报
# "spaces or non-ascii characters in PATH"
git clone --depth=1 -b 25.12 https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git
cd immortalwrt-mt798x-rebase
./scripts/feeds update -a && ./scripts/feeds install -a

# 用本仓库的配置
cp /path/to/ax6000-builder/config/ax6000-mtkuboot.config .config
make defconfig
# part2 内部会：注入内核 eBPF 符号 → 加候选包 → 跑两轮 make defconfig → 自检
# 自检不通过会直接返回非 0，避免白编几小时
bash /path/to/ax6000-builder/scripts/diy-part2.sh

make -j$(nproc) download
make -j$(nproc)              # 首次约 1.5–3 小时（16 核）
```

依赖安装（Ubuntu/Debian）：

```bash
sudo bash -c 'bash <(curl -s https://build-scripts.immortalwrt.org/init_build_environment.sh)'
```

磁盘要留 **40GB 以上**（含 dl 缓存和 build_dir）。

> 国内网络拉源码/feeds 慢的话，在本地跑 part1 时加 `FEEDS_MIRROR=1`：
> `FEEDS_MIRROR=1 bash scripts/diy-part1.sh`

---

## 六、排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `profile ... 不存在`（workflow 直接失败） | 源码里 profile 改名了。日志里会列出实际的 `DEVICE_xiaomi_*` 名称，改 `profile` 输入或 `.config` |
| 编译到 3 小时报 `No space left on device` | 磁盘没清干净。确认第一个 step `释放磁盘空间` 成功执行 |
| `make defconfig` 后某插件消失 | 包名不存在或拼错。看 Actions 页面摘要里的 `[y]`/`[ ]` 清单，或 `precheck.txt` |
| smartdns 编译报 openssl 相关错误 | 25.12 用的是 OpenSSL 3.x，feeds 里的 Makefile 偶尔对不上。可单独重编看详细报错：`make package/feeds/packages/smartdns/compile V=s`，必要时给该包加 `+libopenssl-legacy` 依赖 |
| 无线起不来 | 本固件是 MTK 闭源驱动，配置界面是 **mtwifi-cfg** 不是原生无线页；另外别同时选 mac80211/mt76 相关的 LuCI 应用 |
| `未能定位内核 .config`（step 直接失败） | `scripts/find-kernel-config.sh` 的探测没命中。日志里会打印 `build_dir` 结构和所有候选路径，把那段发出来即可定位 |
| `eBPF/BTF 关键内核开关未生效`（编译前就 fail） | 说明 `CONFIG_KERNEL_DEBUG_INFO_REDUCED` 被 Kconfig 强制置回了 `y`。检查 `.config` 里 `CONFIG_KERNEL_DEBUG_INFO` 是否也是 `y` |
| eBPF 程序跑不起来 | 先看 Release 里的 `kernel-config.txt`，确认里面有 `CONFIG_DEBUG_INFO_BTF=y`；跑 eBPF 前先关掉 Flow Offloading（HNAT 会把包硬件卸载走） |
| 超过 6 小时被 GitHub 掐断 | `timeout-minutes: 355` 已设置；若仍超时，把 `profile` 固定成单设备、别加太多插件 |

## 七、几个必须知道的坑

1. **布局不匹配 = 变砖**。`stock` / `mtkuboot` / `ubootmod` 三者互不兼容，
   刷之前先在 U-Boot 页面确认布局，再选同名镜像。
2. **不要在开启 HNAT 的同时用主线 flow offloading**，两者抢硬件加速。
   本配置里 `CONFIG_PACKAGE_TURBOACC_INCLUDE_FLOW_OFFLOADING` 已关。
3. **私有仓库 Actions 额度**：一次编译约 100–160 分钟，私有仓每月 2000 分钟（约 12 次）。
4. **缓存的真实生效情况**：`dl/` 源码包缓存（约 1.1GB）从第二次运行起就已命中，能省掉十几分钟下载。
   ccache 因为路径写错过（见变更记录 #11），**第一次真正生效要等到第四次运行**——
   第三次运行会从头编译并在结束存下缓存。改配置重编不必有心理负担，但别指望第三次就变快。
5. 编译成功 ≠ 一定刷得进去。刷之前先把 `initramfs-kernel.bin` 和原厂分区备份留在手上。

---

## 附：目录说明

```
.github/workflows/build-ax6000.yml   云编译流水线（含磁盘清理、缓存、校验、发 Release）
config/ax6000-mtkuboot.config        精简后的 .config（单设备 + eBPF + smartdns + eqos-mtk）
scripts/diy-part1.sh                 feeds 后处理 + 包预检（缺包提前报警）
scripts/diy-part2.sh                 注入 eBPF/BTF 内核符号 + defconfig 后自检（eBPF 生效的关键）
scripts/find-kernel-config.sh        稳健定位内核 .config（路径 + 内容双重判据）
files/etc/uci-defaults/99-ax6000-custom   首次启动脚本（主机名/时区/NTP 等）
.gitattributes                       强制 LF 换行，防止 Windows 上传后脚本报错
```

---

## 八、变更记录

### 2026-10-14 基于产物逐项体检的修复（`a99b088` 固件实测）

对 Release `ax6000-20261010-a99b088` 做了**不依赖日志**的体检：从固件镜像里解出内核
并提取其**内嵌**的 IKCONFIG，再解开 squashfs 核对全部 2114 个条目。核心能力全部通过
（BTF 段真实存在、MTK 闭源 WiFi、HNAT/WARP、9 个 LuCI 插件齐全），同时查出以下问题并修复：

| # | 问题 | 机理 | 修复 |
| --- | --- | --- | --- |
| 13 | **`files/` 覆盖层路径错误 → `99-ax6000-custom` 从未进入固件** | 流水线写的是 `cp -rf ../builder/files/* .`。`files/*` 只展开出 `files/etc` 一个条目，而 `cp -r <目录> .` 是**把该目录整体复制进 `.`**，结果落到 `./etc/…`；而 OpenWrt 只从 `$(TOPDIR)/files` 读覆盖层（`include/image.mk` 与 `package/Makefile` 两处都是 `$(call prepare_rootfs,$(TARGET_DIR),$(TOPDIR)/files)`）。路径不匹配 → 文件躺在错误位置，**永不进固件**。紧跟的 `chmod … \|\| true` 又把错误吞掉 → **全程静默** | 改为 `mkdir -p files && cp -a ../builder/files/. files/`，并加**逐个文件到位校验**：源树里每个文件都必须在 `files/` 下存在，缺一个就 `::error::` + `exit 1`。已用真实 bash 验证成功/失败两个分支 |
| 14 | **两条内核符号名在 6.12 里不存在** | `CONFIG_NFNETLINK_QUEUE` 与 `CONFIG_NET_SCH_CLSACT` 均无此符号，会被 Kconfig 静默忽略。真实名是 `CONFIG_NETFILTER_NETLINK_QUEUE`；clsact qdisc 内建于 `CONFIG_NET_SCH_INGRESS` | 改为真实符号名；删除不存在的 `NET_SCH_CLSACT` 并加注释说明。**功能未缺失**（`kmod-nfnetlink-queue` 一直在 manifest 里），修的是「虚假安全感」 |
| 15 | **`CONFIG_PACKAGE_ebtables=y` 被静默丢弃** | 25.12 里真实包名是 `ebtables-legacy`（`PROVIDES:=ebtables`），裸 `ebtables` 不存在 | 改为 `CONFIG_PACKAGE_ebtables-legacy=y` |
| 16 | **`CONFIG_PACKAGE_miniupnpd=y` 被静默丢弃** | `miniupnpd` 是**变体包**：真实名 `miniupnpd-iptables` / `miniupnpd-nftables`（后者 `DEFAULT_VARIANT`、`PROVIDES:=miniupnpd`）。实际入固件的是被 `luci-app-upnp` 依赖带入的 `miniupnpd-nftables` | 显式改为 `CONFIG_PACKAGE_miniupnpd-nftables=y`，并删掉「常用包」段里重复的无效裸名 |
| 17 | **`luci-i18n-proto-wireguard-zh-cn` 不存在** | 上游 `protocols/luci-proto-wireguard/` 下只有 `Makefile` / `htdocs` / `root`，**没有 `po/` 目录** → 不生成任何语言包 | 从配置与预检清单中删除（WireGuard 页面就是英文的，属上游现状） |
| 18 | **`luci-theme-bootstrap-mod` 不存在** | luci feed 的 `themes/` 下只有 argon / bootstrap / footstrap / material / openwrt 系列 | 删除该行；实际生效主题是 argon + bootstrap |
| 19 | **预检清单两处误报** | `libbpf1` 是 `ip-full` 的依赖、自动带入，显式列会因「未被用户直接选中」误报未启用；`miniupnpd` 裸名同理 | 清单里 `libbpf1` 改为注释说明；`miniupnpd` → `miniupnpd-nftables`；`luci-i18n-proto-wireguard-zh-cn` 移除 |

**教训**：`make defconfig` 对不存在的包是**静默丢弃**，所以「配置里写了」≠「固件里有」。
本轮 6 个问题里有 4 个是同一类：**包名/符号名/路径与实际不符，且完全无报错**。
判断依据永远是 **manifest（包）+ 内核内嵌 IKCONFIG（内核开关）**，不是配置文件本身。

### 2026-10-09 第三次编译前的修复（缓存顺序 bug 导致第二次编译 3 分钟即失败）

第二次运行（run `37946575159`）在**第 8 步「克隆源码」就挂了**，退出码 128，总共只跑了 3 分钟，
前面 7 步全绿。这不是上游仓库的问题（仓库和 `25.12` 分支都正常），
而是**流水线自己的步骤顺序错**：

| # | 问题 | 机理 | 修复 |
| --- | --- | --- | --- |
| 10 | **`dl/` 缓存恢复排在 `git clone` 之前** | 首次运行结束时存下了 `dl-…-1`（1.1GB）缓存。第二次运行时 `actions/cache` 按 `restore-keys: dl-` 命中并把内容解到 `immortalwrt/dl/` —— 于是 `immortalwrt/` 这个目录被**提前创建出来**。紧接着 `git clone … immortalwrt` 直接报 `fatal: destination path 'immortalwrt' already exists and is not an empty directory`，**exit 128**。诡异之处在于：**首次运行（无缓存）必然成功，第二次（有缓存）必然失败** | 把两个缓存步骤整体挪到克隆**之后**（缓存恢复时源码树已就位，解压只是往里填东西，不会再破坏 clone），克隆前先 `rm -rf immortalwrt` 清场，并加了 5 次重试 |
| 11 | **ccache 缓存路径写错** —— 写成 `~/.ccache` | 上游 `rules.mk` 第 354 行把 `CCACHE_DIR` 固定为 `$(TOPDIR)/.ccache`，即 `immortalwrt/.ccache`；`$HOME/.ccache` 里**始终是空的**。所以「已缓存 ccache」是假象：每次都是 0 字节，编译加速完全没生效 | 缓存路径改为 `immortalwrt/.ccache`，键里带上源码 commit；并加 `CCACHE_MAXSIZE=2G` 限制体积（仓库缓存配额只有 10GB，不限制会挤掉 `dl/`） |
| 12 | **克隆失败没有重试** | Azure runner 到 github.com 偶发抖动时，一次失败就整轮报废 | 克隆改为最多 5 次重试（退避 10/20/30/40s），失败才 `exit 1`；`git clone` 前先清目录，避免残留干扰 |

**教训**：缓存步骤的位置是**有副作用的**。`actions/cache` 的 `path` 只写「某个子目录」时，
它会把父目录一并创建出来，从而破坏后续「往这个父目录里 clone」的步骤。

### 2026-10-09 第二次编译前的修复（基于首次编译的实编产物核验）

首次编译（run `37929636730`，96 分钟，成功）产出固件后，我下载了 Release 里的
`manifest` / `build-info.txt` 逐项核对，发现并修掉以下问题：

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | **内核 `.config` 探测路径少一层** —— 写成 `build_dir/target-*/linux-*/.config`，而内核配置实际在 `$(LINUX_DIR)/.config`（即 `.../linux-<board>_<sub>/linux-<版本>/.config`，见 `include/kernel.mk`） | 路径取空 → eBPF 校验**静默失效**，还打印「未检测到 BTF」的**假告警**。固件里到底有没有 eBPF 完全无法判断 | 新增 `scripts/find-kernel-config.sh`：路径 + 内容双重判据、三级回退；找不到就 **fail**，不再静默放过 |
| 2 | **`kmod-mediatek_hnat` 被误判为「不存在的包」** —— 上一轮只搜了 `netsupport.mk` 和「路径名含 hnat」的文件，而它实际定义在 `package/kernel/linux/modules/**netdevices.mk**`（文件名不含 hnat） | 注释写错成「不存在此包」；好在 `kmod-warp` 和 `kmod-mt_wifi` 都有 `DEPENDS:= +kmod-mediatek_hnat`，功能没丢 | 恢复显式配置行 + 修正注释（实编 manifest 里确实有 `kmod-mediatek_hnat - 6.12.108-r1`） |
| 3 | **`kmod-sched-bpf` / `kmod-xdp-sockets-diag` 被漏掉** —— 旧脚本只查「同名目录」，而 kmod 包是在 `.mk` 里用 `define KernelPackage/xxx` 定义的（定义名不带 `kmod-` 前缀） | 这两个包**没进固件**（manifest 已证实），`tc` 挂 eBPF 的玩法不可用 | 新增 `pkg_exists()` 双路判定；并改为**在 `make defconfig` 之后回读 `.config` 实测**，不靠猜 |
| 4 | **`bpftool` / `libbpf` 包名错误** | `CONFIG_PACKAGE_bpftool=y`、`libbpf=y` 都被 defconfig 静默丢弃 | 修正为真实包名 `bpftool-minimal`（`DEFAULT_VARIANT`）、`libbpf1`（ABI 后缀） |
| 5 | **`DEBUG_INFO_BTF` 的隐藏依赖** —— 它 `depends on !KERNEL_DEBUG_INFO_REDUCED`，而后者的 `default y if ... \|\| !BUILDBOT` 在 GitHub Actions 上成立 | `DEBUG_INFO_REDUCED` 会被默认置 `y`，导致 BTF 被内核 Kconfig **静默丢弃** | `diy-part2.sh` 在两轮 defconfig 之间强制把 `KERNEL_DEBUG_INFO_REDUCED` 置 `n`，并加自检 |
| 6 | **profile 存在性校验只看 `filogic.mk`** | `-mtkuboot` 实际定义在 `filogic-ext.mk`，报错提示会误导 | 两个文件都查 |
| 7 | **Release 说明硬编码「已启用 eBPF/BTF」** | 未经校验就宣称 | 改为动态：由 `kernel-config.txt` 实测结果生成 |
| 8 | **`build-info.txt` 里自身的 sha256 永远是错的** | `sha256sum *` 写在与 `> build-info.txt` 同一个块里，读到的是一半内容 | 校验段改为最后追加，并排除自身 |
| 9 | **关键结论只在日志里，匿名读不到** | 用户必须自己翻几十万行日志 | 关键清单**渲染到 Actions 页面摘要** + 落成 `precheck.txt` / `kernel-config.txt` 随固件发布 |

**这一轮新增的可验证性**：编译完成后，Release 里的 `kernel-config.txt` 是内核实测配置，
`build-info.txt` 里有一行 `结论: ✅/❌ BTF ...`。**只看这两个文件就能确认 eBPF 有没有真编进去。**

---

### 2026-10-14 / 10-15 流水线运维修复（ttyd 编入 + 缓存配额治理）

10-14 两次编译（run 8 `c79d028` 1h28m、run 9 `1b10202` 1h38m）全绿，
Release `ax6000-20261014-468e251` / `ax6000-20261015-468e251`。
run 8 即上面 #13–19 那批修复的实编验证；run 9 追加 ttyd。
本轮把「编译能过但流水线在慢性自伤」的问题一并清掉：

| # | 问题 | 机理 / 证据 | 修复 |
| --- | --- | --- | --- |
| 20 | **`dl/` 缓存 key 带 `hashFiles(config)`，每改一次配置多存一份 1.8GB** | `actions/caches` API 实测：`dl-468e251-fa6960…`(1.80GB) 与 `dl-468e251-eec9ae…`(1.78GB) 并存，加上两份 ccache 共占 **6.6GB / 10GB 配额**。dl/ 里只是源码包压缩包，与 `.config` 毫无关系 | key 改为 `dl-${上游sha}`，只按源码 commit 区分；`restore-keys: dl-` 保持兼容 |
| 21 | **ccache key 带 `run_number`，每次必然新增 0.56GB** | 同上，`ccache-468e251-8` / `-9` 两份并存，永不覆盖 | 改为**固定滚动 key** + `cache/restore` + `cache/save` 两步（单 step 在 miss 时不会保存，必须拆开）；`CCACHE_MAXSIZE` 2G→1G（实测只用 560MB） |
| 22 | **Release tag 会撞车，撞了就覆盖旧版本** | tag = `ax6000-${日期}-${上游短sha}`，同一天 + 同源码编两次即同 tag，`action-gh-release` 会**更新**已存在 Release。历史已发生：第三次与第五次都产出 `ax6000-20261010-ae65e1d`，后一次盖掉前一次 | tag 追加 `-r${GITHUB_RUN_NUMBER}`，单调递增 |
| 23 | **没有 concurrency 控制** | 连推两次会并行跑两个 build：同抢 tag、同读写 ccache、同占 runner | 加 `concurrency: {group: ax6000-build, cancel-in-progress: true}` |
| 24 | **Release 说明硬编码「预装 smartdns」，而 smartdns 第 6 版已按要求移除** | 每次发版都在 Release 页面写一句假话 | 「预装」改为从 `.manifest` **实测生成**，并明确写出 sing-box/momo/homeproxy/smartdns 的按需不预装策略 |
| 25 | **预检清单是手写的 30 多个包名** | 加插件要同步两处，忘了就漂移（ttyd 就是手工补进去的） | 改为从 `.config` 自动提取 `CONFIG_PACKAGE_*=y`，天然不漂移 |
| 26 | **`diy-part1.sh` 还在查已移除的 smartdns** | 长期输出误导性 `[WARN]` | 从检查清单移除，并注释说明原因（含 libbpf1 为何不查） |
| 27 | **缺「manifest 实测」段，依赖 precheck 推断** | precheck 只反映「配置里写了什么」，且对依赖自动带入的包会误报（`libbpf1` ← `ip-full` 被误报过一次） | `build-info.txt` 新增 **manifest 实测**段：核心能力逐项 `[y]/[ ]` + 应排除项反向核对 + LuCI 图形插件全清单。manifest 才是「固件里真有什么」的唯一权威判据 |
| 28 | **`tc-tiny` 装不了 eBPF 程序** | OpenWrt 把 `tc` 拆成 tiny/full 两个互斥变体，**BPF 对象加载只在 `tc-full`**（[拆分提交](https://git.openwrt.org/openwrt/staging/pepe2k/commit/?id=72885e9608d9c0fa06abce6bdb6dd054c2116eb7)）。固件预装了 `bpftool-minimal` + `kmod-sched-bpf` + `XDP_SOCKETS_DIAG`，却少这个入口 | 改 `CONFIG_PACKAGE_tc-full=y`。注：sing-box/mihomo 自带 loader 不依赖 tc，非硬需求 |
| 29 | **根目录 `AX6000-build-guide.md` / `build-ax6000.yml` 是废弃草稿** | 含「2GB eMMC」（实际 128MB SPI-NAND）、`./scripts/download`（该脚本不存在）、推荐 stock 布局等错误 | 顶部加醒目作废声明，逐条列已证伪内容 |

**本轮新增的可验证性**：`build-info.txt` 的「manifest 实测」段让「某插件到底进没进固件」
不再需要翻日志或解开 squashfs —— 编译完成即知。

**遗留（未改，需用户决策）**：
- `files/etc/uci-defaults/99-ax6000-custom` 目前只设主机名/时区/NTP，
  **未预置 WiFi SSID/密码，也未强制首次改密码** —— 2026-10-17 已与用户确认：
  **不预置 WiFi**，保持「开箱空密码 + 无 WiFi」，由用户首次进 LuCI 手动配置。

### 2026-10-17 actions 全面升级到 v6 + runner 迁移到 24.04

| # | 问题 | 机理 / 证据 | 修复 |
| --- | --- | --- | --- |
| 30 | **`actions/*@v4` 已被强制跑在 Node 20→24 兼容层** | 每次 run 都刷一条 warning：`Node.js 20 is deprecated ... actions/cache@v4, actions/checkout@v4, actions/upload-artifact@v4, softprops/action-gh-release@v2` | 全部升到 **v6**（checkout / cache / cache/restore / cache/save / upload-artifact）。选 v6 而非 v5：两者同为 Node 24 运行时，但 v6 是主线且 `cache-mode` 语义文档最明确 |
| 31 | **v5/v6 起 `cache-mode` 默认值取决于触发类型** | [GitHub Changelog 2026-09-10](https://github.blog/changelog/2026-09-10-control-github-actions-cache-access-with-cache-mode/)：不显式指定时，trusted 事件默认 `write`、low-trust 默认 `read`。依赖隐式默认不可靠 —— 哪天把触发方式从 `push` 改成 `pull_request`，缓存就会**静默不再保存** | 三个缓存 step 全部**显式写 `cache-mode`**（dl 和 save 用 `write`，restore 用 `read`） |
| 32 | **`jlumbroso/free-disk-space@main` 用浮动 ref，且该 action 已废弃** | 2026-08-30 起无人维护（安全评分 F），README 示例里甚至已出现 `@v2` 而我们用 `@main`；它 hardcode 的「预装大件」路径随 runner 镜像更新会漏删 | **改为内联 shell 清理**：显式删 `/usr/share/dotnet`(~6GB) `/usr/local/lib/android`(~8GB) `/opt/ghc`(~2GB) `/usr/local/share/boost` / `/usr/share/swift` `/opt/hostedtoolcache/CodeQL` + apt 缓存与 journal。不依赖第三方、行为可控可复现 |
| 33 | **`runs-on: ubuntu-22.04` 已停止积极支持** | [runner-images#14254](https://github.com/actions/runner-images/issues/14254)：2026-09-17 起 deprecated，deprecation 期间有 brownout（24 小时级偶发无 runner），2027-04-17 才移除 | 迁到 **`ubuntu-24.04`**。同时避开 `ubuntu-latest` —— 它将在 2026-10-19~11-19 跳到 Ubuntu 26.04，那会是一次不受控的工具链突变 |
| 34 | **换 runner 后 `libgmp3-dev` 成了 dummy 包** | 24.04(noble) 里 `libgmp3-dev` 只是「pulls in libgmp-dev」的兼容包 | 显式改写 `libgmp-dev`。其余依赖包已在 noble 逐一核实存在 |

**本轮风险与验证**：这是本项目**第一次换 runner 镜像**（22.04→24.04），
工具链版本会变（gcc/clang/python3 小版本），存在编译失败的可能。
若失败，最快的回退方式是把 `runs-on` 改回 `ubuntu-22.04`（保留 v6 actions，
v6 在 22.04 上同样能跑，只是 22.04 本身有 brownout 风险）。

