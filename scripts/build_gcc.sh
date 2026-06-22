#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build libstdc++ from GCC source for both amd64 and arm64
# Looks like libstdc++ is very dependant on the version of GCC is it built with.  
# When building with github actions (https://github.com/actions/runner-images), the default image is
# Ubuntu 24.04. It has GCC 13.2.0, To simplify building this, We are sticking with 13.2.0 for this build.

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
readonly GCC_SRC_DIR="${BUILD_DIR}/gcc"
readonly GCC_BUILD_DIR_AMD64="${BUILD_DIR}/gcc_amd64_build"
readonly GCC_OUT_DIR_AMD64="${BUILD_DIR}/gcc_amd64_out"
readonly GCC_BUILD_DIR_ARM64="${BUILD_DIR}/gcc_arm64_build"
readonly GCC_OUT_DIR_ARM64="${BUILD_DIR}/gcc_arm64_out"
readonly LOG_DIR="${BUILD_DIR}/logs"

# Default options
BUILD_AMD64=1
BUILD_ARM64=1
CLEAN_BUILD=0
VERBOSE=0
JOBS=$(nproc)
BLACKDUCK_SCAN=0

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Build libstdc++ from GCC source for amd64 and arm64.

OPTIONS:
    --amd64-only        Build only for amd64
    --arm64-only        Build only for arm64
    --clean             Clean existing build directories before building
    --verbose           Show build output instead of logging to file
    --jobs N            Number of parallel jobs (default: $(nproc))
    --blackduck-scan    Run Black Duck scan on the build output (amd64 only)
    -h, --help          Show this help message

PREREQUISITES:
    - GCC source tarball (downloaded via download_gcc.sh)
    - Build tools (gcc, g++, make, etc.)
    - For ARM64 cross-compilation: gcc-aarch64-linux-gnu, g++-aarch64-linux-gnu

EXAMPLES:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} --amd64-only
    ${SCRIPT_NAME} --clean

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
        --amd64-only)
            BUILD_ARM64=0
            shift
            ;;
        --arm64-only)
            BUILD_AMD64=0
            shift
            ;;
        --clean)
            CLEAN_BUILD=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --jobs)
            JOBS="$2"
            shift 2
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

# Validate prerequisites
validate_prerequisites() {
    log "Validating prerequisites..."
    if [[ ! -f "${SOURCE_DIR}/${GCC_NAME}" ]]; then
        error "GCC source not found: ${SOURCE_DIR}/${GCC_NAME}"
        error "Run ./scripts/download_gcc.sh first"
        exit 1
    fi
    if [[ $BUILD_ARM64 -eq 1 ]] && ! command -v aarch64-linux-gnu-gcc &> /dev/null; then
        error "ARM64 cross-compiler not found. Install with: sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
        exit 1
    fi
    log "Prerequisites validated successfully"
}

# Setup build directories
setup_directories() {
    if [[ $CLEAN_BUILD -eq 1 ]]; then
        log "Cleaning build directories..."
        rm -rf "$GCC_SRC_DIR" "$GCC_BUILD_DIR_AMD64" "$GCC_OUT_DIR_AMD64" "$GCC_BUILD_DIR_ARM64" "$GCC_OUT_DIR_ARM64"
    fi
    mkdir -p "$GCC_SRC_DIR" "$GCC_BUILD_DIR_AMD64" "$GCC_OUT_DIR_AMD64" "$GCC_BUILD_DIR_ARM64" "$GCC_OUT_DIR_ARM64" "$LOG_DIR"
}

# Extract GCC source
extract_source() {
    if [[ -d "${GCC_SRC_DIR}/gcc-${GCC_VERSION}" ]]; then
        log "GCC source already extracted"
    else
        log "Extracting GCC source..."
        tar -xf "${SOURCE_DIR}/${GCC_NAME}" -C "$GCC_SRC_DIR"
        log "GCC source extracted to ${GCC_SRC_DIR}"
    fi

    pushd "${GCC_SRC_DIR}/gcc-${GCC_VERSION}" > /dev/null
    log "Downloading GCC prerequisites..."
    ./contrib/download_prerequisites
    popd > /dev/null
    log "GCC prerequisites downloaded."
}

