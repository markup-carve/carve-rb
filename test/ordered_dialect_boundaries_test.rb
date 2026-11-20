# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "carve"

class OrderedDialectBoundariesTest < Minitest::Test
  def test_ordered_dialect_boundaries
    cases = JSON.parse(File.read(File.join(__dir__, "fixtures", "ordered-dialect-boundaries.json")))
    assert_equal 17, cases.length
    cases.each do |row|
      source = row.fetch("source")
      assert_equal row.fetch("html"), Carve.to_html(source).sub(/\n+\z/, ""), row.fetch("name")
      assert_equal source, Carve.to_carve(source), row.fetch("name")
      assert_equal source, Carve.to_carve(source + "\n"), row.fetch("name")
      imported = Carve.from_html(row.fetch("inputHtml"))
      assert_equal source, imported[:value], row.fetch("name")
      assert_empty imported[:report][:diagnostics], row.fetch("name")
      assert_equal row.fetch("html"), Carve.to_html(imported[:value]).sub(/\n+\z/, ""), row.fetch("name")
    end
  end

  def test_article_retains_raw_payload_as_code
    assert_equal "<pre><code class=\"language-html\">&lt;b&gt;x&lt;/b&gt;\n</code></pre>",
                 Carve.to_html("``` =html\n<b>x</b>\n```", profile: "article")
  end

  def test_markdown_import_uses_the_engine_call
    cases = JSON.parse(File.read(File.join(__dir__, "fixtures", "markdown-ordered-delimiters.json")))
    assert_equal 3, cases.length
    expected = {
      "CommonMark 296" => "{start=10}\n. foo\n  - bar\n",
      "CommonMark 297" => "{start=10}\n. foo\n\n- bar\n",
      "CommonMark 302" => ". foo\n. bar\n\n\n\n{start=3}\n. baz\n",
    }
    cases.each do |row|
      # C2-T-003 leaves the importer outside the 0.2 core, while the pinned
      # engine still exposes it through the generic importDocument call.
      result = Carve.call("importDocument", source: row.fetch("markdown"), from: "markdown")
      assert_equal expected.fetch(row.fetch("name")), result.fetch("source")
      assert_empty result.fetch("diagnostics")
    end
  end
end
