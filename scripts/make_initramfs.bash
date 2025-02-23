#!/bin/bash

set -eu

ZIGOUT=zig-out
IMGDIR=$ZIGOUT/img
OUTFILE=$(realpath "$IMGDIR/rootfs.cpio")

RESOURCEDIR=$(realpath "assets/rootfs")
COPY_SOURCE=$(realpath "$ZIGOUT/rootfs")

# Copy generated binaries
find "$COPY_SOURCE" -type f | while read -r file; do
  dir=$(dirname "$file")
  mkdir -p "$RESOURCEDIR/${dir#"$COPY_SOURCE"}"
  cp "$file" "$RESOURCEDIR/${file#"$COPY_SOURCE"}"
done

# Create rootfs
cd "$RESOURCEDIR"
find . -print0 \
  | cpio --owner root:root --null -o --format=newc \
  > "$OUTFILE" \
  2>/dev/null
cd -
