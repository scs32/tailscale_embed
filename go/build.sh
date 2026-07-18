#!/bin/sh
# Build the gomobile xcframework and install it where the podspec expects it.
#
# Requirements: Go (matching go.mod), gomobile + gobind:
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   go get -tool golang.org/x/mobile/cmd/gobind
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
echo "TailscaleEmbed.xcframework installed to ios/"
