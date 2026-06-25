#!/usr/bin/env bash
#
# build-ffmpeg-ios.sh — cross-compile a static FFmpeg + ffprobe for iOS arm64.
#
# Runs on a macOS (Apple Silicon) runner. Produces ldid-signed Mach-O arm64
# binaries in artifacts/bin, statically linked against:
#   video : libx264, libx265, libvpx (VP8/9), libdav1d (AV1 decode)
#   audio : libopus, libmp3lame, libfdk-aac, libvorbis (+libogg)
#   apple : VideoToolbox (hw H.264/HEVC) + AudioToolbox (built in, no ext dep)
#
# Usage: build-ffmpeg-ios.sh [FFMPEG_VERSION] [IOS_MIN]   e.g. 8.1.2 14.0
#
# Scope note: this is the high-value codec set. Adding the subtitle/text stack
# (freetype/fribidi/harfbuzz/libass/fontconfig) or extra AV1 encoders
# (libaom/SVT-AV1) is a mechanical extension of the same helpers below.
#
# -E (errtrace) is required so the ERR trap fires for failures inside functions.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly FFMPEG_VERSION="${1:-8.1.2}"
readonly IOS_MIN="${2:-14.0}"
readonly ARCH="arm64"
readonly HOST_TRIPLE="aarch64-apple-darwin"

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly WORK="$ROOT/build"
readonly SRC="$WORK/src"          # dependency sources are cloned/unpacked here
readonly PREFIX="$WORK/prefix"    # dependencies install here (static)
readonly ART="$ROOT/artifacts"    # FFmpeg + final binaries install here
readonly JOBS="$(sysctl -n hw.ncpu)"

# ---------------------------------------------------------------------------
# Toolchain — target the iPhoneOS SDK, never the host macOS SDK.
# (Do NOT add -fembed-bitcode=no: it is invalid clang syntax. Bitcode is
#  deprecated and off by default since Xcode 14, so it needs no flag.)
# ---------------------------------------------------------------------------
readonly SDKPATH="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos -f clang)"
export CXX="$(xcrun --sdk iphoneos -f clang++)"
export AR="$(xcrun --sdk iphoneos -f ar)"
export RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
export STRIP="$(xcrun --sdk iphoneos -f strip)"
export LD="$(xcrun --sdk iphoneos -f ld)"

readonly ARCH_FLAGS="-arch $ARCH -isysroot $SDKPATH -miphoneos-version-min=$IOS_MIN"
export CFLAGS="$ARCH_FLAGS -I$PREFIX/include -fPIC -O2"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="$ARCH_FLAGS -L$PREFIX/lib"

# Force pkg-config to resolve ONLY our prefix, never host macOS libraries.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
log()        { printf '\n==> %s\n' "$*"; }
group()      { echo "::group::$*"; }
endgroup()   { echo "::endgroup::"; }
make_install() { make -j"$JOBS"; make install; }

# Fetch sources (idempotent: skip if already present).
fetch_git() {  # <name> <url> [branch]
  local name="$1" url="$2" branch="${3:-}"
  [ -d "$SRC/$name" ] || git clone --depth 1 ${branch:+--branch "$branch"} "$url" "$SRC/$name"
}
fetch_tar() {  # <name> <url>
  local name="$1" url="$2"
  [ -d "$SRC/$name" ] && return
  mkdir -p "$SRC/$name"
  curl -fsSL "$url" | tar -xf - -C "$SRC/$name" --strip-components=1
}

# Standard autotools configure for the audio libs (all share these flags).
configure_static() {  # <extra configure args...>
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
    --enable-static --disable-shared "$@"
}

# meson cross file for iOS arm64 (used by dav1d).
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

# ---------------------------------------------------------------------------
# Diagnostics — gather facts, never guess.
# ---------------------------------------------------------------------------

