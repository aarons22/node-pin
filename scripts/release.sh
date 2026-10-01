#!/bin/bash
# Builds, signs and publishes a NodePin release to GitHub, with the Sparkle appcast as a release asset.
# Usage: scripts/release.sh <version> [--dry-run]
#   --dry-run builds the zip and appcast into build/release without tagging or publishing.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version> [--dry-run]}
DRY_RUN=${2:-}
REPO=aarons22/node-pin
OUT=build/release
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.0.0.app/Contents/Developer}

die() { echo "error: $*" >&2; exit 1; }

if [[ $DRY_RUN != --dry-run ]]; then
    [[ -z $(git status --porcelain) ]] || die "working tree is not clean"
    [[ $(git branch --show-current) == main ]] || die "release from main"
    git fetch -q origin main
    [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "push main first"
    ! gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 || die "v$VERSION already exists"
fi

# Sparkle compares CFBundleVersion, so it must only go up: use the commit count on main.
BUILD=$(git rev-list --count HEAD)

rm -rf "$OUT"
# Signed with the Apple Development identity (no paid account, so no notarization). Its designated
# requirement names the certificate, which survives renewal, so Location and keychain grants persist
# across updates. Dropping get-task-allow keeps release builds non-debuggable.
xcodebuild -project NodePin.xcodeproj -scheme NodePin -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$OUT/dd" -quiet \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build

APP=$OUT/dd/Build/Products/Release/NodePin.app
codesign --verify --strict --deep "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

ZIP=NodePin-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
SIGNATURE=$("$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" --account node-pin "$OUT/$ZIP")

cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NodePin</title>
    <item>
      <title>NodePin $VERSION</title>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ZIP"
                 type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

if [[ $DRY_RUN == --dry-run ]]; then
    echo "Dry run: $OUT/$ZIP and $OUT/appcast.xml (version $VERSION, build $BUILD)"
    exit 0
fi

git tag "v$VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$OUT/$ZIP" "$OUT/appcast.xml" -R "$REPO" \
    --title "NodePin $VERSION" --generate-notes
echo "Released v$VERSION (build $BUILD)"
