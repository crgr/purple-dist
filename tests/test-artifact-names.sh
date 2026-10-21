#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/artifact-names.sh
source "$root/scripts/artifact-names.sh"

check() {
  local component=$1 kind=$2 version=$3 expected=$4 actual
  actual=$(artifact_filename "$component" "$kind" "$version")
  [[ $actual == "$expected" ]] || {
    printf 'expected %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

check tabu package 0.2.0 tabu-v0.2.0_amd64.deb
check braid package 0.1.0 braid-v0.1.0_amd64.deb
check braid agent 0.1.0 braid-agent-v0.1.0_windows_amd64.zip
check habit package 0.1.0 habit-content-v0.1.0_amd64.deb
check habit agent 0.1.0 habit-agent-v0.1.0_windows_amd64.exe
check habit browser 0.1.0 habit-agent-browser-v0.1.0_windows_amd64.exe
if artifact_filename tabu browser 0.1.0 >/dev/null; then
  echo 'unsupported artifact kind was accepted' >&2
  exit 1
fi
printf 'artifact filename tests passed\n'
