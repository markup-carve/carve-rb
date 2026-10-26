# carve (Ruby)

Ruby bindings for the Carve Rust engine. The gem processes Carve 0.1 documents through `carve-lang`. See the [Carve documentation](https://markup-carve.github.io/carve/).

## Install

```sh
gem install carve-lang
```

## Usage

```ruby
require "carve"
puts Carve.to_html("# Hello *world*")
```

## Documentation

- [Carve documentation](https://markup-carve.github.io/carve/)
- [Guide](docs/guide.md)
- [Documentation index](docs/README.md)

## License

[MIT](LICENSE).
