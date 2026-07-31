import contextlib
import io
import importlib.util
import pathlib
import subprocess
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
UPDATE_PATH = ROOT / "scripts" / "update.py"


def load_update_module():
    spec = importlib.util.spec_from_file_location("herdr_block_sleep_update", UPDATE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class UpdateScriptTests(unittest.TestCase):
    def setUp(self):
        self.update = load_update_module()

    def test_next_link_returns_next_relation_url(self):
        header = '<https://api.example.test/page/1>; rel="prev", <https://api.example.test/page/3>; rel="next"'

        self.assertEqual(self.update.next_link(header), "https://api.example.test/page/3")

    def test_next_link_returns_none_without_next_relation(self):
        self.assertIsNone(self.update.next_link('<https://api.example.test/page/1>; rel="prev"'))

    def test_tags_url_encodes_owner_and_repo(self):
        self.update.GITHUB_API = "https://api.example.test"

        self.assertEqual(
            self.update.tags_url("owner name/repo.name"),
            "https://api.example.test/repos/owner%20name/repo.name/tags?per_page=100",
        )

    def test_tags_url_rejects_invalid_repo_format(self):
        with self.assertRaisesRegex(RuntimeError, "REPO must be owner/name"):
            self.update.tags_url("owner/repo/subdir")

    def test_latest_release_tag_selects_highest_semver_across_pages(self):
        responses = {
            "https://api.example.test/repos/marvelm/herdr-block-sleep/tags?per_page=100": (
                [{"name": "v0.1.0"}, {"name": "not-a-release"}],
                '<https://api.example.test/page/2>; rel="next"',
            ),
            "https://api.example.test/page/2": (
                [{"name": "v0.2.0"}, {"name": "v0.1.9"}],
                "",
            ),
        }
        self.update.GITHUB_API = "https://api.example.test"

        with mock.patch.object(self.update, "fetch_json", side_effect=lambda url: responses[url]):
            self.assertEqual(self.update.latest_release_tag("marvelm/herdr-block-sleep"), "v0.2.0")

    def test_latest_release_tag_rejects_empty_semver_set(self):
        self.update.GITHUB_API = "https://api.example.test"

        with mock.patch.object(self.update, "fetch_json", return_value=([{"name": "latest"}], "")):
            with self.assertRaisesRegex(RuntimeError, "no SemVer release tags"):
                self.update.latest_release_tag("marvelm/herdr-block-sleep")

    def test_run_herdr_raises_for_required_failure(self):
        self.update.HERDR_BIN = "herdr-test"

        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(["herdr-test"], 7)):
            with self.assertRaisesRegex(RuntimeError, "herdr-test plugin list exited 7"):
                self.update.run_herdr(["plugin", "list"])

    def test_run_herdr_allows_optional_failure(self):
        self.update.HERDR_BIN = "herdr-test"

        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(["herdr-test"], 7)):
            self.assertEqual(self.update.run_herdr(["plugin", "list"], required=False), 7)

    def test_main_runs_update_sequence_with_latest_tag(self):
        self.update.PLUGIN_ID = "dev.herdr-block-sleep"
        self.update.REPO = "marvelm/herdr-block-sleep"
        calls = []

        def fake_run_herdr(args, required=True):
            calls.append((args, required))
            return 0

        with contextlib.redirect_stdout(io.StringIO()), \
             mock.patch.object(self.update, "latest_release_tag", return_value="v1.2.3"), \
             mock.patch.object(self.update, "run_herdr", side_effect=fake_run_herdr):
            self.assertEqual(self.update.main(), 0)

        self.assertEqual(
            calls,
            [
                (["plugin", "action", "invoke", "stop", "--plugin", "dev.herdr-block-sleep"], False),
                (["plugin", "uninstall", "dev.herdr-block-sleep"], True),
                (["plugin", "install", "marvelm/herdr-block-sleep", "--ref", "v1.2.3", "--yes"], True),
                (["plugin", "action", "invoke", "start", "--plugin", "dev.herdr-block-sleep"], True),
            ],
        )


if __name__ == "__main__":
    unittest.main()
