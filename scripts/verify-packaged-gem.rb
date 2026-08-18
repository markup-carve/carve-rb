# frozen_string_literal: true

# Runs the mandatory spec corpus through the gem that is about to be published.
#
# The distinction this script exists to make is between "the code in this
# checkout is correct" and "the artifact this job would push is correct". Every
# other check in this repository answers the first question. `rake test`
# compiles the extension into lib/carve/ from the working tree and drives the
# corpus through that; release.yml then built a .gem out of the same directory
# and pushed it without asking anything about it. A gem is not its checkout: the
# gemspec's file globs decide what is packaged, and a packaged source tree
# builds under `gem install`'s toolchain rather than under `rake compile`. Two
# separate compiles of two separate file sets were being tested and shipped.
#
# So this script refuses to look at the checkout at all. It is pointed at a
# GEM_HOME into which the built .gem was installed -- the same install path an
# embedder takes -- and it asserts, before rendering a single document, that the
# `carve` it just required resolved into that install root and nowhere else. The
# check has already earned that: on a developer machine carrying an unrelated
# carve-lang install, the first run of this gate resolved `require "carve"` to
# THAT gem instead of the packaged one, and said so rather than certifying it.
#
# The population half is not decoration. Measured on a sibling binding, a corpus
# cut to 400 pairs rendered "400/400 byte-identical" -- a clean verdict over a
# third of the corpus. Content and population are two different questions and a
# release gate has to ask both. The expected population is derived from the
# spec's own example pages by test/corpus_population.rb, the same helper the
# ordinary corpus gate uses; a second, hand-written count here would be free to
# disagree with it, and a release gate that disagrees with CI about how big the
# corpus is has already failed at its job.

require "fileutils"
require "tmpdir"
require "rubygems/package"

# Fail, never skip. The ordinary corpus test skips when CARVE_SPEC_CORPUS is
# unset so a plain `rake test` works in a checkout without the spec; that same
# skip, inherited into CI, once turned the whole corpus gate into "2 runs, 0
# assertions, 0 failures" and an exit status of zero
# (markup-carve/carve-rb#73). A release gate has no configuration under which
# doing nothing is the right answer.
def required_env(name, what)
  value = ENV[name]
  return value unless value.nil? || value.strip.empty?

  warn "verify-packaged-gem: #{name} is not set; it must name #{what}."
  warn "This gate never skips. Run it through scripts/verify-release-artifact.sh."
  exit 1
end

CORPUS = required_env("CARVE_SPEC_CORPUS", "the spec's tests/corpus directory")
INSTALL_ROOT = required_env("CARVE_PACKAGED_GEM_ROOT", "the GEM_HOME the built gem was installed into")
GEM_FILE = required_env("CARVE_PACKAGED_GEM", "the .gem file this job would publish")
WANT_VERSION = required_env("CARVE_PACKAGED_GEM_VERSION", "the version of that .gem file")

REPO_ROOT = File.expand_path("..", __dir__)

# Required BEFORE minitest, and outside any test, so that a native extension
# which cannot be loaded at all -- the first thing a corrupt artifact does --
# ends the run here with a message naming the artifact, rather than as a
# LoadError backtrace out of a test method.
begin
  require "carve"
rescue LoadError, StandardError => e
  warn "verify-packaged-gem: the packaged gem installed into #{INSTALL_ROOT} could not be loaded."
  warn "This is the artifact the release would publish, so the release is refused."
  warn "#{e.class}: #{e.message}"
  exit 1
end

require "minitest/autorun"
require "corpus_population"

