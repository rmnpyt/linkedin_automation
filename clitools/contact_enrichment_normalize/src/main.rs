//! `contact_enrichment_normalize` turns a raw HarvestAPI contact-enrichment response into
//! the internal ContactEnrichmentResult contract (PROPOSAL.md sec.16, CONTRACT.md
//! sec.36-38). Pure transformation: no network calls, no secrets.
//!
//! IMPORTANT CAVEAT: unlike `harvestapi_normalize` (built from a real captured execution
//! of this project's pre-existing search workflow), no real HarvestAPI email-enrichment
//! response has been observed yet -- no enrichment call has been made, since paid provider
//! calls are not authorized this phase (AGENT-START.md sec.14, no test budget configured).
//! This tool's parsing of a single top-level `email` string field is a best-effort
//! placeholder shape, not a validated one, and MUST be re-verified (and this file updated
//! if the real shape differs) the first time a live, budget-authorized call is actually
//! made. What IS Contract-load-bearing regardless of the exact raw shape -- and is fully
//! implemented and tested here -- is the semantics: no email found is a valid, non-error
//! result (CONTRACT.md sec.38), and provider-reported verification is distinguished from
//! independently verified (CONTRACT.md sec.38).

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

const TOOL_NAME: &str = "contact_enrichment_normalize";
const TOOL_VERSION: &str = "0.1.0";
const PROVIDER_NAME: &str = "harvestapi";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NormalizeInput {
    #[serde(default)]
    provider_run_id: Option<String>,
    #[serde(default)]
    actual_cost_usd: Option<f64>,
    #[serde(default)]
    raw_result: Option<serde_json::Value>,
    #[serde(default)]
    provider_error: Option<String>,
}

#[derive(Debug, Serialize)]
struct NormalizedContact {
    #[serde(rename = "type")]
    contact_type: &'static str,
    value: String,
    #[serde(rename = "normalizedValue")]
    normalized_value: String,
    #[serde(rename = "verificationStatus")]
    verification_status: &'static str,
}

#[derive(Debug, Serialize)]
struct NormalizeResult {
    provider: &'static str,
    #[serde(rename = "providerRunId")]
    provider_run_id: Option<String>,
    #[serde(rename = "contactsFound")]
    contacts_found: usize,
    contacts: Vec<NormalizedContact>,
    #[serde(rename = "actualCostUsd")]
    actual_cost_usd: Option<f64>,
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

fn normalize_email(raw: &str) -> String {
    raw.trim().to_lowercase()
}

fn process(raw_input: &str) -> ToolOutput {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return err("INVALID_INPUT", "stdin was empty; contact_enrichment_normalize requires a JSON input object");
    }

    let input: NormalizeInput = match serde_json::from_str(trimmed) {
        Ok(parsed) => parsed,
        Err(e) => return err("INVALID_INPUT", format!("stdin was not a valid normalize input: {e}")),
    };

    if input.actual_cost_usd.is_some_and(|v| v < 0.0) {
        return err("INVALID_INPUT", "actual_cost_usd must be >= 0 when set");
    }

    // Provider failure (CONTRACT.md sec.76-equivalent "provider failure" for this
    // capability): the enrichment call itself errored.
    if let Some(message) = input.provider_error {
        return err("PROVIDER_ERROR", message);
    }

    // A JSON `null` and an entirely absent `raw_result` key are indistinguishable once
    // deserialized into Option<Value> (both become None) -- rather than rely on a
    // distinction JSON/serde cannot cleanly represent, both are treated identically as "no
    // data", equivalent to an empty object: a valid no-email-found outcome, not an error
    // (CONTRACT.md sec.38).
    let raw_result = input.raw_result.unwrap_or(serde_json::Value::Null);

    if !raw_result.is_object() && !raw_result.is_null() {
        return err("INVALID_INPUT", "raw_result must be a JSON object or null");
    }

    // A missing/null/empty email is a valid, non-error "no result" (CONTRACT.md sec.38),
    // not an error condition.
    let email = raw_result
        .get("email")
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let contacts = match email {
        Some(raw_email) => vec![NormalizedContact {
            contact_type: "email",
            value: raw_email.to_string(),
            normalized_value: normalize_email(raw_email),
            // PROVIDER_VERIFIED, never silently upgraded to a stronger internally-verified
            // state this tool does not itself perform (CONTRACT.md sec.38).
            verification_status: "PROVIDER_VERIFIED",
        }],
        None => Vec::new(),
    };

