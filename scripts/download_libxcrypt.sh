#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download and verify libxcrypt source code

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
readonly BASE_URL="https://github.com/besser82/libxcrypt/releases/download/v${LIBXCRYPT_VERSION}"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

# Default options
FORCE_DOWNLOAD=0
SKIP_VERIFY=0

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Download failed with exit code $exit_code" >&2
        # Clean up partial downloads
        [[ -f "${SOURCE_DIR}/${LIBXCRYPT_NAME}.tmp" ]] && rm -f "${SOURCE_DIR}/${LIBXCRYPT_NAME}.tmp"
        [[ -f "${SOURCE_DIR}/${LIBXCRYPT_NAME}.asc.tmp" ]] && rm -f "${SOURCE_DIR}/${LIBXCRYPT_NAME}.asc.tmp"
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Download and verify libxcrypt source code with GPG signature validation.

OPTIONS:
    --force             Force re-download even if file exists
    --skip-verify       Skip GPG signature verification (not recommended)
    -h, --help          Show this help message

PREREQUISITES:
    - wget
    - gpg

EXAMPLES:
    ${SCRIPT_NAME}                    # Download and verify
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
        --skip-verify)
            SKIP_VERIFY=1
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

# Import GPG key
import_gpg_key() {
    local keyid="$1"

    if gpg --list-keys "$keyid" &> /dev/null; then
        log "GPG key ${keyid} already imported"
        return 0
    fi

    log "Importing GPG key ${keyid}..."
    local attempt=1

    while [[ $attempt -le $MAX_RETRIES ]]; do
        if gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$keyid" &> /dev/null; then
            log "Successfully imported GPG key"
            return 0
        else
            error "Failed to import GPG key (attempt ${attempt}/${MAX_RETRIES})"

            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log "Retrying in ${RETRY_DELAY} seconds..."
                sleep $RETRY_DELAY
            fi

            ((attempt++))
        fi
    done

    error "Failed to import GPG key after ${MAX_RETRIES} attempts"
    return 1
}

# Main script execution
main() {
    mkdir -p "${SOURCE_DIR}"

    local libxcrypt_tarball="${LIBXCRYPT_NAME}"
    local libxcrypt_sig="${LIBXCRYPT_NAME}.asc"
    local libxcrypt_tarball_path="${SOURCE_DIR}/${libxcrypt_tarball}"
    local libxcrypt_sig_path="${SOURCE_DIR}/${libxcrypt_sig}"

    if [[ $FORCE_DOWNLOAD -eq 1 && -f "$libxcrypt_tarball_path" ]]; then
        log "Force option is set. Deleting existing file: $libxcrypt_tarball_path"
        rm -f "$libxcrypt_tarball_path"
    fi

    if [[ -f "$libxcrypt_tarball_path" ]]; then
        log "File already exists: $libxcrypt_tarball_path. Skipping download."
    else
        log "Downloading libxcrypt source: ${BASE_URL}/${libxcrypt_tarball}"
        wget --progress=bar:force:noscroll -O "${libxcrypt_tarball_path}.tmp" "${BASE_URL}/${libxcrypt_tarball}"
        mv "${libxcrypt_tarball_path}.tmp" "$libxcrypt_tarball_path"
    fi

    if [[ $SKIP_VERIFY -eq 0 ]]; then
        import_gpg_key "$LIBXCRYPT_KEYID"
        log "Downloading libxcrypt signature: ${BASE_URL}/${libxcrypt_sig}"
        wget --progress=bar:force:noscroll -O "${libxcrypt_sig_path}.tmp" "${BASE_URL}/${libxcrypt_sig}"
        mv "${libxcrypt_sig_path}.tmp" "$libxcrypt_sig_path"

        log "Verifying GPG signature..."
        gpg --verify "$libxcrypt_sig_path" "$libxcrypt_tarball_path"
        log "GPG signature is valid."
    else
        log "Skipping GPG verification."
    fi

    log "Download and verification complete."
}

main "$@"
