#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$root/.." && pwd)
config="$root/config/sources.yml"
dist_root=${PURPLE_DIST_DIST:-"$root/dist"}

usage() {
  cat <<'EOF'
Usage: ./release.sh COMPONENT --build|--verify|--publish
       ./release.sh --help

Components: habit (build, verify, publish); braid and tabu are inspected only.
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

if [[ $component != habit ]]; then
  die "$component integration is not enabled yet; see README.md"
fi

package_version=$(field package_version) || die "missing package_version in $config"
candidate="$dist_root/$component-v$version"
deb="habit-content_${package_version}_amd64.deb"

pe_check() {
  local path=$1 description
  description=$(file -b "$path") || die "cannot inspect executable: $path"
  [[ $description == *PE32+* && $description == *x86-64* ]] || die "unexpected Windows executable format: $description"
}

verify_candidate() {
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

case $action in
  --verify)
    verify_candidate "$actual_commit" "$version"
    ;;
  --build)
    for command in go debpack jq shasum file tar; do command -v "$command" >/dev/null || die "required tool missing: $command"; done
    [[ $(go version) == 'go version go1.27.2 darwin/amd64' ]] || die "HABIT release requires Go 1.27.2 on darwin/amd64"
    [[ ! -e $candidate ]] || die "candidate already exists: $candidate; remove it manually after review"
    mkdir -p "$root/work" "$dist_root"
    tmp=$(mktemp -d "$root/work/habit.XXXXXX")
    cleanup() { rm -rf -- "$tmp"; }
    trap cleanup EXIT

    (cd "$source" && GOTOOLCHAIN=local go test ./...)
    (cd "$source" && GOTOOLCHAIN=local go vet ./...)

    # Build binaries in source checkout to retain Go's source provenance metadata.
    (cd "$source" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$tmp/habit-agent.exe" ./cmd/habit-agent)
    (cd "$source" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -tags=browser -trimpath -ldflags='-s -w' -o "$tmp/habit-agent-browser.exe" ./cmd/habit-agent)
    # Package in a source snapshot so HABIT's script cannot overwrite its ignored build/ or dist/ files.
    git -C "$source" archive "$source_commit" | tar -x -C "$tmp"
    (cd "$tmp" && GOTOOLCHAIN=local packaging/build-content-deb.sh "$tmp/out")
    mkdir -p "$tmp/candidate"
    install -m 0644 "$tmp/out/$deb" "$tmp/candidate/$deb"
    install -m 0644 "$tmp/habit-agent.exe" "$tmp/candidate/habit-agent.exe"
    install -m 0644 "$tmp/habit-agent-browser.exe" "$tmp/candidate/habit-agent-browser.exe"

    for file in "$deb" habit-agent.exe habit-agent-browser.exe; do
      hash=$(shasum -a 256 "$tmp/candidate/$file" | awk '{print $1}')
      printf '%s  %s\n' "$hash" "$file" >>"$tmp/candidate/SHA256SUMS"
    done
    built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    go_version=$(go version)
    jq -n \
      --arg component "$component" --arg version "$version" --arg commit "$actual_commit" \
      --arg built_at "$built_at" --arg environment "$(uname -s)/$(uname -m)" --arg go "$go_version" \
      --arg deb "$deb" --arg deb_hash "$(awk 'NR==1 {print $1}' "$tmp/candidate/SHA256SUMS")" \
      --arg deb_arch amd64 --arg agent_hash "$(awk 'NR==2 {print $1}' "$tmp/candidate/SHA256SUMS")" \
      --arg browser_hash "$(awk 'NR==3 {print $1}' "$tmp/candidate/SHA256SUMS")" \
      '{component:$component,version:$version,source:{commit:$commit},build:{timestamp_utc:$built_at,host:$environment,go:$go},artifacts:[{filename:$deb,architecture:$deb_arch,sha256:$deb_hash},{filename:"habit-agent.exe",architecture:"windows/amd64",sha256:$agent_hash},{filename:"habit-agent-browser.exe",architecture:"windows/amd64",sha256:$browser_hash}]}' \
      >"$tmp/candidate/manifest.json"
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
    gh release create "$tag" "$candidate/$deb" "$candidate/habit-agent.exe" "$candidate/habit-agent-browser.exe" "$candidate/SHA256SUMS" "$candidate/manifest.json" \
      --repo crgr/purple-dist --title "$component $version" --notes "Verified local build from $actual_commit."
    download_dir=$(mktemp -d "$root/work/publish-check.XXXXXX")
    trap 'rm -rf -- "$download_dir"' EXIT
    for file in "$deb" habit-agent.exe habit-agent-browser.exe SHA256SUMS manifest.json; do
      url="https://github.com/crgr/purple-dist/releases/download/$tag/$file"
      curl --fail --silent --show-error --location --output "$download_dir/$file" "$url" || die "anonymous asset download failed: $url"
      expected=$(awk -v file="$file" '$2 == file {print $1}' "$candidate/SHA256SUMS")
      if [[ $file == manifest.json || $file == SHA256SUMS ]]; then expected=$(shasum -a 256 "$candidate/$file" | awk '{print $1}'); fi
      actual=$(shasum -a 256 "$download_dir/$file" | awk '{print $1}')
      [[ -n $expected && $actual == "$expected" ]] || die "anonymous download checksum mismatch: $file"
    done
    ;;
esac
