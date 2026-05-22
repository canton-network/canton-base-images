# SBOM and Provenance Generation

## Overview

This document explains how to generate Software Bill of Materials (SBOM) and provenance attestations for DA Base Images, and why Google Artifact Registry (GAR) has limitations with these features.

## Google Artifact Registry Limitations

### Why Attestations Don't Work Well with GAR

1. **No Native Attestation Storage**: GAR doesn't natively support storing OCI attestations (SBOM/provenance) in the same way as Docker Hub or GitHub Container Registry
2. **Registry Spec Limitations**: GAR implements a subset of the OCI Distribution Spec and doesn't fully support referrers API for attestations
3. **Missing UI Support**: Even if attestations are pushed, GAR UI won't display them
4. **API Gaps**: Standard tools like `cosign` or `docker buildx imagetools` can't reliably retrieve attestations from GAR

### What Happens When You Try

When you use `--sbom=true` or `--provenance=mode=max` with GAR:
- Docker buildx may succeed in building
- Attestations are generated
- Push may appear to work
- **But**: Attestations aren't actually stored or are inaccessible
- Result: No way to verify or retrieve the attestations later

## Recommended Approaches

### Option 1: Export SBOM to File (Recommended for GAR)

Generate SBOM and save it alongside your image:

```bash
# Build with SBOM saved to file
./create_image_variant.sh \
  --variant jdk \
  --tag europe-docker.pkg.dev/project/repo/image:tag \
  --sbom-output sbom-jdk.spdx.json \
  --push

# SBOM file can be:
# - Stored in Cloud Storage bucket
# - Uploaded to security scanning platform
# - Committed to git (if not too large)
# - Used for compliance audits
```

### Option 2: Use Syft Separately

Generate SBOM after the image is built using [Syft](https://github.com/anchore/syft):

```bash
# Build and push image normally
./create_image_variant.sh --variant jdk --tag myimage:latest --push

# Generate SBOM separately
syft myimage:latest -o spdx-json > sbom.spdx.json
syft myimage:latest -o cyclonedx-json > sbom.cyclonedx.json
syft myimage:latest -o table  # Human-readable table
```

### Option 3: Use Cloud Build Attestations

If using Google Cloud Build, use its native attestation features:

```yaml
# cloudbuild.yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', '$_IMAGE_NAME', '.']
  
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '$_IMAGE_NAME']

# Enable Binary Authorization
options:
  requestedVerifyOption: VERIFIED
```

Then use Binary Authorization policies to require attestations.

### Option 4: Alternative Registry

Consider using a registry with better attestation support for critical images:

- **GitHub Container Registry**: Full OCI attestation support
- **Docker Hub**: Supports Docker Content Trust
- **Harbor**: Self-hosted with Notary integration
- **Azure Container Registry**: Content Trust support

## SBOM Format Options

When generating SBOMs, you can choose formats:

```bash
# SPDX JSON (default, widely supported)
--sbom-output sbom.spdx.json

# CycloneDX (alternative format)
syft image -o cyclonedx-json > sbom.cyclonedx.json

# In-toto (for provenance)
cosign attest --predicate sbom.spdx.json --type spdxjson image
```

## Provenance Generation

Provenance tracks how the image was built. For GAR, generate provenance separately:

```bash
# Generate provenance with in-toto format
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --provenance=mode=max \
  --output type=local,dest=./build-output \
  .

# Provenance will be in build-output/provenance.json
```

Or use SLSA provenance generators:

```bash
# Install slsa-provenance
go install github.com/slsa-framework/slsa-github-generator/...@latest

# Generate SLSA provenance
slsa-provenance generate \
  --subject myimage:latest \
  --output provenance.json
```

## CI/CD Integration

### GitHub Actions

```yaml
- name: Build image with SBOM
  run: |
    ./create_image_variant.sh \
      --variant jdk \
      --tag ${{ env.IMAGE }} \
      --sbom-output sbom-${{ matrix.variant }}.spdx.json \
      --push

- name: Upload SBOM as artifact
  uses: actions/upload-artifact@v4
  with:
    name: sbom-${{ matrix.variant }}
    path: sbom-${{ matrix.variant }}.spdx.json

- name: Upload SBOM to GCS
  run: |
    gsutil cp sbom-*.spdx.json gs://my-sbom-bucket/$(date +%Y%m%d)/
```

### Cloud Build

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'buildx'
      - 'build'
      - '--platform=linux/amd64,linux/arm64'
      - '--tag=${_IMAGE_NAME}'
      - '--push'
      - '.'
    env:
      - 'DOCKER_BUILDKIT=1'

  - name: 'anchore/syft'
    args: ['${_IMAGE_NAME}', '-o', 'spdx-json=/workspace/sbom.spdx.json']

  - name: 'gcr.io/cloud-builders/gsutil'
    args: ['cp', '/workspace/sbom.spdx.json', 'gs://${_SBOM_BUCKET}/']
```

## Verification

### Verify SBOM Contents

```bash
# View SBOM packages
jq '.packages[] | {name: .name, version: .versionInfo}' sbom.spdx.json

# Count packages
jq '.packages | length' sbom.spdx.json

# Find specific package
jq '.packages[] | select(.name == "openssl")' sbom.spdx.json
```

### Scan SBOM for Vulnerabilities

```bash
# Use Grype to scan SBOM
grype sbom:sbom.spdx.json

# Use Trivy to scan SBOM
trivy sbom sbom.spdx.json
```

## Best Practices

1. **Store SBOMs separately**: Don't rely on registry attestation storage
2. **Version SBOM files**: Include image tag/digest in SBOM filename
3. **Automate generation**: Generate SBOM for every build in CI/CD
4. **Scan regularly**: Run vulnerability scans against stored SBOMs
5. **Retention policy**: Keep SBOMs for compliance period (e.g., 7 years)
6. **Access control**: Protect SBOM storage with appropriate IAM policies

## Troubleshooting

### "attestation not found" Error

```bash
# This is expected with GAR - attestations aren't stored
docker buildx imagetools inspect --format '{{ json .Attestations }}' myimage:latest
# Returns: null or error
```

**Solution**: Use file-based SBOM generation or external tools.

### SBOM Generation Fails

```bash
# Check buildkit version
docker buildx version
# Need v0.11+ for full SBOM support

# Ensure buildkit builder supports attestations
docker buildx create --use --name sbom-builder
```

### Large SBOM Files

For minimal images, SBOM should be small (< 100KB). If large:
- Review base image layers
- Consider compression: `gzip sbom.spdx.json`
- Use binary formats if supported by tooling

## References

- [OCI Image Spec Attestations](https://github.com/opencontainers/image-spec/blob/main/manifest.md)
- [SLSA Provenance](https://slsa.dev/provenance/)
- [SPDX Specification](https://spdx.dev/specifications/)
- [CycloneDX BOM Standard](https://cyclonedx.org/)
- [Docker Buildx Attestations](https://docs.docker.com/build/attestations/)
- [Syft SBOM Generator](https://github.com/anchore/syft)
- [Google Binary Authorization](https://cloud.google.com/binary-authorization/docs)
