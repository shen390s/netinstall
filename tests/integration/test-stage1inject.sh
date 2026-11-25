#!/bin/sh
# Integration test: stage1 artifact injection (task 4.2 — stage0-netboot-image).
#
# Runs the REAL stage1-install (not dry-run) against a mounted sysroot and
# asserts the deployment payload lands at the exact paths with the right
# executable bits (requirement 7.1):
#   reinstall bundle         -> <sysroot>/usr/local/sbin/{reinstall.sh,trans.sh,initrd-network.sh}
#   reinstall-adapter        -> <sysroot>/usr/local/sbin/reinstall-adapter  (+x)
#   DeploymentConfig         -> <sysroot>/etc/netinstall/config.json
#   proxy profile            -> <sysroot>/etc/profile.d/99-proxy.sh
#   firstboot hook           -> <sysroot>/etc/local.d/stage1.start         (+x)
# and that the OpenRC `local` service is enabled (rc-update ran for real, so
# <sysroot>/etc/runlevels/default/local exists) and that the injected
# reinstall.sh has the proxy patch applied.
#
# The sysroot is a disposable tmpfs mount. A tmpfs (rather than an ext4 loop
# device) is used because the build container carries no ext filesystem tool
# (only busybox mkfs.vfat, which cannot hold exec bits or symlinks), while the
# real chroot step needs a POSIX filesystem. The chroot target is a minimal
# copy of the container's own OpenRC (rc-update + its musl/OpenRC libraries +
# /etc/init.d/local + /etc/rc.conf + runlevel dirs) so `chroot ... rc-update`
# succeeds for real.
#
# SKIPs (exit 3, not fail) when root, mount, chroot, or the chroot source files
# are unavailable. Requires running inside the privileged build container.
# Invoke with: sh tests/integration/test-stage1inject.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
STAGE1_INSTALL="$REPO_ROOT/stage0/payload/usr/local/sbin/stage1-install"
ADAPTER="$REPO_ROOT/stage0/payload/usr/local/sbin/reinstall-adapter"

# --- prerequisite gate (skip, not fail) -------------------------------------
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    printf 'SKIP: requires root for mount/chroot\n'
    exit 3
fi
for tool in mount umount chroot patch; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: %s is unavailable\n' "$tool"; exit 3; }
done
# The chroot step needs the container's OpenRC runtime to copy in.
[ -x /sbin/rc-update ] || { printf 'SKIP: /sbin/rc-update is unavailable\n'; exit 3; }
[ -x /etc/init.d/local ] || { printf 'SKIP: /etc/init.d/local is unavailable\n'; exit 3; }
[ -r "$STAGE1_INSTALL" ] || { printf 'SKIP: stage1-install missing\n'; exit 3; }

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n       %s\n' "$1" "$2"; }

assert_return_ok() { # name status
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "expected status 0 got $2"; fi
}
assert_file() { # name path
    if [ -f "$2" ]; then pass "$1"; else fail "$1" "missing $2"; fi
}
assert_exec() { # name path
    if [ -x "$2" ]; then pass "$1"; else fail "$1" "not executable: $2"; fi
}

tmpdir=$(mktemp -d) || exit 1
sysroot="$tmpdir/sysroot"
mkdir -p "$sysroot"
mount -t tmpfs tmpfs "$sysroot" 2>"$tmpdir/mount.err" \
    || { printf 'SKIP: cannot mount tmpfs (%s)\n' "$(cat "$tmpdir/mount.err")"; rm -rf "$tmpdir"; exit 3; }
mounted=1

cleanup() {
    [ "${mounted:-0}" = 1 ] && umount "$sysroot" 2>/dev/null
    rm -rf "$tmpdir"
}
trap cleanup EXIT HUP INT TERM

# --- fixture: a minimal chroot-able OpenRC runtime -------------------------
mkdir -p "$sysroot/sbin" "$sysroot/usr/lib" "$sysroot/lib" \
         "$sysroot/etc/init.d" "$sysroot/etc/rc.conf.d" \
         "$sysroot/etc/runlevels/default" "$sysroot/etc/runlevels/sysinit" \
         "$sysroot/etc/runlevels/boot" "$sysroot/etc/runlevels/shutdown" \
         "$sysroot/run/openrc" "$sysroot/etc"
cp /sbin/rc-update "$sysroot/sbin/rc-update"
cp /lib/ld-musl-x86_64.so.1 "$sysroot/lib/ld-musl-x86_64.so.1"
ln -s ld-musl-x86_64.so.1 "$sysroot/lib/libc.musl-x86_64.so.1"
cp /usr/lib/libeinfo.so.1 /usr/lib/librc.so.1 "$sysroot/usr/lib/"
cp /etc/init.d/local "$sysroot/etc/init.d/local"
cp /etc/rc.conf "$sysroot/etc/rc.conf"

CONFIG="$tmpdir/config.json"
cat > "$CONFIG" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"}}
EOF
chmod 600 "$CONFIG"

# --- run the REAL stage1-install command (not dry-run) ---------------------
STAGE1_INSTALL_ROOT="$REPO_ROOT"
STAGE1_INSTALL_ADAPTER="$ADAPTER"
NETINSTALL_CONFIG="$CONFIG"
export STAGE1_INSTALL_ROOT STAGE1_INSTALL_ADAPTER NETINSTALL_CONFIG

sh "$STAGE1_INSTALL" "$sysroot" "$CONFIG" >"$tmpdir/run.out" 2>&1
st=$?
assert_return_ok "stage1-install (real) returns 0" "$st"

# --- verify the injected artifacts -----------------------------------------
assert_file "bundle reinstall.sh lands at usr/local/sbin" "$sysroot/usr/local/sbin/reinstall.sh"
assert_exec "reinstall.sh is executable" "$sysroot/usr/local/sbin/reinstall.sh"
assert_file "bundle trans.sh lands at usr/local/sbin" "$sysroot/usr/local/sbin/trans.sh"
assert_file "bundle initrd-network.sh lands at usr/local/sbin" "$sysroot/usr/local/sbin/initrd-network.sh"
assert_file "adapter lands at usr/local/sbin/reinstall-adapter" "$sysroot/usr/local/sbin/reinstall-adapter"
assert_exec "reinstall-adapter is executable" "$sysroot/usr/local/sbin/reinstall-adapter"
assert_file "config lands at etc/netinstall/config.json" "$sysroot/etc/netinstall/config.json"
assert_file "proxy profile lands at etc/profile.d/99-proxy.sh" "$sysroot/etc/profile.d/99-proxy.sh"
assert_file "firstboot lands at etc/local.d/stage1.start" "$sysroot/etc/local.d/stage1.start"
assert_exec "stage1.start is executable" "$sysroot/etc/local.d/stage1.start"

# The injected reinstall.sh must carry the proxy patch applied by the real run.
if grep -q 'export github_proxy=$github_proxy' "$sysroot/usr/local/sbin/reinstall.sh" 2>/dev/null; then
    pass "injected reinstall.sh has the proxy patch applied"
else
    fail "injected reinstall.sh has the proxy patch applied" "export github_proxy not found"
fi

# OpenRC local service enabled for real by the chroot rc-update step.
if [ -L "$sysroot/etc/runlevels/default/local" ]; then
    pass "OpenRC local service enabled (runlevel default/local symlink)"
else
    fail "OpenRC local service enabled (runlevel default/local symlink)" \
        "missing $sysroot/etc/runlevels/default/local"
fi

# Cleanup + summary (trap also runs, but be explicit).
umount "$sysroot" 2>/dev/null; mounted=0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
