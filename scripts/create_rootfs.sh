#!/usr/bin/env bash

# Copyright 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Create root filesystem for Docker containers with multiple variant support

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
readonly VARIANTS_CONFIG_FILE="${WORK_DIR}/config/variants.json"
readonly HOST_ARCH=$(uname -m)

# Variant definitions
declare -A VARIANTS
while IFS='=' read -r key value; do
    VARIANTS["$key"]="$value"
done < <(jq -r '.variants | to_entries[] | "\(.key)=\(.value.description)"' "${VARIANTS_CONFIG_FILE}")

# Default options
VARIANT="jdk"
BUILD_AMD64=1
BUILD_ARM64=1
CLEAN_BUILD=0
SBOM_VERSION=0
IMAGE_VERSION=""

# Architecture mappings
declare -A tini_map
declare -A jdk_map
declare -A grpc_health_probe_map
declare -A nodejs_map
tini_map=(["amd64"]="tini-amd64" ["arm64"]="tini-arm64")
jdk_map=(["amd64"]="OpenJDK21U-jre_x64_linux_hotspot_" ["arm64"]="OpenJDK21U-jre_aarch64_linux_hotspot_")
grpc_health_probe_map=(["amd64"]="grpc-health-probe-amd64" ["arm64"]="grpc-health-probe-arm64")
nodejs_map=(["amd64"]="${NODEJS_X86_NAME}" ["arm64"]="${NODEJS_ARM_NAME}")

# Cleanup function for error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Rootfs creation failed with exit code $exit_code" >&2
    fi
}
trap cleanup EXIT

# Help function
function show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Create root filesystem for Docker containers with different variants.

VARIANTS:
$(for variant in "${!VARIANTS[@]}"; do
    printf "    %-12s %s\n" "$variant" "${VARIANTS[$variant]}"
done | sort)

OPTIONS:
    --variant NAME      Build specific variant (default: jdk)
    --amd64-only        Build only amd64 architecture
    --arm64-only        Build only arm64 architecture
    --clean             Clean existing rootfs before building
    --image-version     Set the image version
    --sbom-version VER  Set SBOM version (Defaults to 1, but has to be > 0 to publish SBOM to REPO)
    --list-variants     List all available variants
    -h, --help          Show this help message

EXAMPLES:
    ${SCRIPT_NAME}                        # Build jdk variant for both architectures
    ${SCRIPT_NAME} --variant minimal      # Build minimal variant
    ${SCRIPT_NAME} --variant full          # Build fullelopment variant
    ${SCRIPT_NAME} --amd64-only           # Build only amd64
    ${SCRIPT_NAME} --clean --variant base # Clean build of base variant

VARIANT DETAILS:
	certs:	  CA certs only
    minimal:  glibc + busybox (minimal), CA certs, tzdb
    base:     minimal + bash + ncurses + busybox (minimal)
    jdk: base + JDK + tini + tzdb + CA certs
    node:     base + Node.js + tini + tzdb + CA certs
    full:      jdk with complete libraries and busybox

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
        --image-version)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                error "--image-version requires a non-empty value"
                exit 1
            fi
            IMAGE_VERSION="$2"
            shift 2
            ;;
        --sbom-version)
            SBOM_VERSION="$2"
            if [[ ! "$SBOM_VERSION" =~ ^[1-9][0-9]*$ ]]; then
                error "SBOM version must be a positive integer greater than zero"
                exit 1
            fi
            shift 2
            ;;
        --list-variants)
            echo "Available variants:"
            for variant in "${!VARIANTS[@]}"; do
                printf "  %-12s - %s\n" "$variant" "${VARIANTS[$variant]}"
            done | sort
            exit 0
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

# Validate variant
validate_variant() {
    if [[ ! -v "VARIANTS[$VARIANT]" ]]; then
        error "Unknown variant: $VARIANT"
        log "Available variants: ${!VARIANTS[*]}"
        exit 1
    fi
}

