# frozen_string_literal: true

# THIS GEM'S TREE IS CARVE-RS'S TREE. Nothing here said so.
#
# carve-rb serializes carve-rs's AST; that is the whole contract of a binding.
# A binding cannot be AHEAD of the engine it wraps, so every difference between
# the two trees is this gem's - a stale pin, or a gap in the binding - and there
# is no window in which this repository is the one that is right. Until this
# file existed, the only thing that could state that was the binding-parity gate
# in markup-carve/carve's `scripts/ast-conformance.mjs`, on its 06:15 UTC
# schedule, in another repository. It fired twice inside a week: once on a pin
# 28 commits behind (#82), and once on a pin ONE DAY old, over three documents
# (`05-lists-23`,
# `380-a-terminal-comment-line-still-leaves-an-empty-verse-line`,
# `395-a-longer-run-at-a-list-boundary-is-written-as-exactly-three-blank-lines`),
# fixed by #84.
#
# WHY EVERY OTHER CHECK HERE PASSED BOTH TIMES. Each one compares this gem to
# its own PINNED WORLD, and a stale pin is self-consistent inside it:
#
#   * corpus_test.rb compares HTML. `380-...` is an AST-only divergence - the
#     old pin emitted an extra `comment` node and the rendered HTML was
#     byte-identical.
#   * the corpus runs against the spec commit the PINNED ENGINE pins, which is
#     deliberate (see the long note in ci.yml) and is exactly what makes a stale
#     pin self-consistent: `395-...` was added to the spec after that gitlink,
#     so it was not in the corpus this repository checked at all.
#   * corpus_ast_types_test.rb, corpus_ast_fields_test.rb and
#     corpus_ast_schema_shape_test.rb are ledgers over that same pinned corpus.
#     A list splitting into two lists changes no type, no field name and no
#     schema shape.
#   * the `engine-pin` job fails only on AGE, with a 14-day bound. The pin was
#     one day old.
#   * `corpus-drift` reports rather than gates, and its number moved 144, 145,
#     147 across the runs that straddle this. Three documents cannot be read out
#     of that.
#
# SO THE OTHER SIDE HAS TO BE AN ENGINE THE PIN DID NOT CHOOSE, AND THIS IS THE
# PART THAT WAS MEASURED RATHER THAN ASSUMED. #85 proposed comparing the gem
# against the engine binary it was BUILT FROM, on the grounds that both sides
# then come from the same revision. Built and run, that check is green on the
# stale pin and green on the current one:
#
#     gem @ 54f596f2 vs carve --json @ 54f596f2  ->  0 of 1356 diverge
#     gem @ 3250454b vs carve --json @ 3250454b  ->  0 of 1356 diverge
#
# while the two engine revisions themselves disagree on exactly the three
# documents above. Of course they do: one revision compared with itself agrees
# with itself. It would still catch a binding wired to the wrong options, but
# for the drift it exists to find it is a check that cannot fail - the shape
# catalogued in markup-carve/carve#755 and already shipped three times in this
# gem's population floors.
#
# So the reference is carve-rs at MAIN, which is what the upstream gate has
# always compared against, and the corpus is spec main rather than the pinned
# spec, because a document the spec gained after the pinned engine's gitlink is
# precisely the one the pinned corpus cannot hold. Both are outside the pinned
# world; either alone would leave half the drift invisible.
#
# AND IT IS STILL CLEARABLE BY AN ACTION TAKEN HERE, which is the property the
# corpus gate had to be re-aimed to get (#78). That gate could not be: the spec
# adds documents no engine implements yet, so a pull request here could be red
# with the fix living in another repository. carve-rs main has no such state -
# whatever it does is by definition implementable here, because bumping the pin
# to it makes these two trees equal by construction. One line in
# ext/carve/Cargo.toml plus the lock.
#
# THAT SENTENCE ASSUMED THE PIN WAS A REVISION, and #136 made it a published
# crate. The clearing action now exists only while a newer carve-lang is
# published; see publication_window? below for what the verdict does in the
# window where it is not.
#
# SO THE BUILT-FROM COMPARISON COMES BACK, for the half of the question it can
# answer. #85's version was rejected above as the only reference, because one
# revision compared with itself agrees with itself and the drift goes unseen.
# What the same paragraph concedes is that it still catches a binding wired to
# the wrong options - and that is precisely what the window would otherwise
# swallow, since publishing an engine does not fix a gem that asks it the wrong
# question. So there are two comparisons with two different verdicts: against
# the PINNED engine, always fatal, no window; against MAIN, fatal unless the
# pin is already the newest release.
#
# IT IS NOT THE DISTANCE CHECK the `engine-pin` job deliberately refuses, and
# the two are complements rather than rivals. That job prints the lag and fails
# only on AGE, because "behind main" is red for every merge upstream and says
# nothing about whether the lag matters. This fails only when the lag CHANGES A
# TREE, which is the half of the question a commit count cannot answer - a pin
# fifty commits behind an engine that only refactored passes here.

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "carve"
require "corpus_population"

