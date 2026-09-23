# carve (Ruby)

Native Ruby bindings for the
[Carve](https://github.com/markup-carve/carve) markup language. The gem wraps
the [carve-rs](https://github.com/markup-carve/carve-rs) engine through magnus
and rb-sys rather than reimplementing the parser.

## Install

```ruby
gem "carve-lang"
```

```bash
bundle install
```

The distribution name is `carve-lang`, while the require path is `carve`.
Building from source requires Rust 1.75 or newer and Ruby development headers.

## Render Carve

```ruby
require "carve"

Carve.to_html("# Hello *world*")
Carve.to_markdown(source)
Carve.to_plain_text(source)
Carve.to_ansi(source)
Carve.to_carve(source)
```

Options configure extensions, safe rendering, profiles, symbols, section
wrappers, and custom renderers:

```ruby
Carve.to_html(
  source,
  extensions: %w[autolink list-table],
  safe: true,
  profile: "comment",
)
```

`Carve::EXTENSIONS` reports the names accepted by the bundled engine. Unknown
names raise `ArgumentError`.

## Migration and AST access

`Carve.from_html` and `Carve.from_markdown` return canonical Carve with
structured fidelity reports. `Carve.parse` exposes a Ruby hash representation
of the AST, and static rendering produces self-contained output for documents
that do not load client-side renderers.

The [usage reference](docs/reference.md) documents AST fields, static
rendering, symbols, wrappers, profiles, and the main methods.

## Includes

Includes are opt-in and require an absolute containment root plus the source
document's absolute path:

```ruby
result = Carve.to_html_with_includes(
  File.read("book.crv"),
  root: File.expand_path("."),
  source_path: File.expand_path("book.crv"),
)
```

The result contains the value, warnings, and root-relative dependencies.
Other render methods leave directives literal. See the
[include reference](docs/reference.md#file-includes) for budgets, AST expansion,
targets, and containment behavior.

## Security

Use `safe: true` and a restrictive profile for untrusted documents. Custom
renderer callbacks and symbol values are trusted output and may emit raw HTML.
The [untrusted-input reference](docs/reference.md#untrusted-input) describes
resource limits and URL handling.

## Development

Source builds, tests, and the carve-rs dependency pin are documented under
[Development](docs/reference.md#develop) and
[carve-rs dependency pin](docs/reference.md#carve-rs-dependency-pin).
