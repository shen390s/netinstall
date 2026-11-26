#!/bin/sh
# E2E: proxy traversal (stage0-netboot-image, task 4.3 — requirements 8.2, 8.3).
#
# Builds the REAL stage0 initramfs, extracts it, and drives the REAL baked
# proxy helper, reinstall adapter, and stage1 proxy profile (the exact scripts
# the booted image runs — not mocks) against a proxy config. Asserts:
#   1. proxy env construction emits http_proxy/https_proxy/all_proxy/no_proxy/
#      github_proxy (req 8.2);
#   2. the reinstall adapter propagates that same env block into its output
#      (forwarded to reinstall during installation, req 8.2);
#   3. the stage1 profile, when sourced, exports the same five vars (forwarded
#      into stage1 shells, req 8.2);
#   4. proxy reachability: a local loopback proxy stub (real HTTP, served by
#      busybox nc) is reported reachable, and a dead loopback port is reported
#      unreachable with a clear error (req 8.3).
#
# A full QEMU boot is not required here: proxy env construction/propagation and
# the reachability probe are exercised against the shipped artifacts directly,
# with a real loopback proxy stub (no internet required).

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
E2E_DIR="$SCRIPT_DIR"
. "$E2E_DIR/lib.sh"

PASS=0
FAIL=0
QEMU_PID=
PROXY_PID=
TMPDIR=$(mktemp -d) || exit 1
trap 'e2e_cleanup' EXIT HUP INT TERM
e2e_cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
    rm -rf "$TMPDIR"
}

e2e_require nc "loopback proxy stub (busybox nc)"
e2e_require wget "proxy reachability probe"
e2e_skip_unless "$REPO_ROOT/stage0/build-initramfs.sh" "initramfs builder"

INITRD="$TMPDIR/initramfs-stage0"
e2e_info "building stage0 initramfs"
e2e_build_initramfs "$INITRD"
_st=$?
if [ "$_st" -ne 0 ]; then
    [ "$_st" -eq 3 ] && exit 3
    e2e_fail "initramfs build failed"
    exit 1
fi

ROOTFS="$TMPDIR/rootfs"
e2e_extract_initramfs "$INITRD" "$ROOTFS" || { e2e_fail "initramfs extract failed"; exit 1; }

# --- fixture: a proxy config with all five fields --------------------------
PROXY_HTTP="http://proxy.example:8080"
PROXY_HTTPS="http://proxy.example:8080"
PROXY_ALL="socks5://proxy.example:1080"
PROXY_NO="localhost,127.0.0.1"
PROXY_GITHUB="https://ghproxy.example.com"

cat > "$TMPDIR/proxy.json" <<EOF
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"},"proxy":{"http":"$PROXY_HTTP","https":"$PROXY_HTTPS","all":"$PROXY_ALL","noProxy":["localhost","127.0.0.1"],"githubProxy":"$PROXY_GITHUB"}}
EOF

# --- (1) proxy env construction (req 8.2) ----------------------------------
. "$ROOTFS/usr/local/sbin/lib/proxy.sh"
EXPORTS=$(proxy_exports "$PROXY_HTTP" "$PROXY_HTTPS" "$PROXY_ALL" "$PROXY_GITHUB" localhost 127.0.0.1)
e2e_assert_contains "proxy env exports http_proxy" "export http_proxy=$PROXY_HTTP" "$EXPORTS"
e2e_assert_contains "proxy env exports https_proxy" "export https_proxy=$PROXY_HTTPS" "$EXPORTS"
e2e_assert_contains "proxy env exports all_proxy" "export all_proxy=$PROXY_ALL" "$EXPORTS"
e2e_assert_contains "proxy env exports no_proxy" "export no_proxy=$PROXY_NO" "$EXPORTS"
e2e_assert_contains "proxy env exports github_proxy" "export github_proxy=$PROXY_GITHUB" "$EXPORTS"

