#!/bin/sh
# Runs inside swift:6.2 with the repo mounted at /src; see build-linux-bundle.sh.
set -eu
: "${ARCH:?}" "${ZMX_COMMIT:?}" "${ZIG_VERSION:?}"
work=/tmp/gcbundle
rm -rf "$work"
mkdir -p "$work/bundle/bin"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl git xz-utils >/dev/null

# A separate build path keeps the host checkout's macOS .build untouched. The static
# stdlib spares task images from needing the Swift runtime; glibc is still required, so
# musl images (Alpine) are out of reach for this bundle.
swift build -c release --static-swift-stdlib --build-path "$work/swift"
cp "$work/swift/release/graphcode" "$work/swift/release/graphcoded" "$work/bundle/bin/"

curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-$ARCH-linux-$ZIG_VERSION.tar.xz" \
  | tar -xJ -C "$work"
git clone -q https://github.com/scgopi/zmx.git "$work/zmx"
git -C "$work/zmx" checkout -q "$ZMX_COMMIT"
# ReleaseFast: a Debug zmx is visibly slower than a plain PTY.
(cd "$work/zmx" && "$work/zig-$ARCH-linux-$ZIG_VERSION/zig" build -Doptimize=ReleaseFast)
cp "$work/zmx/zig-out/bin/zmx" "$work/bundle/bin/"

for binary in "$work"/bundle/bin/*; do
  echo "== $(basename "$binary")"
  ldd "$binary" || true
done
tar -czf "/src/Tools/harbor-graphcode/dist/graphcode-linux-$ARCH.tar.gz" -C "$work/bundle" bin
