#!/bin/sh
# Build the gomobile xcframework and install it where the podspec expects it.
#
#   ./build.sh            build from source, install to ios/ (offline path)
#   ./build.sh --publish  also zip + upload to GitHub Releases and update
#                         ios/Framework.lock so consumers download this build
#
# Requirements: Go (matching go.mod), gomobile + gobind:
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   go get -tool golang.org/x/mobile/cmd/gobind
# --publish additionally requires an authenticated `gh` CLI.
#
# GOTCHA: gvisor must match tailscale's own go.mod pin — a newer gvisor
# breaks gomobile bind with "found packages stack and bridge" errors.
# Re-sync go.mod/go.sum from tailscale.com's pins when bumping tailscale.
set -e
cd "$(dirname "$0")"

go mod tidy
export PATH="$PATH:$(go env GOPATH)/bin"
gomobile bind -target ios -o TailscaleEmbed.xcframework .
rm -rf ../ios/TailscaleEmbed.xcframework
cp -R TailscaleEmbed.xcframework ../ios/
# Mark the installed framework as locally built so download_framework.sh
# doesn't clobber it with the (older) pinned release at the next pod install.
rm -f ../ios/.framework-tag
touch ../ios/.framework-local
echo "TailscaleEmbed.xcframework installed to ios/ (local build)"

[ "${1:-}" = "--publish" ] || exit 0

# ---- publish: zip, checksum, GitHub Release, pin ----------------------------
TS_VERSION="$(grep -m1 'tailscale.com v' go.mod | awk '{print $2}' | sed 's/^v//')"
ZIP=TailscaleEmbed.xcframework.zip

# One immutable release per build: never reuse a tag (old commits pin old
# tags and must stay downloadable forever — don't delete old releases).
TAG="framework-v$TS_VERSION"
N=1
while gh release view "$TAG" >/dev/null 2>&1; do
  N=$((N + 1))
  TAG="framework-v$TS_VERSION-$N"
done

rm -f "$ZIP"
ditto -c -k --keepParent ../ios/TailscaleEmbed.xcframework "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

gh release create "$TAG" "$ZIP" \
  --title "$TAG" \
  --notes "Prebuilt TailscaleEmbed.xcframework (tailscale.com v$TS_VERSION, gomobile). SHA-256: $SHA256"

printf 'TAG=%s\nZIP=%s\nSHA256=%s\n' "$TAG" "$ZIP" "$SHA256" > ../ios/Framework.lock
rm -f "$ZIP" ../ios/.framework-local
printf '%s\n' "$TAG" > ../ios/.framework-tag
echo "Published $TAG and updated ios/Framework.lock — commit it."
