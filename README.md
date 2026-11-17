# 编译指南

本仓库用于按设备配置自动拉取 OpenWrt / ImmortalWrt / LiBwrt 源码、应用自定义补丁与软件包配置，并输出固件到 `firmware/` 目录。

## 1. 环境准备

推荐使用 Ubuntu LTS 或其他主流 Linux 发行版。OpenWrt 编译对磁盘空间、内存和文件系统大小写敏感性有要求，建议预留充足磁盘空间并在原生 Linux 文件系统中编译。

## 2. 安装编译依赖

直接在宿主机编译时安装以下依赖：

```bash
sudo apt -y update
sudo apt -y full-upgrade
sudo apt install -y dos2unix libfuse-dev
sudo bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)'
```

容器构建只需要宿主机已安装并可正常运行的 Docker；上述编译依赖由容器镜像安装，不需要安装到宿主机。

## 3. 获取源码

```bash
git clone -b main-ser8-build https://github.com/cloverzrg/wrt_release.git
cd wrt_release
```

## 4. 编译用法

### 交互式选择

直接运行脚本会列出当前 `wrt_core/compilecfg/*.ini` 与 `wrt_core/deconfig/*.config` 同时存在的设备配置，并提示选择构建模式：

```bash
./build.sh
```

### 直接指定设备

```bash
./build.sh <设备配置名> [debug|container|container_debug|config_preview]
```

构建模式说明：

| 模式 | 命令示例 | 说明 |
| --- | --- | --- |
| 默认 | `./build.sh x64_immwrt` | 拉取源码、应用配置、下载依赖并完整编译固件。 |
| `debug` | `./build.sh x64_immwrt debug` | 执行到 `make defconfig` 后停止，用于检查配置，不产出固件。 |
| `container` | `./build.sh x64_immwrt container` | 使用 Docker 容器执行完整构建，减少本机环境差异。 |
| `container_debug` | `./build.sh x64_immwrt container_debug` | 在 Docker 容器中执行 debug 流程并进入交互 shell。 |
| `config_preview` | `./build.sh x64_immwrt config_preview` | 只预览配置片段组合，不拉取源码、不写构建目录。 |

容器镜像默认使用清华大学 Debian 镜像加速主软件源，将 Debian Bullseye 安全快照切换为南京大学的 Debian 安全归档镜像，保留其他第三方源。安全归档使用 Debian 的签名和包校验，但其索引不一定与原快照完全相同。镜像更新或安装失败时会尝试原始源。

可指定其他 Debian 镜像，或设为空值使用对应的原始源：

```bash
WRT_DEBIAN_MIRROR=https://mirrors.ustc.edu.cn/debian ./build.sh jdcloud_ax6000_immwrt container
WRT_DEBIAN_MIRROR= WRT_DEBIAN_SECURITY_MIRROR= ./build.sh jdcloud_ax6000_immwrt container
```

这只影响容器镜像内的 Debian 软件源，不改变宿主机软件源，也不加速 Docker 镜像拉取或 GitHub 下载。

可通过环境变量临时追加或移除配置片段：

```bash
ADD_CONFIG_FRAGMENTS=docker_deps ./build.sh gemtek_w1701k_immwrt config_preview
REMOVE_CONFIG_FRAGMENTS=ebpf_proxy_deps ./build.sh x64_immwrt config_preview
```

GitHub Actions 的手动构建也提供 `add_fragments` 与 `remove_fragments` 输入项，语义与上述环境变量一致。

### GitHub Actions

`Build WRT` 和 `Release WRT` 都可选择百里 AX6000（`jdcloud_ax6000_immwrt`）或阿里云 AP8220（`aliyun_ap8220_libwrt`）。构建流程上传 Artifacts。发布流程将固件和同批构建的内核模块归档上传到 GitHub Releases。

### APK 和共享应用

共享配置默认使用 APK。固件预装 Argon、Diskman 及其简体中文包、网络唤醒和 UPnP。固件包含 Diskman 所需的 exFAT、MS-DOS、NTFS3 和 CP932 / CP936 / CP950 内核模块。设备配置可将 Diskman 和语言包设为 `m`，生成独立安装包。

