#!/usr/bin/env bash

# Copyright (c) 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build glibc for both amd64 and arm64 architectures

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
readonly GLIBC_SOURCE_DIR="${BUILD_DIR}/glibc"
readonly GLIBC_X86_BUILD="${BUILD_DIR}/glibc_amd64_build"
readonly GLIBC_ARM_BUILD="${BUILD_DIR}/glibc_arm64_build"
readonly GLIBC_X86_OUT="${BUILD_DIR}/glibc_amd64_out"
readonly GLIBC_ARM_OUT="${BUILD_DIR}/glibc_arm64_out"
readonly LOG_DIR="${BUILD_DIR}/logs"
readonly VERSION_STAMP="${BUILD_DIR}/.glibc_version"

# Default options
CLEAN_BUILD=0
SKIP_EXISTING=0
BUILD_JOBS=$(nproc)
BUILD_AMD64=1
BUILD_ARM64=1
VERBOSE=0
FORCE_REBUILD=0

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Build failed with exit code $exit_code" >&2
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Build glibc for amd64 and arm64 architectures.

OPTIONS:
    --clean             Clean build directories before building
    --force             Force clean rebuild (ignores any existing outputs)
    --skip-existing     Skip build if output directory already exists
    --jobs N            Number of parallel jobs (default: $(nproc))
    --amd64-only        Build only amd64 architecture
    --arm64-only        Build only arm64 architecture
    --verbose           Show build output (default: send to log files)
    -h, --help          Show this help message

PREREQUISITES:
    - Cross-compilation toolchain: gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
      Install with: sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

EXAMPLES:
    ${SCRIPT_NAME}                    # Build both architectures
    ${SCRIPT_NAME} --clean            # Clean build
    ${SCRIPT_NAME} --amd64-only       # Build only amd64
    ${SCRIPT_NAME} --jobs 4           # Use 4 parallel jobs

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
        --clean)
            CLEAN_BUILD=1
            shift
            ;;
        --skip-existing)
            SKIP_EXISTING=1
            shift
            ;;
        --force)
            CLEAN_BUILD=1
            FORCE_REBUILD=1
            SKIP_EXISTING=0
            shift
            ;;
        --jobs)
            BUILD_JOBS="$2"
            shift 2
            ;;
        --amd64-only)
            BUILD_ARM64=0
            shift
            ;;
        --arm64-only)
            BUILD_AMD64=0
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

    # Check if source file exists
    if [[ ! -f "${SOURCE_DIR}/${GLIBC_NAME}" ]]; then
        error "Source file not found: ${SOURCE_DIR}/${GLIBC_NAME}"
        error "Run download_glibc.sh first"
        exit 1
    fi

    # Check for required compilers
    if [[ $BUILD_AMD64 -eq 1 ]] && ! command -v x86_64-linux-gnu-gcc &> /dev/null; then
        error "x86_64-linux-gnu-gcc not found"
        error "Install with: sudo apt-get install gcc-x86-64-linux-gnu g++-x86-64-linux-gnu"
        exit 1
    fi

    if [[ $BUILD_ARM64 -eq 1 ]] && ! command -v aarch64-linux-gnu-gcc &> /dev/null; then
        error "aarch64-linux-gnu-gcc not found"
        error "Install with: sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
        exit 1
    fi

    log "Prerequisites validated successfully"
}

# Setup build directories
setup_directories() {
    log "Setting up build directories..."
    # Detect version change and trigger automatic clean
    if [[ -f "$VERSION_STAMP" ]]; then
        EXISTING_VER=$(cat "$VERSION_STAMP" || true)
        if [[ "$EXISTING_VER" != "$GLIBC_VERSION" ]]; then
            log "Detected glibc version change: ${EXISTING_VER:-<none>} -> ${GLIBC_VERSION}. Performing clean rebuild."
            CLEAN_BUILD=1
            SKIP_EXISTING=0
        fi
    fi

    if [[ $CLEAN_BUILD -eq 1 ]]; then
        log "Cleaning existing build directories..."
        rm -rf "$GLIBC_SOURCE_DIR" "$GLIBC_X86_BUILD" "$GLIBC_ARM_BUILD" \
               "$GLIBC_X86_OUT" "$GLIBC_ARM_OUT"
    fi

    mkdir -p "$GLIBC_SOURCE_DIR" "$GLIBC_X86_BUILD" "$GLIBC_ARM_BUILD" \
             "$GLIBC_X86_OUT" "$GLIBC_ARM_OUT" "$LOG_DIR"

    # Record current version
    echo "$GLIBC_VERSION" > "$VERSION_STAMP"

    # Extract source code if not already extracted
    if [[ ! -f "${GLIBC_SOURCE_DIR}/configure" ]]; then
        log "Extracting glibc source..."
        tar --strip-components=1 -C "$GLIBC_SOURCE_DIR" -xf "${SOURCE_DIR}/${GLIBC_NAME}"
    else
        log "Source already extracted, skipping..."
    fi
}

