# frozen_string_literal: true

require "json"
require "pathname"
require_relative "carve/version"

abi = RUBY_VERSION[/\A\d+\.\d+/]
if File.directory?(File.join(__dir__, "carve", abi))
  require_relative "carve/#{abi}/carve"
else
  require_relative "carve/carve"
end

# Ruby facade over the Carve 0.2 engine's public JSON boundary (C2-T-010).
module Carve
  class EngineError < ArgumentError
    attr_reader :name, :category, :status

    def initialize(row)
      @name = row.fetch("name")
      @category = row.fetch("category")
      @status = row.fetch("status")
      super(row.fetch("message"))
    end
  end

  class WriterUnavailable < EngineError; end
  class ExtensionUnavailable < ArgumentError; end
  # Raised by .select_include_region when the region is missing or a marker is
  # malformed or unmatched. +rule+ is the engine's warning rule id.
  class IncludeRegionError < ArgumentError
    RULE = "include-region-invalid"

    def rule = RULE
  end

  # The standard extensions the engine enables by name over JSON (C2-X-039).
  EXTENSIONS = %w[
    carve.autolink carve.externalLinks carve.headingNumbers carve.headingPermalinks carve.headingReference carve.linkPolicy carve.toc carve.tocPlacement
    carve.cite carve.codeCallouts carve.codeGroup carve.colorSwatch carve.details
    carve.fencedRender.abc carve.fencedRender.chart carve.fencedRender.d2 carve.fencedRender.graphviz
    carve.fencedRender.mermaid carve.fencedRender.plantuml carve.fencedRender.vega-lite carve.fencedRender.wavedrom
    carve.glossary carve.imgFence.image carve.imgFence.img carve.index carve.inlineFootnotesToParentheses
    carve.listTable carve.mathBlock carve.references carve.semanticSpan carve.smartQuotes
    carve.spoiler carve.spoilerBlock carve.tabNormalize carve.tabs carve.wiki
  ].freeze
  MODES = %i[interactive static].freeze
  RENDERER_KEYS = %i[mermaid chart graphviz math].freeze

  class << self
    # C2-T-010. A public escape hatch for every 0.2 call and option.
    # The engine checks each option for the stage named by the call.
    def call(name, source: nil, options: {}, **fields)
      call_response(name, source, options, fields, symbolize_names: false)
    end

    def parse(source, **options)
      positions = options.delete(:positions)
      fields = positions.nil? ? {} : { positions: positions }
      if options.empty? && positions != false
        tree_json = _parse_json(source_text(source))
        return JSON.parse(tree_json, max_nesting: false, symbolize_names: true) unless tree_json.empty?
      end
      call_response("parse", source, options, fields, symbolize_names: true).fetch(:tree)
    end

    def parse_with_diagnostics(source, **options)
      positions = options.delete(:positions)
      fields = positions.nil? ? {} : { positions: positions }
      call_response("parseWithDiagnostics", source, options, fields, symbolize_names: true)
    end

    private

    # Build parse trees with symbol keys during JSON decoding. The public
    # generic call keeps its string-key contract, while parse avoids a second
    # recursive allocation of the entire tree.
    def call_response(name, source, options, fields, symbolize_names:)
      request = { "call" => name.to_s }
      request["source"] = source_text(source) unless source.nil?
      request["options"] = stringify(options) unless options.empty?
      fields.each { |key, value| request[camel(key)] = stringify(value) }
      response = JSON.parse(_call_json(JSON.generate(request)), max_nesting: false,
                            symbolize_names: symbolize_names)
      key = symbolize_names ? :error : "error"
      if (row = response[key])
        row = row.transform_keys(&:to_s) if symbolize_names
        if fields[:target] && row["message"].match?(/not available|unsupported/i)
          raise WriterUnavailable.new(row.merge("message" => "#{fields[:target]} writer not available yet: #{row.fetch('message')}"))
        end
        raise EngineError.new(row)
      end
      response.fetch(symbolize_names ? :ok : "ok")
    end

    public

    def to_html(source, extensions: nil, mode: nil, renderers: nil, transforms: nil, symbols: nil,
                safe: nil, raw_html: false, url_policy: nil, profile: nil,
                sections: true, **options)
      config = options.merge(rawHtml: raw_html && safe != true, sections: sections)
      if renderers && renderers.any? { |name, value| EXTENSIONS.include?(name.to_s) && (value.respond_to?(:call) || value.is_a?(Hash)) }
        raise ExtensionUnavailable, "standard extension callbacks are not selected by the JSON options (C2-T-010)"
      end
      if (renderers && renderers.values.any? { |value| value.respond_to?(:call) || value.is_a?(Hash) }) || (transforms && !transforms.empty?)
        config[:symbols] = stringify(symbols) if symbols
        config[:profile] = profile.to_s if profile
        config[:urlPolicy] = stringify(url_policy) if url_policy
        config[:extensions] = Array(extensions).map(&:to_s) if extensions
        config[:mode] = mode.to_s if mode
        return render_with_host(source, options: config, renderers: renderers, transforms: transforms).fetch("html")
      end
      config.merge!(extension_options(extensions, renderers))
      config[:mode] = mode.to_s if mode
      config[:profile] = profile.to_s if profile
      config[:symbols] = stringify(symbols) if symbols
      config[:urlPolicy] = stringify(url_policy) if url_policy
      call("render", source: source, options: config).fetch("html")
    end


    # Native extension renderers and ordered document transforms (C2-X-052/053).
    # A renderer may be a callable for both channels, or a hash with
    # :interactive and :static callables. A transform receives a mutable
    # JSON-shaped resolved document and returns a document.
    def render_with_host(source = "", tree: nil, options: {}, renderers: nil, transforms: nil)
      names = []
      callbacks = []
      standard = {}
      declared = tree.nil? ? [] : Array(stringify(tree)["extensions"])
      (renderers || {}).each do |name, renderer|
        if renderer.to_s == "standard" && (renderer.is_a?(String) || renderer.is_a?(Symbol))
          standard[name.to_s] = "standard"
          next
        end
        declared_version = declared.find { |row| row["name"] == name.to_s }&.fetch("version", nil)
        version = renderer.is_a?(Hash) ? renderer.fetch(:version, renderer.fetch("version", declared_version || "1")) : (declared_version || "1")
        channels = renderer.is_a?(Hash) ? renderer.reject { |key, _| key.to_s == "version" } : { interactive: renderer, static: renderer }
        channels.each do |channel, callback|
          raise ExtensionUnavailable, "renderer #{name} must respond to call" unless callback.respond_to?(:call)
          key = channel.to_s == "build_time" ? "static" : channel.to_s
          raise ExtensionUnavailable, "renderer channel must be interactive or static" unless %w[interactive static].include?(key)
          names << "#{name}\u001f#{version}\u001f#{key}"
          callbacks << callback
        end
      end
      transforms = Array(transforms)
      transforms.each do |callback|
        raise ExtensionUnavailable, "transform must respond to call" unless callback.respond_to?(:call)
      end
      tree_json = tree.nil? ? nil : JSON.generate(stringify(tree))
      host_options = standard.empty? ? options : options.merge(renderers: standard)
      JSON.parse(_render_host(source_text(source), tree_json, JSON.generate(stringify(host_options)), names, callbacks, transforms), max_nesting: false)
    end

    def render_with_diagnostics(source, **options)
      symbolize(call("renderWithDiagnostics", source: source, options: options))
    end

    def _to_html(source)
      to_html(source)
    end

    def to_html_with_extensions(source, extensions)
      to_html(source, extensions: extensions)
    end

    def to_html_full(source, extensions, mode, renderers)
      to_html(source, extensions: extensions, mode: mode, renderers: renderers)
    end

    def to_html_full_with_symbols(source, extensions, mode, renderers, symbols)
      to_html(source, extensions: extensions, mode: mode, renderers: renderers, symbols: symbols)
    end

    def write(source, target:, **options)
      tree = call("parse", source: source).fetch("tree")
      call("write", options: options, tree: tree, target: target.to_s).fetch("output")
    end

    def to_carve(source, align_tables: false)
      call("format", source: source, options: { alignTables: align_tables }).fetch("source")
    rescue EngineError => error
      if error.message.match?(/not available|unsupported/i)
        raise WriterUnavailable.new(error_row(error).merge("message" => "carve writer not available yet: #{error.message}"))
      end
      raise
    end

    def to_markdown(source)
      write(source, target: "markdown")
    end

    def to_plain_text(source)
      write(source, target: "plain")
    end

    def to_ansi(source)
      write(source, target: "ansi")
    end

    def lint(source, extensions: nil, root: nil, source_path: nil, rules: nil,
             platforms: nil, max_depth: nil, max_bytes: nil,
             max_resolver_calls: nil, max_warnings: nil, caption_hints: false,
             upgrade: false)
      unless Array(extensions).empty?
        raise ExtensionUnavailable, "0.2 lint takes no extensions; its options are rules, platforms and includes (C2-W-109)"
      end
      unsupported = { max_resolver_calls: max_resolver_calls, max_warnings: max_warnings,
                      caption_hints: caption_hints ? true : nil }.compact
      raise ArgumentError, "0.2 lint does not accept #{unsupported.keys.join(', ')}" unless unsupported.empty?
      opts = {}
      opts[:rules] = stringify(rules) if rules
      opts[:platforms] = platforms if platforms
      opts[:includes] = include_options(root, source_path, max_depth, max_bytes) if root
      # The 0.1 migration notices of C2-W-156 report only with upgrade: true.
      opts[:upgrade] = true if upgrade
      symbolize(call("lint", source: source, options: opts).fetch("diagnostics"))
    end

    def render_with_includes(source, root:, source_path:, target: "html",
                             extensions: nil, mode: nil, renderers: nil,
                             symbols: nil, safe: nil, raw_html: false,
                             url_policy: nil, profile: nil, sections: true,
                             max_depth: nil, max_bytes: nil,
                             max_resolver_calls: nil, max_warnings: nil, **options)
      raise ArgumentError, "0.2 includes does not accept max_resolver_calls or max_warnings" if max_resolver_calls || max_warnings
      raise ArgumentError, "the include options come from root:, source_path:, max_depth: and max_bytes:" if options.key?(:includes) || options.key?("includes")
      config = options.merge(includes: include_options(root, source_path, max_depth, max_bytes),
                             rawHtml: raw_html && safe != true, sections: sections)
      config.merge!(extension_options(extensions, renderers))
      config[:mode] = mode.to_s if mode
      config[:symbols] = stringify(symbols) if symbols
      config[:profile] = profile.to_s if profile
      config[:urlPolicy] = stringify(url_policy) if url_policy
      parse_config = { includes: config.fetch(:includes) }
      parse_config[:extensions] = config[:extensions] if config[:extensions]
      # Any other core option goes to the stage that makes the value, so the
      # engine accepts or refuses it as it does on the plain entry points.
      parse_config = options.merge(parse_config) if target.to_s == "ast"
      parsed = call("parseWithDiagnostics", source: source, options: parse_config)
      tree = parsed.fetch("tree")
      if target.to_s == "html"
        rendered = call("renderWithDiagnostics", source: source, options: config)
        value = rendered.fetch("html")
        diagnostics = rendered.fetch("diagnostics")
        suppressed = rendered.fetch("suppressedDiagnostics")
      elsif target.to_s == "ast"
        value = symbolize(tree)
        diagnostics = parsed.fetch("diagnostics")
        suppressed = parsed.fetch("suppressedDiagnostics")
      else
        written = call("write", options: options, tree: tree, target: target.to_s)
        value = written.fetch("output")
        diagnostics = written.fetch("diagnostics")
        suppressed = 0
      end
      file_id = Pathname.new(source_path.to_s).relative_path_from(Pathname.new(root.to_s)).to_s
      dependencies = call("includeDependencies", tree: tree, file: file_id).fetch("dependencies")
      { value: value, warnings: symbolize(diagnostics),
        dependencies: symbolize(dependencies),
        suppressedWarnings: suppressed }
    end

    def to_html_with_includes(source, root:, source_path:, **options)
      render_with_includes(source, root: root, source_path: source_path, **options)
    end

    def parse_with_includes(source, root:, source_path:, **options)
      render_with_includes(source, root: root, source_path: source_path,
                           target: "ast", **options)
    end

    def from_html(source, mode: :safe)
      raise ArgumentError, "HTML import modes were removed in Carve 0.2 (C2-M-008)" unless mode.to_s == "safe"
      call("importDocument", source: source, from: "html")
    end

    # The 0.1 Markdown importer read GFM, so this imports from: "gfm" (UPGRADING).
    def from_markdown(source)
      import_document(source, from: "gfm")
    end

    # Imports html, gfm, markdown (CommonMark only) or djot (C2-T-003).
    def import_document(source, from: "html", **options)
      call("importDocument", source: source, options: options, from: from.to_s)
    end

    # The 1-based, inclusive Range of content lines of <tt>@region:name</tt>,
    # resolved with the engine's marker rules (C2-N-037 to C2-N-043). An empty
    # region is an empty Range such as +2..1+. +mode: :code+ also reads the
    # source-comment markers.
    def select_include_region(source, name, mode: :carve)
      mode = mode.to_s
      raise ArgumentError, "mode must be :carve or :code, got #{mode.inspect}" unless %w[carve code].include?(mode)

      name = name.to_s
      result = _select_include_region(source_text(source), name, mode == "code")
      if result.is_a?(String)
        raise IncludeRegionError, "#{IncludeRegionError::RULE}: region #{name.inspect} #{result}"
      end

      result[0]..result[1]
    end

    def decision_trace(_source)
      raise ArgumentError, "decision_trace is a 0.1 debugging API, absent in Carve 0.2"
    end

    def read_stamp(_source)
      raise ArgumentError, "0.1 provenance stamps are handled by the 0.2 upgrade tool"
    end

    def needs_review?(_source, _version = nil)
      raise ArgumentError, "0.1 provenance stamps are handled by the 0.2 upgrade tool"
    end

    def register_extension(_definition)
      raise ExtensionUnavailable, "host extensions take host code, which the JSON boundary has no form for (C2-T-010); " \
                                  "select a standard extension with extensions: (#{EXTENSIONS.join(', ')})"
    end

    private

    # Standard extensions and their standard renderers travel as options;
    # a Ruby callable has no JSON form (C2-T-010).
    def extension_options(extensions, renderers)
      config = {}
      names = Array(extensions).map(&:to_s)
      config[:extensions] = names unless names.empty?
      unless renderers.nil? || renderers.empty?
        renderers.each do |name, renderer|
          next if renderer.to_s == "standard" && (renderer.is_a?(String) || renderer.is_a?(Symbol))
          raise ExtensionUnavailable, "renderers: #{name}: host renderers have no JSON form (C2-T-010); use \"standard\""
        end
        config[:renderers] = renderers.to_h { |name, renderer| [name.to_s, renderer.to_s] }
      end
      config
    end

    def include_options(root, source_path, max_depth, max_bytes)
      raise ArgumentError, "include root and source path must be absolute" unless
        Pathname.new(root.to_s).absolute? && Pathname.new(source_path.to_s).absolute?
      file_id = Pathname.new(source_path.to_s).relative_path_from(Pathname.new(root.to_s)).to_s
      raise ArgumentError, "include source path must be inside root" if file_id == ".." || file_id.start_with?("../")
      result = { root: root.to_s, file: file_id }
      result[:depth] = max_depth unless max_depth.nil?
      result[:bytes] = max_bytes unless max_bytes.nil?
      result
    end

    def source_text(source)
      source.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "\uFFFD")
    end

    def camel(key)
      key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
    end

    def stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), out| out[camel(k)] = stringify(v) }
      when Array then value.map { |entry| stringify(entry) }
      when Symbol then value.to_s
      else value
      end
    end

    def symbolize(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), out| out[k.to_sym] = symbolize(v) }
      when Array then value.map { |entry| symbolize(entry) }
      else value
      end
    end

    def error_row(error)
      { "name" => error.name, "category" => error.category,
        "status" => error.status, "message" => error.message }
    end
  end
end
