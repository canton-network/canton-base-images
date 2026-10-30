# Development in a Docker Sandbox (sbx)

AI-assisted development for this repository runs in a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/)
(`sbx`) using the `claude` agent. The sandbox is declared in the repository, so a new
one has the full build toolchain without manual setup.

> `sbx env` and kits are experimental; the file formats may change.

## Files

| File | Purpose |
| ---- | ------- |
| [`sbxenv.yaml`](../sbxenv.yaml) | Environment file: agent (`claude`), workspace (this repo), 4 CPUs, 8 GB memory, and the kit to load |
| [`.sbx/kit/spec.yaml`](../.sbx/kit/spec.yaml) | Kit (v2 mixin): network allowlist, package installs, key import at startup |
| [`keys/trusted-keys.asc`](../keys/trusted-keys.asc) | Committed keyring with the upstream signing keys used to verify downloads |

## Usage

```bash
sbx env plan      # preview what will be created
sbx env run       # create (if needed), then attach to the agent
sbx env exec -- <command>   # run a command in the existing sandbox
sbx env rm        # remove the sandbox
```

Docker builds work inside the sandbox: the built-in `claude` agent uses Docker's
`claude-code-docker` template, which includes Docker Engine.

Kit changes only apply when the sandbox is created. After editing `.sbx/kit/spec.yaml`
or `keys/trusted-keys.asc`, run `sbx env rm` then `sbx env create`. This discards
anything outside the mounted workspace, so keep build output in the repository.

Validate kit edits with `sbx kit validate ./.sbx/kit --offline`.

## What the kit installs

- **Build dependencies**, mirroring the CI workflow: `build-essential`, x86_64 and
  aarch64 cross compilers, `bison`, `gawk`, `texinfo`, `qemu-user`, `proot`, `jq`,
  `gpg`, `direnv` and others.
- **GCC 13** (native and both cross toolchains). `scripts/build_gcc.sh` pins GCC 13
  because newer compilers fail building the GCC 13 libstdc++ sources. The sandbox
  base image (Ubuntu 26.04) defaults to GCC 15.
- **`qemu-*-static` symlinks.** Ubuntu 26.04 has no `qemu-user-static` package.
  `qemu-user` ships statically linked binaries, and the kit symlinks them to the
  `qemu-aarch64-static` and `qemu-x86_64-static` names that `create_rootfs.sh` expects.
- **`syft` and `grype`** from `get.anchore.io`.

`cosign` and `trivy` (used in CI) are not installed.

## Signature verification and GPG keys

The `download_*.sh` scripts fetch each key from `keyserver.ubuntu.com` with
`gpg --recv-keys`. gpg does not use the sandbox's HTTP proxy, so this fails inside the
sandbox. Instead, the kit imports `keys/trusted-keys.asc` on every sandbox start, and the
scripts then find the keys already present and skip the keyserver.

When adding or changing a `KEYID` in `artifacts.json`, update the keyring too:

```bash
export GNUPGHOME=$(mktemp -d)
gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys <FULL_FINGERPRINT>
# repeat for every key in artifacts.json, then:
gpg --armor --export > keys/trusted-keys.asc
```

Verify fingerprints against the upstream project before committing. Prefer full
40-character fingerprints in `artifacts.json`; two entries are 16-character key IDs.
Treat changes to `keys/trusted-keys.asc` as security-sensitive and review them as code.

## Working from VS Code

VS Code Remote - SSH connects directly to the sandbox. This gives the VS Code
workspace access to the sandbox's toolchain, terminals, language services, extensions,
tasks and debugger, while the repository remains bind-mounted at the same absolute path.

1. Install the **Remote - SSH** extension in VS Code.
2. Set up Docker Sandbox SSH integration once on the host:

   ```bash
   sbx setup ssh
   ```

   This generates and includes SSH configuration for `*.sbx` hosts. It is safe to
   rerun if the configuration needs refreshing.
3. Connect to this repository's sandbox from VS Code. Open the Command Palette, select
   **Remote-SSH: Connect to Host...**, and choose `canton-base-images.sbx`. Or open a
   host terminal and run:

   ```bash
   code --remote ssh-remote+canton-base-images.sbx /home/kareemkhan/Projects/canton-base-images
   ```

   The command-line example uses the current host's absolute repository path. The
   sandbox mounts the workspace at that same path. In the remote VS Code window, open
   a terminal, run builds there, and install any requested extensions when prompted
   to install them on the SSH host. Use F5 to launch the debugger remotely as well.

The Claude Code extension (`anthropic.claude-code`) is listed in
[`.vscode/extensions.json`](../.vscode/extensions.json). In the remote window, accept the
prompt to install the recommended extension on the SSH host. To install it automatically
on every sandbox, add this to your VS Code user settings (it can't be set per workspace):

```json
"remote.SSH.defaultExtensions": ["anthropic.claude-code"]
```

No ports need to be published for this SSH connection. The sandbox network policy still
applies to VS Code Server and remote extensions. The VS Code Server and extensions are
installed in the sandbox; removing and recreating the sandbox removes those installs,
so they may need to be downloaded again.

For files outside the mounted workspace, use `sbx cp` with absolute sandbox paths.

## Network access

The sandbox can only reach hosts in `permissions.network.allow` in the kit: Ubuntu apt
mirrors, the upstream source hosts (GNU, busybox, curl, nodejs, adoptium, IANA), GitHub,
`get.anchore.io`, and the Docker and GHCR registries. If a download or build step is
blocked, check `sbx policy log` and add the host to the kit, then recreate the sandbox.

## Secrets

`sbxenv.yaml` is mounted read-only because it sits in the workspace root. Do not keep
secrets in `.envrc.private`; the agent can read the workspace. Use `sbx secret` instead.
