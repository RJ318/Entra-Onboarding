// onboarding-rules.js
// A JavaScript mirror of the validation and planning rules in src/EntraOnboarding.psm1
// (Test-NewHireRecord, ConvertTo-UpnSafeName, New-UniqueUpn, Get-OnboardingPlan).
//
// It powers the browser demo only. The PowerShell module is the real tool.
// CI runs both on the same CSV files and fails the build if their plans differ
// (tools/check-parity.mjs), so this file cannot drift from the module unnoticed.

// PowerShell property lookups are case-insensitive, so config keys are matched that way too.
function lookup(obj, key) {
  if (obj == null || key == null) return undefined;
  const wanted = String(key).toLowerCase();
  for (const k of Object.keys(obj)) {
    if (k.toLowerCase() === wanted) return obj[k];
  }
  return undefined;
}

const isBlank = (v) => v == null || String(v).trim() === '';
const str = (v) => (v == null ? '' : String(v));

export function upnSafeName(name) {
  return str(name)
    .normalize('NFD')
    .replace(/\p{Mn}/gu, '')          // drop accents (NonSpacingMark), like FormD + filter in .NET
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, '')
    .replace(/^-+|-+$/g, '');
}

function isValidIsoDate(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (y < 1 || mo < 1 || mo > 12 || d < 1) return false;
  const daysInMonth = new Date(Date.UTC(2000, mo, 0)).getUTCDate(); // leap-safe base year
  const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const max = mo === 2 ? (leap ? 29 : 28) : daysInMonth;
  return d <= max;
}

export function validateRecord(record, config) {
  const problems = [];
  for (const field of ['FirstName', 'LastName', 'Department', 'JobTitle', 'EmployeeType', 'StartDate']) {
    if (isBlank(lookup(record, field))) problems.push(`${field} is required.`);
  }

  const dept = str(lookup(record, 'Department'));
  if (dept && lookup(config.DepartmentGroups, dept) === undefined) {
    problems.push(`Department '${dept}' has no group mapping in the config.`);
  }

  const type = str(lookup(record, 'EmployeeType'));
  if (type && lookup(config.LicenseByEmployeeType, type) === undefined) {
    problems.push(`EmployeeType '${type}' has no license mapping in the config.`);
  }

  const start = str(lookup(record, 'StartDate'));
  if (start && !isValidIsoDate(start)) problems.push(`StartDate '${start}' must be yyyy-MM-dd.`);

  const mgr = str(lookup(record, 'ManagerUpn'));
  if (mgr && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/i.test(mgr)) problems.push(`ManagerUpn '${mgr}' isn't a valid UPN.`);

  const loc = str(lookup(record, 'UsageLocation'));
  if (loc && !/^[A-Za-z]{2}$/.test(loc)) problems.push(`UsageLocation '${loc}' must be a 2-letter country code.`);

  return problems;
}

export function uniqueUpn(firstName, lastName, domain, isTaken, maxAttempts = 50) {
  const first = upnSafeName(firstName);
  const last = upnSafeName(lastName);
  if (!first || !last) throw new Error(`Can't build a UPN from '${firstName} ${lastName}'.`);

  let base = `${first}.${last}`;
  if (base.length > 60) base = base.substring(0, 60).replace(/[.-]+$/, '');

  for (let i = 1; i <= maxAttempts; i++) {
    const candidate = i === 1 ? `${base}@${domain}` : `${base}${i}@${domain}`;
    if (!isTaken(candidate)) return candidate;
  }
  throw new Error(`No free UPN for '${base}' after ${maxAttempts} attempts.`);
}

// existingUpns: iterable of UPNs already in the tenant (case-insensitive), like -ExistingUpnsPath.
export function buildPlan(records, config, existingUpns = []) {
  const existing = new Set([...existingUpns].map((u) => String(u).trim().toLowerCase()).filter(Boolean));
  const claimed = new Set();
  const taken = (upn) => claimed.has(upn.toLowerCase()) || existing.has(upn.toLowerCase());

  return records.map((r, i) => {
    const errors = validateRecord(r, config);
    const first = str(lookup(r, 'FirstName')).trim();
    const last = str(lookup(r, 'LastName')).trim();
    const dept = str(lookup(r, 'Department')).trim();
    const type = str(lookup(r, 'EmployeeType')).trim();

    let upn = null;
    if (errors.length === 0) {
      try {
        upn = uniqueUpn(first, last, config.Domain, taken);
        claimed.add(upn.toLowerCase());
      } catch (e) {
        errors.push(e.message);
      }
    }

    const deptGroups = [].concat(lookup(config.DepartmentGroups, dept) ?? []).filter(Boolean);
    const usage = str(lookup(r, 'UsageLocation')).trim();
    return {
      Row: i + 2, // header is row 1
      Status: errors.length ? 'Invalid' : 'Ready',
      Errors: errors.join(' '),
      DisplayName: `${first} ${last}`.trim(),
      UserPrincipalName: upn,
      Department: dept,
      JobTitle: str(lookup(r, 'JobTitle')).trim(),
      EmployeeType: type,
      StartDate: str(lookup(r, 'StartDate')).trim(),
      ManagerUpn: str(lookup(r, 'ManagerUpn')).trim(),
      UsageLocation: usage ? usage.toUpperCase() : config.UsageLocation,
      License: lookup(config.LicenseByEmployeeType, type) ?? null,
      Groups: [...[].concat(config.BaseGroups ?? []), ...deptGroups],
    };
  });
}

// Minimal RFC 4180 CSV parser (quoted fields, escaped quotes, CRLF), enough for HR exports.
export function parseCsv(text) {
  const rows = [];
  let row = [], field = '', q = false;
  const src = text.replace(/^﻿/, '');
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (q) {
      if (c === '"') {
        if (src[i + 1] === '"') { field += '"'; i++; } else q = false;
      } else field += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && src[i + 1] === '\n') i++;
      row.push(field); rows.push(row); row = []; field = '';
    } else field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  const nonEmpty = rows.filter((r) => r.some((v) => v !== ''));
  if (!nonEmpty.length) return [];
  const header = nonEmpty[0].map((h) => h.trim());
  return nonEmpty.slice(1).map((cells) => {
    const o = {};
    header.forEach((h, idx) => { o[h] = cells[idx] ?? ''; });
    return o;
  });
}

// Reads an "already in the tenant" list the same way Invoke-Onboarding.ps1 -ExistingUpnsPath does:
// one UPN per line, blank lines and # comments ignored.
export function parseExistingUpns(text) {
  return String(text)
    .split(/\r?\n/)
    .filter((line) => line && !/^\s*#/.test(line))
    .map((line) => line.trim())
    .filter(Boolean);
}
