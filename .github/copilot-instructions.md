# Project Guidelines

## Repository Purpose

- This repository provides PowerShell 7 scripts for creating, assigning, checking, managing, and deleting Windows Server 2012/R2 Extended Security Update (ESU) licenses through Azure Arc.
- Treat ESU edition, core type, core count, activation state, program year, invoice ID, and exception handling as billing- and compliance-sensitive behavior. Do not infer or silently change licensing decisions.
- Use `README.md` and `docs/*.md` for documented behavior. The scripts in `Scripts/` are the implementation source of truth when documentation and code disagree; call out the discrepancy rather than guessing.

## Work Approach

- Start substantial or multi-step work with explicit, dependency-ordered phases. Complete and validate each phase before moving to the next; keep simple requests direct when phases would add no value.
- Use subagents for bounded research, codebase exploration, independent review, or noisy validation output when context isolation will reduce total token usage. Give each subagent a narrow question, exact scope, and required output, and do not duplicate its work in the main session without a concrete reason.
- Select the most appropriate available model for each subagent task. Prefer a fast, lower-cost model for deterministic searches, summaries, and routine validation; use a stronger reasoning model for ambiguous, cross-cutting, billing-sensitive, or complex debugging work.
- Optimize for total task cost and correctness, not merely the fewest calls. Do not delegate when coordination overhead would exceed the task, and never trade away required evidence, validation, or safety to save tokens.
- Keep the main session focused on decisions, validated evidence, integration, and user-facing results. Summarize subagent findings instead of reproducing large logs or raw exploration output.

## PowerShell And Azure Conventions

- Target PowerShell 7.x and preserve the existing direct Azure Resource Manager REST approach unless a task explicitly requires another implementation.
- Preserve public parameters, aliases, accepted values, CSV column names, output objects, exit-code behavior, and authentication options. Treat changes to these surfaces as breaking changes that require explicit approval and coordinated documentation updates.
- Continue to support both authentication paths used by the scripts: service principal credentials and user-provided `Get-AzAccessToken` token objects.
- Never print, log, persist, or include in examples real access tokens, client secrets, authorization headers, tenant IDs, subscription IDs, or other credentials. Use clearly fictitious placeholders in documentation and tests.
- Build request payloads as PowerShell objects and serialize them with `ConvertTo-Json` at an explicit depth. Do not hand-build JSON strings.
- Keep resource IDs explicit about the applicable subscription, especially in cross-subscription assignment flows. Do not assume the Arc server and ESU license share a subscription.
- Do not normalize Azure API versions across endpoints without verifying that each affected resource type supports the proposed version and payload. Ground Azure API and licensing changes in current official Microsoft documentation.
- Validate every assumption about Microsoft products, Azure APIs, Azure Arc, ESU licensing, authentication, PowerShell, and Az modules against current official Microsoft documentation. Do not guess or rely solely on memory, examples, or nearby code.
- Treat proposed explanations as hypotheses until first-party Microsoft documentation confirms them. Only a validated hypothesis may be turned into an implementation; if official documentation is unavailable or inconclusive, state the uncertainty and ask for direction instead of changing behavior.
- Follow the existing verb-noun function naming and parameter-validation patterns. Add comments only for Azure constraints or non-obvious billing, compatibility, and control-flow decisions.

## Azure Safety

- Read-only inspection is allowed. Before running any command that creates, updates, activates, assigns, unassigns, or deletes an Azure resource, state the exact action and known subscription, resource group, and resource names, then obtain explicit user approval.
- Prefer `-DryRun` or an equivalent non-mutating check when the script supports it. A successful dry run does not authorize the live operation.
- Never use a live Azure tenant as an automated validation target. Mock REST calls when adding tests.
- Preserve safeguards such as minimum core counts, even-core requirements, Arc agent version checks, resource-group license limits, and deletion warnings unless an explicitly requested change is supported by current official requirements.
- Do not broaden RBAC permissions beyond the least-privilege actions documented in this repository without explaining why and receiving approval.

## Documentation

- Update comment-based help and the relevant Markdown documentation whenever parameters, CSV schemas, authentication, API behavior, prerequisites, or examples change.
- Keep English and French counterparts synchronized in the same change when a counterpart exists. Preserve established filenames and links; do not invent a missing translation unless requested.
- Keep examples free of real customer or tenant data and show both authentication approaches when the surrounding documentation already does so.

## Validation

- For every changed `.ps1` file, run the PowerShell parser and fail validation on any parse error.
- Run `Invoke-ScriptAnalyzer` on changed PowerShell files when PSScriptAnalyzer is installed. Report when it is unavailable rather than installing it implicitly.
- Do not execute mutating scripts merely to validate syntax or parameter binding.
- When practical, add focused Pester tests for new pure functions, validation logic, CSV processing, subscription-selection rules, and request-body construction. Mock authentication and all HTTP calls.
- Review the final diff for accidental secrets, changed public interfaces, stale examples, and missing English/French documentation updates.