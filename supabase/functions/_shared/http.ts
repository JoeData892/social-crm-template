// Request plumbing shared by the ingest and ask endpoints: shared-secret auth,
// bounded JSON bodies, and the phone's local date.

const MAX_BODY_BYTES = 64 * 1024;

export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

async function sha256(s: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
}

// Constant-time comparison of the x-crm-key header against CRM_SHARED_SECRET.
export async function requireSecret(req: Request): Promise<void> {
  const secret = Deno.env.get("CRM_SHARED_SECRET") ?? "";
  if (secret.length < 32) {
    throw new HttpError(500, "Server is missing CRM_SHARED_SECRET (32+ characters).");
  }
  const given = req.headers.get("x-crm-key") ?? "";
  const [a, b] = await Promise.all([sha256(given), sha256(secret)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  if (diff !== 0) throw new HttpError(401, "Unauthorized.");
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  if (req.method !== "POST") throw new HttpError(405, "Use POST.");
  const raw = await req.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) throw new HttpError(413, "Request too large.");
  try {
    const body = JSON.parse(raw);
    if (body && typeof body === "object" && !Array.isArray(body)) return body;
  } catch {
    // fall through
  }
  throw new HttpError(400, "Body must be a JSON object.");
}

export function requireText(body: Record<string, unknown>, key: string, max: number): string {
  const v = body[key];
  if (typeof v !== "string" || v.trim() === "") throw new HttpError(400, `"${key}" is required.`);
  if (v.length > max) throw new HttpError(413, `"${key}" is longer than ${max} characters.`);
  return v.trim();
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

// The phone sends its clock as ISO 8601 with offset (e.g. 2026-10-22T08:15:00-04:00).
// Its date and hour are the user's local ones, which is what "today",
// "yesterday" and "last Friday" are relative to. Falls back to CRM_TIMEZONE.
export function localToday(now: unknown): { date: string; weekday: string; hour: number; spokenAt: string | null } {
  let date: string;
  let hour: number;
  let spokenAt: string | null = null;
  if (typeof now === "string" && /^\d{4}-\d{2}-\d{2}/.test(now) && !Number.isNaN(Date.parse(now))) {
    date = now.slice(0, 10);
    hour = /^.{10}T\d{2}/.test(now) ? Number(now.slice(11, 13)) : 12;
    spokenAt = new Date(now).toISOString();
  } else {
    const tz = Deno.env.get("CRM_TIMEZONE") ?? "UTC";
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date());
    const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
    date = `${get("year")}-${get("month")}-${get("day")}`;
    hour = Number(get("hour"));
  }
  const [y, m, d] = date.split("-").map(Number);
  return { date, weekday: WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()], hour, spokenAt };
}

// Run work after the response is sent (Supabase Edge Runtime), or detached elsewhere.
export function background(p: Promise<unknown>): void {
  const rt = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
  const guarded = p.catch((e) => console.error("background task failed:", e instanceof Error ? e.message : e));
  if (rt) rt.waitUntil(guarded);
}

export function handle(fn: (req: Request) => Promise<Response>): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      return await fn(req);
    } catch (e) {
      if (e instanceof HttpError) return json({ ok: false, message: e.message }, e.status);
      console.error("unhandled:", e instanceof Error ? e.message : e);
      return json({ ok: false, message: "Something went wrong on the server." }, 500);
    }
  };
}
