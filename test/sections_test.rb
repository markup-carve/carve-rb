# frozen_string_literal: true

require "minitest/autorun"
require "carve"

# PART 9 §13: top-level headings are wrapped in `<section>`, and `sections:`
# turns that off.
#
# With the wrapper gone the id returns to the `<h*>` and the blocks that would
# have been section children stay as siblings - the same shape a heading inside
# a container has always rendered, which is the point of the option: one
# placement rule for the whole document rather than two.
class SectionsTest < Minitest::Test
  def flat(source)
    Carve.to_html(source, sections: false)
  end

  def test_wraps_by_default
    assert_equal "<section id=\"A\">\n  <h1>A</h1>\n  <p>p</p>\n</section>",
                 Carve.to_html("# A\n\np\n")
  end

  def test_emits_no_wrapper_and_keeps_the_id_on_the_heading
    assert_equal "<h1 id=\"A\">A</h1>\n<p>p</p>", flat("# A\n\np\n")
  end

  # The fast path in `to_html` short-circuits to `_to_html`, which takes no
  # options. If `sections: false` did not disqualify that path the flag would be
  # dropped and wrapped output returned with no error - a failure a caller
  # cannot see, so it is pinned rather than left to the implementation.
  def test_the_fast_path_does_not_swallow_the_flag
    refute_includes flat("# A\n"), "<section"
    assert_includes Carve.to_html("# A\n"), "<section"
  end

  def test_flattens_nested_levels
    assert_equal "<h1 id=\"A\">A</h1>\n<p>p</p>\n<h2 id=\"B\">B</h2>\n<p>q</p>",
                 flat("# A\n\np\n\n## B\n\nq\n")
  end

  def test_changes_nothing_without_headings
    source = "just a paragraph\n\n- and a list\n"
    assert_equal Carve.to_html(source), flat(source)
  end

  def test_leaves_container_headings_alone
    source = "> # Quoted\n>\n> Quoted body.\n\n:::\n# Divved\n:::\n"
    assert_equal Carve.to_html(source), flat(source)
  end

  def test_resolves_crossrefs_and_implicit_heading_references
    assert_equal "<h1 id=\"Target\">Target</h1>\n" \
                 "<p>See <a href=\"#Target\">Target</a> and <a href=\"#Target\">Target</a>.</p>",
                 flat("# Target\n\nSee </#target> and [Target][].\n")
  end

  def test_keeps_the_dedup_namespace_intact
    assert_equal "<h1 id=\"abc\">abc</h1>\n" \
                 "<blockquote>\n  <h1 id=\"abc-2\">abc</h1>\n</blockquote>\n" \
                 "<h1 id=\"abc-3\">abc</h1>",
                 flat("# abc\n\n> # abc\n\n# abc\n")
  end

  def test_still_emits_the_endnotes_region
    html = flat("# A\n\nText[^n].\n\n[^n]: Note.\n")

    assert_includes html, "<h1 id=\"A\">A</h1>"
    # The open tag, not the whole element: the region gained an accessible name
    # (`aria-label="Footnotes"`, markup-carve/carve-rs#1189), and what this test
    # is about is that the endnotes region survives `sections: false` at all.
    assert_includes html, "<section role=\"doc-endnotes\""
    refute_includes html, "<section id="
  end

  # The generated id joins after the author's attributes (PART 10 §1); an id the
  # author wrote keeps its authored position.
  def test_attribute_order_on_an_unwrapped_heading
    assert_equal "<h1 a=\"b\" class=\"c\" id=\"Auto\">Auto</h1>", flat("{a=b .c}\n# Auto\n")
    assert_equal "<h1 id=\"x\" a=\"b\">Written</h1>", flat("{#x a=b}\n# Written\n")
  end

  # The option composes with the other keywords rather than being exclusive
  # with them, which the fast-path branch makes easy to get wrong.
  def test_composes_with_other_options
    html = Carve.to_html("# A\n\n:rocket:\n", sections: false, symbols: { "rocket" => "🚀" })

    assert_includes html, "<h1 id=\"A\">A</h1>"
    assert_includes html, "🚀"
    refute_includes html, "<section"
  end
end
