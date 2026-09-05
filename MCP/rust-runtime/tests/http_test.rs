//! Integration tests for the HTTP transport layer. These exercise the exact router served in
//! production (`rust_runtime::build_router`) in-process via `tower::ServiceExt::oneshot` --
//! no real socket is bound, but every layer between an HTTP request and the underlying
//! `clitools/` engine's `process` function is genuinely exercised, including JSON body
//! extraction and the ok/err -> status-code mapping in `response::tool_response`.
//!
//! These tests intentionally do NOT re-assert the engines' own business rules (e.g. every
//! KPI-scoring edge case) -- that coverage already exists in `clitools/scoring`'s own tests
//! and must not be duplicated here (CONTRACT.md sec.7). They only prove the transport layer
//! correctly carries a request to the engine and the engine's answer back out.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

async fn body_json(response: axum::response::Response) -> serde_json::Value {
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).expect("response body was not valid JSON")
}

#[tokio::test]
async fn get_health_returns_200_and_a_real_health_tool_invocation() {
    let app = rust_runtime::build_router();
    let request = Request::builder().uri("/health").body(Body::empty()).unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let json = body_json(response).await;
    assert_eq!(json["ok"], true);
    assert_eq!(json["tool"], "health");
    assert_eq!(json["result"]["status"], "ok");
}

#[tokio::test]
async fn post_tools_scoring_with_valid_body_returns_200_and_a_composite_score() {
    let app = rust_runtime::build_router();
    let payload = serde_json::json!({
        "weights": {"kpi1":25,"kpi2":20,"kpi3":15,"kpi4":20,"kpi5":10,"kpi6":10},
        "scores": {"kpi1":95,"kpi2":100,"kpi3":85,"kpi4":90,"kpi5":80,"kpi6":70},
        "requireField": true, "requireLocation": true, "qualificationThreshold": 60
    });
    let request = Request::builder()
        .method("POST")
        .uri("/tools/scoring")
        .header("content-type", "application/json")
        .body(Body::from(payload.to_string()))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let json = body_json(response).await;
    assert_eq!(json["ok"], true);
    assert_eq!(json["tool"], "scoring");
    assert_eq!(json["result"]["status"], "COMPLETE");
    assert!(json["result"]["qualified"].as_bool().unwrap());
}

#[tokio::test]
async fn post_tools_scoring_with_malformed_body_returns_400_not_500() {
    let app = rust_runtime::build_router();
    let request = Request::builder()
        .method("POST")
        .uri("/tools/scoring")
        .header("content-type", "application/json")
        .body(Body::from("{not valid json"))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let json = body_json(response).await;
    assert_eq!(json["ok"], false);
    assert_eq!(json["error"]["code"], "INVALID_INPUT");
}

#[tokio::test]
async fn post_tools_campaign_policy_with_valid_body_returns_200() {
    let app = rust_runtime::build_router();
    let payload = serde_json::json!({
        "budgetPolicy": {
            "max_unique_candidates": 1000,
            "max_search_cost_usd": 10.0,
            "max_total_campaign_cost_usd": 20.0,
            "target_qualified_profiles": 100
        },
        "currentState": {
            "unique_candidate_count": 50,
            "qualified_count": 5,
            "search_committed_cost_usd": 1.0,
            "total_committed_cost_usd": 1.0,
            "provider_exhausted": false,
            "manual_stop_requested": false
        },
        "requestedBatchSize": 25
    });
    let request = Request::builder()
        .method("POST")
        .uri("/tools/campaign-policy")
        .header("content-type", "application/json")
        .body(Body::from(payload.to_string()))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let json = body_json(response).await;
    assert_eq!(json["ok"], true);
    assert_eq!(json["tool"], "campaign_policy");
    assert_eq!(json["result"]["canContinueSearch"], true);
    assert_eq!(json["result"]["adjustedBatchSize"], 25);
}

#[tokio::test]
async fn post_tools_campaign_policy_stop_reason_passes_through_unmodified() {
    let app = rust_runtime::build_router();
    let payload = serde_json::json!({
        "budgetPolicy": {},
        "currentState": {
            "unique_candidate_count": 0,
            "qualified_count": 0,
            "search_committed_cost_usd": 0,
            "total_committed_cost_usd": 0,
            "provider_exhausted": false,
            "manual_stop_requested": true
        },
        "requestedBatchSize": 25
    });
    let request = Request::builder()
        .method("POST")
        .uri("/tools/campaign-policy")
        .body(Body::from(payload.to_string()))
        .unwrap();
    let response = app.oneshot(request).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let json = body_json(response).await;
    assert_eq!(json["result"]["stopReason"], "STOP_MANUAL");
}

#[tokio::test]
async fn unknown_route_returns_404() {
    let app = rust_runtime::build_router();
    let request = Request::builder().uri("/does-not-exist").body(Body::empty()).unwrap();
    let response = app.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}
