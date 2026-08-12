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

`Carve::EXTENSIONS` is the list, and it comes from the engine rather than from
a copy kept here that could fall behind it:

```ruby
Carve::EXTENSIONS
# => [:autolink, :citations, :"code-callouts", :"code-group", ...]
```

The canonical names are kebab-case (`:"math-block"`, `:"table-of-contents"`).
Snake_case spellings (`:math_block`) work as arguments, as do the short aliases
this binding has always taken: `:math`, `:permalinks`, `:mermaid`, `:dot`,
`:graphviz`, `:chart`, `:toc`.

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

## Section wrappers

A top-level heading is wrapped, along with the content following it up to the
next same-or-shallower heading, in a `<section>` carrying the heading's id (spec
PART 9 §13). Only the id moves - `{#install .featured}` gives
`<section id="install"><h2 class="featured">` - and a heading inside a
blockquote, div or list item is not wrapped at all.

Pass `sections: false` to render headings flat, with the id back on the `<h*>`:

```ruby
Carve.to_html("# A\n\np\n")
# => "<section id=\"A\">\n  <h1>A</h1>\n  <p>p</p>\n</section>"

Carve.to_html("# A\n\np\n", sections: false)
# => "<h1 id=\"A\">A</h1>\n<p>p</p>"
```

This is for a host whose CSS or JS assumes rendered blocks are direct children
of the content container - the `.stack > * + *` spacing idiom, `:first-child`,
`nth-child()` counting, DOM child walks - all of which stop matching once a
wrapper sits in between. It is the one output change that breaks a document
whose *source* migrated cleanly.

Nothing else changes: ids, collision dedup, `</#id>` cross-references, implicit
`[Heading][]` references and heading numbering all resolve against the slug
rather than the element carrying it. The endnotes
`<section role="doc-endnotes">` is a separate construct and is still emitted.

## Untrusted input

Carve's normative hardening is always on and needs no option: dangerous URL
schemes are blanked, event-handler attributes like `onclick` are dropped, and the
bidi override/isolate characters behind Trojan Source are removed from rendered
text.

Raw passthrough is the deliberate exception. A ` ```=html ` block or a
`` `…`{=html} `` span renders **verbatim** by design, so it is the one thing
input you did not author has to switch off:

``` ruby
Carve.to_html(user_input, safe: true, profile: :comment)
```

`safe:` escapes those raw blocks and spans instead of emitting them. `profile:`
restricts which constructs are allowed at all and caps input length -
`:full`, `:article`, `:comment` or `:minimal`, String or Symbol. An unknown name
raises `ArgumentError` rather than being ignored.

A profile **rejection** raises too, rather than returning something that looks
like output:

``` ruby
Carve.to_html("x" * 20_000, profile: :minimal)
# ArgumentError: Profile violations: 'document' is not allowed: max_length_exceeded (...)
```

That matters for untrusted input: the engine's infallible entry point answers a
rejection with an empty String, which a caller cannot tell from a document that
legitimately rendered to nothing.

Full recipe, defaults and threat model:
[Security](https://markup-carve.github.io/carve/security).

## Stored documents and spec versions

`carve fmt --stamp` (in any Carve engine) records the spec version a document was
last processed under. This gem reads that marker back, so a repository of stored
`.crv` files can be checked for documents predating a breaking spec change:

``` ruby
Carve.read_stamp(source)
# => {version: "0.1", generated_by: "carve-php 0.1.0"}

Carve.needs_review?(source)   # true when the document predates this engine
```

An **unstamped** document answers `true`: its provenance is unknown, and assuming
it is current is the unsafe direction. Both marker forms are read, and a marker
written by any engine reads the same - the format is the contract, not any one
API - so the answer matches carve-php, carve-js, carve-rs and carve-go on the
same document.

What a version difference means is the
[versioning contract](https://markup-carve.github.io/carve/versioning): only
`[behavior]` changelog entries between the stamped version and yours can require
a document change.

## API

| Method | Description |
| ------ | ----------- |
| `Carve.to_html(source)` | Render Carve source to HTML. |
| `Carve.parse(source)` | Parse Carve source into an AST (tree of Ruby Hashes/Arrays). |
| `Carve.to_html(source, extensions: [...])` | Render with the named extensions enabled. |
| `Carve.to_html(source, mode: :static, renderers: {...})` | Render self-contained static HTML with build-time renderers. |
| `Carve.to_html(source, symbols: {...})` | Render with a `:name:` -> value symbol map (values are raw, see above). |
| `Carve.to_html(source, safe: true, profile: :comment)` | Render untrusted input: escape `=html` raw blocks/spans, restrict constructs. |
| `Carve.to_html(source, sections: false)` | Render headings flat, with the id on the `<h*>` instead of a `<section>` wrapper. |
| `Carve.read_stamp(source)` | Read a document's provenance marker: `{version:, generated_by:}` or `nil`. |
| `Carve.needs_review?(source)` | Whether a document predates this engine's spec version (unstamped counts as yes). |
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
carve_rs = { package = "carve-lang", git = "https://github.com/markup-carve/carve-rs", rev = "..." }
```

Read the current revision out of `ext/carve/Cargo.toml` rather than from a copy
here. This section used to quote one, and it drifted three bumps behind the
manifest before anyone noticed - a duplicated value goes stale the first time
someone edits the original, and a stale one here is worse than none because it
reads as authoritative.

The crate is imported under the alias `carve_rs`. It is published as `carve-lang`
(carve-rs renamed it from `carve`), so a pin at any revision past that rename
needs `package = "carve-lang"` as above.

When bumping the `rev`, run `rake compile` and commit the resulting
`ext/carve/Cargo.lock` in the same change. The lock records the resolved
revision, so leaving it behind means every fresh clone gets a dirty working tree
on its first build and the gem can resolve to a different engine than the one
that was tested.

Whether the pin is current is not a judgment call: CI runs the mandatory spec
corpus through the compiled extension and requires byte-identical HTML, so a pin
that has fallen behind fails a build. Locally:

```sh
CARVE_SPEC_CORPUS=/path/to/carve/tests/corpus bundle exec rake test
```

## License

MIT, markup-carve.
