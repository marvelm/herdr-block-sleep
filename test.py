#!/usr/bin/env python3
import subprocess
import sys


def run(command):
    print("+ " + " ".join(command), flush=True)
    subprocess.run(command, check=True)


def main():
    checks = [
        ["swift", "test"],
        [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"],
        ["swift", "build", "-c", "release", "--product", "herdr-block-sleep"],
    ]

    for check in checks:
        run(check)

    print("all release checks passed")


if __name__ == "__main__":
    main()
