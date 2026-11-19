# Ruby API reference for Carve 0.2

The native extension calls `carve2::api::json::call`. `Carve.call(name, source:, options:, **fields)` exposes the engine's 0.2 JSON boundary directly. It returns the `ok` object with string keys and raises `Carve::EngineError` for an engine error. The exception carries `name`, `category`, and `status` from C2-T-040. Parsing JSON has no Ruby nesting limit beyond the engine's own limits.

```ruby
Carve.call("render", source: "Hi *there*")
Carve.call("parseWithDiagnostics", source: "# Title", positions: true)
Carve.call("encodeTree", tree: Carve.call("parse", source: "Text").fetch("tree"))
```

## Convenience calls

- `Carve.to_html(source, mode:, profile:, symbols:, sections:, raw_html:, safe:, url_policy:)` returns HTML. The default is `raw_html: false`; `safe: true` forces it off even when `raw_html: true` is supplied. `url_policy:` is passed as `urlPolicy` to the engine. `mode:` accepts `interactive` or `static`; `profile:` accepts the 0.2 engine profiles.
- `Carve.parse(source, **options)` returns the 0.2 tree with symbol keys. `Carve.parse_with_diagnostics(source, **options)` returns the tree and diagnostics. Options use Ruby snake case or the JSON names; they are converted to the 0.2 option names.
- `Carve.render_with_diagnostics(source, **options)` returns HTML plus diagnostics. `Carve.lint(source, rules:, platforms:)` returns diagnostic entries with the 0.2 fields `code`, `severity`, `channel`, `message`, and byte ranges where applicable (C2-T-020).
- `Carve.write(source, target:, **options)` writes a resolved tree through the engine writer registry. `to_carve(source, align_tables:)`, `to_markdown`, `to_plain_text`, and `to_ansi` keep their public names. The source, Markdown, plain, and ANSI writers are pending in carve-rs#4327 and currently raise `Carve::WriterUnavailable`.
- `Carve.to_html_with_includes(source, root:, source_path:)`, `parse_with_includes`, and `render_with_includes` use the 0.2 `includes` option. Both paths must be absolute. The result has `value`, `warnings`, `dependencies`, and `suppressedWarnings`; diagnostics and dependencies follow the 0.2 engine schema. The 0.2 include budgets are `max_depth` and `max_bytes`.
- `Carve.from_html` routes to `importDocument`, pending in carve-rs#4328. `from_markdown` has no 0.2 importer (C2-T-003) and raises an error.
- `Carve.register_extension` and nonempty `extensions:` or `renderers:` arguments raise `Carve::ExtensionUnavailable` while the 0.2 extension host is pending in carve-rs#4329. The option remains available for that API.

The old `safe: false` spelling does not enable raw HTML. Use `raw_html: true` for trusted source (U-076 and U-077). `Carve.read_stamp`, `needs_review?`, and `decision_trace` are 0.1 utilities with no 0.2 counterpart. The 0.2 upgrade tool handles provenance and source rewriting.

## Installation from this branch

Build the gem with `bundle exec rake compile`. Cargo fetches the pinned `carve2` commit directly from Git, then `bundle exec rake test` runs the Ruby tests. The branch contains no released dependency or version change.
