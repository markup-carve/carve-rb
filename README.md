# Carve for Ruby

The `next2` branch binds Ruby to the unreleased Carve 0.2 Rust engine. It pins a specific commit of `carve2` from `markup-carve/carve-rs`; it does not use a registry engine release.

```ruby
require "carve"

Carve.to_html("Hello *world*.")
Carve.parse("= Title")
Carve.lint("Text")
```

Raw HTML is escaped by default. To enable it for trusted source, pass `raw_html: true`; `safe: true` keeps it escaped. URL policy stays with the engine.

The 0.2 source, Markdown, plain-text, and ANSI writer targets, HTML importer, and extension host are still being implemented upstream. Their Ruby methods remain available and raise clear errors until the corresponding engine API works. See [the API reference](docs/reference.md) and [migration guide](docs/guide.md).

This branch is for integration testing. No 0.2 gem has been released.
