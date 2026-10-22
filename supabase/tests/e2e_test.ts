// End-to-end tests for the ingest and ask Edge Functions. Run via run.sh, which
// provides Postgres + PostgREST. This file stands up one local server that
// (a) plays the Claude API from a script and (b) proxies /rest/v1 to PostgREST
// the way the Supabase gateway does, then runs each function as a subprocess.

import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const REST_URL = Deno.env.get("REST_URL")!;
const JWT_SECRET = Deno.env.get("JWT_SECRET")!;
const STUB_PORT = 54340;
const FN_PORT = 8000;
const SECRET = "test-shared-secret-0123456789abcdef0123456789";
const STUB = `http://127.0.0.1:${STUB_PORT}`;

function b64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return btoa(String.fromCharCode(...bytes)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function serviceJwt(): Promise<string> {
  const head = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64url(JSON.stringify({ role: "service_role", iat: 1700000000, exp: 4100000000 }));
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(JWT_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${head}.${body}`)));
  return `${head}.${body}.${b64url(sig)}`;
}

const SERVICE_KEY = await serviceJwt();
const sb = createClient(STUB, SERVICE_KEY, { auth: { persistSession: false } });

// ---- scripted Claude ------------------------------------------------------

// deno-lint-ignore no-explicit-any
type Req = { headers: Headers; body: any };
type Step = (req: Req) => unknown;
let script: Step[] = [];
const seen: Req[] = [];
let delayMs = 0;

function toolUse(name: string, input: unknown) {
  return {
    id: `msg_${crypto.randomUUID()}`,
    type: "message",
    role: "assistant",
    model: "claude-opus-5-5",
    content: [{ type: "tool_use", id: `toolu_${crypto.randomUUID().slice(0, 8)}`, name, input }],
    stop_reason: "tool_use",
    stop_sequence: null,
    usage: { input_tokens: 10, output_tokens: 10 },
  };
}

function textReply(text: string) {
  return {
    id: `msg_${crypto.randomUUID()}`,
    type: "message",
    role: "assistant",
    model: "claude-opus-5-5",
    content: [{ type: "text", text }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: 10, output_tokens: 10 },
  };
}

// deno-lint-ignore no-explicit-any
function lastToolResult(req: Req): any {
  const last = req.body.messages.at(-1);
  return Array.isArray(last.content) ? last.content.find((b: { type: string }) => b.type === "tool_result") : undefined;
}

const server = Deno.serve({ port: STUB_PORT, onListen: () => {} }, async (req) => {
  const url = new URL(req.url);
  if (url.pathname.startsWith("/rest/v1/")) {
    const target = REST_URL + url.pathname.slice("/rest/v1".length) + url.search;
    const headers = new Headers(req.headers);
    headers.delete("host");
    const res = await fetch(target, { method: req.method, headers, body: req.body ? await req.arrayBuffer() : undefined });
    const nullBody = res.status === 204 || res.status === 304;
    return new Response(nullBody ? null : await res.arrayBuffer(), { status: res.status, headers: res.headers });
  }
  if (url.pathname === "/v1/messages") {
    const r = { headers: req.headers, body: await req.json() };
    seen.push(r);
    const step = script.shift();
    if (!step) {
      console.error("STUB SCRIPT EXHAUSTED; last tool result:", JSON.stringify(lastToolResult(r) ?? null).slice(0, 600));
      return Response.json({ type: "error", error: { type: "api_error", message: "script exhausted" } }, { status: 500 });
    }
    if (delayMs) await new Promise((res) => setTimeout(res, delayMs));
    try {
      return Response.json(step(r));
    } catch (e) {
      // A failed expectation: surface it and stop the run (400 is not retried).
      console.error("STUB EXPECTATION FAILED:", (e as Error).message);
      return Response.json({ type: "error", error: { type: "invalid_request_error", message: (e as Error).message } }, {
        status: 400,
      });
    }
  }
  return new Response("not found", { status: 404 });
});

// ---- function subprocess --------------------------------------------------

async function startFunction(name: string, extraEnv: Record<string, string> = {}): Promise<Deno.ChildProcess> {
  const child = new Deno.Command(Deno.execPath(), {
    args: ["run", "--allow-net", "--allow-env", `supabase/functions/${name}/index.ts`],
    env: {
      SUPABASE_URL: STUB,
      SUPABASE_SERVICE_ROLE_KEY: SERVICE_KEY,
      ANTHROPIC_API_KEY: "test-key",
      ANTHROPIC_BASE_URL: STUB,
      CRM_SHARED_SECRET: SECRET,
      ...extraEnv,
    },
    stdout: "null",
    stderr: "inherit",
  }).spawn();
  for (let i = 0; i < 100; i++) {
    try {
      await fetch(`http://127.0.0.1:${FN_PORT}/`, { method: "GET" }).then((r) => r.body?.cancel());
      return child;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  throw new Error(`${name} did not start`);
}

async function stop(child: Deno.ChildProcess) {
  child.kill();
  await child.status;
}

function post(body: unknown, key = SECRET) {
  return fetch(`http://127.0.0.1:${FN_PORT}/`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-crm-key": key },
    body: JSON.stringify(body),
  });
}

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

async function one<T>(q: PromiseLike<{ data: T | null; error: { message: string } | null }>): Promise<T> {
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return data as T;
}

// ---- seed -----------------------------------------------------------------

const seed = await one<{ people: { id: number }[] }>(sb.rpc("crm_apply_plan", {
  p_plan: {
    occurred_on: "2026-10-01",
    groups: [{ ref: "g", name: "Brooklyn Boulders", type: "Club", abbreviation: "BKB" }],
    people: [{ ref: "s", name: "Sam Rivera", set: { job: "Urban planner", relationship_tier: "Building" }, groups: ["g"] }],
    interactions: [{ type: "In Person", summary: "Climbed", people: ["s"], hooks: [{ text: "Job interview at Parks Dept" }] }],
    confirmation: "seed",
  },
  p_requested_by: "test seed",
}));
const SAM = seed.people[0].id;
const HOOK = (await one<{ id: number }[]>(sb.from("hooks").select("id")))[0].id;
const BKB = (await one<{ id: number }>(sb.from("groups").select("id").eq("abbreviation", "BKB").single())).id;

// ---- tests ----------------------------------------------------------------

Deno.test("ingest rejects a wrong or missing key", async () => {
  const fn = await startFunction("ingest");
  try {
    const bad = await post({ text: "hi" }, "nope");
    assert(bad.status === 401, `wrong key -> ${bad.status}`);
    await bad.body?.cancel();
    const none = await fetch(`http://127.0.0.1:${FN_PORT}/`, { method: "POST", body: "{}" });
    assert(none.status === 401, `missing key -> ${none.status}`);
    await none.body?.cancel();
    const notes = await one<unknown[]>(sb.from("voice_notes").select("id"));
    assert(notes.length === 0, "unauthorized requests store nothing");
  } finally {
    await stop(fn);
  }
});

Deno.test("ingest files a note end to end, recovering from a bad plan", async () => {
  const transcript = "Climbed with Sam at BKB tonight. He got the Parks job! Met his friend Dana Okafor, she's a nurse " +
    "and also climbs, wants to do the Gunks trip with us next month. Dana's dog is called Biscuit.";
  script = [
    (r) => {
      assert(r.body.model === "claude-opus-5-5", "model");
      assert(r.body.fallbacks === "default", "server-side fallbacks enabled");
      assert(r.headers.get("anthropic-beta")?.includes("server-side-fallback-2026-07-01"), "fallback beta header");
      assert(r.body.output_config?.effort === "medium", "effort");
      assert(r.body.system[0].cache_control?.type === "ephemeral", "system prompt cached");
      assert(r.body.system[0].text.includes("You file voice notes"), "ingest system prompt");
      const user = r.body.messages[0].content as string;
      assert(user.includes("Today is Thursday, 2026-10-22"), "phone's local date used");
      assert(user.includes(`#${SAM} Sam Rivera`), "directory includes Sam");
      assert(user.includes("Brooklyn Boulders (BKB)"), "groups listed");
      assert(user.includes(transcript), "transcript included");
      assert(r.body.tools.some((t: { name: string }) => t.name === "save_plan"), "save_plan offered");
      return toolUse("get_person", { id: SAM });
    },
    (r) => {
      const res = lastToolResult(r);
      assert(res && !res.is_error && res.content.includes("Job interview at Parks Dept"), "get_person returns open hooks");
      return toolUse("save_plan", { interactions: [{ type: "Carrier Pigeon", summary: "x", people: ["1"] }], confirmation: "x" });
    },
    (r) => {
      const res = lastToolResult(r);
      assert(res?.is_error && res.content.includes("Invalid input"), "schema error returned to model");
      return toolUse("save_plan", {
        groups: [{ ref: "bkb", id: BKB, attended_on: "2026-10-22" }],
        people: [
          { ref: "sam", id: SAM, set: { job: "Planner, NYC Parks Dept" }, overwrite: ["job"] },
          {
            ref: "dana",
            name: "Dana Okafor",
            set: {
              job: "Nurse",
              relationship_tier: "Building",
              known_since: "2026-10-22",
              how_we_met: "Sam's friend, climbing at BKB",
            },
            add: { likes_interests: ["climbing"], family_pets: ["Dog: Biscuit"] },
            groups: ["bkb"],
          },
        ],
        interactions: [{
          type: "In Person",
          summary: "Climbed at BKB; Sam got the Parks job; met Dana",
          people: ["sam", "dana"],
          hooks: [{ text: "Gunks climbing trip next month" }],
        }],
        resolve_hooks: [{ id: HOOK, resolution: "Got the job" }],
        flags: ["Is it Dana Okafor or Okafor-Smith?"],
        confirmation: "Added Dana Okafor (Building) · BKB. Logged climbing with Sam & Dana; 1 follow-up. Sam's Parks job saved.",
      });
    },
  ];
  const fn = await startFunction("ingest");
  try {
    const res = await post({ text: transcript, now: "2026-10-22T21:40:00-04:00" });
    const body = await res.json();
    assert(res.status === 200 && body.ok, `ok response: ${JSON.stringify(body)}`);
    assert(body.message.startsWith("Added Dana Okafor"), "confirmation first");
    assert(body.message.includes("? Is it Dana Okafor or Okafor-Smith?"), "flags shown");
    assert(script.length === 0 && seen.length === 3, "exactly three model calls");

    const sam = await one<{ job: string; last_contacted: string }>(
      sb.from("people").select("job, last_contacted").eq("id", SAM).single(),
    );
    assert(sam.job === "Planner, NYC Parks Dept" && sam.last_contacted === "2026-10-22", "Sam updated");
    const dana = await one<{ id: number; family_pets: string[] }>(
      sb.from("people").select("id, family_pets").eq("name", "Dana Okafor").single(),
    );
    assert(dana.family_pets[0] === "Dog: Biscuit", "Dana created with pet");
    const hooks = await one<{ hook: string; resolved_on: string | null }[]>(
      sb.from("hooks").select("hook, resolved_on").order("id"),
    );
    assert(
      hooks[0].resolved_on === "2026-10-22" && hooks[1].hook === "Gunks climbing trip next month",
      "hooks resolved and added",
    );
    const note = await one<{ status: string; spoken_at: string }>(
      sb.from("voice_notes").select("status, spoken_at").eq("id", body.note_id).single(),
    );
    assert(note.status === "needs_review", "note marked for review because of the flag");
    assert(note.spoken_at.startsWith("2026-10-23T01:40:00"), "spoken_at stored in UTC");
    const group = await one<{ last_contacted: string }>(sb.from("groups").select("last_contacted").eq("id", BKB).single());
    assert(group.last_contacted === "2026-10-22", "group attendance");
  } finally {
    await stop(fn);
    seen.length = 0;
  }
});

Deno.test("ingest feeds database rejections back to the model", async () => {
  script = [
    () => toolUse("save_plan", { interactions: [{ type: "Text", summary: "Texted", people: ["99999"] }], confirmation: "x" }),
    (r) => {
      const res = lastToolResult(r);
      assert(res?.is_error && res.content.includes("unknown people reference"), "DB error message reaches the model");
      return toolUse("save_plan", {
        interactions: [{ type: "Text", summary: "Texted Sam about Gunks dates", people: [String(SAM)] }],
        confirmation: "Logged a text with Sam.",
      });
    },
  ];
  const fn = await startFunction("ingest");
  try {
    const body = await (await post({ text: "texted sam about gunks dates", now: "2026-10-23T09:00:00-04:00" })).json();
    assert(body.ok && body.message === "Logged a text with Sam.", JSON.stringify(body));
    const ix = await one<unknown[]>(sb.from("interactions").select("id").eq("summary", "Texted"));
    assert(ix.length === 0, "rejected plan left nothing behind");
  } finally {
    await stop(fn);
    seen.length = 0;
  }
});

Deno.test("ingest answers early and finishes in the background when Claude is slow", async () => {
  delayMs = 600;
  script = [() => toolUse("save_plan", { people: [{ name: "Slow Sally" }], confirmation: "Added Slow Sally." })];
  const fn = await startFunction("ingest", { CRM_REPLY_AFTER_MS: "100" });
  try {
    const body = await (await post({ text: "add slow sally" })).json();
    assert(body.ok && body.pending, `pending reply: ${JSON.stringify(body)}`);
    await new Promise((r) => setTimeout(r, 2000));
    const note = await one<{ status: string }>(sb.from("voice_notes").select("status").eq("id", body.note_id).single());
    assert(note.status === "done", `background finished: ${note.status}`);
  } finally {
    delayMs = 0;
    await stop(fn);
    seen.length = 0;
  }
});

Deno.test("ingest keeps the transcript and reports when Claude fails", async () => {
  script = []; // stub returns a 500 -> SDK retries, then the run fails
  const fn = await startFunction("ingest");
  try {
    const body = await (await post({ text: "this should be kept even if filing fails" })).json();
    assert(!body.ok && body.message.includes(`#${body.note_id}`), JSON.stringify(body));
    const note = await one<{ status: string; transcript: string }>(
      sb.from("voice_notes").select("status, transcript").eq("id", body.note_id).single(),
    );
    assert(note.status === "error" && note.transcript.startsWith("this should be kept"), "transcript kept, status error");
  } finally {
    await stop(fn);
    seen.length = 0;
  }
});

Deno.test("ask answers read-only questions with tools", async () => {
  script = [
    (r) => {
      assert(r.body.system[0].text.includes("You answer questions"), "ask system prompt");
      assert(r.body.output_config?.effort === "low", "ask effort");
      assert(!r.body.tools.some((t: { name: string }) => t.name === "save_plan"), "no write tool offered");
      return toolUse("find_people", { query: "dana okafr" });
    },
    (r) => {
      const res = lastToolResult(r);
      assert(res && res.content.includes("Dana Okafor"), "fuzzy find returns Dana");
      const id = JSON.parse(res.content)[0].id;
      return toolUse("get_person", { id });
    },
    (r) => {
      const res = lastToolResult(r);
      assert(
        res.content.includes("Gunks climbing trip next month") && res.content.includes("Dog: Biscuit"),
        "card has hooks and pets",
      );
      return toolUse("people_due", {});
    },
    (r) => {
      const due = JSON.parse(lastToolResult(r).content);
      assert(Array.isArray(due) && due.some((d: { name: string }) => d.name === "Dana Okafor"), "people_due works");
      return textReply("Ask Dana about the Gunks trip next month. She's a nurse with a dog named Biscuit.");
    },
  ];
  const fn = await startFunction("ask");
  try {
    const res = await post({ question: "seeing dana tonight, anything to ask?", now: "2026-10-24T18:00:00-04:00" });
    const body = await res.json();
    assert(body.ok && body.answer.startsWith("Ask Dana about the Gunks"), JSON.stringify(body));
  } finally {
    await stop(fn);
    seen.length = 0;
  }
});

Deno.test({
  name: "shut down stub server",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    await server.shutdown();
  },
});
