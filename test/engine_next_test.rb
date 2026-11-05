# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "carve"

# What the engine after 0.1.13 adds or changes, pinned through the binding.
class EngineNextTest < Minitest::Test
  def test_the_writer_moves_alignment_into_braces
    assert_equal "|={>} A |= B |\n| x | y |\n", Carve.to_carve("|=> A |= B |\n| x | y |\n")
  end

  def test_braced_alignment_renders
    html = Carve.to_html("|={>} A |= B |\n| x | y |\n")
    assert_includes html, "<th scope=\"col\" style=\"text-align: right;\">A</th>"
    assert_includes html, "<td style=\"text-align: right;\">x</td>"
  end

  def test_the_writer_spells_every_thematic_break_as_stars
    assert_equal "a\n\n***\n\nb\n", Carve.to_carve("a\n\n---\n\nb\n")
  end

  def test_lint_reports_the_deprecated_spellings
    assert_equal ["deprecated-cell-alignment"], rules("|=> A |= B |\n| x | y |\n")
    assert_equal ["thematic-break-spelling"], rules("a\n\n---\n\nb\n")
  end

  def test_caption_hints_are_opt_in
    source = "![x](a.png)\n\nFigure 1: A cat.\n"
    assert_empty rules(source)
    assert_equal ["caption-looking-paragraph"], Carve.lint(source, caption_hints: true).map { |f| f[:rule] }
  end

  def test_decision_trace_is_json_lines
    lines = Carve.decision_trace("- a\n  b\n").lines.map { |line| JSON.parse(line) }
    assert_equal({ "trace" => "carve-decision-trace", "version" => 1, "engine" => "carve-rs" }, lines.first)
    assert_equal [1, 2], lines.drop(1).map { |record| record.fetch("line") }
  end

  def test_a_dotted_letter_marker_needs_two_spaces
    assert_equal "<ol type=\"a\">\n  <li>item</li>\n</ol>", Carve.to_html("a.  item\n").chomp
    assert_equal "<p>a. item</p>", Carve.to_html("a. item\n").chomp
  end

  def test_markdown_import_reads_a_github_alert_as_an_admonition
    assert_equal "::: note\nHi\n:::\n", Carve.from_markdown("> [!NOTE]\n> Hi\n")[:value]
  end

  private

  def rules(source)
    Carve.lint(source).map { |finding| finding[:rule] }
  end
end