# Build for specific architecture
build_arch() {
    local arch="$1"
    local build_dir="$2"
    local out_dir="$3"
    local host="$4"

    # Skip if output exists and skip flag is set
    if [[ $SKIP_EXISTING -eq 1 ]] && [[ -d "${out_dir}/usr/lib" ]]; then
        log "Skipping ${arch} build (output already exists)"
        return 0
    fi

    log "Building glibc for ${arch}..."

    pushd "$build_dir" > /dev/null

    local configure_log="${LOG_DIR}/glibc_${arch}_configure.log"
    local build_log="${LOG_DIR}/glibc_${arch}_build.log"
    local install_log="${LOG_DIR}/glibc_${arch}_install.log"

    # Configure if Makefile doesn't exist
    if [[ ! -f Makefile ]]; then
        log "Configuring glibc for ${arch}..."
        if [[ $VERBOSE -eq 1 ]]; then
            "${GLIBC_SOURCE_DIR}/configure" \
                --prefix=/usr \
                --enable-stack-protector=strong \
                --enable-locales \
                --host="${host}"
        else
            log "  → Log: ${configure_log}"
            "${GLIBC_SOURCE_DIR}/configure" \
                --prefix=/usr \
                --enable-stack-protector=strong \
                --enable-locales \
                --host="${host}" > "$configure_log" 2>&1
        fi
    fi

    # Build
    log "Compiling glibc for ${arch} (using ${BUILD_JOBS} jobs)..."
    if [[ $VERBOSE -eq 1 ]]; then
        make -j "$BUILD_JOBS"
    else
        log "  → Log: ${build_log}"
        make -j "$BUILD_JOBS" > "$build_log" 2>&1
    fi

    # Install
    log "Installing glibc for ${arch} to ${out_dir}..."
    if [[ $VERBOSE -eq 1 ]]; then
        make install DESTDIR="$out_dir"
        # make localedata/install-locales DESTDIR="$out_dir"
    else
        log "  → Log: ${install_log}"
        make install DESTDIR="$out_dir" > "$install_log" 2>&1
        # make localedata/install-locales DESTDIR="$out_dir" > "$install_log" 2>&1
    fi

    popd > /dev/null

    log "Successfully built glibc for ${arch}"
}

# Main function
main() {
    log "Starting glibc build process"
    log "Build configuration:"
    log "  - AMD64: ${BUILD_AMD64}"
    log "  - ARM64: ${BUILD_ARM64}"
    log "  - Jobs: ${BUILD_JOBS}"
    log "  - Clean build: ${CLEAN_BUILD}"
    log "  - Skip existing: ${SKIP_EXISTING}"
    log "  - Force rebuild: ${FORCE_REBUILD}"

    validate_prerequisites
    setup_directories

    # Build amd64
    if [[ $BUILD_AMD64 -eq 1 ]]; then
        build_arch "amd64" "$GLIBC_X86_BUILD" "$GLIBC_X86_OUT" "x86_64-linux-gnu"
    fi

    # Build arm64
    if [[ $BUILD_ARM64 -eq 1 ]]; then
        build_arch "arm64" "$GLIBC_ARM_BUILD" "$GLIBC_ARM_OUT" "aarch64-linux-gnu"
    fi

    log "Build complete!"
    log "Output locations:"
    [[ $BUILD_AMD64 -eq 1 ]] && log "  - AMD64: ${GLIBC_X86_OUT}"
    [[ $BUILD_ARM64 -eq 1 ]] && log "  - ARM64: ${GLIBC_ARM_OUT}"
    [[ $VERBOSE -eq 0 ]] && log "Build logs saved to: ${LOG_DIR}"
}

# Run main function
main
