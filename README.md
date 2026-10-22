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

Current BRAID pin is `3d5bd9fc5507dd8edf33af2e74e66c3495afc220`. Public artifact and
internal Debian/binary version are both `0.2.1`. This release makes `zeek` the
canonical native collector config key and retains `tabu` as a deprecated input
alias. Both keys in one config are rejected. After upgrading the package, use
`braid-server config normalize --config /etc/braid/server.json --write` to
atomically rename the old key while preserving other bytes, mode and ownership;
repeated runs leave canonical configs untouched. Upgrade before changing the key,
because artifact 0.2.0's executable and package scripts only understand `tabu`.
No schema migration is added; agent delivery protocol remains 2.

Publishing requires GitHub CLI (`gh`) authenticated with a fine-grained token
restricted to `crgr/purple-dist`, with repository **Contents: read and write**
permission. Keep the token in the CLI credential store or `GH_TOKEN`, never in
this repository. Publishing re-verifies the candidate, refuses an existing
release tag, uploads only selected artifacts, checksums, and manifest, then
checks each asset over anonymous HTTPS.

| Component | Pinned revision | Build interface | Release notes |
| --- | --- | --- | --- |
| HABIT | `0421598e40806e241698a4d015d931531d49a708` | Go tests and vet; `packaging/build-content-deb.sh` using `debpack` | Existing package version; amd64 Debian package and standard and browser-enabled Windows agents. |
| BRAID | `3d5bd9fc5507dd8edf33af2e74e66c3495afc220` | Go tests and vet; `go run ./cmd/braid-release build` | Intel macOS and `debpack`; amd64 Debian server and Windows amd64 agent ZIP; canonical `zeek` config, legacy `tabu` alias and idempotent config normalization. |

Debian installation and systemd lifecycle testing require a disposable Debian
environment. No package is installed on the build host.
