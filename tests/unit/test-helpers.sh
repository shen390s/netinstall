#!/bin/sh
# Unit tests for the shared helper libraries (task 1.4 — stage0-netboot-image).
#
# Exercises the three pure helper libs under stage0/payload/usr/local/sbin/lib/:
#   - net.sh:   network bring-up command generation (DHCP vs static)
#   - disk.sh:  lsblk output parsing (model/serial/size), stable by-id path
#   - proxy.sh: proxy env construction (exports, no_proxy join, github rewrite)
#
# Runs under any POSIX sh. Invoke with: sh tests/unit/test-helpers.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
LIB_DIR="$REPO_ROOT/stage0/payload/usr/local/sbin/lib"

# Source the libraries under test. (RED phase: these files do not exist yet.)
. "$LIB_DIR/net.sh"
. "$LIB_DIR/disk.sh"
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

# ---------------------------------------------------------------------------
# net.sh
# ---------------------------------------------------------------------------

net_dhcp_expected=$(cat <<'EOF'
ip link set eth0 up
udhcpc -i eth0 -f -q -n
EOF
)

net_static_expected=$(cat <<'EOF'
ip addr add 192.168.1.100/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.1.1
echo "nameserver 1.1.1.1" > /etc/resolv.conf
EOF
)

net_dhcp=$(net_commands eth0 dhcp); st=$?
assert_return_ok "net_commands(dhcp) returns 0" "$st"
assert_eq "net_commands(dhcp) generates DHCP bring-up" "$net_dhcp_expected" "$net_dhcp"

net_static=$(net_commands eth0 static 192.168.1.100/24 192.168.1.1 1.1.1.1); st=$?
assert_return_ok "net_commands(static) returns 0" "$st"
assert_eq "net_commands(static) generates static bring-up" "$net_static_expected" "$net_static"

net_static_nodns=$(net_commands eth0 static 192.168.1.100/24 192.168.1.1); st=$?
assert_return_ok "net_commands(static, no dns) returns 0" "$st"
case "$net_static_nodns" in
    *"nameserver"*) fail "net_commands(static, no dns) omits resolv.conf line" \
        "unexpected nameserver line in [$net_static_nodns]" ;;
    *) pass "net_commands(static, no dns) omits resolv.conf line" ;;
esac

net_static_missing=$(net_commands eth0 static 2>/dev/null); st=$?
assert_return_fail "net_commands(static, missing ipv4/gateway) fails" "$st"
assert_eq "net_commands(static, missing ipv4/gateway) emits nothing" "" "$net_static_missing"

net_badmode=$(net_commands eth0 bogus 2>/dev/null); st=$?
assert_return_fail "net_commands(unknown mode) fails" "$st"
assert_eq "net_commands(unknown mode) emits nothing" "" "$net_badmode"

# ---------------------------------------------------------------------------
# disk.sh
# ---------------------------------------------------------------------------

# lsblk -P output carries NAME/MODEL/SERIAL/SIZE as unambiguous KEY="value"
# pairs; the plain -o form separates columns by single spaces and is not
# reliably parseable when MODEL contains spaces, so the parser consumes -P.
sda_pairs='NAME="sda" MODEL="Samsung SSD 870 EVO 500GB" SERIAL="S6PXNX0R123456" SIZE="500107862016"'
nvme_pairs='NAME="nvme0n1" MODEL="Samsung SSD 970 EVO 500GB" SERIAL="S465NX0M123456" SIZE="1000204886016"'
empty_pairs='NAME="loop0" MODEL="" SERIAL="" SIZE="0B"'

name='' model='' serial='' size=''
disk_parse "$sda_pairs"; st=$?
assert_return_ok "disk_parse returns 0" "$st"
assert_eq "disk_parse extracts name" "sda" "$name"
assert_eq "disk_parse extracts model" "Samsung SSD 870 EVO 500GB" "$model"
assert_eq "disk_parse extracts serial" "S6PXNX0R123456" "$serial"
assert_eq "disk_parse extracts size" "500107862016" "$size"

bid=$(disk_by_id_path "$model" "$serial")
assert_eq "disk_by_id_path forms stable ata by-id path" \
    "/dev/disk/by-id/ata-Samsung_SSD_870_EVO_500GB_S6PXNX0R123456" "$bid"

