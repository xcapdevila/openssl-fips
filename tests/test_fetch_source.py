"""Offline checks for release selection and source checksum enforcement."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


FETCH_SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "fetch-source.sh"
ARCHIVE = b"public source archive fixture\n"
ARCHIVE_SHA256 = hashlib.sha256(ARCHIVE).hexdigest()
PINNED_RELEASES = {
    "openssl-3.1.2": "a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539",
    "openssl-3.5.9": "603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a",
}

CURL_FIXTURE = r'''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith("https://"))
with open(os.environ["MOCK_CURL_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if os.environ.get("MOCK_CURL_FAIL_SUFFIX") and url.endswith(os.environ["MOCK_CURL_FAIL_SUFFIX"]):
    sys.exit(22)
output = Path(args[args.index("--output") + 1])
if url.endswith(".sha256"):
    output.write_text(os.environ["MOCK_SIDECAR"])
else:
    output.write_bytes(bytes.fromhex(os.environ["MOCK_ARCHIVE_HEX"]))
'''

SHA256_FIXTURE = r'''
import hashlib
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
checksum = os.environ.get("MOCK_SHA256") or hashlib.sha256(path.read_bytes()).hexdigest()
print(checksum + "  " + str(path))
'''


class FetchSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openssl-fetch-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.output = self.directory / "source.tar.gz"
        self.log = self.directory / "curl.jsonl"
        for name, fixture in (("curl", CURL_FIXTURE), ("sha256sum", SHA256_FIXTURE)):
            command = self.bin / name
            command.write_text("#!" + sys.executable + "\n" + fixture)
            command.chmod(0o755)

    def invoke(self, version="openssl-4.1.0", checksum="", **environment):
        self.log.unlink(missing_ok=True)
        self.output.unlink(missing_ok=True)
        env = os.environ.copy()
        env.update({
            "PATH": str(self.bin) + os.pathsep + env.get("PATH", ""),
            "MOCK_CURL_LOG": str(self.log),
            "MOCK_ARCHIVE_HEX": ARCHIVE.hex(),
            "MOCK_SIDECAR": ARCHIVE_SHA256 + "\n",
            "TMPDIR": str(self.directory),
        })
        env.update(environment)
        return subprocess.run(
            ["/bin/sh", str(FETCH_SOURCE), version, checksum, str(self.output)],
            env=env, text=True, capture_output=True, check=False,
        )

    def requests(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def urls(self):
        return [next(arg for arg in request if arg.startswith("https://"))
                for request in self.requests()]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output.read_bytes(), ARCHIVE)
        for request in self.requests():
            self.assertIn("--fail", request)
            self.assertIn("--tlsv1.2", request)
            self.assertEqual(request[request.index("--proto") + 1], "=https")
            self.assertNotIn("--insecure", request)

    def assert_failure(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.output.exists(), "unverified archive was published")

    def test_default_releases_use_their_pinned_checksums(self):
        # The hash tool fixture supplies each real release's recorded digest;
        # alternate-release tests below hash the downloaded fixture bytes.
        for version, checksum in PINNED_RELEASES.items():
            with self.subTest(version=version):
                result = self.invoke(version, MOCK_SHA256=checksum, MOCK_SIDECAR="invalid")
                self.assert_success(result)
                self.assertIn("pinned release checksum", result.stdout)
                self.assertIn("Verified " + version + " SHA256 " + checksum, result.stdout)
                self.assertEqual(self.urls(), [
                    f"https://github.com/openssl/openssl/releases/download/{version}/{version}.tar.gz"
                ])

    def test_alternate_release_accepts_a_bare_hash_sidecar(self):
        result = self.invoke("openssl-4.1.0", MOCK_SIDECAR=" \n " + ARCHIVE_SHA256 + " \n\n")
        self.assert_success(result)
        self.assertIn("official HTTPS checksum sidecar", result.stdout)
        self.assertEqual(self.urls(), [
            "https://github.com/openssl/openssl/releases/download/openssl-4.1.0/openssl-4.1.0.tar.gz.sha256",
            "https://github.com/openssl/openssl/releases/download/openssl-4.1.0/openssl-4.1.0.tar.gz",
        ])

    def test_alternate_release_accepts_hash_and_filename_sidecars(self):
        for marker in ("", "*"):
            with self.subTest(marker=marker):
                result = self.invoke("openssl-3.0.9", MOCK_SIDECAR=(
                    ARCHIVE_SHA256 + "  " + marker + "openssl-3.0.9.tar.gz\n"
                ))
                self.assert_success(result)

    def test_uppercase_sidecar_hash_is_normalized(self):
        self.assert_success(self.invoke(MOCK_SIDECAR=ARCHIVE_SHA256.upper() + "\n"))

    def test_explicit_checksum_overrides_pinned_and_automatic_checksums(self):
        for version in ("openssl-3.5.9", "openssl-4.1.0"):
            with self.subTest(version=version):
                result = self.invoke(version, ARCHIVE_SHA256.upper(), MOCK_SIDECAR="invalid")
                self.assert_success(result)
                self.assertIn("explicit checksum", result.stdout)
                self.assertEqual(len(self.urls()), 1)
                self.assertFalse(self.urls()[0].endswith(".sha256"))

    def test_wrong_explicit_checksum_fails_without_fallback(self):
        result = self.invoke("openssl-3.5.9", "0" * 64)
        self.assert_failure(result)
        self.assertIn("archive checksum mismatch", result.stderr)
        self.assertEqual(len(self.urls()), 1)

    def test_wrong_automatic_checksum_fails(self):
        self.assert_failure(self.invoke(MOCK_SIDECAR="0" * 64 + "\n"))

    def test_invalid_explicit_checksums_fail_before_download(self):
        for checksum in ("abc", "g" * 64, "a" * 63, "a" * 65, "a" * 63 + "\n"):
            with self.subTest(checksum=checksum):
                self.assert_failure(self.invoke(checksum=checksum))
                self.assertEqual(self.requests(), [])

    def test_invalid_sidecars_fail_before_archive_download(self):
        malformed = (
            "", " \n", "not-a-checksum\n", "a" * 63 + "\n", "g" * 64 + "\n",
            ARCHIVE_SHA256 + " *different.tar.gz\n",
            ARCHIVE_SHA256 + " openssl-4.1.0.tar.gz extra\n",
            ARCHIVE_SHA256 + "\n" + ARCHIVE_SHA256 + "\n",
            "$(echo invalid)\n",
        )
        for sidecar in malformed:
            with self.subTest(sidecar=sidecar):
                result = self.invoke(MOCK_SIDECAR=sidecar)
                self.assert_failure(result)
                self.assertIn("invalid official SHA256 sidecar", result.stderr)
                self.assertEqual(len(self.urls()), 1)
                self.assertTrue(self.urls()[0].endswith(".sha256"))

    def test_invalid_or_unsupported_versions_fail_before_network_access(self):
        for version in (
            "openssl-2.0.0", "openssl-1.1.1", "openssl-03.5.9", "3.5.9",
            "openssl-3.5", "openssl-3.5.9-rc1", "openssl-3.5.9;echo invalid",
            "openssl-4.1.0\ninvalid", "../openssl-4.1.0", "https://example.com/source",
        ):
            with self.subTest(version=version):
                self.assert_failure(self.invoke(version))
                self.assertEqual(self.requests(), [])

    def test_sidecar_http_failure_does_not_publish_an_archive(self):
        self.assert_failure(self.invoke(MOCK_CURL_FAIL_SUFFIX=".sha256"))
        self.assertEqual(len(self.urls()), 1)

    def test_archive_http_failure_does_not_publish_an_archive(self):
        self.assert_failure(self.invoke(checksum=ARCHIVE_SHA256, MOCK_CURL_FAIL_SUFFIX=".tar.gz"))


if __name__ == "__main__":
    unittest.main()
