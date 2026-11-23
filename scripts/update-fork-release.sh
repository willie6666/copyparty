#!/bin/bash
set -euo pipefail

upstream=9001/copyparty
fork=willie6666/copyparty
branch=codex/public-share-paths
asset_name=copyparty-sfx.py

usage() {
    cat <<'EOF'
Usage: update-fork-release.sh [--resume WORK_DIR]
       update-fork-release.sh --build-only OUTPUT [--resume WORK_DIR]
       update-fork-release.sh --deploy-file PATH [--resume WORK_DIR] -- RESTART [ARGS...]

Merge the latest upstream release into the fork's public-share branch, test
and build the SFX, then publish it to the fork. Use --build-only to save the
tested SFX locally. On the server, --deploy-file replaces an existing SFX and
runs the supplied restart command. Use --resume with the workspace printed
after a failure, committing any merge conflict resolutions first.

Requires git, an authenticated gh, Python 3 with venv, and the SFX build
tools listed in docs/devnotes.md.
EOF
}

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

build_output=
deploy_file=
resume=
has_restart=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --build-only|--deploy-file|--resume)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a path"
            case "$1" in
                --build-only) build_output=$2 ;;
                --deploy-file) deploy_file=$2 ;;
                --resume) resume=$2 ;;
            esac
            shift 2
            ;;
        --)
            shift
            [ "$#" -gt 0 ] || die 'Supply a restart command after --'
            restart=("$@")
            has_restart=1
            break
            ;;
        *) die "Unknown argument $1. Run with --help for usage." ;;
    esac
done

if [ -n "$deploy_file" ]; then
    [ "$has_restart" = 1 ] || die '--deploy-file requires a restart command after --'
    [ -z "$build_output" ] || die '--deploy-file and --build-only are separate modes'
    [ -f "$deploy_file" ] || die "Deployment file does not exist at $deploy_file"
elif [ "$has_restart" = 1 ]; then
    die 'A restart command requires --deploy-file'
fi

for tool in git gh python3; do
    command -v "$tool" >/dev/null || die "Install $tool before running this script"
done

git_fork() {
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
        -c 'credential.helper=!gh auth git-credential' "$@"
}

sha256() {
    python3 -I -S -c 'import hashlib, pathlib, sys; print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())' "$1"
}

merge_into_fork() {
    if git -C "$source_dir" merge --no-edit "$1"; then
        return
    fi
    if git -C "$source_dir" rev-parse --verify -q MERGE_HEAD >/dev/null; then
        printf 'Resolve the merge in %s and run git merge --continue there.\n' "$source_dir" >&2
        die "Then rerun this script with --resume '$work_dir' and the original options."
    fi
    die "Unable to merge $1. See the Git error above."
}

if [ -n "$resume" ]; then
    work_dir=$(cd "$resume" && pwd -P) || die "Updater workspace not found at $resume"
    [ -f "$work_dir/upstream-tag" ] || die "Updater workspace not found at $work_dir"
    upstream_tag=$(cat "$work_dir/upstream-tag")
else
    upstream_tag=$(gh release view --repo "github.com/$upstream" --json tagName --jq .tagName)
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/copyparty-release.XXXXXXXX")
fi

deploy_tmp=
cleanup() {
    local result=$?
    if [ -n "$deploy_tmp" ]; then
        rm -f -- "$deploy_tmp"
    fi
    if [ "$result" -ne 0 ]; then
        printf 'Workspace and logs saved at %s\n' "$work_dir" >&2
    elif [ -z "$resume" ]; then
        rm -rf -- "$work_dir"
    fi
}
trap cleanup EXIT

