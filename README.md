# purple-dist

`purple-dist` coordinates local builds from the private sibling repositories in
`~/dev/gh/`, verifies release candidates, and publishes selected artifacts as
anonymous GitHub Release downloads. It never checks out source from GitHub.
HABIT is the only enabled build in this checkpoint. BRAID and TABU pins and
their owning build interfaces are recorded in [config/sources.yml](config/sources.yml).

Run from this repository:

```sh
./release.sh --help
./release.sh habit --build
./release.sh habit --verify
./release.sh habit --publish
```

Build and verification need Go 1.27.2 for Intel macOS, `debpack`, `jq`, `file`,
`tar`, `shasum`, and Git. They do not use or require GitHub credentials. Build
requires the exact clean source revision pinned in the config. It runs HABIT's
Go tests and vet, then its documented release builds and Debian packaging
script. Output appears under ignored `dist/habit-v<version>/`; temporary files
appear under ignored `work/`. The manifest records the full source commit,
build host and Go toolchain, timestamp, target architectures, filenames, and
SHA256 values.

The source pin for HABIT is `e93647ae39dc02556185c86b54a1e3395dddc32f`.
Its release version follows the existing package metadata:
`0.1.0-m4.5+git021f365`. The Debian package version includes its Debian
revision, `-1`. A release tag is `habit-v0.1.0-m4.5+git021f365`.

Publishing requires GitHub CLI (`gh`) authenticated with a fine-grained token
restricted to `crgr/purple-dist`, with repository **Contents: read and write**
permission. Authenticate with `gh auth login --hostname github.com`; keep the
token in the CLI credential store or `GH_TOKEN`, never in this repository.
Publish re-verifies the candidate, refuses an existing release tag, uploads
only the three binaries, checksums, and manifest, then downloads each asset
over anonymous HTTPS and checks its hash against the candidate.

## Integration findings

| Component | Pinned revision | Owning build interface | Release notes |
| --- | --- | --- | --- |
| HABIT | `e93647ae39dc02556185c86b54a1e3395dddc32f` | `go test ./...`, `go vet ./...`, documented Windows release builds, `packaging/build-content-deb.sh` using `debpack` | Go 1.27.2; amd64 Debian package and Windows amd64 agents; version is existing package metadata. |
| BRAID | `97b071fa8eeccc4ea7fbcc170e01a91333ebce0c` | `go test ./...`; `go run ./cmd/braid-release build` | Release command builds amd64 Debian server and a Windows amd64 agent ZIP containing `braid-agent.exe`. It requires Intel macOS and `debpack`. No source tag exists; config records the command's exact-commit fallback version. |
| TABU | `acc2a84dfe2a439e3b5edda1f6d9ed1663dcb2ad` | `make check`; `packaging/build-deb.sh` | Candidate pin matches the supplied standalone revision. Package build needs Linux amd64, Go 1.27.2, CGO, GCC/libc headers, and `dpkg-deb`; it currently defaults to a sibling PURPLE output path. Do not select the pin for publication before Linux package validation. |

The previous Debian candidate hash matches the fresh build in this checkpoint.
Debian lifecycle installation was not run: no disposable Debian 13 environment
is available, and Docker is installed without a running daemon. No package was
installed on the host.

The supplied Windows reference hashes came from Go build metadata revision
`c883f40a65557e4e73e6364ca31e77c8673dbd91`, while this build uses
`e93647ae39dc02556185c86b54a1e3395dddc32f`. The intervening `021f365`
commit changed `internal/content/content.go` and its tests to serve distinct
sites by hostname. Thus the Windows hash differences reflect changed source
and embedded Git provenance. Repeated builds from the pinned current revision
produce identical artifact hashes.
