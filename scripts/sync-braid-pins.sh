#!/usr/bin/env bash
set -euo pipefail

# Apply one verified, published BRAID bundle to PURPLE's local component pins.
[[ $# == 3 ]] || { echo 'usage: sync-braid-pins.sh RELEASE_DIR ARTIFACT_VERSION COMPONENTS_LOCK' >&2; exit 2; }
release_dir=$1
artifact_version=$2
lock_file=$3
source "$(dirname "$0")/artifact-names.sh"
server=$(artifact_filename braid package "$artifact_version")
agent=$(artifact_filename braid agent "$artifact_version")
xdeb=$(artifact_filename braid x "$artifact_version")
manifest="$release_dir/manifest.json"
[[ -f $manifest && -f $lock_file ]] || { echo 'missing manifest or PURPLE component lock' >&2; exit 1; }
(cd "$release_dir" && shasum -a 256 -c SHA256SUMS >/dev/null)
version=$(jq -er '.version' "$manifest")
package_version=$(jq -er '.package_version' "$manifest")
revision=$(jq -er '.source.commit' "$manifest")
[[ $revision =~ ^[0-9a-f]{40}$ && $version != *.dirty ]] || { echo 'release must have a clean full source revision' >&2; exit 1; }
jq -e --arg version "$artifact_version" --arg s "$server" --arg a "$agent" --arg x "$xdeb" '
  .component == "braid" and .artifact_version == $version and (.artifacts | length == 3) and
  ([.artifacts[].filename] | sort) == ([$s,$a,$x] | sort)
' "$manifest" >/dev/null
for artifact in "$server" "$agent" "$xdeb"; do
  actual=$(shasum -a 256 "$release_dir/$artifact" | awk '{print $1}')
  expected=$(jq -er --arg name "$artifact" '.artifacts[] | select(.filename == $name) | .sha256' "$manifest")
  [[ $actual == "$expected" ]] || { echo "manifest checksum mismatch: $artifact" >&2; exit 1; }
done
debpack verify "$release_dir/$server" >/dev/null
debpack verify "$release_dir/$xdeb" >/dev/null
unzip -tq "$release_dir/$agent" >/dev/null
server_metadata=$(debpack inspect "$release_dir/$server")
x_metadata=$(debpack inspect "$release_dir/$xdeb")
jq -e --arg version "$package_version" '.package.Package == "braid-server" and .package.Version == $version and .package.Architecture == "amd64"' <<<"$server_metadata" >/dev/null
jq -e --arg version "$package_version" '.package.Package == "braid-x" and .package.Version == $version and .package.Architecture == "amd64"' <<<"$x_metadata" >/dev/null
windows_version=$(unzip -p "$release_dir/$agent" version.txt)
[[ $windows_version == "$(printf 'version=%s\ncommit=%s\ntarget=windows/amd64' "$version" "${revision:0:12}")" ]] || { echo 'Windows release version or revision does not match' >&2; exit 1; }
agent_hash=$(unzip -p "$release_dir/$agent" braid-agent.exe | shasum -a 256 | awk '{print $1}')
x_hash=$(unzip -p "$release_dir/$agent" x.exe | shasum -a 256 | awk '{print $1}')
checksums=$(unzip -p "$release_dir/$agent" SHA256SUMS)
[[ $checksums == "$agent_hash  braid-agent.exe"$'\n'"$x_hash  x.exe" ]] || { echo 'Windows executable checksums do not match' >&2; exit 1; }
server_hash=$(shasum -a 256 "$release_dir/$server" | awk '{print $1}')
agent_zip_hash=$(shasum -a 256 "$release_dir/$agent" | awk '{print $1}')
xdeb_hash=$(shasum -a 256 "$release_dir/$xdeb" | awk '{print $1}')
server_binary_hash=$(tar -xOf "$release_dir/$server" data.tar.gz | tar -xzOf - usr/bin/braid-server | shasum -a 256 | awk '{print $1}')
linux_x_hash=$(tar -xOf "$release_dir/$xdeb" data.tar.gz | tar -xzOf - usr/bin/x | shasum -a 256 | awk '{print $1}')
tag="braid/v$artifact_version"
base="https://github.com/crgr/purple-dist/releases/download/$tag"
jq -e '.components["braid-server"] and .components["braid-agent"]' "$lock_file" >/dev/null
new_lock=$(mktemp "${lock_file}.tmp.XXXXXX")
trap 'rm -f -- "$new_lock"' EXIT
jq --arg version "$version" --arg package_version "$package_version" --arg revision "$revision" \
  --arg tag "$tag" --arg base "$base" --arg server "$server" --arg agent "$agent" --arg xdeb "$xdeb" \
  --arg server_hash "$server_hash" --arg agent_zip_hash "$agent_zip_hash" --arg xdeb_hash "$xdeb_hash" \
  --arg server_binary_hash "$server_binary_hash" --arg linux_x_hash "$linux_x_hash" \
  --arg agent_hash "$agent_hash" --arg x_hash "$x_hash" --arg artifact_version "$artifact_version" '
  .components["braid-server"] += {
    version:$version, source_repository:"crgr/braid", source_revision:$revision, release_tag:$tag,
    asset:$server, url:($base + "/" + $server), sha256:$server_hash, platform:"linux/amd64",
    cache_path:("braid-server/" + $artifact_version + "/" + $server), publication:"published", package_version:$package_version,
    binary_sha256:$server_binary_hash
  } |
  .components["braid-agent"] += {
    version:$version, source_repository:"crgr/braid", source_revision:$revision, release_tag:$tag,
    asset:$agent, url:($base + "/" + $agent), sha256:$agent_zip_hash, platform:"windows/amd64",
    cache_path:("braid-agent/" + $artifact_version + "/" + $agent), publication:"published",
    archive_member:"braid-agent.exe", archive_member_sha256:$agent_hash,
    x_archive_member:"x.exe", x_archive_member_sha256:$x_hash
  } |
  .components["braid-x"] = {
    version:$version, source_repository:"crgr/braid", source_revision:$revision, release_tag:$tag,
    asset:$xdeb, url:($base + "/" + $xdeb), sha256:$xdeb_hash, platform:"linux/amd64",
    cache_path:("braid-x/" + $artifact_version + "/" + $xdeb), publication:"published", package_version:$package_version,
    binary_sha256:$linux_x_hash
  }
' "$lock_file" > "$new_lock"
chmod 0644 "$new_lock"
mv "$new_lock" "$lock_file"
trap - EXIT
printf 'synchronized BRAID component pins in %s\n' "$lock_file"
