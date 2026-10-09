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
end
