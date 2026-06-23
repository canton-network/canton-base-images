#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build busybox for both amd64 and arm64 architectures (regular and full variants)

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
readonly BUSYBOX_X86_BUILD="${BUILD_DIR}/busybox_amd64_build"
readonly BUSYBOX_ARM_BUILD="${BUILD_DIR}/busybox_arm64_build"
readonly BUSYBOX_X86_OUT="${BUILD_DIR}/busybox_amd64_out"
readonly BUSYBOX_ARM_OUT="${BUILD_DIR}/busybox_arm64_out"
readonly BUSYBOX_X86_FULL_BUILD="${BUILD_DIR}/busybox_amd64_full_build"
readonly BUSYBOX_ARM_FULL_BUILD="${BUILD_DIR}/busybox_arm64_full_build"
readonly BUSYBOX_X86_FULL_OUT="${BUILD_DIR}/busybox_amd64_full_out"
readonly BUSYBOX_ARM_FULL_OUT="${BUILD_DIR}/busybox_arm64_full_out"
readonly LOG_DIR="${BUILD_DIR}/logs"
readonly VERSION_STAMP="${BUILD_DIR}/.busybox_version"

# Default options
CLEAN_BUILD=0
SKIP_EXISTING=0
BUILD_JOBS=$(nproc)
BUILD_AMD64=1
BUILD_ARM64=1
BUILD_FULL=0
REINIT_CONFIG=0
VERBOSE=0
FORCE_REBUILD=0
BLACKDUCK_SCAN=0

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

Build busybox for amd64 and arm64 architectures.

OPTIONS:
    --clean             Clean build directories before building
    --force             Force clean rebuild (ignores any existing outputs)
    --skip-existing     Skip build if output directory already exists
    --jobs N            Number of parallel jobs (default: $(nproc))
    --amd64-only        Build only amd64 architecture
    --arm64-only        Build only arm64 architecture
    --full               Build full image with full busybox tools
    --reinit            Reinitialize .config file even if it exists
    --verbose           Show build output (default: send to log files)
    --blackduck-scan    Run Black Duck scan on the build output (amd64 only)
    -h, --help          Show this help message

PREREQUISITES:
    - Cross-compilation toolchain: gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
      Install with: sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

EXAMPLES:
    ${SCRIPT_NAME}                    # Build regular busybox for both architectures
    ${SCRIPT_NAME} --full              # Build full variant with all tools
    ${SCRIPT_NAME} --clean            # Clean build
    ${SCRIPT_NAME} --amd64-only       # Build only amd64
    ${SCRIPT_NAME} --reinit           # Reinitialize config files

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
        --force)
            CLEAN_BUILD=1
            FORCE_REBUILD=1
            SKIP_EXISTING=0
            shift
            ;;
        --skip-existing)
            SKIP_EXISTING=1
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
        --full)
            BUILD_FULL=1
            shift
            ;;
        --reinit)
            REINIT_CONFIG=1
            shift
            ;;
        --verbose)
            VERBOSE=1
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

# Validate prerequisites
validate_prerequisites() {
    log "Validating prerequisites..."

    # Check if source file exists
    if [[ ! -f "${SOURCE_DIR}/${BUSYBOX_NAME}" ]]; then
        error "Source file not found: ${SOURCE_DIR}/${BUSYBOX_NAME}"
        error "Run download_busybox.sh first"
        exit 1
    fi

    # Check if config files exist
    if [[ ! -f "${WORK_DIR}/config/busybox.config" ]]; then
        error "Config file not found: ${WORK_DIR}/config/busybox.config"
        exit 1
    fi

    if [[ $BUILD_FULL -eq 1 ]] && [[ ! -f "${WORK_DIR}/config/busybox.full.config" ]]; then
        error "Dev config file not found: ${WORK_DIR}/config/busybox.full.config"
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
        if [[ "$EXISTING_VER" != "$BUSYBOX_VERSION" ]]; then
            log "Detected busybox version change: ${EXISTING_VER:-<none>} -> ${BUSYBOX_VERSION}. Performing clean rebuild."
            CLEAN_BUILD=1
            SKIP_EXISTING=0
        fi
    fi

    if [[ $CLEAN_BUILD -eq 1 ]]; then
        log "Cleaning existing build directories..."
        rm -rf "$BUSYBOX_X86_BUILD" "$BUSYBOX_ARM_BUILD" \
               "$BUSYBOX_X86_OUT" "$BUSYBOX_ARM_OUT" \
               "$BUSYBOX_X86_FULL_BUILD" "$BUSYBOX_ARM_FULL_BUILD" \
               "$BUSYBOX_X86_FULL_OUT" "$BUSYBOX_ARM_FULL_OUT"
    fi

    mkdir -p "$BUSYBOX_X86_BUILD" "$BUSYBOX_ARM_BUILD" \
             "$BUSYBOX_X86_OUT" "$BUSYBOX_ARM_OUT" \
             "$BUSYBOX_X86_FULL_BUILD" "$BUSYBOX_ARM_FULL_BUILD" \
             "$BUSYBOX_X86_FULL_OUT" "$BUSYBOX_ARM_FULL_OUT" "$LOG_DIR"

    # Record current version
    echo "$BUSYBOX_VERSION" > "$VERSION_STAMP"
}

