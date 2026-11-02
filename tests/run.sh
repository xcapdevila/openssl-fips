#!/bin/sh
set -eu

image=${1:-openssl-fips:local}
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
negative_dir=$(mktemp -d)
trap 'rm -rf "$negative_dir"' EXIT HUP INT TERM
chmod 755 "$negative_dir"

printf '%s\n' 'Running cryptographic and provider checks as the image user...'
docker run --rm --read-only --tmpfs /tmp \
    --volume "$test_dir:/tests:ro" "$image" sh /tests/smoke.sh

printf '%s\n' 'Checking default and compatibility commands...'
docker run --rm "$image" >"$negative_dir/default.log"
grep -q 'OpenSSL FIPS Provider' "$negative_dir/default.log"
docker run --rm "$image" 'openssl list -providers' >"$negative_dir/legacy.log"
grep -q 'OpenSSL FIPS Provider' "$negative_dir/legacy.log"
docker run --rm "$image" --shell 'openssl list -providers' >"$negative_dir/shell.log"
grep -q 'OpenSSL FIPS Provider' "$negative_dir/shell.log"
docker run --rm "$image" /bin/bash -c 'test "$(id -u)" -eq 10001 && openssl list -providers' \
    >"$negative_dir/nonroot.log"
grep -q 'OpenSSL FIPS Provider' "$negative_dir/nonroot.log"

printf '%s\n' 'Checking repository and bundled component license notices...'
docker run --rm --entrypoint sh "$image" -ec '
    grep -q "MIT License" /usr/share/doc/openssl-fips/LICENSE
    grep -q "Apache License" /usr/share/doc/openssl-from-source/OPENSSL-LICENSE.txt
    grep -q "Apache License" /usr/share/doc/openssl-from-source/FIPS-LICENSE.txt
'

printf '%s\n' 'Checking the quoted FIPS random-generation command...'
docker run --rm "$image" 'openssl rand -provider fips -base64 32' \
    >"$negative_dir/random-base64.txt"
grep -Eq '^[A-Za-z0-9+/]{43}=$' "$negative_dir/random-base64.txt"
docker run --rm -i "$image" openssl base64 -d \
    <"$negative_dir/random-base64.txt" >"$negative_dir/random.bin"
[ "$(wc -c <"$negative_dir/random.bin")" -eq 32 ] || {
    printf '%s\n' 'FAIL: quoted FIPS command did not produce 32 random bytes' >&2
    exit 1
}

expect_refusal() {
    name=$1
    shift
    if docker run --rm "$@" "$image" sh -c 'echo COMMAND_WAS_EXECUTED' \
        >"$negative_dir/$name.log" 2>&1; then
        printf 'FAIL: %s unexpectedly started\n' "$name" >&2
        cat "$negative_dir/$name.log" >&2
        exit 1
    fi
    if ! grep -q 'FIPS startup failed:' "$negative_dir/$name.log" || \
        grep -q 'COMMAND_WAS_EXECUTED' "$negative_dir/$name.log"; then
        printf 'FAIL: %s did not refuse through the startup checks\n' "$name" >&2
        cat "$negative_dir/$name.log" >&2
        exit 1
    fi
    printf 'PASS: %s refused before executing the command\n' "$name"
}

expect_refusal missing-module --env OPENSSL_FIPS_MODULE=/missing/fips.so
expect_refusal relative-module --env OPENSSL_FIPS_MODULE=relative/fips.so
expect_refusal unwritable-state --read-only --env OPENSSL_FIPS_TMPDIR=/opt

docker run --rm --entrypoint cat "$image" \
    /opt/openssl/lib/ossl-modules/fips.so >"$negative_dir/pristine-fips.so"
chmod 644 "$negative_dir/pristine-fips.so"
docker run --rm --volume "$negative_dir/pristine-fips.so:/override/fips.so:ro" \
    --env OPENSSL_FIPS_MODULE=/override/fips.so "$image" openssl list -providers \
    >"$negative_dir/positive-module.log"
grep -q 'OpenSSL FIPS Provider' "$negative_dir/positive-module.log"
# Create a distinct fixture before mounting it. Mutating a previously mounted
# file can expose stale bytes through desktop VM file-sharing caches.
cp "$negative_dir/pristine-fips.so" "$negative_dir/modified-fips.so"
printf '\nmodified\n' >>"$negative_dir/modified-fips.so"
chmod 644 "$negative_dir/modified-fips.so"
mounted_checksum=$(docker run --rm --entrypoint /bin/sh \
    --volume "$negative_dir/modified-fips.so:/override/fips.so:ro" \
    "$image" -c 'cksum < /override/fips.so')
[ "$mounted_checksum" = "$(cksum <"$negative_dir/modified-fips.so")" ] || {
    printf '%s\n' 'FAIL: mounted corruption fixture differs from the host file' >&2
    exit 1
}
expect_refusal modified-module \
    --volume "$negative_dir/modified-fips.so:/override/fips.so:ro" \
    --env OPENSSL_FIPS_MODULE=/override/fips.so

printf '%s\n' 'PASS: all container checks'
