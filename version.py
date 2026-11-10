#!/usr/bin/env python3
# (C) 2012-2013 see Authors.txt
#
# This file is part of MPC-HC.
#
# MPC-HC is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# MPC-HC is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SVN_REVISION = 760
SVN_COMMIT = "0cd53aab71b006820233224bbf14c2b18b2caca6"


def git(*args, check=True):
    return subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, check=check
    )


def revision_at(commit):
    count = git("rev-list", "--count", f"{SVN_COMMIT}..{commit}").stdout
    return SVN_REVISION + int(count)


def write_if_changed(path, content):
    if not path.is_file() or path.read_bytes() != content:
        path.write_bytes(content)


def main():
    revision = 0
    commit_hash = b"0000000"
    branch_info = b""
    definitions = []
    modified = False
    merge_base = b""

    if shutil.which("git") and git("rev-parse", "--git-dir", check=False).returncode == 0:
        ref = git("symbolic-ref", "-q", "HEAD", check=False).stdout.rstrip(b"\n")
        branch = ref.removeprefix(b"refs/heads/") or b"no branch"
        print("On branch:", branch.decode("utf-8", errors="replace"))
        if branch != b"master":
            escaped_branch = branch.replace(b'"', b'\\"')
            definitions.append(b'#define BRANCH _T("%s")' % escaped_branch)
            branch_info = b" (%s)" % escaped_branch
            master_ref = git(
                "show-ref", "--verify", "--quiet", "refs/heads/master", check=False
            )
            if master_ref.returncode == 0:
                merge_base = git("merge-base", "master", "HEAD").stdout.strip()
                base_revision = revision_at(merge_base.decode("ascii"))
                branch_info += b" (master@%s)" % str(base_revision).encode("ascii")[:7]

        revision = revision_at("HEAD")
        commit_hash = git("rev-parse", "--short", "HEAD").stdout.strip()
        modified = git("diff-index", "--quiet", "HEAD", check=False).returncode != 0

    print("Hash:     ", commit_hash.decode("ascii"))
    print(f"Revision:  {revision}" + (" (Local modifications found)" if modified else ""))
    if merge_base:
        print(f"Mergebase: master@{base_revision} ({merge_base[:7].decode('ascii')})")

    definitions.extend([
        b'#define VERSION_HASH _T("%s")' % commit_hash,
        b"#define VERSION_REV %d" % revision,
        b'#define VERSION_REV_FULL _T("%d (%s)%s")' % (revision, commit_hash, branch_info),
    ])
    manifest = ROOT / "res" / "Notepad2.exe.manifest"
    template = manifest.with_suffix(".manifest.conf").read_bytes()
    revision_text = str(revision).encode("ascii")
    manifest_content = b"".join(
        line.replace(b"$WCREV$", revision_text, 1)
        for line in template.splitlines(keepends=True)
    )
    write_if_changed(ROOT / "src" / "VersionRev.h", b"\n".join(definitions) + b"\n")
    write_if_changed(manifest, manifest_content.rstrip(b"\n") + b"\n")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stderr.decode("utf-8", errors="replace").strip() or error, file=sys.stderr)
        sys.exit(1)
