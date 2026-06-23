//! Native Ruby binding for the Carve markup language.
//!
//! Wraps the `carve` crate (carve-rs) with magnus, exposing a `Carve` Ruby
//! module:
//!
//! * `Carve.to_html(source)` -> HTML String
//! * `Carve.to_html_with_extensions(source, extensions)` -> HTML String,
//!   where `extensions` is an Array of extension name Strings/Symbols.
//!
//! The pure-Ruby wrapper in `lib/carve.rb` adds a keyword-argument form
//! `Carve.to_html(source, extensions: [...])` on top of these primitives.

use carve_rs::{
    Autolink, CarveExtension, Citations, Details, ExternalLinks, FencedRender, HeadingPermalinks,
    ListTable, MathBlock, Options, Spoiler, TabNormalize, TableOfContents, Wikilinks,
};
use magnus::{function, prelude::*, Error, RArray, Ruby};

/// Build an owned, boxed extension instance from a Ruby-facing name.
///
/// Accepts both snake_case (`math_block`) and hyphenated (`math-block`) forms
/// so symbols and strings map cleanly. Returns `None` for an unknown name; the
/// caller turns that into a Ruby `ArgumentError`.
fn extension_for(name: &str) -> Option<Box<dyn CarveExtension>> {
    // Normalize: lowercase, hyphens -> underscores, strip surrounding space.
    let key = name.trim().to_ascii_lowercase().replace('-', "_");
    let ext: Box<dyn CarveExtension> = match key.as_str() {
        "autolink" => Box::new(Autolink::new()),
        "details" => Box::new(Details::new()),
        "list_table" | "listtable" => Box::new(ListTable::new()),
        "math_block" | "mathblock" | "math" => Box::new(MathBlock::new()),
        "heading_permalinks" | "permalinks" => Box::new(HeadingPermalinks::new()),
        "citations" => Box::new(Citations::new()),
        "tab_normalize" | "tabnormalize" => Box::new(TabNormalize::new()),
        "wikilinks" => Box::new(Wikilinks::new()),
        "external_links" | "externallinks" => Box::new(ExternalLinks::new()),
        // FencedRender needs a language to claim; default to a generic fenced
        // pass-through registered for "text".
        "fenced_render" | "fencedrender" => Box::new(FencedRender::new("text")),
        "spoiler" => Box::new(Spoiler::new()),
        "table_of_contents" | "tableofcontents" | "toc" => Box::new(TableOfContents::new()),
        _ => return None,
    };
    Some(ext)
}

/// Render Carve source to HTML with no extensions enabled.
fn to_html(source: String) -> String {
    carve_rs::to_html(&source)
}

/// Render Carve source to HTML with the named extensions enabled.
///
/// `names` is a Ruby Array of Strings/Symbols. An unrecognized name raises a
/// Ruby `ArgumentError`.
fn to_html_with_extensions(ruby: &Ruby, source: String, names: RArray) -> Result<String, Error> {
    // Collect owned extension instances first, then borrow them into Options.
    // carve_rs::Options holds `&dyn CarveExtension` with a lifetime tied to this
    // function scope, so the boxes must outlive the Options + render call.
    let mut boxed: Vec<Box<dyn CarveExtension>> = Vec::with_capacity(names.len());
    for item in names.into_iter() {
        // Accept both String and Symbol via to_string-style coercion.
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

    let mut options = Options::new();
    for ext in &boxed {
        options = options.with_extension(ext.as_ref());
    }

    Ok(carve_rs::to_html_with_options(&source, &options))
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
    // public `Carve.to_html(source, extensions:)` on top of these. `_to_html`
    // is the no-extension fast path; the wrapper owns the bare `to_html` name.
    module.define_singleton_method("_to_html", function!(to_html, 1))?;
    module.define_singleton_method(
        "to_html_with_extensions",
        function!(to_html_with_extensions, 2),
    )?;
    Ok(())
}