[[ "$upstream_tag" =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "Unsupported upstream tag $upstream_tag"
if [ -z "$resume" ]; then
    printf '%s\n' "$upstream_tag" > "$work_dir/upstream-tag"
fi
fork_tag="${upstream_tag}-shr-path.1"
release_url="https://github.com/$fork/releases/tag/$fork_tag"
fork_url="https://github.com/$fork.git"
source_dir="$work_dir/source"

verify_published_sfx() {
    local artifact=$1 digest actual_digest ref refs commit version suffix
    digest=$(gh release view "$fork_tag" --repo "github.com/$fork" --json body --jq .body |
        sed -nE 's/^The SHA-256 of `copyparty-sfx\.py` is `([0-9a-fA-F]{64})`\.$/\1/p' |
        tr '[:upper:]' '[:lower:]')
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "Missing or ambiguous SFX checksum for $fork_tag"
    actual_digest=$(sha256 "$artifact")
    [ "$actual_digest" = "$digest" ] || die "Published SFX checksum mismatch for $fork_tag"

    ref="refs/tags/$fork_tag"
    refs=$(git_fork ls-remote --exit-code "$fork_url" "$ref" "$ref^{}") \
        || die "Could not resolve the published tag $fork_tag"
    commit=$(awk -v ref="$ref" '
        $2 == ref { tag = $1 }
        $2 == ref "^{}" { peeled = $1 }
        END { print peeled ? peeled : tag }
    ' <<< "$refs")
    version=$(python3 -I -S "$artifact" --versionb) || die "Could not read the published SFX version"
    suffix=${version#"${upstream_tag#v}"}
    if [[ "$version" == "${upstream_tag#v}-"* && "$suffix" =~ ^-[0-9]+-g([0-9a-f]{4,40})$ ]] &&
        [[ "$commit" == "${BASH_REMATCH[1]}"* ]]; then
        return
    fi
    die "Published SFX version $version does not match $fork_tag ($commit)"
}

deploy_sfx() {
    local artifact=$1 target backup
    target=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$deploy_file")
    if cmp -s "$artifact" "$target"; then
        printf 'SFX is already installed at %s\n' "$target"
        "${restart[@]}"
        return
    fi
    backup=$(mktemp "$work_dir/previous-sfx.XXXXXXXX")
    cp -p -- "$target" "$backup"
    deploy_tmp=$(mktemp "$(dirname "$target")/.copyparty-sfx.XXXXXXXX")
    cp -p -- "$target" "$deploy_tmp"
    cat -- "$artifact" > "$deploy_tmp"
    mv -f -- "$deploy_tmp" "$target"

    if ! "${restart[@]}"; then
        cp -p -- "$backup" "$deploy_tmp"
        mv -f -- "$deploy_tmp" "$target"
        "${restart[@]}" || die "Restored $target, but the restart command still failed"
        die "Restart failed. Restored the previous SFX at $target"
    fi
    deploy_tmp=
    printf 'Deployed %s to %s\n' "$fork_tag" "$target"
}

release_state=
if [ -z "$build_output" ]; then
    release_state=$(gh api --hostname github.com --paginate "repos/$fork/releases?per_page=100" --jq \
        ".[] | select(.tag_name == \"$fork_tag\") | any(.assets[]; .name == \"$asset_name\") as \$ready |
         if .draft then (if \$ready then \"draft-ready\" else \"draft\" end)
         elif \$ready then \"published\" else \"missing-asset\" end")
    case "$release_state" in
        published)
            printf 'Already published %s\n' "$release_url"
            if [ -n "$deploy_file" ]; then
                download_dir=$(mktemp -d "$work_dir/download.XXXXXXXX")
                gh release download "$fork_tag" --repo "github.com/$fork" --pattern "$asset_name" --dir "$download_dir"
                artifact="$download_dir/$asset_name"
                verify_published_sfx "$artifact"
                deploy_sfx "$artifact"
            fi
            exit 0
            ;;
        missing-asset) die "Published release is missing $asset_name at $release_url" ;;
        draft|draft-ready|'') ;;
        *) die "Unexpected release state for $fork_tag" ;;
    esac
fi

if [ "$(uname -s)" = Darwin ]; then
    if ! { command -v gtar || command -v gnutar; } >/dev/null; then
        die 'Install the macOS build tools with brew install gsed gnu-tar findutils coreutils'
    fi
    for tool in gsed gfind gsort gtr gnproc gunexpand; do
        command -v "$tool" >/dev/null \
            || die 'Install the macOS build tools with brew install gsed gnu-tar findutils coreutils'
    done
fi

if [ ! -d "$source_dir/.git" ]; then
    git_fork clone --no-tags --single-branch --branch "$branch" "$fork_url" "$source_dir"
else
    [ "$(git -C "$source_dir" config --get remote.origin.url)" = "$fork_url" ] \
        || die "Origin of the saved checkout does not match $fork_url"
    [ "$(git -C "$source_dir" branch --show-current)" = "$branch" ] \
        || die "Switch the saved checkout to $branch before resuming"
    [ -z "$(git -C "$source_dir" status --porcelain)" ] \
        || die 'Finish the merge and commit any changes in the saved checkout before resuming'
fi

git_fork -C "$source_dir" fetch --no-tags "https://github.com/$upstream.git" tag "$upstream_tag"
upstream_commit=$(git -C "$source_dir" rev-parse "refs/tags/${upstream_tag}^{commit}")
remote_tag=
if [ -z "$build_output" ]; then
    remote_tag=$(git_fork -C "$source_dir" ls-remote origin "refs/tags/$fork_tag")
fi

if [ -n "$remote_tag" ]; then
    # Keep the fork tag outside refs/tags so make-sfx only sees the upstream tag.
    ref="refs/fork-releases/$fork_tag"
    git_fork -C "$source_dir" fetch --no-tags origin "refs/tags/$fork_tag:$ref"
    build_commit=$(git -C "$source_dir" rev-parse "${ref}^{commit}")
    git -C "$source_dir" merge-base --is-ancestor "$upstream_commit" "$build_commit" \
        || die "Existing fork tag does not include $upstream_tag"
else
    [ -z "$release_state" ] || die "Draft release exists without its remote tag $fork_tag"
    if [ -n "$resume" ]; then
        git_fork -C "$source_dir" fetch --no-tags origin
        merge_into_fork "refs/remotes/origin/$branch"
    fi
    merge_into_fork "$upstream_commit"
    build_commit=$(git -C "$source_dir" rev-parse HEAD)
fi

build_dir=$(mktemp -d "$work_dir/build.XXXXXXXX")
build_src="$build_dir/src"
git -C "$source_dir" worktree add --detach "$build_src" "$build_commit"
printf 'Testing %s\n' "$build_commit"
python3 -m venv "$build_dir/venv"
"$build_dir/venv/bin/python" -m pip --disable-pip-version-check -q install jinja2
(cd "$build_src" && "$build_dir/venv/bin/python" -m unittest discover -s tests) > "$build_dir/tests.log" 2>&1 \
    || { tail -60 "$build_dir/tests.log" >&2; die 'Source tests failed'; }
grep -E '^Ran [0-9]+ tests? in' "$build_dir/tests.log" || true

if [ "$release_state" = draft-ready ]; then
    gh release download "$fork_tag" --repo "github.com/$fork" --pattern "$asset_name" --dir "$build_dir"
    artifact="$build_dir/$asset_name"
else
    archive_root="copyparty-${upstream_tag#v}"
    gh release download "$upstream_tag" --repo "github.com/$upstream" --pattern "$archive_root.tar.gz" --dir "$build_dir"
    tar -xzf "$build_dir/$archive_root.tar.gz" -C "$build_src" --strip-components=1 "$archive_root/copyparty/web/deps"
    printf 'Building %s\n' "$asset_name"
    (cd "$build_src" && ./scripts/make-sfx.sh gz fast) > "$build_dir/build.log" 2>&1 \
        || { tail -60 "$build_dir/build.log" >&2; die 'SFX build failed'; }
    artifact="$build_src/dist/$asset_name"
fi

expected_version=$(git -C "$build_src" describe --tags)
actual_version=$(python3 -I -S "$artifact" --versionb)
[ "$actual_version" = "${expected_version#v}" ] || die "SFX version $actual_version does not match $build_commit"

printf 'Checking anonymous browsing and download with the SFX\n'
if ! python3 -I -S - "$artifact" "$build_dir" > "$build_dir/sfx-smoke.log" 2>&1 <<'PY'; then
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen

artifact, scratch = map(Path, sys.argv[1:])
files = scratch / "private"
files.mkdir()
content = b"print('public share test')\n"
(files / "test.py").write_bytes(content)
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]

