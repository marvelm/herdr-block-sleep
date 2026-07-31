import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT = shutil.which("swift")


@unittest.skipUnless(SWIFT, "swift is required for binary tests")
class SwiftBinaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._build_dir = tempfile.TemporaryDirectory()
        scratch = pathlib.Path(cls._build_dir.name) / ".build"
        subprocess.run(
            [
                SWIFT,
                "build",
                "--package-path",
                str(ROOT),
                "--scratch-path",
                str(scratch),
                "--product",
                "herdr-block-sleep",
            ],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        cls.binary = scratch / "debug" / "herdr-block-sleep"

    @classmethod
    def tearDownClass(cls):
        cls._build_dir.cleanup()

    def binary_env(self, state_dir, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "HERDR_PLUGIN_STATE_DIR": str(state_dir),
                "HERDR_SOCKET_PATH": str(state_dir / "missing-herdr.sock"),
                "HERDR_BLOCK_SLEEP_LID_CHECK_SECONDS": "1",
                "HERDR_BLOCK_SLEEP_RECONCILE_SECONDS": "1",
                "HERDR_BLOCK_SLEEP_MAX_FAILURES": "20",
            }
        )
        env.update(overrides)
        return env

    def run_binary(self, args, env, timeout=10):
        return subprocess.run(
            [str(self.binary)] + args,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )

    def test_help_prints_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_binary(["help"], self.binary_env(pathlib.Path(directory)))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "usage: herdr-block-sleep [start|stop|status|daemon]")

    def test_unknown_command_prints_usage_and_exits_two(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_binary(["not-a-command"], self.binary_env(pathlib.Path(directory)))

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout.strip(), "usage: herdr-block-sleep [start|stop|status|daemon]")

    def test_status_without_state_reports_stopped_and_unknown_assertion(self):
        with tempfile.TemporaryDirectory() as directory:
            state_dir = pathlib.Path(directory)
            result = self.run_binary(["status"], self.binary_env(state_dir))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("daemon: stopped\n", result.stdout)
        self.assertIn("native_assertion: unknown\n", result.stdout)
        self.assertIn("status: no status file yet\n", result.stdout)

    def test_start_status_stop_uses_isolated_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state_dir = pathlib.Path(directory)
            fake_herdr = state_dir / "herdr"
            fake_herdr.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import json
                    import sys

                    if sys.argv[1:] == ["agent", "list"]:
                        print(json.dumps({"result": {"agents": []}}))
                        raise SystemExit(0)
                    raise SystemExit(2)
                    """
                )
            )
            fake_herdr.chmod(fake_herdr.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            env = self.binary_env(state_dir, HERDR_BIN=str(fake_herdr))

            start = self.run_binary(["start"], env)
            self.assertEqual(start.returncode, 0, start.stderr)
            self.assertIn("block-sleep native monitor started: pid", start.stdout)

            try:
                status_path = state_dir / "status.json"
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and not status_path.exists():
                    time.sleep(0.05)
                self.assertTrue(status_path.exists(), "daemon did not write status.json")

                status = self.run_binary(["status"], env)
                self.assertEqual(status.returncode, 0, status.stderr)
                self.assertIn("daemon: running pid", status.stdout)
                self.assertIn("native_assertion: inactive", status.stdout)
                self.assertIn("log: {}".format(state_dir / "block-sleep.log"), status.stdout)

                with status_path.open() as handle:
                    payload = json.load(handle)
                self.assertEqual(payload["log"], str(state_dir / "block-sleep.log"))
                self.assertFalse(payload["assertion_active"])
            finally:
                stop = self.run_binary(["stop"], env)
                self.assertEqual(stop.returncode, 0, stop.stderr)
                self.assertRegex(stop.stdout, r"block-sleep (native monitor stopped|monitor was not running)")


if __name__ == "__main__":
    unittest.main()
