#!/usr/bin/env bash

artifact_filename() {
  local component=$1 kind=$2 version=$3
  case "$component:$kind" in
    habit:package) printf 'habit-content-v%s_amd64.deb\n' "$version" ;;
    habit:agent) printf 'habit-agent-v%s_windows_amd64.exe\n' "$version" ;;
    habit:browser) printf 'habit-agent-browser-v%s_windows_amd64.exe\n' "$version" ;;
    braid:package) printf 'braid-v%s_amd64.deb\n' "$version" ;;
    braid:agent) printf 'braid-agent-v%s_windows_amd64.zip\n' "$version" ;;
    *) return 1 ;;
  esac
}
