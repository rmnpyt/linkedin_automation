# ConnectionSender — PowerShell Invocation Contract

**Status:** interface definition, pending the real script (ACCESS_PENDING).

MINDSET.md documents that LinkedIn connection-request sending is already a working
PowerShell script on the operator's machine ("Concrete example already working:
connection-request sending is a PowerShell script today"). That script is **not present in
this repository** — `powershell/linkedin/` had no content before this phase. This document
defines the interface any such script (the existing one, adapted, or a new one) MUST
implement so it can be wrapped behind the `ConnectionSender` boundary (PROPOSAL.md sec.19,
CONTRACT.md sec.43,45-48) and validated by `clitools/connection_sender_normalize`.

This is intentionally an interface-only deliverable for this phase (AGENT-START.md sec.17:
"The Agent may fully implement and test: ... sender adapter contract; PowerShell invocation
contract; dry-run behavior" — without requiring the real script). Supplying or pointing to
the actual script is a human/access step; see the final phase report for its status.

## Invocation

The orchestrating workflow (n8n, later) invokes the script per connection-attempt with the
information needed to perform one send:

```text
pwsh -File Send-ConnectionRequest.ps1 -ProfileUrl <canonical LinkedIn profile URL> -NoteText <note body> -DryRun:<$true|$false>
```

- `-DryRun $true` MUST perform every step except the final LinkedIn-mutating action (opening
  the profile, verifying the page, composing the note) and MUST still emit a valid result
  per the output contract below — this is what makes automated testing of the surrounding
  system possible without a real send (AGENT-START.md sec.17).
- The script MUST NOT attempt to bypass account challenges, CAPTCHAs, rate limits, or other
  platform restrictions (AGENT-START.md sec.17, CONTRACT.md sec.48). If a challenge is
  encountered, it MUST stop and report `status: "unknown"` (or `"failed"` if clearly
  blocked) rather than attempt to work around it.
- The script MUST NOT log the note text, session cookies, or any credential material to a
  location outside this one invocation's own stdout contract (CONTRACT.md sec.67).

## Output contract

The script MUST write exactly one line of JSON to stdout on completion, in this shape:

```json
{
  "status": "sent",
  "error_code": null,
  "error_message": null,
  "raw": { "anything": "useful for debugging, opaque to the caller" }
}
```

- `status` (required, string): exactly one of `"sent"`, `"failed"`, `"already_connected"`,
  or `"unknown"` (case-insensitive; leading/trailing whitespace is tolerated). Any other
  value is treated as a hard integration error by `clitools/connection_sender_normalize`,
  not a legitimate outcome — the script must be fixed to conform, not worked around.
  - `"sent"`: the request was successfully submitted.
  - `"failed"`: the request definitely did not go through (e.g. a clear error page,
    invalid profile URL, account restriction with a clear message).
  - `"already_connected"`: LinkedIn indicated the two accounts are already connected.
  - `"unknown"`: the outcome could not be determined (timeout, browser crash mid-action,
    ambiguous page state, a challenge/CAPTCHA was encountered and the script stopped
    rather than attempting to solve it). **This is the required, safe default whenever the
    script cannot positively confirm one of the other three outcomes** — CONTRACT.md
    sec.47 requires the system to never guess success from ambiguity.
- `error_code` (optional, string or null): a short machine-readable code for `failed`/
  `unknown` outcomes.
- `error_message` (optional, string or null): a human-readable explanation.
- `raw` (optional, any JSON): anything else the script wants to preserve for debugging.
  Never include credentials, session tokens, or the recipient's full profile payload here.

The script's **exit code** SHOULD be `0` whenever it successfully produced a valid result
object (including `"failed"`/`"unknown"` results — those are valid, expected outcomes, not
script crashes) and non-zero only when the script itself crashed before producing any
result. `clitools/connection_sender_normalize` validates the JSON on stdout regardless of
exit code; the caller (n8n) should treat a non-zero exit with no valid JSON on stdout as an
`UNKNOWN_SIDE_EFFECT`-class failure per CONTRACT.md sec.64, requiring reconciliation rather
than an automatic retry, exactly like an `"unknown"` status would.

## Downstream normalization

Once the script's stdout is captured, the caller pipes it into
`clitools/connection_sender_normalize`, which validates the shape above and returns:

```json
{"ok": true, "tool": "connection_sender_normalize", "version": "0.1.0",
 "result": {"result": "SENT", "error_code": null, "error_message": null}}
```

The caller then calls `record_connection_attempt_result` (or, for a result later resolved
from `UNKNOWN`, `reconcile_connection_attempt`) with `result.result` and the error fields —
see `supabase/migrations/20260905130001_connection_send_lifecycle.sql`.

If `connection_sender_normalize` itself returns `{"ok": false, "error": {"code":
"UNRECOGNIZED_STATUS", ...}}`, the caller MUST treat this identically to a script crash
(non-zero exit with no valid JSON on stdout) — i.e. call `record_connection_attempt_result`
with `'UNKNOWN'`, never leave the attempt sitting in `SEND_ATTEMPTED` indefinitely. A
non-conformant status string is not a legitimate outcome and must not be swallowed or
retried automatically; it still requires the same reconciliation path as any other
ambiguous result (CONTRACT.md sec.47).

## What remains pending

- The actual script implementing this contract. Until it exists (or the human operator
  points this project at the existing working script so it can be adapted), Phase 1.5's
  database layer and normalizer are fully implemented and tested against mock/dry-run
  inputs, but no real LinkedIn send has been exercised — status: **LIVE VALIDATION
  PENDING**, consistent with CONTRACT.md sec.81's live-connection-validation gate.
