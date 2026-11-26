#!/bin/sh
# Unit tests for the Configuration Menu non-interactive core (task 2.1 —
# stage0-netboot-image).
#
# Drives the pure config-assembly/validation/confirmation-gating functions of
# the `menu` script without launching the dialog TUI, and asserts:
#   1. a full set of answers yields a schema-valid DeploymentConfig;
#   2. an unsupported OS selection is rejected;
#   3. a missing/empty target disk is rejected;
#   4. no config is emitted (and a wipe guard is set) when the operator does
#      not confirm the full wipe;
#   5. disk identity fields (model/serial/size) appear in the emitted config;
#   6. dhcp vs static network and proxy fields round-trip correctly.
#
# Run with: sh tests/unit/test-menu.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
SBIN_DIR="$REPO_ROOT/stage0/payload/usr/local/sbin"
LIB_DIR="$SBIN_DIR/lib"
NETINSTALL_DIR="$REPO_ROOT/stage0/payload/etc/netinstall"

# Point the menu core at the checked-in catalog (test seam).
MENU_OS_CATALOG="$NETINSTALL_DIR/os-catalog.json"
export MENU_OS_CATALOG

# Source the disk helper for identity + by-id path, then the menu core.
. "$LIB_DIR/disk.sh"
MENU_TEST_MODE=1
. "$SBIN_DIR/menu"

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

assert_not_contains() { # name needle haystack
    case "$3" in
        *"$2"*) fail "$1" "expected output to NOT contain [$2]" ;;
        *) pass "$1" ;;
    esac
}

assert_balanced_json() { # name json
    _ob=$(printf '%s\n' "$2" | tr -cd '{' | wc -c)
    _cb=$(printf '%s\n' "$2" | tr -cd '}' | wc -c)
    _osq=$(printf '%s\n' "$2" | tr -cd '[' | wc -c)
    _csq=$(printf '%s\n' "$2" | tr -cd ']' | wc -c)
    if [ "$_ob" -eq "$_cb" ] && [ "$_osq" -eq "$_csq" ]; then
        pass "$1"
    else
        fail "$1" "unbalanced JSON: {$_ob vs }$_cb, [$_osq vs ]$_csq"
    fi
}

# ---------------------------------------------------------------------------
# Fixture: disk identity derived from disk.sh (by-id path + model/serial/size).
# ---------------------------------------------------------------------------
DISK_MODEL="Samsung SSD 870 EVO 500GB"
DISK_SERIAL="S6PXNX0R123456"
DISK_SIZE="500107862016"
DISK_ID=$(disk_by_id_path "$DISK_MODEL" "$DISK_SERIAL")

# emit <os_cat> <os_distro> <os_ver> <os_img_name> <os_lang> <os_img> \
#      <user> <pass> <ssh_key> <ssh_port> \
#      <net_mode> <ipv4> <gw> <dns> \
#      <px_http> <px_https> <px_all> <px_no> <px_github> \
#      <wipe>
# Thin wrapper that prepends the constant disk identity and delegates to the
# menu core (20 answers + 4 disk fields = the core's 24-answer signature).
emit() {
    menu_config_emit \
        "$DISK_ID" "$DISK_MODEL" "$DISK_SERIAL" "$DISK_SIZE" \
        "$1" "$2" "$3" "$4" "$5" "$6" \
        "$7" "$8" "$9" "${10}" \
        "${11}" "${12}" "${13}" "${14}" \
        "${15}" "${16}" "${17}" "${18}" "${19}" \
        "${20}"
}

tmpout=$(mktemp) || exit 1
trap 'rm -f "$tmpout"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# (1) Full answers -> schema-valid config; (5) disk identity; (6) static/proxy.
# ---------------------------------------------------------------------------
MENU_WIPE_GUARD=
emit linux debian 12 "" "" "" \
    ops changeme "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample" 22 \
    static 192.168.1.100/24 192.168.1.1 1.1.1.1 \
    http://proxy.example:8080 http://proxy.example:8080 http://proxy.example:8080 "localhost,127.0.0.1" https://ghproxy.example.com \
    yes >"$tmpout" 2>/dev/null
