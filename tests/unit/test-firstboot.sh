#!/bin/sh
# Unit tests for the Stage1 Firstboot component (task 2.6 — stage0-netboot-image).
#
# Exercises the stage1 local.d consumer of the Reinstall Adapter contract and
# asserts:
#   1. valid config + stubbed adapter -> under DRY_RUN=1 emits the resolved
#      reinstall.sh argv, emits + exports the proxy env, and passes the config
#      path to the adapter;
#   2. the script is non-interactive (no `read` builtin, no dialog/prompt TUI);
#   3. missing config -> non-zero, no adapter/reinstall invocation;
#   4. failing adapter (non-zero) -> non-zero, no reinstall invocation;
#   5. DRY_RUN=1 never executes the real reinstall.sh.
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-firstboot.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
FIRSTBOOT="$REPO_ROOT/stage1/etc/local.d/stage1.start"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

assert_eq() { # name expected actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
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
        *) fail "$1" "expected output to contain [$2]" ;;
    esac
}

# Source the component under test. (RED phase: this file does not exist yet, so
# `stage1_firstboot` stays undefined and the behavioural tests are skipped with
# an explicit failure.)
if [ -r "$FIRSTBOOT" ]; then
    . "$FIRSTBOOT"
fi

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

tmpdir=$(mktemp -d) || exit 1

CONFIG_GOOD="$tmpdir/config.json"
cat > "$CONFIG_GOOD" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"}}
EOF

STUB_ADAPTER="$tmpdir/stub-adapter"
STUB_ADAPTER_FAIL="$tmpdir/stub-adapter-fail"
STUB_REINSTALL="$tmpdir/stub-reinstall"
REINSTALL_MARKER="$tmpdir/reinstall-ran"
ADAPTER_ARG_MARKER="$tmpdir/adapter-arg"
SERIAL_LOG="$tmpdir/serial.log"

cat > "$STUB_ADAPTER" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > "$ADAPTER_ARG_MARKER"
printf '%s\n' 'debian 12 --username operator'
printf '%s\n' 'export http_proxy=http://proxy.example:8080'
printf '%s\n' 'export https_proxy=http://proxy.example:8080'
printf '%s\n' 'export no_proxy=localhost,127.0.0.1'
exit 0
EOF

cat > "$STUB_ADAPTER_FAIL" <<'EOF'
#!/bin/sh
printf '%s\n' 'reinstall-adapter: unsupported os [linux/nixos/24.05]' >&2
exit 3
EOF

cat > "$STUB_REINSTALL" <<EOF
#!/bin/sh
printf 'EXECUTED\n' > "$REINSTALL_MARKER"
exit 0
EOF

chmod +x "$STUB_ADAPTER" "$STUB_ADAPTER_FAIL" "$STUB_REINSTALL"

# ---------------------------------------------------------------------------
# Behavioural tests (only meaningful once the component exists).
# ---------------------------------------------------------------------------

run_tests() {
    NETINSTALL_CONFIG="$CONFIG_GOOD"
    NETINSTALL_ADAPTER="$STUB_ADAPTER"
    NETINSTALL_REINSTALL="$STUB_REINSTALL"
    NETINSTALL_SERIAL_DEV="$SERIAL_LOG"
    export NETINSTALL_CONFIG NETINSTALL_ADAPTER NETINSTALL_REINSTALL NETINSTALL_SERIAL_DEV
    unset http_proxy https_proxy all_proxy no_proxy github_proxy

    # --- (1) valid config + stubbed adapter, DRY_RUN=1 --------------------
    rm -f "$REINSTALL_MARKER" "$ADAPTER_ARG_MARKER"
    DRY_RUN=1
    stage1_firstboot > "$tmpdir/out" 2>"$tmpdir/err"
    st=$?
    assert_return_ok "firstboot(valid config) returns 0" "$st"

    assert_eq "invokes adapter with config path" "$CONFIG_GOOD" "$(cat "$ADAPTER_ARG_MARKER")"

    argv=$(sed -n '1p' "$tmpdir/out")
    assert_eq "emits resolved reinstall.sh argv" "debian 12 --username operator" "$argv"

    env_block=$(sed '1d' "$tmpdir/out")
    assert_contains "emits proxy env block" "export http_proxy=http://proxy.example:8080" "$env_block"

    assert_eq "exports http_proxy" "http://proxy.example:8080" "$http_proxy"
    assert_eq "exports https_proxy" "http://proxy.example:8080" "$https_proxy"
    assert_eq "exports no_proxy" "localhost,127.0.0.1" "$no_proxy"

    # --- (2) non-interactive: no read builtin / no dialog TUI -------------
    if grep -nwE 'read|dialog|select' "$FIRSTBOOT" > "$tmpdir/read-hits" 2>/dev/null; then
        fail "no interactive input builtin" "$(cat "$tmpdir/read-hits")"
    else
        pass "no interactive input builtin (read/dialog/select)"
    fi

    # --- (3) missing config -> non-zero, no reinstall ---------------------
    rm -f "$REINSTALL_MARKER"
    DRY_RUN=0
    NETINSTALL_CONFIG="$tmpdir/does-not-exist.json"
    stage1_firstboot > "$tmpdir/out3" 2>"$tmpdir/err3"
    st=$?
    assert_return_fail "missing config returns non-zero" "$st"
    if [ -e "$REINSTALL_MARKER" ]; then
        fail "missing config does not exec reinstall.sh" "marker present"
    else
        pass "missing config does not exec reinstall.sh"
    fi
    assert_contains "missing config logs to serial" "config" "$(cat "$SERIAL_LOG")"

    # --- (4) failing adapter -> non-zero, no reinstall --------------------
    rm -f "$REINSTALL_MARKER"
    NETINSTALL_CONFIG="$CONFIG_GOOD"
    NETINSTALL_ADAPTER="$STUB_ADAPTER_FAIL"
    DRY_RUN=0
    stage1_firstboot > "$tmpdir/out4" 2>"$tmpdir/err4"
    st=$?
    assert_return_fail "failing adapter returns non-zero" "$st"
    if [ -e "$REINSTALL_MARKER" ]; then
        fail "failing adapter does not exec reinstall.sh" "marker present"
    else
        pass "failing adapter does not exec reinstall.sh"
    fi
    assert_contains "failing adapter logs to serial" "failed" "$(cat "$SERIAL_LOG")"

    # --- (5) DRY_RUN=1 never executes the real reinstall.sh ---------------
    rm -f "$REINSTALL_MARKER"
    NETINSTALL_CONFIG="$CONFIG_GOOD"
    NETINSTALL_ADAPTER="$STUB_ADAPTER"
    DRY_RUN=1
    stage1_firstboot > "$tmpdir/out5" 2>"$tmpdir/err5"
    st=$?
    assert_return_ok "firstboot(DRY_RUN=1) returns 0" "$st"
    if [ -e "$REINSTALL_MARKER" ]; then
        fail "DRY_RUN=1 never executes real reinstall.sh" "marker present"
    else
        pass "DRY_RUN=1 never executes real reinstall.sh"
    fi
}

if type stage1_firstboot >/dev/null 2>&1; then
    pass "firstboot defines stage1_firstboot"
    run_tests
else
    fail "firstboot defines stage1_firstboot" "stage1_firstboot undefined; behavioural tests skipped"
fi

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