# On any failure, surface the real error by dumping every build-system log.
dump_logs() {
  group "AUTODUMP: build logs on error"
  find "$SRC" -type f \( -name config.log -o -name meson-log.txt \
       -o -name CMakeError.log -o -name CMakeOutput.log \) 2>/dev/null |
  while read -r f; do
    echo "===================== $f (tail -120) ====================="
    tail -120 "$f"; echo
  done
  endgroup
}
trap dump_logs ERR

# Print toolchain facts and prove the compiler can build for iOS arm64.
preflight() {
  group "PREFLIGHT: toolchain facts"
  echo "uname      : $(uname -a)"
  echo "SDK        : $SDKPATH ($(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null))"
  echo "CFLAGS     : $CFLAGS"
  echo "LDFLAGS    : $LDFLAGS"
  for t in CC CXX AR RANLIB STRIP LD; do echo "  $t = ${!t}"; done
  echo "-- build-tool versions --"
  for tool in cmake meson ninja nasm pkg-config ldid otool lipo; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '  %-10s %s\n' "$tool" "$("$tool" --version 2>/dev/null | head -1)"
    else
      printf '  %-10s [NOT FOUND]\n' "$tool"
    fi
  done

  printf 'int main(void){return 0;}\n' > "$WORK/t.c"
  if "$CC" $CFLAGS $LDFLAGS "$WORK/t.c" -o "$WORK/t.out" 2> "$WORK/t.log"; then
    echo "[PASS] toolchain compiles+links for iOS arm64: $(file -b "$WORK/t.out")"
  else
    echo "[FAIL] toolchain cannot build — clang output:"; cat "$WORK/t.log"
  fi
  endgroup
}

