#!/usr/bin/env bash
# 构建树一致性检查。

ebpf_proxy_kernel_patchver() {
    local build_dir="$1"
    local target_mk="$build_dir/target/linux/mediatek/Makefile"
    local subtarget_mk="$build_dir/target/linux/mediatek/filogic/target.mk"
    local files=("$target_mk")

    [[ -f "$target_mk" ]] || return 1
    [[ ! -f "$subtarget_mk" ]] || files+=("$subtarget_mk")

    awk '
        /^[[:space:]]*KERNEL_PATCHVER[[:space:]]*:?=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]#].*$/, "")
            version=$0
        }
        END { print version }
    ' "${files[@]}"
}

verify_ebpf_proxy_deps_config() {
    local build_dir="$1"
    local config_path="$build_dir/.config"
    local required_settings=(
        CONFIG_TARGET_mediatek_filogic CONFIG_aarch64 CONFIG_IPV6
        CONFIG_KERNEL_CGROUPS CONFIG_KERNEL_CGROUP_BPF CONFIG_KERNEL_NET_NS
        CONFIG_KERNEL_DEBUG_INFO CONFIG_KERNEL_DEBUG_INFO_BTF
        CONFIG_KERNEL_KPROBES CONFIG_KERNEL_KPROBE_EVENTS CONFIG_KERNEL_BPF_EVENTS
        CONFIG_KERNEL_BPF_STREAM_PARSER CONFIG_KERNEL_FTRACE
        CONFIG_KERNEL_FUNCTION_TRACER CONFIG_KERNEL_DYNAMIC_FTRACE
        CONFIG_PACKAGE_kmod-sched-core CONFIG_PACKAGE_kmod-sched-bpf
        CONFIG_PACKAGE_kmod-veth CONFIG_PACKAGE_kmod-nft-core
        CONFIG_PACKAGE_kmod-nft-queue CONFIG_PACKAGE_kmod-nfnetlink-queue
        CONFIG_PACKAGE_kmod-nf-conntrack CONFIG_PACKAGE_ca-bundle
        CONFIG_PACKAGE_libstdcpp CONFIG_PACKAGE_v2ray-geoip CONFIG_PACKAGE_v2ray-geosite
        CONFIG_PACKAGE_vmlinux-btf-builtin CONFIG_PACKAGE_jshn
        CONFIG_PACKAGE_flock CONFIG_PACKAGE_coreutils-timeout
    )
    local setting
    local patchver

    for setting in "${required_settings[@]}"; do
        if ! grep -qx "${setting}=y" "$config_path"; then
            echo "错误：后续安装 dae/honk 所需 ${setting}=y 在 make defconfig 后缺失。" >&2
            return 1
        fi
    done

    if grep -qx 'CONFIG_KERNEL_DEBUG_INFO_REDUCED=y' "$config_path"; then
        echo "错误：dae/honk 的 BTF 支持不能与缩减调试信息同时启用。" >&2
        return 1
    fi

    # The current ARM64 Filogic profile is verified against its normal kernel.
    # Do not silently validate a different testing kernel's version instead.
    if grep -qx 'CONFIG_TESTING_KERNEL=y' "$config_path"; then
        echo "错误：dae/honk 配置尚未验证 testing kernel，请使用默认内核。" >&2
        return 1
    fi

    patchver=$(ebpf_proxy_kernel_patchver "$build_dir") || return 1
    if [[ ! $patchver =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        echo "错误：无法确定 dae/honk 目标内核版本：${patchver}。" >&2
        return 1
    fi
    if (( BASH_REMATCH[1] < 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] < 12) )); then
        echo "错误：honk 要求 Linux >= 6.12，当前目标为 ${patchver}。" >&2
        return 1
    fi

    verify_baili_apps_config "$build_dir" "$2" "eBPF 代理后续安装依赖" || return 1
    if ! grep -qxF 'CONFIG_USE_APK=y' "$config_path"; then
        echo "错误：daeuniverse 官方软件源要求 APK 包管理器。" >&2
        return 1
    fi
    if ! grep -qxF 'CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"' "$config_path"; then
        echo "错误：当前架构与已配置的 daeuniverse 应用源不匹配。" >&2
        return 1
    fi
    echo "dae/honk 后续安装依赖检查通过，目标内核 ${patchver}。"
}

