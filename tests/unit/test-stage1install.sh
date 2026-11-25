#!/bin/sh
# Unit tests for the Stage1 Installer (task 3.1 — stage0-netboot-image).
#
# Drives the pure injection-plan core of `stage1-install` without touching a real
# chroot or block device, and asserts:
#   1. the plan maps every source to its exact <sysroot> destination
#      (bundle -> usr/local/sbin, adapter -> usr/local/sbin, config ->
#      etc/netinstall, proxy profile -> etc/profile.d, firstboot -> etc/local.d);
#   2. the plan applies reinstall/patches/proxy-env.patch to the injected
#      reinstall.sh and enables the OpenRC `local` service;
#   3. DRY_RUN=1 emits the plan and copies nothing;
#   4. a missing/empty sysroot or a missing source file is refused (non-zero,
#      no copies).
#
# It also exercises the thin execution wrapper with `chroot`/`patch` stubbed to
# prove the actual copy + patch + enable path.
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-stage1install.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
STAGE1_INSTALL="$REPO_ROOT/stage0/payload/usr/local/sbin/stage1-install"

# Overridable seams (env) — set before sourcing so the defaults resolve.
STAGE1_INSTALL_ROOT="$REPO_ROOT"
STAGE1_INSTALL_ADAPTER="$REPO_ROOT/stage0/payload/usr/local/sbin/reinstall-adapter"
export STAGE1_INSTALL_ROOT STAGE1_INSTALL_ADAPTER

# Source the component under test. (RED phase: this file does not exist yet, so
# `stage1_install_plan`/`stage1_install_run` stay undefined and the behavioural
# tests are skipped with an explicit failure.)
if [ -r "$STAGE1_INSTALL" ]; then
    . "$STAGE1_INSTALL"
fi

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
        *) fail "$1" "expected [$3] to contain [$2]" ;;
    esac
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

tmpdir=$(mktemp -d) || exit 1
sysroot="$tmpdir/sysroot"
mkdir -p "$sysroot"

CONFIG="$tmpdir/config.json"
cat > "$CONFIG" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"}}
EOF

