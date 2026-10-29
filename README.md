# purple-dist

`purple-dist` builds releases from pinned local application repositories,
verifies candidates, and publishes selected artifacts as anonymous GitHub
Release downloads. Application repositories own their build and packaging
logic. This factory currently supports HABIT and BRAID.

```sh
./release.sh --help
./release.sh habit --build
./release.sh habit --verify
./release.sh habit --publish
./release.sh braid --build
./release.sh braid --verify
./release.sh braid --publish
./tests/test-artifact-names.sh
./tests/test-braid-source-sync.sh
./tests/test-braid-pin-sync.sh
```

Builds require Go 1.27.2 on Intel macOS, `debpack`, `jq`, `file`, `tar`,
`shasum`, and Git. BRAID also needs `unzip` and `zipinfo`. Builds and
verification need no GitHub credentials. Both pipelines require the exact
clean source trees. HABIT requires its configured source revision. When BRAID's
clean HEAD advances from the configured revision, the factory automatically builds
the new commit with a Git timestamp/revision suffix on all component versions.
Non-descendant BRAID revisions require an explicit pin update.
HABIT runs its tests, vet, and
native Debian packaging. BRAID runs tests and vet in a detached worktree, then
uses its native `braid-release` command to package the Debian server, standalone
`braid-x` Debian package and Windows agent ZIP. Historical candidates without
`braid-x` remain verifiable; building a new candidate requires a BRAID source
revision that produces it. BRAID now includes native Zeek DNS tunnel, beacon, and DGA
analysis. These builds need no Linux host, Docker, or `dpkg-deb`.

Candidates appear under ignored `dist/<component>-v<artifact_version>/`;
temporary files appear under ignored `work/`. Each manifest records the full
source commit, build host and Go toolchain, timestamp, target architectures,
artifact names, and SHA256 digests. Public artifact names use
`<component>-v<artifact_version>_<architecture>`, with Windows assets marked
`_windows_amd64`. Native package names and internal Debian versions remain
unchanged. Release executables use `-trimpath` and strip symbols, DWARF, and Go
build IDs while retaining application version metadata where provided.

Current BRAID pin is `2ce15d2ab828a89f81833ec4e240def43c3e7694`. Public artifact and
internal Debian/binary version are both `0.2.4`. This release adds the host-grouped
event and finding timeline at `/lanes`, compact Exercises and Administration menus,
and an embedded BRAID favicon. The latest source adds synchronized operator
command markers and standalone `x` clients for Linux and Windows. Read-only
administration entry paths redirect to Exercise management. Native collector configuration,
commands, status and operator documentation use `zeek`. Existing saved configs
continue working silently. After upgrading the package, use
`braid-server config normalize --config /etc/braid/server.json --write` for an
atomic, idempotent normalization that preserves all other bytes, mode and ownership.
Upgrade before changing an existing config, so older package scripts can read it.
No schema migration is added; agent delivery protocol remains 2.

Publishing requires GitHub CLI (`gh`) authenticated with a fine-grained token
restricted to `crgr/purple-dist`, with repository **Contents: read and write**
permission. Keep the token in the CLI credential store or `GH_TOKEN`, never in
this repository. Publishing re-verifies the candidate, refuses an existing
release tag, uploads only selected artifacts, checksums, and manifest, then
checks each asset over anonymous HTTPS.

Publishing a complete BRAID release then atomically updates the local PURPLE
component lock for the server, Windows agent (including Windows `x`) and Linux
`braid-x`, using the verified published hashes and one source revision. A locally
modified PURPLE lock blocks publication so it is never overwritten. Review and
commit the synchronized PURPLE lock, refresh the Ludus Source, then deploy the
matching roles; publication does not deploy the range.

| Component | Pinned revision | Build interface | Release notes |
| --- | --- | --- | --- |
| HABIT | `0421598e40806e241698a4d015d931531d49a708` | Go tests and vet; `packaging/build-content-deb.sh` using `debpack` | Existing package version; amd64 Debian package and standard and browser-enabled Windows agents. |
| BRAID | `2ce15d2ab828a89f81833ec4e240def43c3e7694` | Go tests and vet; `go run ./cmd/braid-release build` | Intel macOS and `debpack`; amd64 Debian server and Windows amd64 agent ZIP; host-grouped event and finding timeline, compact navigation, embedded favicon, and synchronized operator command markers with standalone `x` clients. |

Debian installation and systemd lifecycle testing require a disposable Debian
environment. No package is installed on the build host.
