#!/usr/bin/env bash
# 构建树一致性检查。

read_kconfig_value() {
    awk -v name="$2" '
        index($0, name "=") == 1 { value=substr($0, length(name) + 2) }
        $0 == "# " name " is not set" { value="n" }
        END {
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            print value
        }
    ' "$1"
}

ebpf_proxy_kernel_patchver() {
    local build_dir="$1"
    local board subtarget
    board=$(read_kconfig_value "$build_dir/.config" CONFIG_TARGET_BOARD)
    subtarget=$(read_kconfig_value "$build_dir/.config" CONFIG_TARGET_SUBTARGET)
    local target_mk="$build_dir/target/linux/$board/Makefile"
    local subtarget_mk="$build_dir/target/linux/$board/$subtarget/target.mk"
    local files=("$target_mk")

    if [[ -z "$board" || ! -f "$target_mk" ]]; then
        echo "错误：无法读取目标平台 $board 的内核版本。" >&2
        return 1
    fi
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
    local patchver arch

    verify_config_fragment "$build_dir" "$2" "Honk 运行依赖" || return 1

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

    arch=$(read_kconfig_value "$config_path" CONFIG_TARGET_ARCH_PACKAGES)
    case "$arch" in
        aarch64_cortex-a53|aarch64_generic|x86_64) ;;
        *) echo "错误：daeuniverse 25.12 应用源未配置架构 $arch。" >&2; return 1 ;;
    esac
    echo "dae/honk 后续安装依赖检查通过，目标内核 ${patchver}。"
}

verify_ebpf_proxy_kernel() {
    local build_dir="$1"
    local patchver board subtarget
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

    board=$(read_kconfig_value "$build_dir/.config" CONFIG_TARGET_BOARD)
    subtarget=$(read_kconfig_value "$build_dir/.config" CONFIG_TARGET_SUBTARGET)
    config_path=$(find "$build_dir/build_dir" -type f \
        -path "*/linux-${board}${subtarget:+_${subtarget}}/linux-$patchver$suffix/.config" -print -quit)
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

verify_config_fragment() {
    local config_path="$1/.config"
    local preset_path="$2"
    local description="$3"
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
            '# CONFIG_'*' is not set')
                setting=${line#\# }
                setting=${setting% is not set}
                if grep -qxF -e "${setting}=y" -e "${setting}=m" "$config_path"; then
                    echo "错误：${description}中禁止的配置仍被选中：${setting}。" >&2
                    return 1
                fi
                ;;
        esac
    done < "$preset_path"

    echo "${description}检查通过。"
}

verify_shared_config() {
    local config_path="$1/.config"
    local input_config="$2"
    local required=(
        CONFIG_PACKAGE_luci-app-package-manager CONFIG_PACKAGE_dnsmasq-full
        CONFIG_PACKAGE_kmod-fs-exfat CONFIG_PACKAGE_kmod-fs-msdos CONFIG_PACKAGE_kmod-fs-ntfs3
        CONFIG_PACKAGE_kmod-nls-cp932 CONFIG_PACKAGE_kmod-nls-cp936 CONFIG_PACKAGE_kmod-nls-cp950
    )
    local setting expected actual
    if [[ $(read_kconfig_value "$input_config" CONFIG_USE_APK) == y ]]; then
        required+=(CONFIG_USE_APK CONFIG_PACKAGE_apk-openssl)
    else
        required+=(CONFIG_PACKAGE_opkg)
    fi
    for setting in "${required[@]}"; do
        if ! grep -qxF "${setting}=y" "$config_path"; then
            echo "错误：共享配置在 make defconfig 后缺失：${setting}=y。" >&2
            return 1
        fi
    done
    for setting in CONFIG_PACKAGE_luci-app-diskman CONFIG_PACKAGE_luci-i18n-diskman-zh-cn; do
        expected=$(read_kconfig_value "$input_config" "$setting")
        actual=$(read_kconfig_value "$config_path" "$setting")
        if [[ $expected =~ ^[ym]$ && $actual != "$expected" ]]; then
            echo "错误：Diskman 配置在 make defconfig 后缺失：$setting=$expected。" >&2
            return 1
        fi
    done
}

verify_nss_config() {
    local config_path="$1/.config"
    local setting
    for setting in CONFIG_ATH11K_NSS_SUPPORT CONFIG_PACKAGE_kmod-qca-nss-dp \
                   CONFIG_PACKAGE_kmod-qca-nss-drv CONFIG_PACKAGE_kmod-qca-nss-ecm; do
        if ! grep -qxF "${setting}=y" "$config_path"; then
            echo "错误：NSS 配置在 make defconfig 后缺失：${setting}=y。" >&2
            return 1
        fi
    done
}

verify_dockerman_sources() {
    local build_dir="$1"
    local selected
    selected=$(read_kconfig_value "$build_dir/.config" CONFIG_PACKAGE_luci-app-dockerman)
    [[ $selected == y || $selected == m ]] || return 0

    local luci_dir="$build_dir/feeds/luci"
    local dockerman_dir="$luci_dir/applications/luci-app-dockerman"
    local dockerd_init="$build_dir/feeds/packages/utils/dockerd/files/dockerd.init"

    if ! grep -Fq "new form.Map('dockerd'," "$dockerman_dir/htdocs/luci-static/resources/view/dockerman/configuration.js" \
        || ! grep -Fq "ctx.get_first('dockerd', 'globals', 'hosts')" "$dockerman_dir/ucode/docker_socket.uc" \
        || ! grep -Fq "ctx.get('dockerd', 'globals', 'api_version')" "$dockerman_dir/root/usr/share/rpcd/ucode/docker_rpc.uc" \
        || ! grep -Fq "config_load 'dockerd'" "$dockerd_init"; then
        echo "错误：Dockerman 页面、RPC 后端和 dockerd 必须共用 /etc/config/dockerd。" >&2
        return 1
    fi
    echo "Dockerman 配置接口检查通过。"
}


verify_apk_repositories() {
    local build_dir="$1"
    local board arch repositories
    local found=0
    board=$(read_kconfig_value "$build_dir/.config" CONFIG_TARGET_BOARD)
    arch=$(read_kconfig_value "$build_dir/.config" CONFIG_TARGET_ARCH_PACKAGES)

    while IFS= read -r repositories; do
        found=1
        if grep -Eq '/(custom_feed|nss_packages|sqm_scripts_nss|openwrt_bandix|luci_app_bandix)/' "$repositories"; then
            echo "错误：APK 软件源仍包含构建专用源：$repositories" >&2
            return 1
        fi
        if [[ ${ENABLE_EBPF_PROXY_DEPS:-0} == 1 ]]; then
            local daeuniverse_list="${repositories%/*}/daeuniverse.list"
            local expected="@daeuniverse https://openwrt.daeuniverse.org/25.12/packages/$arch/packages.adb"
            if [[ ! -f "$daeuniverse_list" || $(cat "$daeuniverse_list") != "$expected" ||
                  ! -s "${repositories%/*}/../keys/daeuniverse.pem" ]]; then
                echo "错误：固件缺少匹配架构的 daeuniverse 应用源或公钥。" >&2
                return 1
            fi
        fi
    done < <(find "$build_dir/build_dir" -type f \
        -path "*/root-$board*/etc/apk/repositories.d/distfeeds.list" -print)

    if [[ "$found" != 1 ]]; then
        echo "错误：未找到固件根文件系统的 APK 软件源清单。" >&2
        return 1
    fi
    echo "固件 APK 软件源检查通过。"
}
