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
3.1.2 when built with the defaults. Other commands accept normal argument lists:

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

GitHub Actions builds and tests the defaults natively on Linux AMD64 and ARM64,
and tests an OpenSSL 4.1.0 / provider 3.0.9 version-only override on AMD64. These
combinations check technical operation, not deployment validation. Source-selection
tests cover automatic/explicit checksums and malformed inputs without network
access. Images are not automatically published to a registry.

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

## Updating the build

The original two version arguments remain independent. Passing just the versions
is sufficient; no additional checksum argument is required:

```sh
docker build \
  --build-arg OPENSSL_VERSION=openssl-4.1.0 \
  --build-arg FIPS_OPENSSL_VERSION=openssl-3.1.2 \
  -t openssl-fips:custom .
./tests/run.sh openssl-fips:custom
```

For the two default releases, the source helper uses repository-pinned archive
hashes. For another release, it retrieves that release's official `.sha256` asset
over verified HTTPS and verifies the archive before extraction. This checks
integrity against the official download source; it is not independent OpenPGP
signature verification.

`OPENSSL_SHA256` and `FIPS_OPENSSL_SHA256` are optional explicit pins. When supplied,
they take precedence and a mismatch fails the build. Fetch the desired hashes from
the official release assets when you want independently pinned custom releases.
There is no fallback to disabled certificate verification. `MAKE_JOBS` controls
parallel compilation and defaults to 2.

Runtime and provider sources are extracted and built in separate stages, including
when both version arguments are equal. Runtime installation selects its own shared
library ABI, so the image does not hardcode `libcrypto.so.3` or `libssl.so.3`.

## Version compatibility

This image uses the OpenSSL provider architecture: both arguments select release
tags `openssl-X.Y.Z` from version 3 onwards. Legacy OpenSSL 1.x and the historical
FIPS Object Module 2.0 use a different integration and are not supported by this
Dockerfile.

The versions do not need to match. The official
[FIPS module support policy](https://www.openssl-library.org/policies/general/fips-module-support-policy/)
supports an unchanged, supported validated module with supported OpenSSL runtimes
from 3.0 onwards, including later major releases. In particular, the 3.1.2 FIPS
provider can be paired with a supported 3.5, 4.0 or 4.1 runtime.

There is no general rule that the provider's version must be less than or equal to
the runtime's. However, choosing an arbitrary unvalidated provider release does not
give it a validation or a universal cross-major compatibility guarantee. Build and
test the selected pair, and assess the module's current certificate/security-policy
requirements separately. See the [maintainer compatibility discussion](https://groups.google.com/a/openssl.org/g/openssl-users/c/8RKcjxiAMmM/m/xm-HkPEbAwAJ).

The base image digest, default archive hashes and CI action revisions are pinned.
Other versions resolve their official checksums unless explicitly pinned. Package
installation still uses the distribution's current signed repositories, so this
build does not claim bit-for-bit reproducibility.
