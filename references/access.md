# Airtable access

Use this reference for connector parameter shapes or the authorized local REST fallback.

### How to make API calls

**Preferred: a configured Airtable connector** (tools named `<airtable-mcp>__*` in the
reference setup). Inspect the active tool definitions; exact names, parameter shapes,
pagination tokens, and access permissions depend on the installed connector. Fetch all
pages before client-side matching, filtering, ranking or aggregation.

For unattended runs, verify that Airtable and any configured notification channel are
available in the execution environment. Hosted runs may lack local MCP servers and
browser tools. Do not promise portability without checking the actual tool surface.

If the MCP tools aren't in your active tool list, load them in bulk:
```
ToolSearch { query: "<your-airtable-mcp-server-id>", max_results: 30 }
```
Use the runtime's tool-discovery mechanism when tools are deferred; the query above is
for runtimes that provide `ToolSearch`.

**Key MCP tools and their gotchas:**

- `list_bases` → confirm the CRM base ID is `<YOUR_BASE_ID>`.
- `list_tables_for_base` → get table IDs and field IDs. Call this once at task start instead of the old metadata HTTP call.
- `get_table_schema` → required input is `tables: [{tableId, fieldIds: [...]}]` (array of objects with explicit field IDs). Use this when you need singleSelect choice IDs.
- `list_records_for_table` → **does NOT support `filterByFormula`.** Use the structured `filters` parameter:
  - Shape: `{operator: "and"|"or", operands: [...]}` at the top level. **Operands are flat — you cannot nest another `or` inside `operands`**, only individual conditions. If you need a multi-clause OR (e.g., a multi-value "Location contains X OR Y OR ..."), filter server-side on what you can and finish the filter client-side after the fetch.
  - Each condition: `{operator: "contains" | "=" | "isAnyOf" | "isEmpty" | ..., operands: [fieldId, value]}`.
  - For singleSelect/multipleSelects, pass **choice IDs not names** — get them from `get_table_schema` first.
  - `sort` is `[{fieldId, direction}]` (not `field`).
  - Use field IDs (`<FIELD_ID>`), not field names, for reliability.
- `search_records` → free-text fuzzy search across fields. Good for "find person X by partial name" but does NOT cover date / rating / checkbox / button fields.
- `create_records_for_table`, `update_records_for_table`, `delete_records_for_table` → for writes. Pass singleSelect values as plain string names on write (not as objects), even though they come back as objects on read.

**Pattern — typical lookup:**
```
1. (once per session) list_tables_for_base → cache table/field IDs
2. (if needed) get_table_schema → cache singleSelect choice IDs
3. list_records_for_table with structured filters → fetch records
4. Filter / sort client-side for anything the structured filter can't express
```

**Fallback: configured Airtable REST access through a local browser/client** — use
only when the connector fails, local tools are available, and the user authorized this
credential path. An empty lookup alone is not proof of connector failure; use the
lookup procedure in [../SKILL.md](../SKILL.md) first. Unattended connector-only tasks stop on connector errors.
1. Call `tabs_context_mcp(createIfEmpty: true)` then navigate to `https://airtable.com` — exactly once per task.
2. Reuse the task's tab and minimize browser calls.
3. If Chrome is unavailable, use available local access without restarting it or
   closing existing tabs. If approval is required in an unattended run, report and stop.

```js
// Chrome fallback pattern
(async () => {
  const TOKEN = '<YOUR_AIRTABLE_TOKEN>';
  const BASE = '<YOUR_BASE_ID>';
  const H = { 'Authorization': `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };
  const api = (path, opts = {}) => fetch(`https://api.airtable.com/v0/${path}`, { headers: H, ...opts }).then(r => r.json());
  // ...
})()
```

For Metadata API (schema changes via Chrome fallback): `https://api.airtable.com/v0/meta/bases/{baseId}/...`
For Data API (records via Chrome fallback): `https://api.airtable.com/v0/{baseId}/{tableIdOrName}/...`

