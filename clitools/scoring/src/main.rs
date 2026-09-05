//! `scoring` is the deterministic KPI scoring engine (PLAN.md sec.12, CONTRACT.md sec.18-25,
//! doc/KPI-FRAMEWORK.md). It follows the invocation contract established by `clitools/health`:
//! one JSON object on stdin, one JSON object on stdout, exit code 0/1, no network access, no
//! secrets. It performs only deterministic arithmetic on KPI judgments an LLM has already
//! produced -- it never calls an LLM and never invents a score (CONTRACT.md sec.7,20.1,24).
//!
//! Responsibilities, in order:
//! 1. Validate weights (must sum to 100, no negative weight) and the qualification threshold
//!    (CONTRACT.md sec.19).
//! 2. Validate every provided KPI score is within 0..100 (CONTRACT.md sec.20.2) -- an
//!    out-of-range score is a validation error, not something to silently clamp or coerce
//!    (CONTRACT.md sec.24: malformed output must not be silently coerced).
//! 3. Decide COMPLETE vs INCOMPLETE: in V1 only KPI 5 may be missing. If KPI 1, 2, 3, 4, or 6
//!    is missing, the evaluation is INCOMPLETE -- no invented score, no silent reweighting,
//!    and it can never be qualified (CONTRACT.md sec.20.1).
//! 4. Apply the KPI 6 seniority-offset rule: when KPI 3 >= 80, effective KPI 6 must not fall
//!    below 50 (doc/KPI-FRAMEWORK.md, CONTRACT.md sec.20.2), while never exceeding 100.
//! 5. If KPI 5 is missing (and only then), proportionally renormalize the remaining five
//!    weights back up to 100 (CONTRACT.md sec.20, doc/KPI-FRAMEWORK.md "Composite Score").
//! 6. Apply hard filters: requireField fails when KPI 1 == 0; requireLocation fails when
//!    KPI 2 == 0 (CONTRACT.md sec.21).
//! 7. Compute the composite score at fixed precision and qualify using the *unrounded*
//!    (well: fixed 6-decimal-precision) authoritative value, never the 2-decimal display
//!    value, so display rounding can never flip a qualification decision
//!    (CONTRACT.md sec.20.3).

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const TOOL_NAME: &str = "scoring";
const TOOL_VERSION: &str = "0.1.0";

/// Composite score is rounded to this many decimal places for the authoritative,
/// qualification-deciding value (CONTRACT.md sec.20.3 "fixed/controlled numeric precision").
const AUTHORITATIVE_PRECISION: i32 = 6;
/// Separate, coarser rounding used only for human-facing display; never used for the
/// qualification comparison itself.
const DISPLAY_PRECISION: i32 = 2;
/// KPI 3 score at or above this value triggers the KPI 6 seniority floor.
const SENIORITY_THRESHOLD: i32 = 80;
/// The KPI 6 floor applied when the seniority threshold is met.
const SENIORITY_KPI6_FLOOR: i32 = 50;
/// Tolerance for "weights sum to 100" floating-point comparison.
const WEIGHT_SUM_EPSILON: f64 = 1e-6;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Weights {
    kpi1: f64,
    kpi2: f64,
    kpi3: f64,
    kpi4: f64,
    kpi5: f64,
    kpi6: f64,
}

