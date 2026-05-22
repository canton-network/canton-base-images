#!/usr/bin/env bash

# Copyright (c) 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

## Root directory of the playground
# NOTE: This can also be the absolute path to the playground directory
# Install compilers for arm  sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
set -e


source da_build.conf

# Download Required components
echo "Download Components"

## Download GLIBC
./scripts/download_glibc.sh

## Download BusyBox
./scripts/download_busybox.sh

## Download ncurses
./scripts/download_ncurses.sh

## Download Bash
./scripts/download_bash.sh

## Download TimeZone Data
./scripts/download_tzdb.sh

## Download OPENJDK
./scripts/download_jdk.sh

## Download Node.js
./scripts/download_node.sh

## Download Tini
./scripts/download_tini.sh

## Download grpc-health-probe (for full variant)
./scripts/download_grpc-health-probe.sh

## Download Mozilla CA certificates
./scripts/download_cacerts.sh

## Download jemalloc
./scripts/download_jemalloc.sh

## Download libxcrypt
./scripts/download_libxcrypt.sh

## Download screen
./scripts/download_screen.sh

## Download GCC
./scripts/download_gcc.sh

echo "Download All Complete"
