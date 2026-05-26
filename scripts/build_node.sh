#!/usr/bin/env bash

# Copyright (c) canton-base-images contributors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build Node.js for both amd64 and arm64

set -euo pipefail

# Source environment configuration
if [[ ! -f da_build.conf ]]; then
    echo "Error: da_build.conf file not found" >&2
    exit 1
fi
source da_build.conf

# Application configuration
if [[ ! -f artifacts.json ]]; then
    echo "Error: artifacts.json file not found" >&2
    exit 1
fi
while IFS=$'\t' read -r outer_key inner_key value; do
  readonly "${outer_key}_${inner_key}"="$value"
done < <(jq -r '.SOURCE | to_entries[] | .key as $outer_key | .value | to_entries[] |  [$outer_key, .key, .value] | @tsv' artifacts.json)

# Script configuration
readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

# Default options
BUILD_AMD64=1
BUILD_ARM64=1

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

This script is a placeholder for building Node.js.
Since we are using pre-compiled binaries, no build steps are necessary.

OPTIONS:
    --amd64-only        Skip arm64
    --arm64-only        Skip amd64
    -h, --help          Show this help message
EOF
}

# Log function with timestamps
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Error function
error() {
    echo "[$SCRIPT_NAME] ERROR: $*" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --amd64-only)
            BUILD_ARM64=0
            shift
            ;;
        --arm64-only)
            BUILD_AMD64=0
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

log "Node.js build script started."
log "Using pre-compiled binaries, so no build is necessary."

if [[ $BUILD_AMD64 -eq 1 ]]; then
    log "AMD64 binary location: ${SOURCE_DIR}/${NODEJS_X86_NAME}"
fi
if [[ $BUILD_ARM64 -eq 1 ]]; then
    log "ARM64 binary location: ${SOURCE_DIR}/${NODEJS_ARM_NAME}"
fi

log "Node.js build script finished."
