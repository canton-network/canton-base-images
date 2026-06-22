#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build timezone database using zic (timezone compiler)
# Creates compiled zoneinfo files from IANA tzdb source

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
readonly TZDB_SOURCE_DIR="${BUILD_DIR}/tzdb"
readonly TZDB_OUT="${BUILD_DIR}/tzdb_out"
readonly LOG_DIR="${BUILD_DIR}/logs"
readonly VERSION_STAMP="${BUILD_DIR}/.tzdb_version"

# Default options
CLEAN_BUILD=0
SKIP_EXISTING=0
VERBOSE=0
INCLUDE_LEAPSECONDS=0
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

Build timezone database from IANA tzdb source using zic compiler.

OPTIONS:
    --clean             Clean build directories before building
    --force             Force clean rebuild (ignores any existing outputs)
    --skip-existing     Skip build if output directory already exists
    --with-leapseconds  Include leap-second aware zones (right/ directory)
    --verbose, -v       Enable verbose output
    --blackduck-scan    Run Black Duck scan on the build output
    --help, -h          Show this help message

DESCRIPTION:
    Compiles IANA timezone database source files into binary zoneinfo files
    using the zic (zone information compiler) tool. Creates the standard
    directory structure expected by glibc and other timezone-aware software.

    Output directory: ${TZDB_OUT}/
      - usr/share/zoneinfo/     Main timezone files
      - usr/share/zoneinfo/posix/  POSIX-compliant zones (no leap seconds)
      - usr/share/zoneinfo/right/  Leap-second aware zones (optional)

REQUIRES:
    - zic command (from tzdata or tzcode package)
    - Source tarball: ${SOURCE_DIR}/${TZDB_NAME}

EXAMPLES:
    # Standard build
    ${SCRIPT_NAME}

    # Clean build with leap seconds
    ${SCRIPT_NAME} --clean --with-leapseconds

    # Skip if already built
    ${SCRIPT_NAME} --skip-existing

EOF
}

# Logging functions
log() {
    echo "[$(date +'%F %T')] $*"
}

log_verbose() {
    [[ $VERBOSE -eq 1 ]] && echo "[$(date +'%F %T')] $*" || true
}

err() {
    echo "[$(date +'%F %T')] ERROR: $*" >&2
}

die() {
    err "$*"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check for zic compiler
    if ! command -v zic &> /dev/null; then
        die "zic command not found. Install tzdata or tzcode package (apt-get install tzdata)"
    fi

    # Check for source tarball
    if [[ ! -f "${SOURCE_DIR}/${TZDB_NAME}" ]]; then
        die "Source tarball not found: ${SOURCE_DIR}/${TZDB_NAME}"
    fi

    log_verbose "Prerequisites check passed"
}

# Parse command-line arguments
parse_args() {
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
            --with-leapseconds)
                INCLUDE_LEAPSECONDS=1
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --blackduck-scan)
                BLACKDUCK_SCAN=1
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                err "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Clean build directories
clean_build_dirs() {
    log "Cleaning build directories..."
    rm -rf "${TZDB_SOURCE_DIR}" "${TZDB_OUT}"
}

# Extract source tarball
extract_source() {
    log "Extracting tzdb source..."

    mkdir -p "${TZDB_SOURCE_DIR}"

    # Extract based on compression format
    if [[ "${TZDB_NAME}" == *.tar.lz ]]; then
        tar --lzip -xf "${SOURCE_DIR}/${TZDB_NAME}" -C "${TZDB_SOURCE_DIR}"
    elif [[ "${TZDB_NAME}" == *.tar.xz ]]; then
        tar -xJf "${SOURCE_DIR}/${TZDB_NAME}" -C "${TZDB_SOURCE_DIR}"
    elif [[ "${TZDB_NAME}" == *.tar.gz ]]; then
        tar -xzf "${SOURCE_DIR}/${TZDB_NAME}" -C "${TZDB_SOURCE_DIR}"
    else
        die "Unsupported tarball format: ${TZDB_NAME}"
    fi
}

