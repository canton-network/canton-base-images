#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Unpack pre-built binaries and optionally run a Black Duck scan.

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

# Script configuration
readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

# Default options
BLACKDUCK_SCAN=0
CLEAN=0
TARGET_ARCH=""

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <application_name>

Unpacks pre-built binaries for a given application and optionally runs a Black Duck scan.

ARGUMENTS:
    application_name    The name of the application to unpack (e.g., node, jdk, tini, grpc-health-probe).

OPTIONS:
    --blackduck-scan    Run Black Duck scan on the unpacked output.
    --clean             Clean the output directory before unpacking.
    --arch <arch>       Specify the architecture (amd64 or arm64). Required.
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

# Die function
die() {
    error "$*"
    exit 1
}

# Parse command line arguments
if [[ $# -eq 0 ]]; then
    show_help
    exit 1
fi

APPLICATION_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --blackduck-scan)
            BLACKDUCK_SCAN=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            if [[ -z "$APPLICATION_NAME" ]]; then
                APPLICATION_NAME="$1"
                shift
            else
                error "Unknown argument: $1"
                show_help
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$APPLICATION_NAME" ]]; then
    die "Application name not specified."
fi

if [[ -z "$TARGET_ARCH" ]]; then
    die "Target architecture not specified. Use --arch [amd64|arm64]."
fi

if [[ "$TARGET_ARCH" != "amd64" && "$TARGET_ARCH" != "arm64" ]]; then
    die "Invalid architecture: $TARGET_ARCH. Must be 'amd64' or 'arm64'."
fi

# Get artifact details from artifacts.json
get_artifact_info() {
    local app_name_upper
    app_name_upper=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    local arch_suffix
    if [[ "$2" == "amd64" ]]; then
        arch_suffix="X86_NAME"
    else
        arch_suffix="ARM_NAME"
    fi
    jq -r ".SOURCE.${app_name_upper}.${arch_suffix}" artifacts.json
}

ARTIFACT_NAME=$(get_artifact_info "$APPLICATION_NAME" "$TARGET_ARCH")

if [[ -z "$ARTIFACT_NAME" || "$ARTIFACT_NAME" == "null" ]]; then
    die "Could not find artifact name for ${APPLICATION_NAME} and architecture ${TARGET_ARCH} in artifacts.json"
fi

readonly SOURCE_FILE="${SOURCE_DIR}/${ARTIFACT_NAME}"
readonly OUTPUT_DIR="${BUILD_DIR}/${APPLICATION_NAME}_${TARGET_ARCH}_out"

log "Processing ${APPLICATION_NAME} for ${TARGET_ARCH}"
log "Source archive: ${SOURCE_FILE}"
log "Output directory: ${OUTPUT_DIR}"

if [[ ! -f "$SOURCE_FILE" ]]; then
    die "Source file not found: $SOURCE_FILE. Please run the corresponding download script first."
fi

if [[ $CLEAN -eq 1 ]]; then
    log "Cleaning output directory: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
fi

mkdir -p "$OUTPUT_DIR"

log "Unpacking archive..."
case "$SOURCE_FILE" in
    *.tar.gz|*.tgz)
        tar -xzf "$SOURCE_FILE" -C "$OUTPUT_DIR" --strip-components=1
        ;;
    *.tar.xz)
        tar -xJf "$SOURCE_FILE" -C "$OUTPUT_DIR" --strip-components=1
        ;;
    *.zip)
        unzip -q "$SOURCE_FILE" -d "$OUTPUT_DIR"
        ;;
    *)
        # For single binaries like tini and grpc-health-probe
        if [[ "$APPLICATION_NAME" == "tini" || "$APPLICATION_NAME" == "grpc_health_probe" ]]; then
            mkdir -p "${OUTPUT_DIR}/bin"
            cp "$SOURCE_FILE" "${OUTPUT_DIR}/bin/"
            chmod +x "${OUTPUT_DIR}/bin/$(basename "$SOURCE_FILE")"
            log "Copied binary to ${OUTPUT_DIR}/bin/"
        else
            die "Unsupported archive format for $SOURCE_FILE"
        fi
        ;;
esac
log "Unpacking complete."

run_blackduck_scan() {
    log "Starting Black Duck scan for ${APPLICATION_NAME}..."

    if [[ -z "${BLACKDUCK_HUBDETECT_TOKEN:-}" ]]; then
        error "BLACKDUCK_HUBDETECT_TOKEN environment variable must be set for Black Duck scan"
        exit 1
    fi

    if [[ ! -d "$OUTPUT_DIR" ]]; then
        error "Output directory not found: $OUTPUT_DIR"
        return 1
    fi

    log "Changing to directory: $OUTPUT_DIR"
    pushd "$OUTPUT_DIR" > /dev/null

    log "Running Synopsys Detect for autonomous scan..."
    
    if ! bash <(curl -s https://raw.githubusercontent.com/DACH-NY/security-blackduck/master/synopsys-detect) ci-build "$BLACKDUCK_PROJECT_NAME" "$APPLICATION_NAME" --detect.autonomous.scan.enabled=true; then
        error "Black Duck scan failed."
        popd > /dev/null
        return 1
    fi

    popd > /dev/null
    log "Black Duck scan finished."
}

if [[ $BLACKDUCK_SCAN -eq 1 ]]; then
    run_blackduck_scan
fi

log "${APPLICATION_NAME} processing finished."
