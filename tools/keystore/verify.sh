#!/usr/bin/env bash
# verify.sh — integrity checks for the release signing material.
#
# 1. local keystore matches the PUBLIC checksum (tools/keystore/checksum.sha256)
# 2. (optional) an APK carries the release certificate:
#        tools/keystore/verify.sh path/to.apk
#
# Exit non-zero on any mismatch. Safe to run any time.

set -euo pipefail
cd "$(dirname "$0")/../.."

KS=android/owntone-release.keystore
PROPS=android/keystore.properties
[[ -f "$KS" && -f "$PROPS" ]] || {
    echo "FAIL: signing material missing — restore from the private escrow repo:"
    echo "      https://github.com/jptrsn/owntone_remote-private (see this README)"
    exit 1
}

expected=$(awk '{print $1}' tools/keystore/checksum.sha256)
actual=$(shasum -a 256 "$KS" | awk '{print $1}')
if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: keystore checksum mismatch"
    echo "  expected $expected"
    echo "  actual   $actual"
    exit 1
fi
echo "ok: keystore matches public checksum"

if [[ $# -ge 1 ]]; then
    apk="$1"
    APKSIGNER="${APKSIGNER:-}"
    if [[ -z "$APKSIGNER" ]]; then
        APKSIGNER=$(ls -d "$HOME/Library/Android/sdk/build-tools"/*/apksigner 2>/dev/null | tail -1) || true
    fi
    [[ -x "${APKSIGNER:-}" ]] || APKSIGNER=$(command -v apksigner || true)
    [[ -n "${APKSIGNER:-}" ]] || { echo "FAIL: apksigner not found (set APKSIGNER=)"; exit 1; }

    apk_cert=$("$APKSIGNER" verify --print-certs "$apk" 2>/dev/null | awk '/certificate SHA-256 digest/{print $NF}' | tr 'A-Z' 'a-z')
    sp=$(grep '^storePassword=' "$PROPS" | cut -d= -f2-)
    # JDK 21 -v prints "        SHA256: <colon-hex>" (the dash-fingerprint
    # form is pre-17; grep both shapes).
    ks_cert=$(keytool -list -v -keystore "$KS" -storepass "$sp" -alias owntone-remote 2>/dev/null \
        | awk '/SHA256/{print $NF; exit}' | tr -d ':' | tr 'A-Z' 'a-z')

    if [[ -z "$apk_cert" || -z "$ks_cert" ]]; then
        echo "FAIL: could not read certificates (apk=$apk_cert ks=$ks_cert)"
        exit 1
    fi
    if [[ "$apk_cert" == "$ks_cert" ]]; then
        echo "ok: $apk is signed by the release key"
    else
        echo "FAIL: $apk is NOT signed by the release key"
        echo "  apk      $apk_cert"
        echo "  keystore $ks_cert"
        exit 1
    fi
fi
