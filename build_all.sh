#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

## Root directory of the playground
# NOTE: This can also be the absolute path to the playground directory
# Install compilers for arm  sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
set -e

source da_build.conf

# Default options
BLACKDUCK_SCAN_FLAG=""

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --blackduck-scan)
            BLACKDUCK_SCAN_FLAG="--blackduck-scan"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

rm -rf ${BUILD_DIR}/*

# Build Required components
echo "Build Components"

if [[ -n "$BLACKDUCK_SCAN_FLAG" ]]; then
    # Unpack pre-built binaries
    echo "Unpacking pre-built binaries..."
    ./scripts/unpack_and_scan.sh --clean --arch amd64 $BLACKDUCK_SCAN_FLAG nodejs
    ./scripts/unpack_and_scan.sh --clean --arch amd64 $BLACKDUCK_SCAN_FLAG openjdk
    ./scripts/unpack_and_scan.sh --clean --arch amd64 $BLACKDUCK_SCAN_FLAG tini
    ./scripts/unpack_and_scan.sh --clean --arch amd64 $BLACKDUCK_SCAN_FLAG grpc_health_probe
fi

## Build GCC (for libstdc++)
./scripts/build_gcc.sh $BLACKDUCK_SCAN_FLAG

## Build GLIBC
./scripts/build_glibc.sh $BLACKDUCK_SCAN_FLAG

## Build BusyBox
./scripts/build_busybox.sh $BLACKDUCK_SCAN_FLAG
./scripts/build_busybox.sh --full $BLACKDUCK_SCAN_FLAG

## Build ncurses
./scripts/build_ncurses.sh $BLACKDUCK_SCAN_FLAG

## Build Bash
./scripts/build_bash.sh $BLACKDUCK_SCAN_FLAG

## Build tzdata
./scripts/build_tzdb.sh $BLACKDUCK_SCAN_FLAG

## Build Libxcrypt
./scripts/build_libxcrypt.sh $BLACKDUCK_SCAN_FLAG

## Build Screen
./scripts/build_screen.sh $BLACKDUCK_SCAN_FLAG

## Build jemalloc
./scripts/build_jemalloc.sh $BLACKDUCK_SCAN_FLAG

echo "Build All Complete"
