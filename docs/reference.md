# Ruby API reference for Carve 0.2

The native extension calls `carve::api::json::call` from the `carve-lang` crate. `Carve.call(name, source:, options:, **fields)` exposes the engine's 0.2 JSON boundary directly. It returns the `ok` object with string keys and raises `Carve::EngineError` for an engine error. The exception carries `name`, `category`, and `status` from C2-T-040. Parsing JSON has no Ruby nesting limit beyond the engine's own limits.

```ruby
Carve.call("render", source: "Hi *there*")
Carve.call("parseWithDiagnostics", source: "= Title", positions: true)
Carve.call("encodeTree", tree: Carve.call("parse", source: "Text").fetch("tree"))
```

## Convenience calls

- `Carve.to_html(source, mode:, profile:, symbols:, sections:, raw_html:, safe:, url_policy:)` returns HTML. The default is `raw_html: false`; `safe: true` forces it off even when `raw_html: true` is supplied. `url_policy:` is passed as `urlPolicy` to the engine. `mode:` accepts `interactive` or `static`; `profile:` accepts the 0.2 engine profiles. `heading_shift:` (or `headingShift:`) adds 0 to 5 to every heading level (C2-H-208).
- `Carve.parse(source, **options)` returns the 0.2 tree with symbol keys. `Carve.parse_with_diagnostics(source, **options)` returns the tree and diagnostics. Options use Ruby snake case or the JSON names; they are converted to the 0.2 option names.
- `Carve.render_with_diagnostics(source, **options)` returns HTML plus diagnostics. `Carve.lint(source, rules:, platforms:)` returns diagnostic entries with the 0.2 fields `code`, `severity`, `channel`, `message`, and byte ranges where applicable (C2-T-020).
- `Carve.write(source, target:, **options)` writes a resolved tree through the engine writer registry. `to_carve(source, align_tables:)`, `to_markdown`, `to_plain_text`, and `to_ansi` keep their public names. `to_carve` runs the canonical writer. The pinned engine provides Markdown, plain, and ANSI export writers.
- `Carve.to_html_with_includes(source, root:, source_path:)`, `parse_with_includes`, and `render_with_includes` use the 0.2 `includes` option. Both paths must be absolute. The result has `value`, `warnings`, `dependencies`, and `suppressedWarnings`; diagnostics and dependencies follow the 0.2 engine schema. The 0.2 include budgets are `max_depth` and `max_bytes`.
- `Carve.from_html` routes to `importDocument` and returns `tree`, `source`, and `diagnostics`. The old HTML import mode is gone (C2-M-008); only the legacy default `mode: :safe` is accepted. `Carve.import_document(source, from:)` imports `html` (the default), `gfm`, `markdown` (CommonMark only) or `djot` through the same call. `Carve.from_markdown` imports GitHub Flavored Markdown, as the 0.1 importer did; `from: "markdown"` leaves GFM tables as text. These importers are outside the 0.2 specification (C2-T-003).
- `extensions:` on `to_html` and `render_with_includes` selects the engine's standard extensions, listed in `Carve::EXTENSIONS` (C2-X-039, provisional). `renderers:` maps a standard extension to `"standard"` (or `:standard`) for its standard renderer, for example `Carve.to_html(source, extensions: ["carve.tabs"], renderers: { "carve.tabs" => "standard" })`. An unknown name raises `Carve::EngineError`. Ruby callables use the native extension host: `Carve.render_with_host(source, tree:, options:, renderers:, transforms:)` accepts a callable for both channels or `{ interactive: callable, static: callable }`. `Carve.to_html` also accepts callable renderers and ordered transforms. A renderer hash may include `version:` for a declaration introduced by a transform; a supplied tree provides its declared version automatically. A failed callback yields the engine diagnostic and fallback. `Carve.lint` takes no `extensions:` in 0.2.
- The 0.1 math block, list table, diagram, glossary, details and other bundled extensions are standard extensions of the 0.2 engine; `Carve::EXTENSIONS` lists their names. The 0.2 engine provides the navigation extensions, including heading numbers, permalinks, table of contents, external links, and autolink.

The old `safe: false` spelling does not enable raw HTML. Use `raw_html: true` for trusted source (U-076 and U-077). `Carve.read_stamp`, `needs_review?`, and `decision_trace` are 0.1 utilities with no 0.2 counterpart. The 0.2 upgrade tool handles provenance and source rewriting.

## Installation from this branch

Build the gem with `bundle exec rake compile`. Cargo fetches the pinned `carve-lang` commit directly from Git, then `bundle exec rake test` runs the Ruby tests. The branch contains no released dependency or version change.
