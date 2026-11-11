# frozen_string_literal: true

# Corpus pairs the pinned carve-rs declares it renders differently from the
# golden (`BEHIND_ON_PAIR` and `AHEAD_OF_PIN` in its tests/corpus.rs), with the
# HTML it renders today. The gem has no vote of its own: it may differ from the
# golden on exactly those pairs, and there it must render the engine's HTML.
# resources/engine-behind.txt carries the copy; scripts/check-engine-behind.py
# holds it to the engine.
module EngineBehind
  LEDGER = File.expand_path("../resources/engine-behind.txt", __dir__)

  module_function

  # slug -> declared HTML
  def load(path = LEDGER)
    declared = {}
    return declared unless File.file?(path)

    slug = nil
    lines = []
    File.read(path, encoding: "UTF-8").split("\n", -1).each do |line|
      if line.start_with?("== ")
        declared[slug] = lines.join("\n").strip if slug
        slug = line[3..].strip
        lines = []
      elsif slug
        lines << line
      end
    end
    declared[slug] = lines.join("\n").strip if slug
    declared
  end

  # The names of the pairs that differ from the golden, after the declared
  # pairs that render as the engine declares are taken out. A declared pair
  # that matches the golden, renders something else, or is missing from the
  # corpus is reported, so the copy cannot outlive the engine's declaration.
  def mismatches(pairs, declared = load)
    found = pairs.map { |crv, _| File.basename(crv, ".crv") }
    absent = (declared.keys - found).sort.map { |slug| "#{slug} (declared in engine-behind.txt, not in this corpus)" }
    absent + pairs.filter_map do |crv, html|
      name = File.basename(crv, ".crv")
      want = File.read(html).sub(/\n+\z/, "")
      got = Carve.to_html(File.read(crv)).sub(/\n+\z/, "")
      if declared.key?(name)
        "#{name} (declared in engine-behind.txt)" if got.strip != declared[name] || got == want
      elsif got != want
        name
      end
    end
  end
end
