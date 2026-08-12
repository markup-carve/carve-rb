//! Native Ruby binding for the Carve markup language.
//!
//! Wraps the `carve` crate (carve-rs) with magnus, exposing a `Carve` Ruby
//! module:
//!
//! * `Carve.to_html(source)` -> HTML String
//! * `Carve.to_html_with_extensions(source, extensions)` -> HTML String,
//!   where `extensions` is an Array of extension name Strings/Symbols.
//! * `Carve.to_html_full(source, extensions, mode, renderers)` -> HTML String,
//!   the static-render-mode primitive: `mode` is `"interactive"` (default) or
//!   `"static"`; `renderers` is a Hash of build-time renderer callables.
//! * `Carve.to_html_full_with_symbols(source, extensions, mode, renderers,
//!   symbols)` -> HTML String, the same primitive plus the `:name:` symbol map.
//! * `Carve._to_html_safe(source, extensions, mode, renderers, symbols, safe,
//!   profile, sections)` -> HTML String, the same primitive plus the two
//!   safe-render controls and the section-wrapping switch: `safe` escapes
//!   `=html` raw blocks/spans, `profile` is nil or one of `"full"` /
//!   `"article"` / `"comment"` / `"minimal"`, `sections` wraps top-level
//!   headings in `<section>` (spec PART 9 §13). The others delegate to it, so
//!   there is one implementation of the render path.
//!
//! The pure-Ruby wrapper in `lib/carve.rb` adds the keyword-argument form
//! `Carve.to_html(source, extensions: [...], mode: ..., renderers: {...},
//! symbols: {...}, safe: ..., profile: ..., sections: ...)` on top of these
//! primitives.


use carve_rs::extensions::registry;
use carve_rs::{CarveExtension, Mode, Options, Profile, StaticRenderers};
use magnus::value::{InnerValue, Opaque};
use magnus::{function, prelude::*, Error, RArray, RHash, Ruby, Value};

/// HTML-escape a string for the renderer-failure fallback path.
///
/// carve-rs emits a *present* static renderer's return value verbatim (it is
/// the renderer's job to produce safe HTML). So when our Ruby wrapper has to
/// fall back to the construct source - because the callable raised or returned
/// a non-string - that source MUST be escaped here, or a source containing HTML
/// (e.g. `<img onerror=...>`) would be emitted raw. The no-renderer path inside
/// carve-rs already escapes its `<pre><code>` source block; this keeps the
/// failing-renderer floor equally safe rather than a raw-passthrough hole.
fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Build an owned, boxed extension instance from a Ruby-facing name.
///
/// The engine's registry owns the list; this only translates spellings. Ruby
/// callers pass symbols (`:math_block`), the registry keys are kebab-case
/// (`math-block`), and a handful of short aliases predate both. Returns `None`
/// for an unknown name; the caller turns that into a Ruby `ArgumentError`.
///
/// This used to be a match arm per extension, beside a `Carve::EXTENSIONS`
/// array in `lib/carve.rb` that repeated the same names a third time. Nothing
/// compared any of them against carve-rs, so extensions the engine gained were
/// simply unreachable from Ruby until someone noticed by hand.
fn extension_for(name: &str) -> Option<Box<dyn CarveExtension>> {
    let normalized = name.trim().to_ascii_lowercase().replace('_', "-");
    let key = match normalized.as_str() {
        // Short aliases this binding has accepted since before the registry.
        // They stay so existing Ruby code keeps working.
        "math" | "mathblock" => "math-block",
        "permalinks" => "heading-permalinks",
        "listtable" => "list-table",
        "codecallouts" => "code-callouts",
        "tabnormalize" => "tab-normalize",
        "externallinks" => "external-links",
        "fencedrender" | "mermaid" => "fenced-render",
        "graphviz" | "dot" => "fenced-render-graphviz",
        "chart" => "fenced-render-chart",
        "tableofcontents" => "table-of-contents",
        other => other,
    };
    registry::by_key(key)
}

