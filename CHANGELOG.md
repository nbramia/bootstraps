# Changelog

All notable changes to the bootstraps marketplace will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Codex manifest and marketplace validation in `validate-all.sh`
- Pi package metadata and installation guidance for `implement-lifecycle`; Pi users can discover its shared skills and delegate through their separately installed `pi-subagents`
- `tools/ship`: the `ship` and `ship-notice` commands, their tests, an installer and a sample `ship.conf`

### Changed

- Documented the repository's Claude Code/Codex compatibility matrix and installation flows
- `implement-lifecycle` 3.9.2 now delegates every heavy phase through generic isolated subagents that explicitly invoke the canonical worker skills, removing the distributed Claude Code worker templates
- `implement-lifecycle` 3.10.0 defines its phase-to-skill mapping once and applies it through Claude Code, Codex, Pi, and generic isolated-delegation adapters
- `implement-lifecycle` 3.10.19 and `implement-team` 0.5.1 reviewers read `AGENTS.md` as well as `CLAUDE.md` for project conventions
- The repository is canonical at `nbramia/bootstraps`: install commands and the marketplace owner point there, and installing needs no private-repo access or `GITHUB_TOKEN`

## implement-lifecycle [4.0.0] - 2026-11-02

### Changed

- **BREAKING:** `implement` is a short orchestration skill: build in a subagent, have another model family try to break the change, judge the findings, record them on the PR, verify for real, and land with `ship`
- `validate-all.sh` checks the one remaining skill, its Codex metadata and its Pi package

### Removed

- **BREAKING:** the `review-architecture`, `review-correctness`, `review-docs`, `review-general`, `review-security`, `review-testing`, `implement-code`, `implement-address`, `verify`, `merge-pr` and `pr-check` skills, and the lifecycle suite capability declarations

## implement-team [0.5.0] - 2026-07-26

### Deprecated

- `implement-team` is deprecated in favour of `implement-lifecycle` (`/implement`). It remains installable but is unmaintained, receives no fixes, and will be removed in a future release

## implement-cli [1.4.1] - 2026-07-26

### Changed

- Marked work-in-progress and not recommended for general use; `implement-lifecycle` (`/implement`) is the supported lifecycle plugin

## second-opinion [2.2.1] - 2026-07-23

### Fixed

- Removed the hidden external `dirname` startup dependency when running with a restricted `PATH`

## implement-lifecycle [3.4.0] - 2026-07-22

### Added

- Native Codex plugin metadata, marketplace publication, and delegated reviewer skill adapters

### Changed

- Lifecycle delegation now uses explicit Claude Code named subagents or Codex subagents loading plugin-qualified skills
- Worker skills no longer depend on implicit fork metadata and remain reusable across clients

## implement-lifecycle [3.3.2] - 2026-07-22

### Changed

- Adversarial review now requires proportional remedies, a convergence stop after three non-clean rounds dominated by review-introduced complexity, and a five-round default cap unless the user explicitly authorizes more

## bootstrap-docs [1.4.1] - 2026-07-22

### Added

- Native Codex plugin metadata for the existing documentation bootstrap skill

## issue-management [1.1.1] - 2026-07-22

### Added

- Native Codex plugin metadata for the existing issue drafting, cleanup, and refinement skills

## issue-management [1.1.0] - 2026-07-19

### Changed

- `draft-issue`: new "Writing at the Right Altitude" guidance — issues descend through behavior/design/implementation layers, with locational detail confined to Technical Context and PR decomposition tables (Acceptance Criteria may name the contract under test); template sections annotated with their altitude; optional History section for provenance; validation checklist gains altitude, skim-test, and sentence-discipline checks
- `refine-issue`: refinement adds depth at the right layer instead of pushing `file:line` references into Problem/Solution; acceptance-criteria example no longer embeds file references; validation gains altitude and skim-test checks
- `cleanup-issue`: new Altitude quality dimension and "Altitude Fixes" step (3d) that moves misplaced code identifiers, split-worthy sentences, mid-clause citations, and discovery narrative to their proper homes

## implement-lifecycle [3.3.0] - 2026-07-19

### Changed

- `implement-code`: PR body template restructured into descending altitude layers — plain-language TL;DR (no code identifiers) → Design → Implementation Notes → Test evidence → Review focus — with inline altitude, citation, and skim-test rules
- `pr-check`: check 3 now fails descriptions that open with implementation bullets instead of a plain-language TL;DR; new check 8 validates altitude layering (rubric is now 8 checks)

## second-opinion [1.0.1] - 2026-07-18

### Added

- ADR-001 (`docs/adr/001-task-delegation-privilege-model.md`): task-delegation substrate choice, `consult`/`act-sandboxed`/`act-full` privilege tiers, three-boundary enforcement model, pinned `sandbox-runtime` wrapper, fail-closed posture, allowlist ownership, and risk register (issue #77)
- README security section cross-links ADR-001 and notes the consult-to-delegate roadmap

## implement-cli [1.1.4] - 2026-03-15

### Added

- `--version` global flag that reads version from `plugin.json` at runtime
- Validation for `--max-cost` (must be positive and finite) and `--max-depth` (must be >= 1)
- Unit tests for version flag, argument validation, NaN/inf edge cases, and fallback paths

## implement-cli [1.1.2] - 2026-03-15

### Fixed

- SKILL.md path resolution: replaced `$(dirname "$0")` (invalid in skill context) with Glob-based discovery
- `validate-all.sh` now works from any directory via `cd "$(dirname "${BASH_SOURCE[0]}")"` guard

## bootstrap-docs [1.2.0] - 2026-03-10

### Added

- Changelog template asset following Keep a Changelog format
- Changelog document type in strategy template taxonomy

## implement-lifecycle [2.1.0] - 2026-02-26

### Added

- Full implementation lifecycle with adversarial PR review
- Plan, implement, PR, review/address loop, merge workflow
- Specialist reviewer agents (correctness, security, architecture, testing)
- Referee evaluation and filtered action plans
- Draft-issue skill for creating well-structured GitHub issues
- PR-check skill for validating PRs against standards
- Merge-pr skill with issue update automation
- Verify skill for end-to-end verification

## bootstrap-worktrees [1.0.0] - 2026-02-24

### Added

- Setup skill for project-agnostic worktree isolation
- Per-worktree port allocation and Docker Compose project templates
- Script templates for worktree lifecycle management

## bootstrap-docs [1.1.0] - 2026-02-22

### Added

- Implementation sequence guidance in Phase 6 summary
- Audit mode for re-run progress tracking

### Changed

- Phase 6 summary now includes ordered workflow as actionable next steps