name='' model='' serial='' size=''
disk_parse "$empty_pairs"; st=$?
assert_return_ok "disk_parse accepts empty model/serial" "$st"
assert_eq "disk_parse empty-pairs name" "loop0" "$name"
assert_eq "disk_parse empty-pairs model" "" "$model"
assert_eq "disk_parse empty-pairs serial" "" "$serial"
assert_eq "disk_parse empty-pairs size" "0B" "$size"

# disk_enumerate reads lsblk -P output (header-free) and emits identity lines.
tmpdir=$(mktemp -d) || exit 1
fixture="$tmpdir/lsblk.txt"
{
    printf '%s\n' "$sda_pairs"
    printf '%s\n' "$nvme_pairs"
    printf '%s\n' "$empty_pairs"
} > "$fixture"

enumerated_expected=$(cat <<'EOF'
sda|Samsung SSD 870 EVO 500GB|S6PXNX0R123456|500107862016
nvme0n1|Samsung SSD 970 EVO 500GB|S465NX0M123456|1000204886016
loop0|||0B
EOF
)

enumerated=$(disk_enumerate "$fixture"); st=$?
assert_return_ok "disk_enumerate returns 0" "$st"
assert_eq "disk_enumerate lists identity per disk" "$enumerated_expected" "$enumerated"

# disk_resolve_by_id maps a device name to its stable by-id symlink path.
ln -s ../../sda "$tmpdir/ata-Samsung_SSD_870_EVO_500GB_S6PXNX0R123456"
ln -s ../../sdb "$tmpdir/ata-WDC_WD10EZEX-00WN4A0_WD-WCC4N0TEST"
resolved=$(disk_resolve_by_id sda "$tmpdir"); st=$?
assert_return_ok "disk_resolve_by_id returns 0" "$st"
assert_eq "disk_resolve_by_id maps sda to by-id path" \
    "$tmpdir/ata-Samsung_SSD_870_EVO_500GB_S6PXNX0R123456" "$resolved"

resolved=$(disk_resolve_by_id sdb "$tmpdir"); st=$?
assert_return_ok "disk_resolve_by_id returns 0 (sdb)" "$st"
assert_eq "disk_resolve_by_id maps sdb to by-id path" \
    "$tmpdir/ata-WDC_WD10EZEX-00WN4A0_WD-WCC4N0TEST" "$resolved"

missing=$(disk_resolve_by_id sdc "$tmpdir" 2>/dev/null); st=$?
assert_return_fail "disk_resolve_by_id unknown device fails" "$st"
assert_eq "disk_resolve_by_id unknown device emits nothing" "" "$missing"

rm -rf "$tmpdir"

# ---------------------------------------------------------------------------
# proxy.sh
# ---------------------------------------------------------------------------

proxy_export_expected=$(cat <<'EOF'
export http_proxy=http://proxy.example:8080
export https_proxy=http://proxy.example:8080
export all_proxy=http://proxy.example:8080
export no_proxy=localhost,127.0.0.1
export github_proxy=https://ghproxy.example.com
EOF
)

proxy_out=$(proxy_exports "http://proxy.example:8080" "http://proxy.example:8080" \
    "http://proxy.example:8080" "https://ghproxy.example.com" "localhost" "127.0.0.1")
assert_eq "proxy_exports emits all five proxy vars" "$proxy_export_expected" "$proxy_out"

proxy_empty=$(proxy_exports "" "" "" "")
assert_eq "proxy_exports with no proxy emits nothing" "" "$proxy_empty"

joined=$(proxy_join_no_proxy "localhost" "127.0.0.1" "::1" ".example.com")
assert_eq "proxy_join_no_proxy joins bypass list with commas" \
    "localhost,127.0.0.1,::1,.example.com" "$joined"

joined_empty=$(proxy_join_no_proxy "" "")
assert_eq "proxy_join_no_proxy ignores empty hosts" "" "$joined_empty"

rewritten=$(proxy_github_rewrite \
    "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" \
    "https://ghproxy.example.com")
assert_eq "proxy_github_rewrite prefixes raw.githubusercontent URLs" \
    "https://ghproxy.example.com/bin456789/reinstall/main/reinstall.sh" "$rewritten"

untouched=$(proxy_github_rewrite "https://example.com/file" "https://ghproxy.example.com")
assert_eq "proxy_github_rewrite leaves non-GitHub URLs untouched" \
    "https://example.com/file" "$untouched"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