    ToolOutput::Ok {
        ok: true,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        result: NormalizeResult {
            provider: PROVIDER_NAME,
            provider_run_id: input.provider_run_id,
            contacts_found: contacts.len(),
            contacts,
            actual_cost_usd: input.actual_cost_usd,
        },
    }
}

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        eprintln!("contact_enrichment_normalize: failed to serialize output: {e}");
        std::process::exit(2);
    });

    println!("{serialized}");
    io::stdout().flush()?;

    std::process::exit(if is_ok { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

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

    /// CONTRACT.md sec.36-38: "contact-enrichment result with email".
    #[test]
    fn email_found_is_normalized() {
        let input = serde_json::json!({
            "raw_result": {"email": " Foo.Bar@Example.COM "},
            "actual_cost_usd": 0.01
        });
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.contacts_found, 1);
        assert_eq!(result.contacts[0].contact_type, "email");
        assert_eq!(result.contacts[0].value, "Foo.Bar@Example.COM");
        assert_eq!(result.contacts[0].normalized_value, "foo.bar@example.com");
        assert_eq!(result.contacts[0].verification_status, "PROVIDER_VERIFIED");
        assert_eq!(result.actual_cost_usd, Some(0.01));
    }

    /// CONTRACT.md sec.36-38: "contact-enrichment result with no email" -- a valid,
    /// non-error outcome, not treated the same as a provider failure.
    #[test]
    fn no_email_field_is_a_valid_no_result() {
        let input = serde_json::json!({"raw_result": {}});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.contacts_found, 0);
        assert!(result.contacts.is_empty());
    }

    #[test]
    fn null_email_value_is_a_valid_no_result() {
        let input = serde_json::json!({"raw_result": {"email": null}});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.contacts_found, 0);
    }

    #[test]
    fn empty_string_email_is_a_valid_no_result() {
        let input = serde_json::json!({"raw_result": {"email": "   "}});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.contacts_found, 0);
    }

    #[test]
    fn null_raw_result_is_a_valid_no_result() {
        let input = serde_json::json!({"raw_result": null});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.contacts_found, 0);
    }

    /// CONTRACT.md sec.76-equivalent: "provider failure".
    #[test]
    fn provider_error_is_reported_as_a_tool_error() {
        let input = serde_json::json!({"provider_error": "Apify actor run FAILED: timeout"});
        let error = err_output(process(&input.to_string()));
        assert_eq!(error.code, "PROVIDER_ERROR");
        assert!(error.message.contains("timeout"));
    }

    /// CONTRACT.md sec.76-equivalent: "provider-reported cost handling".
    #[test]
    fn cost_is_passed_through() {
        let input = serde_json::json!({"raw_result": {}, "actual_cost_usd": 0.02});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.actual_cost_usd, Some(0.02));
    }

    #[test]
    fn missing_cost_is_null_not_zero() {
        let input = serde_json::json!({"raw_result": {}});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.actual_cost_usd, None);
    }

    #[test]
    fn negative_cost_is_rejected() {
        let input = serde_json::json!({"raw_result": {}, "actual_cost_usd": -1.0});
        let error = err_output(process(&input.to_string()));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    /// A caller that supplies neither raw_result nor provider_error gets a valid
    /// no-result outcome rather than an error: JSON `null` and an absent key are
    /// indistinguishable once deserialized, so both must be treated identically.
    #[test]
    fn missing_both_raw_result_and_provider_error_is_a_valid_no_result() {
        let input = serde_json::json!({});
        let result = ok_result(process(&input.to_string()));
        assert_eq!(result.contacts_found, 0);
    }

    /// CONTRACT.md sec.76-equivalent: "malformed provider result".

    #[test]
    fn raw_result_as_a_non_object_non_null_is_rejected() {
        let input = r#"{"raw_result": "not an object"}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn malformed_json_is_rejected() {
        let error = err_output(process("{not valid json"));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn unknown_field_is_rejected() {
        let input = r#"{"raw_result": {}, "extra": 1}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn output_always_carries_tool_name_and_version() {
        for output in [process(""), process("{not valid json")] {
            let value = serde_json::to_value(&output).unwrap();
            assert_eq!(value["tool"], "contact_enrichment_normalize");
            assert_eq!(value["version"], "0.1.0");
        }
    }
}