# Validate prerequisites
validate_prerequisites() {
    log "Validating prerequisites for variant '${VARIANT}'..."

    local missing_components=()

    # Check glibc (required for all variants)
    if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/glibc_amd64_out" ]]; then
        missing_components+=("glibc (amd64)")
    fi
    if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/glibc_arm64_out" ]]; then
        missing_components+=("glibc (arm64)")
    fi

    # Check busybox (required for all variants)
    if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/busybox_amd64_out" ]]; then
        missing_components+=("busybox (amd64)")
    fi
    if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/busybox_arm64_out" ]]; then
        missing_components+=("busybox (arm64)")
    fi
    if [[ ! -d "${BUILD_DIR}/tzdb_out" ]]; then
        missing_components+=("tzdb")
    fi

    # Check variant-specific components
    if [[ "$VARIANT" != "minimal" ]]; then
        # base, jdk, full need bash and ncurses
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/bash_amd64_out" ]]; then
            missing_components+=("bash (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/bash_arm64_out" ]]; then
            missing_components+=("bash (arm64)")
        fi
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/ncurses_amd64_out" ]]; then
            missing_components+=("ncurses (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/ncurses_arm64_out" ]]; then
            missing_components+=("ncurses (arm64)")
        fi
    fi

    if [[ "$VARIANT" == "jdk" ]] || [[ "$VARIANT" == "full" ]]; then
        # Check JDK
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${jdk_map[amd64]}${OPENJDK_VERSION}.tar.gz" ]]; then
            missing_components+=("JDK (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${jdk_map[arm64]}${OPENJDK_VERSION}.tar.gz" ]]; then
            missing_components+=("JDK (arm64)")
        fi

        # Check tini
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${tini_map[amd64]}" ]]; then
            missing_components+=("tini (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${tini_map[arm64]}" ]]; then
            missing_components+=("tini (arm64)")
        fi
    fi

    if [[ "$VARIANT" == "node" ]]; then
        # Check Node.js
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${nodejs_map[amd64]}" ]]; then
            missing_components+=("Node.js (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${nodejs_map[arm64]}" ]]; then
            missing_components+=("Node.js (arm64)")
        fi

        # Check tini
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${tini_map[amd64]}" ]]; then
            missing_components+=("tini (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${tini_map[arm64]}" ]]; then
            missing_components+=("tini (arm64)")
        fi
    fi

    if [[ "$VARIANT" == "full" ]]; then
        # Check busybox full builds
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/busybox_amd64_full_out" ]]; then
            missing_components+=("busybox-full (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/busybox_arm64_full_out" ]]; then
            missing_components+=("busybox-full (arm64)")
        fi
        # Check grpcurl
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${grpc_health_probe_map[amd64]}" ]]; then
            missing_components+=("grpcurl (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -f "${SOURCE_DIR}/${grpc_health_probe_map[arm64]}" ]]; then
            missing_components+=("grpcurl (arm64)")
        fi
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/libxcrypt_amd64_out" ]]; then
            missing_components+=("libxcrypt (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/libxcrypt_arm64_out" ]]; then
            missing_components+=("libxcrypt (arm64)")
        fi
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/jemalloc_amd64_out" ]]; then
            missing_components+=("jemalloc (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/jemalloc_arm64_out" ]]; then
            missing_components+=("jemalloc (arm64)")
        fi
        # Check screen
        if [[ $BUILD_AMD64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/screen_amd64_out" ]]; then
            missing_components+=("screen (amd64)")
        fi
        if [[ $BUILD_ARM64 -eq 1 ]] && [[ ! -d "${BUILD_DIR}/screen_arm64_out" ]]; then
            missing_components+=("screen (arm64)")
        fi
    fi

    if [[ $BUILD_ARM64 -eq 1 ]] && [[ "${HOST_ARCH}" != "aarch64" ]] && ! command -v qemu-aarch64-static &> /dev/null; then
        missing_components+=("qemu-aarch64-static (for cross-building)")
    fi
    if [[ $BUILD_AMD64 -eq 1 ]] && [[ "${HOST_ARCH}" != "x86_64" ]] && ! command -v qemu-x86_64-static &> /dev/null; then
        missing_components+=("qemu-x86_64-static (for cross-building)")
    fi
    if [[ ( $BUILD_ARM64 -eq 1 && "${HOST_ARCH}" != "aarch64" ) || ( $BUILD_AMD64 -eq 1 && "${HOST_ARCH}" != "x86_64" ) ]] && ! command -v proot &> /dev/null; then
        missing_components+=("proot")
    fi

    if [[ ${#missing_components[@]} -gt 0 ]]; then
        error "Missing required components for variant '${VARIANT}':"
        for component in "${missing_components[@]}"; do
            error "  - $component"
        done
        error ""
        error "Please build missing components first:"
        error "  ./download_all.sh"
        error "  ./build_all.sh"
        exit 1
    fi

    log "Prerequisites validated successfully"
}

# Create base directory structure
create_base_structure() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Creating base directory structure for ${arch}..."

    mkdir -p "${rootfs_dir}"/{etc,var,root,home,tmp}
    chmod 1777 "${rootfs_dir}/tmp"
    mkdir -p "${rootfs_dir}"/usr/{bin,lib,sbin,lib/locale}
    mkdir -p "${rootfs_dir}"/{bin,sbin,lib,lib64}
}
sbom_header() {
    local rootfs_dir="$1"
    local serial_number="$2"

    jq . << EOF  > "${rootfs_dir}/etc/sbom.cdx.json"
{
  "bomFormat": "CycloneDX",
  "\$schema": "https://cyclonedx.org/schema/bom-1.6.schema.json",
  "specVersion": "1.6",
  "serialNumber": "urn:uuid:${serial_number}",
  "version": ${SBOM_VERSION},
  "metadata": {
    "component": {
      "bom-ref": "da-base-images",
      "name": "da-base-images",
      "version": "${VARIANT}",
      "type": "container"
    },
    "tools": {
      "components": [
        {
          "type": "application",
          "name": "da-base-image-generate-cyclonedx",
          "version": "0.0.1",
          "licenses": [
            {
              "license": {
                "id": "GPL-2.0"
              }
            }
          ]
        }
      ]
    }
  },
  "components": []
}
EOF

}

# Install glibc (required for all variants)
install_glibc() {
    local rootfs_dir="$1"
    local arch="$2"
    local use_full="$3" # 0=minimal, 1=full

    jq  --arg version "$GLIBC_VERSION" '.components += [{
        "bom-ref": "glibc",
        "type": "library",
        "name": "glibc",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "LGPL-2.1+"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:gnu:glibc:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/glibc@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

    if [[ $use_full -eq 1 ]]; then
		log "Installing full glibc for ${arch}..."
		# Copy all glibc directories into rootfs
		cp -r "${BUILD_DIR}/glibc_${arch}_out"/* "${rootfs_dir}/"
	else
		# Copy only the necessary parts of glibc to keep the image small
		if [ -d "${BUILD_DIR}/glibc_${arch}_out/lib" ]; then
			cp -r "${BUILD_DIR}/glibc_${arch}_out/lib" "${rootfs_dir}/"
		fi
		if [ -d "${BUILD_DIR}/glibc_${arch}_out/lib64" ]; then
			cp -r "${BUILD_DIR}/glibc_${arch}_out/lib64" "${rootfs_dir}/"
		fi
        # Copy locale binary if available (needed to query locales at runtime)
		if [[ -f "${BUILD_DIR}/glibc_${arch}_out/usr/bin/locale"* ]]; then
			mkdir -p "${rootfs_dir}/usr/bin"
			cp "${BUILD_DIR}/glibc_${arch}_out/usr/bin/locale"* "${rootfs_dir}/usr/bin/"
        fi
		if [ -d "${BUILD_DIR}/glibc_${arch}_out/usr" ]; then
			cp -r "${BUILD_DIR}/glibc_${arch}_out/usr" "${rootfs_dir}/"
		fi
		if [ -f "${BUILD_DIR}/glibc_${arch}_out/sbin/ldconfig" ]; then
			cp "${BUILD_DIR}/glibc_${arch}_out/sbin/ldconfig" "${rootfs_dir}/sbin/"
		fi
	fi

	# setup ldconfig
    mkdir -p "${rootfs_dir}/etc/ld.so.conf.d/"

	#create libc.conf to include /usr/lib and /usr/lib64
	cat <<EOF > "${rootfs_dir}/etc/ld.so.conf.d/libc.conf"
/usr/lib
/usr/lib64
EOF

}

# Install busybox (required for all variants, minimal or full version)
install_busybox() {
    local rootfs_dir="$1"
    local arch="$2"
    local use_full="$3"  # 0=minimal, 1=full

    if [[ $use_full -eq 1 ]]; then
        log "Installing busybox (full/full) for ${arch}..."
        cp -r "${BUILD_DIR}/busybox_${arch}_full_out/"* "${rootfs_dir}/"
    else
        log "Installing busybox (minimal) for ${arch}..."
        cp -r "${BUILD_DIR}/busybox_${arch}_out/"* "${rootfs_dir}/"
    fi

    jq --arg version "$BUSYBOX_VERSION" '.components += [{
        "bom-ref": "busybox",
        "type": "library",
        "name": "busybox",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "GPL-2.0+"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:busybox:busybox:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/busybox@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

}

# Install bash (base, jdk, full variants)
install_bash() {
    local rootfs_dir="$1"
    local arch="$2"
	local use_full="$3" # 0=minimal, 1=full

    if [[ $use_full -eq 1 ]]; then
		log "Installing all of bash for ${arch}..."
		cp -rf "${BUILD_DIR}/bash_${arch}_out/"* "${rootfs_dir}/"
		pushd "${rootfs_dir}/bin/" > /dev/null
		ln -sf ../bin/bash sh
		popd > /dev/null
	else
		log "Installing bash for ${arch}..."
		cp "${BUILD_DIR}/bash_${arch}_out/bin/bash" "${rootfs_dir}/bin/"
		pushd "${rootfs_dir}/bin/" > /dev/null
		ln -sf ../bin/bash sh
		popd > /dev/null
	fi

    jq --arg version "$BASH_VERSION" '.components += [{
        "bom-ref": "bash",
        "type": "library",
        "name": "bash",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "GPL-3.0+"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:gnu:bash:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/bash@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

}

# Install ncurses (base, jdk, full variants)
install_ncurses() {
    local rootfs_dir="$1"
    local arch="$2"
	local use_full="$3" # 0=minimal, 1=full

    jq --arg version "$NCURSES_VERSION" '.components += [{
        "bom-ref": "ncurses",
        "type": "library",
        "name": "ncurses",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "MIT"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:gnu:ncurses:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/ncurses@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

    if [[ $use_full -eq 1 ]]; then
		log "Installing all of ncurses for ${arch}..."
		# Coping all ncurses will overwrite busybox files, so use -n to avoid overwriting
		cp -r --update=none "${BUILD_DIR}/ncurses_${arch}_out/"* "${rootfs_dir}/"
	else
		log "Installing ncurses for ${arch}..."
		cp -r "${BUILD_DIR}/ncurses_${arch}_out/usr/lib/"* "${rootfs_dir}/usr/lib/"
		cp -r "${BUILD_DIR}/ncurses_${arch}_out/usr/bin/tput" "${rootfs_dir}/usr/bin/"
		mkdir -p "${rootfs_dir}/usr/share/terminfo"
		cp -r "${BUILD_DIR}/ncurses_${arch}_out/usr/share/terminfo/"* "${rootfs_dir}/usr/share/terminfo/"
	fi
}

# Install libxcrypt (full variants)
install_libxcrypt() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Installing libxcrypt for ${arch}..."
    cp -r "${BUILD_DIR}/libxcrypt_${arch}_out/"* "${rootfs_dir}/"

    jq --arg version "$LIBXCRYPT_VERSION" '.components += [{
        "bom-ref": "libxcrypt",
        "type": "library",
        "name": "libxcrypt",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "LGPL-2.1-or-later"
            }
        }
        ],
        "purl": ("pkg:generic/libxcrypt@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

}

# Install screen (full variants)
install_screen() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Installing screen for ${arch}..."
    cp -r "${BUILD_DIR}/screen_${arch}_out/"* "${rootfs_dir}/"

    jq --arg version "$SCREEN_VERSION" '.components += [{
        "bom-ref": "screen",
        "type": "library",
        "name": "screen",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "GPL-3.0-or-later"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:screen:screen:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/screen@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

}

# Install jemalloc (full variants)
install_jemalloc() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Installing jemalloc for ${arch}..."
    cp -r "${BUILD_DIR}/jemalloc_${arch}_out/"* "${rootfs_dir}/"

    jq --arg version "$JEMALLOC_VERSION" '.components += [{
        "bom-ref": "jemalloc",
        "type": "library",
        "name": "jemalloc",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "BSD-2-Clause"
            }
        }
        ],
        "purl": ("pkg:generic/jemalloc@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

}

# Install GCC (node variant)
install_libstdc++() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Installing libstdc++ for ${arch}..."
    cp -r "${BUILD_DIR}/gcc_${arch}_out/"* "${rootfs_dir}/"

    jq --arg version "$GCC_VERSION" '.components += [{
        "bom-ref": "gcc",
        "type": "library",
        "name": "gcc",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "GPL-3.0-or-later"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:gnu:gcc:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/gcc@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

}

# Install JDK (jdk, full variants)
install_jdk() {
    local rootfs_dir="$1"
    local arch="$2"

    jq --arg version "$OPENJDK_VERSION" '.components += [{
        "bom-ref": "temurin-jdk",
        "type": "library",
        "name": "temurin-jdk",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "GPL-2.0-with-classpath-exception"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:eclipse:temurin:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/temurin@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

    log "Installing JDK for ${arch}..."
    mkdir -p "${rootfs_dir}/usr/java/"
    tar --strip-components=1 -xzf "${SOURCE_DIR}/${jdk_map[$arch]}${OPENJDK_VERSION}.tar.gz" \
        -C "${rootfs_dir}/usr/java/"
}

# Install Node.js (node variant)
install_node() {
    local rootfs_dir="$1"
    local arch="$2"

    jq --arg version "$NODEJS_VERSION" '.components += [{
        "bom-ref": "nodejs",
        "type": "library",
        "name": "nodejs",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "MIT"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:nodejs:node.js:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/nodejs@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

    log "Installing Node.js for ${arch}..."
    mkdir -p "${rootfs_dir}/usr/"
    tar --strip-components=1 -xJf "${SOURCE_DIR}/${nodejs_map[$arch]}" \
        -C "${rootfs_dir}/usr"
}

# Install tini (jdk, full variants)
install_tini() {
    local rootfs_dir="$1"
    local arch="$2"

    jq --arg version "$TINI_VERSION" '.components += [{
        "bom-ref": "tini",
        "type": "library",
        "name": "tini",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "MIT"
            }
        }
        ],
        "cpe": ("cpe:2.3:a:tini_project:tini:" + $version + ":-:*:*:*:*:*:*"),
        "purl": ("pkg:generic/tini@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

    log "Installing tini for ${arch}..."
    cp "${SOURCE_DIR}/${tini_map[$arch]}" "${rootfs_dir}/usr/bin/tini"
    chmod +x "${rootfs_dir}/usr/bin/tini"
}

# Install grpc-health-probe (full variant)
install_grpc_health_probe() {
    local rootfs_dir="$1"
    local arch="$2"

    jq --arg version "$GRPC_HEALTH_PROBE_VERSION" '.components += [{
        "bom-ref": "grpc-health-probe",
        "type": "library",
        "name": "grpc-health-probe",
        "version": $version,
        "licenses": [
        {
            "license": {
            "id": "Apache-2.0"
            }
        }
        ],
        "purl": ("pkg:golang/github.com/grpc-ecosystem/grpc-health-probe@" + $version)
    }
    ]' "${rootfs_dir}/etc/sbom.cdx.json" > "${rootfs_dir}/etc/sbom_tmp.json" && mv "${rootfs_dir}/etc/sbom_tmp.json" "${rootfs_dir}/etc/sbom.cdx.json"

    log "Installing grpc-health-probe for ${arch}..."
    cp "${SOURCE_DIR}/${grpc_health_probe_map[$arch]}" "${rootfs_dir}/usr/bin/grpc-health-probe"
    chmod +x "${rootfs_dir}/usr/bin/grpc-health-probe"
}

# Install timezone database (jdk, full variants)
install_tzdb() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Installing timezone database for ${arch}..."
    mkdir -p "${rootfs_dir}/usr/share/zoneinfo/"
    cp -r "${BUILD_DIR}/tzdb_out/usr/share/zoneinfo/"* "${rootfs_dir}/usr/share/zoneinfo/"
}

# Install CA certificates (jdk, full variants)
install_ca_certs() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Installing CA certificates for ${arch}..."

    local cacert_pem="${SOURCE_DIR}/cacert.pem"
    if [[ ! -f "${cacert_pem}" ]]; then
        err "CA certificate bundle not found: ${cacert_pem}"
        err "Run scripts/download_cacerts.sh first"
        return 1
    fi

    mkdir -p "${rootfs_dir}/etc/ssl/certs/"

    # Clean existing certs
    rm -rf "${rootfs_dir}/etc/ssl/certs/"*

    # Install the main bundle
    cp "${cacert_pem}" "${rootfs_dir}/etc/ssl/certs/ca-certificates.crt"

    # Also create the ca-bundle.crt symlink (used by some applications)
    ln -sf ca-certificates.crt "${rootfs_dir}/etc/ssl/certs/ca-bundle.crt"

    # Create the hash-based symlinks that OpenSSL expects
    # We'll use the busybox in the rootfs to do this if available, or split manually
    log "Creating certificate hash symlinks..."

    # Split the bundle into individual certificates
    local cert_dir="${rootfs_dir}/etc/ssl/certs"
    local temp_split="${cert_dir}/.temp_certs"
    mkdir -p "${temp_split}"

    # Split cacert.pem into individual certificate files
    awk -v dir="${temp_split}" '
        /BEGIN CERTIFICATE/ { cert_count++; filename = dir "/cert-" cert_count ".pem" }
        { if (filename) print > filename }
        /END CERTIFICATE/ { close(filename); filename = "" }
    ' "${cacert_pem}"

    # Create hash symlinks for each certificate
    # Use openssl from host if available, otherwise just copy the bundle
    if command -v openssl >/dev/null 2>&1; then
        for cert_file in "${temp_split}"/cert-*.pem; do
            [[ -f "${cert_file}" ]] || continue
            local cert_hash
            cert_hash=$(openssl x509 -hash -noout -in "${cert_file}" 2>/dev/null || true)
            local cert_common_name
            cert_common_name=$(openssl x509 -noout -subject -in "${cert_file}" 2>/dev/null | sed -n 's/.*CN=\([^,/]*\).*/\1/p' | sed "s/ /_/g" || true)
            cp "${cert_file}" "${cert_dir}/${cert_common_name}.pem"
            if [[ -n "${cert_hash}" ]]; then
                local hash_file="${cert_dir}/${cert_hash}.0"
                local counter=0
                # Handle hash collisions
                while [[ -e "${hash_file}" ]]; do
                    counter=$((counter + 1))
                    hash_file="${cert_dir}/${cert_hash}.${counter}"
                done
                ln -sf "${cert_common_name}.pem" "${hash_file}"
            fi
        done
        log "Created OpenSSL hash symlinks"
    else
        log "WARNING: openssl not found on host, skipping hash symlink creation"
        log "Applications may need to use /etc/ssl/certs/ca-certificates.crt directly"
    fi

    # Clean up temporary files
    # rm -rf "${temp_split}"

    local cert_count
    cert_count=$(grep -c 'BEGIN CERTIFICATE' "${cacert_pem}" || echo "0")
    log "Installed ${cert_count} CA certificates"
}

# Setup system configuration (all variants)
setup_system_config_files() {
    local rootfs_dir="$1"
    local arch="$2"

    log "Setting up system configuration for ${arch}..."

    # Setup base accounts
    cat <<EOF > "${rootfs_dir}/etc/group"
root:x:0:
nonroot:x:1001:
EOF

    cat <<EOF > "${rootfs_dir}/etc/passwd"
root:x:0:0:root:/root:/sbin/nologin
nonroot:x:1001:1001::/home/nonroot:/usr/bin/bash
EOF

    # Setup nsswitch
    cat <<EOF > "${rootfs_dir}/etc/nsswitch.conf"
# Begin /etc/nsswitch.conf

passwd: files
group: files
shadow: files

hosts: files dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
EOF

    # Create os-release file for OS identification
    # Default IMAGE_VERSION from VERSION file when available, with a date fallback
    local version_date version_file_value
    version_date=$(date +%Y.%m)
    if [[ -z "${IMAGE_VERSION}" ]]; then
        version_file_value=""
        if [[ -f VERSION ]]; then
            version_file_value=$(head -n 1 VERSION)
        fi

        if [[ -n "${version_file_value}" ]]; then
            IMAGE_VERSION=${version_file_value}
        else
            IMAGE_VERSION=${version_date}
        fi
    fi

    cat <<EOF > "${rootfs_dir}/etc/os-release"
NAME="DA Base Image"
VERSION="${IMAGE_VERSION}"
ID=da-base
ID_LIKE=linux
VERSION_ID="${IMAGE_VERSION}"
PRETTY_NAME="DA Base Image ${IMAGE_VERSION} (glibc ${GLIBC_VERSION})"
HOME_URL="https://github.com/${GITHUB_REPO:-DACH-NY/da-base-images}"
SUPPORT_URL="https://github.com/${GITHUB_REPO:-DACH-NY/da-base-images}/issues"
BUG_REPORT_URL="https://github.com/${GITHUB_REPO:-DACH-NY/da-base-images}/issues"
VARIANT="${VARIANT}"
VARIANT_ID="${VARIANT}"
BUILD_ID="${GIT_SHA:-unknown}"
EOF

    # Also create lsb-release for compatibility with older tools
    cat <<EOF > "${rootfs_dir}/etc/lsb-release"
DISTRIB_ID=DA-Base
DISTRIB_RELEASE=${IMAGE_VERSION}
DISTRIB_DESCRIPTION="DA Base Image ${IMAGE_VERSION}"
EOF

    log "Created /etc/os-release with version ${IMAGE_VERSION}"

}

configure_system() {
    local rootfs_dir="$1"
    local arch="$2"
    local ld_cache_skip="$3" # 1=skip, 0=run

    # Generate locale data
    log "Generating locale data for ${arch}..."

    # Determine if we are cross-compiling
    local target_arch_native=""
    local qemu_bin=""
    if [[ "${arch}" == "amd64" ]]; then
        target_arch_native="x86_64"
        qemu_bin="qemu-x86_64-static"
    elif [[ "${arch}" == "arm64" ]]; then
        target_arch_native="aarch64"
        qemu_bin="qemu-aarch64-static"
    fi
    
    # Check if localedef exists in the rootfs
    if [[ ! -f "${rootfs_dir}/usr/bin/localedef" ]]; then
        log "WARNING: localedef not found in rootfs at /usr/bin/localedef, skipping locale generation."
    elif [[ -d "${rootfs_dir}/usr/share/i18n" ]]; then
        
        local localedef_cmd="/usr/bin/localedef -i en_US -f UTF-8 en_US.UTF-8"
        if [[ "${HOST_ARCH}" != "${target_arch_native}" ]]; then
            localedef_cmd="proot -w /root/ -q \"${qemu_bin}\" -r \"${rootfs_dir}\" ${localedef_cmd}"
        else
            localedef_cmd="proot -w /root/ -r \"${rootfs_dir}\" ${localedef_cmd}"
        fi

        if eval "${localedef_cmd}"; then
            log "Successfully generated en_US.UTF-8 locale."
        else
            log "ERROR: Failed to generate en_US.UTF-8 locale."
            exit 1
        fi

        if [[ -f "${rootfs_dir}/usr/share/i18n/locales/C" ]]; then
            local c_localedef_cmd="/usr/bin/localedef -i C -f UTF-8 C.UTF-8"
            if [[ "${HOST_ARCH}" != "${target_arch_native}" ]]; then
                c_localedef_cmd="proot -w /root/ -q \"${qemu_bin}\" -r \"${rootfs_dir}\" ${c_localedef_cmd}"
            else
                c_localedef_cmd="proot -w /root/ -r \"${rootfs_dir}\" ${c_localedef_cmd}"
            fi

            if eval "${c_localedef_cmd}"; then
                log "Successfully generated C.UTF-8 locale."
            else
                log "ERROR: Failed to generate C.UTF-8 locale."
                exit 1
            fi
        fi
    else
        log "WARNING: No i18n data found in rootfs, skipping locale generation."
    fi

    # Clean up localedef binary
    if [[ -f "${rootfs_dir}/usr/bin/localedef" ]]; then
        log "Removing localedef binary."
        rm "${rootfs_dir}/usr/bin/localedef"
    fi

    # Set default timezone to UTC
    ln -sfv /usr/share/zoneinfo/UTC "${rootfs_dir}/etc/localtime"

    if [[ "${ld_cache_skip:-0}" -eq 1 ]]; then
        log "Skipping ldconfig for ${arch} as requested"
        return
    fi

    log "Running ldconfig for ${arch}..."

    if [[ "${HOST_ARCH}" == "${target_arch_native}" ]]; then
        # Native build, run ldconfig directly
        log "Running native ldconfig for ${arch}"
        ldconfig -r "${rootfs_dir}"
    else
        # Cross-build, use proot and QEMU
        log "Using proot and ${qemu_bin} for ${arch} ldconfig"
        proot -w /root/ -q "${qemu_bin}" -r "${rootfs_dir}" /sbin/ldconfig
        log "proot ldconfig complete for ${arch}"
    fi
}

# Build rootfs for specific architecture and variant
build_rootfs_arch() {
    local arch="$1"
    local rootfs_dir="${WORK_DIR}/rootfs_${VARIANT}_${arch}"

    log "Building ${VARIANT} rootfs for ${arch}..."

    # Clean if requested
    if [[ $CLEAN_BUILD -eq 1 ]]; then
        log "Cleaning existing rootfs: ${rootfs_dir}"
        rm -rf "${rootfs_dir}"
    fi

    # Create base structure
    create_base_structure "${rootfs_dir}" "${arch}"

    local sbom_serial_number=$(jq -r ".variants[\"${VARIANT}\"].sbom.serial_number" "${VARIANTS_CONFIG_FILE}")
    sbom_header "${rootfs_dir}" "${sbom_serial_number}"

    # Get variant configuration from JSON
    local use_full
    use_full=$(jq -r ".variants[\"${VARIANT}\"].use_full // false" "${VARIANTS_CONFIG_FILE}")
    local use_full_flag
    if [[ "${use_full}" == "true" ]]; then
        use_full_flag=1
    else
        use_full_flag=0
    fi

    local ld_cache_skip_flag
    ld_cache_skip_flag=$(jq -r ".variants[\"${VARIANT}\"].configure_system_skip_ldconfig // false" "${VARIANTS_CONFIG_FILE}")
    if [[ "${ld_cache_skip_flag}" == "true" ]]; then
        ld_cache_skip_flag=1
    else
        ld_cache_skip_flag=0
    fi

    # Install components based on variant config
    local components
    mapfile -t components < <(jq -r ".variants[\"${VARIANT}\"].components[]" "${VARIANTS_CONFIG_FILE}")

    for component in "${components[@]}"; do
        case "$component" in
            "setup_system_config_files")
                setup_system_config_files "${rootfs_dir}" "${arch}"
                ;;
            "install_glibc")
                install_glibc "${rootfs_dir}" "${arch}" "${use_full_flag}"
                ;;
            "install_busybox")
                install_busybox "${rootfs_dir}" "${arch}" "${use_full_flag}"
                ;;
            "install_bash")
                install_bash "${rootfs_dir}" "${arch}" "${use_full_flag}"
                ;;
            "install_ncurses")
                install_ncurses "${rootfs_dir}" "${arch}" "${use_full_flag}"
                ;;
            "install_jdk")
                install_jdk "${rootfs_dir}" "${arch}"
                ;;
            "install_node")
                install_node "${rootfs_dir}" "${arch}"
                ;;
            "install_libstdc++")
                install_libstdc++ "${rootfs_dir}" "${arch}"
                ;;
            "install_tini")
                install_tini "${rootfs_dir}" "${arch}"
                ;;
            "install_grpc_health_probe")
                install_grpc_health_probe "${rootfs_dir}" "${arch}"
                ;;
            "install_libxcrypt")
                install_libxcrypt "${rootfs_dir}" "${arch}"
                ;;
            "install_screen")
                install_screen "${rootfs_dir}" "${arch}"
                ;;
            "install_jemalloc")
                install_jemalloc "${rootfs_dir}" "${arch}"
                ;;
            "install_tzdb")
                install_tzdb "${rootfs_dir}" "${arch}"
                ;;
            "install_ca_certs")
                install_ca_certs "${rootfs_dir}" "${arch}"
                ;;
            "configure_system")
                configure_system "${rootfs_dir}" "${arch}" "${ld_cache_skip_flag}"
                ;;
            *)
                error "Unknown component in variants.json: $component"
                exit 1
                ;;
        esac
    done

    log "Successfully built ${VARIANT} rootfs for ${arch}"
    log "Location: ${rootfs_dir}"
}

# Main function
main() {
    log "Starting rootfs creation process"
    log "Variant: ${VARIANT}"
    log "Architectures: AMD64=${BUILD_AMD64}, ARM64=${BUILD_ARM64}"

    validate_variant
    validate_prerequisites

    # Build for each architecture
    if [[ $BUILD_AMD64 -eq 1 ]]; then
        build_rootfs_arch "amd64"
    fi

    if [[ $BUILD_ARM64 -eq 1 ]]; then
        build_rootfs_arch "arm64"
    fi

    log "Rootfs creation complete!"
    log ""
    log "Created rootfs directories:"
    [[ $BUILD_AMD64 -eq 1 ]] && log "  - ${WORK_DIR}/rootfs_${VARIANT}_amd64"
    [[ $BUILD_ARM64 -eq 1 ]] && log "  - ${WORK_DIR}/rootfs_${VARIANT}_arm64"
    log ""
    log "To use with Docker, update your Dockerfile to reference:"
    log "  COPY --chown=root:root rootfs_${VARIANT}_\$TARGETARCH /"
}

# Run main function
main

