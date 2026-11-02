# Publishing and releasing

The build workflow validates source selection and all three native container
profiles before publication: Linux AMD64 defaults, Linux ARM64 defaults, and the
AMD64 runtime/provider override. The tested default images are transferred within
the same workflow run and combined into one multi-platform manifest. They are not
rebuilt in the publishing job.

Only a push to this repository's `main` branch or a `vMAJOR.MINOR.PATCH` tag can
publish. Pull requests and manual validation runs are read-only. The publishing
job alone receives package-write and provenance permissions through the temporary
`GITHUB_TOKEN`; no personal access token is needed. Tagged releases must point to
a commit already reachable from `main`.

## First publication

After merging the publication workflow, let the `main` run complete. GitHub creates
new container packages as private by default, even for a public source repository.

1. Open the [container package](https://github.com/users/xcapdevila/packages/container/openssl-fips).
2. In **Package settings**, set the package visibility to **Public** and check that
   it is connected to `xcapdevila/openssl-fips`.
3. Copy the manifest digest from the successful workflow summary and verify public
   access without using saved registry credentials:

   ```sh
   docker_config=$(mktemp -d)
   DOCKER_CONFIG="$docker_config" docker pull \
     ghcr.io/xcapdevila/openssl-fips@sha256:MANIFEST_DIGEST
   rm -rf "$docker_config"
   ```

4. On a suitable host, run the pulled image's FIPS random-generation command.
   The CI already tests both supported native architectures; the public pull checks
   package visibility, rather than repeating that entire matrix.

Do not announce anonymous availability until that pull succeeds. GitHub's
[registry documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
and [visibility settings](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)
describe this one-time operation.

## First versioned release

The first planned project release is `v0.1.0`. The project version identifies the
container tooling, not an OpenSSL version or a FIPS certification.

1. Review and merge the changes through a pull request, and confirm the `main`
   validation run is successful.
2. Select that reviewed commit and push a version tag:

   ```sh
   git tag v0.1.0 REVIEWED_MAIN_COMMIT
   git push origin v0.1.0
   ```

3. The tag run repeats validation, publishes `v0.1.0` and `0.1.0` aliases, attests a
   new manifest when needed, and creates the GitHub release with generated notes
   and its exact image digest. An existing release is left unchanged on a rerun.
4. Confirm anonymous pulling by that digest and check the release page before
   sharing it.

Tags must be final versions in `vMAJOR.MINOR.PATCH` form. The workflow refuses to
replace a version image with a different digest. Do not move a published Git tag;
issue a new patch version for a correction.

## Tags and provenance

- `latest` moves only after successful validation of the current `main` commit.
  A delayed older run cannot move it backwards.
- `sha-<full-commit-id>` retains the first published manifest for that commit.
  Later reruns verify its attestation and reuse it; they do not claim bit-for-bit
  reproducible rebuilds. These aliases are promoted only after attestation succeeds.
- `vMAJOR.MINOR.PATCH` and `MAJOR.MINOR.PATCH` identify a versioned release.
- `build-<run-id>-<attempt>` and its `-amd64` / `-arm64` tags preserve a new manifest
  and the tested platform images used to assemble it. Keep those images while they are
  supported; deleting them is outside the release workflow.
- The `sha256` manifest digest is the exact pull reference. OCI source/revision
  labels and GitHub attestations link the published content to its source workflow.

The CI artifacts expire after one day; GHCR images are not automatically removed.
Updates to source versions and base-image pins still require review. Publishing
an image does not change the documented FIPS validation scope or promise support.
