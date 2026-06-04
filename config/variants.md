# Container Variants

This document describes the different container variants available in this project.

## Available Variants

### certs
**Description:** Root Certificates, timezone, and locale data only.  Intended to be the base for applications that are statically linked and do not need external dependencies.

### minimal
**Description:** Minimal rootfs with glibc and busybox only

**Components:**
- All components from `certs`
- glibc 2.42
- busybox 1.37.0 (minimal configuration)
- Basic system configuration (/etc/passwd, /etc/group, /etc/nsswitch.conf)

**Use Cases:**
- Ultra-lightweight container base
- Static binaries that don't need additional tools
- Minimal attack surface for security-critical applications

---

### base
**Description:** Base rootfs with bash, ncurses, and minimal busybox

**Components:**
- All components from `minimal`
- bash 5.2 shell
- ncurses 6.5 libraries
- tput terminal utility

**Use Cases:**
- Shell scripting applications
- Interactive containers requiring bash
- Applications needing terminal capabilities
- General-purpose base image for custom builds

---

### jdk
**Description:** jdk rootfs with JDK, tini, and all base components

**Components:**
- All components from `base`
- OpenJDK 21 (Temurin)
- tini init system
- Timezone database (2025b)
- CA certificates

**Use Cases:**
- Java applications
- Microservices and web services
- Production applications requiring JVM
- Applications needing timezone and SSL support
- Default recommended variant

**Size:** ~200-250 MB

---

### full
**Description:** Complete rootfs with full busybox tools and all components

**Components:**
- All components from `jdk`
- busybox 1.37.0 (full configuration)
- Additional debugging and development tools
    - grpc-health-probe CLI (for testing gRPC health checks)

**Use Cases:**
- Development and debugging containers
- Interactive troubleshooting
- Testing and experimentation
- Building and compiling within containers

**Size:** ~250-300 MB

---

## Building Variants

### Build jdk Variant (Default)
```bash
./scripts/create_rootfs.sh
```

### Build Specific Variant
```bash
./scripts/create_rootfs.sh --variant minimal
./scripts/create_rootfs.sh --variant base
./scripts/create_rootfs.sh --variant jdk
./scripts/create_rootfs.sh --variant full
```

### Build for Specific Architecture
```bash
./scripts/create_rootfs.sh --variant base --amd64-only
./scripts/create_rootfs.sh --variant jdk --arm64-only
```

### Clean Build
```bash
./scripts/create_rootfs.sh --variant full --clean
```

---

## Using Variants in Docker

### Update Dockerfile
To use a specific variant, update your Dockerfile's COPY command:

```dockerfile
# For jdk variant (default)
COPY --chown=root:root rootfs_jdk_$TARGETARCH /

# For minimal variant
COPY --chown=root:root rootfs_minimal_$TARGETARCH /

# For base variant
COPY --chown=root:root rootfs_base_$TARGETARCH /

# For full variant
COPY --chown=root:root rootfs_full_$TARGETARCH /
```

### Build Docker Image
```bash
# jdk variant
docker buildx build --platform linux/amd64,linux/arm64 \
    -t myimage:jdk .

# Minimal variant (requires Dockerfile update)
docker buildx build --platform linux/amd64,linux/arm64 \
    -t myimage:minimal .
```

---

## Variant Selection Guide

| Requirement | Recommended Variant |
|-------------|---------------------|
| Smallest possible image | minimal |
| Need shell scripting | base |
| Java application | jdk |
| Production microservice | jdk |
| Initial Release | full |
| Custom build from scratch | minimal or base |

---

## Component Matrix

| Component | minimal | base | jdk | full |
|-----------|---------|------|----------|-----|
| glibc | ✓ | ✓ | ✓ | ✓ |
| busybox (minimal) | ✓ | ✓ | ✓ | - |
| busybox (full) | - | - | - | ✓ |
| bash | - | ✓ | ✓ | ✓ |
| ncurses | - | ✓ | ✓ | ✓ |
| CA certificates | - | - | ✓ | ✓ |
| Timezone DB | - | - | ✓ | ✓ |
| tini | - | - | ✓ | ✓ |
| OpenJDK 21 | - | - | ✓ | ✓ |

---

## Prerequisites

All variants require building their respective components first:

```bash
# Download all sources
./download_all.sh

# Build all components
./build_all.sh

# Or build specific components
./scripts/build_glibc.sh
./scripts/build_busybox.sh
./scripts/build_bash.sh
./scripts/build_ncurses.sh

# For full variant, also build busybox-full
./scripts/build_busybox.sh --full
```

---

## Migration from Old create_rootfs.sh

The old script created a single rootfs type equivalent to the new `jdk` variant.

**Old command:**
```bash
./scripts/create_rootfs.sh
```

**New equivalent:**
```bash
./scripts/create_rootfs.sh --variant jdk
```

The output directory naming has changed:
- Old: `rootfs_amd64`, `rootfs_arm64`
- New: `rootfs_jdk_amd64`, `rootfs_jdk_arm64`

Update your Dockerfile accordingly.