/// Every extension name the engine registers, in registry order.
///
/// `Carve::EXTENSIONS` is built from this, so the Ruby-visible list cannot
/// drift from what the binding actually accepts.
fn extension_names() -> Vec<String> {
    registry::keys().map(str::to_string).collect()
}

/// Map a Ruby-facing mode string to a carve-rs [`Mode`].
///
/// Rejects any unknown string with `ArgumentError`, mirroring the spec's
/// "MUST reject an unknown mode value" (no guessing) and the unknown-extension
/// error style. Omitting the mode in Ruby defaults to `"interactive"`, so
/// existing callers are unaffected.
fn parse_mode(ruby: &Ruby, mode: &str) -> Result<Mode, Error> {
    match mode {
        "interactive" => Ok(Mode::Interactive),
        "static" => Ok(Mode::Static),
        other => Err(Error::new(
            ruby.exception_arg_error(),
            format!(
                "Unknown Carve render mode: {other:?} (supported: \"interactive\", \"static\")"
            ),
        )),
    }
}

/// Invoke a stored Ruby callable's `call` method with `args`, returning its
/// String result or the HTML-escaped `fallback` on any failure.
///
/// "Any failure" = the callable raised, OR returned a value that is not a
/// String. Both degrade to the escaped fallback so a bad renderer never
/// produces blank output and can never inject raw HTML. The render runs
/// synchronously on the Ruby thread, so `Ruby::get()` succeeds here.
fn call_renderer<A>(callable: &Opaque<Value>, args: A, fallback: &str) -> String
where
    A: magnus::ArgList,
{
    let Ok(ruby) = Ruby::get() else {
        // Not on a Ruby thread - cannot call back; degrade safely.
        return escape_html(fallback);
    };
    let value: Value = callable.get_inner_with(&ruby);
    match value.funcall::<_, _, String>("call", args) {
        Ok(s) => s,
        // Callable raised, or returned a non-String: escaped-source fallback.
        Err(_) => escape_html(fallback),
    }
}

/// Wrap a Ruby diagram callable `(String) -> String` into a carve-rs closure.
///
/// On a raising / non-string-returning callable it degrades to the
/// HTML-escaped source (see [`call_renderer`]).
fn wrap_diagram(callable: Opaque<Value>) -> Box<dyn Fn(&str) -> String + 'static> {
    Box::new(move |src: &str| call_renderer(&callable, (src,), src))
}

/// Wrap a Ruby math callable `(String, bool) -> String` into a carve-rs
/// closure.
///
/// Same contract as [`wrap_diagram`] (including the HTML-escaped fallback), but
/// the callable receives the TeX source and a `display` flag (`true` for block
/// / display math, `false` for inline).
fn wrap_math(callable: Opaque<Value>) -> Box<dyn Fn(&str, bool) -> String + 'static> {
    Box::new(move |tex: &str, display: bool| call_renderer(&callable, (tex, display), tex))
}

/// Build a [`StaticRenderers`] from a Ruby Hash of callables.
///
/// Recognized keys (String or Symbol): `"mermaid"` / `"chart"` / `"graphviz"`
/// (callables `(String) -> String`) and `"math"` (callable
/// `(String, bool) -> String`). Unknown keys raise `ArgumentError`. A missing
/// key leaves that renderer absent, so the matching static path degrades to
/// source.
fn build_renderers(ruby: &Ruby, hash: RHash) -> Result<StaticRenderers, Error> {
    let mut out = StaticRenderers::default();
    // Collect (key, value) pairs; RHash::each is not exposed, so use foreach.
    let mut pairs: Vec<(String, Value)> = Vec::new();
    hash.foreach(|key: Value, value: Value| {
        // Accept both String and Symbol keys via to_string-style coercion.
        let name: String = key.to_r_string()?.to_string()?;
        pairs.push((name, value));
        Ok(magnus::r_hash::ForEach::Continue)
    })?;

    for (name, value) in pairs {
        let callable: Opaque<Value> = Opaque::from(value);
        match name.trim().to_ascii_lowercase().as_str() {
            // The engine keys diagram renderers by fence css class and accepts
            // ANY key, including a custom fence word's class - it is no longer
            // three named fields. Passing the key through rather than
            // allowlisting it keeps this binding from having to be edited every
            // time the engine learns a new diagram type.
            "math" => out.math = Some(wrap_math(callable)),
            other if !other.is_empty() => {
                out.diagrams
                    .insert(other.to_string(), wrap_diagram(callable));
            }
            _ => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    "Carve renderer key must not be empty".to_string(),
                ));
            }
        }
    }
    Ok(out)
}

