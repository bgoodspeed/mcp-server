# Session Handling Macro via MCP Server — Post Mortem

## Context

Attempted to programmatically create a 5-step session handling macro (full auth flow with MFA) using the Burp Suite MCP server's `set_session_handling_config` tool, to auto-recover expired sessions during testing.

## Challenges Encountered

### 1. New MCP tools not visible until server reconnect

**Problem:** After adding `get_session_handling_config` / `set_session_handling_config` to the MCP server, the tools were not discoverable via ToolSearch.

**Root cause:** Claude Code caches tool schemas at session start and doesn't re-poll the MCP server for new tools.

**Fix:** Run `/mcp` in Claude Code and reconnect to the server. Restarting the session also works.

---

### 2. Config editing disabled by default

**Problem:** First call to `set_session_handling_config` returned: *"User has disabled configuration editing."*

**Root cause:** The MCP server ships with config-editing tools disabled for safety.

**Fix:** In Burp: MCP tab → check "Enable tools that can edit your config".

---

### 3. Burp silently drops invalid JSON fields — no error feedback

**Problem:** `set_session_handling_config` returned "Session handling configuration has been applied" (success), but subsequent `get_session_handling_config` showed macros as `[]` and rule actions as `[]`. No validation error was surfaced.

**Root cause:** Burp's `importProjectOptionsFromJson()` API silently ignores any JSON subtree it can't deserialize. It doesn't throw or return errors — it just drops what it doesn't recognise and merges the rest.

**Impact:** This made debugging extremely slow. Every attempt appeared to succeed, requiring a round-trip export to verify what actually persisted.

**Lesson:** Always call `get_session_handling_config` immediately after `set_session_handling_config` to verify the import. Never trust the success message.

---

### 4. Macro item schema is undocumented and strict

**Problem:** The internal JSON schema for macro items (especially `custom_parameters` and `request_parameters`) is not part of the Montoya API and is not publicly documented.

**What we had to do:** Manually record a macro via the GUI, then export it to reverse-engineer the schema.

**Schema discovered for `custom_parameters` (extraction):**
```json
{
  "end_at_delimiter": "\r\n",
  "end_at_fixed_length": 36,
  "end_mode": "at_delimiter",
  "exclude_http_headers": false,
  "extract_mode": "define_start_and_end",
  "name": "TransactionId",
  "start_af_offset": 0,
  "start_after_expression": "?TransactionId=",
  "start_at_mode": "after_expression",
  "url_encoded": false
}
```

**Schema for `request_parameters` (consumption/derivation):**
```json
{
  "name": "TransactionId",
  "original_value": "9574400c-7fa0-47c1-92ac-32dcc258290c",
  "parameter_handling": "derive_from_prior_response",
  "preset_value": "9574400c-7fa0-47c1-92ac-32dcc258290c",
  "prior_response_index": 1,
  "type": "url"
}
```
- `name`: parameter name in the URL query string
- `original_value`: the literal value recorded when the macro was created (placeholder is fine)
- `parameter_handling`: `"derive_from_prior_response"` tells Burp to substitute at runtime
- `preset_value`: fallback if derivation fails
- `prior_response_index`: 0-based index of the macro item whose `custom_parameters` extraction to use
- `type`: `"url"` for query string parameters

This schema was successfully imported programmatically after initial failures with guessed field names (`parameter_type`, `derive_from`, `value`, `source_item_index`).

**Lesson:** Any field with the wrong name, type, or structure causes Burp to reject the *entire containing object* (the whole macro), not just the offending field.

---

### 5. Session handling rule action schema also undocumented

**Problem:** Rule actions like `check_session_validity` and `run_macro` were rejected when attempted with guessed field names.

**What worked:** Rule metadata (description, scope, tools_scope, include_in_scope) imported fine. Only the `actions` array contents were rejected initially.

**Correct schema for `run_macro` action:**
```json
{
  "enabled": true,
  "invoke_extension_action": false,
  "macro_serial_number": 2884675357478201345,
  "match_cookies": "all_except",
  "match_params": "all_except",
  "tolerate_url_mismatch": false,
  "type": "run_macro",
  "update_with_cookies": true,
  "update_with_params": true
}
```

**What we guessed wrong:**
- `update_current_request` → should be `update_with_cookies` + `update_with_params` (separate booleans)
- `update_with: "cookies_only"` → not a real field
- Missing required fields: `invoke_extension_action`, `match_cookies`, `match_params`

**Workaround used:** Imported rule shell with `actions: []`, configured the action in GUI, then exported to discover the real schema.

---

### 6. The `response` field can be empty string

**Discovery:** The original manual export included the full response body in the `response` field. However, setting `"response": ""` also works — Burp re-records the response at macro runtime. This is useful since including huge response bodies in JSON is unwieldy.

---

## What Worked

| Component | Programmatic | Manual Required |
|-----------|:---:|:---:|
| Macro shell (description, serial_number) | Yes | No |
| Macro items with basic fields | Yes | No |
| `custom_parameters` (extraction) | Yes | No |
| `request_parameters` (derivation) | Yes | No |
| Rule metadata (scope, tools) | Yes | No |
| Rule actions (run_macro, check_session) | Yes (once schema known) | No |
| Cookie jar config | Yes | No |

---

## Recommended Workflow

Given these limitations, the optimal approach for complex macros:

1. **Use MCP to create the macro items** with `request_parameters: []` and correct `custom_parameters` extraction.
2. **Use MCP to create the rule shell** with correct scope and `actions: []`.
3. **Manually configure** in the GUI:
   - Parameter derivation (steps that consume values from prior steps)
   - Rule actions (check session validity → run macro)
4. **Export and save** the final working config for re-import on future sessions.

---

## Recommendations for MCP Server Improvement

1. **Validation feedback:** `set_session_handling_config` should diff what was submitted vs what Burp actually accepted and report any dropped fields/objects.
2. **Schema documentation:** Export a JSON Schema for macro items and rule actions, even if it's auto-generated from Burp's internal serialization classes.
3. **Typed convenience tools:** e.g. `create_macro_item`, `add_rule_action` that build the correct JSON from structured parameters, rather than requiring callers to guess the raw format.
4. **Dry-run mode:** Accept the config, validate it, report errors, but don't apply.

---

## Date
2026-07-28