impl Weights {
    fn sum(&self) -> f64 {
        self.kpi1 + self.kpi2 + self.kpi3 + self.kpi4 + self.kpi5 + self.kpi6
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct KpiScores {
    kpi1: Option<i32>,
    kpi2: Option<i32>,
    kpi3: Option<i32>,
    kpi4: Option<i32>,
    kpi5: Option<i32>,
    kpi6: Option<i32>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ScoringInput {
    weights: Weights,
    scores: KpiScores,
    #[serde(rename = "requireField")]
    require_field: bool,
    #[serde(rename = "requireLocation")]
    require_location: bool,
    #[serde(rename = "qualificationThreshold")]
    qualification_threshold: f64,
}

#[derive(Debug, Serialize, Clone, Copy)]
struct EffectiveWeights {
    kpi1: f64,
    kpi2: f64,
    kpi3: f64,
    kpi4: f64,
    kpi5: Option<f64>,
    kpi6: f64,
}

#[derive(Debug, Serialize)]
struct FilterResults {
    require_field: bool,
    require_location: bool,
    field_passed: Option<bool>,
    location_passed: Option<bool>,
    hard_filter_passed: Option<bool>,
}

#[derive(Debug, Serialize)]
struct ScoreAdjustment {
    raw: i32,
    effective: i32,
    rule: &'static str,
}

#[derive(Debug, Serialize)]
struct ScoringResult {
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    #[serde(rename = "effectiveScores")]
    effective_scores: BTreeMap<&'static str, Option<i32>>,
    #[serde(rename = "scoreAdjustments")]
    score_adjustments: BTreeMap<&'static str, ScoreAdjustment>,
    #[serde(rename = "effectiveWeights", skip_serializing_if = "Option::is_none")]
    effective_weights: Option<EffectiveWeights>,
    #[serde(rename = "filterResults")]
    filter_results: FilterResults,
    #[serde(rename = "compositeScore", skip_serializing_if = "Option::is_none")]
    composite_score: Option<f64>,
    #[serde(rename = "compositeScoreDisplay", skip_serializing_if = "Option::is_none")]
    composite_score_display: Option<f64>,
    #[serde(rename = "qualificationThreshold")]
    qualification_threshold: f64,
    qualified: bool,
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
        result: ScoringResult,
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

fn round_to(value: f64, decimals: i32) -> f64 {
    let factor = 10f64.powi(decimals);
    (value * factor).round() / factor
}

fn validate_score_range(name: &str, value: Option<i32>) -> Result<(), ToolOutput> {
    if let Some(v) = value {
        if !(0..=100).contains(&v) {
            return Err(err(
                "INVALID_SCORE",
                format!("{name} score {v} is outside the valid range 0..100"),
            ));
        }
    }
    Ok(())
}

/// The pure, testable core: given raw stdin text, decide the outcome.
fn process(raw_input: &str) -> ToolOutput {
    let trimmed = raw_input.trim();
    if trimmed.is_empty() {
        return err("INVALID_INPUT", "stdin was empty; scoring requires a JSON input object");
    }

    let input: ScoringInput = match serde_json::from_str(trimmed) {
        Ok(parsed) => parsed,
        Err(e) => return err("INVALID_INPUT", format!("stdin was not a valid scoring input: {e}")),
    };

    // --- Validate weights (CONTRACT.md sec.19) ---
    let weights = &input.weights;
    for (name, w) in [
        ("kpi1", weights.kpi1),
        ("kpi2", weights.kpi2),
        ("kpi3", weights.kpi3),
        ("kpi4", weights.kpi4),
        ("kpi5", weights.kpi5),
        ("kpi6", weights.kpi6),
    ] {
        if w < 0.0 {
            return err("INVALID_WEIGHTS", format!("weight {name} is negative ({w})"));
        }
    }
    let weight_sum = weights.sum();
    if (weight_sum - 100.0).abs() > WEIGHT_SUM_EPSILON {
        return err(
            "INVALID_WEIGHTS",
            format!("weights must sum to 100, got {weight_sum}"),
        );
    }

    // --- Validate threshold ---
    if !(0.0..=100.0).contains(&input.qualification_threshold) {
        return err(
            "INVALID_THRESHOLD",
            format!(
                "qualificationThreshold {} is outside 0..100",
                input.qualification_threshold
            ),
        );
    }

    // --- Validate every provided score is in range (CONTRACT.md sec.20.2) ---
    let scores = &input.scores;
    for (name, v) in [
        ("kpi1", scores.kpi1),
        ("kpi2", scores.kpi2),
        ("kpi3", scores.kpi3),
        ("kpi4", scores.kpi4),
        ("kpi5", scores.kpi5),
        ("kpi6", scores.kpi6),
    ] {
        if let Err(e) = validate_score_range(name, v) {
            return e;
        }
    }

    // --- COMPLETE vs INCOMPLETE (CONTRACT.md sec.20.1): only KPI 5 may be missing ---
    let mut missing_required: Vec<&str> = Vec::new();
    if scores.kpi1.is_none() {
        missing_required.push("kpi1");
    }
    if scores.kpi2.is_none() {
        missing_required.push("kpi2");
    }
    if scores.kpi3.is_none() {
        missing_required.push("kpi3");
    }
    if scores.kpi4.is_none() {
        missing_required.push("kpi4");
    }
    if scores.kpi6.is_none() {
        missing_required.push("kpi6");
    }

    let filter_results_incomplete = FilterResults {
        require_field: input.require_field,
        require_location: input.require_location,
        field_passed: None,
        location_passed: None,
        hard_filter_passed: None,
    };

    if !missing_required.is_empty() {
        return ToolOutput::Ok {
            ok: true,
            tool: TOOL_NAME,
            version: TOOL_VERSION,
            result: ScoringResult {
                status: "INCOMPLETE",
                reason: Some(format!(
                    "missing required KPI score(s): {}",
                    missing_required.join(", ")
                )),
                effective_scores: BTreeMap::from([
                    ("kpi1", scores.kpi1),
                    ("kpi2", scores.kpi2),
                    ("kpi3", scores.kpi3),
                    ("kpi4", scores.kpi4),
                    ("kpi5", scores.kpi5),
                    ("kpi6", scores.kpi6),
                ]),
                score_adjustments: BTreeMap::new(),
                effective_weights: None,
                filter_results: filter_results_incomplete,
                composite_score: None,
                composite_score_display: None,
                qualification_threshold: input.qualification_threshold,
                qualified: false,
            },
        };
    }

    // All of kpi1,2,3,4,6 are Some(_) beyond this point.
    let kpi1 = scores.kpi1.unwrap();
    let kpi2 = scores.kpi2.unwrap();
    let kpi3 = scores.kpi3.unwrap();
    let kpi4 = scores.kpi4.unwrap();
    let kpi6_raw = scores.kpi6.unwrap();

    // --- KPI 6 seniority-offset rule (doc/KPI-FRAMEWORK.md, CONTRACT.md sec.20.2) ---
    let mut score_adjustments: BTreeMap<&'static str, ScoreAdjustment> = BTreeMap::new();
    let kpi6_effective = if kpi3 >= SENIORITY_THRESHOLD && kpi6_raw < SENIORITY_KPI6_FLOOR {
        score_adjustments.insert(
            "kpi6",
            ScoreAdjustment {
                raw: kpi6_raw,
                effective: SENIORITY_KPI6_FLOOR,
                rule: "seniority_floor_kpi3_gte_80",
            },
        );
        SENIORITY_KPI6_FLOOR
    } else {
        kpi6_raw
    };
    // Defensive: the floor can never push the effective value past 100 (raw is already
    // <=100 and the floor constant is 50, so max(raw, 50) <= 100 always holds), but assert
    // the invariant explicitly rather than relying on that reasoning silently.
    debug_assert!(kpi6_effective <= 100);

    let effective_scores: BTreeMap<&'static str, Option<i32>> = BTreeMap::from([
        ("kpi1", Some(kpi1)),
        ("kpi2", Some(kpi2)),
        ("kpi3", Some(kpi3)),
        ("kpi4", Some(kpi4)),
        ("kpi5", scores.kpi5),
        ("kpi6", Some(kpi6_effective)),
    ]);

    // --- Hard filters (CONTRACT.md sec.21) ---
    let field_passed = !input.require_field || kpi1 != 0;
    let location_passed = !input.require_location || kpi2 != 0;
    let hard_filter_passed = field_passed && location_passed;

    let filter_results = FilterResults {
        require_field: input.require_field,
        require_location: input.require_location,
        field_passed: Some(field_passed),
        location_passed: Some(location_passed),
        hard_filter_passed: Some(hard_filter_passed),
    };

    // --- Missing-KPI-5 weight renormalization (CONTRACT.md sec.20) ---
    let (effective_weights, composite_raw) = if let Some(kpi5) = scores.kpi5 {
        let ew = EffectiveWeights {
            kpi1: weights.kpi1,
            kpi2: weights.kpi2,
            kpi3: weights.kpi3,
            kpi4: weights.kpi4,
            kpi5: Some(weights.kpi5),
            kpi6: weights.kpi6,
        };
        let composite = (ew.kpi1 * kpi1 as f64
            + ew.kpi2 * kpi2 as f64
            + ew.kpi3 * kpi3 as f64
            + ew.kpi4 * kpi4 as f64
            + ew.kpi5.unwrap() * kpi5 as f64
            + ew.kpi6 * kpi6_effective as f64)
            / 100.0;
        (ew, composite)
    } else {
        let present_sum = weights.kpi1 + weights.kpi2 + weights.kpi3 + weights.kpi4 + weights.kpi6;
        // present_sum is (100 - weights.kpi5), which is > 0 whenever weights.kpi5 < 100;
        // weights.kpi5 == 100 would mean every other weight is 0, which is a degenerate
        // but not invalid configuration -- guard against division by zero explicitly.
        if present_sum <= 0.0 {
            return err(
                "INVALID_WEIGHTS",
                "cannot renormalize: combined weight of kpi1,2,3,4,6 is zero",
            );
        }
        let scale = 100.0 / present_sum;
        let ew = EffectiveWeights {
            kpi1: weights.kpi1 * scale,
            kpi2: weights.kpi2 * scale,
            kpi3: weights.kpi3 * scale,
            kpi4: weights.kpi4 * scale,
            kpi5: None,
            kpi6: weights.kpi6 * scale,
        };
        let composite = (ew.kpi1 * kpi1 as f64
            + ew.kpi2 * kpi2 as f64
            + ew.kpi3 * kpi3 as f64
            + ew.kpi4 * kpi4 as f64
            + ew.kpi6 * kpi6_effective as f64)
            / 100.0;
        (ew, composite)
    };

    let composite_score = round_to(composite_raw, AUTHORITATIVE_PRECISION);
    let composite_score_display = round_to(composite_raw, DISPLAY_PRECISION);

    // Qualification MUST use the authoritative (fixed-precision, unrounded-for-display)
    // value, never the display-rounded one (CONTRACT.md sec.20.3).
    let qualified = hard_filter_passed && composite_score >= input.qualification_threshold;

    ToolOutput::Ok {
        ok: true,
        tool: TOOL_NAME,
        version: TOOL_VERSION,
        result: ScoringResult {
            status: "COMPLETE",
            reason: None,
            effective_scores,
            score_adjustments,
            effective_weights: Some(effective_weights),
            filter_results,
            composite_score: Some(composite_score),
            composite_score_display: Some(composite_score_display),
            qualification_threshold: input.qualification_threshold,
            qualified,
        },
    }
}

fn main() -> io::Result<()> {
    let mut raw_input = String::new();
    io::stdin().read_to_string(&mut raw_input)?;

    let output = process(&raw_input);
    let is_ok = matches!(output, ToolOutput::Ok { .. });

    let serialized = serde_json::to_string(&output).unwrap_or_else(|e| {
        eprintln!("scoring: failed to serialize output: {e}");
        std::process::exit(2);
    });

    println!("{serialized}");
    io::stdout().flush()?;

    std::process::exit(if is_ok { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_weights_json() -> &'static str {
        r#""weights": {"kpi1":25,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":10}"#
    }

    fn ok_result(output: ToolOutput) -> ScoringResult {
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

    /// CONTRACT.md sec.74: "default weighted score".
    #[test]
    fn default_weighted_score() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.status, "COMPLETE");
        let expected =
            (25.0 * 95.0 + 20.0 * 100.0 + 15.0 * 85.0 + 20.0 * 90.0 + 10.0 * 80.0 + 10.0 * 70.0)
                / 100.0;
        assert_eq!(result.composite_score, Some(round_to(expected, AUTHORITATIVE_PRECISION)));
        assert!(result.qualified);
    }

    /// CONTRACT.md sec.74: "custom weights".
    #[test]
    fn custom_weights() {
        let input = r#"{"weights": {"kpi1":50,"kpi2":10,"kpi3":10,"kpi4":10,"kpi5":10,"kpi6":10}, "scores": {"kpi1":100,"kpi2":0,"kpi3":0,"kpi4":0,"kpi5":0,"kpi6":0}, "requireField": false, "requireLocation": false, "qualificationThreshold": 40}"#;
        let result = ok_result(process(input));
        assert_eq!(result.composite_score, Some(50.0));
        assert!(result.qualified);
    }

    /// CONTRACT.md sec.74: "missing KPI 5 normalization".
    #[test]
    fn missing_kpi5_normalization() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":null,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.status, "COMPLETE");
        let ew = result.effective_weights.expect("effective weights present");
        assert!(ew.kpi5.is_none());
        // 25,20,15,20,10 (kpi6) sum to 90; scaled by 100/90.
        let scale = 100.0 / 90.0;
        assert!((ew.kpi1 - 25.0 * scale).abs() < 1e-9);
        assert!((ew.kpi2 - 20.0 * scale).abs() < 1e-9);
        assert!((ew.kpi3 - 15.0 * scale).abs() < 1e-9);
        assert!((ew.kpi4 - 20.0 * scale).abs() < 1e-9);
        assert!((ew.kpi6 - 10.0 * scale).abs() < 1e-9);
        let expected = (25.0 * scale * 95.0
            + 20.0 * scale * 100.0
            + 15.0 * scale * 85.0
            + 20.0 * scale * 90.0
            + 10.0 * scale * 70.0)
            / 100.0;
        assert_eq!(result.composite_score, Some(round_to(expected, AUTHORITATIVE_PRECISION)));
    }

    /// CONTRACT.md sec.74: "rejection/incomplete handling when KPI 1,2,3,4, or 6 is missing".
    #[test]
    fn missing_non_kpi5_kpi_is_incomplete_not_invented() {
        for missing in ["kpi1", "kpi2", "kpi3", "kpi4", "kpi6"] {
            let mut scores = serde_json::json!({
                "kpi1": 95, "kpi2": 100, "kpi3": 85, "kpi4": 90, "kpi5": 80, "kpi6": 70
            });
            scores[missing] = serde_json::Value::Null;
            let input = serde_json::json!({
                "weights": {"kpi1":25,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":10},
                "scores": scores,
                "requireField": true, "requireLocation": true, "qualificationThreshold": 60
            });
            let result = ok_result(process(&input.to_string()));
            assert_eq!(result.status, "INCOMPLETE", "missing {missing} should be INCOMPLETE");
            assert!(!result.qualified, "an INCOMPLETE evaluation must never be qualified");
            assert!(result.composite_score.is_none());
            assert!(result.reason.unwrap().contains(missing));
        }
    }

    /// CONTRACT.md sec.74: "KPI range validation and cap at 100".
    #[test]
    fn kpi_score_out_of_range_is_rejected() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":101,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}}"#,
            default_weights_json()
        );
        let error = err_output(process(&input));
        assert_eq!(error.code, "INVALID_SCORE");
    }

