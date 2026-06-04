#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#
# Validate the CycloneDX SBOM file inside a Docker image.
#
# Usage: ./scripts/validate_sbom.sh <image_name>
#

set -euo pipefail

# Script configuration
readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
readonly SBOM_PATH="/etc/sbom.cdx.json"

# Default options
IMAGE_NAME=""
VERBOSE=0
PLATFORM=""
local_sbom_file=""
temp_container_name=""

# Cleanup function to be called on exit
cleanup() {
    if [[ -n "${local_sbom_file}" && -f "${local_sbom_file}" ]]; then
        rm -f "${local_sbom_file}"
    fi
    if [[ -n "${temp_container_name}" ]]; then
        docker rm -f "${temp_container_name}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] IMAGE_NAME

Validate the CycloneDX SBOM file inside a Docker image.

OPTIONS:
    --platform PLATFORM The platform of the image to validate (e.g. linux/amd64)
    --verbose           Show verbose output
    -h, --help          Show this help message

EXAMPLE:
    ${SCRIPT_NAME} my-image:latest
    ${SCRIPT_NAME} --platform linux/arm64 my-image:latest

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
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --platform)
                PLATFORM="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$IMAGE_NAME" ]]; then
                    IMAGE_NAME="$1"
                    shift
                else
                    error "Too many arguments. Only one image name is allowed."
                    show_help
                    exit 1
                fi
                ;;
        esac
    done
}

# Main validation logic
validate_sbom() {
    log "Validating SBOM for image: ${IMAGE_NAME}"

    # Extract the SBOM from the container
    local_sbom_file=$(mktemp sbom_XXXXXX.json)

    # Create a temporary container to extract the SBOM
    temp_container_name="sbom-validation-${local_sbom_file}"
    local docker_create_cmd="docker create --name ${temp_container_name}"
    if [[ -n "$PLATFORM" ]]; then
        docker_create_cmd+=" --platform ${PLATFORM}"
    fi
    docker_create_cmd+=" ${IMAGE_NAME}"

    if ! eval "${docker_create_cmd}" >/dev/null; then
        error "Failed to create container from image ${IMAGE_NAME}"
        exit 1
    fi

    if ! docker cp "${temp_container_name}:${SBOM_PATH}" "${local_sbom_file}" >/dev/null; then
        error "Failed to extract SBOM from ${IMAGE_NAME}:${SBOM_PATH}"
        error "Does ${SBOM_PATH} exist in the image?"
        exit 1
    fi

    if [ ! -s "${local_sbom_file}" ]; then
        error "Extracted SBOM file is empty."
        exit 1
    fi

    # Validate the SBOM
    log "Validating SBOM using cyclonedx/cyclonedx-cli docker image..."
    local validation_output
    validation_output=$(docker run --rm -v "$(dirname "${local_sbom_file}"):/app" "cyclonedx/cyclonedx-cli" validate --input-file "/app/$(basename "${local_sbom_file}")" 2>&1)
    if [[ $? -eq 0 ]]; then
        log "SBOM for ${IMAGE_NAME} is valid."
        if [[ $VERBOSE -eq 1 ]]; then
            echo "${validation_output}"
        fi
    else
        error "SBOM validation failed for ${IMAGE_NAME}."
        echo "${validation_output}" >&2
        exit 1
    fi
}

# Main function
main() {
    parse_args "$@"

    # Validate image name
    if [[ -z "$IMAGE_NAME" ]]; then
        error "Image name not provided."
        show_help
        exit 1
    fi

    log "Starting SBOM validation process"
    validate_sbom
    log "SBOM validation complete!"
}

# Run main function
main "$@"
