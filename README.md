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
```

Builds require Go 1.27.2 on Intel macOS, `debpack`, `jq`, `file`, `tar`,
`shasum`, and Git. BRAID also needs `unzip` and `zipinfo`. Builds and
verification need no GitHub credentials. Both pipelines require the exact
clean source revision in `config/sources.yml`. HABIT runs its tests, vet, and
native Debian packaging. BRAID runs tests and vet in a detached worktree, then
uses its native `braid-release` command to package the Debian server and
Windows agent ZIP. BRAID now includes native Zeek DNS tunnel, beacon, and DGA
analysis. These builds need no Linux host, Docker, or `dpkg-deb`.

Candidates appear under ignored `dist/<component>-v<artifact_version>/`;
temporary files appear under ignored `work/`. Each manifest records the full
source commit, build host and Go toolchain, timestamp, target architectures,
artifact names, and SHA256 digests. Public artifact names use
`<component>-v<artifact_version>_<architecture>`, with Windows assets marked
`_windows_amd64`. Native package names and internal Debian versions remain
unchanged. Release executables use `-trimpath` and strip symbols, DWARF, and Go
build IDs while retaining application version metadata where provided.

Current BRAID pin is `24542b69c52dd5519363e75ec830479d6dd74022`. Its native
builder has no exact source tag, so its internal version follows the builder's
commit-derived fallback, `0.0.0+git.24542b69c52d`. Public artifact version is
`0.2.0`; this release adds integrated Zeek DNS analysis to BRAID's existing
server and agent distribution.

Standalone TABU releases are retired. BRAID now owns the DNS analysis
functionality. Previously published TABU releases remain available as
historical releases; this factory no longer builds or publishes them.

Publishing requires GitHub CLI (`gh`) authenticated with a fine-grained token
restricted to `crgr/purple-dist`, with repository **Contents: read and write**
permission. Keep the token in the CLI credential store or `GH_TOKEN`, never in
this repository. Publishing re-verifies the candidate, refuses an existing
release tag, uploads only selected artifacts, checksums, and manifest, then
checks each asset over anonymous HTTPS.

| Component | Pinned revision | Build interface | Release notes |
| --- | --- | --- | --- |
| HABIT | `0421598e40806e241698a4d015d931531d49a708` | Go tests and vet; `packaging/build-content-deb.sh` using `debpack` | Existing package version; amd64 Debian package and standard and browser-enabled Windows agents. |
| BRAID | `24542b69c52dd5519363e75ec830479d6dd74022` | Go tests and vet; `go run ./cmd/braid-release build` | Intel macOS and `debpack`; amd64 Debian server and Windows amd64 agent ZIP; includes Zeek DNS analysis. |

Debian installation and systemd lifecycle testing require a disposable Debian
environment. No package is installed on the build host.
