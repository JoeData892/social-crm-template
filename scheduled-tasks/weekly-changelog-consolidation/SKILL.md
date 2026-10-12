---
name: weekly-changelog-consolidation
description: Consolidate a configured Social CRM's past-week Changelog originals into a summary and delete those originals after verifying the summary. Use when the user requests this cleanup or an already authorized scheduled task invokes it.
---

Requires configured Airtable access and authorization to consolidate and delete source
Changelog records. Keep schema dependencies in the user's private automation inventory.
This skill does not create a schedule or configure notification recipients.

Consolidate the past week's Airtable Changelog records into one summary record, then delete originals to conserve free-tier space.

Use the configured Airtable connector. Inspect active tool definitions for pagination
and parameter shapes; do not fall back to Chrome or inline API credentials. Fetch all
pages before client-side filtering or aggregation.

**Airtable context:**
- Base ID: `<YOUR_BASE_ID>`
- Changelog table ID: `<TBL_CHANGELOG_ID>`
- Field IDs: Summary `<FIELD_ID>`, Date `<FIELD_ID>`, Changes Made `<FIELD_ID>`, Tables Affected `<FIELD_ID>`, Records Added `<FIELD_ID>`, Records Updated `<FIELD_ID>`
- Airtable MCP tools are named `mcp__<airtable-mcp-server-id>__*`. If not in your active tool list, load via ToolSearch, e.g. `ToolSearch { query: "select:mcp__<airtable-mcp-server-id>__list_records_for_table,mcp__<airtable-mcp-server-id>__create_records_for_table,mcp__<airtable-mcp-server-id>__delete_records_for_table", max_results: 3 }`.

**Exclude existing summaries.** Skip records tagged `[consolidated]` or `[monthly]`,
including summaries dated within the past week. This task only consolidates originals.
It does not assume a separate monthly rollup task exists.

**Steps:**

1. **Fetch the last 7 days of Changelog records.** Call `list_records_for_table` with baseId `<YOUR_BASE_ID>`, tableId `<TBL_CHANGELOG_ID>`, filtering on the Date field (`<FIELD_ID>`) for records on or after (today − 7 days). If the structured filter is unreliable for date comparison, fetch all records using the connector's supported page size and pagination, then filter client-side.

2. **Exclude summary records.** Drop any record matching either condition:
   - its Summary (`<FIELD_ID>`) starts with `Weekly consolidation` or `Monthly consolidation` (case-insensitive), OR
   - its Changes Made (`<FIELD_ID>`) contains the marker `[consolidated]` or `[monthly]`.
   The remaining records are the "originals" to consolidate. Never consolidate or delete a summary record in this task.

3. **Skip guard.** If fewer than 2 originals remain after exclusion, report that consolidation was skipped (include the count of originals found and the count of summary records skipped) and exit. Use Telegram only when the user has authorized the configured channel; otherwise return the report in the current session. Do NOT create a consolidated record from a single original or from zero originals.

4. **Build the consolidated record.** Sort the originals by Date ascending and compute:
   - Summary: `Weekly consolidation — <earliest date> to <latest date>`
   - Changes Made: first line must be exactly `[consolidated]` (this is the skip marker for future runs), followed by one bullet per original record in the form `• <Date>: <Changes Made or Summary or "(no detail)">`, joined with newlines. If an original's Changes Made already contains `[consolidated]` or `[monthly]`, it should never have reached this step — re-check step 2.
   - Tables Affected: union of all originals' Tables Affected values
   - Records Added: sum across originals
   - Records Updated: sum across originals

5. **Create and verify the consolidated record** via `create_records_for_table`
   (same base/table). Read it back to confirm the marker, detail and totals before
   deleting originals. If creation or verification fails, delete nothing and report
   the error. Keep the original IDs for the deletion step.

6. **Delete the originals** via `delete_records_for_table`, passing ONLY the IDs of the original records consolidated in step 4. NEVER pass the new consolidated record's ID, and NEVER pass the IDs of the summary records excluded in step 2. Only delete after the create is confirmed.

7. **Report.** Include originals consolidated, date range, confirmed deletions, and
   summary records skipped. Send through `mcp__Telegram_Notifier__send_message` only if
   the user configured and authorized that channel. Otherwise return the report in the
   session. Do not fall back to raw HTTP or claim failed deletions freed record space.

**Error handling:** If any Airtable MCP call fails, report what failed and at which step, then exit. Use Telegram only when the user has authorized the configured channel; otherwise return the report in the current session. Do NOT fall back to Chrome or direct API calls — the MCP connector is the only Airtable path for this task.
