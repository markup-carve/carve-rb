# frozen_string_literal: true

require "minitest/autorun"
require "carve"

class Engine0113Test < Minitest::Test
  def test_task_states_render_and_preserve_markers
    ["/", "!", "_"].each do |marker|
      source = "- [#{marker}] task\n"
      assert_includes Carve.to_html(source), "data-task-state=\"#{marker}\""
      assert_equal source, Carve.to_carve(source)
    end
  end
end
