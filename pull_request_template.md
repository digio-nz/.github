<!-- Target: about 30 content lines, roughly 500 words, excluding headings and blank lines.
     These are targets, not limits. Use one short sentence or bullet per line. -->

## What

<!-- Target: about 3 lines. One paragraph a non-engineer can read: what changed and why. -->

## Decisions

<!-- Target: about 4 lines. Decisions this change makes, or "None". -->

## Closes

<!-- Target: about 1 line. The issue this PR delivers, with a closing keyword so it closes on merge.
     A Phase PR closes its Phase; the Plan closes when the last phase lands.
     For an issue branch, replace the placeholder with Closes #n from its issue-n segment.
     Preserve that closing line when refreshing the PR body, including a pipeline rerun.
     For a chore branch with no issue, replace the placeholder with None. -->

Closes #

## Evidence

<!-- Target: about 10 lines. Evidence, not assertion. The reviewer reads this.
     Put long output and evidence in a PR comment and link it here.
     - Name this repo's verification commands and give short results; AGENTS.md names the commands.
     - Say what you exercised in the running application and what you saw.
       A passing suite alone is not evidence the behaviour is right.
     - Name the regression test and the CI job that runs it.
       State any skip condition, advisory-only coverage, or unverified scenario. -->

## Findings not fixed

<!-- Target: about 3 lines. Defects observed and left. Fix on sight when one line here explains it and it needs
     no test strategy of its own; otherwise it lands here, with evidence.
     Delete this section when empty. -->

## AGENTS.md change needed

<!-- Target: about 3 lines.
     A worker never edits AGENTS.md or CLAUDE.md: name the file, the exact text to change and why, for the orchestrator.
     Delete this section when empty. -->

## Declarations

<!-- Target: about 2 lines. Only when they apply; delete the rest.
     - Touches schema, auth or secrets: say what any migration does and when it runs.
     - Deferred something: say what, and why deferring is safe. -->

shipped-via:
