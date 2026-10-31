#!/usr/bin/env bash
# Prepare only runtime dependency metadata and the user's official APK source.

prepare_ebpf_proxy_dependencies() {
    [[ ${ENABLE_EBPF_PROXY_DEPS:-0} == 1 ]] || return 0

    local package_dir="$BUILD_DIR/package/local/vmlinux-btf-builtin"
    local base_files_dir="$BUILD_DIR/package/base-files/files"
    local source_dir="$BASE_PATH/patches/daeuniverse"

    if [[ ! -d "$base_files_dir" ]]; then
        echo "错误：缺少 base-files 目录，无法配置 daeuniverse 应用源。" >&2
        return 1
    fi
    mkdir -p "$package_dir" || return 1
    cp -f "$BASE_PATH/packages/vmlinux-btf-builtin/Makefile" "$package_dir/Makefile" || return 1
    mkdir -p "$base_files_dir/etc/apk/keys" "$base_files_dir/etc/apk/repositories.d" || return 1
    cp -f "$source_dir/public-key.pem" "$base_files_dir/etc/apk/keys/daeuniverse.pem" || return 1
    cp -f "$source_dir/daeuniverse.list" "$base_files_dir/etc/apk/repositories.d/daeuniverse.list"
}
