#!/usr/bin/env bash
# ===========================================================================
# build-ffmpeg-ios.sh — cross-compile FFmpeg + ffprobe for jailbroken iOS arm64
#
# Runs on a macOS (Apple Silicon) GitHub Actions runner. Builds a "full" GPL +
# nonfree FFmpeg statically linked against:
#   video : libx264, libx265, libvpx (VP8/9), libdav1d (AV1 decode)
#   audio : libopus, libmp3lame, libfdk-aac, libvorbis (+libogg)
#   apple : VideoToolbox (hw h264/hevc), AudioToolbox  (built in, no ext dep)
#
# Output: artifacts/bin/{ffmpeg,ffprobe}  — ldid-signed Mach-O arm64 executables.
#
# Usage: build-ffmpeg-ios.sh [FFMPEG_VERSION] [IOS_MIN]
#   e.g. build-ffmpeg-ios.sh 8.1.2 14.0
#
# NOTE on scope: this is the high-value codec set. The subtitle/text stack
# (freetype+fribidi+harfbuzz+libass+fontconfig) and extra AV1 encoders
# (libaom/SVT-AV1) are deliberately left out to keep build time + failure
# surface sane; each is a mechanical add following the same helpers below.
# ===========================================================================
# -E (errtrace): make the ERR trap fire for failures INSIDE functions too,
# otherwise dump_logs never runs when a build_* function fails.
set -Eeuo pipefail

FFMPEG_VERSION="${1:-8.1.2}"
IOS_MIN="${2:-14.0}"
ARCH="arm64"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build"
PREFIX="$WORK/prefix"      # external libs install here (static)
SRC="$WORK/src"
ART="$ROOT/artifacts"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$PREFIX" "$SRC" "$ART/bin"

# --- toolchain (target the iPhoneOS SDK, not the host macOS SDK) ------------
SDKPATH="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos -f clang)"
export CXX="$(xcrun --sdk iphoneos -f clang++)"
export AR="$(xcrun --sdk iphoneos -f ar)"
export RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
export STRIP="$(xcrun --sdk iphoneos -f strip)"
export LD="$(xcrun --sdk iphoneos -f ld)"

# NOTE: do not add -fembed-bitcode=no — that is invalid clang syntax and makes
# every compile fail with "invalid value 'no'". Bitcode is deprecated and off
# by default since Xcode 14, so it simply doesn't need to be specified.
ARCH_FLAGS="-arch $ARCH -isysroot $SDKPATH -miphoneos-version-min=$IOS_MIN"
export CFLAGS="$ARCH_FLAGS -I$PREFIX/include -fPIC -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$ARCH_FLAGS -L$PREFIX/lib"
export CPPFLAGS="$CFLAGS"

# Force pkg-config to look ONLY in our prefix, never at host macOS libs.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

HOST_TRIPLE="aarch64-apple-darwin"

echo "==> FFmpeg $FFMPEG_VERSION | iOS min $IOS_MIN | $JOBS jobs"
echo "==> SDK: $SDKPATH"

# ===========================================================================
# DIAGNOSTICS — gather facts, do not guess.
# On any error, dump every build system's log so the real failing command is
# visible in CI output.
# ===========================================================================
dump_logs() {
  echo "::group::AUTODUMP: build logs on error"
  # Find every build-system log under the source tree so whichever dependency
  # failed has its real error surfaced — no need to enumerate each one.
  find "$SRC" -type f \( \
        -name config.log \
     -o -name meson-log.txt \
     -o -name CMakeError.log \
     -o -name CMakeOutput.log \) 2>/dev/null | while read -r f; do
    echo "===================== $f (tail -120) ====================="
    tail -120 "$f"
    echo
  done
  echo "::endgroup::"
}
trap dump_logs ERR

preflight() {
  echo "::group::PREFLIGHT: toolchain facts"
  echo "uname        : $(uname -a)"
  echo "host clang   :"; clang --version | sed 's/^/    /'
  echo "target CC    : $CC"
  echo "CC version   :"; "$CC" --version | sed 's/^/    /'
  echo "SDKPATH      : $SDKPATH"; [ -d "$SDKPATH" ] && echo "    (exists)" || echo "    (MISSING!)"
  echo "CFLAGS       : $CFLAGS"
  echo "LDFLAGS      : $LDFLAGS"
  echo "HOST_TRIPLE  : $HOST_TRIPLE"

  printf 'int main(void){return 0;}\n' > "$WORK/t.c"

  echo "-- TEST 1: compile+link with target toolchain (verbose) --"
  if "$CC" -v $CFLAGS $LDFLAGS "$WORK/t.c" -o "$WORK/t.out" 2> "$WORK/t.log"; then
    echo "[TEST1 = PASS] compile+link succeeded"
    file "$WORK/t.out"
  else
    echo "[TEST1 = FAIL] compile+link failed — full clang output below:"
    cat "$WORK/t.log"
  fi

  echo "-- TEST 2: can the produced iOS binary RUN on this macOS host? --"
  if [ -f "$WORK/t.out" ]; then
    if "$WORK/t.out" 2> "$WORK/t.run.log"; then
      echo "[TEST2 = RUNS] binary executed on host (=> host==target, x264 will think NATIVE)"
    else
      echo "[TEST2 = CANNOT RUN] rc=$? — expected for a cross build."
      echo "    => any configure that RUNS its test binary will wrongly report 'no working compiler'."
      cat "$WORK/t.run.log" 2>/dev/null || true
    fi
  fi
  echo "::endgroup::"
}