base = f"http://127.0.0.1:{port}"
env = dict(os.environ, XDG_CONFIG_HOME=str(scratch / "config"), PRTY_XD=str(scratch / "cache"))
cmd = [
    sys.executable, "-I", "-S", str(artifact), "-i", "127.0.0.1", "-p", str(port),
    "--no-ses", "--no-htp", "--shr", "/s", "--shr-path", "--shr-db", str(scratch / "shares.db"),
    "-a", "test:sfx-smoke-test", "-v", f"{files}:private:r,test",
]
with subprocess.Popen(cmd, cwd=scratch, env=env, stdin=subprocess.DEVNULL) as server:
    try:
        for attempt in range(80):
            try:
                with urlopen(base + "/s?ls", timeout=1) as response:
                    assert json.load(response)["dirs"] == []
                break
            except OSError:
                if server.poll() is not None or attempt == 79:
                    raise
                time.sleep(0.1)

        payload = {"path": "python/test.py", "vp": ["/private/test.py"], "exp": "0", "perms": ["read"]}
        request = Request(base + "/?share&pw=sfx-smoke-test", json.dumps(payload).encode(),
                          {"Content-Type": "application/json"})
        with urlopen(request, timeout=5) as response:
            assert response.status == 201, response.status
        with urlopen(base + "/s?ls", timeout=5) as response:
            assert [x["href"] for x in json.load(response)["dirs"]] == ["python/"]
        with urlopen(base + "/s/python/test.py", timeout=5) as response:
            assert response.read() == content
    finally:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
