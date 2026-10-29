#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$root/.." && pwd)
config="$root/config/sources.yml"
dist_root=${PURPLE_DIST_DIST:-"$root/dist"}
source "$root/scripts/artifact-names.sh"
verify_tmp_dir=
braid_snapshot=

usage() {
  cat <<'EOF'
Usage: ./release.sh COMPONENT --build|--verify|--publish
       ./release.sh --help

Components: habit and braid (build, verify, publish).
EOF
}

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# == 2 ]] || { usage >&2; exit 2; }
component=$1
action=$2
[[ $component =~ ^(habit|braid)$ ]] || die "unknown component: $component"
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
artifact_version=$(field artifact_version) || die "missing artifact_version in $config"
source="$repo_root/$source_rel"
[[ -d $source/.git ]] || die "source repository missing: $source"
actual_commit=$(git -C "$source" rev-parse HEAD) || die "cannot read source revision: $source"
[[ -z $(git -C "$source" status --porcelain) ]] || die "$component source working tree is dirty"
source_changed=false
if [[ $actual_commit != "$source_commit" ]]; then
  [[ $component == braid ]] || die "$component source revision mismatch: expected $source_commit, got $actual_commit"
  git -C "$source" merge-base --is-ancestor "$source_commit" "$actual_commit" || die "BRAID HEAD must descend from the configured source revision"
  commit_time=$(git -C "$source" show -s --format=%ct "$actual_commit") || die "cannot read BRAID commit time"
  [[ $commit_time =~ ^[0-9]+$ ]] || die "invalid BRAID commit time"
  suffix="git.${commit_time}.${actual_commit:0:12}"
  version="${version}+${suffix}"
  artifact_version="${artifact_version}+${suffix}"
  source_commit=$actual_commit
  source_changed=true
fi

candidate="$dist_root/$component-v$artifact_version"
package_version=$(field package_version) || die "missing package_version in $config"
if [[ $source_changed == true ]]; then package_version=$version; fi
deb=$(artifact_filename "$component" package "$artifact_version") || die "no package artifact name for $component"
agent=
browser=
zip=
native_deb=
native_zip=
xdeb=
native_x_deb=
case $component in
  habit)
    agent=$(artifact_filename habit agent "$artifact_version")
    browser=$(artifact_filename habit browser "$artifact_version")
    native_deb="habit-content_${package_version}_amd64.deb"
    ;;
  braid)
    zip=$(artifact_filename braid agent "$artifact_version")
    xdeb=$(artifact_filename braid x "$artifact_version")
    native_deb="braid-server_${package_version}_amd64.deb"
    native_zip="braid-agent_${version}_windows_amd64.zip"
    native_x_deb="braid-x_${version}_amd64.deb"
    ;;
esac

write_checksums() {
  local dir=$1 file hash
  : >"$dir/SHA256SUMS"
  shift
  for file in "$@"; do
    hash=$(shasum -a 256 "$dir/$file" | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$file" >>"$dir/SHA256SUMS"
  done
}

artifact_hash() {
  awk -v name="$1" '$2 == name {print $1}' "$2/SHA256SUMS"
}

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
  [[ $(jq -r '.artifact_version' "$manifest") == "$artifact_version" ]] || die "manifest artifact version mismatch"
  [[ $(jq -r '.package_version' "$manifest") == "$package_version" ]] || die "manifest package version mismatch"
  [[ $(jq -r '.artifacts | length' "$manifest") == 3 ]] || die "unexpected HABIT artifact count in manifest"
  (cd "$candidate" && shasum -a 256 -c SHA256SUMS) || die "artifact checksum failed"
  for file in "$deb" "$agent" "$browser"; do
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
  pe_check "$candidate/$agent"
  pe_check "$candidate/$browser"
  printf 'verified %s %s (%s)\n' "$component" "$expected_version" "$expected_commit"
}

