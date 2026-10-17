# purple-dist

`purple-dist` coordinates local builds from the private sibling repositories in
`~/dev/gh/`, verifies release candidates, and publishes selected artifacts as
anonymous GitHub Release downloads. It never checks out source from GitHub.
HABIT and TABU builds are enabled. BRAID's pin and owning build interface are
recorded for later integration in [config/sources.yml](config/sources.yml).

Run from this repository:

```sh
./release.sh --help
./release.sh habit --build
./release.sh habit --verify
./release.sh habit --publish
./release.sh tabu --build
./release.sh tabu --verify
```

Build and verification need Go 1.27.2 for Intel macOS, `debpack`, `jq`, `file`,
`tar`, `shasum`, and Git. TABU also uses `make`. They do not require
GitHub credentials. Builds require the exact clean source revision pinned in
the config. HABIT runs its Go tests and vet, then its release builds and Debian
packaging script. TABU runs `make check` in a temporary source snapshot; this
includes its tests, vet, SQLite behavior tests, and Linux amd64 cross-build with
`CGO_ENABLED=0`. Its own packaging script assembles the `.deb` with `debpack`.
Neither build needs a Linux host, Docker, or `dpkg-deb`. Candidates appear under
ignored `dist/<component>-v<version>/`; temporary files appear under ignored
`work/`. The manifest records the full source commit, build host and Go
toolchain, timestamp, target architectures, filenames, and SHA256 values.
Release executables use `-trimpath` and strip symbol, DWARF, and Go build-ID
data while retaining application version metadata where provided.

The source pin for HABIT is `e93647ae39dc02556185c86b54a1e3395dddc32f`.
Its release version follows the existing package metadata:
`0.1.0-m4.5+git021f365`. The Debian package version includes its Debian
revision, `-1`. A release tag is `habit-v0.1.0-m4.5+git021f365`.

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
| BRAID | `97b071fa8eeccc4ea7fbcc170e01a91333ebce0c` | `go test ./...`; `go run ./cmd/braid-release build` | Release command builds amd64 Debian server and a Windows amd64 agent ZIP containing `braid-agent.exe`. It requires Intel macOS and `debpack`. No source tag exists; config records the command's exact-commit fallback version. |
| TABU | `594ac463107b8fcfddec2cf27366882d9da2fc60` | `make check`; `packaging/build-deb.sh` using `debpack` | Pure-Go `modernc.org/sqlite` at the existing SQLite 3.53.4 version; Go 1.27.2 builds a static Linux amd64 executable with CGO disabled. Package version follows the source commit. The release script builds from a temporary source snapshot. |

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
