#!/bin/sh
# Builds dist/graphcode-linux-<arch>.tar.gz — bin/graphcode, bin/graphcoded and bin/zmx —
# the bundle the Harbor adapter uploads into each task container.
#
#   ARCH=x86_64 Tools/harbor-graphcode/build-linux-bundle.sh    # Terminal-Bench images
#   ARCH=aarch64 Tools/harbor-graphcode/build-linux-bundle.sh
#
# Needs docker (or a docker-compatible CLI) on the host. The arch must match the task
# images, not the host: Terminal-Bench images are linux/amd64, so on Apple Silicon this
# runs emulated and is slow.
set -eu
arch="${ARCH:-x86_64}"
case "$arch" in
  x86_64) platform=linux/amd64 ;;
  aarch64) platform=linux/arm64 ;;
  *) echo "build-linux-bundle: ARCH must be x86_64 or aarch64, got $arch" >&2; exit 2 ;;
esac
root="$(cd "$(dirname "$0")/../.." && pwd)"
# The zmx graphcode ships is the submodule pin (scgopi/zmx, ahead of upstream 0.7.0 with
# the kill-process-group fix), not an upstream release.
zmx_commit="$(git -C "$root" ls-tree HEAD ThirdParty/zmx | awk '{print $3}')"
[ -n "$zmx_commit" ] || { echo "build-linux-bundle: no ThirdParty/zmx pin in HEAD" >&2; exit 1; }
mkdir -p "$root/Tools/harbor-graphcode/dist"
docker run --rm --platform "$platform" \
  -v "$root:/src" -w /src \
  -e ARCH="$arch" -e ZMX_COMMIT="$zmx_commit" -e ZIG_VERSION="${ZIG_VERSION:-0.15.2}" \
  swift:6.2 sh /src/Tools/harbor-graphcode/build-in-container.sh
ls -l "$root/Tools/harbor-graphcode/dist/graphcode-linux-$arch.tar.gz"