RC=$?
OUT=$(cat "$tmpout")
assert_return_ok "full answers emit returns 0" "$RC"
assert_eq "confirmed wipe sets guard" "confirmed" "$MENU_WIPE_GUARD"

menu_config_validate "$OUT" 2>/dev/null
assert_return_ok "full answers validate against critical schema invariants" "$?"
assert_balanced_json "full config JSON is balanced" "$OUT"

assert_contains "config is a JSON object" '"targetDisk"' "$OUT"
assert_contains "disk by-id id appears" "\"id\":\"$DISK_ID\"" "$OUT"
assert_contains "disk model appears" "\"model\":\"Samsung SSD 870 EVO 500GB\"" "$OUT"
assert_contains "disk serial appears" "\"serial\":\"S6PXNX0R123456\"" "$OUT"
assert_contains "disk size appears" "\"size\":\"500107862016\"" "$OUT"
assert_contains "os category linux" "\"category\":\"linux\"" "$OUT"
assert_contains "os distro" "\"distro\":\"debian\"" "$OUT"
assert_contains "os version" "\"version\":\"12\"" "$OUT"
assert_contains "network mode static" "\"mode\":\"static\"" "$OUT"
assert_contains "static ipv4" "\"ipv4\":\"192.168.1.100/24\"" "$OUT"
assert_contains "static gateway" "\"gateway\":\"192.168.1.1\"" "$OUT"
assert_contains "static dns" "\"dns\":\"1.1.1.1\"" "$OUT"
assert_contains "proxy http" "\"http\":\"http://proxy.example:8080\"" "$OUT"
assert_contains "proxy https" "\"https\":\"http://proxy.example:8080\"" "$OUT"
assert_contains "proxy all" "\"all\":\"http://proxy.example:8080\"" "$OUT"
assert_contains "proxy noProxy array" "\"noProxy\":[\"localhost\",\"127.0.0.1\"]" "$OUT"
assert_contains "proxy githubProxy" "\"githubProxy\":\"https://ghproxy.example.com\"" "$OUT"
assert_contains "credentials username" "\"username\":\"ops\"" "$OUT"
assert_contains "credentials sshKey" "\"sshKey\":\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample\"" "$OUT"
assert_contains "credentials sshPort integer" "\"sshPort\":22" "$OUT"

