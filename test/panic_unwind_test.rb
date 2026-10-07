# frozen_string_literal: true

require "minitest/autorun"
require "carve"

# An engine panic must arrive as a rescuable Ruby exception.
#
# magnus already catches the unwind -- that is why a panic produces a Ruby
# backtrace at all -- but it raises the result as `fatal`, and Ruby does not
# let a host stop a `fatal`. Measured against the engine the gem shipped at
# v0.1.6, where `Carve.to_html("|{.r}")` panicked:
#
#   rescue Exception => e   # never reached
#   lib/carve.rb:267:in `_to_html': byte range starts at 1 but ends at 0 (fatal)
#
# Exit status 1, with neither the success nor the rescue branch run. So the only
# protection a host had against an engine panic was the engine not panicking
# (markup-carve/carve-rb#170).
#
# `Carve._panic_probe` is why this file can test the mechanism rather than one
# input's symptom. No Carve source panics the pinned engine: `|{.r}` is fixed in
# 0.1.8 and `test/row_attribute_line_test.rb` pins it. A test that cannot reach
# a panic cannot tell a working safety net from a missing one, so the extension
# exposes a call that panics on purpose.
class PanicUnwindTest < Minitest::Test
  def test_panic_probe_raises_engine_panic
    error = assert_raises(Carve::EnginePanic) { Carve._panic_probe }
    assert_includes error.message, "deliberate panic from the Carve extension panic probe"
  end

  # The point of the ticket: a plain `rescue` has to work. `fatal` descends from
  # Exception, so before the fix not even `rescue Exception` stopped it.
  def test_a_bare_rescue_catches_an_engine_panic
    outcome =
      begin
        Carve._panic_probe
        :returned
      rescue StandardError => e
        e.class
      end

    assert_same Carve::EnginePanic, outcome
  end

  def test_engine_panic_is_a_standard_error
    assert_operator Carve::EnginePanic, :<, StandardError
  end

  # The location is the half of a panic report that identifies the engine bug,
  # and the payload `catch_unwind` returns does not carry it.
  def test_message_carries_the_panic_location
    error = assert_raises(Carve::EnginePanic) { Carve._panic_probe }
    assert_match(/panicked at \S+:\d+:\d+:/, error.message)
  end

  # The process has to still be usable afterwards, which is the whole claim.
  def test_rendering_still_works_after_a_panic
    Carve._panic_probe
  rescue Carve::EnginePanic
    assert_equal "<p>ok</p>", Carve.to_html("ok").strip
  end

  # Every exposed name must be registered through its guarded wrapper, not
  # through the bare implementation. One missed registration leaves exactly the
  # unrescuable `fatal` this file exists to prevent, on just that one call, and
  # no behavioral test would notice until something panicked there.
  def test_every_exposed_function_is_registered_through_a_guard
    source = File.read(File.expand_path("../ext/carve/src/lib.rs", __dir__))
    registered = source.scan(/function!\(\s*([A-Za-z0-9_:]+)\s*,/).flatten

    refute_empty registered
    unguarded = registered.reject { |name| name.start_with?("g_") }
    assert_empty unguarded,
                 "registered without a panic guard: #{unguarded.join(", ")}"
  end
end
