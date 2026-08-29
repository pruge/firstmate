// Single owner of Firstmate's edit-tool argument recovery for malformed
// model tool calls that Pi's own built-in recovery does not cover.
//
// Pi's built-in edit tool (createEditToolDefinition's prepareArguments)
// already recovers two shapes: "edits sent as a clean JSON string" and "a
// single edit object instead of a one-element array". This module adds
// THREE more recoveries observed from live crews (captain evidence,
// 2026-08-29), applied in this order after the built-in recovery has run:
//
//   1. path-hoisting: a model puts `path` inside every edits[] item and
//      omits the top-level `path` entirely.
//   2. lenient JSON re-parse: `edits` is still a string because the
//      built-in JSON.parse threw - most often because the model emitted a
//      literal raw newline/tab/CR byte inside a JSON string value instead
//      of the two-character `\n`/`\t`/`\r` escape. This re-parses after
//      escaping only control characters found strictly inside quoted spans.
//   3. marker-based extraction: `edits` is a string that is not valid JSON
//      at all, mixing an XML-tag-style opener (`<parameter name="oldText">`)
//      or a broken JSON-ish opener (`"oldText">`, missing the colon) with
//      raw, unescaped file content. Both openers are accepted; content runs
//      to the matching `"newText"` marker, then to the end of the string,
//      with any trailing tool-call framing garbage (a stray `</invoke>` or
//      `</parameter>`) stripped first so it cannot be swallowed into the
//      captured content.
//
// Best-effort and safe by construction at every stage: downstream
// validateEditInput and applyEditsToNormalizedContent still require an
// exact oldText match against the real file, so any wrong extraction here
// falls through to the same clean "text not found" error instead of
// corrupting a file. A recovery that cannot conclusively resolve the shape
// (disagreeing hoisted paths, unparseable content) returns null/unchanged
// rather than guessing.
import type { ToolDefinition } from "\u0040earendil-works/pi-coding-agent";
import type { TSchema } from "typebox";

function isEditsString(value: unknown): value is string {
  return typeof value === "string";
}

// Strip trailing wrapper-leftover XML tags (a stray `</invoke>` or
// `</parameter>` from a tool-call framing that leaked into the argument
// text) before pattern matching, so the content regex is never asked to
// backtrack through them.
function stripTrailingToolCallGarbage(text: string): string {
  let out = text;
  for (;;) {
    const next = out.replace(/\s*(<\/invoke>|<\/parameter>)\s*$/, "");
    if (next === out) return out;
    out = next;
  }
}

// Escape raw control characters (literal newline/tab/carriage-return bytes)
// found INSIDE a "..." JSON string span, and nowhere else. A model
// occasionally emits a literal newline where JSON requires the two-character
// escape `\n`; JSON.parse then throws on the whole payload even though every
// other byte is well-formed. Only tried after a first plain JSON.parse
// attempt failed.
function escapeRawControlCharsInsideJsonStrings(text: string): string {
  let out = "";
  let inString = false;
  let escaped = false;
  for (const ch of text) {
    if (inString) {
      if (escaped) {
        out += ch;
        escaped = false;
      } else if (ch === "\\") {
        out += ch;
        escaped = true;
      } else if (ch === "\"") {
        out += ch;
        inString = false;
      } else if (ch === "\n") {
        out += "\\n";
      } else if (ch === "\r") {
        out += "\\r";
      } else if (ch === "\t") {
        out += "\\t";
      } else {
        out += ch;
      }
    } else {
      if (ch === "\"") inString = true;
      out += ch;
    }
  }
  return out;
}

function tryParseJsonLenient(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    // fall through to the control-character repair below
  }
  try {
    return JSON.parse(escapeRawControlCharsInsideJsonStrings(text));
  } catch {
    return undefined;
  }
}

