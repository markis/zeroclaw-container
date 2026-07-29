#!/usr/bin/env node
//
// Patches camofox-mcp to add a `camofox_solve_press_hold_captcha` tool that
// solves a PerimeterX "Press & Hold" CAPTCHA in one MCP call, replacing the
// 4-call evaluate_js -> parse -> click(holdMs) -> wait_for dance (15-30s,
// 3-6 LLM iterations, with the widget able to change between calls).
//
// One server-side call: evaluate_js to find #px-captcha (fallback
// #px-captcha-wrapper), compute its viewport center, dispatch a Playwright
// mouse.down -> holdMs wait -> mouse.up at those coordinates via the existing
// /tabs/{id}/click REST endpoint (which already does press-and-hold; see
// /app/dist/src/services/tab.js:1187 in camofox-browser), and return the
// click result + bounding box.
//
// Baked into the zeroclaw-container image at build time and run against the
// global install at /usr/local/lib/node_modules/camofox-mcp/ (see
// Containerfile). Idempotent: skips if the marker comment is present. Exits
// 1 if a source anchor no longer matches (upstream dist/ refactored), so a
// `&&`-chained build step fails loudly.
//
// Usage: node patch-camofox-mcp-captcha.js  (no args; locates the package)
//
const fs = require('node:fs');
const path = require('node:path');

const MARKER = '/* camofox-mcp press-hold-captcha patch applied */';

function findFile(relativePath) {
  const candidate = path.join('/usr/local/lib/node_modules/camofox-mcp', relativePath);
  return fs.existsSync(candidate) ? candidate : null;
}

const INTERACTION_FILE = findFile('dist/tools/interaction.js');
const SERVER_FILE = findFile('dist/server.js');
if (!INTERACTION_FILE || !SERVER_FILE) {
  console.log('[camofox-mcp-captcha] interaction.js/server.js not found, skipping');
  process.exit(0);
}

let src = fs.readFileSync(INTERACTION_FILE, 'utf8');
let serverSrc = fs.readFileSync(SERVER_FILE, 'utf8');

if (src.includes(MARKER) && serverSrc.includes('registerPressHoldCaptchaTool')) {
  console.log('[camofox-mcp-captcha] patch already applied, skipping');
  process.exit(0);
}

// Find the end of registerInteractionTools() function (the last `});` before
// `export function registerPressKeyTool`). We insert a new exported function
// `registerPressHoldCaptchaTool` that defines a single MCP tool.

const INSERTION_ANCHOR = `export function registerPressKeyTool(server, deps) {`;

