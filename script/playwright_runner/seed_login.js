#!/usr/bin/env node
// One-shot helper to log into a target app via its /login form and dump a
// Playwright storageState.json. browser_executor.js will then use it via
// newContext({ storageState }) so every case starts authenticated.
//
// Usage:
//   node seed_login.js \
//     --app=http://localhost:8088 \
//     --email=test@ownsite.io \
//     --password=password123 \
//     --out=/tmp/ownsites_storage_state.json \
//     [--login-path=/login] \
//     [--email-selector="input[name=email], input[type=email]"] \
//     [--password-selector="input[name=password], input[type=password]"] \
//     [--submit-selector="button[type=submit]"] \
//     [--success-url-contains=/dashboard]
//
// Exits 0 on success, prints the path to the saved state.

import { parseArgs } from 'node:util';
import { chromium } from 'playwright';

const { values: o } = parseArgs({
  strict: false,
  options: {
    app:                    { type: 'string' },
    email:                  { type: 'string' },
    password:               { type: 'string' },
    out:                    { type: 'string' },
    'login-path':           { type: 'string', default: '/login' },
    'email-selector':       { type: 'string', default: 'input[name=email], input[type=email]' },
    'password-selector':    { type: 'string', default: 'input[name=password], input[type=password]' },
    'submit-selector':      { type: 'string', default: 'button[type=submit]' },
    'success-url-contains': { type: 'string', default: '' },
  },
});

for (const k of ['app', 'email', 'password', 'out']) {
  if (!o[k]) { console.error(`missing --${k}`); process.exit(1); }
}

const app = o.app.replace(/\/$/, '');
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
page.setDefaultTimeout(20_000);

try {
  await page.goto(app + o['login-path'], { waitUntil: 'domcontentloaded' });
  await page.fill(o['email-selector'], o.email);
  await page.fill(o['password-selector'], o.password);
  await Promise.all([
    page.waitForURL((url) => !url.toString().endsWith(o['login-path']), { timeout: 15_000 }).catch(() => {}),
    page.click(o['submit-selector']),
  ]);
  // Allow the SPA a moment to write tokens to localStorage.
  await page.waitForTimeout(1000);
  if (o['success-url-contains'] && !page.url().includes(o['success-url-contains'])) {
    console.error(`login may have failed — url is ${page.url()}, expected to contain ${o['success-url-contains']}`);
  }
  await context.storageState({ path: o.out });
  console.log(`storageState saved → ${o.out}`);
  console.log(`final url: ${page.url()}`);
} finally {
  await browser.close();
}