run_tests() {
    # -----------------------------------------------------------------------
    # (1) + (2) the exact injection plan
    # -----------------------------------------------------------------------
    expected_plan=$(cat <<EOF
mkdir -p $sysroot/usr/local/sbin $sysroot/etc/netinstall $sysroot/etc/profile.d $sysroot/etc/local.d
cp $STAGE1_INSTALL_ROOT/reinstall/reinstall.sh $sysroot/usr/local/sbin/reinstall.sh
chmod +x $sysroot/usr/local/sbin/reinstall.sh
( cd $sysroot/usr/local/sbin && patch -p2 -i $STAGE1_INSTALL_ROOT/reinstall/patches/proxy-env.patch )
cp $STAGE1_INSTALL_ROOT/reinstall/trans.sh $sysroot/usr/local/sbin/trans.sh
cp $STAGE1_INSTALL_ROOT/reinstall/initrd-network.sh $sysroot/usr/local/sbin/initrd-network.sh
cp $STAGE1_INSTALL_ADAPTER $sysroot/usr/local/sbin/reinstall-adapter
chmod +x $sysroot/usr/local/sbin/reinstall-adapter
cp $CONFIG $sysroot/etc/netinstall/config.json
cp $STAGE1_INSTALL_ROOT/stage1/etc/profile.d/99-proxy.sh $sysroot/etc/profile.d/99-proxy.sh
cp $STAGE1_INSTALL_ROOT/stage1/etc/local.d/stage1.start $sysroot/etc/local.d/stage1.start
chmod +x $sysroot/etc/local.d/stage1.start
chroot $sysroot /sbin/rc-update add local default
EOF
)

    plan=$(stage1_install_plan "$sysroot" "$CONFIG" 2>"$tmpdir/plan.err"); st=$?
    assert_return_ok "plan returns 0" "$st"
    assert_eq "plan matches the exact injection map" "$expected_plan" "$plan"

    # (1) each source maps to its exact <sysroot> destination.
    assert_contains "bundle reinstall.sh -> usr/local/sbin" \
        "$sysroot/usr/local/sbin/reinstall.sh" "$plan"
    assert_contains "bundle trans.sh -> usr/local/sbin" \
        "$sysroot/usr/local/sbin/trans.sh" "$plan"
    assert_contains "bundle initrd-network.sh -> usr/local/sbin" \
        "$sysroot/usr/local/sbin/initrd-network.sh" "$plan"
    assert_contains "adapter -> usr/local/sbin" \
        "$sysroot/usr/local/sbin/reinstall-adapter" "$plan"
    assert_contains "config -> etc/netinstall" \
        "$sysroot/etc/netinstall/config.json" "$plan"
    assert_contains "proxy profile -> etc/profile.d" \
        "$sysroot/etc/profile.d/99-proxy.sh" "$plan"
    assert_contains "firstboot -> etc/local.d" \
        "$sysroot/etc/local.d/stage1.start" "$plan"

    # (2) proxy-env.patch applied to the injected reinstall.sh + local enabled.
    assert_contains "plan applies proxy-env.patch" \
        "patch -p2 -i $STAGE1_INSTALL_ROOT/reinstall/patches/proxy-env.patch" "$plan"
    assert_contains "patch targets the injected reinstall.sh directory" \
        "cd $sysroot/usr/local/sbin" "$plan"
    assert_contains "plan makes reinstall.sh executable" \
        "chmod +x $sysroot/usr/local/sbin/reinstall.sh" "$plan"
    assert_contains "plan makes reinstall-adapter executable" \
        "chmod +x $sysroot/usr/local/sbin/reinstall-adapter" "$plan"
    assert_contains "plan makes firstboot executable" \
        "chmod +x $sysroot/etc/local.d/stage1.start" "$plan"
    assert_contains "plan enables OpenRC local" \
        "chroot $sysroot /sbin/rc-update add local default" "$plan"

    # (config overridable) no positional config -> NETINSTALL_CONFIG default.
    NETINSTALL_CONFIG="$CONFIG"
    plan_env=$(stage1_install_plan "$sysroot" 2>"$tmpdir/plan-env.err"); st=$?
    assert_return_ok "plan via NETINSTALL_CONFIG returns 0" "$st"
    assert_contains "NETINSTALL_CONFIG used as the config source" \
        "cp $CONFIG $sysroot/etc/netinstall/config.json" "$plan_env"

    # -----------------------------------------------------------------------
    # (3) DRY_RUN=1 emits the plan and copies nothing
    # -----------------------------------------------------------------------
    rm -rf "$sysroot"; mkdir -p "$sysroot"
    DRY_RUN=1
    dry_out=$(stage1_install_run "$sysroot" "$CONFIG" 2>"$tmpdir/dry.err"); st=$?
    unset DRY_RUN
    assert_return_ok "DRY_RUN=1 returns 0" "$st"
    assert_contains "DRY_RUN=1 emits the plan" "$sysroot/usr/local/sbin/reinstall.sh" "$dry_out"
    if [ -z "$(ls -A "$sysroot")" ]; then
        pass "DRY_RUN=1 copies nothing"
    else
        fail "DRY_RUN=1 copies nothing" "sysroot not empty: $(ls -A "$sysroot")"
    fi

    # -----------------------------------------------------------------------
    # (4) fail closed: missing/empty sysroot or missing source -> refused
    # -----------------------------------------------------------------------
    rm -rf "$sysroot"; mkdir -p "$sysroot"

    plan=$(stage1_install_plan "" "$CONFIG" 2>"$tmpdir/fc-empty.err"); st=$?
    assert_return_fail "empty sysroot refused" "$st"
    assert_eq "empty sysroot emits no plan" "" "$plan"

    plan=$(stage1_install_plan "$tmpdir/no-such-dir" "$CONFIG" 2>"$tmpdir/fc-missing.err"); st=$?
    assert_return_fail "missing (non-existent) sysroot refused" "$st"
    assert_eq "missing sysroot emits no plan" "" "$plan"

    # missing config source -> refused at run time with nothing copied.
    rm -rf "$sysroot"; mkdir -p "$sysroot"
    stage1_install_run "$sysroot" "$tmpdir/no-config.json" >"$tmpdir/fc-config.out" 2>"$tmpdir/fc-config.err"; st=$?
    assert_return_fail "missing config source refused" "$st"
    if [ -z "$(ls -A "$sysroot")" ]; then
        pass "missing config source copies nothing"
    else
        fail "missing config source copies nothing" "sysroot not empty: $(ls -A "$sysroot")"
    fi

    # missing bundle source (empty payload root) -> refused.
    empty_root="$tmpdir/empty-root"
    mkdir -p "$empty_root"
    STAGE1_INSTALL_ROOT="$empty_root"
    plan=$(stage1_install_plan "$sysroot" "$CONFIG" 2>"$tmpdir/fc-bundle.err"); st=$?
    assert_return_fail "missing bundle source refused" "$st"
    assert_eq "missing bundle source emits no plan" "" "$plan"
    STAGE1_INSTALL_ROOT="$REPO_ROOT"

    # -----------------------------------------------------------------------
    # (bonus) non-dry-run wrapper copies + invokes patch/chroot (stubbed)
    # -----------------------------------------------------------------------
    fakebin=$(mktemp -d) || exit 1
    fakelog="$tmpdir/exec.log"
    : > "$fakelog"
    cat > "$fakebin/chroot" <<'EOF'
#!/bin/sh
printf 'chroot %s\n' "$*" >> "$FAKE_LOG"
EOF
    cat > "$fakebin/patch" <<'EOF'
#!/bin/sh
printf 'patch %s\n' "$*" >> "$FAKE_LOG"
EOF
    chmod +x "$fakebin/chroot" "$fakebin/patch"
    export FAKE_LOG="$fakelog"

    rm -rf "$sysroot"; mkdir -p "$sysroot"
    old_path=$PATH
    PATH="$fakebin:$PATH"
    stage1_install_run "$sysroot" "$CONFIG" >"$tmpdir/exec.out" 2>"$tmpdir/exec.err"; st=$?
    PATH=$old_path
    assert_return_ok "non-dry-run wrapper returns 0" "$st"

    [ -f "$sysroot/usr/local/sbin/reinstall.sh" ] \
        && pass "wrapper copied reinstall.sh" \
        || fail "wrapper copied reinstall.sh" "missing $sysroot/usr/local/sbin/reinstall.sh"
    [ -x "$sysroot/usr/local/sbin/reinstall.sh" ] \
        && pass "wrapper made reinstall.sh executable" \
        || fail "wrapper made reinstall.sh executable" "not executable"
    [ -x "$sysroot/usr/local/sbin/reinstall-adapter" ] \
        && pass "wrapper made reinstall-adapter executable" \
        || fail "wrapper made reinstall-adapter executable" "not executable"
    [ -f "$sysroot/etc/netinstall/config.json" ] \
        && pass "wrapper copied config.json" \
        || fail "wrapper copied config.json" "missing $sysroot/etc/netinstall/config.json"
    [ -f "$sysroot/etc/local.d/stage1.start" ] \
        && pass "wrapper copied stage1.start" \
        || fail "wrapper copied stage1.start" "missing $sysroot/etc/local.d/stage1.start"
    [ -x "$sysroot/etc/local.d/stage1.start" ] \
        && pass "wrapper made stage1.start executable" \
        || fail "wrapper made stage1.start executable" "not executable"

    assert_contains "wrapper invoked patch against the injected reinstall.sh" \
        "patch -p2 -i" "$(cat "$fakelog")"
    assert_contains "wrapper invoked chroot rc-update add local" \
        "chroot $sysroot /sbin/rc-update add local default" "$(cat "$fakelog")"

    rm -rf "$fakebin"
}

if type stage1_install_plan >/dev/null 2>&1 && type stage1_install_run >/dev/null 2>&1; then
    pass "stage1-install defines stage1_install_plan and stage1_install_run"
    run_tests
else
    fail "stage1-install defines stage1_install_plan and stage1_install_run" \
        "stage1_install_plan/stage1_install_run undefined; behavioural tests skipped"
fi

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
