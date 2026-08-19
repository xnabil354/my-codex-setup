---
name: antislop-ui
description: Audit, design, implement, and improve UI/UX using the antislop v2.2.0 core and official antislop-ui visual skill. Use for websites, web apps, dashboards, frontend interfaces, React Native apps, mobile UI, components, layouts, visual design, motion, and UI quality reviews.
---

# antislop-ui

Use the antislop v2.2.0 system for UI and visual work.

This Codex skill is a wrapper around:

- `references/antislop.md` — antislop v2.2.0 core
- `references/antislop-ui.md` — antislop-ui v2.2.0 UI/Visual skill

The upstream files are authoritative.

## Mandatory loading order

For every invocation of this skill:

1. Read `references/antislop.md`.
2. Read `references/antislop-ui.md`.
3. Look for `DESIGN.md` in the current project.
4. Look for relevant project instructions in `AGENTS.md`.
5. Inspect the existing design system before proposing UI changes.

Never use `antislop-ui.md` without the core.

## Design direction

antislop is a filter, not a style guide.

If `DESIGN.md` exists:

- treat it as project-specific visual direction
- preserve legitimate brand decisions
- use antislop as a quality filter

If DESIGN.md does not exist, do not fabricate brand direction silently.

Use existing product identity and explicit user requirements when available.

## Usage modes

The antislop system supports two modes.

### Mode 1 — DURING

Use when designing or implementing UI.

Workflow:

requirements
→ project inspection
→ DESIGN.md
→ antislop core
→ antislop-ui
→ implementation
→ validation
→ UI Skill Checklist
→ Core Delivery Gate

### Mode 2 — AFTER

Use for auditing existing UI.

In AFTER mode:

1. Inspect first.
2. Do not modify files during the initial audit.
3. Produce numbered findings.
4. Cite the relevant R-XX rule.
5. Assign realistic priority/severity.
6. Explain the evidence and impact.
7. Recommend a fix.
8. Wait for user approval.
9. Modify only approved findings.
10. Re-run the UI Skill Checklist and Core Delivery Gate.

## Mode resolution

If the user explicitly writes:

- `1`
- `DURING`

use DURING.

If the user explicitly writes:

- `2`
- `AFTER`

use AFTER.

If intent is already unambiguous, do not ask unnecessary questions.

For example:

"Audit this existing UI and do not change anything"

clearly means AFTER.

## UI audit scope

When relevant inspect:

- layout
- visual hierarchy
- typography
- color
- spacing
- border radius
- elevation
- shadows
- gradients
- glass effects
- components
- cards
- buttons
- forms
- navigation
- icons
- decorative elements
- content hierarchy
- responsive behavior
- mobile behavior
- animation and motion
- loading states
- empty states
- errors
- disabled states
- accessibility
- functional completeness

## React Native interpretation

For React Native/mobile apps, translate web-specific rules into their
native-mobile equivalent when reasonable.

Audit:

- SafeArea
- Android status/navigation bars
- touch targets
- scrolling
- clipping
- keyboard avoidance
- navigation
- screen density
- orientation where supported
- accessibility labels
- form interactions
- loading/error/empty states
- responsive/adaptive layouts

Do not force CSS/web implementation concepts where they do not apply.

Mark genuinely irrelevant rules as Not Applicable.

## UI-specific checklist

Before completing UI work, run the checklist defined at the end of
`references/antislop-ui.md`.

The UI Skill Checklist supplements the core Delivery Gate.

It does not replace it.

## Delivery Gate

Before declaring UI work complete:

1. Run the antislop-ui checklist.
2. Run the core antislop Delivery Gate.
3. Report PASS / FAIL / N/A with concrete evidence.
4. Do not claim PASS if mandatory checks failed.

## Audit output

For AFTER mode, use stable finding identifiers:

ASUI-001
ASUI-002
ASUI-003
...

Each finding should contain:

- Severity
- Relevant R-XX rule
- File
- Screen/component
- Evidence
- Problem
- Why it matters
- Recommended fix
- Estimated scope

Prioritize:

CRITICAL
HIGH
MEDIUM
LOW

Avoid duplicate findings that share one root cause.

## Scope discipline

Do not redesign unrelated screens while resolving an approved finding.

Do not refactor unrelated backend, database, infrastructure, or business
logic merely because this skill was invoked.

## Completion criteria

UI work is complete only when:

- requested scope has been addressed
- applicable core rules were checked
- applicable UI patterns were checked
- the UI Skill Checklist was run
- the Core Delivery Gate was run
- remaining limitations are reported truthfully