// Accepts either the original XML-tag opener or a broken JSON-ish opener
// that is missing its colon (`"oldText">` instead of `"oldText":`), which is
// what a JSON/XML-hybrid corruption produces in practice.
const XML_STYLE_EDIT_RE =
  /(?:<parameter\s+name=["']oldText["']>|"oldText"\s*[:>]\s*"?)([\s\S]*?)"?\s*,?\s*"newText"\s*[:>]\s*"?([\s\S]*?)"?\s*\}?\s*$/;

export function extractXmlStyleEdit(rawText: string): { oldText: string; newText: string } | null {
  const text = stripTrailingToolCallGarbage(rawText).trim();
  const m = XML_STYLE_EDIT_RE.exec(text);
  if (!m) return null;
  const unescape = (s: string) =>
    s.replace(/\\n/g, "\n").replace(/\\"/g, "\"").replace(/\\\\/g, "\\");
  return { oldText: unescape(m[1]), newText: unescape(m[2]) };
}

// A model sometimes puts `path` inside every edits[] item instead of once at
// the top level, then omits top-level `path` entirely. Hoist a single
// agreeing path up; refuse (return null) if items disagree or are missing
// oldText/newText/path, since guessing the wrong file is worse than a clear
// validation error.
export function hoistPathFromEditsItems(
  editsArr: unknown,
): { path: string; edits: Array<{ oldText: string; newText: string }> } | null {
  if (!Array.isArray(editsArr) || editsArr.length === 0) return null;
  let path: string | undefined;
  const cleaned: Array<{ oldText: string; newText: string }> = [];
  for (const item of editsArr) {
    if (!item || typeof item !== "object") return null;
    const it = item as { oldText?: unknown; newText?: unknown; path?: unknown };
    if (typeof it.oldText !== "string" || typeof it.newText !== "string") return null;
    if (typeof it.path !== "string") return null;
    if (path === undefined) path = it.path;
    else if (path !== it.path) return null;
    cleaned.push({ oldText: it.oldText, newText: it.newText });
  }
  if (path === undefined) return null;
  return { path, edits: cleaned };
}

export function wrapEditPrepareArgumentsWithXmlRecovery<TParams extends TSchema, TDetails, TState>(
  definition: ToolDefinition<TParams, TDetails, TState>,
): ToolDefinition<TParams, TDetails, TState> {
  const originalPrepare = definition.prepareArguments;
  return {
    ...definition,
    prepareArguments(input: unknown) {
      let prepared: unknown = originalPrepare ? originalPrepare(input) : input;

      // Recovery 1: path nested inside every edits[] item, top-level path missing.
      if (prepared && typeof prepared === "object") {
        const args = prepared as { path?: unknown; edits?: unknown };
        if (typeof args.path !== "string" && Array.isArray(args.edits)) {
          const hoisted = hoistPathFromEditsItems(args.edits);
          if (hoisted) {
            prepared = { ...args, path: hoisted.path, edits: hoisted.edits };
          }
        }
      }

      if (!prepared || typeof prepared !== "object") {
        return prepared as ReturnType<NonNullable<typeof originalPrepare>>;
      }
      const args = prepared as { edits?: unknown };
      if (!isEditsString(args.edits)) {
        return prepared as ReturnType<NonNullable<typeof originalPrepare>>;
      }

      // Recovery 2: edits is still a string because the built-in JSON.parse
      // threw; retry leniently before falling back to marker extraction.
      const lenient = tryParseJsonLenient(args.edits);
      if (Array.isArray(lenient)) {
        return { ...args, edits: lenient } as ReturnType<NonNullable<typeof originalPrepare>>;
      }
      if (lenient && typeof lenient === "object") {
        const single = lenient as { oldText?: unknown; newText?: unknown };
        if (typeof single.oldText === "string" && typeof single.newText === "string") {
          return { ...args, edits: [single] } as ReturnType<NonNullable<typeof originalPrepare>>;
        }
      }

      // Recovery 3: marker-based extraction for XML-tag or broken-JSON-ish openers.
      const recovered = extractXmlStyleEdit(args.edits);
      if (!recovered) {
        return prepared as ReturnType<NonNullable<typeof originalPrepare>>;
      }
      return { ...args, edits: [recovered] } as ReturnType<NonNullable<typeof originalPrepare>>;
    },
  };
}
