#!/usr/bin/env python3
"""bezaforge-git-mirror-sync — managed by Ansible role: git-mirror-sync

Copies each repository's main branch from GitHub to GitLab and Gitea, every
five minutes (bezaforge-git-mirror-sync.timer).

WHY THIS EXISTS
---------------
Every repository is pushed to three places at once, GitHub, GitLab and
Gitea, through one remote with three push URLs. A merge made from a laptop
reaches all three, because `git land` pushes main to each after it merges.
A merge made anywhere else, such as GitHub's app on a phone or a website's
writing editor, lands on GitHub alone, and Gitea, inside the home network,
can't be reached from outside to be told. This makes the copy from inside.

WHAT IT DOES
  For each owner in the config, it lists the owner's repositories on Gitea
  (every mirrored repository has one), and for each:

  - reads main on GitHub; a repository not on GitHub, or with no main, is
    skipped and said so in the journal
  - reads main on GitLab and on Gitea, and where either differs, fetches
    GitHub's into a local bare copy and pushes it there

  It never forces a push. A mirror holding a commit GitHub doesn't is
  refused by the mirror itself, reported, and left for a person to settle;
  nothing on it is overwritten. Only main moves: branches and tags stay as
  `git land` and `git prune-branch` leave them.

  It exits non-zero when anything fails, so systemd records a failed unit
  and the failed-unit alert fires once that has lasted 15 minutes (three
  runs), which a passing network blip doesn't.

CONFIG
  A JSON file passed by systemd as the credential `config` (LoadCredential=),
  rendered by the role from vaulted values:

    {"branch": "main",
     "gitea_url": "https://...", "gitea_user": "...", "gitea_token": "...",
     "gitlab_url": "https://gitlab.com", "gitlab_token": "...",
     "github_url": "https://github.com",
     "owners": [{"github": "...", "github_token": "...",
                 "gitlab": "...", "gitea": "..."}]}

  Tokens travel to git in its environment (GIT_CONFIG_*), never in its
  arguments, which any user on the host can read.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ATTEMPTS = 3
PAUSE = 10  # seconds between attempts


class Failure(Exception):
    pass


def basic(user: str, password: str) -> str:
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


def git(args: list[str], url: str, auth: str, cwd: Path | None = None) -> str:
    """Run git against one remote URL, with that remote's credentials.

    Retried, because a run every five minutes meets the odd network blip.
    """
    env = {
        **os.environ,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": f"http.{url}.extraHeader",
        "GIT_CONFIG_VALUE_0": f"Authorization: {auth}",
    }
    for attempt in range(1, ATTEMPTS + 1):
        result = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout
        # A refused push is an answer, not a blip: asking again won't change it.
        if "rejected" in result.stderr:
            raise Failure("refused: the mirror has commits GitHub doesn't; settle it by hand")
        if attempt == ATTEMPTS:
            lines = [l.strip() for l in result.stderr.splitlines() if l.strip() and not l.startswith("hint:")]
            fatal = [l for l in lines if l.startswith(("fatal:", "error:", "remote:"))]
            raise Failure((fatal or lines or [f"git exited {result.returncode}"])[0])
        time.sleep(PAUSE)
    raise AssertionError("unreachable")


def head(url: str, auth: str, branch: str) -> str | None:
    """The commit a remote's branch points at, or None if it has none."""
    out = git(["ls-remote", "--heads", url, f"refs/heads/{branch}"], url, auth)
    return out.split()[0] if out.strip() else None


def gitea_repos(config: dict, owner: str) -> list[str]:
    """The owner's repositories on Gitea, less Gitea's own pull mirrors and
    the archived, which can't be pushed to."""
    names, page = [], 1
    while True:
        query = urllib.parse.urlencode({"page": page, "limit": 50})
        batch = None
        for kind in ("orgs", "users"):
            request = urllib.request.Request(
                f"{config['gitea_url']}/api/v1/{kind}/{owner}/repos?{query}",
                headers={"Authorization": f"token {config['gitea_token']}"},
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    batch = json.load(response)
                break
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    raise Failure(f"Gitea: listing {owner}'s repositories: HTTP {e.code}") from e
        if batch is None:
            raise Failure(f"Gitea has no user or organization {owner}")
        if not batch:
            return names
        names += [r["name"] for r in batch if not r.get("mirror") and not r.get("archived") and not r.get("empty")]
        page += 1


def sync(config: dict, owner: dict, repo: str, cache: Path) -> tuple[bool, list[str]]:
    """Bring one repository's mirrors up to GitHub's main. Returns whether
    GitHub answered for it, and the failures."""
    branch = config["branch"]
    source = (f"{config['github_url']}/{owner['github']}/{repo}.git", basic("x-access-token", owner["github_token"]))
    mirrors = {
        "GitLab": (f"{config['gitlab_url']}/{owner['gitlab']}/{repo}.git", basic("oauth2", config["gitlab_token"])),
        "Gitea": (f"{config['gitea_url']}/{owner['gitea']}/{repo}.git", basic(config["gitea_user"], config["gitea_token"])),
    }
    name = f"{owner['github']}/{repo}"

    try:
        wanted = head(*source, branch)
    except Failure:
        print(f"skip {name}: not on GitHub, or the token can't see it")
        return False, []
    if wanted is None:
        print(f"skip {name}: no {branch} on GitHub")
        return True, []

    failures, fetched = [], False
    for mirror, (url, auth) in mirrors.items():
        try:
            # GitLab makes a private project on a first push, so a missing
            # one isn't an error, just a mirror with nothing on it yet.
            try:
                have = head(url, auth, branch)
            except Failure:
                have = None
            if have == wanted:
                continue
            if not fetched:
                local = cache / owner["github"] / f"{repo}.git"
                if not local.exists():
                    local.mkdir(parents=True)
                    subprocess.run(["git", "init", "--quiet", "--bare"], cwd=local, check=True)
                git(["fetch", "--quiet", source[0], f"+refs/heads/{branch}:refs/heads/{branch}"], *source, cwd=local)
                fetched = True
            git(["push", "--quiet", url, f"refs/heads/{branch}:refs/heads/{branch}"], url, auth, cwd=local)
            print(f"sync {name}: {mirror} {(have or 'nothing')[:12]} -> {wanted[:12]}")
        except Failure as e:
            failures.append(f"{name} to {mirror}: {e}")
    return True, failures


def main() -> int:
    credentials = os.environ.get("CREDENTIALS_DIRECTORY")
    if not credentials:
        print("no CREDENTIALS_DIRECTORY: run this through its systemd unit", file=sys.stderr)
        return 2
    config = {"branch": "main", "github_url": "https://github.com", **json.loads(Path(credentials, "config").read_text())}
    cache = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/bezaforge-git-mirror-sync"))

    failures, checked = [], 0
    for owner in config["owners"]:
        try:
            repos = gitea_repos(config, owner["gitea"])
        except (Failure, urllib.error.URLError) as e:
            failures.append(f"{owner['gitea']}: {e}")
            continue
        answered = 0
        for repo in repos:
            checked += 1
            seen, found = sync(config, owner, repo, cache)
            answered += seen
            failures += found
        # One repository missing from GitHub is a repository kept on Gitea
        # alone. All of them missing is a token that has expired or lost
        # its access, which would otherwise pass quietly as skips.
        if repos and not answered:
            failures.append(f"{owner['github']}: GitHub answered for none of {len(repos)} repositories; check its token")

    for f in failures:
        print(f"FAIL {f}", file=sys.stderr)
    print(f"{checked} repositories checked, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