# After a library installs, prove its archive contains ONLY iOS-arm64 objects.
# Catches the recurring "built for 'macOS'" asm bug at its source. Non-fatal.
#   Mach-O platform: LC_BUILD_VERSION 'platform' 1=macOS 2=iOS 7=iOS-sim
#   (older objects)  LC_VERSION_MIN_IPHONEOS / _MACOSX
verify_lib() {  # <archive.a> [archive.a ...]
  group "VERIFY platform: $*"
  local archive tmp obj plat total ios macos other bad
  for archive in "$@"; do
    local path="$PREFIX/lib/$archive"
    if [ ! -f "$path" ]; then echo "  [MISSING] $path"; continue; fi
    echo "  $archive: $(lipo -info "$path" 2>/dev/null || file -b "$path")"

    tmp="$(mktemp -d)"; ( cd "$tmp" && ar x "$path" 2>/dev/null ) || true
    total=0 ios=0 macos=0 other=0 bad=""
    for obj in "$tmp"/*.o; do
      [ -f "$obj" ] || continue
      total=$((total + 1))
      plat="$(otool -l "$obj" 2>/dev/null | awk '
        /LC_BUILD_VERSION/{b=1}
        b&&/platform/{print $2; exit}
        /LC_VERSION_MIN_IPHONEOS/{print "ios"; exit}
        /LC_VERSION_MIN_MACOSX/{print "macos"; exit}')"
      case "$plat" in
        2|IOS|ios)     ios=$((ios + 1)) ;;
        1|MACOS|macos) macos=$((macos + 1)); bad="$bad $(basename "$obj")" ;;
        *)             other=$((other + 1)) ;;
      esac
    done
    rm -rf "$tmp"

    echo "    objects: total=$total ios=$ios macos=$macos other=$other"
    if   [ "$macos" -gt 0 ]; then
      echo "    [FAIL] macOS-tagged objects will break the iOS link:"
      printf '%s\n' $bad | sed '/^$/d' | head -15 | sed 's/^/        /'
    elif [ "$total" -eq 0 ]; then
      echo "    [WARN] no objects extracted — could not verify"
    else
      echo "    [OK] all objects iOS-tagged"
    fi
  done
  endgroup
}

# Dump what FFmpeg's configure will actually see from pkg-config.
diag_pkgconfig() {
  group "PKG-CONFIG diagnostics"
  echo "PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-<unset>}"
  for p in x264 x265 vpx dav1d opus vorbis ogg fdk-aac; do
    if pkg-config --exists "$p" 2>/dev/null; then
      printf '  OK   %-9s %s\n' "$p" "$(pkg-config --modversion "$p" 2>/dev/null)"
    else
      printf '  FAIL %-9s (--exists failed)\n' "$p"
    fi
  done
  endgroup
}

# Prove what the final binaries are: arch, platform, linkage, signature.
introspect_binaries() {
  group "BINARY introspection"
  local b bin
  for b in ffmpeg ffprobe; do
    bin="$ART/bin/$b"
    [ -f "$bin" ] || { echo "  [MISSING] $bin"; continue; }
    echo "  ===== $b ($(ls -lh "$bin" | awk '{print $5}')) ====="
    echo "    $(file -b "$bin")"
    otool -l "$bin" 2>/dev/null | grep -A4 LC_BUILD_VERSION | head -5 | sed 's/^/    /'
    echo "    linked dylibs:"; otool -L "$bin" 2>/dev/null | sed 's/^/      /' | head -30
  done
  endgroup
}

# ---------------------------------------------------------------------------
# Dependency builds
# ---------------------------------------------------------------------------

build_x264() {
  log "x264"
  fetch_git x264 https://code.videolan.org/videolan/x264.git
  cd "$SRC/x264"; make distclean >/dev/null 2>&1 || true
  # --extra-asflags is essential: x264 assembles .S files through a separate
  # ASFLAGS path; without the iOS flags those objects are tagged macOS and
  # fail to link (e.g. bitstream-a-8.o).
  ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" --sysroot="$SDKPATH" \
    --enable-static --disable-cli --enable-pic \
    --extra-cflags="$CFLAGS" --extra-asflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
  make_install
}

build_x265() {
  log "x265 (cmake)"
  fetch_git x265 https://bitbucket.org/multicoreware/x265_git.git
  rm -rf "$SRC/x265/build-ios"; mkdir -p "$SRC/x265/build-ios"; cd "$SRC/x265/build-ios"
  # ENABLE_ASSEMBLY=OFF: x265 builds its ARM64 .S files through a rule that
  # ignores CMAKE_ASM_FLAGS/OSX_DEPLOYMENT_TARGET, tagging them macOS. A pure
  # C/C++ x265 is correctly iOS-tagged; only the software encoder is slower,
  # and hevc_videotoolbox (hardware) is unaffected.
  cmake ../source \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_SYSROOT="$SDKPATH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF \
    -DCROSS_COMPILE_ARM64=ON
  make_install

  # x265's CMake skips x265.pc when version detection fails on a tagless
  # shallow clone; FFmpeg requires x265 via pkg-config, so emit it ourselves.
  # (C++ static lib => static link needs the C++ runtime, -lc++.)
  if [ ! -f "$PREFIX/lib/pkgconfig/x265.pc" ]; then
    local ver; ver="$(awk '/#define[ \t]+X265_BUILD/{print $3}' "$PREFIX/include/x265.h" 2>/dev/null || true)"
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
  log "libvpx"
  fetch_git libvpx https://chromium.googlesource.com/webm/libvpx
  cd "$SRC/libvpx"; make distclean >/dev/null 2>&1 || true
  ./configure --prefix="$PREFIX" --target=arm64-darwin-gcc \
    --enable-static --disable-shared --enable-pic --enable-vp9-highbitdepth \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --extra-cflags="$CFLAGS"
  make_install
}

build_dav1d() {
  log "dav1d (meson)"
  fetch_git dav1d https://code.videolan.org/videolan/dav1d.git
  write_meson_cross
  rm -rf "$SRC/dav1d/build-ios"
  meson setup "$SRC/dav1d/build-ios" "$SRC/dav1d" \
    --cross-file "$WORK/ios-arm64.meson" --prefix "$PREFIX" --libdir lib \
    --default-library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$SRC/dav1d/build-ios" -j"$JOBS"
  ninja -C "$SRC/dav1d/build-ios" install
}

build_opus() {
  log "opus"
  fetch_git opus https://github.com/xiph/opus.git
  cd "$SRC/opus"; [ -x configure ] || ./autogen.sh
  configure_static --disable-doc --disable-extra-programs
  make_install
}

build_lame() {
  log "lame (mp3)"
  fetch_tar lame https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
  cd "$SRC/lame"
  configure_static --disable-frontend
  make_install
}

build_fdkaac() {
  log "fdk-aac"
  fetch_git fdk-aac https://github.com/mstorsjo/fdk-aac.git
  cd "$SRC/fdk-aac"; [ -x configure ] || ./autogen.sh
  configure_static
  make_install
}

build_ogg() {
  log "libogg"
  fetch_git ogg https://github.com/xiph/ogg.git
  cd "$SRC/ogg"; [ -x configure ] || ./autogen.sh
  configure_static
  make_install
}

build_vorbis() {
  log "libvorbis"
  fetch_git vorbis https://github.com/xiph/vorbis.git
  cd "$SRC/vorbis"
  autoreconf -fi
  # libvorbis injects the legacy '-force_cpusubtype_ALL' flag for *-darwin*
  # hosts; modern ld (Xcode 15) rejects it. Strip it out. (BSD sed.)
  sed -i '' 's/-force_cpusubtype_ALL//g' configure
  configure_static --with-ogg="$PREFIX"
  make_install
}

build_ffmpeg() {
  log "FFmpeg $FFMPEG_VERSION"
  fetch_tar ffmpeg "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  cd "$SRC/ffmpeg"; make distclean >/dev/null 2>&1 || true
  diag_pkgconfig
  ./configure \
    --prefix="$ART" \
    --enable-cross-compile --target-os=darwin --arch="$ARCH" --sysroot="$SDKPATH" \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" \
    --extra-cflags="$CFLAGS" --extra-cxxflags="$CXXFLAGS" --extra-ldflags="$LDFLAGS" \
    --pkg-config=pkg-config --pkg-config-flags="--static" \
    --enable-gpl --enable-nonfree --enable-version3 \
    --enable-libx264 --enable-libx265 --enable-libvpx --enable-libdav1d \
    --enable-libopus --enable-libmp3lame --enable-libfdk-aac --enable-libvorbis \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-static --disable-shared --disable-ffplay --disable-doc --disable-debug
  make -j"$JOBS"
  make install
}

# ldid fake-sign with entitlements so the binaries run on a jailbroken device.
sign_binaries() {
  log "ldid signing"
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
  local b
  for b in ffmpeg ffprobe; do
    [ -f "$ART/bin/$b" ] && ldid -S"$WORK/ent.plist" "$ART/bin/$b" && echo "signed $b"
  done
}

# ---------------------------------------------------------------------------
# main — order matters (vorbis needs ogg; ffmpeg needs all). Each dependency
# is verified the instant it builds, so a bad object names itself immediately.
# ---------------------------------------------------------------------------
main() {
  mkdir -p "$PREFIX" "$SRC" "$ART/bin"
  log "FFmpeg $FFMPEG_VERSION | iOS min $IOS_MIN | $JOBS jobs | SDK $SDKPATH"
  preflight

  build_x264;   verify_lib libx264.a
  build_x265;   verify_lib libx265.a
  build_libvpx; verify_lib libvpx.a
  build_dav1d;  verify_lib libdav1d.a
  build_opus;   verify_lib libopus.a
  build_lame;   verify_lib libmp3lame.a
  build_fdkaac; verify_lib libfdk-aac.a
  build_ogg;    verify_lib libogg.a
  build_vorbis; verify_lib libvorbis.a libvorbisenc.a libvorbisfile.a

  build_ffmpeg
  sign_binaries
  introspect_binaries

  log "Done. Binaries in $ART/bin"
}

main "$@"
