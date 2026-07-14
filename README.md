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
gem "carve-lang"
```

```sh
bundle install
```

Or install directly:

```sh
gem install carve-lang
```

Then `require "carve"` as normal - the gem distribution name is `carve-lang`
but the require path stays `carve`.

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
`citations`, `code_callouts`, `tab_normalize`, `wikilinks`, `external_links`,
`fenced_render`, `fenced_render_graphviz`, `fenced_render_chart`, `spoiler`,
`table_of_contents` (see `Carve::EXTENSIONS`).

An unknown extension name raises `ArgumentError`.

## Parsing to an AST

`Carve.parse` returns the parsed document as a tree of Ruby Hashes and Arrays,
for consumers that want to walk or transform the document rather than render
HTML - for example a custom PDF renderer (see
[`carve-hexapdf`](https://github.com/markup-carve/carve-hexapdf)).

```ruby
Carve.parse("# Hello *world*")
# => {type: "document", frontmatter: {}, footnote_defs: {},
#     children: [{type: "heading", level: 1,
#                 children: [{type: "text", value: "Hello "},
#                            {type: "emphasis", kind: "strong",
#                             children: [{type: "text", value: "world"}], attrs: nil}],
#                 attrs: nil}],
#     source_len: 15}
```

Every node is a Hash with a `:type` key plus its fields; child collections are
Arrays; `:attrs` is `nil` or a Hash of `{id:, classes:, key_values:}`. Keys are
symbols. This is the raw parse tree (default profile, no extensions), so
render-stage extension rewrites are not applied.

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

## Symbols

A `:name:` symbol renders its literal `:name:` source unless the name is in the
**symbols map** passed as `symbols:` (String or Symbol keys, String values):

```ruby
Carve.to_html("Ship it :rocket: :shrug:", symbols: { "rocket" => "🚀" })
# => "<p>Ship it 🚀 :shrug:</p>"   (an unmapped name stays literal)
```

The leading word-boundary guard is unaffected by an active map: `a:b:c`,
`10:30:` and `me@example.com` never become symbols. A non-String value raises
`TypeError`.

> **Security: symbol values are TRUSTED RAW output.**
> A mapped value is inserted into the output **unescaped** - the same trust
> class as a `renderers:` callable. `{ "b" => "<b>x</b>" }` emits a real `<b>`
> element, not escaped text. This is deliberate (processor configuration is
> trusted). **Never build a symbols map out of untrusted / user-supplied
> input.**

## API

| Method | Description |
| ------ | ----------- |
| `Carve.to_html(source)` | Render Carve source to HTML. |
| `Carve.parse(source)` | Parse Carve source into an AST (tree of Ruby Hashes/Arrays). |
| `Carve.to_html(source, extensions: [...])` | Render with the named extensions enabled. |
| `Carve.to_html(source, mode: :static, renderers: {...})` | Render self-contained static HTML with build-time renderers. |
| `Carve.to_html(source, symbols: {...})` | Render with a `:name:` -> value symbol map (values are raw, see above). |
| `Carve.to_html_with_extensions(source, names_array)` | Native primitive (Array of Strings). |
| `Carve.to_html_full(source, names_array, mode_string, renderers_hash)` | Native static-mode primitive. |
| `Carve.to_html_full_with_symbols(source, names_array, mode_string, renderers_hash, symbols_hash)` | Native primitive, static mode + symbol map. |
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

`ext/carve/Cargo.toml` pins a specific carve-rs commit for reproducible gem
builds:

```toml
carve_rs = { package = "carve", git = "https://github.com/markup-carve/carve-rs", rev = "09c64118223c1574d136c308cfe2a70df8ab5128" }
```

The crate is imported under the alias `carve_rs`. Note: carve-rs has since
renamed its published crate to `carve-lang` on `main`; this pin predates that
rename, so `package = "carve"` is correct for this exact `rev`. When bumping to
a newer carve-rs commit (past the rename), update both the `rev` and
`package = "carve-lang"`.

## License

MIT, markup-carve.
