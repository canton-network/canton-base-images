# Testing Container Images

This document describes the functional test framework for validating the container image variants.

## Test Script: `scripts/test_image.sh`

This script runs a series of functional tests against a specified container image to verify that all components are installed and working correctly.

### Usage

```bash
./scripts/test_image.sh --variant <variant_name> --tag <image_tag> [OPTIONS]
```

**Options:**

*   `--variant NAME`: The name of the variant to test (e.g., `minimal`, `base`, `jdk`, `full`).
*   `--tag IMAGE_TAG`: The full Docker image tag to test (e.g., `myapp:jdk`).
*   `--platform PLATFORM`: The platform to test (e.g., `linux/amd64`, `linux/arm64`).
*   `--no-fail-fast`: Continue running tests even after a failure.
*   `--verbose` or `-v`: Enable verbose output for debugging.
*   `-h` or `--help`: Display the help message.

### Examples

```bash
# Test the jdk variant with a specific tag
./scripts/test_image.sh --variant jdk --tag myapp:jdk

# Test the minimal variant for the amd64 platform
./scripts/test_image.sh --variant minimal --tag myapp:minimal --platform linux/amd64

# Test the full variant with verbose output
./scripts/test_image.sh --variant full --tag myapp:full --verbose
```

## Test Coverage

The test script covers the following checks for each variant:

### All Variants (Core Tests)
- ✓ `glibc` installation and dynamic linker.
- ✓ `busybox` installation and basic commands (`ls`, `cat`, `grep`).
- ✓ Basic filesystem structure (`/etc/passwd`, `/etc/group`).
- ✓ User accounts (`root`, `nonroot`).

### `minimal`
- ✓ CA certificates are present.
- ✓ Timezone database is present.
- ✗ `bash` is **not** present.

### `base`
- ✓ `bash` shell and `sh` symlink.
- ✓ `ncurses` library and `tput` utility.
- ✓ `terminfo` database.
- ✓ CA certificates and timezone data.
- ✗ `jdk` is **not** present.

### `jdk`
- ✓ All `base` components.
- ✓ OpenJDK installation and `JAVA_HOME`.
- ✓ `java` and `javac` runtimes.
- ✓ `tini` init system.

### `full`
- ✓ All `jdk` components.
- ✓ Full `busybox` with extended tools (`vi`, `wget`, `find`).
- ✓ `grpcurl` for gRPC testing.
- ✓ `ldconfig` for library management.

## GitHub Actions Integration

### Workflow: `.github/workflows/test-images.yml`

The testing process is integrated into the CI/CD pipeline using a reusable workflow that runs a matrix of tests across different variants and platforms.

**Trigger:**

This workflow is triggered by the main `build-images.yml` workflow after the images have been successfully built.

**Inputs:**

*   `variants`: A comma-separated list of variants to test (default: `minimal,base,jdk,full`).
*   `image_tag_suffix`: An optional tag suffix to append to the image name (e.g., a date string).
*   `platforms`: A comma-separated list of platforms to test (default: `linux/amd64,linux/arm64`).

This setup ensures that every build is automatically tested across all supported configurations, maintaining a high level of quality and reliability.

#   platforms: linux/amd64,linux/arm64
```

### Integrated Testing

The build workflow automatically calls the test workflow after successful builds:

1. Build images → Push to registry
2. Test workflow pulls images
3. Run functional tests for each variant × platform
4. Report results in job summary

## Local Testing Workflow

### Quick Test (After Building Locally)

```bash
# 1. Create rootfs
./scripts/create_rootfs.sh --variant standard

# 2. Build image
./create_image_variant.sh --variant standard --tag test:standard --load

# 3. Run tests
./scripts/test_image.sh --variant standard --tag test:standard
```

### Test All Variants

```bash
#!/bin/bash
for variant in minimal base standard full; do
    echo "Testing $variant..."
    ./scripts/create_rootfs.sh --variant "$variant"
    ./create_image_variant.sh --variant "$variant" --tag "test:$variant" --load
    ./scripts/test_image.sh --variant "$variant" --tag "test:$variant" --verbose
done
```

### Test Specific Platform

```bash
# Build for amd64 only
./scripts/create_rootfs.sh --variant base --amd64-only
./create_image_variant.sh --variant base --tag test:base --platform linux/amd64 --load

# Test amd64
./scripts/test_image.sh --variant base --tag test:base --platform linux/amd64
```

## Adding New Tests

Edit `scripts/test_image.sh` and add tests to the appropriate function:

```bash
# For all variants
test_core() {
  # Add core tests here
  run_test "new-core-test" /bin/sh -c "command -v sometool"
}

# For specific variant
test_full() {
  # Add full-specific tests
  run_test_with_output "tool-version" "expected text" /usr/bin/tool --version
}
```

Test helper functions:
- `run_test "name" command...` - Test command succeeds
- `run_test_with_output "name" "expected" command...` - Test output contains expected text

## Troubleshooting

### Test Fails Locally

```bash
# Run with verbose output
./scripts/test_image.sh --variant standard --tag myapp:standard --verbose

# Continue past first failure to see all issues
./scripts/test_image.sh --variant full --tag myapp:full --no-fail-fast
```

### Test Specific Component Manually

```bash
# Test bash directly
docker run --rm myapp:base /usr/bin/bash --version

# Test grpcurl
docker run --rm myapp:full /usr/bin/grpcurl --help

# Test java
docker run --rm myapp:standard /usr/java/bin/java -version
```

### CI Tests Fail

1. Check the "Test summary" section in the failed job
2. Look at the test output for specific failed assertions
3. Pull the image locally and run tests:
   ```bash
   docker pull ghcr.io/owner/repo:variant-date
   ./scripts/test_image.sh --variant variant --tag ghcr.io/owner/repo:variant-date
   ```

## Test Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed
- Other - Script error (missing variant, image not found, etc.)

## Best Practices

1. **Run tests locally** before pushing to CI
2. **Use --verbose** when debugging test failures
3. **Test both platforms** if building multi-arch images
4. **Add tests** when adding new components to variants
5. **Use --no-fail-fast** to see all failures at once when debugging
