#!/usr/bin/env bash
#
# release.sh — Gate, build, tag, and publish OwnTone Remote to GitHub releases.
#
# The distribution channel for this project is GitHub releases + Obtainium
# (user decision 2026-11-16). The release APK is debug-signed — fine for
# Obtainium sideload; if ~/.android/debug.keystore changes between release
# machines, users hit a signature mismatch and must uninstall/reinstall.
#
# Prerequisites:
#   - gh CLI installed and authenticated (gh auth login) with access to
#     jptrsn/owntone_remote
#   - flutter, dart, git on PATH (host should match the CI pin in
#     .github/workflows/gates.yml — the script warns on drift)
#   - Clean git working tree
#   - Version already bumped in pubspec.yaml
#
# Usage:
#   ./release.sh            # full gate + build + tag + publish
#   ./release.sh --dry-run  # gates + build + preview only; pushes nothing
#
# Release notes default to docs/RELEASE-NOTES.md (the canonical release doc);
# override with RELEASE_NOTES_FILE=path/to/file, or set RELEASE_NOTES_ASK=1
# to type them interactively instead.
#
# Obtainium users can then add: https://github.com/jptrsn/owntone_remote

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
GH_REPO="jptrsn/owntone_remote"
APK_PREFIX="owntone-remote"
APPS_NAME="OwnTone Remote"
CI_FLUTTER_PIN="3.47.9"   # keep in sync with .github/workflows/gates.yml
NOTES_DEFAULT="docs/RELEASE-NOTES.md"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi

# ── Helpers ──────────────────────────────────────────────────────────────────
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# ── Preflight checks ────────────────────────────────────────────────────────
DRY_LABEL=""
if [[ "$DRY_RUN" == "1" ]]; then DRY_LABEL=" (dry run)"; fi
bold "=== ${APPS_NAME} Release${DRY_LABEL} ==="
echo

for cmd in flutter dart gh git; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found on PATH."
done

gh auth status &>/dev/null || die "gh CLI is not authenticated. Run: gh auth login"

[[ -f "pubspec.yaml" ]] || die "pubspec.yaml not found. Run this script from the project root."

# Toolchain drift is how the two-formatters fight started (AGENTS Environment)
# — warn, don't die; the CI gates on the pushed tag are the hard gate.
LOCAL_FLUTTER=$(flutter --version 2>/dev/null | head -1 | sed -E 's/Flutter ([0-9.]+).*/\1/')
if [[ "$LOCAL_FLUTTER" != "$CI_FLUTTER_PIN" ]]; then
    yellow "⚠ Local Flutter is ${LOCAL_FLUTTER}, CI pins ${CI_FLUTTER_PIN}."
    yellow "  The APK you build here is what users get; the CI tag build is"
    yellow "  only a cross-check. Align deliberately (AGENTS Environment)."
    echo
fi

VERSION=$(grep '^version:' pubspec.yaml | head -1 | sed 's/version: *//;s/+.*//')
VERSION_FULL=$(grep '^version:' pubspec.yaml | head -1 | sed 's/version: *//')
TAG="v${VERSION}"

[[ -n "$VERSION" ]] || die "Could not parse version from pubspec.yaml."

bold "Version:  ${VERSION_FULL}"
bold "Tag:      ${TAG}"
bold "APKs:     ${APK_PREFIX}-${TAG}-{arm64-v8a,armeabi-v7a,x86_64}.apk"
bold "Signing:  debug (accepted for the GitHub-release/Obtainium channel)"
echo

if [[ -n "$(git status --porcelain)" ]]; then
    die "Git working tree is dirty. Commit or stash your changes first (including flutter's analysis_options.yaml churn — AGENTS says commit it)."
fi

if git rev-parse "$TAG" &>/dev/null 2>&1; then
    die "Tag '${TAG}' already exists locally. Bump the version in pubspec.yaml first."
fi

if git ls-remote --tags origin "refs/tags/${TAG}" | grep -q "${TAG}"; then
    die "Tag '${TAG}' already exists on the remote. Bump the version in pubspec.yaml first."
fi

green "✓ Preflight checks passed."
echo

