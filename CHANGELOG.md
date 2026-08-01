# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Carve.parse` now publishes source positions.** Every block node the engine
  can place carries `pos` with `startLine`, `endLine`, `startColumn`,
  `endColumn`, `startOffset` and `endOffset`, as PART 12 section 4 spells it:
  lines and columns 1-based, offsets 0-based, all counted in Unicode
  codepoints, with `endColumn` and `endOffset` exclusive.

  The section lets an engine gate position TRACKING behind a parse option but
  not serialization, so the AST entry point turns tracking on. `to_html` and
  the other render paths do not, since they would pay for spans nobody reads.

  A node whose span carve-rs could not determine has no `pos` key at all,
  rather than one holding placeholder numbers. The same section requires that:
  an absent position is a fact a consumer can act on, an invented one is not.

  Inline nodes do not carry positions yet, because carve-rs does not track them
  (markup-carve/carve-rs#333). Against the spec's own conformance checker this
  takes carve-rb from 3413 findings to 2535 over the 507-document corpus, and
  what remains is almost entirely inline.

### Changed

- **BREAKING (AST JSON): node types and root field names now match the
  reference shape.** `Carve.parse` published names PART 12 does not describe,
  so a tree from this binding did not interoperate with carve-js or carve-php:

  | was | now |
  |---|---|
  | `critic_insert` / `critic_delete` / `critic_substitute` | `insert` / `delete` / `substitution` |
  | `footnote` (both forms) | `footnote_ref` / `inline_footnote` |
  | `ref_id` | `refId` |
  | `footnote_defs` | `footnoteDefs` |
  | `source_len` | `srcByteLength` |

  The three `critic_*` names and the footnote split are the spec vocabulary
  (docs/profiles.md); `footnote` there is the BLOCK definition type, so using
  it for the inline forms named three things with one identifier
  (markup-carve/carve#405).

### Changed

- Bump the carve-rs engine to `ef78fd5`, picking up two new AST node types.

- **Breaking (`Carve.parse`):** a backslash escape is now its own inline node,
  `{"type":"escaped_text","value":"-"}`, instead of being folded into the
  surrounding text. The backslash carries intent the character does not - an
  author writes `\-\-` precisely so a consumer will not render an en dash -
  and a walker that reads only `text` nodes now sees the run split at each
  escape (carve#350).

- **Breaking (`Carve.parse`):** a `::: |` fence is now `{"type":"line_block"}`
  instead of a `div` carrying a `.line-block` class. Inside the fence every
  newline is a hard break, which a plain div with that class does not imply, so
  the class alone could not say which one a node was (carve#359).

  Both are additive for a consumer with a default branch and a compile error for
  one without - this binding's walker matches exhaustively, which is why the
  bump and the arms have to land together. carve-hexapdf, the known downstream
  consumer, gained its `escaped_text` arm first (carve-hexapdf#9).

### Changed

- Bump the carve-rs engine to `6887f97`, picking up two language changes:
  superscript/subscript are now braced-only (bare `^x^` / `,x,` are literal
  text; the markup is `{^x^}` / `{,x,}`), and the `:name:` symbol inline was
  added (with a leading word-boundary guard, so `a:b:c`, `10:30:` and
  `me@example.com` stay literal).
- **Breaking (`Carve.parse`):** the inline node formerly emitted as
  `type: "emoji"` is now `type: "symbol"` and carries an `attrs` key, matching
  the engine's rename and the other implementations.
- **Breaking (`Carve.parse`):** a block extension's `summary` is now a list of
  inline nodes rather than a plain string, matching the admonition `title`
  shape (admonition titles are inline content).

## [0.1.0] - 2026-07-12

### Added

- Initial release: `Carve.to_html` exposes the carve-rs engine as a native
  Ruby extension (magnus + rb-sys), with the full extension/option surface,
  the static/print render mode, and pluggable diagram/math renderers.
- `Carve.parse` returns the full parse tree as symbol-keyed Ruby Hashes and
  Arrays (every AST node type is covered), enabling custom renderers such as
  [carve-hexapdf](https://github.com/markup-carve/carve-hexapdf).

[Unreleased]: https://github.com/markup-carve/carve-rb/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/markup-carve/carve-rb/releases/tag/v0.1.0
