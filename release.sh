#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$root/.." && pwd)
config="$root/config/sources.yml"
dist_root=${PURPLE_DIST_DIST:-"$root/dist"}
verify_tmp_dir=

usage() {
  cat <<'EOF'
Usage: ./release.sh COMPONENT --build|--verify|--publish
       ./release.sh --help

Components: habit and tabu (build, verify, publish); braid is inspected only.
EOF
}

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# == 2 ]] || { usage >&2; exit 2; }
component=$1
action=$2
[[ $component =~ ^(habit|braid|tabu)$ ]] || die "unknown component: $component"
[[ $action =~ ^(--build|--verify|--publish)$ ]] || { usage >&2; exit 2; }

field() {
  awk -v component="$component" -v key="$1" '
    $0 == "  " component ":" { in_component=1; next }
    /^  [a-z][a-z0-9_-]*:/ { in_component=0 }
    in_component && $0 ~ "^    " key ": " { sub("^    " key ": ", ""); print; found++ }
    END { if (found != 1) exit 1 }
  ' "$config"
}

source_rel=$(field path) || die "missing source path in $config"
source_commit=$(field commit) || die "missing source commit in $config"
version=$(field version) || die "missing version in $config"
source="$repo_root/$source_rel"
[[ -d $source/.git ]] || die "source repository missing: $source"
actual_commit=$(git -C "$source" rev-parse HEAD) || die "cannot read source revision: $source"
[[ $actual_commit == "$source_commit" ]] || die "$component source revision mismatch: expected $source_commit, got $actual_commit"
[[ -z $(git -C "$source" status --porcelain) ]] || die "$component source working tree is dirty"

candidate="$dist_root/$component-v$version"
package_version=$(field package_version) || die "missing package_version in $config"
case $component in
  habit) deb="habit-content_${package_version}_amd64.deb" ;;
  tabu) deb="tabu_${package_version}_amd64.deb" ;;
  braid) die "braid integration is not enabled yet; see README.md" ;;
esac

pe_check() {
  local path=$1 description
  description=$(file -b "$path") || die "cannot inspect executable: $path"
  [[ $description == *PE32+* && $description == *x86-64* ]] || die "unexpected Windows executable format: $description"
}

verify_habit_candidate() {
  local expected_commit=$1 expected_version=$2 manifest="$candidate/manifest.json" file hash actual
  [[ -d $candidate ]] || die "candidate missing: $candidate"
  [[ -s $manifest && -s $candidate/SHA256SUMS ]] || die "manifest or checksums missing"
  [[ $(jq -r '.source.commit' "$manifest") == "$expected_commit" ]] || die "manifest source commit mismatch"
  [[ $(jq -r '.component' "$manifest") == "$component" ]] || die "manifest component mismatch"
  [[ $(jq -r '.version' "$manifest") == "$expected_version" ]] || die "manifest version mismatch"
  (cd "$candidate" && shasum -a 256 -c SHA256SUMS) || die "artifact checksum failed"
  for file in "$deb" habit-agent.exe habit-agent-browser.exe; do
    [[ -s "$candidate/$file" ]] || die "required artifact missing: $file"
    hash=$(shasum -a 256 "$candidate/$file" | awk '{print $1}')
    actual=$(jq -r --arg name "$file" '.artifacts[] | select(.filename == $name) | .sha256' "$manifest")
    [[ $hash == "$actual" ]] || die "manifest checksum mismatch: $file"
  done
  debpack verify "$candidate/$deb" >/dev/null || die "Debian package verification failed"
  local metadata
  metadata=$(debpack inspect "$candidate/$deb") || die "cannot inspect Debian package"
  [[ $(jq -r '.package.Package' <<<"$metadata") == habit-content ]] || die "unexpected Debian package name"
  [[ $(jq -r '.package.Version' <<<"$metadata") == "$package_version" ]] || die "unexpected Debian package version"
  [[ $(jq -r '.package.Architecture' <<<"$metadata") == amd64 ]] || die "unexpected Debian package architecture"
  pe_check "$candidate/habit-agent.exe"
  pe_check "$candidate/habit-agent-browser.exe"
  printf 'verified %s %s (%s)\n' "$component" "$expected_version" "$expected_commit"
}

