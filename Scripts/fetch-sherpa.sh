#!/bin/sh
# Tải thư viện sherpa-onnx dựng sẵn (dùng cho giọng AI offline) vào Vendor/sherpa-onnx.
set -e
VER=${SHERPA_VERSION:-v1.13.8}
ARCH=$(uname -m); [ "$ARCH" = "arm64" ] || ARCH=x64
cd "$(dirname "$0")/.."
[ -f Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ] && exit 0
mkdir -p Vendor && cd Vendor
NAME=sherpa-onnx-$VER-osx-$ARCH-shared
echo "Tải $NAME…"
curl -fL -o s.tar.bz2 "https://github.com/k2-fsa/sherpa-onnx/releases/download/$VER/$NAME.tar.bz2"
tar xjf s.tar.bz2 && rm s.tar.bz2
rm -rf sherpa-onnx && mv "$NAME" sherpa-onnx && rm -rf sherpa-onnx/bin
