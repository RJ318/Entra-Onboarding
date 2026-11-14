// write-run-info.mjs: CI helper. Collects this run's real results into _site/latest-run.json,
// which the demo page reads to show the latest automated run.
import { readFileSync, writeFileSync } from 'node:fs';

const env = process.env;
const pester = JSON.parse(readFileSync('_site/pester.json', 'utf8'));
const parity = readFileSync('_run/parity.txt', 'utf8').split('\n').map((l) => l.trim()).filter(Boolean);
// Drop the machine-specific "Plan saved: /home/runner/..." path; keep everything else verbatim.
const dryRun = readFileSync('_run/dry-run.txt', 'utf8').replace(/\r/g, '')
  .replace(/^Plan saved: .*\/(onboarding-plan-[^/\s]+\.csv)$/m, 'Plan saved: ./logs/$1');
const repoUrl = `${env.GITHUB_SERVER_URL}/${env.GITHUB_REPOSITORY}`;
const triggers = { push: 'push', schedule: 'weekly schedule', workflow_dispatch: 'manual run' };

writeFileSync('_site/latest-run.json', JSON.stringify({
  generatedAt: new Date().toISOString(),
  trigger: triggers[env.GITHUB_EVENT_NAME] ?? env.GITHUB_EVENT_NAME,
  commit: env.GITHUB_SHA,
  commitUrl: `${repoUrl}/commit/${env.GITHUB_SHA}`,
  runUrl: `${repoUrl}/actions/runs/${env.GITHUB_RUN_ID}`,
  pester,
  parity,
  dryRun,
}, null, 2));
console.log(`latest-run.json written: Pester ${pester.passed}/${pester.total}, parity ${parity.length} checks`);
