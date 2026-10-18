#!/usr/bin/env bash
#=============================================================================
# release-macos.sh
#
# Builds the direct-download release: Release archive -> Developer ID export
# -> signature checks -> notarization + stapling -> build/release/Player.zip.
#
# Upload Player.zip to a GitHub release tagged v<version>. The asset name
# never changes, so this link always serves the newest release:
#   https://github.com/v57/Player/releases/latest/download/Player.zip
# The in-app updater (UpdateKit, GitHubReleases) reads the latest release's
# tag, so the tag must be "v" + CFBundleShortVersionString.
#
# Usage: Tests/Scripts/release-macos.sh [--skip-notarize]
#   Notarization needs a notarytool keychain profile, created once with
#     xcrun notarytool store-credentials player-notary \
#       --apple-id <apple id> --team-id AUCR797TMH
#   (NOTARY_PROFILE overrides the profile name.) --skip-notarize stops after
#   the signature checks, leaving an unnotarized zip.
#=============================================================================
set -euo pipefail

TEAM_ID="AUCR797TMH"
NOTARY_PROFILE="${NOTARY_PROFILE:-player-notary}"
SKIP_NOTARIZE=0
if [[ "${1:-}" == "--skip-notarize" ]]; then SKIP_NOTARIZE=1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT="${REPO_ROOT}/build/release"
rm -rf "${OUT}"
mkdir -p "${OUT}"

# Player.xcodeproj finds its packages at ../Player and ../UpdateKit, so the
# checkout folder must be named Player with UpdateKit beside it. Build from a
# copy when it isn't (e.g. a git worktree), with UpdateKit linked next to it
# (found beside this checkout or beside the main checkout).
SRC="${REPO_ROOT}"
if [[ "$(basename "${REPO_ROOT}")" != "Player" || ! -d "${REPO_ROOT}/../UpdateKit" ]]; then
  SRC="${OUT}/src/Player"
  mkdir -p "${SRC}"
  rsync -a --exclude .build --exclude build --exclude .git --exclude Tests/Corpus \
    "${REPO_ROOT}/" "${SRC}/"
  MAIN_CHECKOUT="$(dirname "$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir)")"
  for dir in "${REPO_ROOT}/../UpdateKit" "${MAIN_CHECKOUT}/../UpdateKit"; do
    if [[ -d "${dir}" ]]; then ln -sfn "$(cd "${dir}" && pwd)" "${OUT}/src/UpdateKit"; break; fi
  done
  [[ -e "${OUT}/src/UpdateKit" ]] \
    || { echo "ERROR: UpdateKit not found beside the checkout (git clone it next to Player)" >&2; exit 1; }
fi

VERSION="$(xcodebuild -project "${SRC}/Player.xcodeproj" -scheme Player -configuration Release \
  -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')"
echo "==> Player ${VERSION} (team ${TEAM_ID})"

echo "==> archive"
# arm64 only: the vendored FFmpeg dylibs are arm64 (the generic destination
# would otherwise also build x86_64 and fail to link them). LTO and ld-archive-prelink
# drop unused package code (Xcode's per-package `ld -r` would keep it).
xcodebuild -project "${SRC}/Player.xcodeproj" -scheme Player -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "${OUT}/Player.xcarchive" \
  -derivedDataPath "${OUT}/DerivedData" ARCHS=arm64 \
  SWIFT_LTO=YES ALTERNATE_LINKER_PATH="${SCRIPT_DIR}/ld-archive-prelink" \
  'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -internalize-at-link -Xfrontend -conditional-runtime-records' \
  archive -quiet

echo "==> export (Developer ID)"
cat > "${OUT}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "${OUT}/Player.xcarchive" \
  -exportOptionsPlist "${OUT}/ExportOptions.plist" -exportPath "${OUT}/export" -quiet
APP="${OUT}/export/Player.app"

echo "==> signature checks"
codesign --verify --deep --strict --verbose=2 "${APP}"
for f in "${APP}/Contents/MacOS/Player" "${APP}"/Contents/Frameworks/libav*.*.*.dylib; do
  info="$(codesign -dvvv "${f}" 2>&1)"
  grep -q "^Authority=Developer ID Application: .*(${TEAM_ID})" <<<"${info}" \
    || { echo "ERROR: ${f##*/} is not signed with Developer ID (${TEAM_ID})" >&2; exit 1; }
  grep -q '^Timestamp=' <<<"${info}" \
    || { echo "ERROR: ${f##*/} has no secure timestamp (notarization needs one)" >&2; exit 1; }
  grep -q 'flags=.*runtime' <<<"${info}" \
    || { echo "ERROR: ${f##*/} lacks the hardened runtime" >&2; exit 1; }
  echo "    ok: ${f##*/}"
done

ZIP="${OUT}/Player.zip"
if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  ditto -c -k --keepParent "${APP}" "${ZIP}"
  echo "==> skipped notarization: ${ZIP} is signed but NOT notarized (Gatekeeper will block it)"
  exit 0
fi

echo "==> notarize (profile ${NOTARY_PROFILE})"
ditto -c -k --keepParent "${APP}" "${OUT}/Player-notarize.zip"
xcrun notarytool submit "${OUT}/Player-notarize.zip" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP}"
spctl --assess --type execute --verbose=2 "${APP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"
rm "${OUT}/Player-notarize.zip"

echo
echo "==> DONE: ${ZIP} ($(stat -f %z "${ZIP}") bytes)"
echo "    Publish: gh release create v${VERSION} '${ZIP}' --repo v57/Player --title 'Player ${VERSION}'"
