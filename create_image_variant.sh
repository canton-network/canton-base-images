#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Build Docker image with specific rootfs variant
# This script helps automate building images with different variants

set -euo pipefail

# Default options
VARIANT="jdk"
IMAGE_TAG="" # backward-compat; prefer TAGS
TAGS=()
PLATFORMS="linux/amd64,linux/arm64"
PUSH=0
LOAD=0
DRY_RUN=0
ENABLE_SBOM=0
ENABLE_PROVENANCE=0
SBOM_OUTPUT=""
ENABLE_DIGEST_OUTPUT=0
DIGEST_OUTPUT_FILE=""
BLACKDUCK_SCAN=0

# Script configuration
readonly SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

source da_build.conf

# Help function
show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Build Docker image with a specific rootfs variant.

OPTIONS:
    --variant NAME       Use specific rootfs variant (default: jdk)
                         Options: minimal, base, jdk, full, node
    --tag NAME[,NAME...] Docker image tag(s) (required; comma-separated or repeatable)
    --platform LIST      Target platforms (default: linux/amd64,linux/arm64)
    --amd64-only        Build only amd64 platform
    --arm64-only        Build only arm64 platform
    --push              Push image to registry
    --load              Load image to local docker (single platform only)
    --sbom              Enable SBOM generation (experimental with GAR)
    --provenance        Enable provenance attestation (experimental with GAR)
    --sbom-output FILE  Save SBOM to file instead of pushing to registry
    --digest-output [FILE] Save image digest to a file (optional)
    --blackduck-scan    Run Black Duck scan on the built image (requires --load)
    --dry-run           Show Dockerfile and commands without executing
    -h, --help          Show this help message

NOTE:
    Google Artifact Registry (GAR) has limited support for image attestations.
    SBOM and provenance may not be visible in the registry UI or via standard
    tools. Consider using --sbom-output to save SBOM to a file for separate
    storage/analysis.

EXAMPLES:
    # Build jdk variant
    ${SCRIPT_NAME} --tag myapp:jdk

    # Build minimal variant for amd64 only
    ${SCRIPT_NAME} --variant minimal --tag myapp:minimal --amd64-only

    # Build full variant and push to registry
    ${SCRIPT_NAME} --variant full --tag myregistry.com/myapp:full --push

    # Test build configuration without executing
    ${SCRIPT_NAME} --variant base --tag myapp:test --dry-run

