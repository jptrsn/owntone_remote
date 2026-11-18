#!/usr/bin/env bash
#
# release.sh — Gate, build, tag, and publish OwnTone Remote to GitHub releases.
#
# The distribution channel for this project is GitHub releases + Obtainium
# (user decision 2026-11-16). Since 2026-11-18 release APKs are signed with
# a DEDICATED keystore (android/owntone-release.keystore, gitignored;
# escrow + restore: tools/keystore/README.md) — this script REFUSES to
# publish debug-signed or foreign-signed APKs (keystore preflight + cert
# check). Emergency override ALLOW_DEBUG_SIGN=1 exists for disaster
# recovery only and says the quiet part out loud.
#
# Prerequisites:
#   - gh CLI installed and authenticated (gh auth login) with access to
#     jptrsn/owntone_remote
#   - flutter, dart, git on PATH (host should match the CI pin in
#     .github/workflows/gates.yml — the script warns on drift)
#   - On main, at origin/main. Under GitFlow (AGENTS § Branching & CI) main
#     receives only release/v* and hotfix/* merges whose PR carried the
#     gates as a required check — the gates already ran on the release
#     branch (RC) and on the PR; the tag push re-runs them as the
#     published-artifact cross-check)
#   - Version already bumped in pubspec.yaml — on the release/v* branch,
#     together with docs/RELEASE-NOTES.md (both land on main via the
#     release PR; after this script publishes, merge main back to develop)
#
# Usage:
#   ./release.sh            # full gate + build + tag + publish
#   ./release.sh --dry-run  # gates + build + preview only; pushes nothing
#
# Release notes default to docs/RELEASE-NOTES.md (the canonical release doc)
# and must mention the release version (the published body gets a generated
# provenance header on top). Override with RELEASE_NOTES_FILE=path/to/file,
# set RELEASE_NOTES_ASK=1 to type them interactively, or RELEASE_NOTES_FORCE=1
# to skip the version-mention guard.
#
# Obtainium users can then add: https://github.com/jptrsn/owntone_remote
# (with three per-ABI APKs per release, users should enable Obtainium's
# "filter APKs by CPU architecture" toggle — see the footer at the end).

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
GH_REPO="${GH_REPO:-jptrsn/owntone_remote}"  # overridable for smoke-testing against a throwaway repo
APK_PREFIX="owntone-remote"
APP_NAME="OwnTone Remote"
NOTES_DEFAULT="docs/RELEASE-NOTES.md"
GATES_FILE=".github/workflows/gates.yml"

DRY_RUN=0
if [[ $# -gt 1 ]]; then
    echo "usage: $0 [--dry-run]" >&2
    exit 1
fi
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ -n "${1:-}" ]]; then
    echo "usage: $0 [--dry-run]" >&2
    exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# ── Preflight checks ────────────────────────────────────────────────────────
DRY_LABEL=""
if [[ "$DRY_RUN" == "1" ]]; then DRY_LABEL=" (dry run)"; fi
bold "=== ${APP_NAME} Release${DRY_LABEL} ==="
echo

for cmd in flutter dart gh git; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found on PATH."
done

if ! AUTH_OUT=$(gh auth status 2>&1); then
    echo "$AUTH_OUT"
    die "gh CLI is not authenticated. Run: gh auth login"
fi

[[ -f "pubspec.yaml" ]] || die "pubspec.yaml not found. Run this script from the project root."

# Releases are cut from gated, merged code only: a tag on an unmerged branch
# would ship to every Obtainium user with no CI gate ever having run on it.
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    die "Releases must be cut from main (currently on '${CURRENT_BRANCH}')."
fi
git fetch -q origin main || die "Cannot reach origin — refusing to guess about sync state."
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    die "HEAD is not origin/main — check out or merge the release commit first."
fi

