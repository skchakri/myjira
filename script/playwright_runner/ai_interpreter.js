import { spawnSync } from 'node:child_process';

// Calls the local `claude` CLI (Claude Code, already authenticated via your Max subscription).
// No API key needed — uses the same session Claude Code uses.

const INSTRUCTIONS = `You are a Playwright test automation expert. Convert a test case description into structured browser actions.

Available actions and required fields:
  navigate       url            — go to URL; use {BASE_URL} for the app root
  fill           selector value — type into an input
  click          selector       — click an element
  check          selector       — check a checkbox
  uncheck        selector       — uncheck a checkbox
  select_option  selector value — pick a <select> option
  type           text           — keyboard input at current focus
  hover          selector       — mouse hover
  wait_ms        ms             — pause N milliseconds
  wait_for_selector selector    — wait until element appears in DOM
  wait_for_url   contains       — wait until URL contains string
  assert_url     contains       — fail if URL does not contain string
  assert_text    selector contains — fail if element text doesn't contain string
  assert_visible selector       — fail if element not visible
  assert_not_visible selector   — fail if element is visible
  screenshot                    — capture screen

Use specific CSS selectors: prefer [name="..."], [id="..."], button[type="submit"], .class-name.
URL handling: if the test case (steps or browser instruction) contains an explicit http(s):// URL, use it verbatim — do NOT rewrite it. Multi-tenant apps expose different routes on different hostnames, so substituting hosts will break tests. Only emit {BASE_URL} when the test case has no explicit URL and you need the app root.

Return ONLY a JSON object — no markdown, no code fences, no explanation outside the JSON:
{
  "actions": [ { "action": "...", ... }, ... ],
  "reasoning": "one-sentence description of the test approach"
}`;

export async function interpretSteps({ title, steps, expected_result, api_call, base_url }) {
  const prompt = [
    INSTRUCTIONS,
    '',
    '---',
    `Test case: ${title}`,
    `Steps:\n${steps || '(none provided)'}`,
    `Expected result:\n${expected_result || '(none provided)'}`,
    api_call?.match(/^browser:/i) ? `Browser instruction:\n${api_call}` : '',
    `Base URL: ${base_url}`,
  ].filter(Boolean).join('\n');

  const result = spawnSync('claude', ['-p', prompt, '--output-format', 'json'], {
    encoding: 'utf8',
    timeout: 90_000,
    maxBuffer: 2 * 1024 * 1024,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, NO_COLOR: '1' },
  });

  if (result.error) {
    throw new Error(`claude CLI not found or failed to start: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`claude CLI exited ${result.status}: ${(result.stderr || result.stdout).slice(0, 400)}`);
  }

  let responseText = result.stdout;
  try {
    const outer = JSON.parse(result.stdout);
    if (outer.is_error) throw new Error(`claude returned error: ${outer.result}`);
    responseText = outer.result ?? result.stdout;
  } catch {
    // stdout was plain text, not JSON envelope — use as-is
  }

  return parseJsonResponse(responseText);
}

function parseJsonResponse(text) {
  const t = text.trim();
  try { return JSON.parse(t); } catch {}

  // Strip markdown fences if Claude added them
  const stripped = t.replace(/```(?:json)?\s*([\s\S]*?)```/g, '$1').trim();
  try { return JSON.parse(stripped); } catch {}

  const match = stripped.match(/\{[\s\S]*\}/);
  if (match) {
    try { return JSON.parse(match[0]); } catch {}
  }

  throw new Error(`Could not parse JSON from claude response:\n${t.slice(0, 500)}`);
}