# Extract source code to build directory
extract_source() {
    local build_dir="$1"
    local variant="$2"

    if [[ -f "${build_dir}/Makefile" ]] && [[ $CLEAN_BUILD -eq 0 ]]; then
        log "Source already extracted for ${variant}, skipping..."
        return 0
    fi

    log "Extracting busybox source to ${variant}..."
    tar --strip-components=1 -C "$build_dir" -xf "${SOURCE_DIR}/${BUSYBOX_NAME}"
}

# Setup config for build
setup_config() {
    local build_dir="$1"
    local config_file="$2"
    local cross_prefix="$3"
    local variant="$4"

    if [[ -f "${build_dir}/.config" ]] && [[ $REINIT_CONFIG -eq 0 ]]; then
        log "Config already exists for ${variant}, skipping..."
        return 0
    fi

    log "Setting up config for ${variant}..."
    cp "$config_file" "${build_dir}/.config"
    sed -i "s/^CONFIG_CROSS_COMPILER_PREFIX=.*/CONFIG_CROSS_COMPILER_PREFIX=\"${cross_prefix}\"/" "${build_dir}/.config"
}

# Build busybox for specific architecture and variant
build_busybox() {
    local arch="$1"
    local build_dir="$2"
    local out_dir="$3"
    local cross_prefix="$4"
    local is_full="$5"

    local variant="$arch"
    [[ $is_full -eq 1 ]] && variant="${arch}-full"

    # Skip if output exists and skip flag is set
    if [[ $SKIP_EXISTING -eq 1 ]] && [[ -f "${out_dir}/bin/busybox" ]]; then
        log "Skipping ${variant} build (output already exists)"
        return 0
    fi

    log "Building busybox for ${variant}..."

    # Choose config file
    local config_file="${WORK_DIR}/config/busybox.config"
    [[ $is_full -eq 1 ]] && config_file="${WORK_DIR}/config/busybox.full.config"

    # Extract source
    extract_source "$build_dir" "$variant"

    # Setup config
    setup_config "$build_dir" "$config_file" "$cross_prefix" "$variant"

    pushd "$build_dir" > /dev/null

    local build_log="${LOG_DIR}/busybox_${variant}_build.log"
    local install_log="${LOG_DIR}/busybox_${variant}_install.log"

    # Build
    log "Compiling busybox for ${variant} (using ${BUILD_JOBS} jobs)..."
    if [[ $VERBOSE -eq 1 ]]; then
        if [[ "$arch" == "arm64" ]]; then
            make -j "$BUILD_JOBS" CONFIG_CROSS_COMPILER_PREFIX=gcc-aarch64-linux-gnu-
        else
            make -j "$BUILD_JOBS"
        fi
    else
        log "  → Log: ${build_log}"
        if [[ "$arch" == "arm64" ]]; then
            make -j "$BUILD_JOBS" CONFIG_CROSS_COMPILER_PREFIX=gcc-aarch64-linux-gnu- > "$build_log" 2>&1
        else
            make -j "$BUILD_JOBS" > "$build_log" 2>&1
        fi
    fi

    # Install
    log "Installing busybox for ${variant} to ${out_dir}..."
    if [[ $VERBOSE -eq 1 ]]; then
        if [[ "$arch" == "arm64" ]]; then
            make install CONFIG_PREFIX="$out_dir" CONFIG_CROSS_COMPILER_PREFIX=gcc-aarch64-linux-gnu-
        else
            make install CONFIG_PREFIX="$out_dir"
        fi
    else
        log "  → Log: ${install_log}"
        if [[ "$arch" == "arm64" ]]; then
            make install CONFIG_PREFIX="$out_dir" CONFIG_CROSS_COMPILER_PREFIX=gcc-aarch64-linux-gnu- > "$install_log" 2>&1
        else
            make install CONFIG_PREFIX="$out_dir" > "$install_log" 2>&1
        fi
    fi

    popd > /dev/null

    log "Successfully built busybox for ${variant}"
}

