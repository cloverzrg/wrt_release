#!/usr/bin/env bash

get_feeds_path() {
    local feeds_path="$BUILD_DIR/$FEEDS_CONF"
    if [[ -f "$BUILD_DIR/feeds.conf" ]]; then
        feeds_path="$BUILD_DIR/feeds.conf"
    fi
    printf '%s\n' "$feeds_path"
}

append_feed_if_missing() {
    local feeds_path="$1"
    local match_pattern="$2"
    local feed_entry="$3"

    if ! grep -q "$match_pattern" "$feeds_path"; then
        [ -z "$(tail -c 1 "$feeds_path")" ] || echo "" >>"$feeds_path"
        echo "$feed_entry" >>"$feeds_path"
    fi
}

update_feeds() {
    local FEEDS_PATH
    FEEDS_PATH=$(get_feeds_path)
    sed -i '/^#/d' "$FEEDS_PATH"
    sed -i '/packages_ext/d' "$FEEDS_PATH"
    sed -i '/video/d' "$FEEDS_PATH"
    sed -i '/[[:space:]]small8[[:space:]]/d' "$FEEDS_PATH"
    sed -i '/[[:space:]]custom_feed[[:space:]]/d' "$FEEDS_PATH"

    if [[ ${ENABLE_BAILI_APPS:-0} != 1 ]]; then
        append_feed_if_missing "$FEEDS_PATH" "openwrt_bandix" "src-git openwrt_bandix https://github.com/timsaya/openwrt-bandix.git;main"
        append_feed_if_missing "$FEEDS_PATH" "luci_app_bandix" "src-git luci_app_bandix https://github.com/timsaya/luci-app-bandix.git;main"
    fi

    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    network_retry ./scripts/feeds update -a
}

install_feeds() {
    network_retry ./scripts/feeds update -i
    ./scripts/feeds install -a -f
}


omit_baili_local_apk_feed() {
    [[ ${ENABLE_BAILI_APPS:-0} == 1 ]] || return 0

    local feeds_mk="$BUILD_DIR/include/feeds.mk"
    local tmp_path
    tmp_path=$(mktemp) || return 1

    # custom_feed is a local src-link build feed. The public ImmortalWrt mirror
    # cannot serve it, including the commented URL emitted for FEED_*=m.
    if ! awk '
        BEGIN {
            old="$(foreach feed,$(FEEDS_AVAILABLE),"
            replacement="$(foreach feed,$(filter-out custom_feed,$(FEEDS_AVAILABLE)),"
        }
        /^define FeedSourcesAppendAPK$/ { in_apk=1 }
        in_apk {
            pos=index($0, old)
            if (pos) {
                $0=substr($0, 1, pos-1) replacement substr($0, pos+length(old))
                found++
            } else if (index($0, replacement)) {
                found++
            }
        }
        { print }
        /^endef$/ { in_apk=0 }
        END { if (found != 1) exit 1 }
    ' "$feeds_mk" > "$tmp_path"; then
        rm -f "$tmp_path"
        echo "错误：无法从 APK 软件源生成器排除本地 custom_feed。" >&2
        return 1
    fi
    cat "$tmp_path" > "$feeds_mk" || { rm -f "$tmp_path"; return 1; }
    rm -f "$tmp_path"
}
