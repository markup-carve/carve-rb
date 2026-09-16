# frozen_string_literal: true

# The include path renders the way `to_html` renders, and publishes the tree.
#
# `carve_test.rb` covers containment: the absolute-root refusal, the symlink
# escape, the cycle, the missing target. What it does not cover is whether a
# render option survives the trip, and whether each budget is really wired -
# three of them were passed in one call there and only `max_depth` was asserted.
# Each assertion here is driven on its own, so a green says which.

require "minitest/autorun"
require "carve"
require "tmpdir"

class IncludesTest < Minitest::Test
  def with_book
    Dir.mktmpdir("carve-rb-includes-") do |root|
      Dir.mkdir(File.join(root, "chapters"))
      File.write(File.join(root, "book.crv"), "{{ chapters/one.crv }}")
      File.write(File.join(root, "chapters", "one.crv"), "One body.")
      yield root, File.join(root, "book.crv")
    end
  end

  def write(root, name, text)
    path = File.join(root, name)
    File.write(path, text)
    path
  end

  # --- render options reach the children ---------------------------------

  def test_a_symbol_map_reaches_an_included_child
    with_book do |root, book|
      write(root, "chapters/one.crv", "One :smile: body.")
      result = Carve.to_html_with_includes(
        "{{ chapters/one.crv }}", root: root, source_path: book,
        symbols: { smile: "SMILED" }
      )
      assert_includes result[:value], "SMILED"
    end
  end

  def test_an_extension_reaches_an_included_child
    with_book do |root, book|
      write(root, "chapters/one.crv", "See [[Target]].")
      result = Carve.to_html_with_includes(
        "{{ chapters/one.crv }}", root: root, source_path: book,
        extensions: [:wikilinks]
      )
      assert_includes result[:value], "<a "
    end
  end

  def test_a_profile_rejection_raises
    with_book do |root, book|
      assert_raises(ArgumentError) do
        Carve.to_html_with_includes("x" * 120_000, root: root, source_path: book,
                                                   profile: :comment)
      end
    end
  end

  def test_safe_escapes_raw_html_in_an_included_child
    with_book do |root, book|
      write(root, "chapters/one.crv", "```=html\n<b>raw</b>\n```")
      result = Carve.to_html_with_includes(
        "{{ chapters/one.crv }}", root: root, source_path: book, safe: true
      )
      refute_includes result[:value], "<b>raw</b>"
    end
  end

  def test_raw_html_in_an_included_child_survives_without_safe
    with_book do |root, book|
      write(root, "chapters/one.crv", "```=html\n<b>raw</b>\n```")
      result = Carve.to_html_with_includes(
        "{{ chapters/one.crv }}", root: root, source_path: book
      )
      assert_includes result[:value], "<b>raw</b>"
    end
  end

  def test_sections_false_leaves_a_heading_unwrapped
    with_book do |root, book|
      write(root, "chapters/one.crv", "# Heading\n")
      result = Carve.to_html_with_includes(
        "{{ chapters/one.crv }}", root: root, source_path: book, sections: false
      )
      refute_includes result[:value], "<section"
    end
  end

  # --- targets -----------------------------------------------------------

  def test_the_markdown_target_expands_too
    with_book do |root, book|
      result = Carve.render_with_includes(
        "{{ chapters/one.crv }}", root: root, source_path: book, target: "markdown"
      )
      assert_equal "One body.", result[:value].strip
    end
  end

  def test_the_carve_target_is_refused
    with_book do |root, book|
      error = assert_raises(ArgumentError) do
        Carve.render_with_includes("Text.", root: root, source_path: book, target: "carve")
      end
      assert_includes error.message, "Unknown Carve include target"
    end
  end

  def test_the_ast_target_returns_a_document_tree
    with_book do |root, book|
      result = Carve.parse_with_includes("{{ chapters/one.crv }}", root: root,
                                                                   source_path: book)
      assert_equal "document", result[:value][:type]
    end
  end

  def test_the_ast_target_carries_the_included_content
    with_book do |root, book|
      result = Carve.parse_with_includes("{{ chapters/one.crv }}", root: root,
                                                                   source_path: book)
      text = result[:value][:children].first[:children].first
      assert_equal "One body.", text[:value]
    end
  end

  def test_the_ast_target_publishes_no_positions
    # Spec I4 leaves position remapping out of scope, so a span on an included
    # node would name an offset in a document the caller never passed.
    with_book do |root, book|
      result = Carve.parse_with_includes("{{ chapters/one.crv }}", root: root,
                                                                   source_path: book)
      refute result[:value][:children].first.key?(:pos)
    end
  end

  def test_the_ast_target_reports_its_dependencies
    with_book do |root, book|
      result = Carve.parse_with_includes("{{ chapters/one.crv }}", root: root,
                                                                   source_path: book)
      assert_equal ["chapters/one.crv"], result[:dependencies].map { |item| item[:path] }
    end
  end

  # --- one budget per assertion ------------------------------------------

  def test_max_bytes_refuses_an_oversized_expansion
    with_book do |root, book|
      result = Carve.to_html_with_includes("{{ chapters/one.crv }}", root: root,
                                                                     source_path: book,
                                                                     max_bytes: 1)
      assert_equal ["include-budget"], result[:warnings].map { |item| item[:rule] }
    end
  end

  def test_a_target_refused_by_max_bytes_was_still_read
    # Section 19 charges the budget for what the resolver handed back: a target
    # is resolved before its size is known, so refusing before the read would be
    # a different rule than the one the spec states.
    with_book do |root, book|
      result = Carve.to_html_with_includes("{{ chapters/one.crv }}", root: root,
                                                                     source_path: book,
                                                                     max_bytes: 1)
      assert_equal [true], result[:dependencies].map { |item| item[:resolved] }
    end
  end

  def test_max_resolver_calls_bounds_the_pass
    with_book do |root, book|
      write(root, "chapters/two.crv", "Two body.")
      source = "{{ chapters/one.crv }}\n\n{{ chapters/two.crv }}"
      result = Carve.to_html_with_includes(source, root: root, source_path: book,
                                                   max_resolver_calls: 1)
      assert_includes result[:warnings].map { |item| item[:rule] }, "include-call-limit"
    end
  end

  def test_max_warnings_caps_the_report_and_says_how_many_it_dropped
    with_book do |root, book|
      source = (0...5).map { |n| "{{ missing-#{n}.crv }}" }.join("\n\n")
      result = Carve.to_html_with_includes(source, root: root, source_path: book,
                                                   max_warnings: 1)
      assert_equal 4, result[:suppressedWarnings]
    end
  end
end
