import { z } from "./deps.ts";

// The plan Claude produces for one voice note. Mirrors crm_apply_plan() in the
// migration; the database re-validates everything (choice lists, references,
// overwrite rules) inside one transaction.

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "YYYY-MM-DD");
const ref = z.union([z.string(), z.number().int()])
  .describe('A ref declared in this plan (e.g. "p1") or an existing record id (e.g. 42).');
const text = z.string().min(1);

// Keep in sync with the CHECK constraints in the migration.
export const INTERACTION_TYPES = ["In Person", "Phone Call", "Text", "Social Media", "Email", "Video Call"] as const;
export const GROUP_TYPES = ["Friend Group", "Social Circle", "Group Chat", "Club", "Community", "Workplace", "Other"] as const;
export const ROSTER_SOURCES = [
  "Event sign-up",
  "Met in person",
  "Online list",
  "Friend's circle",
  "Party invite list",
  "Other",
] as const;

const SCALAR_FIELDS = [
  "community_name",
  "phone",
  "email",
  "location",
  "birthday",
  "known_since",
  "relationship_tier",
  "follow_up_frequency",
  "next_follow_up",
  "job",
  "how_we_met",
] as const;

const PersonSet = z.strictObject({
  community_name: text.describe("Name they go by in a scene or club").optional(),
  phone: text.optional(),
  email: text.optional(),
  location: text.describe("Where they live: address or rough area").optional(),
  birthday: isoDate.describe("Use year 1904 when the year is unknown").optional(),
  known_since: isoDate.describe("When the user first met them; YYYY-01-01 if only the year is known").optional(),
  relationship_tier: text.optional(),
  follow_up_frequency: text.optional(),
  next_follow_up: isoDate.describe("Only when the user names a specific date to reach out").optional(),
  job: text.describe("Title and/or employer").optional(),
  how_we_met: text.optional(),
});

export const Plan = z.strictObject({
  occurred_on: isoDate.describe("Date the note is about; default for dates below. Usually today.").optional(),
  groups: z.array(z.strictObject({
    ref: z.string().optional(),
    id: z.number().int().describe("Existing group id").optional(),
    name: text.describe("For a group not in the list. Matched against existing names and abbreviations before creating.")
      .optional(),
    type: z.enum(GROUP_TYPES).optional(),
    subtype: text.describe("Free text, e.g. Running Club").optional(),
    abbreviation: text.optional(),
    notes: text.optional(),
    attended_on: isoDate.describe("Set when the user showed up to this group").optional(),
  })).optional(),
  people: z.array(z.strictObject({
    ref: z.string().optional(),
    id: z.number().int().describe("Existing contact id. Omit to create a new contact.").optional(),
    name: text.describe("Full name for a NEW contact").optional(),
    set: PersonSet.describe("Fills empty fields only, unless the field is also listed in overwrite.").optional(),
    overwrite: z.array(z.enum(SCALAR_FIELDS))
      .describe("Fields the user is explicitly correcting or updating; these replace a filled value.").optional(),
    add: z.strictObject({
      aliases: z.array(text).describe("Nicknames, alternate spellings").optional(),
      socials: z.array(text).describe("Profile URLs or @handles").optional(),
      tags: z.array(text).optional(),
      likes_interests: z.array(text).describe("Short phrases").optional(),
      family_pets: z.array(text).describe('"Relation: Name", or "Relation: (name unknown)"').optional(),
    }).describe("Appended to lists; duplicates ignored; nothing is removed.").optional(),
    append: z.strictObject({
      history: text.describe("Long-arc backstory; dated automatically").optional(),
      notes: text.describe("Last resort for facts with no field").optional(),
    }).optional(),
    groups: z.array(ref).describe("Group refs or ids to link (links are only ever added)").optional(),
    partner: ref.describe("Their partner, when the partner is (or is being made) a contact").optional(),
  })).optional(),
  events: z.array(z.strictObject({
    ref: z.string().optional(),
    id: z.number().int().optional(),
    name: text.optional(),
    date: isoDate.optional(),
    location: text.optional(),
    notes: text.optional(),
    people: z.array(ref).describe("Contacts who were there").optional(),
  })).optional(),
  interactions: z.array(z.strictObject({
    date: isoDate.optional(),
    type: z.enum(INTERACTION_TYPES),
    summary: text.describe("One short line"),
    location: text.optional(),
    notes: text.describe("Details of the conversation worth keeping that aren't facts about a person").optional(),
    people: z.array(ref).min(1),
    hooks: z.array(z.strictObject({
      text: text.describe("Forward-looking topic, in the user's words, shortened"),
      person: ref.describe("Who it is about, if it is about one participant").optional(),
    })).optional(),
  })).optional(),
  resolve_hooks: z.array(z.strictObject({
    id: z.number().int().describe("hook_id from get_person"),
    resolution: text.describe("How it turned out, briefly").optional(),
  })).optional(),
  rosters: z.array(z.strictObject({
    name: text.describe("Source or host, event, and date"),
    date: isoDate.optional(),
    source: z.enum(ROSTER_SOURCES).optional(),
    names: z.array(text).min(1).describe('One name per entry; optional note after " — "'),
    notes: text.optional(),
    anchor_group: ref.optional(),
    anchor_person: ref.optional(),
    event: ref.optional(),
    people: z.array(ref).describe("Existing contacts you are confident appear on this list").optional(),
  })).optional(),
  flags: z.array(text).describe("Short questions for the user about anything you could not file safely").optional(),
  confirmation: text.describe("1-3 short plain-text lines for an iPhone notification summarizing what was filed"),
});

export type Plan = z.infer<typeof Plan>;