inspect_tabu_binary() {
  local path=$1 description build_info target
  description=$(file -b "$path") || die "cannot inspect TABU executable"
  [[ $description == *"ELF 64-bit LSB executable, x86-64"* && $description == *"statically linked"* ]] || die "unexpected TABU ELF or runtime dependencies: $description"
  build_info=$(go version -m "$path") || die "cannot read TABU Go build information"
  for target in $'\tGOOS=linux' $'\tGOARCH=amd64' $'\tCGO_ENABLED=0'; do
    [[ $build_info == *"$target"* ]] || die "TABU executable missing build setting: ${target//$'\t'/}"
  done
}

verify_tabu_candidate() {
  local expected_commit=$1 expected_version=$2 manifest="$candidate/manifest.json" hash actual metadata
  for command in go debpack jq shasum file tar; do command -v "$command" >/dev/null || die "required verification tool missing: $command"; done
  [[ -d $candidate ]] || die "candidate missing: $candidate"
  [[ -s $manifest && -s $candidate/SHA256SUMS && -s $candidate/$deb ]] || die "TABU package, manifest, or checksums missing"
  [[ $(jq -r '.source.commit' "$manifest") == "$expected_commit" ]] || die "manifest source commit mismatch"
  [[ $(jq -r '.component' "$manifest") == "$component" ]] || die "manifest component mismatch"
  [[ $(jq -r '.version' "$manifest") == "$expected_version" ]] || die "manifest version mismatch"
  (cd "$candidate" && shasum -a 256 -c SHA256SUMS) || die "artifact checksum failed"
  hash=$(shasum -a 256 "$candidate/$deb" | awk '{print $1}')
  actual=$(jq -r --arg name "$deb" '.artifacts[] | select(.filename == $name) | .sha256' "$manifest")
  [[ $hash == "$actual" ]] || die "manifest checksum mismatch: $deb"
  [[ $(jq -r '.artifacts | length' "$manifest") == 1 ]] || die "unexpected TABU artifact count in manifest"
  debpack verify "$candidate/$deb" >/dev/null || die "Debian package verification failed"
  metadata=$(debpack inspect "$candidate/$deb") || die "cannot inspect TABU Debian package"
  jq -e --arg version "$package_version" '
    .package.Package == "tabu" and
    .package.Version == $version and
    .package.Architecture == "amd64" and
    .package.Depends == "libc6 (>= 2.34)" and
    any(.payload[]; .name == "usr/bin/tabu" and .mode == "0755") and
    any(.payload[]; .name == "etc/tabu/tabu.json" and .mode == "0644") and
    any(.payload[]; .name == "var/lib/tabu" and .type == "directory" and .mode == "0755") and
    (.control_files | index("conffiles") != null)
  ' <<<"$metadata" >/dev/null || die "TABU package metadata or contents do not match packaging contract"

  mkdir -p "$root/work"
  verify_tmp_dir=$(mktemp -d "$root/work/tabu-verify.XXXXXX")
  trap 'if [[ -n ${verify_tmp_dir:-} ]]; then rm -rf -- "$verify_tmp_dir"; verify_tmp_dir=; fi' RETURN
  tar -xOf "$candidate/$deb" data.tar.gz | tar -xzOf - usr/bin/tabu >"$verify_tmp_dir/tabu"
  inspect_tabu_binary "$verify_tmp_dir/tabu"
  printf 'verified %s %s (%s)\n' "$component" "$expected_version" "$expected_commit"
}

verify_candidate() {
  if [[ $component == habit ]]; then
    verify_habit_candidate "$@"
  else
    verify_tabu_candidate "$@"
  fi
}