# Toolchain drift is how the two-formatters fight started (AGENTS Environment)
# — warn, don't die; the tag push triggers the same gates on CI as a
# cross-check of the toolchain that produced the published artifact.
CI_FLUTTER_PIN=$(sed -n "s/.*flutter-version: '\(.*\)'.*/\1/p" "$GATES_FILE" 2>/dev/null | head -1) || CI_FLUTTER_PIN=""
[[ -n "$CI_FLUTTER_PIN" ]] || CI_FLUTTER_PIN="3.47.9"  # fall back to the pin-era literal
LOCAL_FLUTTER=$(flutter --version 2>/dev/null | head -1 | sed -E 's/Flutter ([0-9.]+).*/\1/') || LOCAL_FLUTTER="unknown"
if [[ "$LOCAL_FLUTTER" != "$CI_FLUTTER_PIN" ]]; then
    yellow "⚠ Local Flutter is ${LOCAL_FLUTTER}, CI pins ${CI_FLUTTER_PIN}."
    yellow "  The APK you build here is what users get; the CI tag build is"
    yellow "  only a cross-check. Align deliberately (AGENTS Environment)."
    echo
fi

VERSION=$(grep '^version:' pubspec.yaml | head -1 | sed -e 's/version: *//' -e 's/+.*//' -e 's/"//g' -e "s/'//g") || VERSION=""
VERSION_FULL=$(grep '^version:' pubspec.yaml | head -1 | sed -e 's/version: *//' -e 's/"//g' -e "s/'//g") || VERSION_FULL=""
TAG="v${VERSION}"

[[ -n "$VERSION" ]] || die "Could not parse version from pubspec.yaml."

bold "Version:  ${VERSION_FULL}"
bold "Tag:      ${TAG}"
bold "APKs:     ${APK_PREFIX}-${TAG}-{arm64-v8a,armeabi-v7a,x86_64}.apk"
bold "Signing:  dedicated release key (android/owntone-release.keystore)"
echo

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Uncommitted changes:"
    git status --porcelain
    die "Git working tree is dirty. Commit or stash your changes first (including flutter's analysis_options.yaml churn — AGENTS says commit it)."
fi

# refs/tags/ specifically: a bare rev-parse would also match a branch named v0.1.0.
if git rev-parse "refs/tags/${TAG}" &>/dev/null; then
    die "Tag '${TAG}' already exists locally. Bump the version in pubspec.yaml first (or delete the stray tag with 'git tag -d ${TAG}')."
fi

REMOTE_TAG=$(git ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null) \
    || die "Cannot reach origin — refusing to guess about whether ${TAG} exists."
[[ -z "$REMOTE_TAG" ]] || die "Tag '${TAG}' already exists on the remote. Bump the version in pubspec.yaml first."

# ── Signing preflight (never publish a foreign-signed artifact) ──────────────
ALLOW_DEBUG_SIGN="${ALLOW_DEBUG_SIGN:-0}"
if [[ "$ALLOW_DEBUG_SIGN" == "1" ]]; then
    yellow "⚠ ALLOW_DEBUG_SIGN=1 — the disaster-recovery path. The published"
    yellow "  APKs will NOT carry the release key; every existing install"
    yellow "  breaks on next update and the release notes must say so."
    echo
else
    [[ -f "android/keystore.properties" && -f "android/owntone-release.keystore" ]] \
        || die "Signing material missing (android/keystore.properties, android/owntone-release.keystore). Restore it per tools/keystore/README.md (private escrow repo). Emergency-only override: ALLOW_DEBUG_SIGN=1."
    KS_EXPECTED=$(awk '{print $1}' tools/keystore/checksum.sha256) \
        || die "tools/keystore/checksum.sha256 unreadable."
    KS_ACTUAL=$(shasum -a 256 android/owntone-release.keystore | awk '{print $1}')
    [[ "$KS_EXPECTED" == "$KS_ACTUAL" ]] \
        || die "Keystore does NOT match the public checksum (expected ${KS_EXPECTED:0:12}…, got ${KS_ACTUAL:0:12}…) — wrong/restored-wrong key? See tools/keystore/README.md."
fi