# ── Quality gates (AGENTS "done means") ──────────────────────────────────────
# The release artifact must not ship on a red gate. These are the same three
# commands the units run; --exclude-tags live keeps the LAN-server tests out.
bold "Running quality gates..."
ANALYZE_OUT=$(flutter analyze 2>&1) || true
echo "$ANALYZE_OUT" | tail -1
[[ "$ANALYZE_OUT" == *"No issues found"* ]] \
    || die "flutter analyze reports issues — fix them before releasing."
dart format --output=none --set-exit-if-changed . >/dev/null \
    || die "dart format --set-exit-if-changed found drift — run 'dart format .' and commit."
TEST_OUT=$(flutter test --exclude-tags live 2>&1) || true
echo "$TEST_OUT" | tail -1
[[ "$TEST_OUT" == *"All tests passed"* ]] \
    || die "flutter test failed — fix tests before releasing."
green "✓ Gates green (analyze · format · test)."
echo

# flutter analyze may rewrite analysis_options.yaml (known churn) — keep the
# tag on a clean tree so the tagged commit is exactly what was built.
if [[ -n "$(git status --porcelain)" ]]; then
    die "Gates dirtied the working tree (analysis_options.yaml churn) — commit it and rerun."
fi

# ── Collect release notes ────────────────────────────────────────────────────
if [[ "${RELEASE_NOTES_ASK:-0}" == "1" ]]; then
    bold "Enter release notes (press Ctrl-D on an empty line when done):"
    echo
    RELEASE_NOTES=$(cat)
elif [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
    [[ -f "$RELEASE_NOTES_FILE" ]] || die "RELEASE_NOTES_FILE='${RELEASE_NOTES_FILE}' not found."
    RELEASE_NOTES=$(cat "$RELEASE_NOTES_FILE")
else
    [[ -f "$NOTES_DEFAULT" ]] || die "Default notes file '${NOTES_DEFAULT}' not found (set RELEASE_NOTES_FILE or RELEASE_NOTES_ASK=1)."
    RELEASE_NOTES=$(cat "$NOTES_DEFAULT")
    echo "Release notes from ${NOTES_DEFAULT} (${#RELEASE_NOTES} chars) — review below."
fi
echo

if [[ -z "$RELEASE_NOTES" ]]; then
    die "Release notes cannot be empty."
fi

# Show summary and confirm
echo "─────────────────────────────────────────"
bold "Release summary:"
echo "  Tag:     ${TAG}"
echo "  Version: ${VERSION_FULL}"
echo "  APKs:    ${APK_PREFIX}-${TAG}-arm64-v8a.apk"
echo "           ${APK_PREFIX}-${TAG}-armeabi-v7a.apk"
echo "           ${APK_PREFIX}-${TAG}-x86_64.apk"
echo
bold "Release notes (first 30 lines):"
printf '%s\n' "$RELEASE_NOTES" | head -30
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
    APK_SIZE=$(du -h "$dest" | cut -f1)
    echo "  ${dest} (${APK_SIZE})"
done
green "✓ APKs built."
echo

if [[ "$DRY_RUN" == "1" ]]; then
    bold "Dry run complete. APKs left in place; nothing was pushed."
    echo "  (delete them with: rm -f ${APK_PREFIX}-${TAG}-*.apk)"
    exit 0
fi

# ── Create and push git tag ──────────────────────────────────────────────────
bold "Creating git tag ${TAG}..."
git tag -a "$TAG" -m "Release ${TAG}"
git push origin "$TAG"
green "✓ Tag ${TAG} pushed to origin."
echo

# ── Create GitHub release ────────────────────────────────────────────────────
bold "Creating release on GitHub..."

# --verify-tag makes gh fail loudly instead of inventing its own tag if the
# push didn't land; --notes-file - streams the notes without a temp file.
gh release create "$TAG" \
    --repo "$GH_REPO" \
    --title "${APPS_NAME} ${TAG}" \
    --notes-file - \
    --verify-tag \
    $APK_FILES <<< "$RELEASE_NOTES" \
    || die "Release creation/upload failed. The tag has been pushed — you may need to create the release manually on GitHub (the APKs are still in the project root)."

RELEASE_URL=$(gh release view "$TAG" --repo "$GH_REPO" --json url --jq '.url')

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
echo "═══════════════════════════════════════════════════════════════"
