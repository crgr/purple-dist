#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/braid-pin-sync.XXXXXX")
trap 'rm -rf -- "$task_dir"' EXIT
mkdir -p "$task_dir/input" "$task_dir/release" "$task_dir/windows"
version=1.2.3
revision=0123456789abcdef0123456789abcdef01234567
server=braid-v1.2.3_amd64.deb
agent=braid-agent-v1.2.3_windows_amd64.zip
xdeb=braid-x-v1.2.3_amd64.deb
printf 'server fixture\n' > "$task_dir/input/server"
printf 'x fixture\n' > "$task_dir/input/x"
for package in braid-server braid-x; do
  input_name=server
  target=braid-server
  [[ $package != braid-x ]] || input_name=x
  [[ $package != braid-x ]] || target=x
  jq -n --arg name "$package" --arg source "$input_name" --arg target "$target" '{package:{name:$name,version:"1.2.3",architecture:"amd64",maintainer:"Test <test@localhost>",description:"fixture"},input_roots:{input:"input"},contents:[{type:"file",source_root:"input",source:$source,path:("usr/bin/"+$target),mode:"0755",uid:0,gid:0}]}' > "$task_dir/$package.json"
  output=$server
  [[ $package != braid-x ]] || output=$xdeb
  debpack build --manifest "$task_dir/$package.json" --output "$task_dir/release/$output" >/dev/null
done
printf 'agent fixture\n' > "$task_dir/windows/braid-agent.exe"
printf 'windows x fixture\n' > "$task_dir/windows/x.exe"
printf 'version=%s\ncommit=%s\ntarget=windows/amd64\n' "$version" "${revision:0:12}" > "$task_dir/windows/version.txt"
(cd "$task_dir/windows" && shasum -a 256 braid-agent.exe x.exe > SHA256SUMS && zip -q "$task_dir/release/$agent" braid-agent.exe x.exe version.txt SHA256SUMS)
(cd "$task_dir/release" && shasum -a 256 "$server" "$agent" "$xdeb" > SHA256SUMS)
jq -n --arg revision "$revision" --rawfile sums "$task_dir/release/SHA256SUMS" '{component:"braid",version:"1.2.3",package_version:"1.2.3",artifact_version:"1.2.3",source:{commit:$revision},artifacts:[$sums | split("\n")[] | select(length>0) | split("  ") | {sha256:.[0],filename:.[1]}]}' > "$task_dir/release/manifest.json"
printf '%s\n' '{"components":{"braid-server":{},"braid-agent":{},"habit-agent":{"version":"keep"}}}' > "$task_dir/components.json"
"$root/scripts/sync-braid-pins.sh" "$task_dir/release" "$version" "$task_dir/components.json"
server_binary_hash=$(shasum -a 256 "$task_dir/input/server" | awk '{print $1}')
linux_x_hash=$(shasum -a 256 "$task_dir/input/x" | awk '{print $1}')
jq -e --arg revision "$revision" --arg server_hash "$server_binary_hash" --arg x_hash "$linux_x_hash" '.components as $c | all(["braid-server","braid-agent","braid-x"][]; $c[.].source_revision == $revision and $c[.].version == "1.2.3") and ($c["braid-agent"].x_archive_member_sha256 | length == 64) and $c["braid-server"].binary_sha256 == $server_hash and $c["braid-x"].binary_sha256 == $x_hash and $c["habit-agent"].version == "keep"' "$task_dir/components.json" >/dev/null
before=$(shasum -a 256 "$task_dir/components.json" | awk '{print $1}')
jq '(.artifacts[] | select(.filename | startswith("braid-x-")) | .sha256) = ("0" * 64)' "$task_dir/release/manifest.json" > "$task_dir/release/manifest.tmp"
mv "$task_dir/release/manifest.tmp" "$task_dir/release/manifest.json"
if "$root/scripts/sync-braid-pins.sh" "$task_dir/release" "$version" "$task_dir/components.json" >/dev/null 2>&1; then
  echo 'tampered manifest was accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$task_dir/components.json" | awk '{print $1}')
[[ $before == "$after" ]] || { echo 'failed update changed the lock' >&2; exit 1; }
printf 'BRAID pin synchronization tests passed\n'