verify_braid_candidate() {
  local expected_commit=$1 expected_version=$2 manifest="$candidate/manifest.json" hash actual metadata has_x
  for command in debpack jq shasum file tar unzip zipinfo; do command -v "$command" >/dev/null || die "required verification tool missing: $command"; done
  [[ -d $candidate ]] || die "candidate missing: $candidate"
  [[ -s $manifest && -s $candidate/SHA256SUMS && -s $candidate/$deb && -s $candidate/$zip ]] || die "BRAID package, agent ZIP, manifest, or checksums missing"
  [[ $(jq -r '.source.commit' "$manifest") == "$expected_commit" ]] || die "manifest source commit mismatch"
  [[ $(jq -r '.component' "$manifest") == "$component" ]] || die "manifest component mismatch"
  [[ $(jq -r '.version' "$manifest") == "$expected_version" ]] || die "manifest version mismatch"
  [[ $(jq -r '.artifact_version' "$manifest") == "$artifact_version" ]] || die "manifest artifact version mismatch"
  [[ $(jq -r '.package_version' "$manifest") == "$package_version" ]] || die "manifest package version mismatch"
  has_x=$(jq -r --arg name "$xdeb" 'any(.artifacts[]; .filename == $name)' "$manifest")
  if [[ $has_x == true ]]; then
    [[ $(jq -r '.artifacts | length' "$manifest") == 3 && -s $candidate/$xdeb ]] || die "BRAID x package or manifest entry missing"
  else
    [[ $(jq -r '.artifacts | length' "$manifest") == 2 ]] || die "unexpected BRAID artifact count in manifest"
  fi
  (cd "$candidate" && shasum -a 256 -c SHA256SUMS) || die "artifact checksum failed"
  for file in "$deb" "$zip"; do
    hash=$(shasum -a 256 "$candidate/$file" | awk '{print $1}')
    actual=$(jq -r --arg name "$file" '.artifacts[] | select(.filename == $name) | .sha256' "$manifest")
    [[ $hash == "$actual" ]] || die "manifest checksum mismatch: $file"
  done
  if [[ $has_x == true ]]; then
    hash=$(shasum -a 256 "$candidate/$xdeb" | awk '{print $1}')
    actual=$(jq -r --arg name "$xdeb" '.artifacts[] | select(.filename == $name) | .sha256' "$manifest")
    [[ $hash == "$actual" ]] || die "manifest checksum mismatch: $xdeb"
    debpack verify "$candidate/$xdeb" >/dev/null || die "BRAID x package verification failed"
    metadata=$(debpack inspect "$candidate/$xdeb") || die "cannot inspect BRAID x package"
    jq -e --arg version "$expected_version" '
      .package.Package == "braid-x" and .package.Version == $version and .package.Architecture == "amd64" and
      any(.payload[]; .name == "usr/bin/x" and .mode == "0755") and
      any(.payload[]; .name == "usr/share/doc/braid-x/README" and .mode == "0644") and
      any(.payload[]; .name == "usr/share/doc/braid-x/agent.json.example" and .mode == "0644") and
      ([.payload[] | select(.name | endswith(".pem") or endswith(".key"))] | length == 0)
    ' <<<"$metadata" >/dev/null || die "BRAID x package metadata or contents do not match packaging contract"
  fi

  debpack verify "$candidate/$deb" >/dev/null || die "Debian package verification failed"
  metadata=$(debpack inspect "$candidate/$deb") || die "cannot inspect BRAID Debian package"
  jq -e --arg version "$package_version" '
    .package.Package == "braid-server" and
    .package.Version == $version and
    .package.Architecture == "amd64" and
    .package.Depends == "adduser, bash, systemd, init-system-helpers" and
    any(.payload[]; .name == "usr/bin/braid-server" and .mode == "0755") and
    any(.payload[]; .name == "usr/lib/systemd/system/braid-server.service" and .mode == "0644") and
    any(.payload[]; .name == "usr/share/braid/server.json" and .mode == "0644") and
    any(.control_files[]; . == "preinst") and
    any(.control_files[]; . == "postinst") and
    any(.control_files[]; . == "prerm") and
    any(.control_files[]; . == "postrm")
  ' <<<"$metadata" >/dev/null || die "BRAID package metadata or contents do not match packaging contract"

  mkdir -p "$root/work"
  verify_tmp_dir=$(mktemp -d "$root/work/braid-verify.XXXXXX")
  trap 'if [[ -n ${verify_tmp_dir:-} ]]; then rm -rf -- "$verify_tmp_dir"; verify_tmp_dir=; fi' RETURN
  tar -xOf "$candidate/$deb" data.tar.gz | tar -xzOf - usr/bin/braid-server >"$verify_tmp_dir/braid-server"
  local description
  description=$(file -b "$verify_tmp_dir/braid-server") || die "cannot inspect BRAID server ELF"
  [[ $description == *"ELF 64-bit LSB executable, x86-64"* && $description == *"statically linked"* ]] || die "unexpected BRAID server ELF or runtime dependencies: $description"
  if [[ $has_x == true ]]; then
    tar -xOf "$candidate/$xdeb" data.tar.gz | tar -xzOf - usr/bin/x >"$verify_tmp_dir/x"
    description=$(file -b "$verify_tmp_dir/x") || die "cannot inspect BRAID x ELF"
    [[ $description == *"ELF 64-bit LSB executable, x86-64"* && $description == *"statically linked"* ]] || die "unexpected BRAID x ELF or runtime dependencies: $description"
  fi
  unzip -tq "$candidate/$zip" >/dev/null || die "BRAID agent ZIP integrity check failed"
  if [[ $has_x == true ]]; then
    [[ $(zipinfo -1 "$candidate/$zip" | LC_ALL=C sort | tr '\n' ' ') == "README.txt SHA256SUMS braid-agent.exe version.txt x.exe " ]] || die "synchronized Windows ZIP must include x.exe"
  else
    [[ $(zipinfo -1 "$candidate/$zip" | LC_ALL=C sort | tr '\n' ' ') == "README.txt SHA256SUMS braid-agent.exe version.txt " ]] || die "unexpected BRAID agent ZIP contents"
  fi
  unzip -p "$candidate/$zip" braid-agent.exe >"$verify_tmp_dir/braid-agent.exe"
  pe_check "$verify_tmp_dir/braid-agent.exe"
  local agent_hash x_hash zip_hashes
  agent_hash=$(shasum -a 256 "$verify_tmp_dir/braid-agent.exe" | awk '{print $1}')
  zip_hashes=$(unzip -p "$candidate/$zip" SHA256SUMS)
  if [[ $has_x == true ]]; then
    unzip -p "$candidate/$zip" x.exe >"$verify_tmp_dir/x.exe"
    pe_check "$verify_tmp_dir/x.exe"
    x_hash=$(shasum -a 256 "$verify_tmp_dir/x.exe" | awk '{print $1}')
    [[ $zip_hashes == "$agent_hash  braid-agent.exe"$'\n'"$x_hash  x.exe" ]] || die "BRAID Windows executable checksum mismatch"
  else
    [[ $zip_hashes == "$agent_hash  braid-agent.exe" ]] || die "BRAID agent ZIP internal checksum mismatch"
  fi
  [[ $(unzip -p "$candidate/$zip" version.txt) == "$(printf 'version=%s\ncommit=%s\ntarget=windows/amd64' "$expected_version" "${expected_commit:0:12}")" ]] || die "BRAID agent version or commit provenance mismatch"
  printf 'verified %s %s (%s)\n' "$component" "$expected_version" "$expected_commit"
}

