#!/bin/sh
# proxy.sh — proxy environment construction helpers (stage0-netboot-image).
#
# Builds the proxy env vars used across every download stage. The `proxy` config
# object from DeploymentConfig maps onto the arguments of proxy_exports as:
#
#     proxy_exports <proxy.http> <proxy.https> <proxy.all> <proxy.githubProxy> \
#                   [noProxy host ...]
#
# The variadic trailing arguments are the noProxy bypass list; they are comma-joined
# into the no_proxy variable. Unset/empty fields are omitted from the output.
#
# All functions are POSIX sh (busybox ash compatible); no bashisms.

# proxy_join_no_proxy [host ...]
# Join the bypass-list hosts into a single comma-separated string. Empty entries
# are skipped.
proxy_join_no_proxy() {
    _sep=''
    _out=''
    for _host in "$@"; do
        [ -n "$_host" ] || continue
        _out="$_out$_sep$_host"
        _sep=','
    done
    printf '%s\n' "$_out"
}

# proxy_exports <http> <https> <all> <githubProxy> [noProxy host ...]
# Emit `export` lines for http_proxy, https_proxy, all_proxy, no_proxy, and
# github_proxy. Empty values are omitted (so an absent proxy emits nothing).
proxy_exports() {
    _http=${1:-}
    _https=${2:-}
    _all=${3:-}
    _github_proxy=${4:-}
    if [ "$#" -ge 4 ]; then
        shift 4
    fi
    _no_proxy=$(proxy_join_no_proxy "$@")

    [ -n "$_http" ] && printf 'export http_proxy=%s\n' "$_http"
    [ -n "$_https" ] && printf 'export https_proxy=%s\n' "$_https"
    [ -n "$_all" ] && printf 'export all_proxy=%s\n' "$_all"
    [ -n "$_no_proxy" ] && printf 'export no_proxy=%s\n' "$_no_proxy"
    [ -n "$_github_proxy" ] && printf 'export github_proxy=%s\n' "$_github_proxy"
}

# proxy_github_rewrite <url> <githubProxy>
# Rewrite a raw.githubusercontent.com URL through the GitHub proxy mirror prefix,
# matching the pinned reinstall bundle's rewrite rule. Non-GitHub URLs are
# returned unchanged.
proxy_github_rewrite() {
    _url=${1:-}
    _github_proxy=${2:-}
    case "$_url" in
        https://raw.githubusercontent.com/*)
            printf '%s%s\n' "$_github_proxy" "${_url#https://raw.githubusercontent.com}"
            ;;
        *)
            printf '%s\n' "$_url"
            ;;
    esac
}
