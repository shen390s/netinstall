#!/bin/sh
# Unit tests for the Rescue & Observability component (task 2.5 —
# stage0-netboot-image).
#
# Exercises the testable core of the `rescue` script and asserts:
#   1. rescue_log writes a progress/error line to the (overridden) serial device;
#   2. the HTTP log command targets the configured port and serves the log dir;
#   3. the dropbear command uses key auth only (no password auth) and generates
#      host keys;
#   4. a provided SSH public key is written into authorized_keys;
#   5. DRY_RUN=1 performs no actual dropbear/httpd execution;
#   6. rescue_enter execs a shell.
#
# dropbear note (verified against upstream svr-runopts.c): -p is the LISTEN
# PORT, -s disables password authentication, -g disables root password auth,
# -D <dir> points dropbear at the directory containing `authorized_keys`, and
# -r/-R reference/create host keys. Password auth is therefore disabled via -s,
# and key auth is supplied via -D <dir> + -r <hostkeys>.
#
# Run with: sh tests/unit/test-rescue.sh

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/../.." && pwd)
RESCUE="$REPO_ROOT/stage0/payload/usr/local/sbin/rescue"

# Source the script under test. (RED phase: this file does not exist yet.)
. "$RESCUE"

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

# ---------------------------------------------------------------------------
# All functions the component must expose.
# ---------------------------------------------------------------------------
for fn in rescue_log rescue_http_command rescue_start_http \
          rescue_dropbear_command rescue_start_ssh rescue_hostkey_commands \
          rescue_write_authorized_keys rescue_setup_ssh rescue_enter; do
    type "$fn" >/dev/null 2>&1
    assert_return_ok "rescue defines $fn" "$?"
done

tmpdir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# (1) rescue_log writes the message to the (overridden) serial device.
# ---------------------------------------------------------------------------
serial="$tmpdir/serial"
RESCUE_SERIAL_DEV="$serial"; export RESCUE_SERIAL_DEV
rescue_log "stage0: boot reached"; st=$?
assert_return_ok "rescue_log returns 0" "$st"
assert_contains "rescue_log writes message to serial device" \
    "stage0: boot reached" "$(cat "$serial")"

# An empty message is rejected rather than emitting an empty line.
: > "$serial"
rescue_log "" 2>/dev/null; st=$?
assert_return_fail "rescue_log rejects empty message" "$st"
assert_eq "rescue_log empty message writes nothing to serial" "" "$(cat "$serial")"

# ---------------------------------------------------------------------------
# (2) The HTTP log command serves the log directory on the configured port.
# ---------------------------------------------------------------------------
http_cmd=$(rescue_http_command 8080 "$tmpdir/logs")
assert_contains "HTTP log command names the httpd binary" "httpd" "$http_cmd"
assert_contains "HTTP log command targets the configured port" "8080" "$http_cmd"
assert_contains "HTTP log command serves the log directory" "$tmpdir/logs" "$http_cmd"
assert_contains "HTTP log command runs in foreground (-f)" "-f" "$http_cmd"

# ---------------------------------------------------------------------------
# (3) dropbear command: key auth only + generated host keys.
# ---------------------------------------------------------------------------
ssh_cmd=$(rescue_dropbear_command 22 "$tmpdir/ssh" "$tmpdir/authkeys")
assert_contains "dropbear command names the dropbear binary" "dropbear" "$ssh_cmd"
assert_contains "dropbear listens on the configured port (-p)" "-p" "$ssh_cmd"
assert_contains "dropbear port value is 22" "22" "$ssh_cmd"
assert_contains "dropbear disables password auth (-s)" "-s" "$ssh_cmd"
assert_contains "dropbear uses the authorized_keys directory (-D)" "-D" "$ssh_cmd"
assert_contains "dropbear authorized-key path is the configured dir" "$tmpdir/authkeys" "$ssh_cmd"
assert_contains "dropbear creates host keys as required (-R)" "-R" "$ssh_cmd"
assert_contains "dropbear references an ed25519 host key (-r)" "dropbear_ed25519_host_key" "$ssh_cmd"
assert_contains "dropbear references a rsa host key (-r)" "dropbear_rsa_host_key" "$ssh_cmd"
assert_not_contains "dropbear does not allow blank passwords (-B)" "-B" "$ssh_cmd"
assert_not_contains "dropbear does not enable multi-auth method (-t)" "-t" "$ssh_cmd"