/// Render Carve source to HTML with no extensions enabled.
fn to_html(source: String) -> String {
    carve_rs::to_html(&source)
}

/// Parse Carve source and return its AST as a JSON string.
///
/// The pure-Ruby wrapper (`Carve.parse`) turns this into a tree of Ruby
/// Hashes/Arrays. Parsing uses the default profile (no extensions); the AST is
/// the raw parse tree, so render-stage extension rewrites are not applied.
///
/// The serialization itself is the ENGINE's (`carve_rs::to_json`). This binding
/// used to carry its own walker over the same tree, written when carve-rs had
/// none - and a shape kept in two places drifts: that copy published `kind`
/// beside an emphasis type that already encodes it, and `from_crossref` where
/// the wire says `fromCrossref`, neither of which anything here could have
/// caught. Every binding over carve-rs now publishes the same bytes, and a
/// PART 12 change is one edit in the engine rather than one per binding.
///
/// Position tracking is ON here and nowhere else. PART 12 section 4 lets an
/// engine gate tracking behind an option but requires the serialized form to
/// carry it, and this is the only entry point that serializes; `to_html` and
/// friends would pay for spans nobody reads.
fn to_ast_json(source: String) -> String {
    let mut options = Options::new();
    options.positions = true;
    carve_rs::to_json(&carve_rs::parse_with_options(&source, &options))
}

/// Render Carve source to HTML with the named extensions enabled.
///
/// `names` is a Ruby Array of Strings/Symbols. An unrecognized name raises a
/// Ruby `ArgumentError`. Always interactive mode, no renderers.
fn to_html_with_extensions(ruby: &Ruby, source: String, names: RArray) -> Result<String, Error> {
    let boxed = boxed_extensions(ruby, names)?;
    let mut options = Options::new();
    for ext in &boxed {
        options = options.with_extension(ext.as_ref());
    }
    Ok(carve_rs::to_html_with_options(&source, &options))
}

/// Collect owned, boxed extension instances from a Ruby Array of names.
///
/// carve_rs::Options holds `&dyn CarveExtension` with a lifetime tied to the
/// caller's scope, so the boxes must outlive the Options + render call; the
/// caller keeps the returned Vec alive across both.
fn boxed_extensions(ruby: &Ruby, names: RArray) -> Result<Vec<Box<dyn CarveExtension>>, Error> {
    let mut boxed: Vec<Box<dyn CarveExtension>> = Vec::with_capacity(names.len());
    for item in names.into_iter() {
        let name: String = item.to_r_string()?.to_string()?;
        match extension_for(&name) {
            Some(ext) => boxed.push(ext),
            None => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!("Unknown Carve extension: {name:?}"),
                ));
            }
        }
    }
    Ok(boxed)
}

/// Lower a Ruby symbols Hash into owned `(name, value)` pairs.
///
/// Keys may be Strings or Symbols; values MUST be Strings (a non-String value
/// raises Ruby's `TypeError` from the conversion, so a mistyped map fails fast
/// instead of silently dropping entries).
fn build_symbols(hash: RHash) -> Result<Vec<(String, String)>, Error> {
    let mut pairs: Vec<(String, String)> = Vec::new();
    hash.foreach(|key: Value, value: Value| {
        // Accept String or Symbol keys.
        let name: String = key.to_r_string()?.to_string()?;
        // Values must be real Strings - TryConvert raises TypeError otherwise.
        let value: String = magnus::TryConvert::try_convert(value)?;
        pairs.push((name, value));
        Ok(magnus::r_hash::ForEach::Continue)
    })?;
    Ok(pairs)
}

