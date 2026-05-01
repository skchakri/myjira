export async function fetchRun(runId, base) {
  const res = await fetch(`${base}/api/v1/test_runs/${runId}`);
  if (!res.ok) throw new Error(`fetchRun ${res.status}: ${await res.text()}`);
  const run = await res.json();
  return { run, baseUrl: run.base_url };
}

export async function reportResult(runId, testCaseId, outcome, base) {
  const body = {
    status: outcome.status,
    actual_result: outcome.actual_result || '',
    notes: outcome.notes || '',
  };
  const res = await fetch(`${base}/api/v1/test_runs/${runId}/results/${testCaseId}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`reportResult ${res.status}: ${await res.text()}`);
  return res.json();
}

export async function completeRun(runId, summary, base) {
  const res = await fetch(`${base}/api/v1/test_runs/${runId}/complete`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ summary }),
  });
  if (!res.ok) throw new Error(`completeRun ${res.status}: ${await res.text()}`);
  return res.json();
}
