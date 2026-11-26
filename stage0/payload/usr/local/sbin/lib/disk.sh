#!/bin/sh
# disk.sh — disk enumeration, identity, and stable-id helpers (stage0-netboot-image).
#
# Operates on real tool output rather than hardcoded values:
#   - identity (model/serial/size) is parsed from `lsblk -P -d -o NAME,MODEL,SERIAL,SIZE`
#     (KEY="value" pairs). The plain `-o` form separates columns with single spaces and
#     is not reliably parseable when MODEL contains spaces, so the parser consumes the
#     `-P` pair form, which is unambiguous and shell-safe (no eval).
#   - stable ids are resolved from /dev/disk/by-id symlinks (or a test fixture dir).
#
# All functions are POSIX sh (busybox ash compatible); no bashisms.

# disk_parse <line>
# Parse one `lsblk -P -d -o NAME,MODEL,SERIAL,SIZE` line (KEY="value" pairs) and set
# the shell variables name, model, serial, size. Returns 0 on success, 1 on failure.
disk_parse() {
    _line=${1:-}
    [ -n "$_line" ] || return 1
    name=$(printf '%s\n' "$_line" | sed -n 's/^NAME="\([^"]*\)".*/\1/p')
    model=$(printf '%s\n' "$_line" | sed -n 's/.*MODEL="\([^"]*\)".*/\1/p')
    serial=$(printf '%s\n' "$_line" | sed -n 's/.*SERIAL="\([^"]*\)".*/\1/p')
    size=$(printf '%s\n' "$_line" | sed -n 's/.*SIZE="\([^"]*\)".*/\1/p')
    [ -n "$name" ] || return 1
    return 0
}

# disk_enumerate [file]
# Read `lsblk -P -d -o NAME,MODEL,SERIAL,SIZE` output from <file> (or stdin) and emit
# one `name|model|serial|size` line per device. Purely transforms its input.
disk_enumerate() {
    while IFS= read -r _line; do
        case "$_line" in
            '') continue ;;
        esac
        if disk_parse "$_line"; then
            printf '%s|%s|%s|%s\n' "$name" "$model" "$serial" "$size"
        fi
    done < "${1:-/proc/self/fd/0}"
}

# disk_list
# Enumerate all block devices with identity. This is the single side-effecting
# entry point (runs lsblk); the parsing logic above is the testable pure core.
# Writes lsblk output to a temp file (not a pipe) so disk_enumerate reads a
# plain file regardless of the surrounding fd/stdin context.
disk_list() {
    _tmp=${TMPDIR:-/tmp}/disk-list.$$
    lsblk -P -d -o NAME,MODEL,SERIAL,SIZE > "$_tmp" 2>/dev/null
    disk_enumerate "$_tmp"
    rm -f "$_tmp"
}

# disk_by_id_path <model> <serial>
# Form the udev ata-style stable by-id path for a SATA disk from its model and
# serial: /dev/disk/by-id/ata-<MODEL with spaces->underscores>_<SERIAL>.
# (For disks that expose a WWN/EUI/NVMe id, prefer disk_resolve_by_id below.)
disk_by_id_path() {
    _model=${1:-}
    _serial=${2:-}
    if [ -z "$_model" ] || [ -z "$_serial" ]; then
        return 1
    fi
    _id_model=$(printf '%s' "$_model" | tr ' ' '_')
    printf '/dev/disk/by-id/ata-%s_%s\n' "$_id_model" "$_serial"
}

# disk_resolve_by_id <device_name> [by_id_dir]
# Print the first stable by-id symlink path that resolves to <device_name>.
# Scans /dev/disk/by-id by default, or <by_id_dir> when supplied (testable).
# Returns 0 if found, 1 if no by-id link resolves to the device.
disk_resolve_by_id() {
    _dev=${1:-}
    _dir=${2:-/dev/disk/by-id}
    [ -n "$_dev" ] || return 1
    [ -d "$_dir" ] || return 1
    for _link in "$_dir"/*; do
        [ -L "$_link" ] || continue
        _target=$(readlink "$_link") || continue
        case "$_target" in
            *"/$_dev") printf '%s\n' "$_link"; return 0 ;;
        esac
    done
    return 1
}
