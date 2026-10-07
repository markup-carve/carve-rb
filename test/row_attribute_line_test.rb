# frozen_string_literal: true

require "minitest/autorun"
require "carve"

# A lone `|` carrying an attribute block is paragraph text, not a table.
#
# This is a PROCESS-SAFETY regression guard, not a formatting one. Under
# carve-lang 0.1.7 the table check panicked on this input with "byte range
# starts at 1 but ends at 0" (parse.rs:14953), and a panic crossing the FFI
# boundary arrives in Ruby as `fatal`, which `rescue Exception` cannot catch.
# Measured on the pin this gem shipped at v0.1.6:
#
#   ruby -Ilib -e 'require "carve"; Carve.to_html("|{.r}")'  ->  exit 1, no output
#
# So any host rendering untrusted Carve could be taken down by five bytes.
# carve-lang 0.1.8 reads the line as prose instead (markup-carve/carve-rs#2341).
#
# The cases below are the measured boundary: a bare `|`, an empty brace pair and
# a space before the brace never panicked, and two pipes never did either. Only
# one pipe followed immediately by a NON-EMPTY attribute block did, so the
# non-panicking neighbors are pinned beside it rather than left out - a guard
# that only tried the failing shape could pass over an engine that had started
# refusing the whole family.
class RowAttributeLineTest < Minitest::Test
  PANICKED_UNDER_0_1_7 = [
    "|{.r}",
    "|{#i}",
    "|{a=b}",
  ].freeze

  NEVER_PANICKED = [
    "|",
    "|{}",
    "| {.r}",
    "||{.r}",
  ].freeze

  def test_a_single_pipe_with_row_attributes_renders_instead_of_aborting
    PANICKED_UNDER_0_1_7.each do |source|
      html = Carve.to_html(source)

      refute_nil html, "#{source.inspect} produced no HTML"
      assert_includes html, "<p>",
                      "#{source.inspect} must read as paragraph text, got #{html.inspect}"
    end
  end

  def test_the_neighboring_shapes_still_render
    NEVER_PANICKED.each do |source|
      assert_kind_of String, Carve.to_html(source), "#{source.inspect} stopped rendering"
    end
  end

  # The direct calls above cannot REPORT a panic: a `fatal` takes the whole
  # minitest process down, so a regression would show up as an aborted run
  # rather than as this file failing. Driving one shape through a child process
  # makes the failure attributable to this test, and asserts on the exit status
  # rather than on stderr, because the panic message is the engine's to change.
  def test_rendering_it_in_a_child_process_exits_cleanly
    script = 'require "carve"; Carve.to_html("|{.r}"); print "rendered"'
    out = IO.popen([RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script],
                   err: File::NULL, &:read)
    status = $?

    assert_predicate status, :success?,
                     "rendering `|{.r}` in a child process exited #{status.exitstatus.inspect}; " \
                     "the engine panicked instead of reading the line as prose " \
                     "(markup-carve/carve-rs#2341)"
    assert_equal "rendered", out
  end
end
