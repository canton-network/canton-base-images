#!/usr/bin/env bash

# Copyright (c) canton-base-images contributors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download and verify Node.js binaries for both amd64 and arm64

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
readonly BASE_URL="https://nodejs.org/dist/v${NODEJS_VERSION}"
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

# Default options
FORCE_DOWNLOAD=0
SKIP_VERIFY=0
VERBOSE=0
DOWNLOAD_AMD64=1
DOWNLOAD_ARM64=1

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Download failed with exit code $exit_code" >&2
        # Clean up partial downloads
        [[ -f "${SOURCE_DIR}/${NODEJS_X86_NAME}.tmp" ]] && rm -f "${SOURCE_DIR}/${NODEJS_X86_NAME}.tmp"
        [[ -f "${SOURCE_DIR}/${NODEJS_ARM_NAME}.tmp" ]] && rm -f "${SOURCE_DIR}/${NODEJS_ARM_NAME}.tmp"
        [[ -f "${SOURCE_DIR}/SHASUMS256.txt.tmp" ]] && rm -f "${SOURCE_DIR}/SHASUMS256.txt.tmp"
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Download and verify Node.js binaries for amd64 and arm64
with SHA256 checksum validation.

OPTIONS:
    --force             Force re-download even if file exists
    --skip-verify       Skip SHA256 checksum verification (not recommended)
    --verbose           Show detailed download progress
    --amd64-only        Download only amd64 binary
    --arm64-only        Download only arm64 binary
    -h, --help          Show this help message

PREREQUISITES:
    - wget
    - gpg
    - sha256sum

EXAMPLES:
    ${SCRIPT_NAME}                    # Download both architectures
    ${SCRIPT_NAME} --force            # Force re-download
    ${SCRIPT_NAME} --amd64-only       # Download only amd64

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
        --amd64-only)
            DOWNLOAD_ARM64=0
            shift
            ;;
        --arm64-only)
            DOWNLOAD_AMD64=0
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

    if ! command -v sha256sum &> /dev/null; then
        error "sha256sum not found. Install with: sudo apt-get install coreutils"
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

# Verify checksum
verify_checksum() {
    local checksum_file="$1"
    local data_file="$2"
    local description="$3"

    log "Verifying SHA256 checksum for ${description}..."

    if (cd "$(dirname "$checksum_file")" && grep "$(basename "$data_file")" "$(basename "$checksum_file")" | sha256sum -c -); then
        log "✓ Checksum verification successful"
        return 0
    else
        error "✗ Checksum verification failed for ${description}"
        return 1
    fi
}

# Download and verify single architecture
download_arch() {
    local arch="$1"
    local package_name="$2"
    local checksum_file="$3"

    local package_file="${SOURCE_DIR}/${package_name}"

    log "Processing Node.js ${arch}..."

    # Check if already downloaded
    if [[ $FORCE_DOWNLOAD -eq 0 ]] && [[ -f "$package_file" ]]; then
        log "Package already exists: ${package_file}"
        if [[ $SKIP_VERIFY -eq 0 ]]; then
            if verify_checksum "$checksum_file" "$package_file" "Node.js ${arch}"; then
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

    # Download package
    if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$package_file" ]]; then
        download_file "${BASE_URL}/${package_name}" "$package_file" "Node.js ${arch} package" || return 1
    fi

    # Skip verification if requested
    if [[ $SKIP_VERIFY -eq 1 ]]; then
        log "Skipping checksum verification (--skip-verify flag used)"
        return 0
    fi

    # Verify checksum
    verify_checksum "$checksum_file" "$package_file" "Node.js ${arch}" || return 1
}

# Main download function
download_nodejs() {
    local checksum_file="${SOURCE_DIR}/SHASUMS256.txt"
    local sig_file="${SOURCE_DIR}/SHASUMS256.txt.sig"

    # Download checksum and signature files
    if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$checksum_file" ]]; then
        download_file "${BASE_URL}/SHASUMS256.txt" "$checksum_file" "Node.js checksums" || return 1
    fi
    if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$sig_file" ]]; then
        download_file "${BASE_URL}/SHASUMS256.txt.sig" "$sig_file" "Node.js checksums signature" || return 1
    fi

    # Import GPG key and verify checksum file signature
    if [[ $SKIP_VERIFY -eq 0 ]]; then
        import_gpg_key "$NODEJS_KEYID" || return 1
        if ! gpg --verify "$sig_file" "$checksum_file"; then
            error "GPG signature verification failed for SHASUMS256.txt"
            return 1
        fi
        log "✓ GPG signature for SHASUMS256.txt verified successfully"
    fi

    # Download amd64
    if [[ $DOWNLOAD_AMD64 -eq 1 ]]; then
        download_arch "amd64" "$NODEJS_X86_NAME" "$checksum_file" || return 1
    fi

    # Download arm64
    if [[ $DOWNLOAD_ARM64 -eq 1 ]]; then
        download_arch "arm64" "$NODEJS_ARM_NAME" "$checksum_file" || return 1
    fi
}

# Main function
main() {
    log "Starting Node.js download process"
    log "Version: ${NODEJS_VERSION}"
    log "Destination: ${SOURCE_DIR}"
    log "AMD64: ${DOWNLOAD_AMD64}, ARM64: ${DOWNLOAD_ARM64}"

    validate_prerequisites
    setup_directories
    download_nodejs

    log "Download complete!"
    [[ $DOWNLOAD_AMD64 -eq 1 ]] && log "  - AMD64: ${SOURCE_DIR}/${NODEJS_X86_NAME}"
    [[ $DOWNLOAD_ARM64 -eq 1 ]] && log "  - ARM64: ${SOURCE_DIR}/${NODEJS_ARM_NAME}"
}

# Run main function
main
