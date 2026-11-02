#!/bin/sh
# Usage: fetch-source.sh openssl-X.Y.Z [SHA256-or-empty] archive-output
set -eu

fail() {
    printf 'Source verification failed: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 3 ] || fail 'expected a release version, optional checksum, and output path'
version=$1
expected=$2
output=$3
case "$version" in
    *[!a-z0-9.-]*) fail 'release version contains invalid characters' ;;
esac
printf '%s\n' "$version" | grep -Eq '^openssl-([3-9]|[1-9][0-9]+)\.[0-9]+\.[0-9]+$' || \
    fail 'release version must be openssl-X.Y.Z with major version at least 3'
[ -n "$output" ] || fail 'archive output path is required'

archive=$version.tar.gz
release_url=https://github.com/openssl/openssl/releases/download/$version
checksum_source='explicit checksum'
if [ -z "$expected" ]; then
    checksum_source='pinned release checksum'
    case "$version" in
        openssl-3.1.2) expected=a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539 ;;
        openssl-3.5.9) expected=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a ;;
        *) checksum_source='official HTTPS checksum sidecar' ;;
    esac
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/openssl-source.XXXXXXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

if [ -z "$expected" ]; then
    curl --fail --show-error --location --retry 5 --proto '=https' --tlsv1.2 \
        "$release_url/$archive.sha256" --output "$work_dir/source.sha256"
    expected=$(awk -v archive="$archive" '
        NF == 0 { next }
        {
            lines++
            if (NF == 1 || (NF == 2 && ($2 == archive || $2 == "*" archive))) {
                hash = $1
            } else {
                invalid = 1
            }
        }
        END {
            if (lines != 1 || invalid || length(hash) != 64 || hash ~ /[^a-fA-F0-9]/) {
                exit 1
            }
            print hash
        }
    ' "$work_dir/source.sha256") || fail 'invalid official SHA256 sidecar'
fi

[ "${#expected}" -eq 64 ] || fail 'checksum must contain exactly 64 hexadecimal characters'
case "$expected" in *[!a-fA-F0-9]*) fail 'checksum must contain exactly 64 hexadecimal characters' ;; esac
expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
printf 'Fetching %s using %s\n' "$version" "$checksum_source"
curl --fail --show-error --location --retry 5 --proto '=https' --tlsv1.2 \
    "$release_url/$archive" --output "$work_dir/source.tar.gz"
actual=$(sha256sum "$work_dir/source.tar.gz")
actual=${actual%% *}
[ "$actual" = "$expected" ] || fail "archive checksum mismatch for $version"
mv "$work_dir/source.tar.gz" "$output"
printf 'Verified %s SHA256 %s\n' "$version" "$expected"
