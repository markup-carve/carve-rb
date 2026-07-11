# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-11

### Added

- `Carve.parse` returns the full parse tree as symbol-keyed Ruby Hashes and
  Arrays (every AST node type is covered), enabling custom renderers such as
  [carve-hexapdf](https://github.com/markup-carve/carve-hexapdf).
- Autolink nodes expose their display `text` alongside `href`; critic
  insert/delete nodes expose their trailing attribute block as `attrs`.

### Changed

- Engine updated to the current carve-rs main (conformance and renderer fixes,
  including autolink display content, editorial-markup attributes, and
  code-span edge cases).

## 0.1.0 - 2026-06-22

Never tagged or published; superseded by 0.2.0.

### Added

- Initial version: `Carve.to_html` and the full extension/option surface of
  the carve-rs engine as a native Ruby extension (magnus + rb-sys), including
  the static/print render mode and pluggable diagram/math renderers.

[Unreleased]: https://github.com/markup-carve/carve-rb/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/markup-carve/carve-rb/releases/tag/v0.2.0
