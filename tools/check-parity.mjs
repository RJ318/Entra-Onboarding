// check-parity.mjs: proves the browser demo follows the same rules as the PowerShell module.
//
//   node tools/check-parity.mjs <new-hires.csv> <existing-upns.txt> <plan-from-pwsh.csv> [config.json]
//
// Builds a plan with site/onboarding-rules.js and compares it, field by field, with the plan CSV
// that Invoke-Onboarding.ps1 -Offline wrote for the same input. Exits 1 on any difference.
import { readFileSync } from 'node:fs';
import { buildPlan, parseCsv, parseExistingUpns } from '../site/onboarding-rules.js';

const [csvPath, existingPath, pwshPlanPath, configPath = 'config/onboarding-config.json'] = process.argv.slice(2);
if (!csvPath || !existingPath || !pwshPlanPath) {
  console.error('usage: node tools/check-parity.mjs <new-hires.csv> <existing-upns.txt> <plan-from-pwsh.csv> [config.json]');
  process.exit(2);
}

const config = JSON.parse(readFileSync(configPath, 'utf8'));
const records = parseCsv(readFileSync(csvPath, 'utf8'));
const existing = parseExistingUpns(readFileSync(existingPath, 'utf8'));
const jsPlan = buildPlan(records, config, existing);
const psPlan = parseCsv(readFileSync(pwshPlanPath, 'utf8'));

const fields = ['Row', 'Status', 'Errors', 'DisplayName', 'UserPrincipalName', 'Department', 'JobTitle',
  'EmployeeType', 'StartDate', 'ManagerUpn', 'UsageLocation', 'License', 'Groups'];
const norm = (v) => (v == null ? '' : Array.isArray(v) ? v.join('; ') : String(v));

const diffs = [];
if (jsPlan.length !== psPlan.length) diffs.push(`row count: js=${jsPlan.length} pwsh=${psPlan.length}`);
for (let i = 0; i < Math.min(jsPlan.length, psPlan.length); i++) {
  for (const f of fields) {
    const a = norm(jsPlan[i][f]);
    const b = norm(psPlan[i][f]);
    if (a !== b) diffs.push(`row ${psPlan[i].Row} ${f}: js=${JSON.stringify(a)} pwsh=${JSON.stringify(b)}`);
  }
}

if (diffs.length) {
  console.error(`PARITY FAILED for ${csvPath} (${diffs.length} differences)`);
  for (const d of diffs) console.error('  ' + d);
  process.exit(1);
}
const ready = jsPlan.filter((p) => p.Status === 'Ready').length;
console.log(`Parity OK: ${csvPath}: ${jsPlan.length} rows (${ready} ready, ${jsPlan.length - ready} invalid) match the PowerShell plan on all ${fields.length} fields.`);
