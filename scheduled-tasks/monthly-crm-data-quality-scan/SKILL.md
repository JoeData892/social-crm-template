---
name: monthly-crm-data-quality-scan
description: Correct misplaced fields in a configured Social CRM and archive interactions older than six months into People.History before deleting them. Use when the user requests this data-quality scan or an already authorized task invokes it.
---

Requires configured Airtable access, the Social CRM field conventions, and authorization
for archiving and deleting old Interactions. Keep schema dependencies in the user's
private automation inventory. This skill does not establish a recurring schedule.

Run the CRM data-quality scan against the user's Social CRM. Read the installed
social-crm skill for field semantics; in this repository it is [SKILL.md](../../SKILL.md).

Use the configured Airtable connector. Inspect active tool definitions for pagination
and parameter shapes; do not fall back to Chrome or inline API credentials. Fetch all
pages before client-side filtering, grouping or aggregation.

**Airtable context:**
- Base ID: `<YOUR_BASE_ID>`
- People table ID: `<TBL_PEOPLE_ID>` — key fields: Name `<FIELD_ID>`, Notes `<FIELD_ID>`, Location `<FIELD_ID>`, Birthday `<FIELD_ID>`, Job/Employer `<FIELD_ID>`, How We Met `<FIELD_ID>`, Known Since `<FIELD_ID>`, Family and Pets `<FIELD_ID>`, Groups `<FIELD_ID>`, History `<FIELD_ID>`
- Interactions table ID: `<TBL_INTERACTIONS_ID>` — fields: Summary `<FIELD_ID>`, Date `<FIELD_ID>`, Type `<FIELD_ID>`, Notes `<FIELD_ID>`, Person `<FIELD_ID>`, Follow-up Hooks `<FIELD_ID>`
- Groups table ID: `<TBL_GROUPS_ID>`
- Airtable MCP tools are named `mcp__<airtable-mcp-server-id>__*` (list_records_for_table, update_records_for_table, delete_records_for_table, get_table_schema). Load via ToolSearch if missing. If field IDs above seem stale, re-fetch with `get_table_schema` before patching.

**Part 1 — Data quality scan:**

1. Fetch ALL People records via `list_records_for_table`, using the connector's supported page size and pagination cursor until done.
2. For each record:
   - Scan Notes for content that belongs in a structured field: Location, Birthday, Job/Employer, How We Met, Known Since, Family and Pets
   - Scan any text fields for club/group names that should be linked records in Groups
   - Use `update_records_for_table` to move misplaced data to the correct field and clear it from Notes (batch updates, up to 10 records per call)
   - If a target field is already non-empty, skip and add to the flags list — never overwrite
3. Track for the report: # records scanned, # records patched, what was moved, and any flags needing manual review

**Part 2 — History field consolidation (Interactions older than 6 months):**

The People table has a **History** field (multilineText) serving as a running archive of older interaction history.

4. Fetch ALL Interaction records via `list_records_for_table` on `<TBL_INTERACTIONS_ID>`, including Follow-up Hooks; select those with Date more than 6 months ago. Exclude any interaction with a non-blank hook line that does not start with `(resolved`: keep it in Interactions so existing recaps, nudges and hook-resolution workflows can still find it. Report these retained records separately.
5. Group those interactions by their linked Person record.
6. For each Person with old interactions:
   - Build a summary line per interaction: `[YYYY-MM-DD] <Type>: <Summary or Notes snippet>`
   - Preserve each interaction's details and Follow-up Hooks alongside its dated summary
     so deleting the source record does not silently discard unresolved topics.
   - Append those lines to the Person's History field (preserve existing content — always append, never overwrite)
   - PATCH the People record via `update_records_for_table` with the updated History value
7. Read History back and confirm the archived content is present, then delete only
   that person's archived Interaction IDs. If any source has multiple linked people,
   verify the archive for every linked person before deleting it. Flag records with no
   linked person instead of deleting them. Report partial failures; do not repeat the
   append blindly after a failed deletion.

**Report:**

8. Report records scanned and patched, moved content, review flags, interactions
   archived and deleted, and failures. Send via `mcp__Telegram_Notifier__send_message`
   only if the user configured and authorized it; otherwise return the report in the
   session. Do not fall back to raw HTTP.

**Error handling:** If any Airtable MCP call fails, report what failed and at which step, then exit gracefully. Send that report through Telegram only when the user has authorized the configured channel; otherwise return it in the current session. Do NOT fall back to Chrome or direct API calls — the MCP connector is the only Airtable path for this task. Never delete an Interaction whose History append was not confirmed.
