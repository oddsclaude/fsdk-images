"""Regression checks for atomic BuildStream Renovate metadata."""

from pathlib import Path
import json
import re
import unittest


ROOT = Path(__file__).parents[1]


def _manager(config, marker):
    return next(m for m in config["customManagers"] if marker in m["datasourceTemplate"])


class RenovateAtomicTests(unittest.TestCase):
    def test_pypi_manager_must_not_exist(self):
        # The pypi datasource does not provide digests, so a pypi-based regex
        # manager can never compute the new sha256 for the plugin tar elements.
        # Those elements are intentionally left to manual bumping.
        config = json.loads((ROOT / "renovate.json").read_text())
        self.assertEqual(
            [m["datasourceTemplate"] for m in config["customManagers"]].count("pypi"),
            0,
        )
        for element in ["buildstream-plugins.bst", "buildstream-plugins-community.bst"]:
            text = (ROOT / "elements" / "plugins" / element).read_text()
            self.assertNotIn("# renovate:", text)

    def test_git_refs_manager_requires_explicit_annotation(self):
        config = json.loads((ROOT / "renovate.json").read_text())
        manager = _manager(config, "git-refs")
        self.assertEqual(manager["datasourceTemplate"], "git-refs")
        self.assertIn("# renovate:", manager["matchStrings"][0])
        self.assertIn("(?<currentDigest>[0-9a-f]{40})", manager["matchStrings"][0])

        # The FSDK junction has no annotation and must NOT match: it is managed
        # by the auto-update-fsdk workflow, never by Renovate.
        pattern = re.compile(
            manager["matchStrings"][0].replace("(?<", "(?P<")
        )
        fsdk = (ROOT / "elements" / "freedesktop-sdk.bst").read_text()
        self.assertIsNone(pattern.search(fsdk))

    def test_unmanaged_sources_have_no_renovate_annotation(self):
        for path in (ROOT / "elements").rglob("*.bst"):
            text = path.read_text()
            if "kind: remote" in text and "# renovate:" in text:
                self.fail(
                    f"archive/remote source must not use generic Renovate metadata: {path}"
                )

    def test_managers_are_scoped(self):
        config = json.loads((ROOT / "renovate.json").read_text())
        self.assertEqual(config["enabledManagers"], ["github-actions", "custom.regex"])
        self.assertEqual(len(config["customManagers"]), 1)
        self.assertEqual(config["customManagers"][0]["datasourceTemplate"], "git-refs")


if __name__ == "__main__":
    unittest.main()
