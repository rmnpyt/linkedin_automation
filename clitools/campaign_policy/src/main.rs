//! `campaign_policy` decides whether another search batch may run and, if so, how large it
//! may be -- pure deterministic policy logic, no I/O, following the same stdin/stdout/exit
//! contract as `clitools/health` and `clitools/scoring` (PLAN.md sec.5, CONTRACT.md sec.7).
//!
//! Scope is deliberately narrow: search stop-condition decisions and batch-size shrinking
//! (PROPOSAL.md sec.7, CONTRACT.md sec.28,30,34). Email-enrichment eligibility (CONTRACT.md
//! sec.39) is a related but separate decision that belongs to Phase 1.3, not here.
//!
//! Actual budget accounting/reservation is NOT this tool's job -- that is enforced,
//! concurrency-safely, by the `reserve_campaign_budget` database function (CONTRACT.md
//! sec.33,69: workflow/tool code must not be the sole defense for an invariant Postgres can
//! enforce). This tool only answers "given the current known counts/committed costs, should
//! the campaign runner even attempt another batch, and how big should it ask for" -- a
//! decision made from already-durable state, not a source of truth for spend itself.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

const TOOL_NAME: &str = "campaign_policy";
const TOOL_VERSION: &str = "0.1.0";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BudgetPolicy {
    #[serde(default)]
    max_unique_candidates: Option<i64>,
    #[serde(default)]
    max_search_cost_usd: Option<f64>,
    #[serde(default)]
    max_total_campaign_cost_usd: Option<f64>,
    #[serde(default)]
    target_qualified_profiles: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CurrentState {
    unique_candidate_count: i64,
    qualified_count: i64,
    search_committed_cost_usd: f64,
    total_committed_cost_usd: f64,
    provider_exhausted: bool,
    #[serde(default)]
    manual_stop_requested: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PolicyInput {
    #[serde(rename = "budgetPolicy")]
    budget_policy: BudgetPolicy,
    #[serde(rename = "currentState")]
    current_state: CurrentState,
    #[serde(rename = "requestedBatchSize")]
    requested_batch_size: i64,
}

#[derive(Debug, Serialize)]
struct PolicyResult {
    #[serde(rename = "canContinueSearch")]
    can_continue_search: bool,
    #[serde(rename = "stopReason", skip_serializing_if = "Option::is_none")]
    stop_reason: Option<&'static str>,
    #[serde(rename = "adjustedBatchSize")]
    adjusted_batch_size: i64,
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

/// Stop-condition precedence (CONTRACT.md sec.34 lists the six conditions without a
/// mandated order; this tool documents and tests a fixed, deterministic order so behavior
/// is reproducible when multiple conditions are simultaneously true): a manual stop always
/// wins, then provider exhaustion (nothing left to fetch regardless of budget), then the
/// qualified-target goal (the campaign got what it wanted), then the hard candidate-volume
/// cap, then the two cost limits.
fn process(raw_input: &str) -> ToolOutput {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return err("INVALID_INPUT", "stdin was empty; campaign_policy requires a JSON input object");
    }

    let input: PolicyInput = match serde_json::from_str(trimmed) {
        Ok(parsed) => parsed,
        Err(e) => return err("INVALID_INPUT", format!("stdin was not a valid policy input: {e}")),
    };

    if input.requested_batch_size <= 0 {
        return err(
            "INVALID_INPUT",
            format!("requestedBatchSize must be > 0, got {}", input.requested_batch_size),
        );
    }
    if input.current_state.unique_candidate_count < 0 || input.current_state.qualified_count < 0 {
        return err("INVALID_INPUT", "unique_candidate_count and qualified_count must be >= 0");
    }
    if input.current_state.search_committed_cost_usd < 0.0 || input.current_state.total_committed_cost_usd < 0.0 {
        return err("INVALID_INPUT", "search_committed_cost_usd and total_committed_cost_usd must be >= 0");
    }
    for (name, limit) in [
        ("max_search_cost_usd", input.budget_policy.max_search_cost_usd),
        ("max_total_campaign_cost_usd", input.budget_policy.max_total_campaign_cost_usd),
    ] {
        if limit.is_some_and(|v| v < 0.0) {
            return err("INVALID_INPUT", format!("{name} must be >= 0 when set"));
        }
    }
    for (name, limit) in [
        ("max_unique_candidates", input.budget_policy.max_unique_candidates),
        ("target_qualified_profiles", input.budget_policy.target_qualified_profiles),
    ] {
        if limit.is_some_and(|v| v < 0) {
            return err("INVALID_INPUT", format!("{name} must be >= 0 when set"));
        }
    }

    let policy = &input.budget_policy;
    let state = &input.current_state;

    let stop_reason: Option<&'static str> = if state.manual_stop_requested {
        Some("STOP_MANUAL")
    } else if state.provider_exhausted {
        Some("STOP_PROVIDER_EXHAUSTED")
    } else if policy
        .target_qualified_profiles
        .is_some_and(|target| state.qualified_count >= target)
    {
        Some("STOP_QUALIFIED_TARGET_REACHED")
    } else if policy
        .max_unique_candidates
        .is_some_and(|max| state.unique_candidate_count >= max)
    {
        Some("STOP_MAX_UNIQUE_CANDIDATES")
    } else if policy
        .max_search_cost_usd
        .is_some_and(|max| state.search_committed_cost_usd >= max)
    {
        Some("STOP_SEARCH_COST_LIMIT")
    } else if policy
        .max_total_campaign_cost_usd
        .is_some_and(|max| state.total_committed_cost_usd >= max)
    {
        Some("STOP_TOTAL_CAMPAIGN_COST_LIMIT")
    } else {
        None
    };

    if let Some(reason) = stop_reason {
        return ToolOutput::Ok {
            ok: true,
            tool: TOOL_NAME,
            version: TOOL_VERSION,
            result: PolicyResult {
                can_continue_search: false,
                stop_reason: Some(reason),
                adjusted_batch_size: 0,
            },
        };
    }

    // Shrink the requested batch to the remaining unique-candidate capacity when a cap is
    // configured (CONTRACT.md sec.28: "the requested candidate/result capacity SHOULD be
    // reduced to the remaining max_unique_candidates capacity when the provider supports
    // such a limit").
    let adjusted_batch_size = match policy.max_unique_candidates {
        Some(max) => {
            let remaining = (max - state.unique_candidate_count).max(0);
            input.requested_batch_size.min(remaining)
        }
        None => input.requested_batch_size,
    };

    ToolOutput::Ok {
        ok: true,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        result: PolicyResult {
            can_continue_search: adjusted_batch_size > 0,
            stop_reason: if adjusted_batch_size > 0 {
                None
            } else {
                Some("STOP_MAX_UNIQUE_CANDIDATES")
            },
            adjusted_batch_size,
        },
    }
}

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        eprintln!("campaign_policy: failed to serialize output: {e}");
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
        max_unique: Option<i64>,
        max_search_cost: Option<f64>,
        max_total_cost: Option<f64>,
        target_qualified: Option<i64>,
        unique_count: i64,
        qualified_count: i64,
        search_cost: f64,
        total_cost: f64,
        provider_exhausted: bool,
        manual_stop: bool,
        requested_batch: i64,
    ) -> String {
        serde_json::json!({
            "budgetPolicy": {
                "max_unique_candidates": max_unique,
                "max_search_cost_usd": max_search_cost,
                "max_total_campaign_cost_usd": max_total_cost,
                "target_qualified_profiles": target_qualified,
            },
            "currentState": {
                "unique_candidate_count": unique_count,
                "qualified_count": qualified_count,
                "search_committed_cost_usd": search_cost,
                "total_committed_cost_usd": total_cost,
                "provider_exhausted": provider_exhausted,
                "manual_stop_requested": manual_stop,
            },
            "requestedBatchSize": requested_batch,
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
    fn continues_when_nothing_blocks() {
        let input = make_input(Some(1000), Some(10.0), Some(20.0), Some(100), 50, 5, 1.0, 1.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(result.can_continue_search);
        assert_eq!(result.stop_reason, None);
        assert_eq!(result.adjusted_batch_size, 25);
    }

    #[test]
    fn manual_stop_takes_precedence_over_everything_else() {
        let input = make_input(Some(1000), Some(10.0), Some(20.0), Some(100), 50, 5, 1.0, 1.0, true, true, 25);
        let result = ok_result(process(&input));
        assert!(!result.can_continue_search);
        assert_eq!(result.stop_reason, Some("STOP_MANUAL"));
    }

    #[test]
    fn provider_exhausted_stops_regardless_of_remaining_budget() {
        let input = make_input(Some(1000), Some(10.0), Some(20.0), None, 50, 5, 1.0, 1.0, true, false, 25);
        let result = ok_result(process(&input));
        assert!(!result.can_continue_search);
        assert_eq!(result.stop_reason, Some("STOP_PROVIDER_EXHAUSTED"));
    }

    #[test]
    fn qualified_target_reached_stops_the_campaign() {
        let input = make_input(Some(1000), None, None, Some(10), 500, 10, 1.0, 1.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(!result.can_continue_search);
        assert_eq!(result.stop_reason, Some("STOP_QUALIFIED_TARGET_REACHED"));
    }

    #[test]
    fn qualified_target_not_yet_reached_continues() {
        let input = make_input(Some(1000), None, None, Some(10), 500, 9, 1.0, 1.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(result.can_continue_search);
    }

    #[test]
    fn max_unique_candidates_reached_stops() {
        let input = make_input(Some(100), None, None, None, 100, 5, 1.0, 1.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(!result.can_continue_search);
        assert_eq!(result.stop_reason, Some("STOP_MAX_UNIQUE_CANDIDATES"));
    }

    #[test]
    fn search_cost_limit_stops() {
        let input = make_input(None, Some(10.0), None, None, 50, 5, 10.0, 10.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(!result.can_continue_search);
        assert_eq!(result.stop_reason, Some("STOP_SEARCH_COST_LIMIT"));
    }

    #[test]
    fn total_campaign_cost_limit_stops_even_when_search_cost_is_fine() {
        let input = make_input(None, Some(100.0), Some(20.0), None, 50, 5, 5.0, 20.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(!result.can_continue_search);
        assert_eq!(result.stop_reason, Some("STOP_TOTAL_CAMPAIGN_COST_LIMIT"));
    }

    #[test]
    fn unconfigured_limits_never_trigger_a_stop() {
        // No limits configured at all -- only manual/provider-exhausted could ever stop this.
        let input = make_input(None, None, None, None, 1_000_000, 1_000_000, 1_000_000.0, 1_000_000.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(result.can_continue_search);
        assert_eq!(result.adjusted_batch_size, 25);
    }

    /// CONTRACT.md sec.28: batch size shrinks to the remaining unique-candidate capacity.
    #[test]
    fn batch_size_shrinks_to_remaining_capacity() {
        let input = make_input(Some(100), None, None, None, 90, 5, 1.0, 1.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(result.can_continue_search);
        assert_eq!(result.adjusted_batch_size, 10); // only 10 slots remain (100-90)
    }

    #[test]
    fn batch_size_is_not_shrunk_below_the_request_when_capacity_is_larger() {
        let input = make_input(Some(1000), None, None, None, 90, 5, 1.0, 1.0, false, false, 25);
        let result = ok_result(process(&input));
        assert_eq!(result.adjusted_batch_size, 25);
    }

    #[test]
    fn exactly_at_capacity_boundary_stops_via_shrink_path_too() {
        // unique_candidate_count already equals max: the early stop-reason check catches
        // this case directly (STOP_MAX_UNIQUE_CANDIDATES), so canContinueSearch is false
        // with a zero adjusted batch, not a confusing "continue with batch size 0".
        let input = make_input(Some(90), None, None, None, 90, 5, 1.0, 1.0, false, false, 25);
        let result = ok_result(process(&input));
        assert!(!result.can_continue_search);
        assert_eq!(result.adjusted_batch_size, 0);
        assert_eq!(result.stop_reason, Some("STOP_MAX_UNIQUE_CANDIDATES"));
    }

    #[test]
    fn malformed_json_is_rejected() {
        match process("{not valid json") {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }

    /// Independent review finding #5: negative committed-cost/limit values must be
    /// rejected, not silently accepted and left to produce wrong stop-reason precedence.
    #[test]
    fn negative_committed_cost_is_rejected() {
        let input = make_input(None, Some(10.0), None, None, 10, 5, -1.0, 1.0, false, false, 25);
        match process(&input) {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }

    #[test]
    fn negative_budget_limit_is_rejected() {
        let input = make_input(None, Some(-5.0), None, None, 10, 5, 1.0, 1.0, false, false, 25);
        match process(&input) {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }

    #[test]
    fn zero_or_negative_requested_batch_size_is_rejected() {
        let input = make_input(Some(100), None, None, None, 10, 5, 1.0, 1.0, false, false, 0);
        match process(&input) {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }

    #[test]
    fn unknown_field_is_rejected() {
        let input = r#"{"budgetPolicy":{},"currentState":{"unique_candidate_count":0,"qualified_count":0,"search_committed_cost_usd":0,"total_committed_cost_usd":0,"provider_exhausted":false},"requestedBatchSize":10,"extra":1}"#;
        match process(input) {
            ToolOutput::Err { error, .. } => assert_eq!(error.code, "INVALID_INPUT"),
            ToolOutput::Ok { .. } => panic!("expected error"),
        }
    }
}
