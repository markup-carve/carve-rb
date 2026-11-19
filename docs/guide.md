# Moving a Ruby host to Carve 0.2

Install this repository's `next2` branch, then compile its native extension. This branch pins an exact Git commit of the unreleased Rust `carve-lang` crate (carve-rs `next2`).

Use `Carve.to_html` for HTML and `Carve.parse` for a 0.2 tree. The tree schema and diagnostic fields changed; consumers should use the fields in the 0.2 tooling specification, not 0.1 node names. `Carve.call` exposes `parse`, `parseWithDiagnostics`, `render`, `renderWithDiagnostics`, `lint`, `encodeTree`, `decodeTree`, and `includeDependencies` directly.

Raw HTML now defaults to escaped output (U-076 and U-077). Review any host that formerly relied on raw passthrough and enable `raw_html: true` only for trusted source. Keep the engine's URL policy in place; if needed, pass a `url_policy:` value. The old `safe: true` option still forces escaping, while `safe: false` alone does not enable passthrough.

Includes use `root:` and `source_path:` as absolute paths and the engine's `includes` option. The 0.2 dependency report uses `path`, `from`, `file`, and `read`. The old `resolved` and `denial` fields are gone. Lint findings use `code`, `severity`, `channel`, and byte ranges, replacing 0.1 `rule` and character offsets.

`Carve.to_carve` runs the canonical writer and `Carve.from_html` imports HTML. The Markdown, plain-text, and ANSI writers are reserved in the writer registry, but not registered yet (carve-rs#4327, carve-rs#4349). Keep each target in your application and handle `Carve::WriterUnavailable`. The 0.2 extension host is provisional: `extensions:` selects the standard extensions in `Carve::EXTENSIONS`, while the bundled 0.1 extensions are not ported yet (carve-rs#4341, carve-rs#4342, carve-rs#4343) and Ruby build-time renderers have no JSON form. These calls report the gap instead of quietly using 0.1 behavior.

Run the 0.2 upgrade tool over stored Carve source before relying on old output. Its upgrade rows identify silent source changes, including breaks, lists, tables, and inline forms. Review HTML for each silent row.
