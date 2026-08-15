# frozen_string_literal: true

module Carve
  # The released version of this gem. The gemspec derives `spec.version` from
  # it, and an embedder quoting a version in a bug report is quoting this.
  #
  # It is not kept correct by hand on release: test/release_version_test.rb
  # compares it against ext/carve/Cargo.toml and against the newest cut
  # CHANGELOG section on every run, and .github/workflows/release.yml refuses to
  # publish a gem whose version is not the tag being released.
  VERSION = "0.1.0"
end
