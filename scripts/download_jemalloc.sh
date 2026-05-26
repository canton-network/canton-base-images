#!/usr/bin/env bash

# Copyright (c) canton-base-images contributors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download and verify jemalloc source code

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
readonly BASE_URL="https://github.com/jemalloc/jemalloc/releases/download/${JEMALLOC_VERSION}"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

# Default options
FORCE_DOWNLOAD=0

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Download failed with exit code $exit_code" >&2
        # Clean up partial downloads
        [[ -f "${SOURCE_DIR}/${JEMALLOC_NAME}.tmp" ]] && rm -f "${SOURCE_DIR}/${JEMALLOC_NAME}.tmp"
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Download jemalloc source code.

OPTIONS:
    --force             Force re-download even if file exists
    -h, --help          Show this help message

PREREQUISITES:
    - wget

EXAMPLES:
    ${SCRIPT_NAME}                    # Download
    ${SCRIPT_NAME} --force            # Force re-download

EOF
}

# Log function with timestamps
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Error function
error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_DOWNLOAD=1
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

# Main script execution
main() {
    mkdir -p "${SOURCE_DIR}"

    local jemalloc_tarball="${JEMALLOC_NAME}"
    local jemalloc_tarball_path="${SOURCE_DIR}/${jemalloc_tarball}"

    if [[ $FORCE_DOWNLOAD -eq 1 && -f "$jemalloc_tarball_path" ]]; then
        log "Force option is set. Deleting existing file: $jemalloc_tarball_path"
        rm -f "$jemalloc_tarball_path"
    fi

    if [[ -f "$jemalloc_tarball_path" ]]; then
        log "File already exists: $jemalloc_tarball_path. Skipping download."
    else
        log "Downloading jemalloc source: ${BASE_URL}/${jemalloc_tarball}"
        wget --progress=bar:force:noscroll -O "${jemalloc_tarball_path}.tmp" "${BASE_URL}/${jemalloc_tarball}"
        mv "${jemalloc_tarball_path}.tmp" "$jemalloc_tarball_path"
    fi

    log "Download complete."
}

main "$@"