verify_candidate() {
  case $component in
    habit) verify_habit_candidate "$@" ;;
    braid) verify_braid_candidate "$@" ;;
  esac
}

case $action in
  --verify)
    verify_candidate "$actual_commit" "$version"
    ;;
  --build)
    if [[ $component == habit ]]; then
      for command in go debpack jq shasum file tar; do command -v "$command" >/dev/null || die "required tool missing: $command"; done
      [[ $(go version) == 'go version go1.27.2 darwin/amd64' ]] || die "HABIT release requires Go 1.27.2 on darwin/amd64"
    elif [[ $component == braid ]]; then
      for command in go debpack jq shasum file tar unzip zipinfo git; do command -v "$command" >/dev/null || die "required tool missing: $command"; done
      [[ $(go version) == 'go version go1.27.2 darwin/amd64' ]] || die "BRAID release requires Go 1.27.2 on darwin/amd64"
      [[ $(uname -s) == Darwin && $(uname -m) == x86_64 ]] || die "BRAID release requires an Intel Mac"
    fi
    [[ ! -e $candidate ]] || die "candidate already exists: $candidate; remove it manually after review"
    mkdir -p "$root/work" "$dist_root"
    tmp=$(mktemp -d "$root/work/$component.XXXXXX")
    cleanup() {
      rm -rf -- "$tmp"
      if [[ -n ${braid_snapshot:-} ]]; then
        git -C "$source" worktree remove --force "$braid_snapshot" >/dev/null 2>&1 || true
        rm -rf -- "$braid_snapshot"
      fi
    }
    trap cleanup EXIT

    mkdir -p "$tmp/candidate"
    if [[ $component == habit ]]; then
      (cd "$source" && GOTOOLCHAIN=local go test ./...)
      (cd "$source" && GOTOOLCHAIN=local go vet ./...)
      # Build binaries in source checkout to retain Go's source provenance metadata.
      (cd "$source" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags='-s -w -buildid=' -o "$tmp/habit-agent.exe" ./cmd/habit-agent)
      (cd "$source" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -tags=browser -trimpath -ldflags='-s -w -buildid=' -o "$tmp/habit-agent-browser.exe" ./cmd/habit-agent)
      # Package in a source snapshot so HABIT's script cannot overwrite its ignored build/ or dist/ files.
      git -C "$source" archive "$source_commit" | tar -x -C "$tmp"
      (cd "$tmp" && GOTOOLCHAIN=local packaging/build-content-deb.sh "$tmp/out")
      install -m 0644 "$tmp/out/$native_deb" "$tmp/candidate/$deb"
      install -m 0644 "$tmp/habit-agent.exe" "$tmp/candidate/$agent"
      install -m 0644 "$tmp/habit-agent-browser.exe" "$tmp/candidate/$browser"
      write_checksums "$tmp/candidate" "$deb" "$agent" "$browser"
    else
      braid_snapshot=$(mktemp -d "${TMPDIR:-/tmp}/purple-dist-braid.XXXXXX")
      git -C "$source" worktree add --detach "$braid_snapshot" "$source_commit" >/dev/null
      (cd "$braid_snapshot" && GOTOOLCHAIN=local go test ./...)
      (cd "$braid_snapshot" && GOTOOLCHAIN=local go vet ./...)
      (cd "$braid_snapshot" && GOTOOLCHAIN=local go run ./cmd/braid-release build --version "$version" --out "$tmp/out")
      git -C "$source" worktree remove --force "$braid_snapshot" >/dev/null
      braid_snapshot=
      install -m 0644 "$tmp/out/$native_deb" "$tmp/candidate/$deb"
      install -m 0644 "$tmp/out/$native_zip" "$tmp/candidate/$zip"
      install -m 0644 "$tmp/out/$native_x_deb" "$tmp/candidate/$xdeb"
      write_checksums "$tmp/candidate" "$deb" "$zip" "$xdeb"
    fi
    built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    go_version=$(go version)
    if [[ $component == habit ]]; then
      jq -n \
        --arg component "$component" --arg version "$version" --arg commit "$actual_commit" \
        --arg artifact_version "$artifact_version" --arg package_version "$package_version" \
        --arg built_at "$built_at" --arg environment "$(uname -s)/$(uname -m)" --arg go "$go_version" \
        --arg deb "$deb" --arg agent "$agent" --arg browser "$browser" \
        --arg deb_hash "$(artifact_hash "$deb" "$tmp/candidate")" \
        --arg agent_hash "$(artifact_hash "$agent" "$tmp/candidate")" \
        --arg browser_hash "$(artifact_hash "$browser" "$tmp/candidate")" \
        '{component:$component,version:$version,artifact_version:$artifact_version,package_version:$package_version,source:{commit:$commit},build:{timestamp_utc:$built_at,host:$environment,go:$go},artifacts:[{filename:$deb,architecture:"amd64",sha256:$deb_hash},{filename:$agent,architecture:"windows/amd64",sha256:$agent_hash},{filename:$browser,architecture:"windows/amd64",sha256:$browser_hash}]}' \
        >"$tmp/candidate/manifest.json"
    else
      jq -n \
        --arg component "$component" --arg version "$version" --arg commit "$actual_commit" \
        --arg artifact_version "$artifact_version" --arg package_version "$package_version" \
        --arg built_at "$built_at" --arg environment "$(uname -s)/$(uname -m)" --arg go "$go_version" \
        --arg deb "$deb" --arg zip "$zip" --arg xdeb "$xdeb" \
        --arg deb_hash "$(artifact_hash "$deb" "$tmp/candidate")" \
        --arg zip_hash "$(artifact_hash "$zip" "$tmp/candidate")" \
        --arg x_hash "$(artifact_hash "$xdeb" "$tmp/candidate")" \
        '{component:$component,version:$version,artifact_version:$artifact_version,package_version:$package_version,source:{commit:$commit},build:{timestamp_utc:$built_at,host:$environment,go:$go,packager:"braid-release"},artifacts:[{filename:$deb,architecture:"amd64",sha256:$deb_hash},{filename:$zip,architecture:"windows/amd64",sha256:$zip_hash},{filename:$xdeb,architecture:"amd64",sha256:$x_hash}]}' \
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
    pin_file="$repo_root/purple/ansible/roles/purple_artifacts/files/components.lock.yml"
    sync_pins=false
    if [[ $component == braid ]]; then
      jq -e --arg name "$xdeb" 'any(.artifacts[]; .filename == $name)' "$candidate/manifest.json" >/dev/null || die "cannot publish a BRAID release without the synchronized x package"
      [[ -f $pin_file ]] || die "PURPLE component lock is missing: $pin_file"
      git -C "$repo_root/purple" rev-parse --show-toplevel >/dev/null || die "PURPLE checkout is not a Git repository"
      pin_status=$(git -C "$repo_root/purple" status --porcelain -- ansible/roles/purple_artifacts/files/components.lock.yml) || die "cannot inspect PURPLE component lock"
      [[ -z $pin_status ]] || die "PURPLE component lock has local changes; preserve them before publishing"
      sync_pins=true
    fi
    tag="$component/v$artifact_version"
    if gh release view "$tag" --repo crgr/purple-dist >/dev/null 2>&1; then die "release already exists: $tag"; fi
    if [[ -n $(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}") ]]; then die "release tag already exists: $tag"; fi
    if [[ $component == habit ]]; then
      assets=("$candidate/$deb" "$candidate/$agent" "$candidate/$browser")
      asset_names=("$deb" "$agent" "$browser")
    elif [[ $component == braid ]]; then
      assets=("$candidate/$deb" "$candidate/$zip")
      asset_names=("$deb" "$zip")
      if jq -e --arg name "$xdeb" 'any(.artifacts[]; .filename == $name)' "$candidate/manifest.json" >/dev/null; then
        assets+=("$candidate/$xdeb")
        asset_names+=("$xdeb")
      fi
    fi
    distribution_commit=$(git -C "$root" rev-parse HEAD)
    notes="Verified $component v$artifact_version from source commit $actual_commit."
    case $component in
      habit) notes+=" Includes the content-server Debian package and standard and browser-enabled Windows agents. Debian installation and systemd lifecycle tests were not run." ;;
      braid) notes+=" Includes the server Debian package and Windows agent ZIP; newer candidates also include braid-x. Debian installation and systemd lifecycle tests were not run." ;;
    esac
    gh release create "$tag" "${assets[@]}" "$candidate/SHA256SUMS" "$candidate/manifest.json" \
      --repo crgr/purple-dist --target "$distribution_commit" --title "$component v$artifact_version" --notes "$notes"
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
    if [[ $sync_pins == true ]]; then
      "$root/scripts/sync-braid-pins.sh" "$download_dir" "$artifact_version" "$pin_file"
    fi
    ;;
esac
