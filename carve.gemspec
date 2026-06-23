# frozen_string_literal: true

require_relative "lib/carve/version"

Gem::Specification.new do |spec|
  spec.name = "carve"
  spec.version = Carve::VERSION
  spec.authors = ["markup-carve"]
  spec.summary = "Native Ruby bindings for the Carve markup language."
  spec.description = <<~DESC.strip
    Parse and render Carve markup to HTML from Ruby. A native extension
    (magnus + rb-sys) over the carve-rs engine, mirroring how Djot's djotter
    gem wraps the jotdown crate. No parser is reimplemented in Ruby.
  DESC
  spec.homepage = "https://github.com/markup-carve/carve-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rs,rb,toml,lock}",
    "README.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  # Tells RubyGems this gem ships a Rust native extension built via extconf.rb.
  spec.extensions = ["ext/carve/extconf.rb"]

  # Runtime dependency: rb_sys provides the mkmf integration that compiles the
  # Rust crate at install time.
  spec.add_dependency "rb_sys", "~> 0.9"

  # Development dependencies: build + test tooling.
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "minitest", ">= 5.0"
end
