#!/bin/sh

set -eu

mirror=${WRT_DEBIAN_MIRROR-https://mirrors.tuna.tsinghua.edu.cn/debian}
mirror=${mirror%/}
security_mirror=${WRT_DEBIAN_SECURITY_MIRROR-https://mirrors.nju.edu.cn/debian-archive/debian-security}
security_mirror=${security_mirror%/}
sources_dir=/etc/apt
backup_dir=$(mktemp -d)
trap 'rm -rf "$backup_dir"' EXIT
modified=0

for mirror_url in "$mirror" "$security_mirror"; do
    [ -n "$mirror_url" ] || continue
    case "$mirror_url" in
        http://*|https://*) ;;
        *) echo "Invalid Debian mirror URL: $mirror_url" >&2; exit 1 ;;
    esac
    case "$mirror_url" in
        *[!a-zA-Z0-9:/._-]*) echo "Invalid Debian mirror URL: $mirror_url" >&2; exit 1 ;;
    esac
done

for source in "$sources_dir/sources.list" "$sources_dir/sources.list.d/"*.list "$sources_dir/sources.list.d/"*.sources; do
    [ -f "$source" ] || continue
    cp "$source" "$backup_dir/rewritten"
    if [ -n "$mirror" ]; then
        sed -E "s@https?://deb[.]debian[.]org/debian(/|[[:space:]]|$)@${mirror}\\1@g" \
            "$backup_dir/rewritten" > "$backup_dir/rewritten.next"
        mv "$backup_dir/rewritten.next" "$backup_dir/rewritten"
    fi
    if [ -n "$security_mirror" ]; then
        # Only replace the Bullseye security snapshot; preserve other snapshots.
        sed -E "/bullseye-security/s@https?://snapshot[.]debian[.]org/archive/debian-security/[0-9]{8}T[0-9]{6}Z(/|[[:space:]]|$)@${security_mirror}\\1@g" \
            "$backup_dir/rewritten" > "$backup_dir/rewritten.next"
        mv "$backup_dir/rewritten.next" "$backup_dir/rewritten"
    fi
    if ! cmp -s "$source" "$backup_dir/rewritten"; then
        if [ "$source" = "$sources_dir/sources.list" ]; then
            backup="$backup_dir/sources.list"
        else
            mkdir -p "$backup_dir/sources.list.d"
            backup="$backup_dir/sources.list.d/$(basename "$source")"
        fi
        cp -p "$source" "$backup"
        cat "$backup_dir/rewritten" > "$source"
        modified=1
    fi
done

apt_update() {
    apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 -o APT::Update::Error-Mode=any \
        -o Acquire::Languages=none update
}

restore_sources() {
    if [ -f "$backup_dir/sources.list" ]; then
        cp -p "$backup_dir/sources.list" "$sources_dir/sources.list"
    fi
    for backup in "$backup_dir/sources.list.d/"*; do
        [ -f "$backup" ] || continue
        cp -p "$backup" "$sources_dir/sources.list.d/$(basename "$backup")"
    done
    modified=0
}

apt_install() {
    apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 install -y \
        sudo git jq build-essential cmake g++ clang bison flex libelf-dev \
        libncurses5-dev python3-distutils zlib1g-dev python3 pkg-config libssl-dev
}

if ! apt_update; then
    if [ "$modified" -eq 0 ]; then
        exit 1
    fi
    echo "Debian mirror update failed; retrying with the original sources." >&2
    restore_sources
    apt_update
fi

if ! apt_install; then
    if [ "$modified" -eq 0 ]; then
        exit 1
    fi
    echo "Debian mirror install failed; retrying with the original sources." >&2
    restore_sources
    apt_update
    apt_install
fi
