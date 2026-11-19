# frozen_string_literal: true

require "minitest/autorun"
require "weakref"
require_relative "../lib/carve"

class NativeHostTest < Minitest::Test
  def note_tree
    { "type" => "document", "astVersion" => "2.0",
      "extensions" => [{ "name" => "ex.note", "version" => "1", "required" => false, "slots" => [] }],
      "children" => [{ "type" => "block_extension", "name" => "ex.note", "version" => "1",
                       "children" => [], "fallback" => [{ "type" => "paragraph", "children" => [
                         { "type" => "text", "value" => "fallback" }] }] }] }
  end

  def test_heading_permalink_transform
    permalink = lambda do |tree|
      tree.fetch("children").each do |node|
        next unless node["type"] == "heading"
        ident = node.fetch("generatedId")
        node["attrs"] = { "id" => ident }
        node.fetch("children") << { "type" => "link", "href" => "##{ident}",
                                    "children" => [{ "type" => "text", "value" => "¶" }] }
      end
      tree
    end
    assert_equal "<section id=\"Guide\">\n  <h1>Guide<a href=\"#Guide\">¶</a></h1>\n</section>",
                 Carve.to_html("# Guide", transforms: [permalink])
  end

  def test_renderer_channels_and_failures
    renderer = ->(node) { "<aside>#{node.fetch('name')}</aside>" }
    result = Carve.render_with_host("", tree: note_tree, options: { mode: :static },
                                    renderers: { "ex.note" => { static: renderer } })
    assert_equal "<aside>ex.note</aside>", result.fetch("html")
    result = Carve.render_with_host("", tree: note_tree,
                                    renderers: { "ex.note" => { static: renderer } })
    assert_equal "<p>fallback</p>", result.fetch("html")
    result = Carve.render_with_host("", tree: note_tree,
                                    renderers: { "ex.note" => ->(_node) { raise "boom" } })
    assert_equal "<p>fallback</p>", result.fetch("html")
    assert_equal "extension-renderer-failed", result.fetch("diagnostics").first.fetch("code")
    result = Carve.render_with_host("# Guide", transforms: [->(_tree) { raise "boom" }])
    assert_equal Carve.to_html("# Guide"), result.fetch("html")
    assert_equal "extension-transform-failed", result.fetch("diagnostics").first.fetch("code")
    result = Carve.render_with_host("", tree: note_tree,
                                    renderers: { "ex.note" => ->(_node) { 42 } })
    assert_equal "extension-renderer-failed", result.fetch("diagnostics").first.fetch("code")
  end

  def test_code_fence_can_take_a_host_renderer_through_a_transform
    source = "```mermaid\ngraph TD;\n```"
    claim = lambda do |tree|
      tree["extensions"] = [{ "name" => "ex.mermaid", "version" => "1", "required" => false, "slots" => [] }]
      tree.fetch("children").map! do |node|
        if node["type"] == "code_block" && node["syntax"] == "mermaid"
          { "type" => "block_extension", "name" => "ex.mermaid", "version" => "1",
            "children" => [], "fallback" => [node] }
        else
          node
        end
      end
      tree
    end
    renderer = ->(node) { "<svg>#{node.fetch('fallback').first.fetch('value').strip}</svg>" }
    result = Carve.render_with_host(source, options: { mode: :static },
                                    renderers: { "ex.mermaid" => { static: renderer } },
                                    transforms: [claim])
    assert_equal "<svg>graph TD;</svg>", result.fetch("html")
    assert_empty result.fetch("diagnostics")
  end

  def test_standard_renderer_remains_selected_with_transform
    source = "::: tabs\n::: tab {title=A}\nx\n:::\n:::\n"
    expected = Carve.to_html(source, extensions: ["carve.tabs"],
                              renderers: { "carve.tabs" => :standard })
    actual = Carve.to_html(source, extensions: ["carve.tabs"],
                            renderers: { "carve.tabs" => :standard }, transforms: [->(tree) { tree }])
    assert_equal expected, actual
  end

  def test_declared_version_and_existing_render_options
    tree = note_tree
    tree.fetch("extensions").first["version"] = "2"
    tree.fetch("children").first["version"] = "2"
    result = Carve.render_with_host("", tree: tree,
                                    renderers: { "ex.note" => ->(_node) { "<aside>version 2</aside>" } })
    assert_equal "<aside>version 2</aside>", result.fetch("html")
    assert_equal "<p>Ship 🚀</p>", Carve.to_html("Ship :rocket:", symbols: { rocket: "🚀" },
                                                 transforms: [->(view) { view }])
  end

  def test_callback_stays_alive_during_gc_and_drops_after_render
    callback = ->(_node) { GC.start; "<aside>alive</aside>" }
    reference = WeakRef.new(callback)
    assert_equal "<aside>alive</aside>", Carve.render_with_host("", tree: note_tree,
                     renderers: { "ex.note" => callback }).fetch("html")
    assert reference.weakref_alive?
    callback = nil
    GC.start
    refute reference.weakref_alive?
  end
end