# ---------------------------------------------------------------------------
# (4) A provided SSH public key is written into authorized_keys.
# ---------------------------------------------------------------------------
pubkey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample ops@deploy"

rescue_write_authorized_keys "$pubkey" "$tmpdir/authkeys" 2>/dev/null; st=$?
assert_return_ok "rescue_write_authorized_keys returns 0" "$st"
assert_eq "authorized_keys contains the provided key" \
    "$pubkey" "$(cat "$tmpdir/authkeys/authorized_keys")"

# rescue_setup_ssh also writes the key and generates host-key commands.
DRY_RUN=1; export DRY_RUN
setup_out=$(rescue_setup_ssh "$pubkey" "$tmpdir/ssh" "$tmpdir/authkeys2")
assert_eq "rescue_setup_ssh writes authorized_keys" \
    "$pubkey" "$(cat "$tmpdir/authkeys2/authorized_keys")"
assert_contains "rescue_setup_ssh generates an ed25519 host key" "ed25519" "$setup_out"
assert_contains "rescue_setup_ssh generates a rsa host key" "rsa" "$setup_out"
assert_contains "rescue_setup_ssh uses dropbearkey to generate host keys" \
    "dropbearkey" "$setup_out"

# An empty public key is rejected.
rescue_write_authorized_keys "" "$tmpdir/authkeys3" 2>/dev/null; st=$?
assert_return_fail "rescue_write_authorized_keys rejects empty key" "$st"

# ---------------------------------------------------------------------------
# (5) DRY_RUN=1 performs no actual dropbear/httpd execution.
# ---------------------------------------------------------------------------
cat > "$tmpdir/dropbear-stub" <<EOF
#!/bin/sh
echo ran > "$tmpdir/dropbear-ran"
EOF
cat > "$tmpdir/httpd-stub" <<EOF
#!/bin/sh
echo ran > "$tmpdir/httpd-ran"
EOF
chmod +x "$tmpdir/dropbear-stub" "$tmpdir/httpd-stub"

RESCUE_DROPBEAR="$tmpdir/dropbear-stub"; export RESCUE_DROPBEAR
RESCUE_HTTPD="$tmpdir/httpd-stub"; export RESCUE_HTTPD

DRY_RUN=1; export DRY_RUN
rescue_start_ssh 22 "$tmpdir/ssh" "$tmpdir/authkeys" >/dev/null 2>&1
rescue_start_http 8080 "$tmpdir/logs" >/dev/null 2>&1
if [ -e "$tmpdir/dropbear-ran" ] || [ -e "$tmpdir/httpd-ran" ]; then
    fail "DRY_RUN=1 executes nothing" "a stub ran despite DRY_RUN=1"
else
    pass "DRY_RUN=1 executes nothing"
fi

# Without DRY_RUN, the wrappers actually execute the generated commands.
DRY_RUN=0; export DRY_RUN
rescue_start_http 8080 "$tmpdir/logs" >/dev/null 2>&1
if [ -e "$tmpdir/httpd-ran" ]; then
    pass "rescue_start_http executes httpd when not dry-run"
else
    fail "rescue_start_http executes httpd when not dry-run" "httpd stub did not run"
fi

# ---------------------------------------------------------------------------
# (6) rescue_enter execs a shell.
# ---------------------------------------------------------------------------
cat > "$tmpdir/shell-stub" <<EOF
#!/bin/sh
echo SHELL_EXECED
EOF
chmod +x "$tmpdir/shell-stub"

RESCUE_SHELL="$tmpdir/shell-stub"; export RESCUE_SHELL
entered=$(rescue_enter 2>/dev/null)
assert_eq "rescue_enter execs the shell" "SHELL_EXECED" "$entered"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
