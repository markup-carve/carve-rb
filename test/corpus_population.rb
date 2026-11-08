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
# resources/examples/{core,extensions}.md plus the edge-case sections (one
# edge-cases.md page up to spec 0.1.13, one edge-cases/NNNN-slug.md file per
# section after it; see scripts/lib/example-sections.mjs in the spec
# repository), and the generator refuses
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
  SECTION_DIR = "edge-cases"
  SECTION_NUMBER = /\A(\d{4,})-/

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
    input = nil
    lines.each_with_index do |line, index|
      if fence
        if line.start_with?(fence) && line[fence.length..].strip.empty?
          fence = nil
          input = nil
        else
          input&.push(line)
        end
        next
      end
      ticks = line[/\A`*/].length
      if ticks >= 3
        fence = line[0, ticks]
        language = line[ticks..].strip
        block[language] += 1 if block && block.key?(language)
        input = (block[:inputs] << []).last if block && language == "carve"
        next
      end
      trimmed = line.strip
      if block.nil?
        if COMPARE_OPEN.match?(trimmed)
          block = { line: index + 1, marker: MARKER_RUN.match(trimmed)[0], "carve" => 0, "html" => 0,
                    modifiers: trimmed.split(/\s+/).drop(2), inputs: [] }
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

  # The bytes the generator writes for one authored input, transforms in its order.
  def self.input_bytes(lines, modifiers)
    out = "#{lines.join("\n")}\n"
    out = out.sub(/\n\z/, "") if modifiers.include?("no-final-newline")
    out = out.gsub("\n", "\r\n") if modifiers.include?("crlf")
    out = out.gsub("\n", "\r") if modifiers.include?("cr")
    out = "\uFEFF#{out}" if modifiers.include?("bom")
    out = out.gsub("\u2400", "\u0000") if modifiers.include?("nul")
    out.b
  end

  # The source pages in the spec's reading order. The spec split edge-cases.md
  # into edge-cases/NNNN-slug.md after 0.1.13; either layout is read, the single
  # page when it exists.
  def self.example_pages(examples_dir)
    pages = EXAMPLE_PAGES.first(2).map { |page| File.join(examples_dir, page) }
    single = File.join(examples_dir, EXAMPLE_PAGES.last)
    sections = File.join(examples_dir, SECTION_DIR)
    return pages + [single] if File.exist?(single) || !File.directory?(sections)

    files = Dir.children(sections).select { |name| name.end_with?(".md") && name != "README.md" }
    raise "#{sections} holds no section files; the corpus source is incomplete" if files.empty?

    pages + files.sort_by { |name| section_order(name) }.map { |name| File.join(sections, name) }
  end

  def self.section_order(name)
    number = SECTION_NUMBER.match(name)
    [number ? number[1].to_i : Float::INFINITY, name]
  end

  # A section file may open with `page:` front matter, which is not section content.
  def self.section_body(text)
    lines = text.split("\n")
    close = lines.first == "---" && lines.drop(1).index("---")
    close ? lines.drop(close + 2) : lines
  end

  # Counts the example pairs the spec DECLARES. corpus_dir is
  # CARVE_SPEC_CORPUS, i.e. <spec>/tests/corpus.
  #
  # Every `carve` fence inside a compare block is one pair. Each block must
  # carry equal, nonzero counts; literal fenced content is ignored.
  def declared_corpus_size(corpus_dir)
    declared_corpus_inputs(corpus_dir).length
  end

  # One entry per authored pair: the input bytes the generator writes for it.
  def declared_corpus_inputs(corpus_dir)
    examples_dir = File.expand_path(File.join(corpus_dir, "..", "..", "resources", "examples"))
    declared = []
    CorpusPopulation.example_pages(examples_dir).each do |path|
      # Not a soft skip. Without this file there is no independent statement of
      # how big the corpus should be, and a corpus check with nothing to compare
      # against is the failure shape this helper exists to remove.
      assert File.exist?(path),
             "no corpus source page at #{path}. tests/corpus is generated from these pages; " \
             "if the spec moved them, this helper has to move with them"
      lines = CorpusPopulation.section_body(File.read(path, encoding: "utf-8"))
      CorpusPopulation.census_compare_pairs(lines).each do |block|
        assert_nil block[:unclosed], "unclosed compare block in #{path} at line #{block[:line]}"
        assert_nil block[:unclosed_fence], "unclosed fence in #{path}"
        assert block["carve"].positive? && block["carve"] == block["html"],
               "unpaired or empty compare block in #{path} at line #{block[:line]}: " \
               "#{block['carve']} carve, #{block['html']} html"
        declared.concat(block[:inputs].map { |input| CorpusPopulation.input_bytes(input, block[:modifiers]) })
      end
    end
    refute_empty declared,
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
  #
  # Since markup-carve/carve#5244 the generator writes one pair per DISTINCT
  # input, so authored pairs with identical bytes share one corpus file. A
  # corpus that still holds two identical inputs comes from a generator before
  # that change, which wrote every authored pair. A legacy corpus with only its
  # duplicate copies removed is read as deduplicated; it still holds, and
  # assert_whole_corpus still renders, every distinct input.
  def expected_corpus_size(corpus_dir)
    inputs = declared_corpus_inputs(corpus_dir)
    written = Dir.glob(File.join(corpus_dir, "*.crv")).map { |path| File.binread(path) }
    written.uniq.length == written.length ? inputs.uniq.length : inputs.length
  end

  def assert_whole_corpus(corpus_dir, got, what)
    declared = expected_corpus_size(corpus_dir)
    assert_equal declared, got,
                 "#{what}: #{got}, but the spec's example pages declare #{declared}. Every " \
                 "::: compare block in resources/examples/{core,extensions}.md and the " \
                 "edge-case sections yields one corpus pair per distinct `carve` input, so a difference means the corpus " \
                 "at #{corpus_dir} " \
                 "is not the one those pages describe - a truncated or stale checkout, a wrong " \
                 "CARVE_SPEC_CORPUS, or a corpus that needs regenerating (npm run corpus:build " \
                 "in the spec repository). It does not mean this run was clean."

    # Content, not only size: every distinct authored input is on disk, and
    # nothing else is.
    want = declared_corpus_inputs(corpus_dir).uniq
    have = Dir.glob(File.join(corpus_dir, "*.crv")).map { |path| File.binread(path) }.uniq
    missing = (want - have).length
    extra = (have - want).length
    assert missing.zero? && extra.zero?,
           "#{what}: the corpus at #{corpus_dir} lacks #{missing} input(s) the spec's example " \
           "pages declare and holds #{extra} they do not. It is not the corpus those pages " \
           "describe; regenerate it (npm run corpus:build in the spec repository)."
  end
end
