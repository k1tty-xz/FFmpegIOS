#!/usr/bin/env bash
# ===========================================================================
# package-deb.sh — wrap the built iOS ffmpeg/ffprobe into an installable .deb
# for a jailbroken device (dpkg/apt).
#
# Usage: package-deb.sh [FFMPEG_VERSION] [DEB_ARCH]
#   DEB_ARCH MUST match the device: `dpkg --print-architecture`
#   (e.g. iphoneos-arm64 rootful, or iphoneos-arm64e rootless).
#
# Design choices:
#  - Package name is "ffmpeg-static" (NOT "ffmpeg") and binaries install to
#    /usr/local/bin, so this does not collide with or replace the distro
#    "ffmpeg" package and its shared libav* libraries that other packages
#    may depend on. Our binaries are statically linked, so they need nothing.
# ===========================================================================
set -Eeuo pipefail

FFMPEG_VERSION="${1:-8.1.2}"
DEB_ARCH="${2:-iphoneos-arm64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/artifacts"
STAGE="$ART/deb"
PKG="ffmpeg-static"
OUT="$ART/${PKG}_${FFMPEG_VERSION}_${DEB_ARCH}.deb"

echo "==> packaging $PKG $FFMPEG_VERSION ($DEB_ARCH)"

# Verify the inputs exist before we package nothing.
for b in ffmpeg ffprobe; do
  if [ ! -f "$ART/bin/$b" ]; then
    echo "ERROR: $ART/bin/$b missing — build step must run first." >&2
    exit 1
  fi
done

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/local/bin"

install -m 0755 "$ART/bin/ffmpeg"  "$STAGE/usr/local/bin/ffmpeg"
install -m 0755 "$ART/bin/ffprobe" "$STAGE/usr/local/bin/ffprobe"

# Installed-Size is in KiB (dpkg convention).
size_kib="$(du -sk "$STAGE/usr" | awk '{print $1}')"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Name: FFmpeg (static, VideoToolbox)
Version: $FFMPEG_VERSION
Architecture: $DEB_ARCH
Maintainer: LiteReplayd <root@localhost>
Author: FFmpeg developers <https://ffmpeg.org>
Section: Multimedia
Priority: optional
Installed-Size: $size_kib
Homepage: https://ffmpeg.org
Description: FFmpeg $FFMPEG_VERSION static build for iOS arm64
 Statically-linked ffmpeg/ffprobe with VideoToolbox hardware encoders
 (hevc_videotoolbox, h264_videotoolbox), plus x264, x265, libvpx, dav1d,
 opus, fdk-aac, mp3lame and vorbis. Installs into /usr/local/bin and does
 not touch the distro "ffmpeg" package or its shared libraries.
EOF

echo "-- DEBIAN/control --"
sed 's/^/    /' "$STAGE/DEBIAN/control"

# --root-owner-group makes packaged files root:root without needing fakeroot.
# -Zxz is supported by both Procursus and Elucubratus dpkg.
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$OUT"

# --- verify the package we just built (don't assume) -----------------------
echo "::group::VERIFY .deb"
echo "-- dpkg-deb --info --"
dpkg-deb --info "$OUT" | sed 's/^/    /'
echo "-- dpkg-deb --contents --"
dpkg-deb --contents "$OUT" | sed 's/^/    /'
echo "-- file --"
ls -lh "$OUT"
echo "::endgroup::"

echo "==> built $OUT"