/// Full static-render-mode primitive: extensions + mode + renderers.
///
/// Kept at its original arity for direct callers; delegates to
/// [`to_html_full_with_symbols`] with an empty symbol map.
fn to_html_full(
    ruby: &Ruby,
    source: String,
    names: RArray,
    mode: String,
    renderers: RHash,
) -> Result<String, Error> {
    to_html_full_with_symbols(ruby, source, names, mode, renderers, ruby.hash_new())
}

/// Full primitive: extensions + mode + renderers + symbol map.
///
/// * `names` - Ruby Array of extension name Strings/Symbols (may be empty).
/// * `mode` - `"interactive"` (default) or `"static"`; unknown raises
///   `ArgumentError`.
/// * `renderers` - Ruby Hash of build-time renderer callables (keys
///   `mermaid` / `chart` / `graphviz` -> `(String) -> String`, `math` ->
///   `(String, bool) -> String`), consulted only on the static HTML path.
/// * `symbols` - Ruby Hash mapping a `:name:` symbol's name to its value
///   (String/Symbol keys, String values; may be empty). A mapped name renders
///   its value; an unmapped `:name:` stays literal `:name:` text.
///
/// SECURITY: a mapped symbol value is inserted as TRUSTED RAW output in the
/// target format - it is NOT escaped, the same trust class as the `renderers`
/// map. `{"b" => "<b>x</b>"}` emits a real `<b>` element. This is deliberate:
/// processor configuration is trusted. NEVER build a symbols map out of
/// untrusted / user-supplied input.
fn to_html_full_with_symbols(
    ruby: &Ruby,
    source: String,
    names: RArray,
    mode: String,
    renderers: RHash,
    symbols: RHash,
) -> Result<String, Error> {
    // The safe-render arguments default off and section wrapping stays on, so
    // this signature stays as published; `to_html_safe` is the one that takes
    // them.
    to_html_safe(ruby, source, names, mode, renderers, symbols, false, None, true)
}

/// Map a profile name to a [`Profile`], or raise Ruby ArgumentError.
///
/// The four presets are the engine's; an unknown name is reported rather than
/// silently ignored, the same way [`parse_mode`] reports an unknown mode.
fn parse_profile(ruby: &Ruby, name: &str) -> Result<Profile, Error> {
    match name {
        "full" => Ok(Profile::full()),
        "article" => Ok(Profile::article()),
        "comment" => Ok(Profile::comment()),
        "minimal" => Ok(Profile::minimal()),
        other => Err(Error::new(
            ruby.exception_arg_error(),
            format!(
                "Unknown Carve profile: {other:?} \
                 (supported: \"full\", \"article\", \"comment\", \"minimal\")"
            ),
        )),
    }
}

