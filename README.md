# Entra ID New-Hire Onboarding (PowerShell 7 + Microsoft Graph)

[![CI](https://github.com/RJ318/Entra-Onboarding/actions/workflows/ci.yml/badge.svg)](https://github.com/RJ318/Entra-Onboarding/actions/workflows/ci.yml)
[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/RJ318/Entra-Onboarding?quickstart=1)

A PowerShell 7 module and script that turn an HR new-hire CSV into Microsoft Entra ID (Azure AD) accounts through the Microsoft Graph PowerShell SDK. Every row is validated, UPNs are collision-safe, the dry run comes first, and the audit log never contains a password.

## Try it

| Option | What you get | Needs |
|---|---|---|
| **[Live demo](https://rj318.github.io/Entra-Onboarding/)** | Paste or edit a new-hire CSV and watch the plan update: UPNs, groups, licenses, and every validation error. Also shows the latest automated test run. | A browser |
| **[Open in Codespaces](https://codespaces.new/RJ318/Entra-Onboarding?quickstart=1)** | The real PowerShell module in a cloud VS Code. The demo runs automatically when it opens. | A GitHub account |
| **Run locally** | `pwsh ./tools/demo.ps1` | PowerShell 7 |

The demo needs no tenant and makes no changes. All sample data is fictional (`contoso.com`).

## Runs on its own

GitHub Actions ([`ci.yml`](.github/workflows/ci.yml)) runs on every push, every pull request, every Monday morning, and on demand:

1. Runs the **27 Pester tests**.
2. Runs the **offline dry run** on the sample file and on an edge-case file.
3. Runs a **parity check**: the browser demo uses a JavaScript copy of the module's validation and planning rules, so CI builds a plan with both and fails if they differ in any of 13 fields.
4. **Republishes the live demo** with that run's real output, so the demo page always shows the latest result.

## What it handles

| Problem | How it's handled |
|---|---|
| Bad CSV rows | Every row is validated first: required fields, department and license mapping, `yyyy-MM-dd` start date, manager UPN format, 2-letter usage location. Bad rows are reported and skipped, not half-created. |
| Duplicate names | `first.last@domain`, then `first.last2`, `first.last3`… checked against the tenant **and** against earlier rows in the same CSV (two Daniel Chens in one batch). |
| Accents and punctuation | `José Martínez` → `jose.martinez`, `O'Brien` → `obrien`, `Zoë` → `zoe`. |
| Groups and licenses | Driven by `config/onboarding-config.json`: base groups for everyone, extra groups by department, license by employee type (`SPE_E3` for employees, `SPE_F1` for contractors). |
| License assignment failing | `usageLocation` is set when the user is created, since Entra ID requires it before a license can be assigned. The SKU is checked **before** creating the user. |
| Mistakes in production | `-Offline` dry run with no tenant at all; `-WhatIf` connected dry run with real collision checks; one confirmation prompt before a live run. |
| Partial failures | Each user reports `Created`, `Partial` (user exists but a group or manager step failed, with the exact step), `Failed`, `Skipped`, or `WhatIf`. |
| Passwords | Random 16-character temporary password (crypto RNG, no look-alike characters) with change-at-next-sign-in. Returned as a `SecureString`; **never written to the log or the plan file.** |
| Permissions | Connects with least-privilege scopes: `User.ReadWrite.All`, `GroupMember.ReadWrite.All`, `Organization.Read.All`. |

## Offline dry run

```powershell
./Invoke-Onboarding.ps1 -CsvPath ./sample/new-hires.csv -Offline -ExistingUpnsPath ./sample/existing-upns.txt
```

```
Onboarding plan: 9 rows · 7 ready · 2 need fixing

Row Status  UserPrincipalName         Department License Groups Errors
--- ------  -----------------         ---------- ------- ------ ------
  2 Ready   maria.alvarez@contoso.com Finance    SPE_E3       4
  3 Ready   jose.martinez@contoso.com Sales      SPE_E3       4
  4 Ready   aisha.obrien@contoso.com  Marketing  SPE_F1       4
  5 Ready   daniel.chen2@contoso.com  IT         SPE_E3       4
  6 Ready   daniel.chen3@contoso.com  Operations SPE_E3       4
  7 Ready   priya.shah2@contoso.com   Finance    SPE_E3       4
  8 Invalid                           Legal      SPE_E3       2 Department 'Legal' has no group mapping in the config.
  9 Invalid                           Sales                   4 EmployeeType 'Intern' has no license mapping in the config. StartDate '10/05/2026' must be yyyy-MM-dd.
 10 Ready   zoe.lindqvist@contoso.com Marketing  SPE_E3       4
```

## Run against a tenant

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
./Invoke-Onboarding.ps1 -CsvPath ./new-hires.csv -WhatIf     # connected dry run
$results = ./Invoke-Onboarding.ps1 -CsvPath ./new-hires.csv  # live, prompts once
```

Use a test tenant first. The groups named in the config must already exist, and each must be a security or Microsoft 365 group whose membership is assigned (dynamic groups can't take manual members).

## Tests

27 Pester 5 tests. Every Graph call goes through a small adapter (`New-GraphAdapter`), so the tests swap in a fake Graph that records each call. That way the full create → license → groups → manager flow is tested without a tenant, including `-WhatIf` making zero calls, a missing SKU stopping before any user is created, a missing group producing a `Partial` result, and the password never appearing in the audit log.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed
```

**Bugs the checks caught**

- `Test-NewHireRecord` returned its error list as one nested array (`, $problems.ToArray()`). The dry run looked fine, but any caller doing `@(Test-NewHireRecord …)` saw one item for a valid row instead of zero. The fix was to emit each error on the pipeline, the idiomatic PowerShell way.
- The edge-case file showed that a blank `Department` cell printed a stray "argument 'name' is not valid" error, because the property lookup was handed an empty name. Lookups now treat an empty name as "not found".

**Status:** tested with Pester against a fake Graph adapter, dry-run tested end to end, and run live in a Microsoft 365 developer (test) tenant. It has never been run against a production tenant.

## Files

```
├── Invoke-Onboarding.ps1          entry script: plan → review → create → log
├── src/EntraOnboarding.psm1       module: validation, UPNs, passwords, plan, Graph calls, log
├── src/EntraOnboarding.psd1       module manifest
├── config/onboarding-config.json  domain, groups by department, license by employee type
├── sample/                        fictional new-hire files with collisions and bad rows on purpose
├── tests/EntraOnboarding.Tests.ps1
├── tools/demo.ps1                 one-command offline demo
├── tools/check-parity.mjs         proves the browser demo matches the PowerShell output
├── site/                          live demo page (published by CI to GitHub Pages)
├── .github/workflows/ci.yml       tests, dry runs, parity, and publishing
└── .devcontainer/                 Codespaces setup (PowerShell 7 + Pester)
```

## Why I built it

At Zelis I improved our new-hire onboarding and offboarding workflow and used AI to write and debug PowerShell for Active Directory and Entra ID account tasks. This project rebuilds that kind of onboarding flow from scratch in a form I can show: a module with tests instead of one-off scripts.

## How AI helped

I used Claude as a coding partner to draft and debug the PowerShell, the same way I use AI tools on the job. I set the requirements from onboarding work I have done: validate before touching the tenant, never log passwords, handle two people with the same name, and show a dry run first. The design choice that made testing possible (wrapping Graph calls in a swappable adapter) was the AI's suggestion. The tests are how I confirmed it held up, and they caught a real bug in the AI-drafted code.

---

Ravi S. Jethva · [LinkedIn](https://www.linkedin.com/in/rj318) · [GitHub](https://github.com/RJ318) · MIT License
