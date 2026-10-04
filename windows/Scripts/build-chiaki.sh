#!/usr/bin/env bash
# Dựng st_chiaki.dll (PS5 Remote Play: libchiaki của chiaki-ng, AGPL-3.0 + giải mã H.264 bằng FFmpeg tối giản)
# cho bản Windows. Chạy trong MSYS2 MINGW64, hoặc từ Windows:
#   C:\msys64\usr\bin\bash.exe -lc "/e/.../windows/Scripts/build-chiaki.sh"
# Kết quả: windows/Vendor/st_chiaki/bin/*.dll (st_chiaki.dll + DLL phụ thuộc của MinGW), được csproj chép cạnh exe.
set -euo pipefail

if [ "${MSYSTEM:-}" != "MINGW64" ]; then
    export MSYSTEM=MINGW64
    source /etc/profile
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIN="$(cd "$HERE/.." && pwd)"
VENDOR="$WIN/Vendor"
OUT="$VENDOR/st_chiaki"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1.1}"
mkdir -p "$VENDOR"

if [ -f "$OUT/bin/st_chiaki.dll" ] && [ "${1:-}" != "--force" ]; then
    echo "st_chiaki.dll đã có: $OUT/bin (thêm --force để dựng lại)"
    exit 0
fi

echo "== 1/4 Cài thư viện MSYS2 (pacman)"
pacman -S --needed --noconfirm make git diffutils \
    mingw-w64-x86_64-gcc mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja mingw-w64-x86_64-pkgconf \
    mingw-w64-x86_64-openssl mingw-w64-x86_64-curl mingw-w64-x86_64-json-c mingw-w64-x86_64-miniupnpc \
    mingw-w64-x86_64-opus mingw-w64-x86_64-libevent mingw-w64-x86_64-python mingw-w64-x86_64-python-protobuf \
    mingw-w64-x86_64-python-setuptools mingw-w64-x86_64-protobuf mingw-w64-x86_64-nasm

echo "== 2/4 Mã nguồn chiaki-ng"
if [ ! -d "$VENDOR/chiaki-ng" ]; then
    git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/streetpea/chiaki-ng.git "$VENDOR/chiaki-ng"
fi

echo "== 3/4 FFmpeg $FFMPEG_VERSION tối giản (decoder h264/hevc + swscale, tĩnh)"
if [ ! -f "$VENDOR/ffmpeg/lib/libavcodec.a" ]; then
    if [ ! -d "$VENDOR/ffmpeg-src" ]; then
        curl -sL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$VENDOR/ffmpeg.tar.xz"
        tar -xf "$VENDOR/ffmpeg.tar.xz" -C "$VENDOR"
        mv "$VENDOR/ffmpeg-$FFMPEG_VERSION" "$VENDOR/ffmpeg-src"
        rm -f "$VENDOR/ffmpeg.tar.xz"
    fi
    (
        cd "$VENDOR/ffmpeg-src"
        # hevc kéo theo aom_film_grain.c mà h2645_sei.c (dùng chung với h264) cần khi liên kết.
        ./configure --prefix="$VENDOR/ffmpeg" --disable-everything --disable-programs --disable-doc --disable-network \
            --disable-avdevice --disable-avformat --disable-avfilter --disable-swresample --disable-postproc --disable-debug \
            --enable-static --disable-shared --enable-avcodec --enable-avutil --enable-swscale \
            --enable-decoder=h264 --enable-decoder=hevc \
            --disable-bzlib --disable-zlib --disable-lzma --disable-iconv --disable-mediafoundation \
            --disable-d3d11va --disable-dxva2 --disable-schannel --disable-w32threads --enable-pthreads
        make -j"$(nproc)"
        make install
    )
fi

echo "== 4/4 st_chiaki.dll"
cmake -S "$WIN/native/st_chiaki" -B "$OUT/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -Wno-dev
cmake --build "$OUT/build" -j"$(nproc)" --target st_chiaki
rm -rf "$OUT/bin"
mkdir -p "$OUT/bin"
cp "$OUT/build/st_chiaki.dll" "$OUT/bin/"
# Chép các DLL của MinGW mà st_chiaki.dll cần (openssl, curl, json-c, libevent, miniupnpc…).
ldd "$OUT/bin/st_chiaki.dll" | awk '/\/mingw64\// {print $3}' | sort -u | while read -r dll; do cp "$dll" "$OUT/bin/"; done
echo "Xong: $OUT/bin"
ls "$OUT/bin"
