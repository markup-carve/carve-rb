# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "engine_behind"

class EngineBehindTest < Minitest::Test
  def test_load_keeps_inner_blank_lines_and_ignores_the_header
    Dir.mktmpdir do |dir|
      path = File.join(dir, "engine-behind.txt")
      File.write(path, "# header\n\n== 1-a\n<p>a</p>\n\n<p>b</p>\n\n== 2-b\n<hr>\n")
      assert_equal({ "1-a" => "<p>a</p>\n\n<p>b</p>", "2-b" => "<hr>" }, EngineBehind.load(path))
    end
  end

  def test_the_committed_ledger_loads
    EngineBehind.load.each { |slug, html| refute_empty html, slug }
  end
end
