//! `harvestapi_normalize` turns a raw `harvestapi/linkedin-profile-search` Apify actor
//! response into the internal SearchBatchResult contract (PLAN.md sec.13, PROPOSAL.md
//! sec.10, CONTRACT.md sec.26-27). Pure transformation: no network calls, no secrets --
//! the caller (an n8n workflow) already fetched the raw dataset items and run cost from
//! Apify and passes them in on stdin.
//!
//! CONTRACT.md sec.27: provider-specific fields may live in metadata/`raw` but must not
//! leak into domain logic unless formally promoted into this normalized contract. Only
//! `canonicalUrl` and `displayName` are promoted here; everything else stays under `raw`
//! for the caller to store as ProfileSnapshot.raw_data if it chooses.
//!
//! Identifier note: the actor's raw items include an `id` field, but nothing in this
//! project's research notes or fixtures confirms it is a stable per-member identifier
//! rather than a per-search-result index. Rather than risk treating an unstable value as
//! CONTRACT.md sec.10's preferred "stable external_id", this normalizer intentionally
//! leaves `externalId` null and relies solely on the canonicalized `linkedinUrl` as the
//! identity key -- itself a genuinely stable identifier, and one the database layer's
//! `resolve_or_create_person_by_external_profile` already accepts on its own. If a future
//! revision confirms `id` is safe to promote, this is the only place that needs to change.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

const TOOL_NAME: &str = "harvestapi_normalize";
const TOOL_VERSION: &str = "0.1.0";
const PROVIDER_NAME: &str = "harvestapi";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NormalizeInput {
    #[serde(default)]
    provider_run_id: Option<String>,
    requested_limit: i64,
    #[serde(default)]
    actual_cost_usd: Option<f64>,
    #[serde(default)]
    next_cursor: Option<String>,
    #[serde(default)]
    raw_items: Option<Vec<serde_json::Value>>,
    #[serde(default)]
    provider_error: Option<String>,
}

#[derive(Debug, Serialize, Clone)]
struct NormalizedCandidate {
    platform: &'static str,
    #[serde(rename = "externalId")]
    external_id: Option<String>,
    #[serde(rename = "canonicalUrl")]
    canonical_url: String,
    #[serde(rename = "displayName")]
    display_name: String,
    raw: serde_json::Value,
}

#[derive(Debug, Serialize)]
struct NormalizeResult {
    provider: &'static str,
    #[serde(rename = "providerRunId")]
    provider_run_id: Option<String>,
    candidates: Vec<NormalizedCandidate>,
    #[serde(rename = "rawCount")]
    raw_count: usize,
    #[serde(rename = "uniqueCount")]
    unique_count: usize,
    #[serde(rename = "duplicateCount")]
    duplicate_count: usize,
    #[serde(rename = "skippedCount")]
    skipped_count: usize,
    #[serde(rename = "providerExhausted")]
    provider_exhausted: bool,
    #[serde(rename = "actualCostUsd")]
    actual_cost_usd: Option<f64>,
    #[serde(rename = "nextCursor")]
    next_cursor: Option<String>,
}

#[derive(Debug, Serialize)]
struct ToolError {
    code: &'static str,
    message: String,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum ToolOutput {
    Ok {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        result: NormalizeResult,
    },
    Err {
        ok: bool,
        tool: &'static str,
        version: &'static str,
        error: ToolError,
    },
}

fn err(code: &'static str, message: impl Into<String>) -> ToolOutput {
    ToolOutput::Err {
        ok: false,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        error: ToolError {
            code,
            message: message.into(),
        },
    }
}

/// Normalizes a profile URL so different representations of the same real profile collapse
/// to the same canonical_url -- this is the ONLY identity signal in play for this provider
/// (external_id is deliberately left null, see the module doc comment), and
/// external_profile's (platform, canonical_url) uniqueness (CONTRACT.md sec.10-11) depends
/// entirely on this being consistent. Strips query string/fragment and a trailing slash,
/// forces scheme to https, lowercases the host, and strips a www./m./mobile. subdomain, so
/// `http://www.LinkedIn.com/in/Alice/`, `https://m.linkedin.com/in/Alice?trk=x`, and
/// `linkedin.com/in/Alice` all normalize identically.
fn normalize_canonical_url(raw: &str) -> String {
    let trimmed = raw.trim();
    let without_fragment = trimmed.split('#').next().unwrap_or(trimmed);
    let without_query = without_fragment.split('?').next().unwrap_or(without_fragment);
    let after_scheme = without_query
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(without_query);
    let (host, path) = match after_scheme.split_once('/') {
        Some((h, p)) => (h, format!("/{p}")),
        None => (after_scheme, String::new()),
    };

    let mut host_lower = host.to_lowercase();
    for prefix in ["www.", "m.", "mobile."] {
        if let Some(stripped) = host_lower.strip_prefix(prefix) {
            host_lower = stripped.to_string();
            break;
        }
    }

    let path_trimmed = path.trim_end_matches('/');
    if host_lower.is_empty() {
        return String::new();
    }
    format!("https://{host_lower}{path_trimmed}")
}

fn process(raw_input: &str) -> ToolOutput {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return err("INVALID_INPUT", "stdin was empty; harvestapi_normalize requires a JSON input object");
    }

