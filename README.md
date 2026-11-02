# OpenSSL with a FIPS provider

[![Build and verify](https://github.com/xcapdevila/openssl-fips/actions/workflows/build.yml/badge.svg)](https://github.com/xcapdevila/openssl-fips/actions/workflows/build.yml)

Build a maintained OpenSSL CLI with the separately built OpenSSL FIPS provider.
The container loads the `fips` and `base` providers and sets `fips=yes` as the
default algorithm property. It runs the module installation checks on startup.

## Versions

Defaults reviewed on 2 November 2026:

| Component | Default | Purpose |
|---|---|---|
| Ubuntu | 26.04, pinned multi-platform digest | Container base |
| OpenSSL runtime | 3.5.9 LTS | CLI and shared libraries |
| FIPS provider source | 3.1.2 | Separately built module associated with FIPS 140-3 certificate #4985 |

The runtime and provider versions are deliberately independent. OpenSSL supports
using a validated provider with a newer supported runtime. The runtime is built
with `no-fips` to avoid installing its own, different FIPS module. The selected
3.1.2 module is copied from its separate build without source patches.

See the [OpenSSL downloads](https://www.openssl-library.org/source/),
[FIPS build guidance](https://github.com/openssl/openssl/blob/master/README-FIPS.md)
and [NIST certificate #4985](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4985).

## Build and run

Docker with Linux containers is required. Build natively on your host:

```sh
docker build --progress=plain -t openssl-fips:local .
docker run --rm openssl-fips:local
```

The default command lists the active providers: `base` from 3.5.9 and `fips` from
3.1.2. Other commands accept normal argument lists:

```sh
docker run --rm openssl-fips:local openssl version -a
docker run --rm openssl-fips:local openssl list -providers -verbose
docker run --rm openssl-fips:local openssl rand -base64 32
printf abc | docker run --rm -i openssl-fips:local openssl dgst -sha256
```

The previous single-string command interface is also supported:

```sh
docker run --rm openssl-fips:local 'openssl list -providers'
docker run --rm openssl-fips:local --shell 'openssl version; openssl list -providers'
docker run --rm -it openssl-fips:local /bin/bash
```

A single argument containing whitespace and the explicit `--shell` form execute
through Bash. Use normal argument lists when shell interpretation is unnecessary.

## What startup verifies

The build verifies HTTPS certificates and both source archive SHA-256 values. A
separate final stage contains the CLI, required shared libraries and chosen FIPS
module, without the compiler or downloaded source trees.

At startup, the entrypoint:

1. Checks the selected module against the installed artifact's recorded SHA-256.
2. Creates a private configuration directory in writable temporary storage.
3. Runs `openssl fipsinstall` and verifies the resulting configuration.
4. Loads the configured provider before executing the requested command.

No builder-generated `fipsmodule.cnf` or installation-status fields are shipped.
The generated configuration uses `-self_test_onload`, so the module's known-answer
tests also run on subsequent loads. Startup exits if a check fails.

The default user is UID/GID 10001. A read-only root filesystem works with writable
temporary storage:

```sh
docker run --rm --read-only --tmpfs /tmp openssl-fips:local
```

`OPENSSL_FIPS_TMPDIR` optionally selects the parent temporary directory;
`OPENSSL_FIPS_MODULE` selects an absolute module path whose bytes must match the
artifact recorded in this image. Its filename must be `fips.so`, as OpenSSL's
bootstrap installer resolves the provider by that name. The generated configuration is used by the
command and its child processes for that container session.

## FIPS scope

**This repository does not certify a container or deployment.** Loading the FIPS
provider, passing self-tests and using `fips=yes` are functional checks. An approved
deployment must also satisfy the module's security policy, operating-environment
requirements and applicable algorithm/operation restrictions.

The selected source release has a published validation; that does not make every
locally compiled binary or container configuration a validated deployment. This
image's Ubuntu/compiler combination is not asserted to be a listed validated
operating environment. Explicit OpenSSL property/provider overrides can also
change algorithm selection; the defaults are not an isolation boundary.

Read the [module security policy](https://csrc.nist.gov/CSRC/media/projects/cryptographic-module-validation-program/documents/security-policies/140sp4985.pdf),
[OpenSSL FIPS configuration guide](https://docs.openssl.org/3.5/man7/fips_module/)
and [module status/security guidance](https://www.openssl-library.org/news/fips-cve/index.html).

## Verify the image

```sh
./tests/run.sh openssl-fips:local
```

The focused container checks cover provider/runtime identity, default algorithm
selection, cryptographic operations, read-only/nonroot operation, command-interface
compatibility and refusal to start with a missing, modified or unusable module
configuration. They are not a substitute for module validation or the full upstream
OpenSSL test suite.

GitHub Actions builds and tests natively on Linux AMD64 and ARM64. Images are not
automatically published to a registry.

## Updating the build

The existing version argument names are preserved. Change a version and its
matching archive checksum together:

```sh
docker build \
  --build-arg OPENSSL_VERSION=openssl-X.Y.Z \
  --build-arg OPENSSL_SHA256=OFFICIAL_ARCHIVE_SHA256 \
  -t openssl-fips:local .
```

The corresponding provider arguments are `FIPS_OPENSSL_VERSION` and
`FIPS_OPENSSL_SHA256`. Obtain hashes from the official release assets, review the
module's validation/security status independently, and rerun the checks after an
update. `MAKE_JOBS` controls parallel compilation and defaults to 2.

The base image digest, archive hashes and CI action revisions are pinned. Package
installation still uses the distribution's current signed repositories, so this
build does not claim bit-for-bit reproducibility.
