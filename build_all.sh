#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

## Root directory of the playground
# NOTE: This can also be the absolute path to the playground directory
# Install compilers for arm  sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
set -e


source da_build.conf

rm -rf ${BUILD_DIR}/*

# Build Required components
echo "Build Components"

## Build Node.js
./scripts/build_node.sh

## Build GCC (for libstdc++)
./scripts/build_gcc.sh

## Build GLIBC
./scripts/build_glibc.sh

## Build BusyBox
./scripts/build_busybox.sh
./scripts/build_busybox.sh --full

## Build ncurses
./scripts/build_ncurses.sh

## Build Bash
./scripts/build_bash.sh

## Build tzdata
./scripts/build_tzdb.sh

## Build Libxcrypt
./scripts/build_libxcrypt.sh

## Build Screen
./scripts/build_screen.sh

## Build jemalloc
./scripts/build_jemalloc.sh

echo "Build All Complete"