preflight

# --- helpers ---------------------------------------------------------------
fetch_git() {  # name url [ref]
  local name="$1" url="$2" ref="${3:-}"
  if [ ! -d "$SRC/$name" ]; then
    git clone --depth 1 ${ref:+--branch "$ref"} "$url" "$SRC/$name"
  fi
}
fetch_tar() {  # name url
  local name="$1" url="$2"
  if [ ! -d "$SRC/$name" ]; then
    mkdir -p "$SRC/$name"
    curl -fsSL "$url" | tar -xf - -C "$SRC/$name" --strip-components=1
  fi
}

# meson cross file for iOS arm64 (used by dav1d)
write_meson_cross() {
  cat > "$WORK/ios-arm64.meson" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$(command -v pkg-config)'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-arch','$ARCH','-isysroot','$SDKPATH','-miphoneos-version-min=$IOS_MIN']
c_link_args = ['-arch','$ARCH','-isysroot','$SDKPATH','-miphoneos-version-min=$IOS_MIN']
EOF
}

# ===========================================================================
# external libraries
# ===========================================================================

build_x264() {
  echo "==> x264"
  fetch_git x264 https://code.videolan.org/videolan/x264.git
  cd "$SRC/x264"
  make distclean >/dev/null 2>&1 || true
  # --extra-asflags is essential: x264 assembles its .S files through a
  # separate ASFLAGS path. Without the iOS -isysroot/-miphoneos-version-min,
  # clang assembles them targeting the macOS HOST, producing macOS-tagged
  # objects (e.g. bitstream-a-8.o) that fail to link into an iOS binary.
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
    --sysroot="$SDKPATH" \
    --enable-static --disable-cli --enable-pic \
    --extra-cflags="$CFLAGS" \
    --extra-asflags="$CFLAGS" \
    --extra-ldflags="$LDFLAGS"
  make -j"$JOBS" && make install
}

build_x265() {
  echo "==> x265 (cmake)"
  fetch_git x265 https://bitbucket.org/multicoreware/x265_git.git
  rm -rf "$SRC/x265/build-ios"; mkdir -p "$SRC/x265/build-ios"; cd "$SRC/x265/build-ios"
  cmake ../source \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_SYSROOT="$SDKPATH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
    -DCROSS_COMPILE_ARM64=ON \
    `# x265 assembles its ARM64 .S files through a rule that ignores both` \
    `# CMAKE_ASM_FLAGS and CMAKE_OSX_DEPLOYMENT_TARGET, so they get tagged for` \
    `# the macOS host and fail to link into an iOS binary. Disabling assembly` \
    `# yields a pure-C/C++ x265 (correctly iOS-tagged). Only the SOFTWARE x265` \
    `# encoder is a bit slower; hevc_videotoolbox (hardware) is unaffected.` \
    -DENABLE_ASSEMBLY=OFF
  make -j"$JOBS" && make install

  # x265's CMake only generates/installs x265.pc when it can detect a version
  # from a git tag; our shallow clone has no tags, so it silently skips it.
  # FFmpeg REQUIRES x265 via pkg-config, so emit a minimal .pc ourselves.
  # x265 is a C++ static lib, so static linking needs the C++ runtime (-lc++).
  if [ ! -f "$PREFIX/lib/pkgconfig/x265.pc" ]; then
    local ver
    ver="$(awk '/#define[ \t]+X265_BUILD/{print $3}' "$PREFIX/include/x265.h" 2>/dev/null || true)"
    cat > "$PREFIX/lib/pkgconfig/x265.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: ${ver:-0}
Libs: -L\${libdir} -lx265
Libs.private: -lc++
Cflags: -I\${includedir}
EOF
    echo "[+] generated x265.pc (version ${ver:-0})"
  fi
}

build_libvpx() {
  echo "==> libvpx"
  fetch_git libvpx https://chromium.googlesource.com/webm/libvpx
  cd "$SRC/libvpx"
  make distclean >/dev/null 2>&1 || true
  ./configure --prefix="$PREFIX" --target=arm64-darwin-gcc \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-pic --enable-vp9-highbitdepth --enable-static --disable-shared \
    --extra-cflags="$CFLAGS"
  make -j"$JOBS" && make install
}

build_dav1d() {
  echo "==> dav1d (meson)"
  fetch_git dav1d https://code.videolan.org/videolan/dav1d.git
  write_meson_cross
  rm -rf "$SRC/dav1d/build-ios"
  meson setup "$SRC/dav1d/build-ios" "$SRC/dav1d" \
    --cross-file "$WORK/ios-arm64.meson" \
    --prefix "$PREFIX" --libdir lib \
    --default-library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$SRC/dav1d/build-ios" -j"$JOBS"
  ninja -C "$SRC/dav1d/build-ios" install
}

