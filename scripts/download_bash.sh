#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download and verify bash source code

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
readonly BASE_URL="https://gnu.mirror.constant.com/bash"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

# Default options
FORCE_DOWNLOAD=0
SKIP_VERIFY=0
VERBOSE=0

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Download failed with exit code $exit_code" >&2
        # Clean up partial downloads
        [[ -f "${SOURCE_DIR}/${BASH_NAME}.tmp" ]] && rm -f "${SOURCE_DIR}/${BASH_NAME}.tmp"
        [[ -f "${SOURCE_DIR}/${BASH_NAME}.sig.tmp" ]] && rm -f "${SOURCE_DIR}/${BASH_NAME}.sig.tmp"
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Download and verify bash source code with GPG signature validation.

OPTIONS:
    --force             Force re-download even if file exists
    --skip-verify       Skip GPG signature verification (not recommended)
    --verbose           Show detailed download progress
    -h, --help          Show this help message

PREREQUISITES:
    - wget
    - gpg

EXAMPLES:
    ${SCRIPT_NAME}                    # Download and verify
    ${SCRIPT_NAME} --force            # Force re-download
    ${SCRIPT_NAME} --verbose          # Show download progress

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
        --verbose)
            VERBOSE=1
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

# Validate prerequisites
validate_prerequisites() {
    log "Validating prerequisites..."

    if ! command -v wget &> /dev/null; then
        error "wget not found. Install with: sudo apt-get install wget"
        exit 1
    fi

    if ! command -v gpg &> /dev/null; then
        error "gpg not found. Install with: sudo apt-get install gnupg"
        exit 1
    fi

    log "Prerequisites validated successfully"
}

# Setup directories
setup_directories() {
    mkdir -p "$SOURCE_DIR"
}

# Download file with retry logic
download_file() {
    local url="$1"
    local output_file="$2"
    local description="$3"

    local attempt=1
    local wget_opts="-O ${output_file}.tmp"

    if [[ $VERBOSE -eq 0 ]]; then
        wget_opts+=" -q --show-progress"
    fi

    while [[ $attempt -le $MAX_RETRIES ]]; do
        log "Downloading ${description} (attempt ${attempt}/${MAX_RETRIES})..."

        if wget $wget_opts "$url"; then
            mv "${output_file}.tmp" "$output_file"
            log "Successfully downloaded ${description}"
            return 0
        else
            error "Download failed (attempt ${attempt}/${MAX_RETRIES})"
            rm -f "${output_file}.tmp"

            if [[ $attempt -lt $MAX_RETRIES ]]; then
                log "Retrying in ${RETRY_DELAY} seconds..."
                sleep $RETRY_DELAY
            fi

            ((attempt++))
        fi
    done

    error "Failed to download ${description} after ${MAX_RETRIES} attempts"
    return 1
}

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

# Verify GPG signature
verify_signature() {
    local sig_file="$1"
    local data_file="$2"
    local description="$3"

    log "Verifying GPG signature for ${description}..."

    if gpg --verify "$sig_file" "$data_file" &> /dev/null; then
        log "✓ Signature verification successful"
        return 0
    else
        error "✗ Signature verification failed for ${description}"
        gpg --verify "$sig_file" "$data_file"
        return 1
    fi
}

# Main download function
download_bash() {
    local source_file="${SOURCE_DIR}/${BASH_NAME}"
    local sig_file="${SOURCE_DIR}/${BASH_NAME}.sig"

    # Check if already downloaded and verified
    if [[ $FORCE_DOWNLOAD -eq 0 ]] && [[ -f "$source_file" ]] && [[ -f "$sig_file" ]]; then
        log "Source file already exists: ${source_file}"

        if [[ $SKIP_VERIFY -eq 0 ]]; then
            # Import key and verify existing file
            import_gpg_key "$BASH_KEYID" || return 1
            if verify_signature "$sig_file" "$source_file" "bash"; then
                log "Existing file verified successfully, skipping download"
                return 0
            else
                log "Existing file verification failed, re-downloading..."
                FORCE_DOWNLOAD=1
            fi
        else
            log "Skipping verification, using existing file"
            return 0
        fi
    fi

    # Download source
    if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$source_file" ]]; then
        download_file "${BASE_URL}/${BASH_NAME}" "$source_file" "bash source" || return 1
    fi

    # Download signature
    if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$sig_file" ]]; then
        download_file "${BASE_URL}/${BASH_NAME}.sig" "$sig_file" "bash signature" || return 1
    fi

    # Skip verification if requested
    if [[ $SKIP_VERIFY -eq 1 ]]; then
        log "Skipping signature verification (--skip-verify flag used)"
        return 0
    fi

    # Import GPG key
    import_gpg_key "$BASH_KEYID" || return 1

    # Verify signature
    verify_signature "$sig_file" "$source_file" "bash" || return 1
}

# Download and verify patches
download_patches() {
    log "Downloading and verifying bash patches..."
    import_gpg_key "$BASH_KEYID" || return 1

    local BASH_PATCH_NAME_PREFIX="bash${BASH_VERSION//.}"

    for i in $(seq -f "%03g" 1 99); do
        local patch_name="${BASH_PATCH_NAME_PREFIX}-${i}"
        local patch_file="${SOURCE_DIR}/${patch_name}"
        local sig_file="${SOURCE_DIR}/${patch_name}.sig"
        local patch_url="https://ftp.gnu.org/gnu/bash/bash-${BASH_VERSION}-patches/${patch_name}"
        local sig_url="https://ftp.gnu.org/gnu/bash/bash-${BASH_VERSION}-patches/${patch_name}.sig"

        # Download patch
        if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$patch_file" ]]; then
            download_file "$patch_url" "$patch_file" "$patch_name" || {
                log "Could not download patch ${patch_name}, assuming no more patches."
                break
            }
        fi

        # Download signature
        if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$sig_file" ]]; then
            download_file "$sig_url" "$sig_file" "${patch_name} signature" || {
                log "Could not download signature for ${patch_name}, assuming no more patches."
                break
            }
        fi

        # Verify signature
        if [[ $SKIP_VERIFY -eq 0 ]]; then
            verify_signature "$sig_file" "$patch_file" "$patch_name" || return 1
        else
            log "Skipping signature verification for ${patch_name}"
        fi
    done
}

# Main function
main() {
    log "Starting bash download process"
    log "Package: ${BASH_NAME}"
    log "Destination: ${SOURCE_DIR}"

    validate_prerequisites
    setup_directories
    download_bash
    download_patches

    log "Download complete!"
    log "File: ${SOURCE_DIR}/${BASH_NAME}"
}

# Run main function
main
