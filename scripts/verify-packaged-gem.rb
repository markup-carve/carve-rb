# frozen_string_literal: true

# Runs the Carve 0.2 conformance corpus through the gem that is about to be
# published.
#
# The distinction this script exists to make is between "the code in this
# checkout is correct" and "the artifact this job would push is correct". Every
# other check in this repository answers the first question. A gem is not its
# checkout: the gemspec's file globs decide what is packaged, and a packaged
# source tree builds under `gem install`'s toolchain rather than under
# `rake compile`.
#
# So this script refuses to look at the checkout at all. It is pointed at a
# GEM_HOME into which the built .gem was installed -- the same install path an
# embedder takes -- and it asserts, before rendering a single case, that the
# `carve` it just required resolved into that install root and nowhere else.
#
# The population half is not decoration: a truncated corpus that matches every
# case it still holds prints a clean verdict. scripts/verify-release-artifact.sh
# holds the conformance files byte-identical to the copy the pinned carve-rs
# vendors in `spec-conformance/`, so the population is the engine's, not a count
# written here.

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

CONFORMANCE = required_env("CARVE_SPEC_CONFORMANCE", "the spec's spec/0.2/conformance directory")
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

require "json"
require "minitest/autorun"

class PackagedGemTest < Minitest::Test
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
    loaded = $LOADED_FEATURES.grep(%r{/carve/(?:\d+\.\d+/)?carve\.#{Regexp.escape(DLEXT)}\z})
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

  def test_the_conformance_corpus_selects_cases
    assert File.directory?(CONFORMANCE), "CARVE_SPEC_CONFORMANCE=#{CONFORMANCE} is not a directory"
    refute_empty renders, "the conformance corpus selected no verified render examples"
    refute_empty lints, "the conformance corpus selected no source-only lint clause cases"
  end

  def test_the_packaged_gem_passes_the_conformance_corpus
    total = renders.length + lints.length
    failures = render_failures + lint_failures
    mismatches = failures.map(&:first).uniq

    # PRINTED, one line per case, BEFORE the assertion. The assertion message
    # truncates at twenty, and scripts/check-spec-drift.py reads this list to
    # decide which divergences are declared. The leading newline keeps the first
    # line off minitest's progress dots.
    $stdout.puts "" unless mismatches.empty?
    mismatches.each { |id| $stdout.puts "corpus mismatch: #{id}" }

    # The wording of this message and of the line below is what
    # scripts/check-spec-drift.py parses; keep both in step with it.
    assert_empty failures,
                 "#{mismatches.length} of #{total} corpus documents render differently " \
                 "from the spec through the gem this release would publish: " \
                 "#{failures.first(20).map { |id, why| "#{id} (#{why})" }.join(', ')}" \
                 "#{failures.length > 20 ? ' ...' : ''}. " \
                 "The carve-rs rev in ext/carve/Cargo.toml is the usual cause; bump it, commit " \
                 "the regenerated ext/carve/Cargo.lock, and tag again. Publishing is not " \
                 "reversible, so this refuses rather than warns."

    $stdout.puts "packaged gem #{File.basename(GEM_FILE)}: #{total} of #{total} declared corpus " \
                 "documents byte-identical (#{renders.length} verified render examples, " \
                 "#{lints.length} lint clause cases)"
  end

  private

  def under_repo_checkout?(path)
    real = File.realpath(path)
    root = File.realpath(REPO_ROOT)
    real.start_with?("#{root}#{File::SEPARATOR}")
  end

  def examples
    @examples ||= JSON.parse(File.read(File.join(CONFORMANCE, "examples.json"), encoding: "UTF-8"), max_nesting: false).fetch("examples")
  end

  def clause_cases
    @clause_cases ||= JSON.parse(File.read(File.join(CONFORMANCE, "clause-cases.json"), encoding: "UTF-8"), max_nesting: false).fetch("cases")
  end

  # The options the parse stage reads; a render example's other options are
  # render options and do not reach `parse`.
  def parse_keys
    @parse_keys ||= begin
      catalog = JSON.parse(File.read(File.join(CONFORMANCE, "..", "data", "options.json"), encoding: "UTF-8"))
      catalog.fetch("options").select { |option| (Array(option["read_by"]) & %w[parse resolve]).any? }
             .map { |option| option.fetch("name") }
    end
  end

  def renders
    @renders ||= examples.select do |row|
      row["kind"] == "render" && row["status"] == "verified" && row.dig("expected", "html").is_a?(String)
    end
  end

  def lints
    @lints ||= clause_cases.select do |row|
      row["kind"] == "lint" && row["input"].is_a?(String) &&
        (row["files"].nil? || row["files"].empty?) && (row["options"].nil? || row["options"].empty?)
    end
  end

  # An engine error or panic is one more divergence; aborting would leave the
  # rest unmeasured.
  def engine_failure(id)
    yield
  rescue Carve::EngineError, Carve::EnginePanic => e
    [id, "engine #{e.class.name.split('::').last}: #{e.message.lines.first.to_s.strip}"]
  end

  def render_failures
    renders.filter_map do |row|
      id = row.fetch("id")
      options = row["options"] || {}
      engine_failure(id) do
        next [id, "html"] if Carve.call("render", source: row.fetch("input"), options: options).fetch("html") != row.dig("expected", "html")

        tree = row.dig("expected", "tree")
        next unless tree.is_a?(Hash)

        parse_options = options.select { |key, _| parse_keys.include?(key) }
        actual = Carve.call("parse", source: row.fetch("input"), options: parse_options).fetch("tree")
        [id, "tree"] if actual != tree
      end
    end
  end

  # The stated fields of an expected diagnostic, as the spec's
  # scripts/expected-check.mjs compares them.
  PLACE = %w[line column endLine endColumn severity channel path].freeze

  # A UTF-8 byte offset as a 1-based line and code point column.
  def point(source, offset)
    before = source.byteslice(0, offset).force_encoding(Encoding::UTF_8)
    last = before.rindex("\n")
    { "line" => before.count("\n") + 1, "column" => (last ? before[(last + 1)..] : before).length + 1 }
  end

  def lint_entry(found, source)
    entry = found.slice("code", "severity", "channel", "path", "message")
    range = found["range"]
    return entry unless range

    start = point(source, range.fetch("startOffset"))
    finish = point(source, range.fetch("endOffset"))
    entry.merge(start, "endLine" => finish["line"], "endColumn" => finish["column"])
  end

  def fits?(found, want)
    found["code"] == want["code"] && PLACE.all? { |key| !want.key?(key) || found[key] == want[key] } &&
      (!want.key?("messageWhen") || message_fits?(found, want["messageWhen"]))
  end

  # `messageWhen` names a message variant of the rule in data/lint-rules.json;
  # the reported message has to be that variant's text, `${...}` filled in.
  def message_fits?(found, condition)
    rule = lint_rules[found["code"]]
    variant = Array(rule && rule["messages"]).find { |message| message.is_a?(Hash) && message["when"] == condition }
    return false unless variant

    pattern = variant.fetch("text").split(/\$\{[^}]+\}/, -1).map { |part| Regexp.escape(part) }.join(".*?")
    message = found["message"].to_s
    message.match?(/\A#{pattern}\z/m) && !message.include?("${")
  end

  def lint_rules
    @lint_rules ||= JSON.parse(File.read(File.join(CONFORMANCE, "..", "data", "lint-rules.json"), encoding: "UTF-8"))
                        .fetch("rules").to_h { |rule| [rule.fetch("id"), rule] }
  end

  # Each expected entry takes its own finding, so two expectations never share one.
  def all_matched?(found, wanted)
    owner = Array.new(found.length, -1)
    assign = lambda do |w, seen|
      found.each_index.any? do |i|
        next false if seen.include?(i) || !fits?(found[i], wanted[w])

        seen << i
        next false unless owner[i] == -1 || assign.call(owner[i], seen)

        owner[i] = w
        true
      end
    end
    wanted.each_index.all? { |w| assign.call(w, []) }
  end

  def lint_failures
    lints.filter_map do |row|
      id = row.fetch("id")
      source = row.fetch("input")
      engine_failure(id) do
        found = Carve.call("lint", source: source).fetch("diagnostics").map { |entry| lint_entry(entry, source) }
        expected = row.fetch("expected")
        wanted = Array(expected["diagnostics"]).map { |entry| entry.is_a?(String) ? { "code" => entry } : entry }
        if expected["diagnosticsComplete"] && found.length != wanted.length
          [id, "lint: diagnostics are not the complete list"]
        elsif expected["diagnosticsOrdered"] && !wanted.each_with_index.all? { |want, i| found[i] && fits?(found[i], want) }
          [id, "lint: diagnostics are not in the stated order"]
        elsif !all_matched?(found, wanted)
          [id, "lint: missing a reported diagnostic"]
        elsif Array(expected["notReported"]).any? { |code| found.any? { |entry| entry["code"] == code } }
          [id, "lint: reports a code it must not"]
        end
      end
    end
  end
end
