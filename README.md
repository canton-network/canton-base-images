# DA Base Images

This project is dedicated to building a suite of secure, minimal, and multi-architecture base container images. These images serve as a standardized foundation for developing and deploying other containerized applications, ensuring consistency and security from the ground up.

## Key Features

- **Multi-arch support**: linux/amd64 and linux/arm64
- **Variant-based images**: minimal, base, jdk (standard), full 
- **Security**: Trivy scanning integrated in CI, Mozilla CA certificates
- **Automated updates**: Update checker for all components
- **Reproducible builds**: Version-pinned dependencies with signature verification
- **OCI labels**: Full metadata labeling for compliance and tooling integration

## Prerequisites

Install the following dependencies:

```bash
sudo apt install gawk bison
sudo apt install build-essential
sudo apt install linux-headers-generic
sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
sudo apt-get install gcc-x86-64-linux-gnu g++-x86-64-linux-gnu
sudo apt-get install openssl  # Required for CA certificate hash generation
```

## Documentation

- [Variants](docs/VARIANTS_QUICKREF.md) - Overview of image variants
- [Testing](docs/TESTING.md) - Functional test framework
- [CA Certificates](docs/CA_CERTIFICATES.md) - Certificate management
- [Image Labels](docs/LABELS.md) - Label annotations and metadata
- [Trivy Scanning](#image-vulnerability-scanning-trivy) - Security scanning

## CI/CD and Release Process

This repository uses GitHub Actions to automate the build, test, and release process. The workflow is defined in [`.github/workflows/build-images.yml`](./.github/workflows/build-images.yml).

### Continuous Integration

On every push to the `main` and `release-line*` branches, the workflow will:
1.  Build all image variants for both `amd64` and `arm64` architectures.
2.  Run a suite of tests against the newly built images.
3.  Scan the images for vulnerabilities using Trivy.

This process ensures that the codebase is always in a buildable and tested state, but it does **not** push the images to a public registry or create a release.

### Release Creation (Tag-Based)

To create a new public release, you must create and push a Git tag with a version number prefixed by `v` (e.g., `v1.2.3`).

1.  **Create a tag**:
    ```bash
    git tag v1.2.3
    ```
2.  **Push the tag**:
    ```bash
    git push origin v1.2.3
    ```

Pushing a tag will trigger the full release workflow, which includes:
- Building and testing all image variants.
- Pushing the images to the Google Artifact Registry.
- Cryptographically signing the images.
- Creating a new GitHub Release with the corresponding version number.

### Registry

The workflow targets Google Artifact Registry (GAR). The images are pushed to the following locations:

- **Production**: `europe-docker.pkg.dev/da-images/public/docker/da-base-image:<variant>-<version>`
- **Beta**: `europe-docker.pkg.dev/da-images/private-unstable/docker/da-base-image:<variant>-<version>`

The specific registry used depends on whether the build is a `production` (from a tag on `release-line`) or `beta` (from a push to `main`) build.

## Image Vulnerability Scanning (Trivy)

This repo integrates Trivy to scan the built images for HIGH/CRITICAL vulnerabilities and publishes results to GitHub Code Scanning.

- In the build workflow (`.github/workflows/build-images.yml`), scans run automatically after images are built.
- A standalone workflow (`.github/workflows/scan-images.yml`) lets you scan the rolling or a specific date tag on-demand.

### Run scans manually

1. Go to GitHub → Actions → “Scan Images with Trivy” → Run workflow
2. Inputs:
	- `variants`: e.g., `minimal,base,jdk,full`
	- `tag`: optional date suffix to scan a specific build (e.g., `20251106`). Empty uses the rolling tag.
	- `fail_on_severity`: optional, set to `HIGH,CRITICAL` to fail the run if findings are present.
	- `upload_sarif`: optional, set to `true` to publish results to Code Scanning.

Results:
- SARIF is available under the repository’s “Security → Code scanning alerts”.
- Text reports are attached to the workflow run as artifacts.


Copyright (c) 2026 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
