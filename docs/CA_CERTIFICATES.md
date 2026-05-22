# CA Certificate Management

This project uses Mozilla's CA certificate bundle, maintained by the curl project, instead of copying certificates from the build host.

## Overview

- **Source**: Mozilla's CA certificate bundle (https://curl.se/ca/cacert.pem)
- **Verification**: SHA256 checksum validated on every download
- **Version tracking**: Bundle date extracted and stored in `src/cacert.version`
- **Update frequency**: Mozilla typically updates the bundle several times per year

## How it works

### Download

The `scripts/download_cacerts.sh` script:
1. Downloads the latest CA bundle from curl's website
2. Downloads and verifies the SHA256 checksum
3. Extracts the bundle date from the certificate comments
4. Compares against the pinned version in `da_image.conf`
5. Saves the bundle and version file

Version checking:
- If `src/cacert.pem` exists with matching version → skips download
- If version differs → re-downloads and warns if older than pinned version
- Saves actual bundle date to `src/cacert.version`

### Installation

The `scripts/create_rootfs.sh` script:
1. Copies the CA bundle to `/etc/ssl/certs/ca-certificates.crt`
2. Creates `/etc/ssl/certs/ca-bundle.crt` symlink (used by some applications)
3. Splits the bundle into individual certificates
4. Creates OpenSSL hash-based symlinks (e.g., `3513523f.0`) for each certificate
5. Cleans up temporary files

Applications can use:
- `/etc/ssl/certs/ca-certificates.crt` (full bundle, PEM format)
- `/etc/ssl/certs/ca-bundle.crt` (symlink to above)
- `/etc/ssl/certs/<hash>.0` (individual certs by OpenSSL hash)

## Version pinning

Edit `da_image.conf` to pin a specific bundle date:

```bash
CACERT_VERSION="2025-11-04"  # YYYY-MM-DD format
```

The download script will:
- Always fetch the latest bundle from upstream
- Compare the bundle date against `CACERT_VERSION`
- Warn if downloaded bundle is older or different
- Suggest updating `CACERT_VERSION` if a newer bundle is found

## Manual operations

### Download CA certificates

```bash
./scripts/download_cacerts.sh
```

### Check for updates

```bash
./scripts/check_updates.sh
```

The update checker:
- Fetches the latest bundle metadata
- Extracts the bundle date
- Compares against `CACERT_VERSION` in `da_image.conf`
- Reports if an update is available

### Force re-download

```bash
rm src/cacert.pem src/cacert.version
./scripts/download_cacerts.sh
```

## Integration with CI

The build workflow automatically:
1. Downloads CA certificates via `download_all.sh`
2. Installs them into each rootfs variant
3. Caches downloaded files across workflow runs

The update checker workflow:
- Checks for new CA bundle versions
- Reports updates in the GitHub issue (if enabled)
- Runs on schedule or manually

## Updating the pinned version

When a new CA bundle is available:

1. Check the latest bundle date:
   ```bash
   curl -s https://curl.se/ca/cacert.pem | head -20 | grep "Certificate data from"
   ```

2. Update `da_image.conf`:
   ```bash
   CACERT_VERSION="YYYY-MM-DD"  # Use the date from step 1
   ```

3. Download and rebuild:
   ```bash
   ./scripts/download_cacerts.sh
   ./scripts/create_rootfs.sh --variant <variant>
   ```

## Troubleshooting

### "Could not extract date from certificate bundle"

The bundle format may have changed. Check the file manually:
```bash
head -20 src/cacert.pem
```

Look for a line like:
```
## Certificate data from Mozilla as of: Tue Nov  4 04:12:02 2025 GMT
```

### "Downloaded bundle date is older than pinned version"

This happens when:
- You've pinned a future date by mistake
- Mozilla hasn't published a new bundle yet
- The upstream URL is serving a cached version

Verify the latest bundle date at: https://curl.se/docs/caextract.html

### OpenSSL hash symlinks not created

The host needs `openssl` command installed:
```bash
sudo apt-get install openssl
```

Without it, applications must use `/etc/ssl/certs/ca-certificates.crt` directly.

### Certificate count seems low

Mozilla periodically removes outdated or untrustworthy CAs. A decreasing count is normal and expected.

## Alternative approaches considered

1. **Perl script (mk-ca-bundle.pl)**
   - Pros: Can convert certdata.txt directly from Mozilla's NSS repository
   - Cons: Requires perl dependencies; more complex; essentially duplicates curl's work
   - Verdict: Unnecessary since curl already maintains the converted bundle

2. **Debian/Ubuntu ca-certificates package**
   - Pros: Well-maintained, widely used
   - Cons: Requires extracting from .deb; ties us to Debian release schedule
   - Verdict: Adds complexity without benefit

3. **Copy from build host**
   - Pros: Simple, no download required
   - Cons: Unpredictable versions; host-dependent; no verification
   - Verdict: Previous approach, now replaced

## References

- Curl CA Extract: https://curl.se/docs/caextract.html
- Mozilla CA Policy: https://wiki.mozilla.org/CA
- OpenSSL certificates: https://www.openssl.org/docs/man1.1.1/man1/c_rehash.html
