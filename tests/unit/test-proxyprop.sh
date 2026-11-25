#!/bin/sh
# Unit tests for the Proxy Network Propagator (task 2.4 — stage0-netboot-image).
#
# Exercises:
#   1. proxy_check_reachable — returns 0 for a reachable (mocked) proxy, and
#      non-zero plus a clear error for an unreachable one, through the
#      overridable probe-command seam (no real network).
#   2. stage1/etc/profile.d/99-proxy.sh — when sourced, exports the five proxy
#      vars (http_proxy/https_proxy/all_proxy/no_proxy/github_proxy) to exactly
#      the values proxy_exports would emit.
#   3. the profile exports nothing when no proxy is configured.
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-proxyprop.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
LIB_DIR="$REPO_ROOT/stage0/payload/usr/local/sbin/lib"
PROFILE="$REPO_ROOT/stage1/etc/profile.d/99-proxy.sh"

# Reuse the proxy env construction helper under test.
. "$LIB_DIR/proxy.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

assert_eq() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected [$2] got [$3]"
    fi
}

assert_return_ok() { # name status
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "expected status 0 got $2"; fi
}

assert_return_fail() { # name status
    if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1" "expected non-zero status got $2"; fi
}

assert_contains() { # name needle haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "expected [$3] to contain [$2]" ;;
    esac
}

tmpdir=$(mktemp -d) || exit 1

# ---------------------------------------------------------------------------
# 1. proxy_check_reachable (mocked probe command; no real network)
# ---------------------------------------------------------------------------

type proxy_check_reachable >/dev/null 2>&1
assert_return_ok "proxy.sh defines proxy_check_reachable" "$?"

mock_reachable="$tmpdir/reachable.sh"
mock_unreachable="$tmpdir/unreachable.sh"

cat > "$mock_reachable" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$mock_unreachable" <<'EOF'
#!/bin/sh
echo "connection refused" >&2
exit 7
EOF

chmod +x "$mock_reachable" "$mock_unreachable"

PROXY_CHECK_CMD="$mock_reachable"; export PROXY_CHECK_CMD
proxy_check_reachable "http://proxy.example:8080"; st=$?
assert_return_ok "proxy_check_reachable returns 0 for reachable proxy" "$st"

PROXY_CHECK_CMD="$mock_unreachable"; export PROXY_CHECK_CMD
proxy_check_reachable "http://proxy.example:8080" 2>"$tmpdir/reach.err"; st=$?
assert_return_fail "proxy_check_reachable returns non-zero for unreachable proxy" "$st"
assert_contains "proxy_check_reachable reports the proxy as unreachable" \
    "unreachable" "$(cat "$tmpdir/reach.err")"

proxy_check_reachable "" 2>"$tmpdir/empty.err"; st=$?
assert_return_fail "proxy_check_reachable rejects empty proxy URL" "$st"
assert_contains "proxy_check_reachable reports empty proxy URL" \
    "empty proxy URL" "$(cat "$tmpdir/empty.err")"

# ---------------------------------------------------------------------------
# 2. stage1 profile exports the five proxy vars (matching proxy_exports output)
# ---------------------------------------------------------------------------

f_proxy="$tmpdir/proxy.json"
f_no_proxy="$tmpdir/no-proxy.json"

cat > "$f_proxy" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"},"proxy":{"http":"http://proxy.example:8080","https":"http://proxy.example:8080","all":"socks5://proxy.example:1080","noProxy":["localhost","127.0.0.1"],"githubProxy":"https://ghproxy.example.com"}}
EOF

cat > "$f_no_proxy" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"}}
EOF

# What proxy_exports would emit for the same proxy config — the reference the
# profile must match byte-for-byte once evaluated.
expected_exports=$(proxy_exports \
    "http://proxy.example:8080" "http://proxy.example:8080" \
    "socks5://proxy.example:1080" "https://ghproxy.example.com" \
    "localhost" "127.0.0.1")

expected_dump=$(
    unset http_proxy https_proxy all_proxy no_proxy github_proxy
    eval "$expected_exports"
    printf 'http_proxy=%s\nhttps_proxy=%s\nall_proxy=%s\nno_proxy=%s\ngithub_proxy=%s\n' \
        "${http_proxy-}" "${https_proxy-}" "${all_proxy-}" "${no_proxy-}" "${github_proxy-}"
)

NETINSTALL_PROXY_LIB="$LIB_DIR/proxy.sh"; export NETINSTALL_PROXY_LIB

NETINSTALL_CONFIG="$f_proxy"; export NETINSTALL_CONFIG
unset http_proxy https_proxy all_proxy no_proxy github_proxy
. "$PROFILE"

actual_dump=$(printf 'http_proxy=%s\nhttps_proxy=%s\nall_proxy=%s\nno_proxy=%s\ngithub_proxy=%s\n' \
    "${http_proxy-}" "${https_proxy-}" "${all_proxy-}" "${no_proxy-}" "${github_proxy-}")

assert_eq "profile exports match proxy_exports output" "$expected_dump" "$actual_dump"

assert_eq "profile exports http_proxy" "http://proxy.example:8080" "${http_proxy-}"
assert_eq "profile exports https_proxy" "http://proxy.example:8080" "${https_proxy-}"
assert_eq "profile exports all_proxy" "socks5://proxy.example:1080" "${all_proxy-}"
assert_eq "profile exports no_proxy" "localhost,127.0.0.1" "${no_proxy-}"
assert_eq "profile exports github_proxy" "https://ghproxy.example.com" "${github_proxy-}"

# ---------------------------------------------------------------------------
# 3. profile exports nothing when no proxy is configured
# ---------------------------------------------------------------------------

NETINSTALL_CONFIG="$f_no_proxy"; export NETINSTALL_CONFIG
unset http_proxy https_proxy all_proxy no_proxy github_proxy
. "$PROFILE"

for var in http_proxy https_proxy all_proxy no_proxy github_proxy; do
    eval "value=\${$var-}"
    if [ -z "$value" ]; then
        pass "profile leaves $var unset when no proxy is configured"
    else
        fail "profile leaves $var unset when no proxy is configured" "unexpected [$value]"
    fi
done

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