# --- (2) the adapter propagates the proxy env to reinstall (req 8.2) -------
ADAPTER_OS_CATALOG="$ROOTFS/etc/netinstall/os-catalog.json" \
ADAPTER_PROXY_LIB="$ROOTFS/usr/local/sbin/lib/proxy.sh" \
sh "$ROOTFS/usr/local/sbin/reinstall-adapter" "$TMPDIR/proxy.json" \
    >"$TMPDIR/adapter.out" 2>"$TMPDIR/adapter.err"
st=$?
if [ "$st" -eq 0 ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "adapter maps a proxy config successfully"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "adapter failed for proxy config (exit $st): $(cat "$TMPDIR/adapter.err")"
fi
ADAPTER_OUT=$(cat "$TMPDIR/adapter.out")
e2e_assert_contains "adapter emits http_proxy for reinstall" "export http_proxy=$PROXY_HTTP" "$ADAPTER_OUT"
e2e_assert_contains "adapter emits github_proxy for reinstall" "export github_proxy=$PROXY_GITHUB" "$ADAPTER_OUT"
e2e_assert_contains "adapter emits no_proxy for reinstall" "export no_proxy=$PROXY_NO" "$ADAPTER_OUT"

# --- (3) the stage1 profile exports the same vars (req 8.2) ----------------
NETINSTALL_PROXY_LIB="$ROOTFS/usr/local/sbin/lib/proxy.sh"; export NETINSTALL_PROXY_LIB
NETINSTALL_CONFIG="$TMPDIR/proxy.json"; export NETINSTALL_CONFIG
unset http_proxy https_proxy all_proxy no_proxy github_proxy
. "$ROOTFS/stage1/etc/profile.d/99-proxy.sh"
if [ "${http_proxy-}" = "$PROXY_HTTP" ] && [ "${https_proxy-}" = "$PROXY_HTTPS" ] \
   && [ "${all_proxy-}" = "$PROXY_ALL" ] && [ "${no_proxy-}" = "$PROXY_NO" ] \
   && [ "${github_proxy-}" = "$PROXY_GITHUB" ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "stage1 profile exports all five proxy vars"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' \
        "stage1 profile proxy exports mismatch: http=[${http_proxy-}] https=[${https_proxy-}] all=[${all_proxy-}] no=[${no_proxy-}] github=[${github_proxy-}]"
fi

# --- (4) proxy reachability through a real loopback proxy stub (req 8.3) ---
cat > "$TMPDIR/proxy-stub.sh" <<'EOF'
#!/bin/sh
# Minimal forward-proxy stub: read the request line, answer 200 empty.
read -r _request || exit 0
printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
exit 0
EOF
chmod +x "$TMPDIR/proxy-stub.sh"

PROXY_PORT=18080
nc -l -p "$PROXY_PORT" -e "$TMPDIR/proxy-stub.sh" >"$TMPDIR/nc.out" 2>&1 &
PROXY_PID=$!
# Give the single-shot listener a moment to bind. Do NOT probe with a plain
# connect (it would consume the one connection nc handles and shut it down).
sleep 2

PROXY_CHECK_URL="http://example.com"
export PROXY_CHECK_URL
proxy_check_reachable "http://127.0.0.1:$PROXY_PORT" >"$TMPDIR/reach.out" 2>"$TMPDIR/reach.err"
st=$?
if [ "$st" -eq 0 ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "loopback proxy stub is reported reachable (req 8.3)"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "loopback proxy stub should be reachable (exit $st): $(cat "$TMPDIR/reach.err")"
fi

kill "$PROXY_PID" 2>/dev/null; PROXY_PID=

proxy_check_reachable "http://127.0.0.1:1" >"$TMPDIR/dead.out" 2>"$TMPDIR/dead.err"
st=$?
if [ "$st" -ne 0 ]; then
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "dead loopback proxy is reported unreachable"
else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "dead loopback proxy should be unreachable but probe returned 0"
fi
e2e_assert_contains "unreachable proxy reports a clear error" "unreachable" "$(cat "$TMPDIR/dead.err")"

e2e_summary
exit $?
