# herd run: <run name>

## Goal

<one sentence: what this run delivers>

Done-when: <condition herd can check, such as: every story in Scope is finished (its issue closed as completed), or its PR is Gate 1 locked, its checks passed and it waits only on <reviewer>, or its row is parked with only <stand-in> items open>

## Work plan

| Field | Value |
| - | - |
| Path | <absolute path to the work plan> |
| Owner name for next_work | <owner name as it appears in the plan> |

## People

| Role | Name | GitHub login | Slack user id | Channel |
| - | - | - | - | - |
| Stand-in | <name> | <login> | - | this herd session |
| Reviewer | <name> | <login> | <U..., or none> | <PR's Slack announcement thread, the reviewer's DM, or a PR comment> |

## Progress

Used by the plan's `post_progress`. Leave both none when Slack is off.

| Field | Value |
| - | - |
| Channel | <C..., or none> |
| Thread | <thread_ts, or none> |

## Projects in play

<short names from ~/.claude/herd/config.json, comma separated>

## Scope

The story or epic keys (`#42`, `LT-02`) this run may start. A row next_work returns outside Scope is reported as out of scope and never started. Empty means no limit.

- <KEY or epic key>

## Candidates

Used only when the plan has no next_work. Ordered.

1. <KEY>
2. <KEY>

## Settings

| Setting | Value |
| - | - |
| max_lanes | <number, or default> |
| Watch CI | <project:ref[@sha],project:ref[@sha]> (comma-separated, no spaces, sha 40 hex; empty when nothing is watched) |
| Lane ceiling | <model/effort that caps every rung, such as opus/high, or none> |

## Lanes

| Lane | Key | Project | After | Model/effort | State | PR | Announcement | Session |
| - | - | - | - | - | - | - | - | - |
| <lane-42> | <#42> | <project> | <project#n or none> | <R3 opus/high, R3 opus/high (ceiling), R3 opus/high, reviewers by tier, or the stand-in's choice> | <queued> | <project#n> | <Slack link of the PR's announcement, off when the project's Slack is off, or empty> | <session ids, newest last; pane id> |

States: queued, implementing, reviewing, pr-open, merged, finishing, finished, closed, parked.

## Usage

One row per finished story, from `herd-usage.js` over every session in the lane's Session cell.

| Key | Rungs | Turns | Input | Cache write | Cache read | Output | By model |
| - | - | - | - | - | - | - | - |
| <#42> | <R2, or R2→R3> | <assistant turns> | <tokens> | <tokens> | <tokens> | <tokens> | <model: output tokens, ...> |

## Holds

| Subject | Reason | Owner | Unparks when |
| - | - | - | - |
| <lane or PR> | <reason> | <who> | <condition> |

## Carries

| File | Goes in | Source |
| - | - | - |
| <path> | <project next PR> | <branch or path> |

## For <stand-in>

- <item only the stand-in can do or review: settings, credentials, review requests, parked work>

## Decisions

- <HH:MM> | <kind> | <KEY or PR> | <what> | <why> | <evidence>

## End-of-run summary

Write it here when Done-when holds, and give the same text as the conductor's final message in its session. Omit an empty section; back each claim with the Decisions log; re-check each "For <stand-in>" item before it goes under Needs you.

```text
🌅 **<run name>: what landed, what's waiting, what's yours**

**Done** (<reviewer> approved each, base CI green, issue closed as completed)
- <KEY> <title> → [<project> #<n>](<url>), <release if any>

**Waiting on <reviewer>**
- [<project> #<n>](<url>): <KEY>, <state in one clause>

**Needs you**
1. <emoji> <item and what to do>

**Calls I made as you**
- <decision and its reason>

**Follow-ups**
- <story key or one-line item>
```
