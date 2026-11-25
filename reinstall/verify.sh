#!/bin/sh
# Verify the pinned reinstall bundle (task 1.2).
#
# Checks:
#   1. the three vendored files exist
#   2. each file's sha256 matches the recorded checksum in SHA256SUMS
#   3. the recorded version is a 40-char commit SHA
#   4. vendored reinstall.sh is non-trivial (contains the `confhome=` marker)
#
# Usage: sh verify.sh   (run from anywhere; it resolves its own directory)
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
VERSION_FILE="$DIR/VERSION"
SUMS_FILE="$DIR/SHA256SUMS"
FILES="reinstall.sh trans.sh initrd-network.sh"

fail=0

echo "== reinstall bundle verification =="
echo "dir: $DIR"

# 1. files exist
for f in $FILES; do
    if [ -f "$DIR/$f" ]; then
        echo "PASS: $f present"
    else
        echo "FAIL: $f missing"
        fail=1
    fi
done

# 3. version is a 40-char commit SHA
if [ ! -f "$VERSION_FILE" ]; then
    echo "FAIL: VERSION file missing"
    fail=1
else
    ver=$(tr -d '[:space:]' < "$VERSION_FILE")
    if printf '%s' "$ver" | grep -Eq '^[0-9a-fA-F]{40}$'; then
        echo "PASS: VERSION is 40-char SHA ($ver)"
    else
        echo "FAIL: VERSION is not a 40-char commit SHA: '$ver'"
        fail=1
    fi
fi

# 2. checksums match
if [ ! -f "$SUMS_FILE" ]; then
    echo "FAIL: SHA256SUMS file missing"
    fail=1
else
    for f in $FILES; do
        recorded=$(awk -v fn="$f" '$2 == fn { print $1 }' "$SUMS_FILE")
        if [ -z "$recorded" ]; then
            echo "FAIL: no recorded checksum for $f"
            fail=1
            continue
        fi
        actual=$(sha256sum "$DIR/$f" | awk '{print $1}')
        if [ "$actual" = "$recorded" ]; then
            echo "PASS: $f sha256 matches"
        else
            echo "FAIL: $f sha256 mismatch (recorded=$recorded actual=$actual)"
            fail=1
        fi
    done
fi

# 4. reinstall.sh non-trivial
if [ -f "$DIR/reinstall.sh" ]; then
    if grep -q 'confhome=' "$DIR/reinstall.sh"; then
        echo "PASS: reinstall.sh contains 'confhome=' marker"
    else
        echo "FAIL: reinstall.sh missing 'confhome=' marker"
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
