//! Serialize a carve-rs `Document` AST into a JSON string.
//!
//! The Ruby wrapper (`Carve.parse`) turns this JSON back into a tree of Ruby
//! Hashes/Arrays (`JSON.parse(..., symbolize_names: true)`), giving Ruby
//! consumers - notably a HexaPDF PDF renderer - a walkable AST without
//! reimplementing the parser or binding every struct as a Ruby class.
//!
//! Every node becomes a JSON object with a `"type"` tag plus its fields.
//! Inline text is `{"type":"text","value":"..."}`. Child collections are
//! JSON arrays. `Attrs` become `{"id","classes","key_values"}` or `null`.
//!
//! This walker lives in the binding (not carve-rs) so the engine stays free of
//! a serde dependency; only the gem's native extension pulls in `serde_json`.

use carve_rs::{
    Abbreviation, AbbreviationDef, Admonition, Attrs, AutoLink, BlockExtension, BlockNode,
    BlockQuote, CaptionNumber, Citation, CitationGroup, CitationRenderMode, CodeBlock, Comment,
    CriticComment, CriticDelete, CriticInsert, CriticSubstitute, CrossRef, DefinitionList, Div,
    Document, Emphasis, EmphasisKind, Figure, FigureTarget, Footnote, Heading, Image,
    InlineExtension, InlineNode, LineBlock, Link, List, ListItem, Math, Mention,
    OrderedListType,
    Paragraph,
    LiteralInline, RawBlock, RawInline, SmartPunctuation, Span, Symbol, Table, TableAlign,
    TableCell,
    TableCellSpan, TableRow, Tag,
    ThematicBreak,
};
use serde_json::{Map, Value};

/// Public entry point: a full `Document` to a JSON string.
///
/// NOTE: source positions are deliberately NOT published yet. carve-rs tracks
/// them behind a parse option that this binding does not enable, so `pos` is
/// `None` on every node here and emitting the field would publish nothing.
/// PART 12 section 4 requires positions on a serialized document, so this is a
/// known gap rather than a decision - it needs the binding to parse with
/// positions on AND every node type to carry one upstream.
pub fn document_to_json(doc: &Document) -> String {
    let mut m = Map::new();
    m.insert("type".into(), "document".into());

    // PART 12 section 2: the root carries `frontmatter` and `footnoteDefs`
    // EXACTLY when the document has them. Emitting an empty object for a
    // document with neither says "this document has frontmatter, and it is
    // empty" - a different claim, and one the reference does not make.
    //
    // The RAW block, not the parsed mapping. The mapping is built by splitting
    // each line on the first colon, so key order, comments and anything that is
    // not `key: value` are gone - and a typed (`---json`, `---toml`) block is
    // not parsed into it at all, leaving it EMPTY for a document that plainly
    // has frontmatter. Publishing it under the same field name the reference
    // uses for the raw form meant a consumer reading `frontmatter.content` got
    // nothing here and a string from carve-js, with no error anywhere.
    if let Some(raw) = &doc.frontmatter_raw {
        let mut fm = Map::new();
        fm.insert("format".into(), Value::String(raw.format.clone()));
        fm.insert("content".into(), Value::String(raw.content.clone()));
        m.insert("frontmatter".into(), Value::Object(fm));
    }

    if !doc.footnote_defs.is_empty() {
        let mut fdefs = Map::new();
        for (k, v) in &doc.footnote_defs {
            fdefs.insert(k.clone(), blocks(v));
        }
        m.insert("footnoteDefs".into(), Value::Object(fdefs));
    }

    m.insert("children".into(), blocks(&doc.children));
    m.insert("srcByteLength".into(), Value::from(doc.source_len));

    Value::Object(m).to_string()
}

// ---- helpers ---------------------------------------------------------------

/// Build a node object, OMITTING absent fields.
///
/// The reference shape leaves an absent field out rather than publishing it as
/// `null`, so emitting `"inline": null` on every footnote reference was four
/// fields the reference does not have on that node (PART 12 §3). Consumers
/// keying on presence saw every optional field as present-and-empty.
fn obj(pairs: Vec<(&str, Value)>) -> Value {
    let mut m = Map::new();
    for (k, v) in pairs {
        if v.is_null() {
            continue;
        }
        m.insert(k.into(), v);
    }
    Value::Object(m)
}

fn opt_str(o: &Option<String>) -> Value {
    match o {
        Some(s) => Value::String(s.clone()),
        None => Value::Null,
    }
}

