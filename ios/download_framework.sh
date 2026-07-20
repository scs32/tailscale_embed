#!/bin/sh
# Fetch the prebuilt TailscaleEmbed.xcframework pinned in Framework.lock from
# GitHub Releases. Invoked automatically from the podspec at pod-install time;
# safe to run by hand. No-ops when the pinned version is already present or
# when the framework was built locally from source (go/build.sh).
set -eu
cd "$(dirname "$0")"

. ./Framework.lock

FW=TailscaleEmbed.xcframework
URL="https://github.com/scs32/tailscale_embed/releases/download/$TAG/$ZIP"

if [ -f .framework-local ] && [ -d "$FW" ]; then
  echo "tailscale_embed: using locally built $FW (ios/.framework-local present)"
  exit 0
fi
if [ -d "$FW" ] && [ -f .framework-tag ] && [ "$(cat .framework-tag)" = "$TAG" ]; then
  echo "tailscale_embed: using cached $FW ($TAG)"
  exit 0
fi

echo "tailscale_embed: downloading $FW ($TAG)..."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$ZIP" "$URL"

echo "$SHA256  $tmp/$ZIP" | shasum -a 256 -c - >/dev/null || {
  echo "tailscale_embed: checksum mismatch for $URL — refusing to install." >&2
  exit 1
}

rm -rf "$FW" .framework-tag .framework-local
ditto -x -k "$tmp/$ZIP" .
echo "$TAG" > .framework-tag
echo "tailscale_embed: installed $FW ($TAG)"
