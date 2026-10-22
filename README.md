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

Current BRAID pin is `c2de9a5ce26e0ea680bf655d6826a866cb364d0f`. Public artifact and
internal Debian/binary version are both `0.2.2`. Native collector configuration,
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

| Component | Pinned revision | Build interface | Release notes |
| --- | --- | --- | --- |
| HABIT | `0421598e40806e241698a4d015d931531d49a708` | Go tests and vet; `packaging/build-content-deb.sh` using `debpack` | Existing package version; amd64 Debian package and standard and browser-enabled Windows agents. |
| BRAID | `c2de9a5ce26e0ea680bf655d6826a866cb364d0f` | Go tests and vet; `go run ./cmd/braid-release build` | Intel macOS and `debpack`; amd64 Debian server and Windows amd64 agent ZIP; Zeek/DNS operator wording, silent saved-config compatibility and idempotent config normalization. |

Debian installation and systemd lifecycle testing require a disposable Debian
environment. No package is installed on the build host.
