# Image Labels and Annotations

This document describes the labeling strategy used for DA Base Images.

## Overview

All images are labeled using:
1. **OCI Image Spec** standard labels for interoperability
2. **Custom labels** for component versions and variant information
3. **Build metadata** for traceability

## Label Categories

### OCI Standard Labels

Following the [OCI Image Spec annotation standard](https://github.com/opencontainers/image-spec/blob/main/annotations.md):

| Label | Description | Example |
|-------|-------------|---------|
| `org.opencontainers.image.created` | ISO 8601 timestamp of build | `2025-11-12T16:17:20Z` |
| `org.opencontainers.image.authors` | Image authors | `DACH-NY` |
| `org.opencontainers.image.url` | Project URL | `https://github.com/DACH-NY/da-base-images` |
| `org.opencontainers.image.documentation` | Documentation URL | `.../README` |
| `org.opencontainers.image.source` | Source repository URL | `https://github.com/...` |
| `org.opencontainers.image.version` | Semantic version or date | `2025.11` or git tag |
| `org.opencontainers.image.revision` | Git commit SHA | `3dddb23` |
| `org.opencontainers.image.vendor` | Vendor/organization | `digitialasset` |
| `org.opencontainers.image.title` | Human-readable title | `DA Base Image` |
| `org.opencontainers.image.description` | Image description | `Minimal container base image...` |
| `org.opencontainers.image.base.name` | Base image name | `scratch` |

### Custom Image Metadata

Universal labels that apply to all image variants:

| Label | Description | Example |
|-------|-------------|---------|
| `io.digitalasset.image.variant` | Rootfs variant | `full`, `jdk`, `node`, `base`, `minimal` |
| `io.digitalasset.image.architecture` | Target architecture | `amd64`, `arm64` |

## Viewing Labels

### Using Docker CLI

View all labels:
```bash
docker inspect <image> --format='{{json .Config.Labels}}' | jq .
```

View specific label:
```bash
docker inspect <image> --format='{{index .Config.Labels "org.opencontainers.image.version"}}'
```

### Using the helper script

We provide a helper script to display labels in a readable format:

```bash
./scripts/inspect_labels.sh <image>
```

Example output:
```
═══════════════════════════════════════════════════════════
DA Base Image Labels
═══════════════════════════════════════════════════════════
Image: test-labels:full

OCI Standard Labels:
  authors: Digital Asset LLC
  base name: scratch
  created: 2025-11-12T16:55:33Z
  description: Minimal container base image with glibc, busybox, and optional components
  documentation: https://github.com/digitalasset/da-base-images/blob/main/README
  revision: 3dddb23
  source: https://github.com/digitalasset/da-base-images
  title: DA Base Image
  url: https://github.com/digitalasset/da-base-images
  vendor: digitalasset
  version: 2025.11

Custom Labels:
  architecture: amd64
  variant: full

Component Versions:
  (none - component versions are variant-specific and tracked separately)
═══════════════════════════════════════════════════════════
```

## Adding Labels

### At Build Time

Labels are automatically added during image build via `create_image_variant.sh`:

```bash
./create_image_variant.sh --variant full --tag myimage:latest
```

The script:
1. Gets git metadata (commit SHA, repo URL)
2. Generates build timestamp (ISO 8601 format)
3. Determines version from git tags or date (YYYY.MM format)
4. Passes all as `--build-arg` to Docker buildx
5. Dockerfile applies them as `LABEL` instructions

Note: Component versions (glibc, busybox, etc.) are not included in image labels because they vary by variant and not all components are present in all variants.

### Custom Labels

To add additional labels during build, modify `create_image_variant.sh`:

```bash
buildx_args+=(
    "--label" "com.example.custom=value"
    "--label" "com.example.team=myteam"
)
```

Or add to `config/Dockerfile`:

```dockerfile
LABEL com.example.custom="value" \
      com.example.team="myteam"
```

## Label Querying in CI/CD

### GitHub Actions

Extract labels in workflows:

```yaml
- name: Get image version
  id: version
  run: |
    VERSION=$(docker inspect ${{ env.IMAGE }} \
      --format='{{index .Config.Labels "org.opencontainers.image.version"}}')
    echo "version=$VERSION" >> $GITHUB_OUTPUT
```

### Security Scanning

Trivy and other scanners can use labels for:
- OS identification (`org.opencontainers.image.base.name`)
- Version tracking (`org.opencontainers.image.version`)
- Provenance verification (`org.opencontainers.image.revision`)

### Policy Enforcement

Use tools like OPA to enforce policies based on labels:

```rego
# Require images to have version label
deny[msg] {
  not input.Config.Labels["org.opencontainers.image.version"]
  msg = "Image must have org.opencontainers.image.version label"
}

# Require specific variant
deny[msg] {
  not input.Config.Labels["io.dach.image.variant"] == "full"
  msg = "Only full variant allowed in this environment"
}
```

## Label Best Practices

1. **Use OCI standard labels** for maximum compatibility
2. **Namespace custom labels** with reverse domain notation (`io.digitalasset.*`)
3. **Keep values simple** - avoid complex JSON or sensitive data
4. **Document all labels** in this file
5. **Automate labeling** via build scripts (don't manually add)
6. **Version consistently** - use semantic versioning or date-based

## Label Conventions

### Naming

- Use lowercase with dots as separators
- Reverse domain notation for custom labels
- Descriptive but concise

### Values

- Use ISO 8601 for timestamps
- Semantic versioning for software versions
- Short git SHAs (7-8 characters)
- Absolute URLs

### Avoid

- Sensitive information (credentials, keys)
- Large data (logs, configs)
- Frequently changing values (runtime state)
- Special characters that need escaping

## References

- [OCI Image Spec Annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
- [Docker Object Labels](https://docs.docker.com/config/labels-custom-metadata/)
- [Label Schema (deprecated but informative)](http://label-schema.org/)
