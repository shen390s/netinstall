#!/bin/sh
# Unit tests for the Reinstall Adapter (task 2.2 — stage0-netboot-image).
#
# Exercises the config -> reinstall argv/env mapping plus the proxy-env patch:
#   1. argv mapping for linux/windows/dd categories matches the os-catalog
#   2. unsupported OS selections are rejected (non-zero, no argv)
#   3. credentials/access flags map to --username/--password/--ssh-key/--ssh-port
#      and --web-port/--frpc-config
#   4. the proxy env block matches proxy.sh `proxy_exports` output
#   5. reinstall/patches/proxy-env.patch applies cleanly to the pinned
#      reinstall/reinstall.sh and injects the five proxy exports
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-adapter.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)

ADAPTER="$REPO_ROOT/stage0/payload/usr/local/sbin/reinstall-adapter"
ADAPTER_OS_CATALOG="$REPO_ROOT/stage0/payload/etc/netinstall/os-catalog.json"
ADAPTER_PROXY_LIB="$REPO_ROOT/stage0/payload/usr/local/sbin/lib/proxy.sh"
PATCH_FILE="$REPO_ROOT/reinstall/patches/proxy-env.patch"
PATCH_TARGET="$REPO_ROOT/reinstall/reinstall.sh"

export ADAPTER_OS_CATALOG ADAPTER_PROXY_LIB

# Source the proxy helper and the adapter under test. (RED phase: the adapter
# does not exist yet, so `map_config_to_reinstall` stays undefined.)
. "$ADAPTER_PROXY_LIB"
. "$ADAPTER"

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

# map_config_to_reinstall <config.json> -> capture (argv_line, env_block)
adapter_argv() { map_config_to_reinstall "$1" | sed -n '1p'; }
adapter_env()  { map_config_to_reinstall "$1" | sed '1d'; }

type map_config_to_reinstall >/dev/null 2>&1
assert_return_ok "adapter defines map_config_to_reinstall" "$?"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

tmpdir=$(mktemp -d) || exit 1

f_linux_debian="$tmpdir/linux-debian.json"
f_ubuntu_minimal="$tmpdir/ubuntu-minimal.json"
f_arch="$tmpdir/arch.json"
f_windows="$tmpdir/windows.json"
f_dd="$tmpdir/dd.json"
f_unsupported="$tmpdir/unsupported.json"
f_creds="$tmpdir/creds.json"
f_proxy="$tmpdir/proxy.json"

cat > "$f_linux_debian" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"}}
EOF

cat > "$f_ubuntu_minimal" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"ubuntu","version":"24.04-minimal","extra":{}},"network":{"mode":"dhcp"}}
EOF

cat > "$f_arch" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"arch","version":"latest","extra":{}},"network":{"mode":"dhcp"}}
EOF

cat > "$f_windows" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"windows","distro":"windows","version":"any","extra":{"imageName":"Windows 11 Pro","lang":"en-us"}},"network":{"mode":"dhcp"}}
EOF

cat > "$f_dd" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"dd","distro":"dd","version":"any","extra":{"img":"https://example.com/alpine.raw"}},"network":{"mode":"dhcp"}}
EOF

cat > "$f_unsupported" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"nixos","version":"24.05","extra":{}},"network":{"mode":"dhcp"}}
EOF

cat > "$f_creds" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"credentials":{"username":"operator","password":"s3cr3t","sshKey":"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample","sshPort":2222},"access":{"webPort":5666,"frpcConfig":"/etc/frpc.ini"},"network":{"mode":"dhcp"}}
EOF

cat > "$f_proxy" <<'EOF'
{"targetDisk":{"id":"/dev/disk/by-id/ata-TEST_1","model":"TestDisk","serial":"SN1","size":"1000"},"os":{"category":"linux","distro":"debian","version":"12","extra":{}},"network":{"mode":"dhcp"},"proxy":{"http":"http://proxy.example:8080","https":"http://proxy.example:8080","all":"socks5://proxy.example:1080","noProxy":["localhost","127.0.0.1"],"githubProxy":"https://ghproxy.example.com"}}
EOF

# ---------------------------------------------------------------------------
# 1. argv mapping (linux / windows / dd)
# ---------------------------------------------------------------------------

# map_config_to_reinstall must return 0 on the success path even when no proxy
# is configured (proxy_exports' trailing empty `[ -n ... ] && printf` would
# otherwise leak a non-zero status). Assert it directly, not through a pipeline.
map_config_to_reinstall "$f_linux_debian" > "$tmpdir/map.out" 2>/dev/null; st=$?
assert_return_ok "map(debian 12) returns 0" "$st"
argv=$(sed -n '1p' "$tmpdir/map.out")
assert_eq "map(debian 12) argv" "debian 12" "$argv"

