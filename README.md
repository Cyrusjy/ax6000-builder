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
| eBPF | 内核开启 `BPF_SYSCALL / BPF_JIT / BPF_EVENTS / CGROUP_BPF / NET_CLS_BPF / NET_ACT_BPF / XDP_SOCKETS / DEBUG_INFO_BTF`，带 `tc-bpf`、`bpftool`（若 feeds 里有） |
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
> 200–330 分钟，私有仓一个月只能编 6 次左右。公开仓库 Actions 时长不限。

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

点 **Run workflow**，然后去喝杯茶——**首次全量编译约 3–5 小时**（要编交叉工具链 +
内核 + MTK 闭源驱动 + 全部包）。编译完成会：

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
| `sha256sums` / `profiles.json` / `build-info.txt` | 校验值和本次构建信息（内核 eBPF 状态也在里面） |

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

> `make defconfig` 对不存在的包是**静默丢弃**。所以 workflow 里专门有一步
> `打印最终关键配置`，会把 `[y]` / `[ ]` 清单打出来——编译前先看那一段。

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
bash /path/to/ax6000-builder/scripts/diy-part2.sh
make defconfig

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
| `make defconfig` 后某插件消失 | 包名不存在或拼错，看 `包预检` 日志 |
| smartdns 编译报 openssl 相关错误 | 25.12 用的是 OpenSSL 3.x，feeds 里的 Makefile 偶尔对不上。可单独重编看详细报错：`make package/feeds/packages/smartdns/compile V=s`，必要时给该包加 `+libopenssl-legacy` 依赖 |
| 无线起不来 | 本固件是 MTK 闭源驱动，配置界面是 **mtwifi-cfg** 不是原生无线页；另外别同时选 mac80211/mt76 相关的 LuCI 应用 |
| eBPF 程序跑不起来 | 看 Release 里的 `build-info.txt`，确认 `CONFIG_DEBUG_INFO_BTF=y`；跑 eBPF 前先关掉 Flow Offloading |
| 超过 6 小时被 GitHub 掐断 | `timeout-minutes: 355` 已设置；若仍超时，把 `profile` 固定成单设备、别加太多插件 |

## 七、几个必须知道的坑

1. **布局不匹配 = 变砖**。`stock` / `mtkuboot` / `ubootmod` 三者互不兼容，
   刷之前先在 U-Boot 页面确认布局，再选同名镜像。
2. **不要在开启 HNAT 的同时用主线 flow offloading**，两者抢硬件加速。
   本配置里 `CONFIG_PACKAGE_TURBOACC_INCLUDE_FLOW_OFFLOADING` 已关。
3. **私有仓库 Actions 额度**：一次编译约 200–330 分钟，私有仓每月 2000 分钟。
4. **首次编译必定慢**，第二次有缓存会明显快；别第一天就频繁重跑。
5. 编译成功 ≠ 一定刷得进去。刷之前先把 `initramfs-kernel.bin` 和原厂分区备份留在手上。

---

## 附：目录说明

```
.github/workflows/build-ax6000.yml   云编译流水线（含磁盘清理、缓存、校验、发 Release）
config/ax6000-mtkuboot.config        精简后的 .config（单设备 + eBPF + smartdns + eqos-mtk）
scripts/diy-part1.sh                 feeds 后处理 + 包预检（缺包提前报警）
scripts/diy-part2.sh                 注入 eBPF/BTF 内核符号（这一步是 eBPF 生效的关键）
files/etc/uci-defaults/99-ax6000-custom   首次启动脚本（主机名/时区/NTP 等）
.gitattributes                       强制 LF 换行，防止 Windows 上传后脚本报错
```
