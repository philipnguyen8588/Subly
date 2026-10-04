#!/bin/sh
# Dựng thư viện libchiaki (PS5 Remote Play, AGPL-3.0) vào Vendor/chiaki-ng/build. Chỉ cần chạy một lần.
# Cần: brew install cmake pkgconf json-c miniupnpc libevent nanopb opus openssl@3 uv
set -e
cd "$(dirname "$0")/.."
[ -f Vendor/chiaki-ng/build/lib/libchiaki.a ] && exit 0
mkdir -p Vendor && cd Vendor
[ -d chiaki-ng ] || git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/streetpea/chiaki-ng.git
[ -d pyenv ] || uv venv pyenv -q
uv pip install -q --python pyenv/bin/python protobuf setuptools
cd chiaki-ng
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCHIAKI_ENABLE_TESTS=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_GUI=OFF \
  -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_ENABLE_SPEEX=OFF -DCHIAKI_USE_SYSTEM_NANOPB=OFF \
  -DCHIAKI_USE_SYSTEM_JERASURE=OFF -DCHIAKI_USE_SYSTEM_CURL=ON -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DPython_EXECUTABLE="$PWD/../pyenv/bin/python" \
  "-DCMAKE_PREFIX_PATH=/opt/homebrew/opt/curl;/opt/homebrew/opt/openssl@3;/opt/homebrew" \
  -DCMAKE_OSX_SYSROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
cmake --build build -j8
