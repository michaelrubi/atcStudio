#!/usr/bin/env bash
#
# Builds a self-contained arm64 ffmpeg for the app bundle.
#
# LGPL build (no --enable-gpl) with libmp3lame linked statically. It links only to
# macOS system libraries, so it runs on any Mac without Homebrew.
#
# Output: .build/ffmpeg/bin/ffmpeg  (skipped when it already exists)
# The release ships ffmpeg's source link and license (see THIRD_PARTY_NOTICES.md).

set -euo pipefail

FFMPEG_VERSION=8.0
FFMPEG_SHA256=b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e
LAME_VERSION=3.100
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
MIN_MACOS=15.0

cd "$(dirname "$0")/.."
ROOT="$PWD/.build/ffmpeg"
PREFIX="$ROOT/prefix"
OUT="$ROOT/bin/ffmpeg"

if [[ -x "$OUT" ]]; then
  echo "ffmpeg already built: $OUT"
  exit 0
fi

mkdir -p "$ROOT/src" "$PREFIX" "$ROOT/bin"
cd "$ROOT/src"

fetch() { # fetch URL FILE SHA256
  [[ -f "$2" ]] || curl -fsSL --retry 3 -o "$2" "$1"
  echo "$3  $2" | shasum -a 256 -c -
}

fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" \
  lame.tar.gz "$LAME_SHA256"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" ffmpeg.tar.xz "$FFMPEG_SHA256"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
FLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS"
JOBS="$(sysctl -n hw.ncpu)"

rm -rf "lame-$LAME_VERSION" && tar xzf lame.tar.gz
(
  cd "lame-$LAME_VERSION"
  # lame 3.100 exports a symbol it no longer defines; harmless for a static build, but drop it.
  sed -i '' '/lame_init_old/d' include/libmp3lame.sym
  CFLAGS="$FLAGS -O2" LDFLAGS="$FLAGS" ./configure --prefix="$PREFIX" \
    --host=aarch64-apple-darwin --disable-shared --enable-static --disable-frontend --disable-decoder
  make -j"$JOBS" && make install
)

rm -rf "ffmpeg-$FFMPEG_VERSION" && tar xJf ffmpeg.tar.xz
(
  cd "ffmpeg-$FFMPEG_VERSION"
  # --disable-autodetect keeps Homebrew libraries out; we turn back on only system ones.
  ./configure --prefix="$PREFIX" --arch=arm64 --cc=clang \
    --extra-cflags="$FLAGS -I$PREFIX/include" --extra-ldflags="$FLAGS -L$PREFIX/lib" \
    --disable-autodetect --enable-libmp3lame --enable-zlib --enable-audiotoolbox \
    --disable-ffplay --disable-ffprobe --disable-doc --disable-network --disable-debug \
    --disable-shared --enable-static
  make -j"$JOBS"
  cp ffmpeg "$OUT"
)

# Fail if anything outside the OS slipped in.
if otool -L "$OUT" | tail -n +2 | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
  echo "error: ffmpeg links to a non-system library (above)" >&2
  exit 1
fi
"$OUT" -hide_banner -encoders 2>/dev/null | grep -q libmp3lame
echo "Built $OUT"