PY
    tail -60 "$build_dir/sfx-smoke.log" >&2
    die 'SFX smoke test failed'
fi

if [ -n "$build_output" ]; then
    mkdir -p -- "$(dirname "$build_output")"
    install -m 755 -- "$artifact" "$build_output"
    printf 'Built %s\n' "$build_output"
    exit 0
fi

if [ -z "$remote_tag" ]; then
    git_fork -C "$source_dir" push --atomic origin \
        "$build_commit:refs/heads/$branch" "$build_commit:refs/tags/$fork_tag"
fi

notes="$build_dir/notes.md"
digest=$(sha256 "$artifact")
{
    printf 'Updates this fork to %s with browsable public share paths.\n\n' "$upstream_tag"
    printf 'Download `copyparty-sfx.py` and run it with your existing configuration.\n\n'
    printf 'The SHA-256 of `copyparty-sfx.py` is `%s`.\n' "$digest"
} > "$notes"
case "$release_state" in
    draft|draft-ready)
        if [ "$release_state" = draft ]; then
            gh release upload "$fork_tag" "$artifact" --repo "github.com/$fork"
        fi
        gh release edit "$fork_tag" --repo "github.com/$fork" --draft=false --latest --notes-file "$notes"
        ;;
    '')
        gh release create "$fork_tag" "$artifact" --repo "github.com/$fork" --verify-tag --latest \
            --title "copyparty $upstream_tag with public share paths" --notes-file "$notes"
        ;;
esac

mkdir -p -- "$build_dir/published"
gh release download "$fork_tag" --repo "github.com/$fork" --pattern "$asset_name" --dir "$build_dir/published"
cmp "$artifact" "$build_dir/published/$asset_name" || die 'Published SFX differs from the tested build'
printf 'Published %s\n' "$release_url"
if [ -n "$deploy_file" ]; then
    deploy_sfx "$build_dir/published/$asset_name"
fi