    let input: NormalizeInput = match serde_json::from_str(trimmed) {
        Ok(parsed) => parsed,
        Err(e) => return err("INVALID_INPUT", format!("stdin was not a valid normalize input: {e}")),
    };

    if input.requested_limit <= 0 {
        return err("INVALID_INPUT", format!("requested_limit must be > 0, got {}", input.requested_limit));
    }
    if input.actual_cost_usd.is_some_and(|v| v < 0.0) {
        return err("INVALID_INPUT", "actual_cost_usd must be >= 0 when set");
    }

    // Provider failure (CONTRACT.md sec.76 "provider failure"): the actor run itself
    // errored; the caller reports this explicitly rather than us guessing from shape.
    if let Some(message) = input.provider_error {
        return err("PROVIDER_ERROR", message);
    }

    let raw_items = match input.raw_items {
        Some(items) => items,
        None => {
            return err(
                "INVALID_INPUT",
                "one of raw_items or provider_error is required",
            )
        }
    };

    let raw_count = raw_items.len();
    let mut candidates: Vec<NormalizedCandidate> = Vec::with_capacity(raw_count);
    let mut seen_urls: Vec<String> = Vec::with_capacity(raw_count);
    let mut duplicate_count = 0usize;
    let mut skipped_count = 0usize;

    for item in &raw_items {
        let linkedin_url = item.get("linkedinUrl").and_then(|v| v.as_str());
        let Some(linkedin_url) = linkedin_url else {
            skipped_count += 1;
            continue;
        };
        let canonical_url = normalize_canonical_url(linkedin_url);
        if canonical_url.is_empty() {
            skipped_count += 1;
            continue;
        }

        if seen_urls.contains(&canonical_url) {
            duplicate_count += 1;
            continue;
        }
        seen_urls.push(canonical_url.clone());

        let first_name = item.get("firstName").and_then(|v| v.as_str()).unwrap_or("");
        let last_name = item.get("lastName").and_then(|v| v.as_str()).unwrap_or("");
        let display_name = format!("{first_name} {last_name}").trim().to_string();

        candidates.push(NormalizedCandidate {
            platform: "linkedin",
            external_id: None,
            canonical_url,
            display_name,
            raw: item.clone(),
        });
    }

    let unique_count = candidates.len();
    // Standard Apify-style pagination heuristic: a page returning fewer results than
    // requested (including zero) signals the provider has nothing more to give.
    let provider_exhausted = raw_count == 0 || raw_count < input.requested_limit as usize;