case $action in
  --verify)
    verify_candidate "$actual_commit" "$version"
    ;;
  --build)
    if [[ $component == habit ]]; then
      for command in go debpack jq shasum file tar; do command -v "$command" >/dev/null || die "required tool missing: $command"; done
      [[ $(go version) == 'go version go1.27.2 darwin/amd64' ]] || die "HABIT release requires Go 1.27.2 on darwin/amd64"
    else
      for command in go debpack jq shasum file tar make; do command -v "$command" >/dev/null || die "required tool missing: $command"; done
      [[ $(go version) == 'go version go1.27.2 darwin/amd64' ]] || die "TABU release requires Go 1.27.2 on darwin/amd64"
    fi
    [[ ! -e $candidate ]] || die "candidate already exists: $candidate; remove it manually after review"
    mkdir -p "$root/work" "$dist_root"
    tmp=$(mktemp -d "$root/work/$component.XXXXXX")
    cleanup() {
      rm -rf -- "$tmp"
      [[ -z ${tabu_snapshot:-} ]] || rm -rf -- "$tabu_snapshot"
    }
    trap cleanup EXIT

    mkdir -p "$tmp/candidate"
    if [[ $component == habit ]]; then
      (cd "$source" && GOTOOLCHAIN=local go test ./...)
      (cd "$source" && GOTOOLCHAIN=local go vet ./...)
      # Build binaries in source checkout to retain Go's source provenance metadata.
      (cd "$source" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$tmp/habit-agent.exe" ./cmd/habit-agent)
      (cd "$source" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -tags=browser -trimpath -ldflags='-s -w' -o "$tmp/habit-agent-browser.exe" ./cmd/habit-agent)
      # Package in a source snapshot so HABIT's script cannot overwrite its ignored build/ or dist/ files.
      git -C "$source" archive "$source_commit" | tar -x -C "$tmp"
      (cd "$tmp" && GOTOOLCHAIN=local packaging/build-content-deb.sh "$tmp/out")
      for file in "$deb" habit-agent.exe habit-agent-browser.exe; do
        if [[ $file == "$deb" ]]; then
          install -m 0644 "$tmp/out/$deb" "$tmp/candidate/$deb"
        elif [[ $file == habit-agent.exe ]]; then
          install -m 0644 "$tmp/habit-agent.exe" "$tmp/candidate/$file"
        else
          install -m 0644 "$tmp/habit-agent-browser.exe" "$tmp/candidate/$file"
        fi
        hash=$(shasum -a 256 "$tmp/candidate/$file" | awk '{print $1}')
        printf '%s  %s\n' "$hash" "$file" >>"$tmp/candidate/SHA256SUMS"
      done
    else
      tabu_snapshot=$(mktemp -d "${TMPDIR:-/tmp}/purple-dist-tabu.XXXXXX")
      git -C "$source" archive "$source_commit" | tar -x -C "$tabu_snapshot"
      (cd "$tabu_snapshot" && TABU_SOURCE_REVISION="$actual_commit" TABU_PACKAGE_VERSION="$package_version" TABU_BINARY_OUTPUT="$tmp/tabu" GOTOOLCHAIN=local packaging/build-deb.sh "$tmp/out")
      rm -rf -- "$tabu_snapshot"
      tabu_snapshot=
      inspect_tabu_binary "$tmp/tabu"
      install -m 0644 "$tmp/out/$deb" "$tmp/candidate/$deb"
      hash=$(shasum -a 256 "$tmp/candidate/$deb" | awk '{print $1}')
      printf '%s  %s\n' "$hash" "$deb" >"$tmp/candidate/SHA256SUMS"
    fi
    built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    go_version=$(go version)
    if [[ $component == habit ]]; then
      jq -n \
        --arg component "$component" --arg version "$version" --arg commit "$actual_commit" \
        --arg built_at "$built_at" --arg environment "$(uname -s)/$(uname -m)" --arg go "$go_version" \
        --arg deb "$deb" --arg deb_hash "$(awk 'NR==1 {print $1}' "$tmp/candidate/SHA256SUMS")" \
        --arg deb_arch amd64 --arg agent_hash "$(awk 'NR==2 {print $1}' "$tmp/candidate/SHA256SUMS")" \
        --arg browser_hash "$(awk 'NR==3 {print $1}' "$tmp/candidate/SHA256SUMS")" \
        '{component:$component,version:$version,source:{commit:$commit},build:{timestamp_utc:$built_at,host:$environment,go:$go},artifacts:[{filename:$deb,architecture:$deb_arch,sha256:$deb_hash},{filename:"habit-agent.exe",architecture:"windows/amd64",sha256:$agent_hash},{filename:"habit-agent-browser.exe",architecture:"windows/amd64",sha256:$browser_hash}]}' \
        >"$tmp/candidate/manifest.json"
    else
      jq -n \
        --arg component "$component" --arg version "$version" --arg commit "$actual_commit" \
        --arg built_at "$built_at" --arg environment "$(uname -s)/$(uname -m)" --arg go "$go_version" \
        --arg deb "$deb" --arg hash "$(awk 'NR==1 {print $1}' "$tmp/candidate/SHA256SUMS")" \
        '{component:$component,version:$version,source:{commit:$commit},build:{timestamp_utc:$built_at,host:$environment,go:$go,packager:"debpack"},artifacts:[{filename:$deb,architecture:"amd64",sha256:$hash}]}' \
        >"$tmp/candidate/manifest.json"
    fi
    mv "$tmp/candidate" "$candidate"
    if ! verify_candidate "$actual_commit" "$version"; then
      rm -rf -- "$candidate"
      die "candidate verification failed; removed $candidate"
    fi
    printf 'candidate: %s\n' "$candidate"
    ;;
  --publish)
    command -v gh >/dev/null || die "GitHub CLI (gh) is required only for publishing"
    command -v curl >/dev/null || die "curl is required for anonymous download verification"
    gh auth status >/dev/null 2>&1 || die "authenticate gh with write access to crgr/purple-dist"
    verify_candidate "$actual_commit" "$version"
    tag="$component-v$version"
    if gh release view "$tag" --repo crgr/purple-dist >/dev/null 2>&1; then die "release already exists: $tag"; fi
    if [[ $component == habit ]]; then
      assets=("$candidate/$deb" "$candidate/habit-agent.exe" "$candidate/habit-agent-browser.exe")
      asset_names=("$deb" habit-agent.exe habit-agent-browser.exe)
    else
      assets=("$candidate/$deb")
      asset_names=("$deb")
    fi
    gh release create "$tag" "${assets[@]}" "$candidate/SHA256SUMS" "$candidate/manifest.json" \
      --repo crgr/purple-dist --title "$component $version" --notes "Verified local build from $actual_commit."
    download_dir=$(mktemp -d "$root/work/publish-check.XXXXXX")
    trap 'rm -rf -- "$download_dir"' EXIT
    asset_names+=(SHA256SUMS manifest.json)
    for file in "${asset_names[@]}"; do
      url="https://github.com/crgr/purple-dist/releases/download/$tag/$file"
      curl --fail --silent --show-error --location --output "$download_dir/$file" "$url" || die "anonymous asset download failed: $url"
      expected=$(awk -v file="$file" '$2 == file {print $1}' "$candidate/SHA256SUMS")
      if [[ $file == manifest.json || $file == SHA256SUMS ]]; then expected=$(shasum -a 256 "$candidate/$file" | awk '{print $1}'); fi
      actual=$(shasum -a 256 "$download_dir/$file" | awk '{print $1}')
      [[ -n $expected && $actual == "$expected" ]] || die "anonymous download checksum mismatch: $file"
    done
    ;;
esac