# ---------------------------------------------------------------------------
# (6) dhcp config round-trips (and omits static-only fields).
# ---------------------------------------------------------------------------
OUT=$(emit linux alpine 3.21 "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes)
RC=$?
assert_return_ok "dhcp answers emit returns 0" "$RC"
assert_contains "dhcp mode" "\"mode\":\"dhcp\"" "$OUT"
assert_not_contains "dhcp omits ipv4" "\"ipv4\"" "$OUT"
assert_not_contains "dhcp omits gateway" "\"gateway\"" "$OUT"
menu_config_validate "$OUT" 2>/dev/null
assert_return_ok "dhcp config validates" "$?"
assert_balanced_json "dhcp config JSON is balanced" "$OUT"

# ---------------------------------------------------------------------------
# (2) Unsupported OS is rejected.
# ---------------------------------------------------------------------------
OUT=$(emit linux mint 21 "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_fail "unsupported OS rejected" "$RC"
assert_eq "unsupported OS emits no config" "" "$OUT"

# Also reject a category outside the closed enum.
OUT=$(emit macos macos 15 "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_fail "os.category outside enum rejected" "$RC"
assert_eq "bad category emits no config" "" "$OUT"

# ---------------------------------------------------------------------------
# (3) Missing/empty disk is rejected.
# ---------------------------------------------------------------------------
OUT=$(menu_config_emit \
    "" "" "" "" \
    linux debian 12 "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_fail "empty disk rejected" "$RC"
assert_eq "empty disk emits no config" "" "$OUT"

# A plain /dev/<name> fallback (disks without a by-id symlink, e.g. a virtual
# disk with no serial) is accepted, with model/serial allowed to be empty.
OUT=$(menu_config_emit \
    /dev/sda "QEMU HARDDISK" "" "134217728" \
    linux debian 12 "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_ok "plain /dev/<name> disk with empty serial accepted" "$RC"
assert_contains "fallback disk id emitted" '"id":"/dev/sda"' "$OUT"
assert_contains "empty serial emitted" '"serial":""' "$OUT"
menu_config_validate "$OUT" 2>/dev/null
assert_return_ok "fallback disk config validates" "$?"

# A non-/dev id is still rejected.
OUT=$(menu_config_emit \
    sda "$DISK_MODEL" "$DISK_SERIAL" "$DISK_SIZE" \
    linux debian 12 "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_fail "non-/dev disk id rejected" "$RC"
assert_eq "non-/dev disk id emits no config" "" "$OUT"

# ---------------------------------------------------------------------------
# Windows / dd per-category `extra` fields round-trip and are validated.
# ---------------------------------------------------------------------------
OUT=$(emit windows windows any "Windows 11 Pro" en-us "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes)
RC=$?
assert_return_ok "windows answers emit returns 0" "$RC"
assert_contains "windows category" "\"category\":\"windows\"" "$OUT"
assert_contains "windows imageName" "\"imageName\":\"Windows 11 Pro\"" "$OUT"
assert_contains "windows lang" "\"lang\":\"en-us\"" "$OUT"
menu_config_validate "$OUT" 2>/dev/null
assert_return_ok "windows config validates" "$?"
assert_balanced_json "windows config JSON is balanced" "$OUT"

OUT=$(emit windows windows any "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_fail "windows missing imageName/lang rejected" "$RC"
assert_eq "windows missing extra emits no config" "" "$OUT"

OUT=$(emit dd dd any "" "" "https://example.com/img.raw" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes)
RC=$?
assert_return_ok "dd answers emit returns 0" "$RC"
assert_contains "dd category" "\"category\":\"dd\"" "$OUT"
assert_contains "dd img" "\"img\":\"https://example.com/img.raw\"" "$OUT"
menu_config_validate "$OUT" 2>/dev/null
assert_return_ok "dd config validates" "$?"
assert_balanced_json "dd config JSON is balanced" "$OUT"

OUT=$(emit dd dd any "" "" "" \
    "" "" "" "" \
    dhcp "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_fail "dd missing img rejected" "$RC"
assert_eq "dd missing img emits no config" "" "$OUT"

# ---------------------------------------------------------------------------
# Invalid network.mode is rejected.
# ---------------------------------------------------------------------------
OUT=$(emit linux debian 12 "" "" "" \
    "" "" "" "" \
    bogus "" "" "" \
    "" "" "" "" "" \
    yes 2>/dev/null)
RC=$?
assert_return_fail "invalid network.mode rejected" "$RC"
assert_eq "invalid network.mode emits no config" "" "$OUT"

# ---------------------------------------------------------------------------
# (4) Unconfirmed wipe -> no config emitted and a guard is set.
# ---------------------------------------------------------------------------
MENU_WIPE_GUARD=
emit linux debian 12 "" "" "" \
    ops changeme "" 22 \
    dhcp "" "" "" \
    "" "" "" "" "" \
    no >"$tmpout" 2>/dev/null
RC=$?
assert_eq "unconfirmed wipe returns 2" "2" "$RC"
assert_eq "unconfirmed wipe emits no config" "" "$(cat "$tmpout")"
assert_eq "unconfirmed wipe sets guard" "unconfirmed" "$MENU_WIPE_GUARD"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