fn opt_usize(o: &Option<usize>) -> Value {
    match o {
        Some(n) => Value::from(*n),
        None => Value::Null,
    }
}

fn attrs(a: &Option<Attrs>) -> Value {
    match a {
        None => Value::Null,
        Some(at) => {
            let mut kv = Map::new();
            for (k, v) in &at.key_values {
                kv.insert(k.clone(), Value::String(v.clone()));
            }
            obj(vec![
                ("id", opt_str(&at.id)),
                (
                    "classes",
                    Value::Array(at.classes.iter().map(|c| Value::String(c.clone())).collect()),
                ),
                ("key_values", Value::Object(kv)),
            ])
        }
    }
}

fn opt_inlines(o: &Option<Vec<InlineNode>>) -> Value {
    match o {
        Some(v) => inlines(v),
        None => Value::Null,
    }
}

fn blocks(list: &[BlockNode]) -> Value {
    Value::Array(list.iter().map(block).collect())
}

fn inlines(list: &[InlineNode]) -> Value {
    Value::Array(list.iter().map(inline).collect())
}

// ---- block nodes -----------------------------------------------------------

fn block(b: &BlockNode) -> Value {
    match b {
        BlockNode::Heading(Heading { attrs: a, level, children, pos: _ }) => obj(vec![
            ("type", "heading".into()),
            ("level", Value::from(*level)),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
        BlockNode::Paragraph(Paragraph {
            attrs: a,
            children,
            at_content_column: _,
            pos: _,
        }) => obj(vec![
            ("type", "paragraph".into()),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
        BlockNode::CodeBlock(c) => code_block(c),
        BlockNode::List(List {
            attrs: a,
            ordered,
            start,
            ol_type,
            tight,
            items,
            delim: _,
            bullet_char: _,
        }) => obj(vec![
            ("type", "list".into()),
            ("ordered", Value::Bool(*ordered)),
            ("start", opt_usize(start)),
            ("ol_type", ol_type.map(ol_type_str).map(Value::from).unwrap_or(Value::Null)),
            ("tight", Value::Bool(*tight)),
            (
                "items",
                Value::Array(items.iter().map(list_item).collect()),
            ),
            ("attrs", attrs(a)),
        ]),
        BlockNode::BlockQuote(q) => block_quote(q),
        BlockNode::Table(t) => table(t),
        BlockNode::Admonition(Admonition { attrs: a, kind, title, label, children }) => obj(vec![
            ("type", "admonition".into()),
            ("kind", Value::String(kind.clone())),
            ("title", opt_inlines(title)),
            ("label", opt_str(label)),
            ("children", blocks(children)),
            ("attrs", attrs(a)),
        ]),
        BlockNode::Div(Div { attrs: a, label, children }) => obj(vec![
            ("type", "div".into()),
            ("label", opt_str(label)),
            ("children", blocks(children)),
            ("attrs", attrs(a)),
        ]),
        // A `::: |` fence, where every newline is a hard break. Its own type
        // rather than a div carrying a `.line-block` class: a plain div with
        // that class keeps soft breaks, so the class alone cannot say which one
        // this is (carve#359).
        BlockNode::LineBlock(LineBlock { attrs: a, children }) => obj(vec![
            ("type", "line_block".into()),
            ("children", blocks(children)),
            ("attrs", attrs(a)),
        ]),
        BlockNode::DefinitionList(DefinitionList { attrs: a, items }) => obj(vec![
            ("type", "definition_list".into()),
            (
                "items",
                Value::Array(
                    items
                        .iter()
                        .map(|it| {
                            obj(vec![
                                (
                                    "terms",
                                    Value::Array(it.terms.iter().map(|t| inlines(t)).collect()),
                                ),
                                (
                                    "definitions",
                                    Value::Array(
                                        it.definitions.iter().map(|d| blocks(d)).collect(),
                                    ),
                                ),
                            ])
                        })
                        .collect(),
                ),
            ),
            ("attrs", attrs(a)),
        ]),
        BlockNode::Figure(Figure { attrs: a, target, caption }) => obj(vec![
            ("type", "figure".into()),
            ("target", figure_target(target)),
            ("caption", inlines(caption)),
            ("attrs", attrs(a)),
        ]),
        BlockNode::AbbreviationDef(AbbreviationDef { abbr, expansion }) => obj(vec![
            ("type", "abbreviation_def".into()),
            ("abbr", Value::String(abbr.clone())),
            ("expansion", Value::String(expansion.clone())),
        ]),
        BlockNode::RawBlock(RawBlock { format, content }) => obj(vec![
            ("type", "raw_block".into()),
            ("format", Value::String(format.clone())),
            ("content", Value::String(content.clone())),
        ]),
        BlockNode::Comment(Comment { block, content }) => obj(vec![
            ("type", "comment".into()),
            ("block", Value::Bool(*block)),
            ("content", Value::String(content.clone())),
        ]),
        BlockNode::Extension(BlockExtension { attrs: a, name, children, summary, label }) => {
            obj(vec![
                ("type", "block_extension".into()),
                ("name", Value::String(name.clone())),
                ("children", blocks(children)),
                ("summary", opt_inlines(summary)),
                ("label", opt_str(label)),
                ("attrs", attrs(a)),
            ])
        }
        BlockNode::BlockImage(img) => {
            // A block-level image reuses the inline Image shape but tagged
            // block_image so a renderer can place it as a standalone figure.
            let mut v = image(img);
            if let Value::Object(ref mut m) = v {
                m.insert("type".into(), "block_image".into());
            }
            v
        }
        BlockNode::ThematicBreak(ThematicBreak { attrs: a }) => obj(vec![
            ("type", "thematic_break".into()),
            ("attrs", attrs(a)),
        ]),
    }
}

fn code_block(c: &CodeBlock) -> Value {
    obj(vec![
        ("type", "code_block".into()),
        ("lang", opt_str(&c.lang)),
        ("title", opt_str(&c.title)),
        ("label", opt_str(&c.label)),
        ("content", Value::String(c.content.clone())),
        ("attrs", attrs(&c.attrs)),
    ])
}

fn block_quote(q: &BlockQuote) -> Value {
    obj(vec![
        ("type", "block_quote".into()),
        ("children", blocks(&q.children)),
        ("attribution", opt_inlines(&q.attribution)),
        ("attrs", attrs(&q.attrs)),
    ])
}

fn list_item(it: &ListItem) -> Value {
    obj(vec![
        ("type", "list_item".into()),
        (
            "checked",
            match it.checked {
                Some(b) => Value::Bool(b),
                None => Value::Null,
            },
        ),
        ("children", blocks(&it.children)),
        ("attrs", attrs(&it.attrs)),
    ])
}

fn table(t: &Table) -> Value {
    obj(vec![
        ("type", "table".into()),
        ("caption", opt_inlines(&t.caption)),
        (
            "rows",
            Value::Array(t.rows.iter().map(table_row).collect()),
        ),
        ("attrs", attrs(&t.attrs)),
    ])
}

fn table_row(r: &TableRow) -> Value {
    obj(vec![
        ("type", "table_row".into()),
        (
            "cells",
            Value::Array(r.cells.iter().map(table_cell).collect()),
        ),
        ("attrs", attrs(&r.attrs)),
    ])
}

fn table_cell(c: &TableCell) -> Value {
    obj(vec![
        ("type", "table_cell".into()),
        ("header", Value::Bool(c.header)),
        (
            "span",
            match c.span {
                Some(TableCellSpan::Rowspan) => "rowspan".into(),
                Some(TableCellSpan::Colspan) => "colspan".into(),
                None => Value::Null,
            },
        ),
        (
            "align",
            match c.align {
                Some(TableAlign::Left) => "left".into(),
                Some(TableAlign::Right) => "right".into(),
                Some(TableAlign::Center) => "center".into(),
                None => Value::Null,
            },
        ),
        ("children", inlines(&c.children)),
        ("attrs", attrs(&c.attrs)),
    ])
}

fn figure_target(t: &FigureTarget) -> Value {
    match t {
        FigureTarget::Image(img) => image(img),
        FigureTarget::BlockQuote(q) => block_quote(q),
        FigureTarget::Table(tb) => table(tb),
        FigureTarget::CodeBlock(c) => code_block(c),
        FigureTarget::Paragraph(Paragraph {
            attrs: a,
            children,
            at_content_column: _,
            pos: _,
        }) => obj(vec![
            ("type", "paragraph".into()),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
    }
}

fn ol_type_str(t: OrderedListType) -> &'static str {
    match t {
        OrderedListType::LowerAlpha => "lower-alpha",
        OrderedListType::UpperAlpha => "upper-alpha",
        OrderedListType::LowerRoman => "lower-roman",
        OrderedListType::UpperRoman => "upper-roman",
    }
}

// ---- inline nodes ----------------------------------------------------------

fn inline(n: &InlineNode) -> Value {
    match n {
        InlineNode::Text(s) => obj(vec![
            ("type", "text".into()),
            ("value", Value::String(s.clone())),
        ]),
        // A character the author escaped. Its own type rather than plain text:
        // the backslash carries intent the character does not, which is what
        // lets a consumer reproduce `\-\-` instead of emitting an en dash
        // (carve#350). The value is the character, without the backslash.
        InlineNode::EscapedText(s) => obj(vec![
            ("type", "escaped_text".into()),
            ("value", Value::String(s.clone())),
        ]),
        InlineNode::Emphasis(Emphasis { attrs: a, kind, children }) => obj(vec![
            ("type", "emphasis".into()),
            ("kind", emphasis_kind_str(*kind).into()),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
        // The inline literal (spec PART 9 section 27) is a verbatim span with
        // the code wrapper dropped. It serializes as its own type rather than
        // as code, because a consumer rebuilding source has to know which of
        // the two the author wrote.
        InlineNode::LiteralInline(l) => obj(vec![
            ("type", "literal_inline".into()),
            ("content", Value::String(l.content.clone())),
            ("attrs", attrs(&l.attrs)),
        ]),
        InlineNode::Code(s, a) => obj(vec![
            ("type", "code".into()),
            ("value", Value::String(s.clone())),
            ("attrs", attrs(a)),
        ]),
        InlineNode::Link(l) => link(l),
        InlineNode::Image(img) => image(img),
        InlineNode::Span(Span { attrs: a, children }) => obj(vec![
            ("type", "span".into()),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
        InlineNode::Math(Math { attrs: a, display, content }) => obj(vec![
            ("type", "math".into()),
            ("display", Value::Bool(*display)),
            ("content", Value::String(content.clone())),
            ("attrs", attrs(a)),
        ]),
        InlineNode::RawInline(RawInline { format, content }) => obj(vec![
            ("type", "raw_inline".into()),
            ("format", Value::String(format.clone())),
            ("content", Value::String(content.clone())),
        ]),
        InlineNode::Symbol(Symbol { name, attrs: a }) => obj(vec![
            ("type", "symbol".into()),
            ("name", Value::String(name.clone())),
            ("attrs", attrs(a)),
        ]),
        // A typographic substitution carries BOTH halves: the resolved kind and
        // the author's source run (spec PART 9 section 8). A consumer that only
        // wants to display the document reads the glyph - present on quotes,
        // whose character is locale-dependent and fixed during parsing - or
        // resolves `kind` through the spec's table. One rebuilding source reads
        // `value`. Dropping either half would make this binding's JSON lossier
        // than the tree it serializes.
        InlineNode::SmartPunctuation(SmartPunctuation { kind, value, glyph }) => obj(vec![
            ("type", "smart_punctuation".into()),
            ("kind", Value::String(kind.clone())),
            ("value", Value::String(value.clone())),
            ("glyph", opt_str(glyph)),
        ]),
        InlineNode::AutoLink(AutoLink { attrs: a, href, text }) => obj(vec![
            ("type", "autolink".into()),
            ("href", Value::String(href.clone())),
            ("text", Value::String(text.clone())),
            ("attrs", attrs(a)),
        ]),
        InlineNode::CrossRef(CrossRef { target }) => obj(vec![
            ("type", "cross_ref".into()),
            ("target", Value::String(target.clone())),
        ]),
        InlineNode::CaptionNumber(CaptionNumber { number }) => obj(vec![
            ("type", "caption_number".into()),
            ("number", opt_usize(number)),
        ]),
        InlineNode::Mention(Mention { user }) => obj(vec![
            ("type", "mention".into()),
            ("user", Value::String(user.clone())),
        ]),
        InlineNode::Tag(Tag { name }) => obj(vec![
            ("type", "tag".into()),
            ("name", Value::String(name.clone())),
        ]),
        InlineNode::CitationGroup(g) => citation_group(g),
        InlineNode::Extension(InlineExtension { attrs: a, name, children }) => obj(vec![
            ("type", "inline_extension".into()),
            ("name", Value::String(name.clone())),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
        InlineNode::Abbreviation(Abbreviation { abbr, expansion }) => obj(vec![
            ("type", "abbreviation".into()),
            ("abbr", Value::String(abbr.clone())),
            ("expansion", Value::String(expansion.clone())),
        ]),
        // `footnote` names the BLOCK definition type in the vocabulary, so the
        // two inline forms are `footnote_ref` (`[^a]`) and `inline_footnote`
        // (`^[…]`) - split by the node's own shape, since the engine keeps both
        // in one struct (carve#405).
        InlineNode::Footnote(Footnote { attrs: a, id, inline: inl, number, ref_id }) => {
            if inl.is_some() {
                obj(vec![
                    ("type", "inline_footnote".into()),
                    ("inline", opt_inlines(inl)),
                    ("number", opt_usize(number)),
                    ("refId", opt_str(ref_id)),
                    ("attrs", attrs(a)),
                ])
            } else {
                obj(vec![
                    ("type", "footnote_ref".into()),
                    ("id", opt_str(id)),
                    ("number", opt_usize(number)),
                    ("refId", opt_str(ref_id)),
                    ("attrs", attrs(a)),
                ])
            }
        }
        InlineNode::SoftBreak => obj(vec![("type", "soft_break".into())]),
        InlineNode::HardBreak => obj(vec![("type", "hard_break".into())]),
        InlineNode::CriticInsert(CriticInsert { attrs: a, children }) => obj(vec![
            ("type", "insert".into()),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
        InlineNode::CriticDelete(CriticDelete { attrs: a, children }) => obj(vec![
            ("type", "delete".into()),
            ("children", inlines(children)),
            ("attrs", attrs(a)),
        ]),
        InlineNode::CriticSubstitute(CriticSubstitute { old_text, new_text }) => obj(vec![
            ("type", "substitution".into()),
            ("old_text", Value::String(old_text.clone())),
            ("new_text", Value::String(new_text.clone())),
        ]),
        InlineNode::CriticComment(CriticComment { text }) => obj(vec![
            ("type", "critic_comment".into()),
            ("text", Value::String(text.clone())),
        ]),
    }
}

fn link(l: &Link) -> Value {
    obj(vec![
        ("type", "link".into()),
        ("href", Value::String(l.href.clone())),
        ("title", opt_str(&l.title)),
        ("children", inlines(&l.children)),
        ("ref_label", opt_str(&l.ref_label)),
        ("raw_ref", opt_str(&l.raw_ref)),
        ("from_crossref", Value::Bool(l.from_crossref)),
        ("attrs", attrs(&l.attrs)),
    ])
}

fn image(img: &Image) -> Value {
    obj(vec![
        ("type", "image".into()),
        ("src", Value::String(img.src.clone())),
        ("alt", Value::String(img.alt.clone())),
        ("title", opt_str(&img.title)),
        ("attrs", attrs(&img.attrs)),
    ])
}

fn citation_group(g: &CitationGroup) -> Value {
    obj(vec![
        ("type", "citation_group".into()),
        ("raw", Value::String(g.raw.clone())),
        ("integral", Value::Bool(g.integral)),
        (
            "mode",
            match g.mode {
                Some(CitationRenderMode::Numbered) => "numbered".into(),
                Some(CitationRenderMode::AuthorDate) => "author-date".into(),
                None => Value::Null,
            },
        ),
        (
            "items",
            Value::Array(g.items.iter().map(citation).collect()),
        ),
    ])
}

fn citation(c: &Citation) -> Value {
    obj(vec![
        ("key", Value::String(c.key.clone())),
        ("prefix", opt_inlines(&c.prefix)),
        ("locator", opt_inlines(&c.locator)),
        ("locator_label", opt_str(&c.locator_label)),
        ("locator_value", opt_str(&c.locator_value)),
        ("suffix", opt_inlines(&c.suffix)),
        ("suppress_author", Value::Bool(c.suppress_author)),
        ("number", opt_usize(&c.number)),
        ("label", opt_str(&c.label)),
        ("use_index", opt_usize(&c.use_index)),
    ])
}

fn emphasis_kind_str(k: EmphasisKind) -> &'static str {
    match k {
        EmphasisKind::Italic => "italic",
        EmphasisKind::Strong => "strong",
        EmphasisKind::Underline => "underline",
        EmphasisKind::Strike => "strike",
        EmphasisKind::Super => "super",
        EmphasisKind::Sub => "sub",
        EmphasisKind::Highlight => "highlight",
        EmphasisKind::BoldItalic => "bold-italic",
    }
}
