#!/bin/sh
set -eu

fail() {
    printf 'FIPS startup failed: %s\n' "$*" >&2
    exit 1
}

umask 077
OPENSSL_FIPS_MODULE=${OPENSSL_FIPS_MODULE:-/opt/openssl/lib/ossl-modules/fips.so}
case "$OPENSSL_FIPS_MODULE" in
    /*) ;;
    *) fail 'the module path must be absolute' ;;
esac
[ -f "$OPENSSL_FIPS_MODULE" ] && [ -r "$OPENSSL_FIPS_MODULE" ] || \
    fail 'the selected FIPS module is not a readable file'

# Authenticate the exact installed artifact before producing a new module MAC.
# Recomputing a MAC alone would also accept a modified but loadable module.
expected=$(cat /opt/openssl/ssl/fips-module.sha256)
actual=$(sha256sum "$OPENSSL_FIPS_MODULE")
actual=${actual%% *}
[ "$actual" = "$expected" ] || fail 'the selected FIPS module checksum does not match the image'

state_dir=$(mktemp -d "${OPENSSL_FIPS_TMPDIR:-/tmp}/openssl-fips.XXXXXXXXXX") || \
    fail 'a private writable temporary directory is required'
trap 'rm -rf "$state_dir"' EXIT HUP INT TERM
OPENSSL_FIPS_CONFIG=$state_dir/fipsmodule.cnf
export OPENSSL_FIPS_MODULE OPENSSL_FIPS_CONFIG
export OPENSSL_CONF=/opt/openssl/ssl/openssl.cnf
export OPENSSL_MODULES=/opt/openssl/lib/ossl-modules

# Bootstrap with the built-in default provider only for fipsinstall itself.
# Omit install-status fields so KATs run on every subsequent module load.
OPENSSL_CONF=/dev/null /opt/openssl/bin/openssl fipsinstall \
    -module "$OPENSSL_FIPS_MODULE" -out "$OPENSSL_FIPS_CONFIG" \
    -provider_name fips -section_name fips_sect -self_test_onload -quiet || \
    fail 'module installation or self tests failed'
OPENSSL_CONF=/dev/null /opt/openssl/bin/openssl fipsinstall \
    -module "$OPENSSL_FIPS_MODULE" -in "$OPENSSL_FIPS_CONFIG" \
    -provider_name fips -section_name fips_sect -self_test_onload -verify -quiet || \
    fail 'module configuration verification failed'
/opt/openssl/bin/openssl fipsinstall -config "$OPENSSL_CONF" -quiet || \
    fail 'the configured FIPS provider could not be loaded'

if [ "$#" -eq 0 ]; then
    set -- openssl list -providers
fi

# Preserve the original single-string shell-command interface. The shell is
# invoked only for an explicit shell mode or that legacy one-argument form.
if [ "$1" = '--shell' ]; then
    shift
    [ "$#" -eq 1 ] || fail '--shell requires one command string'
    set -- /bin/bash -c "$1"
elif [ "$#" -eq 1 ]; then
    case "$1" in
        *[[:space:]]*) set -- /bin/bash -c "$1" ;;
    esac
fi

# The command needs its configuration until it exits; /tmp may be a tmpfs.
trap - EXIT HUP INT TERM
exec "$@"
