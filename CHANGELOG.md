# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Everything below is the delta from `v0.1.0`, which is the only version a
reader can be upgrading from. The engine pin moved six times inside this
window; the intermediate revisions are not listed, because no release ever
shipped them.

### Added

- **`Carve.parse` publishes source positions.** Every block node the engine can
  place carries `pos` with `startLine`, `endLine`, `startColumn`, `endColumn`,
  `startOffset` and `endOffset`, as PART 12 §4 spells it: lines and columns
  1-based, offsets 0-based, counted in Unicode codepoints, `endColumn` and
  `endOffset` exclusive. A node whose span the engine could not determine has
  no `pos` key at all rather than one holding placeholder numbers - an absent
  position is a fact a consumer can act on, an invented one is not. Inline
  nodes do not carry positions yet (markup-carve/carve-rs#333).

- **`Carve.to_html(source, sections: false)` renders headings without the
  `<section>` wrapper** (#36, PART 9 §13). The id goes back on the `<h*>`
  alongside its other attributes and the blocks that would have been section
  children stay siblings. Default `true`, so existing output is unchanged. The
  wrapper is the one output change that breaks a site whose source migrated
  cleanly: CSS and JS assuming rendered blocks are direct children of the
  content container stop matching once a `<section>` sits in between.

- **Every extension the engine registers is reachable from Ruby.**
  `Carve::EXTENSIONS` lists 31 names instead of 15, adding glossary, index,
  table-of-contents placement (`::: toc`), heading numbers, heading references,
  heading level shift, code groups, tabs, the img fence, color swatches, smart
  quotes, and the remaining fenced-render presets (PlantUML, D2, WaveDrom,
  Vega-Lite, ABC). The list comes from the engine's registry rather than being
  typed out in the native binding and again in `lib/carve.rb`. Canonical names
  are the engine's kebab-case keys; snake_case spellings and the short aliases
  (`:math`, `:permalinks`, `:mermaid`, `:dot`, `:chart`, `:toc`) still work.

- **Composite figures** (PART 9 §4c). A **bare** `::: figure` fence is no longer
  a generic container: it is one figure of ordered panels, rendering
  `<figure class="carve-figure-group">` around a
  `<div class="carve-figure-panels">` whose members are each a
  `<figure class="carve-figure-panel">`, and a `^ ` line following the closer
  becomes the group's `<figcaption>` instead of an ordinary paragraph. A fence
  carrying a title or a `[label]` keeps the old shape, so a document that named
  its figure divs renders as before. `Carve.parse` publishes the group as a new
  `figure_group` node type.

### Changed

- **Breaking (`Carve.parse`): the published tree now matches the reference
  shape.** A tree from this binding did not interoperate with carve-js or
  carve-php, so several names and the root's shape moved at once:

  | was | now |
  |---|---|
  | `critic_insert` / `critic_delete` / `critic_substitute` | `insert` / `delete` / `substitution` |
  | `footnote` (both forms) | `footnote_ref` / `inline_footnote` |
  | `ref_id` | `refId` |
  | `footnote_defs` | `footnoteDefs` |
  | `source_len` | `srcByteLength` |
  | `emoji` | `symbol` (and it carries `attrs`) |

  The root now carries exactly `type`, `children` and `srcByteLength`.
  Frontmatter and footnote definitions are block nodes in `children` rather
  than root fields, which PART 12 §7 requires: a root field cannot carry the
  position §4 requires of every node, and both are source an editor navigates
  to (carve#411, carve#418). Frontmatter is the first child, carrying `format`
  and **raw** `content` - not parsed key/values, which could not represent a
  `---toml` block at all. Anything reading `ast[:frontmatter]` or
  `ast[:footnoteDefs]` breaks.

- **Breaking (`Carve.parse`): three constructs became their own node types.** A
  backslash escape is `{"type":"escaped_text","value":"-"}` instead of being
  folded into surrounding text - the backslash carries intent the character does
  not, since an author writes `\-\-` precisely so a consumer will not render an
  en dash (carve#350). A `::: |` fence is `line_block` instead of a `div` with a
  `.line-block` class, because inside it every newline is a hard break and a
  class alone could not say which one a node was (carve#359). A block
  extension's `summary` is a list of inline nodes rather than a plain string,
  matching the admonition `title` shape. Definition lists publish
  `definition_term` and `definition_description` nodes
  (markup-carve/carve-rs#374).

  These are additive for a consumer with a default branch and a compile error
  for one without.

- **Delimited inline comments carried in from the engine.** `{% … %}` is an
  inline comment that ends at its closer, alongside the trailing `%%` form that
  runs to the end of its inline run (PART 9 §21a). Both render nothing; in
  `Carve.parse` they are the same `comment` node, told apart by a `delimited`
  field, because the two spell different documents and a writer has to
  reproduce the one that was written.

- **Language changes carried in from the engine.** Superscript and subscript are
  braced-only - bare `^x^` and `,x,` are literal text, the markup is `{^x^}` and
  `{,x,}`. The `:name:` symbol inline was added, with a leading word-boundary
  guard so `a:b:c`, `10:30:` and `me@example.com` stay literal. Compact semantic
  spans arrived: `[Tab]{kbd}` renders `<kbd>Tab</kbd>`, with `abbr`, `time` and
  `kbd` in core and `samp`, `var`, `cite` and `dfn` behind the `semantic-span`
  extension.

  Every `<th>` carries a `scope` - `col` in the header run, `row` for a
  `|=` cell in a body row. A cell's attribute block binds after its kind and
  alignment markers, so a `{...}` following a cell's `=` marker is read as
  attributes rather than rendered as cell text. A mandatory base class merges
  into the author's class slot at its authored position rather than leading it,
  so `:widget[x]{#i .c}` keeps `id` first.

- **Rendering corrections carried in from the engine.** A block-attribute line
  reaches the nested list it was written for, and a flush-left attribute line is
  read as attributes rather than as paragraph text. A figure group holds its
  panels directly. A table's sections and rows keep the attributes they have a
  slot for. A code block resolves the no-break-space sentinel instead of
  emitting it. A fence opened inside a
  container keeps that container open, so a boundary line, a list marker at the
  content column and a closed fence's residue land where PART 9 §24 puts them
  rather than folding into the code text. A lazy line folded into a container
  leaves it open. A caption attaches across at most one blank line, so two blank
  lines detach it and the image stays an image. A definition body is an
  indented-block collector, so a line below its column ends it. A heading with
  no `<section>` wrapper renders the author's attributes first and the generated
  id last. A frontmatter block whose opener named no format is written back as
  `---yaml`, and a blank line inside a fenced block under a footnote definition
  or a definition-list description is written empty rather than indented.

  Reference resolution reaches three places it used to stop short of: a
  reference inside an inline note, a critic insertion or a critic deletion
  resolves against the document's definitions; a footnote inside an unresolved
  reference stays a footnote rather than being swallowed by the failed
  reference; and a reference tail no longer seals its own link text, so the
  text a reference link carries survives the frame that resolves it.

  For `Carve.parse` specifically: a nested link and an autolink stay nodes and
  the renderers unwrap them; a collapsed reference publishes the label it
  resolves by; a heading's derived display text clones the heading's nodes
  instead of re-rendering them, so an escaped character in a heading reaches the
  label; and `attrs.keyValues` is published in the author's source order, the
  same order the sibling `attrs.order` field states.


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
