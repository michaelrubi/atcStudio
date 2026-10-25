# Third-party notices

ATC Studio ships with the software below.

## FFmpeg

The app includes an `ffmpeg` program in `ATC Studio.app/Contents/Resources/bin/ffmpeg`.

- FFmpeg 8.0, licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later.
- Built without `--enable-gpl` and without `--enable-nonfree`.
- Source: https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz
- Build script: `scripts/build_ffmpeg.sh` in https://github.com/michaelrubi/atcStudio
- License text: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.

## LAME

FFmpeg in this app links LAME statically for MP3 encoding.

- LAME 3.100, licensed under the GNU LGPL version 2 or later.
- Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz

To relink with a different LAME or FFmpeg, change the versions in `scripts/build_ffmpeg.sh`,
rebuild, and replace `Contents/Resources/bin/ffmpeg`.

## Desert Ant Labs

On-device AI by Desert Ant Labs (Clear, Voz, Who, Align, Uhm, Title), under the
Desert Ant Labs Source-Available License 1.0. https://desertant.com

## Swift packages

GRDB.swift (MIT), MLX Swift and MLX Swift LM (MIT), swift-transformers (Apache 2.0),
swift-huggingface, swift-jinja, EventSource (MIT or Apache 2.0, see each project),
swift-crypto, swift-asn1, swift-collections, swift-numerics (Apache 2.0), yyjson (MIT).