    ToolOutput::Ok {
        ok: true,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        result: NormalizeResult {
            provider: PROVIDER_NAME,
            provider_run_id: input.provider_run_id,
            candidates,
            raw_count,
            unique_count,
            duplicate_count,
            skipped_count,
            provider_exhausted,
            actual_cost_usd: input.actual_cost_usd,
            next_cursor: input.next_cursor,
        },
    }
}

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        eprintln!("harvestapi_normalize: failed to serialize output: {e}");
        std::process::exit(2);
    });

    println!("{serialized}");
    io::stdout().flush()?;

    std::process::exit(if is_ok { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shape observed from a real prior execution of this project's pre-existing
    /// "Connection Automation - Apify Search (Goal-Driven)" n8n workflow's Search Page
    /// node (execution #116 on the linkedin_automation n8n instance), used as a realistic
    /// fixture rather than a guessed shape.
    fn realistic_item(linkedin_url: &str, first: &str, last: &str) -> serde_json::Value {
        serde_json::json!({
            "id": "abc123",
            "linkedinUrl": linkedin_url,
            "firstName": first,
            "lastName": last,
            "summary": "Some summary text",
            "openProfile": true,
            "premium": false,
            "currentPositions": [{"title": "Software Engineer", "company": "Acme"}],
            "pictureUrl": "https://example.test/pic.jpg",
            "location": {"linkedinText": "Montreal, Quebec, Canada"},
            "_meta": {"pagination": {"page": 1}, "scrapedAt": "2026-08-29T21:08:00Z"},
            "profileIdInSearch": "1"
        })
    }

    fn ok_result(output: ToolOutput) -> NormalizeResult {
        match output {
            ToolOutput::Ok { result, .. } => result,
            ToolOutput::Err { error, .. } => panic!("expected Ok, got error: {error:?}"),
        }
    }

    fn err_output(output: ToolOutput) -> ToolError {
        match output {
            ToolOutput::Err { error, .. } => error,
            ToolOutput::Ok { .. } => panic!("expected Err, got Ok"),
        }
    }

    /// CONTRACT.md sec.76: "HarvestAPI search response normalization".
    #[test]
    fn normalizes_a_realistic_batch() {
        let input = serde_json::json!({
            "provider_run_id": "run-1",
            "requested_limit": 25,
            "actual_cost_usd": 0.82,
            "raw_items": [
                realistic_item("https://www.linkedin.com/in/alice-synthetic-123/", "Alice", "Synthetic"),
                realistic_item("https://www.linkedin.com/in/bob-synthetic-456", "Bob", "Synthetic"),
            ]
        });
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.raw_count, 2);
        assert_eq!(result.unique_count, 2);
        assert_eq!(result.duplicate_count, 0);
        assert_eq!(result.skipped_count, 0);
        assert_eq!(result.candidates[0].canonical_url, "https://linkedin.com/in/alice-synthetic-123");
        assert_eq!(result.candidates[0].display_name, "Alice Synthetic");
        assert_eq!(result.candidates[0].platform, "linkedin");
        assert!(result.candidates[0].external_id.is_none());
    }

    #[test]
    fn canonical_url_strips_trailing_slash_and_query_string() {
        let input = serde_json::json!({
            "requested_limit": 25,
            "raw_items": [realistic_item("https://www.linkedin.com/in/alice-synthetic-123/?trk=abc#frag", "Alice", "Synthetic")]
        });
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.candidates[0].canonical_url, "https://linkedin.com/in/alice-synthetic-123");
    }

    /// Independent review finding #1: different representations of the same profile URL
    /// (www vs bare host, http vs https, mobile subdomain, host casing, no scheme at all)
    /// must all normalize identically, since canonical_url is the sole identity signal
    /// this provider supplies (external_id is always null).
    #[test]
    fn different_url_forms_of_the_same_profile_normalize_identically() {
        let forms = [
            "https://www.linkedin.com/in/alice-synthetic-123",
            "http://www.linkedin.com/in/alice-synthetic-123",
            "https://linkedin.com/in/alice-synthetic-123",
            "https://m.linkedin.com/in/alice-synthetic-123",
            "https://mobile.linkedin.com/in/alice-synthetic-123/",
            "https://WWW.LinkedIn.com/in/alice-synthetic-123",
            "linkedin.com/in/alice-synthetic-123",
            "www.linkedin.com/in/alice-synthetic-123?trk=abc#frag",
        ];
        let normalized: Vec<String> = forms
            .iter()
            .map(|url| {
                let input = serde_json::json!({
                    "requested_limit": 25,
                    "raw_items": [realistic_item(url, "Alice", "Synthetic")]
                });
                ok_result(process(&input.to_string())).candidates[0].canonical_url.clone()
            })
            .collect();
        for (form, result) in forms.iter().zip(normalized.iter()) {
            assert_eq!(
                result, &normalized[0],
                "form {form:?} normalized to {result:?}, expected {:?}",
                normalized[0]
            );
        }
        assert_eq!(normalized[0], "https://linkedin.com/in/alice-synthetic-123");
    }

    #[test]
    fn a_different_profile_path_does_not_collapse_to_the_same_url() {
        let input_a = serde_json::json!({"requested_limit": 25, "raw_items": [realistic_item("https://www.linkedin.com/in/alice", "Alice", "S")]});
        let input_b = serde_json::json!({"requested_limit": 25, "raw_items": [realistic_item("https://www.linkedin.com/in/bob", "Bob", "S")]});
        let a = ok_result(process(&input_a.to_string()));
        let b = ok_result(process(&input_b.to_string()));
        assert_ne!(a.candidates[0].canonical_url, b.candidates[0].canonical_url);
    }

    #[test]
    fn duplicate_urls_within_one_batch_are_deduplicated() {
        let input = serde_json::json!({
            "requested_limit": 25,
            "raw_items": [
                realistic_item("https://www.linkedin.com/in/alice-synthetic-123", "Alice", "Synthetic"),
                realistic_item("https://www.linkedin.com/in/alice-synthetic-123/", "Alice", "Synthetic"),
            ]
        });
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.raw_count, 2);
        assert_eq!(result.unique_count, 1);
        assert_eq!(result.duplicate_count, 1);
    }

    #[test]
    fn items_missing_linkedin_url_are_skipped_not_erroring_the_whole_batch() {
        let input = serde_json::json!({
            "requested_limit": 25,
            "raw_items": [
                serde_json::json!({"firstName": "No", "lastName": "Url"}),
                realistic_item("https://www.linkedin.com/in/alice-synthetic-123", "Alice", "Synthetic"),
            ]
        });
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.raw_count, 2);
        assert_eq!(result.skipped_count, 1);
        assert_eq!(result.unique_count, 1);
    }

    /// CONTRACT.md sec.76: "exhausted pagination".
    #[test]
    fn empty_batch_is_exhausted() {
        let input = serde_json::json!({"requested_limit": 25, "raw_items": []});
        let result = ok_result(process(&input.to_string()));
        assert!(result.provider_exhausted);
        assert_eq!(result.raw_count, 0);
    }

    #[test]
    fn a_full_page_is_not_marked_exhausted() {
        let items: Vec<_> = (0..25)
            .map(|i| realistic_item(&format!("https://www.linkedin.com/in/person-{i}"), "P", "Erson"))
            .collect();
        let input = serde_json::json!({"requested_limit": 25, "raw_items": items});
        let result = ok_result(process(&input.to_string()));
        assert!(!result.provider_exhausted);
    }

    #[test]
    fn a_partial_page_is_marked_exhausted() {
        let items: Vec<_> = (0..3)
            .map(|i| realistic_item(&format!("https://www.linkedin.com/in/person-{i}"), "P", "Erson"))
            .collect();
        let input = serde_json::json!({"requested_limit": 25, "raw_items": items});
        let result = ok_result(process(&input.to_string()));
        assert!(result.provider_exhausted);
    }

    /// CONTRACT.md sec.76: "provider failure".
    #[test]
    fn provider_error_is_reported_as_a_tool_error_not_an_empty_success() {
        let input = serde_json::json!({
            "requested_limit": 25,
            "provider_error": "Apify actor run FAILED: rate limited"
        });
        let error = err_output(process(&input.to_string()));
        assert_eq!(error.code, "PROVIDER_ERROR");
        assert!(error.message.contains("rate limited"));
    }

    /// CONTRACT.md sec.76: "provider-reported cost handling".
    #[test]
    fn actual_cost_is_passed_through_when_present() {
        let input = serde_json::json!({"requested_limit": 25, "raw_items": [], "actual_cost_usd": 1.23});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.actual_cost_usd, Some(1.23));
    }

    #[test]
    fn missing_cost_is_null_not_zero() {
        let input = serde_json::json!({"requested_limit": 25, "raw_items": []});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.actual_cost_usd, None);
    }

    /// CONTRACT.md sec.76: "malformed provider result".
    /// Independent review finding #5: a negative provider-reported cost is rejected.
    #[test]
    fn negative_actual_cost_is_rejected() {
        let input = serde_json::json!({"requested_limit": 25, "raw_items": [], "actual_cost_usd": -1.0});
        let error = err_output(process(&input.to_string()));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    /// Independent review finding: deny_unknown_fields should be verified on this tool too.
    #[test]
    fn unknown_field_is_rejected() {
        let input = r#"{"requested_limit": 25, "raw_items": [], "unexpected": 1}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn missing_both_raw_items_and_provider_error_is_rejected() {
        let input = serde_json::json!({"requested_limit": 25});
        let error = err_output(process(&input.to_string()));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn raw_items_not_an_array_is_rejected() {
        let input = r#"{"requested_limit": 25, "raw_items": "not an array"}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn malformed_json_is_rejected() {
        let error = err_output(process("{not valid json"));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn next_cursor_passes_through_unchanged() {
        let input = serde_json::json!({"requested_limit": 25, "raw_items": [], "next_cursor": "page-2-token"});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.next_cursor, Some("page-2-token".to_string()));
    }

    #[test]
    fn output_always_carries_tool_name_and_version() {
        for output in [process(""), process("{not valid json")] {
            let value = serde_json::to_value(&output).unwrap();
            assert_eq!(value["tool"], "harvestapi_normalize");
            assert_eq!(value["version"], "0.1.0");
        }
    }
}
