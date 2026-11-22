# Documentation rule

Owner requirement (2026-10-13): everything done in this project must be documented well enough that
someone else can rebuild the whole project on another network without the original author.

Therefore, for every component and decision:

- What it is and why it exists (ADR for decisions).
- Exact prerequisites (versions of tools and modules, accounts, permissions, network paths).
- Exact steps to install and configure it, in order, with the commands and the expected result of each.
- Every value that differs per environment, and where it is set (no hidden defaults).
- How to verify it works (commands, expected output) and how to roll it back.
- What was NOT verified and what assumptions were made (so the next person tests them first).
- Known failure modes and what to do about them (runbooks).

Items already queued for the final documentation are listed in `docs/open-questions.md`
(section "Deferred explanations") and `docs/readiness-gaps.md`.