class BindingParityTest < Minitest::Test
  include CorpusPopulation

  # A `carve` binary built from carve-rs at MAIN. Not the pinned revision: see
  # the measurement above, where that comparison is green on both pins.
  ENGINE = ENV.fetch("CARVE_ENGINE_BIN", nil)

  # The revision that binary was built from, for the failure message. Provenance
  # only - nothing branches on it.
  ENGINE_REV = ENV.fetch("CARVE_ENGINE_REV", nil)

  # A `carve` binary built from the revision ext/carve/Cargo.toml pins - the
  # engine this gem actually embeds. Compared against separately and without
  # any window: see the header.
  PINNED_ENGINE = ENV.fetch("CARVE_PINNED_ENGINE_BIN", nil)

  # The newest carve-lang RELEASED on crates.io, resolved by the job from the
  # sparse index. It is what says whether a difference below is this gem's to
  # fix; see the note on publication_window? Unset or empty means the question
  # was not asked, and the verdict is then the strict one.
  PUBLISHED = ENV.fetch("CARVE_PUBLISHED_ENGINE", "").strip

  # A corpus directory, deliberately NOT CARVE_SPEC_CORPUS. That one is the
  # corpus the pinned engine's spec gitlink names, and reading it here would
  # rebuild the self-consistency this file exists to break.
  CORPUS = ENV.fetch("CARVE_PARITY_CORPUS", nil)

  def corpus_files
    Dir.glob(File.join(CORPUS, "*.crv")).sort
  end

  # The pin, read through the one script that resolves it, so that a failure can
  # say which revision the gem is standing on. Never parsed here with a regular
  # expression - scripts/pinned-spec-commit.py says why. Best-effort: this is
  # prose in a message, and a missing python3 must not fail a parity run.
  def pinned_revision
    out, _err, status = Open3.capture3(
      "python3", "scripts/pinned-spec-commit.py", "--print", "engine",
      "--engine", "carve-rs",
      "--manifest", "ext/carve/Cargo.toml", "--lock", "ext/carve/Cargo.lock"
    )
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  # The pinned carve-lang version, read from the manifest and the lock through
  # the same script. Needs no checkout and no release tag, which is why the
  # verdict branches on this rather than on the revision above.
  def pinned_version
    out, _err, status = Open3.capture3(
      "python3", "scripts/pinned-spec-commit.py", "--print", "version",
      "--manifest", "ext/carve/Cargo.toml", "--lock", "ext/carve/Cargo.lock"
    )
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  # IS A DIFFERENCE HERE SOMETHING A COMMIT IN THIS REPOSITORY CAN CLOSE?
  #
  # The header above answers yes, and gives the reason: bumping the pin to
  # carve-rs main makes the two trees equal by construction, one line in
  # ext/carve/Cargo.toml plus the lock. That held while the pin WAS a carve-rs
  # revision. #136 replaced it with the published crate, so `gem install` needs
  # only rubygems and crates.io - and took the property with it. Between a
  # carve-rs merge and its release there is no version for the pin to move to,
  # and the gate then asks for an edit nobody can write.
  #
  # Measured on 2026-09-24: carve-rs main was 41 commits past the `0.1.6` tag,
  # 0.1.7 was a DRAFT release with no tag, crates.io served 0.1.6, and this
  # gate reported 35 of 1858 documents. Every one of them was this window.
  #
  # So the window is a verdict rather than a pass. It needs a POSITIVE fact -
  # the pin equals the newest RELEASED carve-lang, resolved from the sparse
  # index by the job - and anything short of that is strict: a pin behind a
  # published version fails and names the bump, which is the only state a
  # commit here can change, and an unresolved pin or an unset variable fails
  # too. The release gate is unaffected either way; release.yml refuses to tag
  # while resources/spec-drift.txt declares an open window.
  def self.publication_window?(pinned, published)
    return false if pinned.nil? || pinned.empty?
    return false if published.nil? || published.empty?

    pinned == published
  end

  # The engine's own answer for one document, from whichever `carve` binary
  # the caller is holding the gem to.
  def engine_tree(binary, path)
    stdout, stderr, status = Open3.capture3(binary, "--json", path)
    # A refusal is an answer, and it has to be comparable to the gem's. Reported
    # rather than swallowed: an engine that refuses every document would
    # otherwise make this run vacuous.
    return [:refused, stderr.strip] unless status.success?

    [:tree, JSON.parse(stdout, max_nesting: false)]
  end

  # This gem's answer, through the entry point Carve.parse uses. Compared as
  # parsed JSON rather than as bytes: key order and whitespace are not part of
  # the contract, the tree is.
  def gem_tree(source)
    [:tree, JSON.parse(Carve._to_ast_json(source), max_nesting: false)]
  rescue StandardError => e
    [:refused, e.message]
  end

  # Where two trees first disagree, as a path a reader can follow into the JSON.
  # A bare "not equal" over a 40 KB tree is a finding nobody can act on.
  def first_difference(mine, theirs, path = "$")
    return "#{path}: #{mine.class} here, #{theirs.class} in the engine" unless mine.instance_of?(theirs.class)

    case mine
    when Hash then first_hash_difference(mine, theirs, path)
    when Array then first_array_difference(mine, theirs, path)
    else mine == theirs ? nil : "#{path}: #{mine.inspect} here, #{theirs.inspect} in the engine"
    end
  end

  def first_hash_difference(mine, theirs, path)
    (mine.keys | theirs.keys).each do |key|
      return "#{path}.#{key}: only in the gem" unless theirs.key?(key)
      return "#{path}.#{key}: only in the engine" unless mine.key?(key)

      found = first_difference(mine[key], theirs[key], "#{path}.#{key}")
      return found if found
    end
    nil
  end

  def first_array_difference(mine, theirs, path)
    if mine.length != theirs.length
      return "#{path}: #{mine.length} children here, #{theirs.length} in the engine"
    end

    mine.each_with_index do |item, index|
      found = first_difference(item, theirs[index], "#{path}[#{index}]")
      return found if found
    end
    nil
  end

  def divergences(binary, files)
    files.filter_map do |path|
      mine = gem_tree(File.read(path))
      theirs = engine_tree(binary, path)
      next if mine == theirs

      detail =
        if mine.first == :tree && theirs.first == :tree
          first_difference(mine.last, theirs.last)
        else
          "the gem #{mine.first == :refused ? "refused (#{mine.last})" : "parsed"}, " \
            "the engine #{theirs.first == :refused ? "refused (#{theirs.last})" : "parsed"}"
        end
      "  #{File.basename(path, ".crv")}: #{detail}"
    end
  end

  # The skip below is a convenience for a plain checkout with no carve-rs build
  # and no spec beside it. In the job that exists to run this, it is a hole:
  # rename or drop the `env:` block and the gate SKIPS and exits 0, having
  # compared nothing. That is the shape corpus_wiring_test.rb was written for,
  # after this gem shipped it once already - measured there at "2 runs, 0
  # assertions, 0 failures, 0 errors, 2 skips" over an engine diverging on 24
  # documents.
  #
  # So the job sets CARVE_REQUIRE_PARITY=1 and this refuses the skip there. The
  # flag is upstream's CARVE_REQUIRE_ALL_ENGINES spelled for one engine, and it
  # is set in the workflow next to the two variables it guards, so dropping the
  # wiring cannot quietly drop the guard with it.
  def test_the_gate_is_wired_up_where_it_is_supposed_to_run
    return unless ENV["CARVE_REQUIRE_PARITY"] == "1"

    refute_nil ENGINE,
               "CARVE_REQUIRE_PARITY=1 but CARVE_ENGINE_BIN is unset, so the parity comparison " \
               "below skips and this run reports success having compared nothing. See the " \
               "binding-parity job in .github/workflows/ci.yml."
    refute_nil CORPUS,
               "CARVE_REQUIRE_PARITY=1 but CARVE_PARITY_CORPUS is unset, so the parity " \
               "comparison below skips and this run reports success having compared nothing."
    refute_empty PUBLISHED,
                 "CARVE_REQUIRE_PARITY=1 but CARVE_PUBLISHED_ENGINE is unset, so the verdict " \
                 "below cannot tell a stale pin from the window between a carve-rs merge and " \
                 "its release, and reports every difference as a stale pin. The resolver step " \
                 "is `Resolve the newest released carve-lang` in .github/workflows/ci.yml."
    refute_nil PINNED_ENGINE,
               "CARVE_REQUIRE_PARITY=1 but CARVE_PINNED_ENGINE_BIN is unset, so the comparison " \
               "against the engine this gem embeds skips. That is the one with no window, and " \
               "without it a binding defect passes as unreleased upstream drift."
  end

  # AGAINST THE ENGINE THIS GEM EMBEDS, with no window and nothing to declare.
  # Both sides are the same revision, so a difference cannot be upstream being
  # ahead: it is the gem asking its own engine a different question from the
  # one `carve --json` asks. Publishing a new carve-lang would not fix it,
  # which is why this one never softens.
  def test_the_gem_reports_the_same_tree_as_the_engine_it_embeds
    skip "CARVE_PINNED_ENGINE_BIN / CARVE_PARITY_CORPUS not set (see .github/workflows/ci.yml)" \
      unless PINNED_ENGINE && CORPUS

    assert File.executable?(PINNED_ENGINE),
           "CARVE_PINNED_ENGINE_BIN=#{PINNED_ENGINE} is not an executable."

    files = corpus_files
    assert_whole_corpus(CORPUS, files.length, "corpus documents compared against the pinned engine")

    assert_empty divergences(PINNED_ENGINE, files),
                 "this gem and the carve-rs revision it embeds disagree on the tree. Both sides " \
                 "are the same engine, so this is the binding: ext/carve/src/lib.rs builds its " \
                 "own Options for `_to_ast_json` and `carve --json` builds its own, and those " \
                 "two have to ask for the same thing. No pin bump and no engine release closes " \
                 "this one."
  end

  # The window is an EXACT match against the newest released version, and the
  # cases below are the three ways a looser reading would be wrong: a pin one
  # release behind is the stale pin this gate exists to catch, and an answer
  # nobody resolved is not evidence of anything.
  def test_the_publication_window_needs_the_pin_to_be_the_newest_release
    assert BindingParityTest.publication_window?("0.1.6", "0.1.6")
    refute BindingParityTest.publication_window?("0.1.6", "0.1.7")
    refute BindingParityTest.publication_window?(nil, "0.1.6")
    refute BindingParityTest.publication_window?("0.1.6", "")
  end

  # The ordering the sparse index is read with. `sort` puts 0.1.10 before
  # 0.1.9, and a wrong newest here turns a stale pin into a declared window.
  def test_the_newest_release_is_ordered_numerically_and_skips_yanks
    Dir.mktmpdir do |dir|
      index = File.join(dir, "carve-lang")
      File.write(index, <<~INDEX)
        {"name":"carve-lang","vers":"0.1.9","yanked":false}
        {"name":"carve-lang","vers":"0.1.10","yanked":false}
        {"name":"carve-lang","vers":"0.2.0","yanked":true}
      INDEX
      out, _err, status = Open3.capture3(
        "python3", "scripts/newest-published-engine.py", "--index", index
      )

      assert_predicate status, :success?
      assert_equal "0.1.10", out.strip
    end
  end

  def test_the_gem_reports_the_same_tree_as_carve_rs
    skip "CARVE_ENGINE_BIN / CARVE_PARITY_CORPUS not set (see .github/workflows/ci.yml)" unless ENGINE && CORPUS

    assert File.executable?(ENGINE),
           "CARVE_ENGINE_BIN=#{ENGINE} is not an executable. Build it from a carve-rs checkout " \
           "at main: `cargo build --release --bin carve`."

    files = corpus_files

    # Without this, a mistyped or truncated corpus produces an empty file list,
    # the comparison runs over nothing, and the run reads as clean - the
    # variant-2 defect catalogued in markup-carve/carve#755, which this gem has
    # already shipped three spellings of.
    assert_whole_corpus(CORPUS, files.length, "corpus documents compared against carve-rs")

    diverging = divergences(ENGINE, files)
    version = pinned_version
    window = diverging.any? && self.class.publication_window?(version, PUBLISHED)
    report_publication_window(diverging, files.length, version) if window

    assert_empty(window ? [] : diverging,
                 "#{diverging.length} of #{files.length} corpus documents parse to a different " \
                 "tree in this gem than in carve-rs#{ENGINE_REV ? " #{ENGINE_REV}" : ""}:\n" \
                 "#{diverging.join("\n")}\n" \
                 "A binding has no vote of its own: carve-rs is right by definition here, so " \
                 "every one of these is this gem's.\n" \
                 "#{bump_advice(version)}\n" \
                 "A binding defect would show up in the comparison against the pinned " \
                 "engine above, which has no window; this one is about the distance to main.")
  end

  # What to do about it, in the terms of the pin this gem actually carries.
  # Said as three different sentences because they ask for three different
  # actions, and the one that used to cover all of them - "usually the pin is
  # stale, bump it" - was wrong for the state this gate spent 2026-09-23 and
  # 2026-09-24 in.
  def bump_advice(version)
    if version.nil?
      return "The pin could not be read from ext/carve/Cargo.toml and ext/carve/Cargo.lock, " \
             "so this run cannot say whether a bump would close this. Run " \
             "`python3 scripts/pinned-spec-commit.py --print version --manifest " \
             "ext/carve/Cargo.toml --lock ext/carve/Cargo.lock` and fix what it reports."
    end

    if PUBLISHED.empty?
      return "CARVE_PUBLISHED_ENGINE is unset, so this run cannot tell a stale pin from the " \
             "window between a carve-rs merge and its release. See the binding-parity job in " \
             ".github/workflows/ci.yml; the pin is carve-lang #{version}."
    end

    if PUBLISHED == version
      return "The pin is already carve-lang #{version}, which is the newest released engine, " \
             "so no bump can close this and the difference is the binding's own."
    end

    "THE PIN IS STALE. carve-lang #{PUBLISHED} is the newest released engine and " \
      "ext/carve/Cargo.toml pins #{version}#{pinned_revision ? " (carve-rs #{pinned_revision})" : ""}. " \
      "Bump it and the lock together, then `rake compile` so lib/carve/ is rebuilt from the new " \
      "version - an unrebuilt extension keeps the old tree and this stays red."
  end

  # The window still prints everything a failure would, because its size is the
  # thing worth watching: it is how long the published gem has been rendering
  # documents by a superseded rule, and resources/spec-drift.txt is where that
  # gets written down per document.
  def report_publication_window(diverging, total, version)
    puts "::warning::carve-rs main parses #{diverging.length} of #{total} corpus documents " \
         "differently from carve-lang #{version}, which is the newest released engine. No " \
         "commit here can close that - publishing the next carve-lang can. See " \
         "markup-carve/carve-rb#142."
    puts diverging
  end
end
