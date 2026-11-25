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

# proxy_check_reachable <proxy_url>
# Verify that <proxy_url> accepts connections by issuing a probe request through
# it. Returns 0 if the proxy is reachable; non-zero with a clear message on
# stderr otherwise (requirement 8.3). An empty proxy URL fails fast.
#
# The probe is unit-testable without a real network via two overridable seams:
#   PROXY_CHECK_URL     — URL fetched through the proxy (default http://example.com).
#   PROXY_CHECK_CMD     — when set, invoked as `$PROXY_CHECK_CMD <proxy_url> <probe_url>`
#                         and its exit status decides reachability (test seam).
#                         Otherwise a `wget -q -O /dev/null -T <timeout>` probe is used,
#                         with PROXY_CHECK_TIMEOUT seconds (default 5).
proxy_check_reachable() {
    _proxy_url=${1:-}
    if [ -z "$_proxy_url" ]; then
        printf 'proxy_check_reachable: empty proxy URL\n' >&2
        return 1
    fi
    _probe_url=${PROXY_CHECK_URL:-http://example.com}
    if [ -n "${PROXY_CHECK_CMD:-}" ]; then
        # shellcheck disable=SC2086
        $PROXY_CHECK_CMD "$_proxy_url" "$_probe_url" 2>/dev/null
    else
        http_proxy="$_proxy_url" https_proxy="$_proxy_url" no_proxy='' \
            wget -q -O /dev/null -T "${PROXY_CHECK_TIMEOUT:-5}" "$_probe_url" 2>/dev/null
    fi
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf 'proxy_check_reachable: proxy %s unreachable\n' "$_proxy_url" >&2
    fi
    return "$_rc"
}
