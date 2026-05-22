# Quick Reference: Container Variants

## Quick Start

### 1. List Available Variants
```bash
./scripts/create_rootfs.sh --list-variants
```

### 2. Create Rootfs for a Variant
```bash
# Standard variant (default - includes JDK)
./scripts/create_rootfs.sh

# Minimal variant (smallest size)
./scripts/create_rootfs.sh --variant minimal

# Base variant (with bash)
./scripts/create_rootfs.sh --variant base

# Dev variant (full tooling)
./scripts/create_rootfs.sh --variant full
```

### 3. Build Docker Image
```bash
# Using helper script
./create_image_variant.sh --variant standard --tag myapp:standard

# Or manually update config/Dockerfile and use:
./create_image.sh
```

## Common Commands

### Build All Variants
```bash
# Create rootfs for all variants
for variant in minimal base standard full; do
    ./scripts/create_rootfs.sh --variant $variant
done
```

### Build Specific Architecture
```bash
# AMD64 only
./scripts/create_rootfs.sh --variant base --amd64-only

# ARM64 only
./scripts/create_rootfs.sh --variant standard --arm64-only
```

### Clean and Rebuild
```bash
./scripts/create_rootfs.sh --variant full --clean
```

## Variant Comparison

| Variant  | Size    | Components | Use Case |
|----------|---------|------------|----------|
| minimal  | ~20 MB  | glibc + busybox | Smallest possible |
| base     | ~30 MB  | + bash + ncurses | Shell scripting |
| standard | ~250 MB | + JDK + tini + certs | Java apps (recommended) |
| full     | ~300 MB | + full busybox | Development/debugging |

## Directory Structure

After running `create_rootfs.sh`, you'll have:
```
rootfs_<variant>_<arch>/
├── bin/           # Basic binaries (busybox symlinks)
├── etc/           # Configuration files
├── lib/           # Core libraries (glibc)
├── lib64/         # 64-bit libraries
├── usr/
│   ├── bin/       # User binaries (bash, java, etc.)
│   ├── java/      # JDK installation (standard/full only)
│   ├── lib/       # Additional libraries
│   ├── share/     # Shared data (terminfo, zoneinfo)
│   └── sbin/      # System binaries
├── var/           # Variable data
└── root/          # Root home directory
```

## Troubleshooting

### Missing Components Error
```
Error: Missing required components for variant 'standard':
  - JDK (amd64)
```

**Solution:** Build missing components first:
```bash
./download_all.sh
./build_all.sh
```

### Wrong Variant in Docker Image
**Solution:** Either:
1. Use the helper script:
   ```bash
   ./create_image_variant.sh --variant minimal --tag myapp:minimal
   ```

2. Or manually edit `config/Dockerfile` line 15:
   ```dockerfile
   COPY --chown=root:root rootfs_minimal_$TARGETARCH /
   ```

### Check Variant Contents
```bash
# List files in rootfs
ls -lah rootfs_standard_amd64/

# Check installed binaries
ls -lah rootfs_standard_amd64/usr/bin/

# Verify JDK installation
ls -lah rootfs_standard_amd64/usr/java/
```

## Environment Variables

Key variables from `.envrc`:
- `WORK_DIR`: Where rootfs directories are created
- `BUILD_DIR`: Where built components are located
- `SOURCE_DIR`: Where downloaded sources are located

## Migration Guide

### From Old create_rootfs.sh

**Old:**
```bash
./scripts/create_rootfs.sh
# Created: rootfs_amd64, rootfs_arm64
```

**New:**
```bash
./scripts/create_rootfs.sh --variant standard
# Creates: rootfs_standard_amd64, rootfs_standard_arm64
```

Update your Dockerfile accordingly.

## Best Practices

1. **Use standard variant by default** - It's the recommended base for most applications
2. **Use minimal for static binaries** - When you don't need any additional tools
3. **Use full for Initial Depolyment** - Full busybox makes initial deployments easier
4. **Build for specific arch during development** - Use `--amd64-only` to speed up iteration
5. **Clean build after component updates** - Use `--clean` when you rebuild components

## Examples

### Java Microservice
```bash
./scripts/create_rootfs.sh --variant standard
./create_image_variant.sh --variant standard --tag myservice:1.0
```

### Minimal Alpine Alternative
```bash
./scripts/create_rootfs.sh --variant minimal
./create_image_variant.sh --variant minimal --tag minimal:latest
```

### Development Container
```bash
./scripts/create_rootfs.sh --variant full
./create_image_variant.sh --variant full --tag full:latest
```

Includes grpc-health-probe for gRPC health checking:
```bash
docker run --rm full:latest grpc-health-probe --help
```

### Multi-arch Production Build
```bash
# Create rootfs
./scripts/create_rootfs.sh --variant standard

# Build and push
./create_image_variant.sh \
    --variant standard \
    --tag registry.example.com/myapp:v1.0 \
    --push
```