run_blackduck_scan() {
    log "Starting Black Duck scan for busybox..."

    if [[ -n "${DA_BLACKDUCK:-}" ]]; then
        export BLACKDUCK_HUBDETECT_TOKEN="${DA_BLACKDUCK}"
    fi

    if [[ -z "${BLACKDUCK_HUBDETECT_TOKEN:-}" ]]; then
        error "BLACKDUCK_HUBDETECT_TOKEN environment variable must be set for Black Duck scan"
        exit 1
    fi

    local project_name="${BLACKDUCK_PROJECT_OVERRIDE:-$BLACKDUCK_PROJECT_NAME}"
    local out_dir=$BUSYBOX_X86_OUT
    local app_name="busybox"
    if [[ $BUILD_FULL -eq 1 ]]; then
        out_dir=$BUSYBOX_X86_FULL_OUT
        app_name="busybox-full"
    fi

    if [[ ! -d "$out_dir" ]]; then
        error "amd64 output directory not found: $out_dir"
        error "Please build for amd64 first."
        return 1
    fi

    log "Changing to directory: $out_dir"
    pushd "$out_dir" > /dev/null

    log "Running Synopsys Detect for autonomous scan..."
    
    if ! bash <(curl -s https://raw.githubusercontent.com/DACH-NY/security-blackduck/master/synopsys-detect) ci-build "$project_name" "$app_name-$BUSYBOX_VERSION" --detect.autonomous.scan.enabled=true; then
        error "Black Duck scan failed."
        popd > /dev/null
        return 1
    fi

    popd > /dev/null
    log "Black Duck scan finished."
}

# Main function
main() {
    log "Starting busybox build process"
    log "Build configuration:"
    log "  - AMD64: ${BUILD_AMD64}"
    log "  - ARM64: ${BUILD_ARM64}"
    log "  - Dev variant: ${BUILD_FULL}"
    log "  - Jobs: ${BUILD_JOBS}"
    log "  - Clean build: ${CLEAN_BUILD}"
    log "  - Skip existing: ${SKIP_EXISTING}"
    log "  - Reinit config: ${REINIT_CONFIG}"
    log "  - Force rebuild: ${FORCE_REBUILD}"
    log "  - Black Duck Scan: ${BLACKDUCK_SCAN}"

    validate_prerequisites
    setup_directories

    # Build regular variants
    if [[ $BUILD_FULL -eq 0 ]]; then
        if [[ $BUILD_AMD64 -eq 1 ]]; then
            build_busybox "amd64" "$BUSYBOX_X86_BUILD" "$BUSYBOX_X86_OUT" "x86_64-linux-gnu-" 0
        fi

        if [[ $BUILD_ARM64 -eq 1 ]]; then
            build_busybox "arm64" "$BUSYBOX_ARM_BUILD" "$BUSYBOX_ARM_OUT" "aarch64-linux-gnu-" 0
        fi
    # Build full variants
    else
        if [[ $BUILD_AMD64 -eq 1 ]]; then
            build_busybox "amd64" "$BUSYBOX_X86_FULL_BUILD" "$BUSYBOX_X86_FULL_OUT" "x86_64-linux-gnu-" 1
        fi

        if [[ $BUILD_ARM64 -eq 1 ]]; then
            build_busybox "arm64" "$BUSYBOX_ARM_FULL_BUILD" "$BUSYBOX_ARM_FULL_OUT" "aarch64-linux-gnu-" 1
        fi
    fi

    # Run Blackduck scan if enabled
    if [[ $BLACKDUCK_SCAN -eq 1 ]] && [[ $BUILD_AMD64 -eq 1 ]]; then
        run_blackduck_scan
    elif [[ $BLACKDUCK_SCAN -eq 1 ]]; then
        log "Skipping Black Duck scan as amd64 build was not requested."
    fi

    log "Build complete!"
    log "Output locations:"
    if [[ $BUILD_FULL -eq 0 ]]; then
        [[ $BUILD_AMD64 -eq 1 ]] && log "  - AMD64: ${BUSYBOX_X86_OUT}"
        [[ $BUILD_ARM64 -eq 1 ]] && log "  - ARM64: ${BUSYBOX_ARM_OUT}"
    else
        [[ $BUILD_AMD64 -eq 1 ]] && log "  - AMD64-FULL: ${BUSYBOX_X86_FULL_OUT}"
        [[ $BUILD_ARM64 -eq 1 ]] && log "  - ARM64-FULL: ${BUSYBOX_ARM_FULL_OUT}"
    fi
    [[ $VERBOSE -eq 0 ]] && log "Build logs saved to: ${LOG_DIR}"
}

# Run main function
main
