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
# IT IS NOT THE DISTANCE CHECK the `engine-pin` job deliberately refuses, and
# the two are complements rather than rivals. That job prints the lag and fails
# only on AGE, because "behind main" is red for every merge upstream and says
# nothing about whether the lag matters. This fails only when the lag CHANGES A
# TREE, which is the half of the question a commit count cannot answer - a pin
# fifty commits behind an engine that only refactored passes here.

require "minitest/autorun"
require "json"
require "open3"
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
      "--manifest", "ext/carve/Cargo.toml", "--lock", "ext/carve/Cargo.lock"
    )
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  # The engine's own answer for one document.
  def engine_tree(path)
    stdout, stderr, status = Open3.capture3(ENGINE, "--json", path)
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

  def divergences(files)
    files.filter_map do |path|
      mine = gem_tree(File.read(path))
      theirs = engine_tree(path)
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

    diverging = divergences(files)
    pinned = pinned_revision

    assert_empty diverging,
                 "#{diverging.length} of #{files.length} corpus documents parse to a different " \
                 "tree in this gem than in carve-rs#{ENGINE_REV ? " #{ENGINE_REV}" : ""}:\n" \
                 "#{diverging.join("\n")}\n" \
                 "A binding has no vote of its own: carve-rs is right by definition here, so " \
                 "every one of these is this gem's.\n" \
                 "USUALLY THE PIN IS STALE. ext/carve/Cargo.toml pins " \
                 "#{pinned || "(could not be resolved)"}; bump it and the lock together, then " \
                 "`rake compile` so lib/carve/ is rebuilt from the new revision - an unrebuilt " \
                 "extension keeps the old tree and this stays red.\n" \
                 "If the pin is already at that revision the difference is in the binding " \
                 "itself: ext/carve/src/lib.rs builds its own Options for `_to_ast_json`, and " \
                 "`carve --json` builds its own. Those two have to ask for the same thing."
  end
end