argv=$(adapter_argv "$f_ubuntu_minimal")
assert_eq "map(ubuntu 24.04-minimal) argv" "ubuntu 24.04 --minimal" "$argv"

argv=$(adapter_argv "$f_arch")
assert_eq "map(arch) argv" "arch" "$argv"

argv=$(adapter_argv "$f_windows")
assert_eq "map(windows) argv" "windows --image-name 'Windows 11 Pro' --lang en-us" "$argv"

argv=$(adapter_argv "$f_dd")
assert_eq "map(dd) argv" "dd --img https://example.com/alpine.raw" "$argv"

# ---------------------------------------------------------------------------
# 2. unsupported OS
# ---------------------------------------------------------------------------

unsupported_out=$(map_config_to_reinstall "$f_unsupported" 2>"$tmpdir/unsupported.err"); st=$?
assert_return_fail "unsupported OS returns non-zero" "$st"
assert_eq "unsupported OS emits no argv" "" "$unsupported_out"
assert_contains "unsupported OS reports selection" "unsupported" "$(cat "$tmpdir/unsupported.err")"

# ---------------------------------------------------------------------------
# 3. credentials / access flags
# ---------------------------------------------------------------------------

argv=$(adapter_argv "$f_creds")
assert_eq "credentials/access argv" \
    "debian 12 --username operator --password s3cr3t --ssh-key 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample' --ssh-port 2222 --web-port 5666 --frpc-config /etc/frpc.ini" \
    "$argv"

# ---------------------------------------------------------------------------
# 4. proxy env block
# ---------------------------------------------------------------------------

proxy_env_expected=$(proxy_exports \
    "http://proxy.example:8080" "http://proxy.example:8080" \
    "socks5://proxy.example:1080" "https://ghproxy.example.com" \
    "localhost" "127.0.0.1")

argv=$(adapter_argv "$f_proxy")
assert_eq "map(proxy) argv" "debian 12" "$argv"

proxy_env_actual=$(adapter_env "$f_proxy")
assert_eq "proxy env block matches proxy.sh output" "$proxy_env_expected" "$proxy_env_actual"

# ---------------------------------------------------------------------------
# 5. proxy-env patch
# ---------------------------------------------------------------------------

if [ ! -f "$PATCH_FILE" ]; then
    fail "patch file exists" "missing $PATCH_FILE"
elif [ ! -f "$PATCH_TARGET" ]; then
    fail "patch target exists" "missing $PATCH_TARGET"
else
    patch_tmp=$(mktemp -d)
    mkdir -p "$patch_tmp/reinstall"
    cp "$PATCH_TARGET" "$patch_tmp/reinstall/reinstall.sh"

    # (a) applies cleanly (dry-run) to the pinned reinstall.sh
    patch -d "$patch_tmp" -p1 --dry-run < "$PATCH_FILE" >/dev/null 2>&1
    assert_return_ok "proxy-env.patch applies cleanly (dry-run)" "$?"

    # (b) real apply succeeds
    patch -d "$patch_tmp" -p1 < "$PATCH_FILE" >/dev/null 2>&1
    assert_return_ok "proxy-env.patch applies" "$?"

    # (c) the injected init hook now exports the five proxy vars, after
    #     MAC_ADDRESS=1 and before `return`
    hook=$(awk '/MAC_ADDRESS=1/{f=1} f{print} f && /return/{exit}' \
        "$patch_tmp/reinstall/reinstall.sh")
    for var in http_proxy https_proxy all_proxy no_proxy github_proxy; do
        if printf '%s\n' "$hook" | grep -qF "export $var=\$$var"; then
            pass "init hook exports $var"
        else
            fail "init hook exports $var" "missing export $var in init hook"
        fi
    done
    assert_contains "init hook keeps MAC_ADDRESS=1" "MAC_ADDRESS=1" "$hook"

    # (d) the patch changes only the injected lines (5 added, 0 removed)
    diff "$PATCH_TARGET" "$patch_tmp/reinstall/reinstall.sh" > "$patch_tmp/patch.diff" 2>&1 || true
    added=$(grep -c '^>' "$patch_tmp/patch.diff" || true)
    removed=$(grep -c '^<' "$patch_tmp/patch.diff" || true)
    assert_eq "patch adds exactly 5 lines" "5" "$added"
    assert_eq "patch removes no lines" "0" "$removed"

    rm -rf "$patch_tmp"
fi

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
