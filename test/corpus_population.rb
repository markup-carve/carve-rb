# frozen_string_literal: true

# How many documents the spec corpus should hold, derived rather than recorded.
#
# ONE spelling of "a corpus runner must not report success over an empty or
# short population" (the variant-2 defect catalogued in markup-carve/carve#755).
# This gem had THREE of them, each with its own literal and its own wrong
# number: corpus_test.rb said "the corpus has ~500", corpus_ast_types_test.rb
# said "~650", corpus_ast_fields_test.rb said "~1000", and all three let a run
# through at 400 documents against a corpus of 1131.
#
# That gap is not theoretical. Measured on a sibling binding carrying the
# identical floor, a corpus cut to 420 documents printed
# "corpus: 420/420 documents byte-identical" - a clean verdict over 37 percent
# of the corpus, with every then-diverging document simply absent
# (markup-carve/carve-rb#68).
#
# THE COMPARISON HAS TO BE AGAINST SOMETHING THE RUNNER DOES NOT ITSELF READ AS
# THE POPULATION. Deriving "how many documents should there be" from the corpus
# directory would be a check that reads its own input hiding inside a fix for a
# check that cannot fail: emptying the directory would move both sides and the
# guard would still pass.
#
# So the reference is the corpus's SOURCE, not the corpus. tests/corpus is
# generated from the `::: compare` blocks in
# resources/examples/{core,extensions,edge-cases}.md (see
# scripts/generate-corpus.mjs in the spec repository), and the generator refuses
# to write a corpus where the two disagree. Both live in the same spec checkout
# CI already clones, one directory away from CARVE_SPEC_CORPUS - the same route
# corpus_ast_schema_shape_test.rb already takes to resources/ast-schema.json.
#
# Counting the source rather than recording a number also means there is no
# literal left to go stale: adding an example upstream moves the expectation on
# the next spec checkout, without anyone editing these files. A hardcoded 1131
# would be this same defect with a bigger number.
module CorpusPopulation
  # The pages the corpus is generated from, in the order the generator reads
  # them. Order is irrelevant to a count; the list is the generator's.
  EXAMPLE_PAGES = %w[core.md extensions.md edge-cases.md].freeze

  # Mirrors the generator: `::: compare`, or a longer colon run, with optional
  # modifiers such as `::: compare no-render`.
  COMPARE_OPEN = /\A:{3,}\s+compare(\s+\S.*)?\z/
  MARKER_RUN = /\A:{3,}/

  # An independent census of the pairs one example page declares, ported from
  # the spec's scripts/lib/example-pair-census.mjs. One entry per `::: compare`
  # block, in source order, carrying how many `carve` and `html` fences the
  # author put in it.
  #
  # A block may hold SEVERAL pairs - one per `carve` fence - so counting the
  # blocks reports N-1 pairs too few for a block of N pairs, which is a gate
  # that cannot detect what it claims to detect.
  #
  # Fences are tracked by their literal opening backtick run, because inside a
  # fence nothing is markup: a ```` example whose content is a ``` carve line
  # declares no pair of its own.
  #
  # A plain function over lines, deliberately. The counting used to be inline in
  # declared_corpus_size, where it could only be exercised by pointing the suite
  # at a real spec checkout, and the one corpus shape that would have caught the
  # block-counting defect no longer exists upstream.
  def self.census_compare_pairs(lines)
    blocks = []
    block = nil
    fence = nil
    lines.each_with_index do |line, index|
      if fence
        fence = nil if line.start_with?(fence) && line[fence.length..].strip.empty?
        next
      end
      ticks = line[/\A`*/].length
      if ticks >= 3
        fence = line[0, ticks]
        language = line[ticks..].strip
        block[language] += 1 if block && block.key?(language)
        next
      end
      trimmed = line.strip
      if block.nil?
        if COMPARE_OPEN.match?(trimmed)
          block = { line: index + 1, marker: MARKER_RUN.match(trimmed)[0], "carve" => 0, "html" => 0 }
        end
        next
      end
      next unless trimmed == block[:marker]

      blocks << block
      block = nil
    end
    blocks << block.merge(unclosed: true) if block
    blocks << { unclosed_fence: fence } if fence
    blocks
  end

  # Counts the example pairs the spec DECLARES. corpus_dir is
  # CARVE_SPEC_CORPUS, i.e. <spec>/tests/corpus.
  #
  # Every `carve` fence inside a compare block is one pair. Each block must
  # carry equal, nonzero counts; literal fenced content is ignored.
  def declared_corpus_size(corpus_dir)
    examples_dir = File.expand_path(File.join(corpus_dir, "..", "..", "resources", "examples"))
    declared = 0
    EXAMPLE_PAGES.each do |page|
      path = File.join(examples_dir, page)
      # Not a soft skip. Without this file there is no independent statement of
      # how big the corpus should be, and a corpus check with nothing to compare
      # against is the failure shape this helper exists to remove.
      assert File.exist?(path),
             "no corpus source page at #{path}. tests/corpus is generated from these pages; " \
             "if the spec moved them, this helper has to move with them"
      CorpusPopulation.census_compare_pairs(File.read(path).split("\n")).each do |block|
        assert_nil block[:unclosed], "unclosed compare block in #{path} at line #{block[:line]}"
        assert_nil block[:unclosed_fence], "unclosed fence in #{path}"
        assert block["carve"].positive? && block["carve"] == block["html"],
               "unpaired or empty compare block in #{path} at line #{block[:line]}: " \
               "#{block['carve']} carve, #{block['html']} html"
        declared += block["carve"]
      end
    end
    refute_equal 0, declared,
                 "the corpus source pages under #{examples_dir} declare no ::: compare blocks " \
                 "at all; this is a wiring problem, not a corpus of size zero"
    declared
  end

  # The only place this gem decides whether a corpus population is whole. `got`
  # is what the caller actually processed; `what` names it for the failure.
  #
  # Equality rather than a floor, deliberately. A floor is what went stale three
  # times here, and it answers the wrong question: "at least 400" cannot tell a
  # whole corpus from a truncated checkout, and truncation is the failure being
  # guarded against.
  def assert_whole_corpus(corpus_dir, got, what)
    declared = declared_corpus_size(corpus_dir)
    assert_equal declared, got,
                 "#{what}: #{got}, but the spec's example pages declare #{declared}. Every " \
                 "::: compare block in resources/examples/{core,extensions,edge-cases}.md " \
                 "yields one corpus pair per `carve` fence, so a difference means the corpus " \
                 "at #{corpus_dir} " \
                 "is not the one those pages describe - a truncated or stale checkout, a wrong " \
                 "CARVE_SPEC_CORPUS, or a corpus that needs regenerating (npm run corpus:build " \
                 "in the spec repository). It does not mean this run was clean."
  end
end