class PackagedGemTest < Minitest::Test
  include CorpusPopulation

  DLEXT = RbConfig::CONFIG["DLEXT"]

  def install_root
    @install_root ||= File.realpath(INSTALL_ROOT)
  end

  def under_install_root?(path)
    real = File.realpath(path)
    real == install_root || real.start_with?("#{install_root}#{File::SEPARATOR}")
  end

  # The whole gate rests on this: everything below is about the `carve` that got
  # required, and unless that came out of the install of the .gem being
  # published, every assertion after it is about some other engine.
  def test_the_loaded_extension_is_the_one_installed_from_the_built_gem
    loaded = $LOADED_FEATURES.grep(%r{/carve/carve\.#{Regexp.escape(DLEXT)}\z})
    assert_equal 1, loaded.length,
                 "expected exactly one loaded carve native extension, got #{loaded.inspect}. " \
                 "More than one means two engines are in the process and which one answered " \
                 "Carve.to_html is not decidable."

    extension = loaded.first
    assert under_install_root?(extension),
           "the loaded native extension is #{extension}, which is not inside #{install_root}. " \
           "The gate is meant to drive the corpus through the gem built for publication; " \
           "resolving to anything else -- the checkout's lib/carve/, a previously installed " \
           "carve-lang, a system copy -- certifies an artifact nobody is about to push."

    refute under_repo_checkout?(extension),
           "the loaded native extension is #{extension}, inside this checkout at #{REPO_ROOT}. " \
           "`rake compile` builds one there; a release gate that picks it up is testing the " \
           "source tree again rather than the package."
  end

  def test_the_loaded_gem_is_the_version_that_was_built
    spec = Gem.loaded_specs["carve-lang"]
    refute_nil spec, "carve-lang is not among the activated gems: #{Gem.loaded_specs.keys.sort.inspect}"
    assert_equal WANT_VERSION, spec.version.to_s,
                 "the activated carve-lang is #{spec.version}, but the .gem built for this " \
                 "release is #{WANT_VERSION}."
    assert under_install_root?(spec.gem_dir),
           "carve-lang activated from #{spec.gem_dir}, outside #{install_root}."
    assert_equal WANT_VERSION, Carve::VERSION,
                 "the installed gem reports Carve::VERSION #{Carve::VERSION}, which is not the " \
                 "#{WANT_VERSION} its own package name claims."
  end

  # `gem install` compiles the extension from the packaged sources, so the
  # binary cannot be byte-compared against anything in the .gem. Its inputs can.
  # Every file the package carries has to be byte-identical to the installed
  # copy that was just loaded, which is what makes "the corpus ran through this
  # install" a statement about THIS .gem rather than about whatever happened to
  # be installed under that path.
  def test_every_packaged_file_is_byte_identical_to_the_install
    spec = Gem.loaded_specs["carve-lang"]
    package = Gem::Package.new(GEM_FILE)
    packaged = package.spec.files.sort
    refute_empty packaged, "#{GEM_FILE} declares no files"

    Dir.mktmpdir("carve-packaged") do |dir|
      package.extract_files(dir)
      differing = packaged.reject do |rel|
        from_package = File.join(dir, rel)
        installed = File.join(spec.gem_dir, rel)
        File.exist?(installed) && File.binread(from_package) == File.binread(installed)
      end
      assert_empty differing,
                   "#{differing.length} of #{packaged.length} files in #{File.basename(GEM_FILE)} " \
                   "differ from the install this gate rendered through: " \
                   "#{differing.first(10).join(', ')}. The install is then not this package, and " \
                   "the corpus result below says nothing about what would be published."
    end
  end

  def test_the_corpus_is_whole
    assert File.directory?(CORPUS), "CARVE_SPEC_CORPUS=#{CORPUS} is not a directory"
    # Equality against what the spec's example pages declare, via the one helper
    # this repository has for the question. A floor, or a count grepped out of
    # the pages here, is how a truncated corpus certifies a publish.
    assert_whole_corpus(CORPUS, pairs.length, "corpus pairs found")
  end

  def test_the_packaged_gem_renders_the_corpus_byte_identically
    all = pairs
    assert_whole_corpus(CORPUS, all.length, "corpus pairs rendered")

    mismatches = all.reject do |crv, html|
      want = File.read(html).sub(/\n+\z/, "")
      got = Carve.to_html(File.read(crv)).sub(/\n+\z/, "")
      got == want
    end.map { |crv, _| File.basename(crv, ".crv") }

    assert_empty mismatches,
                 "#{mismatches.length} of #{all.length} corpus documents render differently " \
                 "from the spec through the gem this release would publish: " \
                 "#{mismatches.first(20).join(', ')}#{mismatches.length > 20 ? ' ...' : ''}. " \
                 "The carve-rs rev in ext/carve/Cargo.toml is the usual cause; bump it, commit " \
                 "the regenerated ext/carve/Cargo.lock, and tag again. Publishing is not " \
                 "reversible, so this refuses rather than warns."

    # Printed, not merely asserted. A reader of a release log should be able to
    # see the population the verdict covers without taking "0 failures" on
    # trust; "400/400 byte-identical" is what a truncated corpus looks like when
    # only the content half gets reported.
    $stdout.puts "packaged gem #{File.basename(GEM_FILE)}: #{all.length} of " \
                 "#{declared_corpus_size(CORPUS)} declared corpus documents byte-identical"
  end

  private

  def under_repo_checkout?(path)
    real = File.realpath(path)
    root = File.realpath(REPO_ROOT)
    real.start_with?("#{root}#{File::SEPARATOR}")
  end

  def pairs
    @pairs ||= Dir.glob(File.join(CORPUS, "*.crv")).sort.filter_map do |crv|
      html = crv.sub(/\.crv\z/, ".html")
      [crv, html] if File.exist?(html)
    end
  end
end
