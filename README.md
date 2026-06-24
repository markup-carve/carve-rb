# carve (Ruby)

Native Ruby bindings for the [Carve](https://github.com/markup-carve/carve)
markup language. This gem is a thin native extension built with
[magnus](https://github.com/matsadler/magnus) + [rb-sys](https://github.com/oxidize-rb/rb-sys)
over the [carve-rs](https://github.com/markup-carve/carve-rs) engine. The parser
is not reimplemented in Ruby; it calls into the Rust crate directly, mirroring
how Djot's `djotter` gem wraps the `jotdown` crate.

## Install

```ruby
# Gemfile
gem "carve"
```

```sh
bundle install
```

Building from source requires a **Rust toolchain** (`cargo`, Rust >= 1.75) and
Ruby development headers. RubyGems compiles the native extension at install
time via `rb_sys`.

## Usage

```ruby
require "carve"

Carve.to_html("# Hello *world*")
# => "<section id=\"Hello-world\">\n  <h1>Hello <strong>world</strong></h1>\n</section>"

# Carve syntax note: *...* is STRONG (bold), /.../ is EMPHASIS (italic).
Carve.to_html("*bold* and /italic/")

# Enable opt-in extensions (Symbols or Strings, snake_case or hyphenated):
Carve.to_html(<<~CRV, extensions: [:math_block])
  ```math
  a^2 + b^2 = c^2
  ```
CRV

Carve.to_html(src, extensions: %w[math-block list-table])
```

### Recognized extensions

`autolink`, `details`, `list_table`, `math_block`, `heading_permalinks`,
`citations`, `tab_normalize`, `wikilinks`, `external_links`, `fenced_render`,
`fenced_render_graphviz`, `fenced_render_chart`, `spoiler`,
`table_of_contents` (see `Carve::EXTENSIONS`).

An unknown extension name raises `ArgumentError`.

## Static render mode + renderers

By default `Carve.to_html` renders **interactive** HTML: client-script
constructs (Mermaid/Graphviz/Chart diagrams, math) emit hydration elements
(`<pre class="mermaid">`, ...) and disclosure stays collapsed (`<details>`).

Pass `mode: :static` to emit **self-contained** HTML for print, PDF, or
archival. Static mode forces disclosure (`<details open>`) and pre-renders
client-script constructs through the `renderers:` callables you supply.

```ruby
Carve.to_html(<<~CRV, extensions: [:fenced_render], mode: :static,
              renderers: { mermaid: ->(src) { "<svg>#{src}</svg>" } })
  ```mermaid
  graph TD; A-->B
  ```
CRV
```

### Renderer callable signatures

The `renderers:` Hash is keyed by Symbol or String (see
`Carve::RENDERER_KEYS`):

| Key | Callable signature | Receives |
| --- | ------------------ | -------- |
| `:mermaid` | `(String) -> String` | the diagram source |
| `:chart` | `(String) -> String` | the chart JSON source |
| `:graphviz` | `(String) -> String` | the DOT / Graphviz source |
| `:math` | `(String, display) -> String` | the TeX source and a `display` boolean (`true` for block / display math, `false` for inline) |

Each callable returns a self-contained HTML string (an `<svg>` / `<img>` for a
diagram, MathML / HTML for math) that the engine emits **verbatim** on the
static path.

### Source fallback (graceful degradation)

When the renderer a construct needs is **absent**, or a supplied renderer
**raises** or returns a **non-String**, the construct degrades to its source -
never blank, and never raw HTML. The fallback source is **HTML-escaped**, so a
construct body containing markup (e.g. `<img onerror=...>`) can never inject raw
HTML. This is part of the cross-implementation graceful-degradation rollout
(spec carve #205; siblings carve-js #242, carve-php #240, carve-rs #143,
carve-py #1).

An unknown `mode:` value or an unknown `renderers:` key raises `ArgumentError`.

## API

| Method | Description |
| ------ | ----------- |
| `Carve.to_html(source)` | Render Carve source to HTML. |
| `Carve.to_html(source, extensions: [...])` | Render with the named extensions enabled. |
| `Carve.to_html(source, mode: :static, renderers: {...})` | Render self-contained static HTML with build-time renderers. |
| `Carve.to_html_with_extensions(source, names_array)` | Native primitive (Array of Strings). |
| `Carve.to_html_full(source, names_array, mode_string, renderers_hash)` | Native static-mode primitive. |
| `Carve::VERSION` | Gem version. |
| `Carve::EXTENSIONS` | Array of recognized extension symbols. |
| `Carve::MODES` | Array of recognized render modes (`:interactive`, `:static`). |
| `Carve::RENDERER_KEYS` | Array of recognized `renderers:` keys. |

## Develop

```sh
bundle install
rake compile   # builds the Rust extension into lib/carve/carve.so
rake test      # runs the minitest suite
```

> [!NOTE]
> The native build uses `rb_sys` + `bindgen` (libclang) to read Ruby's
> headers. On systems where libclang cannot find its builtin C headers (the
> `'stdarg.h' file not found` error), point it at the GCC builtin include dir:
>
> ```sh
> export BINDGEN_EXTRA_CLANG_ARGS="-I/usr/lib/gcc/x86_64-linux-gnu/13/include"
> ```
>
> (Adjust the GCC version directory to match your toolchain.)

## carve-rs dependency pin

The static render mode + `StaticRenderers` API lives on the carve-rs
`proto/div-label-fallback` branch (carve-rs PR #143), so
`ext/carve/Cargo.toml` is pinned to it:

```toml
carve_rs = { package = "carve", git = "https://github.com/markup-carve/carve-rs", branch = "proto/div-label-fallback" }
```

Re-pin to the default branch once carve-rs #143 merges to main:

```toml
carve_rs = { package = "carve", git = "https://github.com/markup-carve/carve-rs" }
```

## License

MIT, markup-carve.
