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
`spoiler`, `table_of_contents` (see `Carve::EXTENSIONS`).

An unknown extension name raises `ArgumentError`.

## API

| Method | Description |
| ------ | ----------- |
| `Carve.to_html(source)` | Render Carve source to HTML. |
| `Carve.to_html(source, extensions: [...])` | Render with the named extensions enabled. |
| `Carve.to_html_with_extensions(source, names_array)` | Native primitive (Array of Strings). |
| `Carve::VERSION` | Gem version. |
| `Carve::EXTENSIONS` | Array of recognized extension symbols. |

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

## Publishing note

For a published gem, the Rust crate dependency in `ext/carve/Cargo.toml` should
point at the git (or crates.io) source rather than a local path:

```toml
carve = { git = "https://github.com/markup-carve/carve-rs" }
```

## License

MIT, markup-carve.
