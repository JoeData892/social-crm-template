import { Anthropic, z } from "./deps.ts";

// A small manual tool-use loop. Tools validate their own input with zod and
// return text; a tool can end the run (`done`) so the last step needs no extra
// model call (save_plan in ingest).

export interface Tool<S extends z.ZodType = z.ZodType> {
  name: string;
  description: string;
  schema: S;
  run(input: z.infer<S>): Promise<ToolOutcome>;
}

export interface ToolOutcome {
  content: string;
  isError?: boolean;
  done?: boolean;
}

export function tool<S extends z.ZodType>(t: Tool<S>): Tool {
  return t as unknown as Tool;
}

function toApiTool(t: Tool): Anthropic.Beta.BetaTool {
  const { $schema: _ignored, ...schema } = z.toJSONSchema(t.schema) as Record<string, unknown>;
  return { name: t.name, description: t.description, input_schema: schema as Anthropic.Beta.BetaTool.InputSchema };
}

export const MODEL = Deno.env.get("CRM_MODEL") ?? "claude-opus-5-5";

let client: Anthropic | null = null;
function anthropic(): Anthropic {
  // Reads ANTHROPIC_API_KEY from the environment.
  client ??= new Anthropic({ maxRetries: 2, timeout: 120_000 });
  return client;
}

export interface RunResult {
  text: string;
  done: boolean;
}

export async function runAgent(opts: {
  system: string;
  user: string;
  tools: Tool[];
  effort: "low" | "medium" | "high";
  maxTurns: number;
}): Promise<RunResult> {
  const byName = new Map(opts.tools.map((t) => [t.name, t]));
  const apiTools = opts.tools.map(toApiTool);
  const messages: Anthropic.Beta.BetaMessageParam[] = [{ role: "user", content: opts.user }];

  for (let turn = 0; turn < opts.maxTurns; turn++) {
    const res = await anthropic().beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      // Stable prefix (tools + system) is cached across notes; the top-level
      // marker caches the growing conversation between turns of one note.
      system: [{ type: "text", text: opts.system, cache_control: { type: "ephemeral" } }],
      cache_control: { type: "ephemeral" },
      tools: apiTools,
      messages,
      output_config: { effort: opts.effort },
      // On a policy decline, let the API retry on its recommended fallback model.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
    });

    if (res.stop_reason === "refusal") {
      throw new Error("Claude declined to process this request.");
    }
    if (res.stop_reason === "max_tokens") {
      throw new Error("Claude's response was cut off (max_tokens).");
    }
    // Keep the full content (including thinking blocks) so history stays append-only.
    messages.push({ role: "assistant", content: res.content });

    const calls = res.content.filter((b): b is Anthropic.Beta.BetaToolUseBlock => b.type === "tool_use");
    if (res.stop_reason !== "tool_use" || calls.length === 0) {
      const text = res.content
        .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === "text")
        .map((b) => b.text)
        .join("\n")
        .trim();
      return { text, done: false };
    }

    // Sequential on purpose: a write tool must never run twice concurrently.
    const outcomes: ToolOutcome[] = [];
    for (const call of calls) {
      const t = byName.get(call.name);
      const parsed = t?.schema.safeParse(call.input);
      let outcome: ToolOutcome;
      if (!t || !parsed) {
        outcome = { content: `Unknown tool ${call.name}`, isError: true };
      } else if (!parsed.success) {
        outcome = { content: `Invalid input: ${z.prettifyError(parsed.error)}`, isError: true };
      } else {
        try {
          outcome = await t.run(parsed.data);
        } catch (e) {
          outcome = { content: e instanceof Error ? e.message : String(e), isError: true };
        }
      }
      if (outcome.done && !outcome.isError) return { text: outcome.content, done: true };
      outcomes.push(outcome);
    }

    messages.push({
      role: "user",
      content: calls.map((call, i): Anthropic.Beta.BetaToolResultBlockParam => ({
        type: "tool_result",
        tool_use_id: call.id,
        content: outcomes[i].content,
        is_error: outcomes[i].isError ?? false,
      })),
    });
  }
  throw new Error(`Gave up after ${opts.maxTurns} model turns.`);
}