固件保留 DNS、IPv6、防火墙、TUN 和 OpenVPN DCO 等依赖。AP8220 的 LiBwrt 配置与百里一样预装 Docker 和 Dockerman。其他设备可通过设备配置选择 Docker 和 `docker_deps`。

百里固定使用 ImmortalWrt `v25.12.2`。AP8220 跟随 LibWrt `25.12-nss` 分支，目标为 `qualcommax/ipq807x`。AP8220 的内核和软件包随该分支更新。软件包管理器保留固件内置的 `base-files` 版本约束。

### 安装 Honk

支持 Linux 6.12 及以上的设备默认启用 `ebpf_proxy_deps`。固件包含 BTF、TC BPF、cgroup BPF、NFQUEUE、GeoIP 和 GeoSite。构建流程按目标架构配置 daeuniverse 25.12 应用源及公钥。内核模块随固件构建，APK 源只安装应用。

刷入对应型号的 APK 固件后，执行以下命令安装 Honk。Honk 自带 doona 界面。

```sh
apk update
apk add honk@daeuniverse
```

需要 LuCI 管理页面时，安装 `luci-app-honk@daeuniverse`。Honk 的配置与启用步骤见[上游安装指南](https://github.com/daeuniverse/openwrt-packages#openwrt-integration)。

### AP8220 的 NSS

固件包含 NSS 驱动、Wi-Fi 卸载及 ECM 连接加速。首次启用 Honk 前，在 AP8220 上停用 ECM 和防火墙流量卸载，让 Honk 接管流量。

```sh
/etc/init.d/qca-nss-ecm disable
/etc/init.d/qca-nss-ecm stop
uci set 'firewall.@defaults[0].flow_offloading=0'
uci set 'firewall.@defaults[0].flow_offloading_hw=0'
uci commit firewall
/etc/init.d/firewall reload
```

停用 Honk 后，可执行 `/etc/init.d/qca-nss-ecm enable` 和 `/etc/init.d/qca-nss-ecm start` 恢复 ECM。

编译完成后，脚本会从 `<BUILD_DIR>/bin/targets/` 收集固件文件到仓库根目录的 `firmware/`。每次完整构建前会清理旧的目标固件文件，`firmware/Packages.manifest` 会被移除。

## 5. 支持设备

设备配置名来自 `wrt_core/compilecfg/` 和 `wrt_core/deconfig/` 中同名文件。当前支持：

| 厂商 / 平台 | 设备 | 配置名 |
| --- | --- | --- |
| 京东云 | 雅典娜(02)、亚瑟(01)、太乙(07)、AX5(JDC版) | `jdcloud_ipq60xx_immwrt` |
| 京东云 | 雅典娜(02)、亚瑟(01)、太乙(07)、AX5(JDC版) - LiBwrt | `jdcloud_ipq60xx_libwrt` |
| 京东云 | 百里 / AX6000 | `jdcloud_ax6000_immwrt` |
| 阿里云 | AP8220 | `aliyun_ap8220_immwrt` |
| 阿里云 | AP8220 - LiBwrt | `aliyun_ap8220_libwrt` |
| Linksys | MX4200v1、MX4200v2、MX4300 | `linksys_mx4x00_libwrt` |
| Link | NN6000v2 | `link_nn6000v2_immwrt` |
| 奇虎 | 360v6 | `qihoo_360v6_immwrt` |
| 红米 | AX5 | `redmi_ax5_immwrt` |
| 红米 | AX6 | `redmi_ax6_immwrt` |
| 红米 | AX6 - LiBwrt | `redmi_ax6_libwrt` |
| CMCC（中国移动） | RAX3000M | `cmcc_rax3000m_immwrt` |
| Cudy | TR3000 v1 / 256 MB v1（ImmortalWrt `v25.12.2`，mt76） | `cudy_tr3000_immwrt` |
| 斐讯 | N1 | `n1_immwrt` |
| 兆能 | M2 | `zn_m2_immwrt` |
| 兆能 | M2 - LiBwrt | `zn_m2_libwrt` |
| Gemtek | W1701K | `gemtek_w1701k_immwrt` |
| SuperGateway | S20M | `supergateway_s20m_immwrt` |
| Nokia | XG-040G-MD UBI | `nokia_040g_immwrt` |
| x86 | X64 | `x64_immwrt` |

示例：

```bash
./build.sh jdcloud_ipq60xx_immwrt
./build.sh aliyun_ap8220_libwrt
./build.sh redmi_ax6_libwrt container
```

## 6. 配置来源

每个设备由两类文件共同定义：

- `wrt_core/compilecfg/<设备配置名>.ini`：定义源码仓库、分支、构建目录、默认配置片段、可选提交哈希和容器 SDK 镜像。
- `wrt_core/deconfig/<设备配置名>.config`：定义 OpenWrt 目标平台、设备和软件包配置。

不同设备会使用不同上游源码，例如 `VIKINGYFY/immortalwrt`、`immortalwrt/immortalwrt`、`LiBwrt/openwrt-6.x`、`padavanonly/immortalwrt-mt798x` 或本仓库维护的特定分支。`BUILD_TARGET_SDK` 未配置时，容器构建默认使用 `immortalwrt/sdk:openwrt-25.12`。

构建按以下顺序组合配置，后面的设置优先。

1. 共享的 `wrt_core/deconfig/compile_base.config`
2. 设备专用 `.config`
3. 共享的 `ebpf_proxy_deps`、设备 `CONFIG_FRAGMENTS` 和额外配置片段

高通 IPQ60xx / IPQ807x 通过 `nss` 片段启用硬件加速。S20M 的 24.10 源码使用 opkg 和 Linux 6.6。S20M 在设备配置中覆盖包管理器，并以 `DEFAULT_EBPF_PROXY_DEPS=0` 跳过 Honk 依赖。

`ADD_CONFIG_FRAGMENTS` 追加片段，`REMOVE_CONFIG_FRAGMENTS` 移除片段。可用 `ADD_CONFIG_FRAGMENTS=proxy` 选择 Passwall。

## 7. 三方插件

三方插件主要通过 feeds 机制加入，其中 small-package 源自：

```text
https://github.com/kenzok8/small-package.git
```

相关增删和同步逻辑位于 `wrt_core/update.sh` 编排的 `wrt_core/modules/` 静态阶段。构建脚本按合成后的配置准备所选插件的源码。

## 8. 项目结构说明

- `build.sh`：主编译入口，负责设备选择、模式选择、配置组合、容器构建和固件收集。
- `firmware/`：完整构建后的固件输出目录，由脚本自动创建和刷新。
- `wrt_core/build_container.sh`：容器内构建入口。
- `wrt_core/update.sh`：源码更新、feeds 调整、软件包同步和补丁应用主流程。
- `wrt_core/pre_clone_action.sh`：GitHub Actions 预克隆辅助脚本。
- `wrt_core/compilecfg/`：设备构建元信息 `.ini`。
- `wrt_core/deconfig/`：设备和共享默认配置 `.config`。
- `wrt_core/deconfig/fragments/`：可组合配置片段。
- `wrt_core/packages/`：本仓库维护的本地包定义，当前仅包含内核 BTF 的空依赖标记包。
- `wrt_core/modules/`：模块化脚本，包括仓库准备、网络重试、feeds/custom_feed、源码修正、LuCI 修正、服务修正、验证、Docker、CUPS 等静态职责模块。
- `wrt_core/patches/`：补丁、默认设置、Wi-Fi 初始化、NSS 诊断、PBR 规则和其他构建时注入文件。

## 9. 构建脚本回归检查

使用 Python 3、Git、Make 和 Bash 4.3 以上版本运行离线检查。

```bash
python3 -m unittest discover -s tests -v
```

macOS 可用 `WRT_TEST_BASH=/path/to/bash` 指定较新的 Bash。离线测试覆盖共享配置、AP8220 NSS、Honk 内核和软件源检查，以及源码浅克隆。用 `./build.sh aliyun_ap8220_libwrt debug` 检查实际源码的 `make defconfig` 结果。
