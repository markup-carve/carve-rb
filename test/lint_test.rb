# frozen_string_literal: true

require "minitest/autorun"
require "carve"
require "tmpdir"

class LintTest < Minitest::Test
  BROKEN = "é ü [x](#nope)\n"

  def test_a_clean_document_has_no_findings
    assert_equal [], Carve.lint("# Title\n\nSee [it](#Title).\n")
  end

  def test_a_finding_carries_rule_message_and_position
    finding = Carve.lint(BROKEN).first

    assert_equal "broken-fragment-link", finding[:rule]
    assert_includes finding[:message], "#nope"
    assert_equal 1, finding[:line]
    assert_nil finding[:file]
    assert_equal [], finding[:includedBy]
  end

  # The engine reports byte offsets; the two characters before the link are two
  # bytes each, so a byte offset would land four characters late.
  def test_positions_count_characters_not_bytes
    finding = Carve.lint(BROKEN).first

    assert_equal 5, finding[:column]
    assert_equal "[x](#nope)", BROKEN[finding[:start]...finding[:end]]
  end

  def test_an_unknown_extension_raises
    assert_raises(ArgumentError) { Carve.lint("x", extensions: [:no_such_extension]) }
  end

  def test_root_without_source_path_raises
    Dir.mktmpdir do |root|
      assert_raises(ArgumentError) { Carve.lint("x", root: root) }
    end
  end

  def test_a_relative_root_raises
    assert_raises(ArgumentError) { Carve.lint("x", root: "docs", source_path: "docs/a.crv") }
  end

  def with_book
    Dir.mktmpdir("carve-rb-lint-") do |root|
      Dir.mkdir(File.join(root, "ch"))
      File.write(File.join(root, "ch", "one.crv"), "é [b](#nope)\n")
      book = File.join(root, "book.crv")
      File.write(book, "[a](#zz)\n\n{{ ch/one.crv }}\n\n{{ ch/missing.crv }}\n")
      yield root, book
    end
  end

  def test_without_a_root_includes_are_not_followed
    with_book do |_root, book|
      assert_equal ["broken-fragment-link"], Carve.lint(File.read(book)).map { _1[:rule] }
    end
  end

  def test_an_included_file_is_linted_with_its_chain
    with_book do |root, book|
      findings = Carve.lint(File.read(book), root: root, source_path: book)
      child = findings.find { _1[:file] == "ch/one.crv" }

      assert_equal "broken-fragment-link", child[:rule]
      assert_equal [1, 3], [child[:line], child[:column]]
      assert_equal [{ file: "book.crv", line: 3, column: 1 }], child[:includedBy]
      assert_nil child[:start]
      assert_nil child[:end]
    end
  end

  def test_the_documents_own_findings_keep_their_offsets_under_includes
    with_book do |root, book|
      own = Carve.lint(File.read(book), root: root, source_path: book).first

      assert_nil own[:file]
      assert_equal [0, 8], [own[:start], own[:end]]
    end
  end

  def test_a_literal_include_directive_is_reported
    with_book do |root, book|
      missing = Carve.lint(File.read(book), root: root, source_path: book)
                     .find { _1[:rule] == "include-unresolved" }

      refute_nil missing
      assert_equal 5, missing[:line]
    end
  end

  def test_an_include_budget_is_wired
    with_book do |root, book|
      File.write(File.join(root, "ch", "one.crv"), "{{ two.crv }}\n")
      File.write(File.join(root, "ch", "two.crv"), "Two.\n")
      rules = Carve.lint(File.read(book), root: root, source_path: book, max_depth: 1)
                   .map { _1[:rule] }

      assert_includes rules, "include-depth"
    end
  end
end