# Compile timezone data
compile_zones() {
    log "Compiling timezone database..."

    mkdir -p "${TZDB_OUT}/usr/share/zoneinfo"

    cd "${TZDB_SOURCE_DIR}"

    # Main data files to compile
    local data_files=(
        africa
        antarctica
        asia
        australasia
        europe
        northamerica
        southamerica
        etcetera
        backward
    )

    # Check which files exist (some releases combine them differently)
    local existing_files=()
    for file in "${data_files[@]}"; do
        if [[ -f "${file}" ]]; then
            existing_files+=("${file}")
        else
            log_verbose "Skipping missing data file: ${file}"
        fi
    done

    if [[ ${#existing_files[@]} -eq 0 ]]; then
        die "No timezone data files found in ${TZDB_SOURCE_DIR}"
    fi

    log "Compiling ${#existing_files[@]} data files: ${existing_files[*]}"

    # Compile main zones (no leap seconds)
    for data_file in "${existing_files[@]}"; do
        log_verbose "Processing ${data_file}..."
        if ! zic -d "${TZDB_OUT}/usr/share/zoneinfo" "${data_file}"; then
            err "Failed to compile ${data_file}"
            return 1
        fi
    done

    # Create posix subdirectory (POSIX-compliant, no leap seconds)
    log_verbose "Creating POSIX zones..."
    mkdir -p "${TZDB_OUT}/usr/share/zoneinfo/posix"
    for data_file in "${existing_files[@]}"; do
        zic -d "${TZDB_OUT}/usr/share/zoneinfo/posix" -L /dev/null "${data_file}" 2>/dev/null || true
    done

    # Optionally create right subdirectory (with leap seconds)
    if [[ $INCLUDE_LEAPSECONDS -eq 1 ]]; then
        if [[ -f leap-seconds.list ]]; then
            log "Creating leap-second aware zones (right/)..."
            mkdir -p "${TZDB_OUT}/usr/share/zoneinfo/right"
            for data_file in "${existing_files[@]}"; do
                zic -d "${TZDB_OUT}/usr/share/zoneinfo/right" -L leap-seconds.list "${data_file}" 2>/dev/null || true
            done
        else
            err "WARNING: leap-seconds.list not found, skipping right/ directory"
        fi
    fi

    # Create version marker
    echo "${TZDB_VERSION}" > "${TZDB_OUT}/usr/share/zoneinfo/tzdb-version"

    # Count compiled zones
    local zone_count
    zone_count=$(find "${TZDB_OUT}/usr/share/zoneinfo" -type f ! -name "tzdb-version" | wc -l)
    log "Compiled ${zone_count} timezone files"
}

# Create symlinks for common timezone names
create_symlinks() {
    log_verbose "Creating common timezone symlinks..."

    cd "${TZDB_OUT}/usr/share/zoneinfo"

    # UTC is the most common default
    if [[ -f UTC ]]; then
        ln -sf UTC UCT 2>/dev/null || true
        ln -sf UTC Universal 2>/dev/null || true
        ln -sf UTC Zulu 2>/dev/null || true
    fi
}

# Validate build output
validate_output() {
    log "Validating build output..."

    # Check for essential zones
    local essential_zones=(
        "UTC"
        "America/New_York"
        "Europe/London"
        "Asia/Tokyo"
    )

    local missing=0
    for zone in "${essential_zones[@]}"; do
        if [[ ! -f "${TZDB_OUT}/usr/share/zoneinfo/${zone}" ]]; then
            err "WARNING: Essential zone missing: ${zone}"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        err "WARNING: ${missing} essential zones are missing"
    fi

    # Check version file
    if [[ ! -f "${TZDB_OUT}/usr/share/zoneinfo/tzdb-version" ]]; then
        err "WARNING: Version marker not created"
    else
        local version
        version=$(cat "${TZDB_OUT}/usr/share/zoneinfo/tzdb-version")
        log "Built timezone database version: ${version}"
    fi
}

run_blackduck_scan() {
    log "Starting Black Duck scan for tzdb..."

    if [[ -z "${BLACKDUCK_HUBDETECT_TOKEN:-}" ]]; then
        error "BLACKDUCK_HUBDETECT_TOKEN environment variable must be set for Black Duck scan"
        exit 1
    fi

    if [[ ! -d "$TZDB_OUT" ]]; then
        error "Output directory not found: $TZDB_OUT"
        error "Please build first."
        return 1
    fi

    log "Changing to directory: $TZDB_OUT"
    pushd "$TZDB_OUT" > /dev/null

    log "Running Synopsys Detect for autonomous scan..."
    
    if ! bash <(curl -s https://raw.githubusercontent.com/DACH-NY/security-blackduck/master/synopsys-detect) ci-build "$BLACKDUCK_PROJECT_NAME" "tzdb" --detect.autonomous.scan.enabled=true; then
        error "Black Duck scan failed."
        popd > /dev/null
        return 1
    fi

    popd > /dev/null
    log "Black Duck scan finished."
}

# Main build function
build_tzdb() {
    log "Starting tzdb build (version ${TZDB_VERSION})..."
    # Detect version change and trigger automatic clean
    if [[ -f "${VERSION_STAMP}" ]]; then
        EXISTING_VER=$(cat "${VERSION_STAMP}" || true)
        if [[ "${EXISTING_VER}" != "${TZDB_VERSION}" ]]; then
            log "Detected tzdb version change: ${EXISTING_VER:-<none>} -> ${TZDB_VERSION}. Performing clean rebuild."
            CLEAN_BUILD=1
            SKIP_EXISTING=0
        fi
    fi

    # Check if we should skip
    if [[ $SKIP_EXISTING -eq 1 && -d "${TZDB_OUT}" ]]; then
        log "Output directory exists, skipping build (use --clean to rebuild)"
        return 0
    fi

    # Clean if requested
    if [[ $CLEAN_BUILD -eq 1 ]]; then
        clean_build_dirs
    fi

    # Create log directory
    mkdir -p "${LOG_DIR}"

    # Build steps
    check_prerequisites
    extract_source
    compile_zones
    create_symlinks
    validate_output
    # Record current version
    echo "${TZDB_VERSION}" > "${VERSION_STAMP}"

    # Run Blackduck scan if enabled
    if [[ $BLACKDUCK_SCAN -eq 1 ]]; then
        run_blackduck_scan
    fi

    log "Timezone database build complete: ${TZDB_OUT}"
    log "To use in rootfs: cp -r ${TZDB_OUT}/* /path/to/rootfs/"
}

# Main entry point
main() {
    parse_args "$@"

    local start_time
    start_time=$(date +%s)

    build_tzdb

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log "Build completed in ${duration} seconds"
    log "Force rebuild: ${FORCE_REBUILD}"
    log "Black Duck Scan: ${BLACKDUCK_SCAN}"
}

main "$@"
