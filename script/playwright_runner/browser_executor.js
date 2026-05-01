import { chromium } from 'playwright';
import { existsSync } from 'node:fs';

export async function executeBrowserActions({ actions, base_url, headless = true }) {
  const browser = await chromium.launch({ headless });
  // Optional: pre-seeded auth state (cookies + localStorage) so cases start
  // already logged in. Set STORAGE_STATE_FILE to a path produced by
  // seed_login.js. Missing or unreadable files fall back to a clean context.
  const storagePath = process.env.STORAGE_STATE_FILE;
  const ctxOpts = storagePath && existsSync(storagePath) ? { storageState: storagePath } : {};
  const context = await browser.newContext(ctxOpts);
  const page = await context.newPage();
  page.setDefaultTimeout(30_000);

  const log = [];
  const resolveUrl = (raw) => (raw || '').replace('{BASE_URL}', base_url.replace(/\/$/, ''));

  try {
    for (const step of actions) {
      switch (step.action) {
        case 'navigate':
          await page.goto(resolveUrl(step.url), { waitUntil: 'domcontentloaded' });
          log.push(`navigate → ${resolveUrl(step.url)}`);
          break;

        case 'fill':
          await page.fill(step.selector, step.value ?? '');
          log.push(`fill ${step.selector} = "${step.value}"`);
          break;

        case 'click':
          await page.click(step.selector);
          log.push(`click ${step.selector}`);
          break;

        case 'check':
          await page.check(step.selector);
          log.push(`check ${step.selector}`);
          break;

        case 'uncheck':
          await page.uncheck(step.selector);
          log.push(`uncheck ${step.selector}`);
          break;

        case 'select_option':
          await page.selectOption(step.selector, step.value);
          log.push(`select ${step.selector} → "${step.value}"`);
          break;

        case 'type':
          await page.keyboard.type(step.text ?? '');
          log.push(`type "${step.text}"`);
          break;

        case 'hover':
          await page.hover(step.selector);
          log.push(`hover ${step.selector}`);
          break;

        case 'wait_ms':
          await page.waitForTimeout(step.ms ?? 500);
          log.push(`wait ${step.ms}ms`);
          break;

        case 'wait_for_selector':
          await page.waitForSelector(step.selector);
          log.push(`wait_for_selector ${step.selector}`);
          break;

        case 'wait_for_url':
          await page.waitForURL(`**${step.contains}**`);
          log.push(`wait_for_url contains "${step.contains}"`);
          break;

        case 'assert_url': {
          const current = page.url();
          if (!current.includes(step.contains)) {
            throw new Error(`URL assertion failed: expected "${step.contains}" in "${current}"`);
          }
          log.push(`assert_url ✓ (${step.contains})`);
          break;
        }

        case 'assert_text': {
          const el = await page.locator(step.selector).first();
          const text = await el.innerText();
          if (!text.includes(step.contains)) {
            throw new Error(`Text assertion failed: "${step.selector}" text "${text}" does not contain "${step.contains}"`);
          }
          log.push(`assert_text ✓ ${step.selector} contains "${step.contains}"`);
          break;
        }

        case 'assert_visible':
          await page.waitForSelector(step.selector, { state: 'visible', timeout: 10_000 });
          log.push(`assert_visible ✓ ${step.selector}`);
          break;

        case 'assert_not_visible':
          await page.waitForSelector(step.selector, { state: 'hidden', timeout: 10_000 });
          log.push(`assert_not_visible ✓ ${step.selector}`);
          break;

        case 'screenshot':
          log.push('screenshot (auto-captured at end)');
          break;

        default:
          log.push(`unknown action "${step.action}" — skipped`);
      }
    }

    return {
      status: 'pass',
      actual_result: log.join('\n'),
      notes: '',
    };

  } catch (err) {
    return {
      status: 'fail',
      actual_result: log.join('\n'),
      notes: err.message,
    };

  } finally {
    await browser.close();
  }
}
