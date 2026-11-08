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

Current BRAID pin is `c4dbae0d6d3c5735f652ccdcb5be7d9af7602025`, version `0.6.2`. BRAID owns its packager,
`packaging/braid-release`, and its Debian inputs in `packaging/debian`. For a new BRAID
release, set `commit` to the clean BRAID HEAD and bump `version`, `artifact_version` and
`package_version` to the next patch number; a HEAD that only descends from the pin gets the
`+git.<time>.<revision>` suffix instead.

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
| BRAID | `c4dbae0d6d3c5735f652ccdcb5be7d9af7602025` | Go tests and vet; `go run ./packaging/braid-release build` | Intel macOS and `debpack`; amd64 Debian server, standalone `braid-x` Debian package, and Windows amd64 ZIP with the agent and `x.exe`. |

Debian installation and systemd lifecycle testing require a disposable Debian
environment. No package is installed on the build host.
