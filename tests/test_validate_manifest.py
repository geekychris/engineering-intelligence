from __future__ import annotations

from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
import importlib.util
import json
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "validate_manifest.py"
SPEC = importlib.util.spec_from_file_location("validate_manifest", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
validate_manifest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validate_manifest)


class ManifestValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = TemporaryDirectory()
        self.build_dir = Path(self.temp_dir.name)
        (self.build_dir / "figures" / "mermaid").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_artifact(self, name: str, content: bytes) -> dict[str, object]:
        path = self.build_dir / name
        path.write_bytes(content)
        return {
            "name": name,
            "bytes": len(content),
            "sha256": sha256(content).hexdigest(),
        }

    def write_manifest(
        self,
        *,
        mode: str,
        files: list[dict[str, object]],
        diagram_count: int = 0,
        publication_time: str = "2026-07-16T12:00:00+00:00",
        source_date_epoch: int = 1784203200,
        source_commit: str = "a" * 40,
    ) -> None:
        manifest = {
            "schema_version": 1,
            "title": "Engineering Intelligence",
            "build_mode": mode,
            "publication_time": publication_time,
            "source_date_epoch": source_date_epoch,
            "source_commit": source_commit,
            "files": files,
            "diagram_count": diagram_count,
        }
        (self.build_dir / "manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )

    def test_valid_html_manifest(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(mode="html", files=[artifact])

        self.assertEqual(validate_manifest.validate(self.build_dir), 0)

    def test_valid_expected_source_commit(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        expected_commit = "a" * 40
        self.write_manifest(
            mode="html", files=[artifact], source_commit=expected_commit
        )

        self.assertEqual(
            validate_manifest.validate(self.build_dir, expected_commit), 0
        )

    def test_valid_equivalent_non_utc_timestamp(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(
            mode="html",
            files=[artifact],
            publication_time="2026-07-16T05:00:00-07:00",
        )

        self.assertEqual(validate_manifest.validate(self.build_dir), 0)

    def test_valid_full_manifest_with_diagram(self) -> None:
        html = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        pdf = self.write_artifact("engineering-intelligence.pdf", b"%PDF-test")
        (self.build_dir / "figures" / "mermaid" / "system.png").write_bytes(
            b"\x89PNG\r\n\x1a\n"
        )
        self.write_manifest(mode="validate", files=[html, pdf], diagram_count=1)

        self.assertEqual(validate_manifest.validate(self.build_dir), 0)

    def test_rejects_hash_mismatch(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"original")
        artifact["sha256"] = "0" * 64
        self.write_manifest(mode="html", files=[artifact])

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_missing_expected_artifact(self) -> None:
        html = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(mode="all", files=[html])

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_diagram_count_mismatch(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        (self.build_dir / "figures" / "mermaid" / "one.png").write_bytes(
            b"\x89PNG\r\n\x1a\n"
        )
        self.write_manifest(mode="html", files=[artifact], diagram_count=0)

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_artifact_paths(self) -> None:
        nested = self.build_dir / "nested"
        nested.mkdir()
        content = b"unsafe"
        (nested / "engineering-intelligence.html").write_bytes(content)
        artifact = {
            "name": "nested/engineering-intelligence.html",
            "bytes": len(content),
            "sha256": sha256(content).hexdigest(),
        }
        self.write_manifest(mode="html", files=[artifact])

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_invalid_publication_time(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(
            mode="html", files=[artifact], publication_time="not-a-timestamp"
        )

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_publication_time_without_timezone(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(
            mode="html",
            files=[artifact],
            publication_time="2026-07-16T12:00:00",
        )

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_timestamp_epoch_mismatch(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(
            mode="html",
            files=[artifact],
            publication_time="2026-07-16T12:00:01+00:00",
        )

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_unexpected_source_commit(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(mode="html", files=[artifact], source_commit="a" * 40)

        self.assertEqual(
            validate_manifest.validate(self.build_dir, "b" * 40), 1
        )

    def test_rejects_abbreviated_source_commit(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(mode="html", files=[artifact], source_commit="abc1234")

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)

    def test_rejects_non_hex_source_commit(self) -> None:
        artifact = self.write_artifact("engineering-intelligence.html", b"<html></html>")
        self.write_manifest(mode="html", files=[artifact], source_commit="z" * 40)

        self.assertEqual(validate_manifest.validate(self.build_dir), 1)


if __name__ == "__main__":
    unittest.main()
