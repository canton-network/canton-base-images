#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Download and verify OpenJDK binaries for both amd64 and arm64

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
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5

# Default options
FORCE_DOWNLOAD=0
SKIP_VERIFY=0
VERBOSE=0
DOWNLOAD_AMD64=1
DOWNLOAD_ARM64=1
JDK_SELECTION="all"

# Supported JDK major versions mapped to their artifacts.json SOURCE key.
# 21 uses the historical "OPENJDK" key (default jdk image); 25 uses "OPENJDK25".
declare -A JDK_KEYS=(["21"]="OPENJDK" ["25"]="OPENJDK25")

# Per-run state set by select_jdk()
JDK_MAJOR=""
JDK_VERSION=""
JDK_X86_NAME=""
JDK_ARM_NAME=""
JDK_KEYID=""
BASE_URL=""

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Download failed with exit code $exit_code" >&2
        # Clean up partial downloads
        rm -f "${SOURCE_DIR}"/OpenJDK*U-jdk_*.tmp
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Download and verify OpenJDK (Adoptium Temurin) binaries for amd64 and arm64
with GPG signature validation.

OPTIONS:
    --force             Force re-download even if file exists
    --skip-verify       Skip GPG signature verification (not recommended)
    --verbose           Show detailed download progress
    --amd64-only        Download only amd64 binary
    --arm64-only        Download only arm64 binary
    --jdk VERSION       JDK major version to download: 21, 25 or all (default: all)
    -h, --help          Show this help message

PREREQUISITES:
    - wget
    - gpg

EXAMPLES:
    ${SCRIPT_NAME}                    # Download both architectures
    ${SCRIPT_NAME} --force            # Force re-download
    ${SCRIPT_NAME} --amd64-only       # Download only amd64
    ${SCRIPT_NAME} --jdk 25           # Download only JDK 25

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
        --jdk)
            if [[ $# -lt 2 ]]; then
                error "--jdk requires a value (21, 25 or all)"
                exit 1
            fi
            JDK_SELECTION="$2"
            shift 2
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

if [[ "$JDK_SELECTION" != "all" ]] && [[ ! -v "JDK_KEYS[$JDK_SELECTION]" ]]; then
    error "Unsupported --jdk value: ${JDK_SELECTION} (expected one of: ${!JDK_KEYS[*]}, all)"
    exit 1
fi

# Load artifact details for a JDK major version from the readonly SOURCE vars
select_jdk() {
    local major="$1"
    local key="${JDK_KEYS[$major]}"
    local v="${key}_VERSION" x="${key}_X86_NAME" a="${key}_ARM_NAME" k="${key}_KEYID"

    JDK_MAJOR="$major"
    JDK_VERSION="${!v}"
    JDK_X86_NAME="${!x}"
    JDK_ARM_NAME="${!a}"
    JDK_KEYID="${!k}"
    local version_tag
    version_tag="jdk-$(sed 's/_/%2B/' <<< "$JDK_VERSION")"
    BASE_URL="https://github.com/adoptium/temurin${major}-binaries/releases/download/${version_tag}"
}

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

# Download and verify single architecture
download_arch() {
    local arch="$1"
    local package_name="$2"

    local package_file="${SOURCE_DIR}/${package_name}"
    local sig_file="${SOURCE_DIR}/${package_name}.sig"

    log "Processing OpenJDK ${JDK_MAJOR} ${arch}..."

    # Check if already downloaded and verified
    if [[ $FORCE_DOWNLOAD -eq 0 ]] && [[ -f "$package_file" ]] && [[ -f "$sig_file" ]]; then
        log "Package already exists: ${package_file}"

        if [[ $SKIP_VERIFY -eq 0 ]]; then
            # Import key and verify existing file
            import_gpg_key "$JDK_KEYID" || return 1
            if verify_signature "$sig_file" "$package_file" "OpenJDK ${JDK_MAJOR} ${arch}"; then
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
        download_file "${BASE_URL}/${package_name}" "$package_file" "OpenJDK ${JDK_MAJOR} ${arch} package" || return 1
    fi

    # Download signature
    if [[ $FORCE_DOWNLOAD -eq 1 ]] || [[ ! -f "$sig_file" ]]; then
        download_file "${BASE_URL}/${package_name}.sig" "$sig_file" "OpenJDK ${JDK_MAJOR} ${arch} signature" || return 1
    fi

    # Skip verification if requested
    if [[ $SKIP_VERIFY -eq 1 ]]; then
        log "Skipping signature verification (--skip-verify flag used)"
        return 0
    fi

    # Verify signature
    verify_signature "$sig_file" "$package_file" "OpenJDK ${JDK_MAJOR} ${arch}" || return 1
}

# Main download function
download_openjdk() {
    # Import GPG key once for all downloads
    if [[ $SKIP_VERIFY -eq 0 ]]; then
        import_gpg_key "$JDK_KEYID" || return 1
    fi

    # Download amd64
    if [[ $DOWNLOAD_AMD64 -eq 1 ]]; then
        download_arch "amd64" "$JDK_X86_NAME" || return 1
    fi

    # Download arm64
    if [[ $DOWNLOAD_ARM64 -eq 1 ]]; then
        download_arch "arm64" "$JDK_ARM_NAME" || return 1
    fi
}

# Main function
main() {
    local majors=()
    if [[ "$JDK_SELECTION" == "all" ]]; then
        mapfile -t majors < <(printf '%s\n' "${!JDK_KEYS[@]}" | sort -n)
    else
        majors=("$JDK_SELECTION")
    fi

    log "Starting OpenJDK download process"
    log "JDK versions: ${majors[*]}"
    log "Destination: ${SOURCE_DIR}"
    log "AMD64: ${DOWNLOAD_AMD64}, ARM64: ${DOWNLOAD_ARM64}"

    validate_prerequisites
    setup_directories

    local major
    for major in "${majors[@]}"; do
        select_jdk "$major"
        log "OpenJDK ${JDK_MAJOR} version: ${JDK_VERSION}"
        download_openjdk

        log "OpenJDK ${JDK_MAJOR} download complete!"
        [[ $DOWNLOAD_AMD64 -eq 1 ]] && log "  - AMD64: ${SOURCE_DIR}/${JDK_X86_NAME}"
        [[ $DOWNLOAD_ARM64 -eq 1 ]] && log "  - ARM64: ${SOURCE_DIR}/${JDK_ARM_NAME}"
    done
    return 0
}

# Run main function
main
