# Carve for Ruby

The `next2` branch binds Ruby to the unreleased Carve 0.2 Rust engine. It pins a specific commit of the `carve-lang` crate from the `next2` branch of `markup-carve/carve-rs`; it does not use a registry engine release.

```ruby
require "carve"

Carve.to_html("Hello *world*.")
Carve.parse("= Title")
Carve.lint("Text")
```

Raw HTML is escaped by default. To enable it for trusted source, pass `raw_html: true`; `safe: true` keeps it escaped. URL policy stays with the engine.

The source writer, HTML importer, Markdown, plain-text, and ANSI writers, and native extension host are available on this branch. See [the API reference](docs/reference.md) and [migration guide](docs/guide.md).

This branch is for integration testing. No 0.2 gem has been released.

Ruby callables can render declared extension nodes and transform resolved documents:

```ruby
Carve.to_html("# Guide", transforms: [->(tree) { tree }])
Carve.render_with_host("", tree: tree, renderers: { "ex.note" => ->(node) { "<aside>Note</aside>" } })
```

Use `{ interactive: callable, static: callable }` to choose renderers by channel. Callback errors become engine diagnostics and retain the fallback or previous view.
