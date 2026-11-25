#!/bin/sh
# 99-proxy.sh — stage1 proxy environment profile (stage0-netboot-image, task 2.4).
#
# Sourced by stage1 login shells (via /etc/profile) to export the egress proxy
# the operator configured, so every stage1 shell tool honors it (requirement 8.2):
#   http_proxy https_proxy all_proxy no_proxy github_proxy
#
# Values are derived from the persisted DeploymentConfig at $NETINSTALL_CONFIG
# (default /etc/netinstall/config.json) and emitted through the shared proxy env
# construction helper (lib/proxy.sh `proxy_exports`). This file is static:
# stage1-install copies it verbatim; all runtime variation lives in config.json.
#
# With no proxy configured, or no config/helper present, this profile exports
# nothing and is a no-op. POSIX sh (busybox ash compatible); no bashisms.

NETINSTALL_CONFIG=${NETINSTALL_CONFIG:-/etc/netinstall/config.json}
NETINSTALL_PROXY_LIB=${NETINSTALL_PROXY_LIB:-/usr/local/sbin/lib/proxy.sh}

# Reuse the shared proxy env constructor. Degrade to a no-op (rather than fail
# every login) if the helper or the config is absent from a bare stage1 root.
[ -r "$NETINSTALL_PROXY_LIB" ] || return 0
. "$NETINSTALL_PROXY_LIB"
[ -r "$NETINSTALL_CONFIG" ] || return 0

# --- minimal single-line JSON extraction (same shape the menu writes) ---
_npx_json_get_str() {
    printf '%s\n' "$1" | sed -n "s/.*\"$2\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}
_npx_json_get_array() {
    printf '%s\n' "$1" | sed -n "s/.*\"$2\":[[:space:]]*\[\(.*\)\].*/\1/p" | head -n 1
}
_npx_json_array_items() {
    printf '%s\n' "${1:-}" | sed 's/", */","/g' | awk -F'","' '{ for (i=1;i<=NF;i++) print $i }' \
        | sed -e 's/^"//' -e 's/"$//'
}
_npx_json_unescape() {
    sed -e 's/\\\\/\\/g' -e 's/\\"/"/g'
}

_cfg=$(cat "$NETINSTALL_CONFIG")

_http=$(_npx_json_get_str "$_cfg" http | _npx_json_unescape)
_https=$(_npx_json_get_str "$_cfg" https | _npx_json_unescape)
_all=$(_npx_json_get_str "$_cfg" all | _npx_json_unescape)
_github=$(_npx_json_get_str "$_cfg" githubProxy | _npx_json_unescape)

_no_proxy_args=''
_sep=''
_old_ifs=$IFS
IFS='
'
for _h in $(_npx_json_array_items "$(_npx_json_get_array "$_cfg" noProxy)" | _npx_json_unescape); do
    _no_proxy_args="$_no_proxy_args$_sep$_h"
    _sep=' '
done
IFS=$_old_ifs

# shellcheck disable=SC2086
eval "$(proxy_exports "$_http" "$_https" "$_all" "$_github" $_no_proxy_args)"
