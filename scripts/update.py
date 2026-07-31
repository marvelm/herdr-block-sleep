#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


PLUGIN_ID = os.environ.get("PLUGIN_ID", "dev.herdr-block-sleep")
REPO = os.environ.get("REPO", "marvelm/herdr-block-sleep")
HERDR_BIN = os.environ.get("HERDR_BIN", "herdr")
GITHUB_API = os.environ.get("GITHUB_API", "https://api.github.com").rstrip("/")
TAG_PATTERN = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$")


def github_headers():
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "herdr-block-sleep-updater",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    return headers


def fetch_json(url):
    request = Request(url, headers=github_headers())
    try:
        with urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8")
            return json.loads(payload), response.headers.get("Link", "")
    except HTTPError as error:
        raise RuntimeError("GitHub request failed: HTTP {} {}".format(error.code, url))
    except URLError as error:
        raise RuntimeError("GitHub request failed: {} {}".format(error.reason, url))


def next_link(link_header):
    for part in link_header.split(","):
        section = part.strip()
        if 'rel="next"' not in section:
            continue
        start = section.find("<")
        end = section.find(">")
        if start != -1 and end != -1 and start < end:
            return section[start + 1:end]
    return None


def tags_url(repo):
    pieces = repo.split("/")
    if len(pieces) != 2 or not all(pieces):
        raise RuntimeError("REPO must be owner/name, got {!r}".format(repo))
    owner = quote(pieces[0], safe="")
    name = quote(pieces[1], safe="")
    return "{}/repos/{}/{}/tags?per_page=100".format(GITHUB_API, owner, name)


def latest_release_tag(repo):
    candidates = []
    url = tags_url(repo)
    while url:
        tags, link_header = fetch_json(url)
        if not isinstance(tags, list):
            raise RuntimeError("GitHub tags response was not a list")
        for item in tags:
            tag = item.get("name") if isinstance(item, dict) else None
            if not tag:
                continue
            match = TAG_PATTERN.match(tag)
            if match:
                version = tuple(int(part) for part in match.groups())
                candidates.append((version, tag))
        url = next_link(link_header)

    if not candidates:
        raise RuntimeError("no SemVer release tags found for {}".format(repo))
    return max(candidates)[1]


def run_herdr(args, required=True):
    command = [HERDR_BIN] + args
    result = subprocess.run(command)
    if required and result.returncode != 0:
        raise RuntimeError("{} exited {}".format(" ".join(command), result.returncode))
    return result.returncode


def main():
    try:
        tag = latest_release_tag(REPO)
        print("Updating {} from {} release {}".format(PLUGIN_ID, REPO, tag))

        stop_code = run_herdr(["plugin", "action", "invoke", "stop", "--plugin", PLUGIN_ID], required=False)
        if stop_code != 0:
            print("warning: stop action failed; continuing with reinstall", file=sys.stderr)

        run_herdr(["plugin", "uninstall", PLUGIN_ID])
        run_herdr(["plugin", "install", REPO, "--ref", tag, "--yes"])
        run_herdr(["plugin", "action", "invoke", "start", "--plugin", PLUGIN_ID])

        print("Updated {} to {}".format(PLUGIN_ID, tag))
    except RuntimeError as error:
        print("error: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
