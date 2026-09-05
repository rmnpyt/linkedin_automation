//! `enrichment_policy` decides whether a qualified candidate is eligible for email
//! enrichment, per CONTRACT.md sec.39's eligibility conditions -- pure deterministic
//! decision logic, no I/O, same stdin/stdout/exit contract as every other clitools binary.
//!
//! Count-cap and cost-budget enforcement themselves are owned by the database
//! (`claim_contact_enrichment_attempt`, `reserve_campaign_budget` -- CONTRACT.md sec.69);
//! this tool only answers "should we even attempt to claim/reserve for this candidate",
//! from already-known counts/costs, mirroring `campaign_policy`'s relationship to
//! `reserve_campaign_budget` in Phase 1.2.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

const TOOL_NAME: &str = "enrichment_policy";
const TOOL_VERSION: &str = "0.1.0";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EnrichmentBudgetPolicy {
    email_enrichment_enabled: bool,
    #[serde(default)]
    minimum_score_for_email_enrichment: Option<f64>,
    #[serde(default)]
    max_email_enrichments: Option<i64>,
    #[serde(default)]
    max_email_enrichment_cost_usd: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Candidate {
    qualified: bool,
    #[serde(default)]
    composite_score: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CurrentState {
    attempt_count: i64,
    committed_cost_usd: f64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PolicyInput {
    policy: EnrichmentBudgetPolicy,
    candidate: Candidate,
    #[serde(rename = "currentState")]
    current_state: CurrentState,
}

#[derive(Debug, Serialize)]
struct PolicyResult {
    eligible: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'static str>,
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
        result: PolicyResult,
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

/// Precedence (CONTRACT.md sec.39 lists conditions without a mandated order; documented
/// and tested here): campaign-level enable flag, then candidate qualification, then score
/// threshold, then the two independent caps (attempt count, cost).
fn process(raw_input: &str) -> ToolOutput {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return err("INVALID_INPUT", "stdin was empty; enrichment_policy requires a JSON input object");
    }

    let input: PolicyInput = match serde_json::from_str(trimmed) {
        Ok(parsed) => parsed,
        Err(e) => return err("INVALID_INPUT", format!("stdin was not a valid policy input: {e}")),
    };

    if input.current_state.attempt_count < 0 {
        return err("INVALID_INPUT", "attempt_count must be >= 0");
    }
    if input.current_state.committed_cost_usd < 0.0 {
        return err("INVALID_INPUT", "committed_cost_usd must be >= 0");
    }
    if input
        .policy
        .max_email_enrichment_cost_usd
        .is_some_and(|v| v < 0.0)
    {
        return err("INVALID_INPUT", "max_email_enrichment_cost_usd must be >= 0 when set");
    }
    if input.policy.max_email_enrichments.is_some_and(|v| v < 0) {
        return err("INVALID_INPUT", "max_email_enrichments must be >= 0 when set");
    }

    let reason: Option<&'static str> = if !input.policy.email_enrichment_enabled {
        Some("DISABLED")
    } else if !input.candidate.qualified {
        Some("NOT_QUALIFIED")
    } else if let Some(min_score) = input.policy.minimum_score_for_email_enrichment {
        match input.candidate.composite_score {
            Some(score) if score < min_score => Some("BELOW_SCORE_THRESHOLD"),
            None => Some("BELOW_SCORE_THRESHOLD"),
            _ => None,
        }
    } else {
        None
    };

    let reason = reason.or_else(|| {
        if input
            .policy
            .max_email_enrichments
            .is_some_and(|max| input.current_state.attempt_count >= max)
        {
            Some("ATTEMPT_LIMIT_REACHED")
        } else {
            None
        }
    });

    let reason = reason.or_else(|| {
        if input
            .policy
            .max_email_enrichment_cost_usd
            .is_some_and(|max| input.current_state.committed_cost_usd >= max)
        {
            Some("COST_BUDGET_EXHAUSTED")
        } else {
            None
        }
    });

    ToolOutput::Ok {
        ok: true,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        result: PolicyResult {
            eligible: reason.is_none(),
            reason,
        },
    }
}

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        eprintln!("enrichment_policy: failed to serialize output: {e}");
        std::process::exit(2);
    });

    println!("{serialized}");
    io::stdout().flush()?;

    std::process::exit(if is_ok { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_input(
        enabled: bool,
        min_score: Option<f64>,
        max_attempts: Option<i64>,
        max_cost: Option<f64>,
        qualified: bool,
        score: Option<f64>,
        attempt_count: i64,
        committed_cost: f64,
    ) -> String {
        serde_json::json!({
            "policy": {
                "email_enrichment_enabled": enabled,
                "minimum_score_for_email_enrichment": min_score,
                "max_email_enrichments": max_attempts,
                "max_email_enrichment_cost_usd": max_cost,
            },
            "candidate": {"qualified": qualified, "composite_score": score},
            "currentState": {"attempt_count": attempt_count, "committed_cost_usd": committed_cost},
        })
        .to_string()
    }

    fn ok_result(output: ToolOutput) -> PolicyResult {
        match output {
            ToolOutput::Ok { result, .. } => result,
            ToolOutput::Err { error, .. } => panic!("expected Ok, got error: {error:?}"),
        }
    }

    #[test]
    fn eligible_when_every_condition_passes() {
        let input = make_input(true, Some(70.0), Some(200), Some(3.0), true, Some(85.0), 50, 1.0);
        let result = ok_result(process(&input));
        assert!(result.eligible);
        assert_eq!(result.reason, None);
    }

    #[test]
    fn disabled_policy_is_not_eligible() {
        let input = make_input(false, None, None, None, true, Some(85.0), 0, 0.0);
        let result = ok_result(process(&input));
        assert!(!result.eligible);
        assert_eq!(result.reason, Some("DISABLED"));
    }

    #[test]
    fn unqualified_candidate_is_not_eligible() {
        let input = make_input(true, None, None, None, false, Some(85.0), 0, 0.0);
        let result = ok_result(process(&input));
        assert_eq!(result.reason, Some("NOT_QUALIFIED"));
    }

    #[test]
    fn below_score_threshold_is_not_eligible() {
        let input = make_input(true, Some(70.0), None, None, true, Some(60.0), 0, 0.0);
        let result = ok_result(process(&input));
        assert_eq!(result.reason, Some("BELOW_SCORE_THRESHOLD"));
    }

    #[test]
    fn missing_score_with_a_threshold_configured_is_not_eligible() {
        let input = make_input(true, Some(70.0), None, None, true, None, 0, 0.0);
        let result = ok_result(process(&input));
        assert_eq!(result.reason, Some("BELOW_SCORE_THRESHOLD"));
    }

    #[test]
    fn no_threshold_configured_allows_any_score() {
        let input = make_input(true, None, None, None, true, None, 0, 0.0);
        let result = ok_result(process(&input));
        assert!(result.eligible);
    }

    #[test]
    fn attempt_limit_reached_is_not_eligible() {
        let input = make_input(true, None, Some(100), None, true, Some(90.0), 100, 0.0);
        let result = ok_result(process(&input));
        assert_eq!(result.reason, Some("ATTEMPT_LIMIT_REACHED"));
    }

    #[test]
    fn cost_budget_exhausted_is_not_eligible() {
        let input = make_input(true, None, None, Some(3.0), true, Some(90.0), 0, 3.0);
        let result = ok_result(process(&input));
        assert_eq!(result.reason, Some("COST_BUDGET_EXHAUSTED"));
    }

    #[test]
    fn disabled_takes_precedence_over_every_other_reason() {
        let input = make_input(false, Some(70.0), Some(1), Some(1.0), false, Some(0.0), 999, 999.0);
        let result = ok_result(process(&input));
        assert_eq!(result.reason, Some("DISABLED"));
    }

    #[test]
    fn malformed_json_is_rejected() {
        match process("{not valid json") {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }

    #[test]
    fn negative_committed_cost_is_rejected() {
        let input = make_input(true, None, None, None, true, Some(90.0), 0, -1.0);
        match process(&input) {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }

    #[test]
    fn unknown_field_is_rejected() {
        let input = r#"{"policy":{"email_enrichment_enabled":true},"candidate":{"qualified":true},"currentState":{"attempt_count":0,"committed_cost_usd":0},"extra":1}"#;
        match process(input) {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }
}
