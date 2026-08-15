# frozen_string_literal: true

# The version this gem reports is the version that shipped.
#
# A version constant is read by people who cannot see the build: an embedder
# quotes it in a bug report, and `carve fmt --stamp` writes the engine's into a
# document. When it names a release that is not the one running, every
# conclusion drawn from it is wrong and the reader has no way to notice - they
# suspect their own build first. carve-js shipped `LIB_VERSION = '0.1.0'`
# through three releases while its package was at 0.1.3, found by an outside
# embedder (markup-carve/carve-js#1074). The comment guarding it said "keep in
# sync with package.json on release", which is an instruction, not a check.
#
# `Carve::VERSION` is the one hand-written copy of this gem's release version;
# the gemspec derives `spec.version` from it, so that side cannot drift. Two
# other places state the same number by hand:
#
#   - ext/carve/Cargo.toml, the native extension's own package version;
#   - the newest cut CHANGELOG section, which is what the release process
#     writes when it cuts a release.
#
# Both assertions below read BOTH of their sides out of a file at run time. No
# version literal appears in this file: a literal would have to be edited on
# release too, which is the defect rather than the fix.

require "minitest/autorun"
require "carve/version"

class ReleaseVersionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # The `version` of the `[package]` table in the extension's manifest.
  def extension_crate_version
    manifest = read(File.join(ROOT, "ext/carve/Cargo.toml"))
    in_package = false
    manifest.each_line do |line|
      stripped = line.strip
      if stripped.start_with?("[")
        in_package = stripped == "[package]"
        next
      end
      next unless in_package

      match = stripped.match(/\Aversion\s*=\s*"([^"]+)"/)
      return match[1] if match
    end
    flunk "ext/carve/Cargo.toml has no [package] version field"
  end

  # The newest CUT changelog section, i.e. the first `## [X.Y.Z]` heading,
  # skipping the open `## [Unreleased]` one.
  def newest_released_changelog_version
    read(File.join(ROOT, "CHANGELOG.md")).each_line do |line|
      match = line.match(/\A## \[?(\d[^\]\s]*)/)
      return match[1] if match
    end
    flunk "CHANGELOG.md has no cut '## [X.Y.Z]' section"
  end

  def read(path)
    flunk "cannot read #{path}; this gate compares two files against each " \
          "other, so a missing side means the comparison did not happen" unless File.file?(path)
    File.read(path)
  end

  def test_the_gem_version_is_the_extension_crate_version
    crate = extension_crate_version

    assert_equal crate, Carve::VERSION,
                 "Carve::VERSION is #{Carve::VERSION}, but ext/carve/Cargo.toml " \
                 "is at #{crate}. They are two hand-written copies of one " \
                 "release number, and the gem reports the first while the " \
                 "native extension is built from the second."
  end

  def test_the_gem_version_is_the_newest_released_changelog_section
    changelog = newest_released_changelog_version

    assert_equal changelog, Carve::VERSION,
                 "Carve::VERSION is #{Carve::VERSION}, but the newest cut " \
                 "CHANGELOG section is #{changelog}. Either the release bumped " \
                 "the constant without cutting the changelog, or it cut the " \
                 "changelog without bumping the constant."
  end
end