WORKFLOW:
    1. Create rootfs variant:
       ./scripts/create_rootfs.sh --variant <NAME>

    2. Build Docker image:
       ${SCRIPT_NAME} --variant <NAME> --tag <IMAGE:TAG>

    3. Test the image:
       docker run --rm --entrypoint /usr/bin/bash <IMAGE:TAG>

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
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        --tag)
            # Support comma-separated tags or repeated --tag flags
            IFS=',' read -ra _tag_parts <<< "$2"
            for _t in "${_tag_parts[@]}"; do
                _t_trim=$(echo "$_t" | xargs)
                [[ -n "$_t_trim" ]] && TAGS+=("$_t_trim")
            done
            shift 2
            ;;
        --platform)
            PLATFORMS="$2"
            shift 2
            ;;
        --amd64-only)
            PLATFORMS="linux/amd64"
            shift
            ;;
        --arm64-only)
            PLATFORMS="linux/arm64"
            shift
            ;;
        --push)
            PUSH=1
            shift
            ;;
        --load)
            LOAD=1
            shift
            ;;
        --sbom)
            ENABLE_SBOM=1
            shift
            ;;
        --provenance)
            ENABLE_PROVENANCE=1
            shift
            ;;
        --sbom-output)
            SBOM_OUTPUT="$2"
            ENABLE_SBOM=1
            shift 2
            ;;
        --digest-output)
            ENABLE_DIGEST_OUTPUT=1
            # Optional argument for filename
            if [[ $# -gt 1 ]] && ! [[ "$2" =~ ^-- ]]; then
                DIGEST_OUTPUT_FILE="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --blackduck-scan)
            BLACKDUCK_SCAN=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
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

# Validate arguments
if [[ ${#TAGS[@]} -eq 0 ]]; then
    error "At least one --tag is required"
    show_help
    exit 1
fi

if [[ $BLACKDUCK_SCAN -eq 1 ]]; then
    if [[ ${LOAD:-0} -eq 0 && ${PUSH:-0} -eq 0 ]]; then
        error "--blackduck-scan requires --load or --push to be specified"
        exit 1
    fi
fi

if [[ $BLACKDUCK_SCAN -eq 1 ]] && [[ -z "${BLACKDUCK_HUBDETECT_TOKEN:-}" ]]; then
    error "BLACKDUCK_HUBDETECT_TOKEN environment variable must be set for --blackduck-scan"
    exit 1
fi

if [[ $LOAD -eq 1 ]] && [[ "$(echo "$PLATFORMS" | tr ',' '\n' | wc -l)" -ne 1 ]]; then
    error "Only one architecture can be built when --load is requested"
    exit 1
fi

# Validate variant
case "$VARIANT" in
    certs|minimal|base|jdk|full|node)
        ;;
    *)
        error "Unknown variant: $VARIANT"
        error "Valid options: minimal, base, jdk, full, node"
        exit 1
        ;;
esac

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if rootfs exists
    local missing_rootfs=()
    
    if [[ "$PLATFORMS" == *"amd64"* ]] && [[ ! -d "rootfs_${VARIANT}_amd64" ]]; then
        missing_rootfs+=("rootfs_${VARIANT}_amd64")
    fi
    
    if [[ "$PLATFORMS" == *"arm64"* ]] && [[ ! -d "rootfs_${VARIANT}_arm64" ]]; then
        missing_rootfs+=("rootfs_${VARIANT}_arm64")
    fi
    
    if [[ ${#missing_rootfs[@]} -gt 0 ]]; then
        error "Missing rootfs directories:"
        for rootfs in "${missing_rootfs[@]}"; do
            error "  - $rootfs"
        done
        error ""
        error "Please create rootfs first:"
        error "  ./scripts/create_rootfs.sh --variant $VARIANT"
        exit 1
    fi
    
    # Check docker buildx
    if ! docker buildx version &> /dev/null; then
        error "docker buildx is required but not found"
        error "Please install docker buildx"
        exit 1
    fi

    if [[ ${ENABLE_DIGEST_OUTPUT} -eq 1 ]] && ! command -v jq &> /dev/null; then
        error "jq is required for --digest-output but not found"
        error "Please install jq"
        exit 1
    fi
    
    log "Prerequisites check passed"
}

# Create temporary Dockerfile with correct variant
create_temp_dockerfile() {
    local temp_dockerfile="$1"
    
    log "Creating temporary Dockerfile for variant: $VARIANT"
    
    # Read original Dockerfile and replace the COPY line
    sed "s|COPY --chown=root:root rootfs_.*_\$TARGETARCH /|COPY --chown=root:root rootfs_${VARIANT}_\$TARGETARCH /|" \
        config/Dockerfile > "$temp_dockerfile"
    
    log "Temporary Dockerfile created: $temp_dockerfile"
}

# Show Dockerfile for dry run
show_dockerfile() {
    local temp_dockerfile="$1"
    
    cat <<EOF

===========================================
Generated Dockerfile (variant: $VARIANT)
===========================================

EOF
    cat "$temp_dockerfile"
    cat <<EOF

===========================================

EOF
}

# Build Docker image
build_image() {
    local temp_dockerfile="$1"
    local metadata_file="$2"
    
    # Get build metadata
    local build_date
    build_date=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    
    local git_sha
    git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    
    local git_url
    git_url=$(git config --get remote.origin.url 2>/dev/null || echo "https://github.com/canton-network/canton-base-images")
    
    # Get version from date or tag
    local version
    version=$(cat VERSION)
    
    local buildx_args=(
        "buildx" "build"
        "--platform" "$PLATFORMS"
        "-f" "$temp_dockerfile"
        "--build-arg" "BUILD_DATE=${build_date}"
        "--build-arg" "VERSION=${version}"
        "--build-arg" "VCS_REF=${git_sha}"
        "--build-arg" "VCS_URL=${git_url}"
        "--build-arg" "VARIANT=${VARIANT}"
    )

    if [[ -n "${metadata_file}" ]]; then
        buildx_args+=("--metadata-file" "${metadata_file}")
    fi

    # Add all tags
    for t in "${TAGS[@]}"; do
        buildx_args+=("-t" "$t")
    done
    
    # Add SBOM generation
    if [[ $ENABLE_SBOM -eq 1 ]]; then
        if [[ -n "$SBOM_OUTPUT" ]]; then
            # Save SBOM to file (works reliably with all registries)
            log "SBOM will be saved to: $SBOM_OUTPUT"
            buildx_args+=("--sbom=true")
            buildx_args+=("--output" "type=registry,sbom-out=${SBOM_OUTPUT}")
        else
            # Attempt to attach SBOM to image (may not work with GAR)
            log "WARNING: SBOM attestation may not be stored in GAR"
            buildx_args+=("--sbom=true")
        fi
    fi
    
    # Add provenance attestation
    if [[ $ENABLE_PROVENANCE -eq 1 ]]; then
        log "WARNING: Provenance attestation may not be visible in GAR"
        buildx_args+=("--provenance=mode=max")
    fi
    
    if [[ $PUSH -eq 1 ]]; then
        buildx_args+=("--push")
    fi
    
    if [[ $LOAD -eq 1 ]]; then
        buildx_args+=("--load")
    fi
    
    buildx_args+=(".")
    
    log "Building Docker image..."
    log "Variant: $VARIANT"
    IFS=',' read -r -a _tags_copy <<< "${TAGS[*]}"
    log "Tags: ${TAGS[*]}"
    log "Platforms: $PLATFORMS"
    log "Version: $version"
    log "Git SHA: $git_sha"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo ""
        echo "Would execute:"
        echo "docker ${buildx_args[*]}"
        echo ""
    else
        docker "${buildx_args[@]}"
        if [[ ${ENABLE_DIGEST_OUTPUT} -eq 1 ]]; then
            digest=$(jq -r '.["containerimage.descriptor"].digest' "${metadata_file}")
            if [[ -z "${digest}" || "${digest}" == "null" || "${digest}" != sha256:* ]]; then
                error "Failed to extract valid image digest from metadata file '${metadata_file}'"
                return 1
            fi
            if [[ -n "${DIGEST_OUTPUT_FILE}" ]]; then
                echo "${digest}" > "${DIGEST_OUTPUT_FILE}"
                log "Image digest saved to ${DIGEST_OUTPUT_FILE}"
            else
                log "Image digest: ${digest}"
            fi
        fi
    fi
}

run_blackduck_scan() {
    local image_name="$1"
    log "Starting Black Duck scan for image: $image_name"

    local temp_tar_file
    temp_tar_file=$(mktemp)

    log "Saving image to temporary file: $temp_tar_file"
    if ! docker image save "$image_name" -o "$temp_tar_file"; then
        error "Failed to save docker image to tar file"
        rm -f "$temp_tar_file"
        return 1
    fi

    log "Running Synopsys Detect..."
    bash <(curl -s https://raw.githubusercontent.com/DACH-NY/security-blackduck/master/synopsys-detect) ci-build $BLACKDUCK_PROJECT_NAME "$image_name" -detect.tools=CONTAINER_SCAN --detect.container.scan.file.path="$temp_tar_file" --detect.tools.excluded=DETECTOR,SIGNATURE_SCAN

    log "Cleaning up temporary tar file: $temp_tar_file"
    rm -f "$temp_tar_file"

    log "Black Duck scan finished."
}

# Main function
main() {
    log "Starting Docker image build with variant: $VARIANT"
    
    # Validate push and load flags
    if [[ $PUSH -eq 1 ]] && [[ $LOAD -eq 1 ]]; then
        error "Cannot use --push and --load together"
        exit 1
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Create temporary Dockerfile
    local temp_dockerfile="Dockerfile.tmp.${VARIANT}"
    create_temp_dockerfile "$temp_dockerfile"
    
    # Create temporary metadata file if needed
    local metadata_file=""
    if [[ ${ENABLE_DIGEST_OUTPUT} -eq 1 ]]; then
        metadata_file=$(mktemp)
    fi

    # Show Dockerfile if dry run
    if [[ $DRY_RUN -eq 1 ]]; then
        show_dockerfile "$temp_dockerfile"
    fi
    
    # Build image
    build_image "$temp_dockerfile" "$metadata_file"
    
    # Run Black Duck scan if enabled
    if [[ $BLACKDUCK_SCAN -eq 1 ]] && [[ $DRY_RUN -eq 0 ]]; then
        run_blackduck_scan "${TAGS[0]}"
    fi

    # Cleanup
    if [[ $DRY_RUN -eq 0 ]]; then
        rm -f "$temp_dockerfile"
        if [[ -n "${metadata_file}" ]]; then
            rm -f "${metadata_file}"
        fi
    else
        log "Temporary Dockerfile kept for inspection: $temp_dockerfile"
    fi
    
    if [[ $DRY_RUN -eq 0 ]]; then
        log ""
        log "Docker image build complete!"
        log "Images: ${TAGS[*]}"
        log "Variant: $VARIANT"
        log ""
        log "To test the image:"
        # Suggest using the first tag
        log "  docker run -it --rm --tmpfs /tmp ${TAGS[0]}"
    fi
}

# Run main function
main