const NEW_TOOL = `export function registerPressHoldCaptchaTool(server, deps) {
    server.tool("camofox_solve_press_hold_captcha", "Atomically solve a PerimeterX 'Press & Hold' CAPTCHA challenge on the current page. Finds the #px-captcha element (fallback #px-captcha-wrapper), computes its viewport center, and dispatches a real Playwright mouse.down → wait → mouse.up sequence at those coordinates for holdMs ms (default 8000). Returns { boundingBox, center, clickResult }. Use this INSTEAD of separate evaluate_js + click + wait_for calls when you see a 'Press & Hold to confirm you are a human' challenge.", {
        tabId: z.string().min(1).describe("Tab ID from create_tab"),
        holdMs: z.number().int().min(0).max(60000).optional().describe("How long to hold the mouse button in ms. Default 8000 (PerimeterX requires 6-10s)."),
        selector: z.string().optional().describe("CSS selector for the captcha element. Default '#px-captcha'. Fallback to '#px-captcha-wrapper' if not found.")
    }, async (input) => {
        try {
            const parsed = z
                .object({
                tabId: z.string().min(1),
                holdMs: z.number().int().min(0).max(60000).optional(),
                selector: z.string().optional()
            })
                .parse(input);
            const tracked = getTrackedTab(parsed.tabId);
            const holdMs = parsed.holdMs ?? 8000;
            const primary = parsed.selector ?? '#px-captcha';
            const fallback = '#px-captcha-wrapper';
            // Step 1: find the captcha element + bounding box. Try the
            // primary selector, then the fallback. The expression runs in
            // the page context (browser-side JS, not the MCP server's
            // context).
            const findExpr = \`JSON.stringify((function(){var c=document.querySelector(\\\"\${primary}\\\");if(!c)c=document.querySelector(\\\"\${fallback}\\\");if(!c)return JSON.stringify({error:'no captcha element found (tried ' + \${JSON.stringify(primary)} + ', ' + \${JSON.stringify(fallback)} + ')'});var r=c.getBoundingClientRect();return{selector:c.id||c.tagName,x:r.x,y:r.y,w:r.width,h:r.height,cx:r.x+r.width/2,cy:r.y+r.height/2};})())\`;
            const findResult = await deps.client.evaluate(parsed.tabId, findExpr, tracked.userId);
            let bb;
            try {
                bb = JSON.parse(findResult.result);
            } catch (e) {
                return toErrorResult(new Error('Failed to parse captcha bounding box: ' + e.message + ' raw=' + JSON.stringify(findResult)));
            }
            if (bb && bb.error) {
                return toErrorResult(new Error(bb.error));
            }
            // Step 2: click at the captcha center with the requested holdMs.
            // The camofox-browser REST /click endpoint does a real Playwright
            // mouse.down → wait → mouse.up sequence when holdMs > 0.
            const clickResult = await deps.client.click(parsed.tabId, {
                x: bb.cx,
                y: bb.cy,
                holdMs
            }, tracked.userId);
            incrementToolCall(parsed.tabId);
            return okResult({
                boundingBox: { x: bb.x, y: bb.y, w: bb.w, h: bb.h, selector: bb.selector },
                center: { x: bb.cx, y: bb.cy },
                holdMs,
                clickResult
            });
        }
        catch (error) {
            return toErrorResult(error);
        }
    });
}
`;

if (!src.includes(INSERTION_ANCHOR)) {
  console.error('[camofox-mcp-captcha] FATAL: insertion anchor not found in ' + INTERACTION_FILE);
  console.error('  The camofox-mcp package may have been updated and the patch is no longer applicable.');
  process.exit(1);
}

src = src.replace(INSERTION_ANCHOR, NEW_TOOL + '\n' + INSERTION_ANCHOR);

if (!src.startsWith(MARKER)) {
  src = MARKER + '\n' + src;
}

// --- Patch server.js to import + register the new tool ---
const SERVER_IMPORT_LINE = `import { registerInteractionTools, registerPressKeyTool } from "./tools/interaction.js";`;
const SERVER_IMPORT_PATCHED = `import { registerInteractionTools, registerPressKeyTool, registerPressHoldCaptchaTool } from "./tools/interaction.js";`;

const SERVER_REGISTRATION_LINE = `    registerPressKeyTool(server, deps);`;
const SERVER_REGISTRATION_PATCHED = SERVER_REGISTRATION_LINE + '\n    registerPressHoldCaptchaTool(server, deps);';

if (!serverSrc.includes(SERVER_IMPORT_LINE)) {
  console.error('[camofox-mcp-captcha] FATAL: server.js import line not found.');
  process.exit(1);
}
if (!serverSrc.includes('registerPressHoldCaptchaTool')) {
  serverSrc = serverSrc.replace(SERVER_IMPORT_LINE, SERVER_IMPORT_PATCHED);
  serverSrc = serverSrc.replace(SERVER_REGISTRATION_LINE, SERVER_REGISTRATION_PATCHED);
}
if (!serverSrc.startsWith(MARKER)) {
  serverSrc = MARKER + '\n' + serverSrc;
}

fs.writeFileSync(INTERACTION_FILE, src, 'utf8');
fs.writeFileSync(SERVER_FILE, serverSrc, 'utf8');
console.log('[camofox-mcp-captcha] patched ' + INTERACTION_FILE);
console.log('[camofox-mcp-captcha] patched ' + SERVER_FILE);
