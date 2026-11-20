# frozen_string_literal: true

# Run the 30 ported checks while other inherited 0.1 fixtures remain out of CI.
require "minitest/autorun"

ported = {
  "test/carve_test.rb" => %w[
    test_ill_formed_utf8_is_replaced_at_the_native_boundary
    test_all_core_render_targets_are_exposed
    test_core_math_and_retired_extension_refusal
    test_retired_math_extension_spellings_are_refused
    test_retired_code_callouts_are_refused
    test_static_tabs_use_panels
    test_tabs_mode_default_is_interactive
    test_mermaid_static_without_renderer_falls_back_to_source
    test_mermaid_static_with_renderer_injects_svg
    test_graphviz_renderer_consulted_for_dot_fence
    test_math_host_renderer_receives_block_node
    test_arbitrary_renderer_key_registers_a_diagram_renderer
    test_renderer_raising_falls_back_to_escaped_source
    test_renderer_non_string_return_falls_back_to_escaped_source
    test_constants_advertise_standard_extensions
    test_extensions_cover_what_the_engine_registers
    test_retired_alias_spellings_are_refused
    test_tabs_control_ids_avoid_heading_ids
    test_tabs_control_ids_avoid_explicit_ids
    test_tabs_control_ids_stable_without_collision
    test_symbols_map_accepts_symbol_keys_and_composes_with_extensions
    test_safe_composes_with_extensions
  ],
  "test/engine_next_test.rb" => %w[
    test_writer_uses_02_cell_alignment_spelling
    test_writer_keeps_02_thematic_break_spelling
  ],
  "test/glossary_ids_test.rb" => %w[
    test_core_terms_differing_only_in_case_stay_distinct
    test_core_terms_stay_present_without_retired_glossary
    test_core_term_texts_are_distinct
  ],
  "test/includes_test.rb" => %w[
    test_an_extension_reaches_an_included_child
    test_the_carve_target_writes_source
  ],
  "test/ordered_dialect_boundaries_test.rb" => %w[
    test_markdown_import_uses_the_engine_call
  ],
}
names = ported.values.flatten
abort "expected 30 ported checks" unless names.length == 30
ARGV.replace(["--name", "/^(?:#{names.join('|')})$/"])
ported.each_key { |file| require File.expand_path("../#{file}", __dir__) }

classes = {
  "test/carve_test.rb" => CarveTest,
  "test/engine_next_test.rb" => EngineNextTest,
  "test/glossary_ids_test.rb" => GlossaryIdsTest,
  "test/includes_test.rb" => IncludesTest,
  "test/ordered_dialect_boundaries_test.rb" => OrderedDialectBoundariesTest,
}
ported.each do |file, methods|
  missing = methods - classes.fetch(file).instance_methods(false).map(&:to_s)
  abort "ported checks missing from #{file}: #{missing.join(', ')}" unless missing.empty?
end
