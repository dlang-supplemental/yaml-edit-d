# Agent notes: yaml-edit-d

Project facts for agents. Workstation/env facts live only in `$CODE_ROOT/MEMORIES.md`.

- DUB package name is `yaml-edit`; GitHub repo is `dlang-supplemental/yaml-edit-d`; build with LDC
- Primary API: `module yaml_edit` (`Document`, `NodeRef`), a lossless line CST; untouched bytes must round-trip identically
- `yaml_edit.compat.dyaml` is a thin D-YAML drop-in layer; keep D-YAML names there only, idiomatic names in the core
- `dyaml` is a test-only dependency (`unittest` configuration) used as an oracle; never add it to the library configuration
- Tests: `dub test --compiler=ldc2`; fixtures in `tests/fixtures` are byte-exact (`-text` in .gitattributes)
- Upstream plan: `docs/upstream-plan.adoc`; do not open upstream issues or PRs without the maintainer's say-so
- Categories: `library.data`, `library.development.parsing`; publish via sibling `dub-publish` on a `v*` tag only
