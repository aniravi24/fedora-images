#!/usr/bin/bash
# Root-side build helper. Two modes:
#
#   ./build-and-disk.sh vm            build the image locally, then a qcow2 to boot-test
#   ./build-and-disk.sh iso           build an installable ISO from the published image
#   ./build-and-disk.sh qcow2 <image>  qcow2 from any local bootc image, to boot-test
#
# Root throughout: bootc-image-builder refuses to run rootless.
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" = 0 ] || { echo "must run as root (sudo $0 $*)" >&2; exit 1; }

MODE="${1:-vm}"
OWNER="${SUDO_USER:?run via sudo}"
IMAGE=ghcr.io/aniravi24/aurora-ani
BLUEBUILD="/home/$OWNER/.local/bin/bluebuild"

case "$MODE" in
  vm)
    [ -f vm-config.toml ] || { echo "vm-config.toml missing (gitignored, local only)" >&2; exit 1; }

    # bluebuild's final :latest tag fails if an older image holds the name.
    podman rmi localhost/aurora-ani:latest >/dev/null 2>&1 || true

    echo "==> [1/2] building image"
    "$BLUEBUILD" build -B podman -I podman recipes/recipe.yml

    # bluebuild leaves the arch-suffixed tag; point :latest at it.
    podman tag localhost/aurora-ani:latest_linux_amd64 localhost/aurora-ani:latest

    echo "==> [2/2] building bootable disk"
    rm -rf output && mkdir -p output
    podman run --rm --privileged \
      --security-opt label=type:unconfined_t \
      -v ./output:/output \
      -v ./vm-config.toml:/config.toml:ro \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      quay.io/centos-bootc/bootc-image-builder:latest \
      --type qcow2 --rootfs btrfs localhost/aurora-ani

    chown -R "$OWNER:users" output
    echo "==> done: $(du -h output/qcow2/disk.qcow2 | cut -f1)"
    ;;

  iso)
    # iso [<image-ref> [variant [name]]]
    #
    # ALWAYS from a published image ref, never from a recipe. `generate-iso
    # recipe` builds the image locally, and a local build has no registry name
    # to record - so the installed system ends up with its BASE image as its
    # bootc source (quay.io/fedora-ostree-desktops/base:44 rather than ours).
    # That box then has no route to updates, and `bootc upgrade` would replace
    # the customised OS with stock Fedora. Publish first, then build the ISO.
    REF="${2:-$IMAGE}"; VARIANT="${3:-kinoite}"; NAME="${4:-aurora-ani.iso}"
    mkdir -p output
    # xorriso refuses to write into an existing non-empty target.
    rm -f "output/$NAME" "output/$NAME-CHECKSUM"
    echo "==> building $NAME from $REF (variant $VARIANT)"
    "$BLUEBUILD" generate-iso --variant "$VARIANT" --output-dir ./output \
      --iso-name "$NAME" image "$REF"
    chown -R "$OWNER:users" output
    echo "==> done: $(du -h "output/$NAME" | cut -f1)"
    ;;

  qcow2)
    # Boot-test any locally built bootc image without publishing it first.
    SRC="${2:?usage: $0 qcow2 <local-image-ref|oci-archive.tar>}"
    # bluebuild builds rootless, bootc-image-builder reads the ROOTFUL store,
    # so accept a `podman save` archive and load it here.
    case "$SRC" in
      *.tar)
        [ -f "$SRC" ] || { echo "no such archive: $SRC" >&2; exit 1; }
        echo "==> loading $SRC into the rootful store"
        SRC=$(podman load -q -i "$SRC" | sed 's/.*: //' | tail -1)
        echo "    loaded as $SRC"
        ;;
    esac
    OUT="output-$(echo "$SRC" | tr '/:' '__')"
    [ -f vm-config.toml ] || { echo "vm-config.toml missing (gitignored, local only)" >&2; exit 1; }
    podman image exists "$SRC" || { echo "no such local image: $SRC" >&2; exit 1; }
    echo "==> building qcow2 from $SRC"
    rm -rf "$OUT" && mkdir -p "$OUT"
    podman run --rm --privileged \
      --security-opt label=type:unconfined_t \
      -v "./$OUT":/output \
      -v ./vm-config.toml:/config.toml:ro \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      quay.io/centos-bootc/bootc-image-builder:latest \
      --type qcow2 --rootfs btrfs "$SRC"
    chown -R "$OWNER:users" "$OUT"
    echo "==> done: $OUT/qcow2/disk.qcow2 ($(du -h "$OUT"/qcow2/disk.qcow2 | cut -f1))"
    ;;

  fcos-live)
    # Build a Fedora CoreOS *live installer* ISO from a local container image.
    # bluebuild generate-iso cannot do this: on a CoreOS base its Anaconda
    # output installs but never boots, because CoreOS expects an Ignition
    # layout. osbuild needs Fedora + loop devices, hence the privileged
    # container rather than running it on the host.
    ARCHIVE="${2:?usage: $0 fcos-live <path-to.ociarchive>}"
    [ -f "$ARCHIVE" ] || { echo "no such archive: $ARCHIVE" >&2; exit 1; }
    OUT="$PWD/output"
    mkdir -p "$OUT"
    cp -f "$ARCHIVE" "$OUT/fcos-wifi.ociarchive"
    echo "==> building live ISO via osbuild (privileged fedora container)"
    podman run --rm --privileged \
      --security-opt label=disable \
      -v "$OUT":/work:z -w /work \
      registry.fedoraproject.org/fedora:42 bash -c '
        set -e
        dnf install -y -q osbuild osbuild-tools osbuild-ostree podman jq \
          xfsprogs e2fsprogs dosfstools genisoimage squashfs-tools \
          erofs-utils syslinux-nonlinux git >/dev/null
        git clone -q --depth 1 https://github.com/coreos/custom-coreos-disk-images.git /tmp/ccdi
        cd /tmp/ccdi
        ./custom-coreos-disk-images.sh \
          --ociarchive /work/fcos-wifi.ociarchive \
          --osname fedora-coreos \
          --platforms live
        cp -v /tmp/ccdi/*live-iso*.iso /work/ 2>/dev/null || cp -v ./*live-iso*.iso /work/
      '
    chown -R "$OWNER:users" "$OUT"
    echo "==> done:"
    ls -lh "$OUT"/*live-iso*.iso 2>/dev/null || echo "  no ISO produced"
    ;;

  *)
    echo "usage: $0 [vm|iso|qcow2 <image>|fcos-live <image>]" >&2; exit 1 ;;
esac
