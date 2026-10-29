#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/braid-source-sync.XXXXXX")
task_dir=$(cd "$task_dir" && pwd)
trap 'rm -rf -- "$task_dir"' EXIT
mkdir -p "$task_dir/purple-dist/config" "$task_dir/purple-dist/scripts" "$task_dir/braid"
cp "$root/release.sh" "$task_dir/purple-dist/release.sh"
cp "$root/scripts/artifact-names.sh" "$task_dir/purple-dist/scripts/artifact-names.sh"
git -C "$task_dir/braid" -c init.defaultBranch=main init -q
printf 'before\n' > "$task_dir/braid/component"
git -C "$task_dir/braid" add component
git -C "$task_dir/braid" -c user.name='test' -c user.email='test@localhost' -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm before
baseline=$(git -C "$task_dir/braid" rev-parse HEAD)
printf 'after\n' > "$task_dir/braid/component"
git -C "$task_dir/braid" add component
git -C "$task_dir/braid" -c user.name='test' -c user.email='test@localhost' -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm after
revision=$(git -C "$task_dir/braid" rev-parse HEAD)
commit_time=$(git -C "$task_dir/braid" show -s --format=%ct HEAD)
printf 'components:\n  braid:\n    path: braid\n    commit: %s\n    version: 0.2.4\n    artifact_version: 0.2.4\n    package_version: 0.2.4\n' "$baseline" > "$task_dir/purple-dist/config/sources.yml"
if output=$("$task_dir/purple-dist/release.sh" braid --verify 2>&1); then
  echo 'verification unexpectedly accepted a missing candidate' >&2
  exit 1
fi
[[ $output == *"candidate missing: $task_dir/purple-dist/dist/braid-v0.2.4+git.${commit_time}.${revision:0:12}"* ]] || { printf 'unexpected automatic version: %s\n' "$output" >&2; exit 1; }
printf 'components:\n  braid:\n    path: braid\n    commit: 0000000000000000000000000000000000000000\n    version: 0.2.4\n    artifact_version: 0.2.4\n    package_version: 0.2.4\n' > "$task_dir/purple-dist/config/sources.yml"
if output=$("$task_dir/purple-dist/release.sh" braid --verify 2>&1); then
  echo 'verification unexpectedly accepted an unrelated source revision' >&2
  exit 1
fi
[[ $output == *'BRAID HEAD must descend from the configured source revision'* ]] || { printf 'unexpected source rejection: %s\n' "$output" >&2; exit 1; }
printf 'BRAID source synchronization tests passed\n'
