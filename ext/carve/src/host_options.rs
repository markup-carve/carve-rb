//! Render options for native callbacks, using the public Rust engine options.
use ::carve::api::{self, HeadingIds, Mode, Profile, SoftBreak, UrlPolicy};
use ::carve::options::{CodeBlockRenderer, Social};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

fn text<'a>(key: &str, value: &'a Value) -> Result<&'a str, String> {
    value.as_str().ok_or_else(|| format!("{key} must be text"))
}
fn flag(key: &str, value: &Value) -> Result<bool, String> {
    value
        .as_bool()
        .ok_or_else(|| format!("{key} must be a boolean"))
}
fn strings(key: &str, value: &Value) -> Result<Vec<String>, String> {
    value
        .as_array()
        .ok_or_else(|| format!("{key} must be a list"))?
        .iter()
        .map(|item| text(key, item).map(str::to_string))
        .collect()
}
fn string_map(key: &str, value: &Value) -> Result<BTreeMap<String, String>, String> {
    value
        .as_object()
        .ok_or_else(|| format!("{key} must be an object"))?
        .iter()
        .map(|(name, item)| Ok((name.clone(), text(key, item)?.to_string())))
        .collect()
}

pub(crate) fn read(value: &Value) -> Result<api::Options, String> {
    let mut out = api::Options::default();
    let map = value.as_object().ok_or("options must be an object")?;
    for (key, item) in map {
        match key.as_str() {
            "mode" => {
                out.mode = match text(key, item)? {
                    "interactive" => Mode::Interactive,
                    "static" => Mode::Static,
                    _ => return Err("mode must be interactive or static".into()),
                }
            }
            "headingIds" => {
                out.heading_ids =
                    HeadingIds::from_name(text(key, item)?).ok_or("invalid headingIds")?
            }
            "profile" => {
                out.profile = Profile::from_name(text(key, item)?).ok_or("invalid profile")?
            }
            "softBreak" => {
                out.soft_break =
                    SoftBreak::from_name(text(key, item)?).ok_or("invalid softBreak")?
            }
            "sections" => out.sections = flag(key, item)?,
            "rawHtml" => out.raw_html = flag(key, item)?,
            "sourceLines" => out.source_lines = flag(key, item)?,
            "smartTypography" => out.smart_typography = flag(key, item)?,
            "roundtrip" => out.roundtrip = flag(key, item)?,
            "strictLosses" => out.strict_losses = flag(key, item)?,
            "symbols" => out.symbols = string_map(key, item)?,
            "labels" => out.labels.extend(string_map(key, item)?),
            "allowLosses" => out.allow_losses = strings(key, item)?,
            "maxLosses" => {
                out.max_losses = item
                    .as_u64()
                    .and_then(|n| usize::try_from(n).ok())
                    .ok_or("maxLosses must be a count")?
            }
            "urlPolicy" => {
                let policy = item.as_object().ok_or("urlPolicy must be an object")?;
                out.url_policy = if policy.len() == 1 {
                    if let Some(deny) = policy.get("deny") {
                        UrlPolicy::Deny(strings(key, deny)?)
                    } else if let Some(allow) = policy.get("allow") {
                        UrlPolicy::Allow(strings(key, allow)?)
                    } else {
                        return Err("urlPolicy must have allow or deny".into());
                    }
                } else {
                    return Err("urlPolicy must have exactly one of allow or deny".into());
                };
            }
            "social" => {
                let social = string_map(key, item)?;
                for name in social.keys() {
                    if !matches!(name.as_str(), "mentionUrl" | "tagUrl") {
                        return Err(format!("unknown social field {name}"));
                    }
                }
                out.social = Some(Social {
                    mention_url: social.get("mentionUrl").cloned(),
                    tag_url: social.get("tagUrl").cloned(),
                });
            }
            "includes" => {
                if item.is_null() {
                    out.includes = None;
                    continue;
                }
                let includes = item.as_object().ok_or("includes must be an object")?;
                let root = text(
                    "includes.root",
                    includes.get("root").ok_or("includes.root is required")?,
                )?;
                let allow_absolute = includes
                    .get("allowAbsolute")
                    .map_or(Ok(true), |v| flag("includes.allowAbsolute", v))?;
                let resolver = ::carve::include::fs::resolver_with(Path::new(root), allow_absolute)
                    .map_err(|e| format!("include root: {e:?}"))?;
                let mut resolved = api::Includes::new(resolver);
                for (name, value) in includes {
                    match name.as_str() {
                        "root" | "allowAbsolute" => {}
                        "file" => resolved.file = Some(text("includes.file", value)?.to_string()),
                        "depth" => {
                            resolved.depth = value
                                .as_u64()
                                .and_then(|n| usize::try_from(n).ok())
                                .ok_or("includes.depth must be a count")?
                        }
                        "bytes" => {
                            resolved.bytes = value
                                .as_u64()
                                .and_then(|n| usize::try_from(n).ok())
                                .ok_or("includes.bytes must be a count")?
                        }
                        _ => return Err(format!("unknown includes field {name}")),
                    }
                }
                out.includes = Some(resolved);
            }
            "codeBlockRenderer" => {
                if item.is_null() {
                    out.code_block_renderer = None;
                    continue;
                }
                let config = item
                    .as_object()
                    .ok_or("codeBlockRenderer must be an object")?;
                for name in config.keys() {
                    if !matches!(name.as_str(), "syntax" | "result") {
                        return Err(format!("unknown codeBlockRenderer field {name}"));
                    }
                }
                let syntax = config
                    .get("syntax")
                    .filter(|v| !v.is_null())
                    .map(|v| text("codeBlockRenderer.syntax", v).map(str::to_string))
                    .transpose()?;
                let result = config
                    .get("result")
                    .filter(|v| !v.is_null())
                    .map(|v| text("codeBlockRenderer.result", v).map(str::to_string))
                    .transpose()?;
                out.code_block_renderer = Some(CodeBlockRenderer::new(move |node, default| {
                    let own = node.get("syntax").and_then(Value::as_str).unwrap_or("");
                    if syntax.as_deref().is_some_and(|s| s != own) {
                        return None;
                    }
                    result
                        .as_ref()
                        .map(|html| html.replace("{default}", default).replace("{syntax}", own))
                }));
            }
            "extensions" | "renderers" => {}
            _ => return Err(format!("native host does not read option {key}")),
        }
    }
    Ok(out)
}