# ── versionCode must strictly climb (Obtainium/Android refuse installs of ──
# ── equal-or-lower versionCode; release.sh used to rely on the human) ──────
CURRENT_BUILD=$(printf '%s' "$VERSION_FULL" | sed -e 's/.*+//')
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || die "Could not parse build number from '${VERSION_FULL}' (expected version: X.Y.Z+N)."
LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [[ -n "$LAST_TAG" ]]; then
    LAST_FULL=$(git show "${LAST_TAG}:pubspec.yaml" | grep '^version:' | head -1 | sed -e 's/version: *//' -e 's/"//g' -e "s/'//g")
    LAST_BUILD=$(printf '%s' "$LAST_FULL" | sed -e 's/.*+//')
    if [[ "$LAST_BUILD" =~ ^[0-9]+$ ]] && (( CURRENT_BUILD <= LAST_BUILD )); then
        die "versionCode must increase: ${TAG} has +${CURRENT_BUILD} but ${LAST_TAG} already shipped +${LAST_BUILD}. Bump the +N in pubspec.yaml."
    fi
fi
green "✓ versionCode ${CURRENT_BUILD} climbs past ${LAST_TAG:-<no prior tag>}."

green "✓ Preflight checks passed."
echo

# ── Quality gates (AGENTS "done means") ──────────────────────────────────────
# The release artifact must not ship on a red gate. These are the same three
# commands the units run; --exclude-tags live keeps the LAN-server tests out.
bold "Running quality gates..."
ANALYZE_OUT=$(flutter analyze 2>&1) || true
echo "$ANALYZE_OUT" | tail -1
if [[ "$ANALYZE_OUT" != *"No issues found"* ]]; then
    echo "$ANALYZE_OUT"
    die "flutter analyze reports issues — fix them before releasing."
fi
FORMAT_OUT=$(dart format --output=none --set-exit-if-changed . 2>&1) || {
    echo "$FORMAT_OUT"
    die "dart format --set-exit-if-changed found drift — run 'dart format .' and commit."
}
echo "$FORMAT_OUT" | tail -1
TEST_OUT=$(flutter test --exclude-tags live 2>&1) || true
echo "$TEST_OUT" | tail -1
if [[ "$TEST_OUT" != *"All tests passed"* ]]; then
    echo "$TEST_OUT" | tail -50
    die "flutter test failed — fix tests before releasing."
fi
green "✓ Gates green (analyze · format · test)."
echo

# flutter analyze may rewrite analysis_options.yaml (known churn) — keep the
# tag on a clean tree so the tagged commit is exactly what was built.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Uncommitted changes:"
    git status --porcelain
    die "Gates dirtied the working tree (analysis_options.yaml churn) — commit it and rerun."
fi

# ── Collect release notes ────────────────────────────────────────────────────
NOTES_SOURCE="ask"
if [[ "${RELEASE_NOTES_ASK:-0}" == "1" ]]; then
    bold "Enter release notes (press Ctrl-D on an empty line when done):"
    echo
    RELEASE_NOTES=$(cat)
