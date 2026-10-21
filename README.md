# purple-dist

`purple-dist` coordinates local builds from the private sibling repositories in
`~/dev/gh/`, verifies release candidates, and publishes selected artifacts as
anonymous GitHub Release downloads. It never checks out source from GitHub.
HABIT, BRAID, and TABU builds are enabled. Each application repository owns
its build and packaging logic; `purple-dist` stages, verifies, and publishes
the selected outputs.

Run from this repository:

```sh
./release.sh --help
./release.sh habit --build
./release.sh habit --verify
./release.sh habit --publish
./release.sh tabu --build
./release.sh tabu --verify
./release.sh braid --build
./release.sh braid --verify
./tests/test-artifact-names.sh
```

Build and verification need Go 1.27.2 for Intel macOS, `debpack`, `jq`, `file`,
`tar`, `shasum`, and Git. TABU also uses `make`. They do not require
GitHub credentials. Builds require the exact clean source revision pinned in
the config. BRAID also needs `unzip` and `zipinfo`. HABIT runs its Go tests and
vet, then its release builds and Debian packaging script. TABU runs `make check`
in a temporary source snapshot; this includes its tests, vet, SQLite behavior
tests, and Linux amd64 cross-build with `CGO_ENABLED=0`. Its own packaging script
assembles the `.deb` with `debpack`. BRAID runs tests and vet in a detached
worktree at the pinned commit, then invokes its native `braid-release` command
to produce the Debian server and Windows agent ZIP. Its current pin has no exact
source tag, so its version is the native builder's documented commit-derived
fallback, `0.0.0+git.97b071fa8eee`; its public artifact version is `0.1.0`.
These builds do not need a Linux host, Docker,
or `dpkg-deb`. Candidates appear under ignored `dist/<component>-v<version>/`;
temporary files appear under ignored `work/`. The manifest records the full
source commit, build host and Go toolchain, timestamp, target architectures,
filenames, and SHA256 values.
Release executables use `-trimpath` and strip symbol, DWARF, and Go build-ID
data while retaining application version metadata where provided.

Public asset names use `<component>-v<artifact_version>_<architecture>`, with
Windows targets marked `_windows_amd64`. For example, the current outputs are
`habit-content-v0.1.0_amd64.deb`, `habit-agent-v0.1.0_windows_amd64.exe`,
`habit-agent-browser-v0.1.0_windows_amd64.exe`, `braid-v0.1.0_amd64.deb`,
`braid-agent-v0.1.0_windows_amd64.zip`, and `tabu-v0.1.0_amd64.deb`. Native
packaging names and Debian `Version` metadata remain unchanged. `version` and
`package_version` in the manifest preserve the application/package provenance;
`artifact_version` records the clean version used in filenames. Existing
candidates with the previous filenames are retained under their old paths.

The source pin for HABIT is `e93647ae39dc02556185c86b54a1e3395dddc32f`.
Its release version follows the existing package metadata:
`0.1.0-m4.5+git021f365`. The Debian package version includes its Debian
revision, `-1`. Release tags use `<component>/v<artifact_version>`, such as
`habit/v0.1.0`.

Publishing requires GitHub CLI (`gh`) authenticated with a fine-grained token
restricted to `crgr/purple-dist`, with repository **Contents: read and write**
permission. Authenticate with `gh auth login --hostname github.com`; keep the
token in the CLI credential store or `GH_TOKEN`, never in this repository.
Publish re-verifies the candidate, refuses an existing release tag, uploads
only the selected component's artifacts, checksums, and manifest, then downloads
each asset over anonymous HTTPS and checks its hash against the candidate.

## Integration findings

| Component | Pinned revision | Owning build interface | Release notes |
| --- | --- | --- | --- |
| HABIT | `e93647ae39dc02556185c86b54a1e3395dddc32f` | `go test ./...`, `go vet ./...`, documented Windows release builds, `packaging/build-content-deb.sh` using `debpack` | Go 1.27.2; amd64 Debian package and Windows amd64 agents; version is existing package metadata. |
| BRAID | `97b071fa8eeccc4ea7fbcc170e01a91333ebce0c` | `go test ./...`, `go vet ./...`; `go run ./cmd/braid-release build` | Release command builds an amd64 Debian server and Windows amd64 agent ZIP. It requires Intel macOS and `debpack`. No exact source tag exists; internal version `0.0.0+git.97b071fa8eee` follows the command's commit-derived fallback; public artifact version is `0.1.0`. |
| TABU | `8a3aa83b8c1b8abe367dda1b7a6693511b269bfa` | `make check`; `packaging/build-deb.sh` using `debpack` | Release adds DNS tunnel, beacon, and DGA detection. Pure-Go `modernc.org/sqlite`; Go 1.27.2 builds a static Linux amd64 executable with CGO disabled. Internal package version `0.2.0~dns+git8a3aa83b8c1` follows the native packager; public artifact version is `0.2.0`. The release script builds from a temporary source snapshot. |

The earlier HABIT Debian candidate hash matches its fresh build in this
checkpoint. TABU package assembly and structural verification run natively with
`debpack`; Debian installation and systemd lifecycle testing require a
disposable Debian environment and were not run. No package was installed on
the host.

The supplied Windows reference hashes came from Go build metadata revision
`c883f40a65557e4e73e6364ca31e77c8673dbd91`, while this build uses
`e93647ae39dc02556185c86b54a1e3395dddc32f`. The intervening `021f365`
commit changed `internal/content/content.go` and its tests to serve distinct
sites by hostname. Thus the Windows hash differences reflect changed source
and embedded Git provenance. Repeated builds from the pinned current revision
produce identical artifact hashes.
