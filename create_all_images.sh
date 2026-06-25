#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# This will build and push all images 

set -euo pipefail

BLACKDUCK_SCAN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --blackduck-scan)
            BLACKDUCK_SCAN=1
            shift
            ;;
        *)
            # Pass through other arguments
            shift
            ;;
    esac
done

BLACKDUCK_SCAN_ARGS=()
if [[ $BLACKDUCK_SCAN -eq 1 ]]; then
    BLACKDUCK_SCAN_ARGS+=("--blackduck-scan")
fi

source da_build.conf

if [[ "$(uname -m)" == "x86_64" ]]; then
    local_platform="linux/amd64"
    local_arch="amd64"
elif [[ "$(uname -m)" == "aarch64" ]]; then
    local_platform="linux/arm64"
    local_arch="arm64"
else
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
fi

local_repo="local-image"
version=$(cat VERSION)
timestamp=$(date +'%Y%m%d-%H%M')

# Download Required components
echo "Create Image"

bash ./scripts/create_rootfs.sh --variant certs --sbom-version 1 --clean --image-version "$version"
bash ./create_image_variant.sh --variant certs --tag "${local_repo}:certs-${version}" --tag "${local_repo}:certs-latest" --tag "${local_repo}:certs-${timestamp}" --platform "$local_platform" --load "${BLACKDUCK_SCAN_ARGS[@]}"
bash ./scripts/validate_sbom.sh "${local_repo}:certs-latest"

bash ./scripts/create_rootfs.sh --variant minimal --sbom-version 1 --clean --image-version "$version"
bash ./create_image_variant.sh --variant minimal --tag "${local_repo}:minimal-${version}" --tag "${local_repo}:minimal-latest" --tag "${local_repo}:minimal-${timestamp}" --platform "$local_platform" --load "${BLACKDUCK_SCAN_ARGS[@]}"
bash ./scripts/test_image.sh --variant minimal --tag "${local_repo}:minimal-latest"
bash ./scripts/validate_sbom.sh "${local_repo}:minimal-latest"

bash ./scripts/create_rootfs.sh --variant base --sbom-version 1 --clean --image-version "$version"
bash ./create_image_variant.sh --variant base --tag "${local_repo}:base-${version}" --tag "${local_repo}:base-latest" --tag "${local_repo}:base-${timestamp}" --platform "$local_platform" --load "${BLACKDUCK_SCAN_ARGS[@]}"
bash ./scripts/test_image.sh --variant base --tag "${local_repo}:base-latest"
bash ./scripts/validate_sbom.sh "${local_repo}:base-latest"

bash ./scripts/create_rootfs.sh --variant jdk --sbom-version 1 --clean --image-version "$version"
bash ./create_image_variant.sh --variant jdk --tag "${local_repo}:jdk-${version}" --tag "${local_repo}:jdk-latest" --tag "${local_repo}:jdk-${timestamp}" --platform "$local_platform" --load "${BLACKDUCK_SCAN_ARGS[@]}"
bash ./scripts/test_image.sh --variant jdk --tag "${local_repo}:jdk-latest"
bash ./scripts/validate_sbom.sh "${local_repo}:jdk-latest"

bash ./scripts/create_rootfs.sh --variant full --sbom-version 1 --clean --image-version "$version"
bash ./create_image_variant.sh --variant full --tag "${local_repo}:full-${version}" --tag "${local_repo}:full-latest" --tag "${local_repo}:full-${timestamp}" --platform "$local_platform" --load "${BLACKDUCK_SCAN_ARGS[@]}"
bash ./scripts/test_image.sh --variant full --tag "${local_repo}:full-latest"
bash ./scripts/validate_sbom.sh "${local_repo}:full-latest"

echo "Create Image Complete"