verify_ebpf_proxy_kernel() {
    local build_dir="$1"
    local patchver
    local suffix
    local config_path
    local setting
    local builtin_settings=(
        BPF BPF_SYSCALL BPF_JIT CGROUPS CGROUP_BPF NET_NS IPV6
        KPROBES KPROBE_EVENTS BPF_EVENTS BPF_STREAM_PARSER DEBUG_INFO_BTF
        NET_SCHED NET_CLS_ACT NET_XGRESS
        FTRACE FUNCTION_TRACER DYNAMIC_FTRACE
    )
    local module_settings=(
        NET_SCH_INGRESS NET_CLS_BPF NF_TABLES NF_TABLES_INET NFT_CT NFT_QUEUE
        NETFILTER_NETLINK_QUEUE
    )

    patchver=$(ebpf_proxy_kernel_patchver "$build_dir") || return 1
    suffix=$(awk -F= -v key="LINUX_VERSION-$patchver" '
        { name=$1; gsub(/[[:space:]]/, "", name) }
        name == key { value=$2; gsub(/[[:space:]]/, "", value); print value }
    ' "$build_dir/target/linux/generic/kernel-$patchver") || return 1
    [[ -n "$suffix" ]] || return 1

    config_path=$(find "$build_dir/build_dir" -type f \
        -path "*/linux-mediatek_filogic/linux-$patchver$suffix/.config" -print -quit)
    if [[ ! -f "$config_path" ]]; then
        echo "错误：未找到 dae/honk 的实际内核配置 linux-${patchver}${suffix}。" >&2
        return 1
    fi

    for setting in "${builtin_settings[@]}"; do
        if ! grep -qx "CONFIG_${setting}=y" "$config_path"; then
            echo "错误：实际内核缺少 dae/honk 所需 CONFIG_${setting}=y。" >&2
            return 1
        fi
    done
    for setting in "${module_settings[@]}"; do
        if ! grep -qxE "CONFIG_${setting}=(y|m)" "$config_path"; then
            echo "错误：实际内核缺少 dae/honk 所需 CONFIG_${setting}。" >&2
            return 1
        fi
    done

    echo "dae/honk 实际内核配置检查通过。"
}

verify_baili_apps_config() {
    local config_path="$1/.config"
    local preset_path="$2"
    local description=${3:-百里预装与后续安装依赖}
    local line
    local setting

    if [[ ! -r "$config_path" || ! -r "$preset_path" ]]; then
        echo "错误：无法读取${description}清单或构建配置。" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            CONFIG_*=y)
                if ! grep -qxF "$line" "$config_path"; then
                    echo "错误：${description}配置在 make defconfig 后缺失：${line}。" >&2
                    return 1
                fi
                ;;
            '# CONFIG_PACKAGE_'*' is not set'|'# CONFIG_FEED_'*' is not set')
                setting=${line#\# }
                setting=${setting% is not set}
                if grep -qxE "${setting}=(y|m)" "$config_path"; then
                    echo "错误：${description}中禁止的配置仍被选中：${setting}。" >&2
                    return 1
                fi
                ;;
        esac
    done < "$preset_path"

    echo "${description}检查通过。"
}

verify_custom_feed_installed_paths() {
    local custom_feed_name
    local custom_feed_package_dir
    # install_feeds 后必须存在的 custom_feed 包路径。
    local required_package_dirs=(
        luci-app-adguardhome luci-app-mosdns v2ray-geodata luci-app-easytier
        luci-app-passwall nikki luci-app-nikki mihomo-meta luci-app-emmc-health
    )
    local missing_package_dirs=()

    if [[ ${ENABLE_BAILI_APPS:-0} == 1 ]]; then
        required_package_dirs=(
            xray-core chinadns-ng dns2socks geoview ipt2socks tcping v2ray-geodata
            luci-app-passwall
        )
    fi

    custom_feed_name=$(get_custom_feed_name)
    custom_feed_package_dir=$(get_custom_feed_package_dir)

    collect_missing_directories "$custom_feed_package_dir" required_package_dirs missing_package_dirs

    if [ ${#missing_package_dirs[@]} -ne 0 ]; then
        printf '错误：%s 安装后缺少以下仓库依赖路径：\n' "$custom_feed_name" >&2
        printf '  - %s\n' "${missing_package_dirs[@]}" >&2
        return 1
    fi
}


verify_baili_luci_sources() {
    [[ ${ENABLE_BAILI_APPS:-0} == 1 ]] || return 0

    local build_dir="$1"
    local luci_dir="$build_dir/feeds/luci"
    local argon_mk="$luci_dir/themes/luci-theme-argon/Makefile"
    local dockerman_dir="$luci_dir/applications/luci-app-dockerman"
    local dockerd_init="$build_dir/feeds/packages/utils/dockerd/files/dockerd.init"

    if ! grep -qxF 'PKG_VERSION:=2.4.7' "$argon_mk" \
        || ! grep -qxF 'PKG_RELEASE:=20260824' "$argon_mk"; then
        echo "错误：百里 Argon 必须使用固定 LuCI feed 的 2.4.7-r20260824。" >&2
        return 1
    fi
    if ! grep -Fq "new form.Map('dockerd'," "$dockerman_dir/htdocs/luci-static/resources/view/dockerman/configuration.js" \
        || ! grep -Fq "ctx.get_first('dockerd', 'globals', 'hosts')" "$dockerman_dir/ucode/docker_socket.uc" \
        || ! grep -Fq "ctx.get('dockerd', 'globals', 'api_version')" "$dockerman_dir/root/usr/share/rpcd/ucode/docker_rpc.uc" \
        || ! grep -Fq "config_load 'dockerd'" "$dockerd_init"; then
        echo "错误：Dockerman 页面、RPC 后端和 dockerd 必须共用 /etc/config/dockerd。" >&2
        return 1
    fi
    echo "百里 Argon、Dockerman 配置接口检查通过。"
}


verify_baili_apk_repositories() {
    local build_dir="$1"
    local repositories
    local found=0

    while IFS= read -r repositories; do
        found=1
        if grep -q '/custom_feed/' "$repositories"; then
            echo "错误：固件 APK 软件源仍包含不可发布的本地 custom_feed：$repositories" >&2
            return 1
        fi
    done < <(find "$build_dir/build_dir" -type f \
        -path '*/root-mediatek/etc/apk/repositories.d/distfeeds.list' -print)

    if [[ "$found" != 1 ]]; then
        echo "错误：未找到百里固件根文件系统的 APK 软件源清单。" >&2
        return 1
    fi
    echo "百里固件 APK 软件源检查通过。"
}
