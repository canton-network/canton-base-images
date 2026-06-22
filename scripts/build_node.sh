#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
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
BLACKDUCK_SCAN=0

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

This script is a placeholder for building Node.js.
Since we are using pre-compiled binaries, no build steps are necessary.

OPTIONS:
    --amd64-only        Skip arm64
    --arm64-only        Skip amd64
    --blackduck-scan    Run Black Duck scan on the build output
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

run_blackduck_scan() {
    log "Starting Black Duck scan for node..."

    if [[ -z "${BLACKDUCK_HUBDETECT_TOKEN:-}" ]]; then
        error "BLACKDUCK_HUBDETECT_TOKEN environment variable must be set for Black Duck scan"
        exit 1
    fi

    local application_name="node"
    local output_dir="${BUILD_DIR}/${application_name}_amd64_out"

    if [[ ! -d "$output_dir" ]]; then
        error "Output directory not found: $output_dir"
        error "Please build first."
        return 1
    fi

    log "Changing to directory: $output_dir"
    pushd "$output_dir" > /dev/null

    log "Running Synopsys Detect for autonomous scan..."
    
    if ! bash <(curl -s https://raw.githubusercontent.com/DACH-NY/security-blackduck/master/synopsys-detect) ci-build "$BLACKDUCK_PROJECT_NAME" "$application_name" --detect.autonomous.scan.enabled=true; then
        error "Black Duck scan failed."
        popd > /dev/null
        return 1
    fi

    popd > /dev/null
    log "Black Duck scan finished."
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
        --blackduck-scan)
            BLACKDUCK_SCAN=1
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

if [[ $BLACKDUCK_SCAN -eq 1 && $BUILD_AMD64 -eq 1 ]]; then
    run_blackduck_scan
fi

log "Node.js build script finished."
