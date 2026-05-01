#!/usr/bin/env node
// Usage: node index.js --run-id=<uuid> [--visible|--headless] [--base-url=<url>] [--myjira=<url>]

import { parseArgs } from 'node:util';
import { fetchRun, reportResult, completeRun } from './myjira_api.js';
import { interpretSteps } from './ai_interpreter.js';
import { executeBrowserActions } from './browser_executor.js';

const { values: opts } = parseArgs({
  strict: false,
  options: {
    'run-id':   { type: 'string' },
    'myjira':   { type: 'string', default: 'http://localhost:1200' },
    'base-url': { type: 'string' },
    'visible':  { type: 'boolean', default: false },
    'headless': { type: 'boolean', default: false },
  },
});

if (!opts['run-id']) {
  console.error('Usage: node index.js --run-id=<uuid> [--visible|--headless] [--base-url=<url>] [--myjira=<url>]');
  process.exit(1);
}

const headless = !opts['visible'];
const runId = opts['run-id'];
const myjiraBase = opts['myjira'];

async function main() {
  console.log(`\nFetching run ${runId.slice(0, 8)}… from ${myjiraBase}`);
  const { run, baseUrl } = await fetchRun(runId, myjiraBase);

  const appUrl = opts['base-url'] || baseUrl;
  if (!appUrl) {
    console.error('No app base URL found. Set one on the environment in myjira, or pass --base-url=<url>');
    process.exit(1);
  }

  const pending = (run.results || []).filter(r => r.status === 'pending');
  console.log(`App URL: ${appUrl}`);
  console.log(`Mode:    ${headless ? 'headless' : 'visible browser'}`);
  console.log(`Cases:   ${pending.length} pending (${run.counts.total} total)\n`);

  if (pending.length === 0) {
    console.log('Nothing to run — all cases already have results.');
    return;
  }

  const outcomes = [];

  for (let i = 0; i < pending.length; i++) {
    const r = pending[i];
    process.stdout.write(`[${i + 1}/${pending.length}] ${r.title.slice(0, 60)}… `);

    let outcome;
    try {
      const { actions, reasoning } = await interpretSteps({
        title: r.title,
        steps: r.steps,
        expected_result: r.expected_result,
        api_call: r.api_call,
        base_url: appUrl,
      });

      outcome = await executeBrowserActions({ actions, base_url: appUrl, headless });

      if (reasoning && outcome.notes === '') {
        outcome.notes = `AI plan: ${reasoning}`;
      }
    } catch (err) {
      outcome = {
        status: 'blocked',
        actual_result: '',
        notes: `Runner error: ${err.message}`,
      };
    }

    console.log(outcome.status);
    await reportResult(runId, r.test_case_id, outcome, myjiraBase);
    outcomes.push(outcome);
  }

  const passed  = outcomes.filter(o => o.status === 'pass').length;
  const failed  = outcomes.filter(o => o.status === 'fail').length;
  const blocked = outcomes.filter(o => o.status === 'blocked').length;
  const summary = `Playwright AI runner · ${passed} passed / ${failed} failed / ${blocked} blocked out of ${pending.length}`;

  await completeRun(runId, summary, myjiraBase);

  console.log(`\n${summary}`);
  console.log(`Results: ${myjiraBase}/test_runs/${runId}`);
}

main().catch(err => {
  console.error('\nFatal:', err.message);
  process.exit(1);
});
