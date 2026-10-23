// Pushover delivery (https://pushover.net/api). Notifications go only to the
// user's own Pushover account; this never contacts anyone else.

const MAX_MESSAGE = 1024;

export async function pushover(opts: { title: string; lines: string[]; url?: string; urlTitle?: string }): Promise<void> {
  const token = Deno.env.get("PUSHOVER_TOKEN");
  const user = Deno.env.get("PUSHOVER_USER");
  if (!token || !user) throw new Error("PUSHOVER_TOKEN / PUSHOVER_USER are not set");

  // Fit as many whole lines as the API allows, then say how many were left out.
  let message = "";
  for (let i = 0; i < opts.lines.length; i++) {
    const rest = opts.lines.length - i - 1;
    const candidate = message ? `${message}\n${opts.lines[i]}` : opts.lines[i];
    const suffix = rest > 0 ? `\n+${rest} more in Follow-ups` : "";
    if ((candidate + suffix).length > MAX_MESSAGE) {
      message += `\n+${opts.lines.length - i} more in Follow-ups`;
      break;
    }
    message = candidate;
  }

  const body = new URLSearchParams({ token, user, title: opts.title.slice(0, 250), message });
  if (opts.url) {
    body.set("url", opts.url);
    if (opts.urlTitle) body.set("url_title", opts.urlTitle);
  }
  const res = await fetch(Deno.env.get("PUSHOVER_API_URL") ?? "https://api.pushover.net/1/messages.json", {
    method: "POST",
    body,
  });
  if (!res.ok) throw new Error(`Pushover returned ${res.status}: ${(await res.text()).slice(0, 300)}`);
  await res.body?.cancel();
}
