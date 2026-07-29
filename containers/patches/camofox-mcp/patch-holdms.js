#!/usr/bin/env node
//
// Patches the camofox-mcp `click` tool to accept an optional `holdMs`
// parameter, forwarded to the camofox-browser REST POST /tabs/{tabId}/click
// endpoint. That endpoint already implements holdMs (see
// /app/dist/src/services/tab.js:1187 in the camofox-browser container): it
// dispatches a real Playwright mouse.down -> wait -> mouse.up sequence that
// produces an isTrusted=true event. PerimeterX "Press & Hold" CAPTCHAs
// reject synthetic isTrusted=false JS-dispatched events, so holdMs is the
// only working bypass; without it the `click` tool can only instant-click
// and the PerimeterX challenge can never be solved.
//
// Baked into the zeroclaw-container image at build time and run against the
// global install at /usr/local/lib/node_modules/camofox-mcp/ (see
// Containerfile). Idempotent: skips if the marker comment is present. Exits
// 1 if a source anchor no longer matches (upstream dist/ refactored), so a
// `&&`-chained build step fails loudly.
//
// Usage: node patch-camofox-mcp-holdms.js  (no args; locates the package)
//
const fs = require('node:fs');

const MARKER = '/* camofox-mcp holdMs patch applied */';

function findCamofoxMcpDir() {
  const candidate = '/usr/local/lib/node_modules/camofox-mcp/dist/tools/interaction.js';
  return fs.existsSync(candidate) ? candidate : null;
}

const FILE = findCamofoxMcpDir();
if (!FILE) {
  console.log('[camofox-mcp-holdms] interaction.js not found, skipping');
  process.exit(0);
}

let src = fs.readFileSync(FILE, 'utf8');

if (src.includes(MARKER)) {
  console.log('[camofox-mcp-holdms] patch already applied, skipping');
  process.exit(0);
}

const ORIGINAL_TOOL_DEF = `    server.tool("click", "Click an element. Provide either ref (from snapshot) or CSS selector. Use snapshot first to discover element refs.", {
        tabId: z.string().min(1).describe("Tab ID from create_tab"),
        ref: z.string().min(1).optional().describe("Element ref from snapshot (e.g. 'e1', 'e2')"),
        selector: z.string().min(1).optional().describe("CSS selector (e.g. 'button.submit', '#login')")
    }, async (input) => {`;

const PATCHED_TOOL_DEF = `    server.tool("click", "Click an element. Provide either ref (from snapshot) or CSS selector. Use snapshot first to discover element refs. For PerimeterX 'Press & Hold' CAPTCHAs, pass holdMs to keep the mouse button pressed for N ms (e.g. holdMs=8000).", {
        tabId: z.string().min(1).describe("Tab ID from create_tab"),
        ref: z.string().min(1).optional().describe("Element ref from snapshot (e.g. 'e1', 'e2')"),
        selector: z.string().min(1).optional().describe("CSS selector (e.g. 'button.submit', '#login')"),
        x: z.number().optional().describe("Viewport x coordinate (alternative to ref/selector)"),
        y: z.number().optional().describe("Viewport y coordinate (alternative to ref/selector)"),
        holdMs: z.number().int().min(0).max(60000).optional().describe("Hold mouse button for N ms. Required for PerimeterX 'Press & Hold' CAPTCHAs (e.g. 8000).")
    }, async (input) => {`;

const ORIGINAL_PARSED = `            const parsed = z
                .object({
                tabId: z.string().min(1).describe("Tab ID from create_tab"),
                ref: z.string().min(1).optional().describe("Element ref from snapshot (e.g. 'e1', 'e2')"),
                selector: z.string().min(1).optional().describe("CSS selector (e.g. 'button.submit', '#login')")
            })
                .refine((data) => Boolean(data.ref || data.selector), {
                message: "Either 'ref' or 'selector' is required"
            })
                .parse(input);
            const tracked = getTrackedTab(parsed.tabId);
            const result = await deps.client.click(parsed.tabId, {
                ref: parsed.ref,
                selector: parsed.selector
            }, tracked.userId);`;

const PATCHED_PARSED = `            const parsed = z
                .object({
                tabId: z.string().min(1).describe("Tab ID from create_tab"),
                ref: z.string().min(1).optional().describe("Element ref from snapshot (e.g. 'e1', 'e2')"),
                selector: z.string().min(1).optional().describe("CSS selector (e.g. 'button.submit', '#login')"),
                x: z.number().optional().describe("Viewport x coordinate (alternative to ref/selector)"),
                y: z.number().optional().describe("Viewport y coordinate (alternative to ref/selector)"),
                holdMs: z.number().int().min(0).max(60000).optional().describe("Hold mouse button for N ms. Required for PerimeterX 'Press & Hold' CAPTCHAs (e.g. 8000).")
            })
                .refine((data) => Boolean(data.ref || data.selector || (data.x !== undefined && data.y !== undefined)), {
                message: "Either 'ref', 'selector', or 'x'+'y' is required"
            })
                .parse(input);
            const tracked = getTrackedTab(parsed.tabId);
            const result = await deps.client.click(parsed.tabId, {
                ref: parsed.ref,
                selector: parsed.selector,
                x: parsed.x,
                y: parsed.y,
                holdMs: parsed.holdMs
            }, tracked.userId);`;

if (!src.includes(ORIGINAL_TOOL_DEF)) {
  console.error('[camofox-mcp-holdms] FATAL: original tool def not found in ' + FILE);
  console.error('  The camofox-mcp package may have been updated and the patch is no longer applicable.');
  process.exit(1);
}
if (!src.includes(ORIGINAL_PARSED)) {
  console.error('[camofox-mcp-holdms] FATAL: original parsed block not found in ' + FILE);
  process.exit(1);
}

src = src.replace(ORIGINAL_TOOL_DEF, PATCHED_TOOL_DEF);
src = src.replace(ORIGINAL_PARSED, PATCHED_PARSED);

// Add marker at the top so we can detect the patch on re-runs.
src = MARKER + '\n' + src;

fs.writeFileSync(FILE, src, 'utf8');
console.log('[camofox-mcp-holdms] patched ' + FILE);