    #[test]
    fn kpi_score_at_boundary_100_is_valid() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":100,"kpi2":100,"kpi3":100,"kpi4":100,"kpi5":100,"kpi6":100}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.composite_score, Some(100.0));
    }

    #[test]
    fn negative_kpi_score_is_rejected() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":-1,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}}"#,
            default_weights_json()
        );
        let error = err_output(process(&input));
        assert_eq!(error.code, "INVALID_SCORE");
    }

    /// CONTRACT.md sec.74: "KPI 6 seniority offset when KPI 3 >= 80".
    #[test]
    fn kpi6_seniority_floor_applies_when_kpi3_at_least_80() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":80,"kpi4":90,"kpi5":80,"kpi6":10}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 0}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.effective_scores["kpi6"], Some(50));
        let adj = result.score_adjustments.get("kpi6").expect("adjustment recorded");
        assert_eq!(adj.raw, 10);
        assert_eq!(adj.effective, 50);
    }

    #[test]
    fn kpi6_seniority_floor_does_not_apply_below_threshold() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":79,"kpi4":90,"kpi5":80,"kpi6":10}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 0}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.effective_scores["kpi6"], Some(10));
        assert!(result.score_adjustments.get("kpi6").is_none());
    }

    #[test]
    fn kpi6_seniority_floor_never_lowers_an_already_higher_score() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":100,"kpi4":90,"kpi5":80,"kpi6":95}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 0}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.effective_scores["kpi6"], Some(95));
        assert!(result.score_adjustments.get("kpi6").is_none());
    }

    /// CONTRACT.md sec.74/20.3: "authoritative score precision around qualification threshold" --
    /// display rounding (59.996 -> 60.00) must never flip a qualification decision.
    #[test]
    fn display_rounding_never_flips_qualification() {
        // weight kpi1=59.996, all remaining weight on kpi2 (=40.004) scored 0, so the
        // composite is exactly 59.996 -- which rounds to 60.00 for 2-decimal display.
        let input = r#"{"weights": {"kpi1":59.996,"kpi2":40.004,"kpi3":0,"kpi4":0,"kpi5":0,"kpi6":0}, "scores": {"kpi1":100,"kpi2":0,"kpi3":50,"kpi4":50,"kpi5":50,"kpi6":50}, "requireField": false, "requireLocation": false, "qualificationThreshold": 60}"#;
        let result = ok_result(process(input));
        assert_eq!(result.composite_score, Some(59.996));
        assert_eq!(result.composite_score_display, Some(60.0));
        assert!(
            !result.qualified,
            "authoritative 59.996 < threshold 60 must not qualify, even though display rounds to 60.00"
        );
    }

    /// CONTRACT.md sec.74: "qualification requiring hard filters plus threshold".
    #[test]
    fn qualification_requires_both_hard_filters_and_threshold() {
        // High composite score but a failing hard filter must not qualify.
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":0,"kpi2":100,"kpi3":100,"kpi4":100,"kpi5":100,"kpi6":100}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 10}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert!(result.composite_score.unwrap() > 10.0);
        assert!(!result.qualified, "field hard filter must block qualification regardless of score");
    }

    /// CONTRACT.md sec.74: "hard field filter".
    #[test]
    fn hard_field_filter_fails_on_kpi1_zero() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":0,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": false, "qualificationThreshold": 0}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.filter_results.field_passed, Some(false));
        assert_eq!(result.filter_results.hard_filter_passed, Some(false));
        assert!(!result.qualified);
    }

    #[test]
    fn field_filter_disabled_allows_kpi1_zero() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":0,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": false, "requireLocation": false, "qualificationThreshold": 0}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.filter_results.field_passed, Some(true));
    }

    /// CONTRACT.md sec.74: "hard location filter".
    #[test]
    fn hard_location_filter_fails_on_kpi2_zero() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":0,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": false, "requireLocation": true, "qualificationThreshold": 0}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.filter_results.location_passed, Some(false));
        assert_eq!(result.filter_results.hard_filter_passed, Some(false));
        assert!(!result.qualified);
    }

    /// CONTRACT.md sec.74: "custom qualification threshold".
    #[test]
    fn custom_qualification_threshold_changes_outcome_for_same_score() {
        let make_input = |threshold: f64| {
            format!(
                r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": {threshold}}}"#,
                default_weights_json()
            )
        };
        let low_threshold = ok_result(process(&make_input(50.0)));
        let high_threshold = ok_result(process(&make_input(99.0)));
        assert_eq!(low_threshold.composite_score, high_threshold.composite_score);
        assert!(low_threshold.qualified);
        assert!(!high_threshold.qualified);
    }

    /// CONTRACT.md sec.74: "malformed input".
    #[test]
    fn malformed_json_is_rejected() {
        let error = err_output(process("{not valid json"));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn empty_stdin_is_rejected() {
        let error = err_output(process(""));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn weights_not_summing_to_100_is_rejected() {
        let input = r#"{"weights": {"kpi1":25,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":5}, "scores": {"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_WEIGHTS");
    }

    #[test]
    fn negative_weight_is_rejected() {
        let input = r#"{"weights": {"kpi1":-5,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":40}, "scores": {"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_WEIGHTS");
    }

    #[test]
    fn threshold_out_of_range_is_rejected() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 150}}"#,
            default_weights_json()
        );
        let error = err_output(process(&input));
        assert_eq!(error.code, "INVALID_THRESHOLD");
    }

    /// Independent review finding: unrecognized fields must be rejected, not silently
    /// ignored, since this tool is meant to be a strict validation boundary.
    #[test]
    fn unknown_top_level_field_is_rejected() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60, "unexpectedField": 1}}"#,
            default_weights_json()
        );
        let error = err_output(process(&input));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    #[test]
    fn unknown_field_in_weights_is_rejected() {
        let input = r#"{"weights": {"kpi1":25,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":10,"kpi7":0}, "scores": {"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}, "requireField": true, "requireLocation": true, "qualificationThreshold": 60}"#;
        let error = err_output(process(input));
        assert_eq!(error.code, "INVALID_INPUT");
    }

    /// Independent review coverage gap: exact equality at the threshold must qualify
    /// (CONTRACT.md sec.20.3 uses ">=", not ">").
    #[test]
    fn composite_exactly_equal_to_threshold_qualifies() {
        let input = format!(
            r#"{{{}, "scores": {{"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70}}, "requireField": true, "requireLocation": true, "qualificationThreshold": 89.5}}"#,
            default_weights_json()
        );
        let result = ok_result(process(&input));
        assert_eq!(result.composite_score, Some(89.5));
        assert!(result.qualified, "composite exactly equal to the threshold must qualify");
    }

    #[test]
    fn output_always_carries_tool_name_and_version() {
        for output in [process(""), process("{not valid json")] {
            let value = serde_json::to_value(&output).unwrap();
            assert_eq!(value["tool"], "scoring");
            assert_eq!(value["version"], "0.1.0");
        }
    }
}