elif [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
    [[ -f "$RELEASE_NOTES_FILE" ]] || die "RELEASE_NOTES_FILE='${RELEASE_NOTES_FILE}' not found."
    RELEASE_NOTES=$(cat "$RELEASE_NOTES_FILE")
    NOTES_SOURCE="$RELEASE_NOTES_FILE"
else
    [[ -f "$NOTES_DEFAULT" ]] || die "Default notes file '${NOTES_DEFAULT}' not found (set RELEASE_NOTES_FILE or RELEASE_NOTES_ASK=1)."
    RELEASE_NOTES=$(cat "$NOTES_DEFAULT")
    NOTES_SOURCE="$NOTES_DEFAULT"
fi
echo

if [[ -z "$RELEASE_NOTES" ]]; then
    die "Release notes cannot be empty."
fi

# File-sourced notes are reused across releases by default — a stale doc
# would publish another release's commit/size/test claims. Guard: the body
# must mention the version being published (guard BEFORE the provenance
# header, which contains the tag and would pass it trivially).
if [[ "$NOTES_SOURCE" != "ask" && "${RELEASE_NOTES_FORCE:-0}" != "1" ]]; then
    if [[ "$RELEASE_NOTES" != *"${VERSION}"* ]]; then
        die "Notes from '${NOTES_SOURCE}' never mention ${VERSION} — likely stale. Update the doc (or use RELEASE_NOTES_FILE / RELEASE_NOTES_ASK=1 / RELEASE_NOTES_FORCE=1)."
    fi
fi

# Published-body provenance: docs/RELEASE-NOTES.md describes an audited
# artifact (a specific commit/build); the thing being uploaded is built HERE
# and now, so the body must say so.
SHORT_SHA=$(git rev-parse --short HEAD)
FLUTTER_LABEL="$LOCAL_FLUTTER"
if [[ "$FLUTTER_LABEL" == "unknown" ]]; then FLUTTER_LABEL="version not detected (see operator console drift warning)"; fi
if [[ "$ALLOW_DEBUG_SIGN" == "1" ]]; then
    SIGNING_LABEL="**debug-signed via the ALLOW_DEBUG_SIGN disaster-recovery override**"
else
    SIGNING_LABEL="signed with the release key (public anchor \`tools/keystore/checksum.sha256\`)"
fi
NOTES_HEADER="> Built from \`${SHORT_SHA}\` (main @ publish) with \`flutter build apk --release --split-per-abi\` on Flutter ${FLUTTER_LABEL}; ${SIGNING_LABEL}. The body below is the release doc as of publish — it describes the audited release-candidate build, while the attached per-ABI APKs are the artifacts built here."
RELEASE_NOTES="${NOTES_HEADER}

${RELEASE_NOTES}"

# Show summary and confirm
echo "─────────────────────────────────────────"
bold "Release summary:"
echo "  Tag:     ${TAG}"
echo "  Version: ${VERSION_FULL}"
echo "  APKs:    ${APK_PREFIX}-${TAG}-arm64-v8a.apk"
echo "           ${APK_PREFIX}-${TAG}-armeabi-v7a.apk"
echo "           ${APK_PREFIX}-${TAG}-x86_64.apk"
echo
TOTAL_LINES=$(printf '%s\n' "$RELEASE_NOTES" | wc -l | tr -d ' ')
bold "Release notes (first 40 of ${TOTAL_LINES} lines — the FULL text is published):"
printf '%s\n' "$RELEASE_NOTES" | head -40 || true
if [[ "$TOTAL_LINES" -gt 40 ]]; then
    yellow "  … $((TOTAL_LINES - 40)) more line(s) NOT shown but WILL be published."
fi
echo "─────────────────────────────────────────"
echo
if [[ "$DRY_RUN" == "1" ]]; then
    bold "Dry run: building APKs only — no tag, no push, no GitHub release."
else
    read -rp "Proceed with build and release? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi
echo

# ── Build APKs ───────────────────────────────────────────────────────────────
bold "Building release APKs (split per ABI)..."
flutter build apk --release --split-per-abi

FLUTTER_APK_DIR="build/app/outputs/flutter-apk"

APK_FILES=""
for abi in arm64-v8a armeabi-v7a x86_64; do
    src="${FLUTTER_APK_DIR}/app-${abi}-release.apk"
    dest="${APK_PREFIX}-${TAG}-${abi}.apk"
    [[ -f "$src" ]] || die "Expected APK not found: ${src}"
    cp "$src" "$dest"
    APK_FILES="${APK_FILES} ${dest}"
    APK_SIZE=$(du -h "$dest" | cut -f1) || APK_SIZE="?"
    echo "  ${dest} (${APK_SIZE})"
done

if [[ "$ALLOW_DEBUG_SIGN" == "1" ]]; then
    yellow "⚠ Skipping release-key cert check (ALLOW_DEBUG_SIGN=1) —"
    yellow "  these APKs must not be published as normally-signed releases."
else
    # The gradle fallback silently debug-signs when the keystore vanished
    # mid-session; verify every artifact actually carries the release key.
    for apk in $APK_FILES; do
        tools/keystore/verify.sh "$apk" >/dev/null \
            || die "$apk is not signed by the release key — aborting before publish."
    done
    green "✓ All APKs signed by the release key (cert-checked)."
fi

# Integrity asset: users (and Obtainium, on demand) can verify the bits.
SUMS="${APK_PREFIX}-${TAG}-SHA256SUMS.txt"
shasum -a 256 $APK_FILES > "$SUMS"
APK_FILES="${APK_FILES} ${SUMS}"
echo "  ${SUMS}"
green "✓ APKs built."
echo

if [[ "$DRY_RUN" == "1" ]]; then
    bold "Dry run complete. APKs left in place (gitignored); nothing was pushed."
    echo "  (delete them with: rm -f ${APK_PREFIX}-${TAG}-*.apk ${APK_PREFIX}-${TAG}-SHA256SUMS.txt)"
    exit 0
fi

# ── Create and push git tag ──────────────────────────────────────────────────
# Last clean-tree check: the build itself must not have dirtied a tracked
# file (AGENTS flags gradle.properties re-dirtying as a live hazard) — the
# tag must name exactly what was built.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Uncommitted changes:"
    git status --porcelain
    die "Build dirtied the working tree — investigate (AGENTS: verify it is the tool's own flag text) before tagging."
fi

bold "Creating git tag ${TAG}..."
git tag -a "$TAG" -m "Release ${TAG}"
git push origin "$TAG"
green "✓ Tag ${TAG} pushed to origin."
echo

# ── Create GitHub release ────────────────────────────────────────────────────
bold "Creating release on GitHub..."

# --verify-tag makes gh fail loudly instead of inventing its own tag if the
# push didn't land; --notes-file - streams the notes without a temp file.
# gh uploads assets as separate API requests (not atomic) — on failure the
# tag is pushed and the APKs are still in the project root, so print the
# recovery commands instead of leaving the operator to guess.
if ! gh release create "$TAG" \
    --repo "$GH_REPO" \
    --title "${APP_NAME} ${TAG}" \
    --notes-file - \
    --verify-tag \
    $APK_FILES <<< "$RELEASE_NOTES"; then
    red "Release creation/upload failed — the tag is pushed and APKs remain in the project root."
    echo "To FINISH the release (assets upload is resumable):"
    echo "    gh release upload ${TAG} ${APK_PREFIX}-${TAG}-*.apk ${APK_PREFIX}-${TAG}-SHA256SUMS.txt --repo ${GH_REPO} --clobber"
    echo "    gh release edit ${TAG} --repo ${GH_REPO} --draft=false   # only if left as a draft"
    echo "To START OVER:"
    echo "    gh release delete ${TAG} --repo ${GH_REPO} --yes --cleanup-tag"
    echo "    git tag -d ${TAG} && git push origin :refs/tags/${TAG}"
    exit 1
fi

RELEASE_URL=$(gh release view "$TAG" --repo "$GH_REPO" --json url --jq '.url') || \
    RELEASE_URL="(unknown — check https://github.com/${GH_REPO}/releases)"

green "✓ Release created: ${RELEASE_URL}"
echo

# ── Clean up local APK copies ────────────────────────────────────────────────
rm -f $APK_FILES

# ── Done ─────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════"
green "Release ${TAG} published successfully!"
echo
bold "Release page:"
echo "  ${RELEASE_URL}"
echo
bold "Obtainium URL (give this to users):"
echo "  https://github.com/${GH_REPO}"
bold "In Obtainium, enable 'Attempt to filter APKs by CPU architecture if"
bold "possible' for this app — without it, three per-ABI APKs mean a manual"
bold "pick prompt on every update (wiki: sources / app_tracking)."
echo "═══════════════════════════════════════════════════════════════"