build_opus() {
  echo "==> opus"
  fetch_git opus https://github.com/xiph/opus.git
  cd "$SRC/opus"; [ -x configure ] || ./autogen.sh
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
    --enable-static --disable-shared --disable-doc --disable-extra-programs
  make -j"$JOBS" && make install
}

build_lame() {
  echo "==> lame (mp3)"
  fetch_tar lame https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
  cd "$SRC/lame"
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
    --enable-static --disable-shared --disable-frontend
  make -j"$JOBS" && make install
}

build_fdkaac() {
  echo "==> fdk-aac"
  fetch_git fdk-aac https://github.com/mstorsjo/fdk-aac.git
  cd "$SRC/fdk-aac"; [ -x configure ] || ./autogen.sh
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
    --enable-static --disable-shared
  make -j"$JOBS" && make install
}

build_ogg() {
  echo "==> libogg"
  fetch_git ogg https://github.com/xiph/ogg.git
  cd "$SRC/ogg"; [ -x configure ] || ./autogen.sh
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
    --enable-static --disable-shared
  make -j"$JOBS" && make install
}

build_vorbis() {
  echo "==> libvorbis"
  fetch_git vorbis https://github.com/xiph/vorbis.git
  cd "$SRC/vorbis"
  # Generate ./configure (autoreconf, without running it).
  autoreconf -fi
  # libvorbis's configure injects the legacy Apple linker flag
  # '-force_cpusubtype_ALL' for any *-darwin* host; the modern ld (Xcode 15)
  # rejects it and the test_sharedbook link fails. Strip it out. (BSD sed.)
  sed -i '' 's/-force_cpusubtype_ALL//g' configure
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
    --enable-static --disable-shared --with-ogg="$PREFIX"
  make -j"$JOBS" && make install
}

# ===========================================================================
# FFmpeg
# ===========================================================================
build_ffmpeg() {
  echo "==> FFmpeg $FFMPEG_VERSION"
  fetch_tar ffmpeg "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  cd "$SRC/ffmpeg"
  make distclean >/dev/null 2>&1 || true

  # --- pkg-config diagnostics: prove what FFmpeg's configure will see --------
  echo "::group::PKG-CONFIG diagnostics (pre-FFmpeg-configure)"
  echo "which pkg-config : $(command -v pkg-config)"
  echo "PKG_CONFIG_LIBDIR: ${PKG_CONFIG_LIBDIR:-<unset>}"
  echo "PKG_CONFIG_PATH  : ${PKG_CONFIG_PATH:-<unset>}"
  echo "-- .pc files actually present in prefix --"
  ls -la "$PREFIX/lib/pkgconfig" 2>&1 || echo "  (pkgconfig dir missing!)"
  echo "-- per-lib pkg-config probe (exactly how configure looks them up) --"
  for p in x264 x265 vpx dav1d opus vorbis ogg fdk-aac; do
    if pkg-config --exists "$p" 2>/dev/null; then
      printf '  OK   %-10s version=%s\n' "$p" "$(pkg-config --modversion "$p" 2>/dev/null)"
    else
      printf '  FAIL %-10s (--exists failed)\n' "$p"
    fi
  done
  echo "-- x264 resolved flags (plain and --static) --"
  echo "  cflags : $(pkg-config --cflags x264 2>&1)"
  echo "  libs   : $(pkg-config --libs x264 2>&1)"
  echo "  static : $(pkg-config --static --libs x264 2>&1)"
  echo "::endgroup::"

  ./configure \
    --prefix="$ART" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch="$ARCH" \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" \
    --sysroot="$SDKPATH" \
    --extra-cflags="$CFLAGS" \
    --extra-cxxflags="$CXXFLAGS" \
    --extra-ldflags="$LDFLAGS" \
    --pkg-config=pkg-config --pkg-config-flags="--static" \
    --enable-gpl --enable-nonfree --enable-version3 \
    --enable-libx264 --enable-libx265 --enable-libvpx --enable-libdav1d \
    --enable-libopus --enable-libmp3lame --enable-libfdk-aac \
    --enable-libvorbis \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-static --disable-shared \
    --disable-ffplay \
    --disable-doc --disable-debug
  make -j"$JOBS"
  make install
}

# ===========================================================================
# sign so the binaries run on a jailbroken device
# ===========================================================================
sign_binaries() {
  echo "==> ldid fake-signing"
  cat > "$WORK/ent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>platform-application</key><true/>
  <key>com.apple.private.security.no-container</key><true/>
  <key>get-task-allow</key><true/>
</dict>
</plist>
EOF
  for b in ffmpeg ffprobe; do
    [ -f "$ART/bin/$b" ] && ldid -S"$WORK/ent.plist" "$ART/bin/$b" && echo "signed $b"
  done
}

# --- order matters (vorbis needs ogg; ffmpeg needs all) --------------------
build_x264
build_x265
build_libvpx
build_dav1d
build_opus
build_lame
build_fdkaac
build_ogg
build_vorbis
build_ffmpeg
sign_binaries

echo "==> Done. Binaries in $ART/bin"