/// [`to_html_full_with_symbols`] plus the two safe-render controls.
///
/// `safe` escapes `=html` raw blocks and spans instead of emitting them. Carve's
/// normative hardening (URL scheme denylist, event-handler attributes, the
/// Trojan-Source bidi characters) is always on and needs no argument; raw
/// passthrough is the deliberate exception, so it is the one thing untrusted
/// input has to switch off.
///
/// `profile` is `nil` or one of the four preset names, restricting which
/// constructs are allowed at all and capping input length.
///
/// `sections` wraps each top-level heading in `<section id="…">` (spec PART 9
/// §13) and is `true` for every existing caller. `false` renders headings flat
/// with the id back on the `<h*>`, for a host whose CSS or JS assumes rendered
/// blocks are direct children of the content container.
#[allow(clippy::too_many_arguments)]
fn to_html_safe(
    ruby: &Ruby,
    source: String,
    names: RArray,
    mode: String,
    renderers: RHash,
    symbols: RHash,
    safe: bool,
    profile: Option<String>,
    sections: bool,
) -> Result<String, Error> {
    let parsed_mode = parse_mode(ruby, &mode)?;
    let parsed_profile = match profile.as_deref() {
        None => None,
        Some(name) => Some(parse_profile(ruby, name)?),
    };
    let static_renderers = build_renderers(ruby, renderers)?;
    let boxed = boxed_extensions(ruby, names)?;
    let symbol_pairs = build_symbols(symbols)?;

    let mut options = Options::new()
        .with_mode(parsed_mode)
        .with_renderers(static_renderers);
    for ext in &boxed {
        options = options.with_extension(ext.as_ref());
    }
    for (name, value) in &symbol_pairs {
        options = options.with_symbol(name.clone(), value.clone());
    }
    if safe {
        options = options.with_raw_html(false);
    }
    if let Some(p) = parsed_profile {
        options = options.with_profile(p);
    }
    if !sections {
        options = options.with_sections(false);
    }

    // The fallible entry point, not `to_html_with_options`. That one is
    // `try_...().unwrap_or_default()`, so a profile rejection -- input past
    // `max_length`, or a denied construct when the action is Error -- comes back
    // as an EMPTY STRING. For the untrusted-input case that is the worst
    // possible answer: a caller cannot tell a rejected 20 KB comment from a
    // document that legitimately rendered to nothing.
    carve_rs::try_to_html_with_options(&source, &options)
        .map_err(|e| Error::new(ruby.exception_arg_error(), e.to_string()))
}


/// Read a document's provenance marker.
///
/// Returns a Hash `{version:, generated_by:}` or nil when the document carries
/// none - the normal case for a hand-written document, meaning "unknown" rather
/// than "current".
fn read_stamp(ruby: &Ruby, source: String) -> Result<Value, Error> {
    let Some(stamp) = carve_rs::read_stamp(&source) else {
        return Ok(ruby.qnil().as_value());
    };

    let hash = ruby.hash_new();
    hash.aset(ruby.sym_new("version"), stamp.version)?;
    match stamp.generated_by {
        Some(writer) => hash.aset(ruby.sym_new("generated_by"), writer)?,
        None => hash.aset(ruby.sym_new("generated_by"), ruby.qnil())?,
    }

    Ok(hash.as_value())
}

/// Whether a document was last processed under an older spec version than this
/// engine targets.
///
/// An unstamped document answers true: its provenance is unknown, and assuming
/// it is current is the unsafe direction.
fn stamp_needs_review(source: String, current_version: Option<String>) -> bool {
    let current = current_version.unwrap_or_else(|| carve_rs::SPEC_VERSION.to_string());

    carve_rs::needs_review(&source, &current)
}

/// Entry point invoked by Ruby when the extension is loaded.
///
/// `name = "carve"` makes the macro emit the `Init_carve` symbol that matches
/// the compiled object `carve.so` (the [lib] name), even though the crate
/// package is named `carve-rb`.
#[magnus::init(name = "carve")]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let module = ruby.define_module("Carve")?;
    // Native primitives. The pure-Ruby wrapper in lib/carve.rb defines the
    // public `Carve.to_html(source, extensions:, mode:, renderers:)` on top of
    // these. `_to_html` is the no-extension fast path; the wrapper owns the
    // bare `to_html` name.
    module.define_singleton_method("_to_html", function!(to_html, 1))?;
    module.define_singleton_method("_to_ast_json", function!(to_ast_json, 1))?;
    module.define_singleton_method(
        "to_html_with_extensions",
        function!(to_html_with_extensions, 2),
    )?;
    module.define_singleton_method("to_html_full", function!(to_html_full, 4))?;
    module.define_singleton_method(
        "to_html_full_with_symbols",
        function!(to_html_full_with_symbols, 5),
    )?;
    module.define_singleton_method("_to_html_safe", function!(to_html_safe, 8))?;
    module.define_singleton_method("_extension_names", function!(extension_names, 0))?;
    module.define_singleton_method("_read_stamp", function!(read_stamp, 1))?;
    module.define_singleton_method("_stamp_needs_review", function!(stamp_needs_review, 2))?;
    Ok(())
}
