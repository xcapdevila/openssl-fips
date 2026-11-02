#!/bin/sh
# Run inside the initialized image: sh /tests/smoke.sh
set -eu

fail() {
    printf 'Smoke test failed: %s\n' "$*" >&2
    exit 1
}

runtime_tag=${OPENSSL_SOURCE_TAG:-openssl-3.5.9}
fips_tag=${FIPS_SOURCE_TAG:-openssl-3.1.2}
expected_runtime=${EXPECTED_OPENSSL_VERSION:-${runtime_tag#openssl-}}
expected_fips=${EXPECTED_FIPS_VERSION:-${fips_tag#openssl-}}
test_dir=$(mktemp -d /tmp/openssl-smoke.XXXXXXXXXX)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

[ "$(command -v openssl)" = /opt/openssl/bin/openssl ] || fail 'unexpected OpenSSL executable'
openssl version | grep -F "OpenSSL $expected_runtime " >/dev/null || fail 'runtime version'
ldd /opt/openssl/bin/openssl > "$test_dir/libraries"
for library in libcrypto libssl; do
    awk -v library="$library" '
        $1 ~ ("^" library "\\.so\\.[0-9]+$") && $2 == "=>" &&
            $3 == ("/opt/openssl/lib/" $1) { found = 1 }
        END { exit !found }
    ' "$test_dir/libraries" || fail "$library does not resolve to the installed runtime"
done

openssl list -providers > "$test_dir/providers"
for provider in fips base; do
    awk -v selected="$provider" '
        /^  [^ ]/ { active = ($1 == selected) }
        active { print }
    ' "$test_dir/providers" > "$test_dir/$provider"
    grep -F 'status: active' "$test_dir/$provider" >/dev/null || fail "$provider is not active"
done
grep -F "version: $expected_fips" "$test_dir/fips" >/dev/null || fail 'selected FIPS provider version'
grep -F "version: $expected_runtime" "$test_dir/base" >/dev/null || fail 'base provider version'
if grep -Eq '^  default$' "$test_dir/providers"; then
    fail 'the default provider is unexpectedly active'
fi

[ -r "$OPENSSL_FIPS_CONFIG" ] || fail 'runtime module configuration is missing'
if grep -Eq '^[[:space:]]*(install-status|install-mac)[[:space:]]*=' "$OPENSSL_FIPS_CONFIG"; then
    fail 'module configuration must run self tests on every load'
fi
OPENSSL_CONF=/dev/null openssl fipsinstall -module "$OPENSSL_FIPS_MODULE" \
    -in "$OPENSSL_FIPS_CONFIG" -self_test_onload -verify -quiet || \
    fail 'selected module configuration verification'
openssl fipsinstall -config "$OPENSSL_CONF" -quiet || fail 'configured module self tests'

# A known answer under the configured defaults also exercises the FIPS fetch.
sha256=$(printf abc | openssl dgst -sha256 -binary | od -An -tx1 | tr -d ' \n')
[ "$sha256" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ] || \
    fail 'SHA-256 known answer'
openssl rand -out "$test_dir/random" 32
[ "$(wc -c < "$test_dir/random")" -eq 32 ] || fail 'random output length'

printf 'OpenSSL FIPS smoke test\n' > "$test_dir/plaintext"
key=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
iv=000102030405060708090a0b0c0d0e0f
openssl enc -aes-256-cbc -K "$key" -iv "$iv" \
    -in "$test_dir/plaintext" -out "$test_dir/ciphertext"
openssl enc -d -aes-256-cbc -K "$key" -iv "$iv" \
    -in "$test_dir/ciphertext" -out "$test_dir/decrypted"
cmp "$test_dir/plaintext" "$test_dir/decrypted" || fail 'AES round trip'
if cmp -s "$test_dir/plaintext" "$test_dir/ciphertext"; then
    fail 'AES encryption did not change the message'
fi

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$test_dir/key.pem"
openssl pkey -in "$test_dir/key.pem" -pubout -out "$test_dir/public.pem"
openssl dgst -sha256 -sign "$test_dir/key.pem" -out "$test_dir/signature" "$test_dir/plaintext"
openssl dgst -sha256 -verify "$test_dir/public.pem" \
    -signature "$test_dir/signature" "$test_dir/plaintext" > "$test_dir/verification"
grep -F 'Verified OK' "$test_dir/verification" >/dev/null || fail 'ECDSA verification'
printf 'modified message\n' > "$test_dir/modified"
if openssl dgst -sha256 -verify "$test_dir/public.pem" \
    -signature "$test_dir/signature" "$test_dir/modified" > "$test_dir/negative-signature" 2>&1; then
    fail 'ECDSA accepted a modified message'
fi

if printf abc | openssl dgst -md5 > "$test_dir/md5" 2>&1; then
    fail 'MD5 was available under the configured defaults'
fi

# Confirm that the installed provider actually reports a forced KAT failure.
# Disable config autoload so fipsinstall installs its test callback first.
if OPENSSL_CONF=/dev/null openssl fipsinstall -module "$OPENSSL_FIPS_MODULE" \
    -out "$test_dir/failed-selftest.cnf" -self_test_onload -corrupt_desc SHA1 \
    -quiet > "$test_dir/negative-selftest" 2>&1; then
    fail 'the selected module accepted an induced self-test failure'
fi

printf 'Smoke tests passed: runtime %s, FIPS provider %s\n' "$expected_runtime" "$expected_fips"
