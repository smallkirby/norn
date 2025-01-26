#!/bin/bash

set -eu

ZIGOUT=zig-out
IMGDIR=$ZIGOUT/img
OUTFILE=$(realpath "$IMGDIR/rootfs.cpio")

RESOURCEDIR=$(realpath "assets/rootfs")

cd "$RESOURCEDIR"
find . -print0 \
  | cpio --owner root:root --null -o --format=newc \
  > "$OUTFILE" \
  2>/dev/null
cd -
