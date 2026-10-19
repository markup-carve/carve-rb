# frozen_string_literal: true

# Aligned table formatting and include-region selection (markup-carve/carve#3333).
#
# The alignment rows are the spec's shared fixtures, read from the spec checkout
# next to CARVE_SPEC_CORPUS; unset, those tests skip like the corpus does. The
# region expectations were taken from carve-rs `select_include_region` directly.

require "minitest/autorun"
require "carve"
require "json"
require "tmpdir"

class AlignTablesAndRegionsTest < Minitest::Test
  CORPUS = ENV.fetch("CARVE_SPEC_CORPUS", nil)

  DOC = "intro\n" \
        "%% #region setup\n" \
        "a\n" \
        "b\n" \
        "%% #endregion\n" \
        "// #region code\n" \
        "x\n" \
        "// #endregion\n"

  def alignment_rows
    skip "CARVE_SPEC_CORPUS not set (see .github/workflows/ci.yml)" if CORPUS.nil? || CORPUS.empty?

    path = File.join(CORPUS, "..", "..", "resources", "spec", "table-alignment-fixtures.json")
    JSON.parse(File.read(path, encoding: "UTF-8"))
  end

  def test_align_tables_matches_every_shared_fixture
    rows = alignment_rows
    assert_operator rows.length, :>=, 13
    rows.each do |row|
      assert_equal row.fetch("aligned"), Carve.to_carve(row.fetch("canonical"), align_tables: true),
                   row.fetch("name")
      assert_equal row.fetch("canonical"), Carve.to_carve(row.fetch("aligned")), row.fetch("name")
    end
  end

  def test_align_tables_is_off_by_default
    source = "| a | longer |\n| < | c |\n"
    assert_equal source, Carve.to_carve(source)
    assert_equal "| a | longer |\n| < | c      |\n", Carve.to_carve(source, align_tables: true)
  end

  def test_select_include_region_in_both_modes
    assert_equal 3..4, Carve.select_include_region(DOC, "setup", mode: :carve)
    assert_equal 3..4, Carve.select_include_region(DOC, "setup", mode: "code")
    assert_equal 7..7, Carve.select_include_region(DOC, "code", mode: :code)
  end

  def test_an_empty_region_is_an_empty_range
    region = Carve.select_include_region("%% #region e\n%% #endregion\n", "e", mode: :carve)
    assert_equal 2..1, region
    assert_empty region.to_a
  end

  def test_an_invalid_region_raises_with_the_rule_id
    [
      [DOC, "code", :carve],
      [DOC, "missing", :code],
      ["%% #region a\nx\n", "a", :carve],
      ["%% #region a\n%% #endregion\n%% #region a\n%% #endregion\n", "a", :code],
    ].each do |source, name, mode|
      error = assert_raises(Carve::IncludeRegionError) do
        Carve.select_include_region(source, name, mode: mode)
      end
      assert_equal "include-region-invalid", error.rule
      assert_kind_of ArgumentError, error
    end
  end

  def test_an_unknown_mode_is_refused
    error = assert_raises(ArgumentError) { Carve.select_include_region(DOC, "setup", mode: :markdown) }
    assert_match(/mode must be/, error.message)
  end

  def test_an_include_that_is_not_utf8_warns_as_non_text
    Dir.mktmpdir("carve-rb-non-text-") do |root|
      File.binwrite(File.join(root, "blob.crv"), "ok \xFF\xFE\n".b)
      page = File.join(root, "page.crv")
      File.write(page, "{{ blob.crv }}\n")
      result = Carve.to_html_with_includes(File.read(page), root: root, source_path: page)
      assert_equal ["include-non-text"], result[:warnings].map { |w| w[:rule] }
    end
  end
end
