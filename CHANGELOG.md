# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Engine bumped to carve-rs `19cc87c`** (from `fa4d3f7`, one commit), which
  moves the canonical writer's bytes twice. A frontmatter block whose opener
  named no format is written back as `---yaml` rather than as a bare `---`
  (PART 11 section 6b), and a blank line inside a fenced block under a footnote
  definition or a definition-list description is written EMPTY rather than
  indented to the content column (PART 11 section 7). Both were this engine
  alone against the other two.

- **Engine bumped to carve-rs `9fa8870`** (from `c94f808`, 33 commits). The pin
  had gone stale enough to render documents differently from the spec: against
  the corpus at carve `59b12e8`, 17 of 866 documents came out wrong, and the
  AST this binding publishes differed from the engine's own on the same
  documents. Both are back to zero.

  What moves for a caller, in four groups. A fence opened inside a container
  keeps that container open, so a boundary line, a list marker at the content
  column and a closed fence's residue land where PART 9 §24 puts them rather
  than folding into the code text. A lazy line folded into a container leaves
  that container open. A caption attaches across at most one blank line, so two
  blank lines detach it and the image stays an image. A definition body is an
  indented-block collector, so a line below its column ends it.

  For `Carve.parse` specifically, a nested link and an autolink stay nodes and
  the renderers unwrap them, rather than being unwrapped in the tree; a
  collapsed reference publishes the label it resolves by; and a heading's
  derived display text (what a numbered cross-reference expands to) clones the
  heading's nodes instead of re-rendering them, so an escaped character in a
  heading reaches the label.

  Neither of carve-rs's two Breaking entries reaches a caller here. The AST
  ingest tightening (a decoder that refuses every property the schema does not
  name, `footnote.id` among them) applies to reading a stored tree back, and
  this binding exposes no ingest entry point - `Carve.parse` writes trees and
  nothing reads one. `BlockQuote` losing its `attribution` field breaks a Rust
  struct literal naming it, and this extension constructs no engine types at
  all; it calls nine free functions. Both were checked against the source
  rather than assumed, and the extension compiles unchanged.

### Added

- **`Carve.to_html(source, sections: false)` renders headings without the
  `<section>` wrapper** (#36, spec PART 9 §13). The id goes back on the `<h*>`
  alongside its other attributes, and the blocks that would have been section
  children stay as siblings. Default `true`, so existing output is unchanged.

  The wrapper is the one output change that breaks a site whose source migrated
  cleanly: CSS and JS assuming rendered blocks are direct children of the
  content container stop matching once a `<section>` sits in between.

  The keyword also disqualifies the no-options fast path in `to_html`. That path
  calls `_to_html`, which takes no options at all, so short-circuiting to it
  would have dropped the flag and returned wrapped output with no error - the
  kind of failure a caller cannot see. It is pinned by its own test rather than
  left to the implementation.

### Changed

- **Engine bumped to carve-rs `5308d86`** (from `aad11cc`, 15 commits). Two of
  them change what this binding produces.

  A heading that carries no `<section>` wrapper now renders its attributes in
  the canonical order: the author's own first, the generated id last
  (`<h1 a="b" class="c" id="Auto">`). carve-rs had been emitting the id first,
  which agreed with neither carve-js nor carve-php - the combination was only
  reachable through a heading inside a container, and no corpus case gave such a
  heading attributes, so three engines held three answers and every suite stayed
  green (markup-carve/carve-rs#379, spec PART 10 §1). An id the author wrote
  keeps its authored position.

  `Carve.parse` publishes definition lists as `definition_term` and
  `definition_description` nodes (markup-carve/carve-rs#374). No edit was needed
  here for that: `to_ast_json` delegates to the engine's serializer rather than
  walking the tree itself, which is exactly why that delegation replaced this
  binding's own walker.

  The remaining commits place source positions on constructs that lacked them
  (block images, quoted figures, footnote definition bodies, the pieces an
  abbreviation splits a text node into, resolved cross-reference spans, list
  items, definition lists, line-block stanzas, frontmatter) plus a profile fix
  for `deny_block(["frontmatter"])` and two spec-corpus submodule bumps.

  Not included: the new `sections` render option. This binding builds `Options`
  internally and exposes no render options, so the switch is not reachable from
  Ruby. Surfacing it is a separate decision about what the entry points accept.

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

- **The AST root carries exactly `type`, `children` and `srcByteLength`.**
  Frontmatter and footnote definitions are now block nodes in `children`
  rather than root fields, which is what PART 12 §7 requires: a root field
  cannot carry the position §4 requires of every node, and both are source an
  editor navigates to (carve#411, carve#418).

  Frontmatter is the first child, carrying `format` and **raw** `content` -
  not the parsed key/values, which could not represent a `---toml` block at
  all. A definition is a `footnote` child of the document carrying `id`.

  Breaking for anything reading `ast[:frontmatter]` or `ast[:footnoteDefs]`.


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
