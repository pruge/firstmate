// Firstmate's edit-tool XML-argument-recovery override.
//
// A weak model occasionally sends the edit tool's "edits" argument as an
// XML-tag-flavored pseudo-JSON mash-up instead of a clean array or JSON
// string (see ./lib/fm-edit-xml-recovery.ts for the exact shape and the
// single-owner recovery function). Pi's own built-in edit tool recovers two
// other malformed shapes but not this one, and that recovery logic lives in
// node_modules, so it silently reverts on every pi-coding-agent package
// update. This extension registers the SAME recovery through Pi's supported
// tool-override mechanism (pi.registerTool with the built-in name "edit")
// instead, which survives package updates because it lives in this tracked
// repo and Pi re-loads it on every trusted session.
//
// fm-calm.ts separately wraps createEditToolDefinition with the identical
// recovery (see its wrapBuiltIn(createEditToolDefinition) call) so a
// Calm-on session keeps the recovery even though Calm claims the "edit"
// tool-name slot for presentation. This extension only needs to act when
// Calm is NOT going to claim "edit" at load time, i.e. Calm is off; Pi has
// one first-registration-wins ToolDefinition per tool name, so whichever of
// the two extensions actually registers "edit" first is fine as long as
// both register the same recovery behavior.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "\u0040earendil-works/pi-coding-agent";
import { createEditToolDefinition } from "\u0040earendil-works/pi-coding-agent";
import { wrapEditPrepareArgumentsWithXmlRecovery } from "./lib/fm-edit-xml-recovery.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "..");

// Same calm-preference resolution as fm-calm.ts: "max" is the legacy value
// for the removed third presentation level, treated as on.
function calmIsActive(): boolean {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  const calmPreferencePath = resolve(configDirectory, "calm");
  let stored: string;
  try {
    stored = readFileSync(calmPreferencePath, "utf8").trim();
  } catch {
    return false;
  }
  return stored === "on" || stored === "max";
}

export default function (pi: ExtensionAPI) {
  // Calm-on sessions get the identical recovery through fm-calm.ts's own
  // wrapped builtin registration; registering here too would just be a
  // second, redundant claim of the same tool name.
  if (calmIsActive()) return;
  pi.registerTool(wrapEditPrepareArgumentsWithXmlRecovery(createEditToolDefinition(process.cwd())));
}