# Build libstdc++ for a specific architecture
build_arch() {
    local arch="$1"
    local build_dir=""
    local out_dir=""
    local configure_args=()
    local build_log="${LOG_DIR}/gcc_${arch}_build.log"
    local install_log="${LOG_DIR}/gcc_${arch}_install.log"

    if [[ "$arch" == "amd64" ]]; then
        build_dir="$GCC_BUILD_DIR_AMD64"
        out_dir="$GCC_OUT_DIR_AMD64"
        configure_args=(
            "--host=x86_64-linux-gnu"
            "--target=x86_64-linux-gnu"
        )
    elif [[ "$arch" == "arm64" ]]; then
        build_dir="$GCC_BUILD_DIR_ARM64"
        out_dir="$GCC_OUT_DIR_ARM64"
        configure_args=(
            "--host=aarch64-linux-gnu"
            "--target=aarch64-linux-gnu"
        )
    else
        error "Unknown architecture: $arch"
        return 1
    fi

    log "Building libstdc++ for ${arch}..."

    pushd "$build_dir" > /dev/null

    local configure_cmd=("${GCC_SRC_DIR}/gcc-${GCC_VERSION}/configure"
        "${configure_args[@]}"
        "--prefix=${out_dir}"
        "--disable-multilib"
        "--enable-languages=c,c++"
        "--disable-bootstrap"
        "--disable-libstdcxx-pch"
        "--enable-threads=posix"
    )

    log "Configuring GCC for ${arch}..."
    if [[ $VERBOSE -eq 1 ]]; then
        "${configure_cmd[@]}"
    else
        log "  → Log: ${build_log}"
        # Ensure a clean log file
        "${configure_cmd[@]}" > "$build_log" 2>&1
    fi

    log "Running make for ${arch}..."
    if [[ $VERBOSE -eq 1 ]]; then
        make -j"$JOBS" all-target-libstdc++-v3
    else
        log "  → Log: ${build_log}"
        make -j"$JOBS" all-target-libstdc++-v3 >> "$build_log" 2>&1
    fi

    log "Running make install for ${arch}..."
    if [[ $VERBOSE -eq 1 ]]; then
        make install-target-libstdc++-v3
    else
        log "  → Log: ${install_log}"
        make install-target-libstdc++-v3 > "$install_log" 2>&1
    fi

    popd > /dev/null
    log "libstdc++ for ${arch} built successfully in ${out_dir}"
}

run_blackduck_scan() {
    log "Starting Black Duck scan for gcc..."

    if [[ -z "${BLACKDUCK_HUBDETECT_TOKEN:-}" ]]; then
        error "BLACKDUCK_HUBDETECT_TOKEN environment variable must be set for Black Duck scan"
        exit 1
    fi

    if [[ ! -d "$GCC_OUT_DIR_AMD64" ]]; then
        error "amd64 output directory not found: $GCC_OUT_DIR_AMD64"
        error "Please build for amd64 first."
        return 1
    fi

    log "Changing to directory: $GCC_OUT_DIR_AMD64"
    pushd "$GCC_OUT_DIR_AMD64" > /dev/null

    log "Running Synopsys Detect for autonomous scan..."
    
    if ! bash <(curl -s https://raw.githubusercontent.com/DACH-NY/security-blackduck/master/synopsys-detect) ci-build "$BLACKDUCK_PROJECT_NAME" "gcc-${GCC_VERSION}" --detect.autonomous.scan.enabled=true; then
        error "Black Duck scan failed."
        popd > /dev/null
        return 1
    fi

    popd > /dev/null
    log "Black Duck scan finished."
}

# Main function
main() {
    log "Starting libstdc++ build process"
    log "Architectures: AMD64=${BUILD_AMD64}, ARM64=${BUILD_ARM64}"
    log "Jobs: $JOBS"
    log "Verbose: $VERBOSE"
    log "Black Duck Scan: ${BLACKDUCK_SCAN}"

    validate_prerequisites
    setup_directories
    extract_source

    if [[ $BUILD_AMD64 -eq 1 ]]; then
        build_arch "amd64"
    fi

    if [[ $BUILD_ARM64 -eq 1 ]]; then
        build_arch "arm64"
    fi

    # Run Blackduck scan if enabled
    if [[ $BLACKDUCK_SCAN -eq 1 ]] && [[ $BUILD_AMD64 -eq 1 ]]; then
        run_blackduck_scan
    elif [[ $BLACKDUCK_SCAN -eq 1 ]]; then
        log "Skipping Black Duck scan as amd64 build was not requested."
    fi

    log "libstdc++ build complete!"
    [[ $VERBOSE -eq 0 ]] && log "Build logs are in ${LOG_DIR}"
}

# Run main function
main
