#!/bin/sh

set -eu

mirror=${WRT_DEBIAN_MIRROR-https://mirrors.tuna.tsinghua.edu.cn/debian}
mirror=${mirror%/}
sources_dir=/etc/apt
backup_dir=$(mktemp -d)
trap 'rm -rf "$backup_dir"' EXIT
modified=0

if [ -n "$mirror" ]; then
    case "$mirror" in
        http://*|https://*) ;;
        *) echo "Invalid Debian mirror URL: $mirror" >&2; exit 1 ;;
    esac
    case "$mirror" in
        *[!a-zA-Z0-9:/._-]*) echo "Invalid Debian mirror URL: $mirror" >&2; exit 1 ;;
    esac

    # Keep security snapshots and third-party repositories unchanged.
    for source in "$sources_dir/sources.list" "$sources_dir/sources.list.d/"*.list "$sources_dir/sources.list.d/"*.sources; do
        [ -f "$source" ] || continue
        if grep -Eq 'https?://deb[.]debian[.]org/debian(/|[[:space:]]|$)' "$source"; then
            if [ "$source" = "$sources_dir/sources.list" ]; then
                backup="$backup_dir/sources.list"
            else
                mkdir -p "$backup_dir/sources.list.d"
                backup="$backup_dir/sources.list.d/$(basename "$source")"
            fi
            cp -p "$source" "$backup"
            sed -E "s@https?://deb[.]debian[.]org/debian(/|[[:space:]]|$)@${mirror}\\1@g" "$source" > "$backup_dir/rewritten"
            cat "$backup_dir/rewritten" > "$source"
            modified=1
        fi
    done
fi

apt_update() {
    apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 -o APT::Update::Error-Mode=any \
        -o Acquire::Languages=none update
}

if ! apt_update; then
    if [ "$modified" -eq 0 ]; then
        exit 1
    fi
    echo "Debian mirror update failed; retrying with the original sources." >&2
    if [ -f "$backup_dir/sources.list" ]; then
        cp -p "$backup_dir/sources.list" "$sources_dir/sources.list"
    fi
    for backup in "$backup_dir/sources.list.d/"*; do
        [ -f "$backup" ] || continue
        cp -p "$backup" "$sources_dir/sources.list.d/$(basename "$backup")"
    done
    apt_update
fi

apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 install -y \
    sudo git jq build-essential cmake g++ clang bison flex libelf-dev \
    libncurses5-dev python3-distutils zlib1g-dev python3 pkg-config libssl-dev
