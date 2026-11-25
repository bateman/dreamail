# Project instructions

## Communication style: concise

This applies to every conversation in a session: replies to the owner, reports
to the orchestrator, and messages between sessions.

- Lead with the result or the decision needed. No preamble, no recap of the request.
- Say only what the reader needs to act: what changed, what is verified, what is
  not, what is blocked. Leave out the story of how you got there.
- Short sentences, plain words. A few bullets at most; a table only for
  enumerable facts.
- One status line while working, not a running commentary.
- Ask a question only when it blocks the work, and ask it once.
- Details (logs, long lists, design notes) go in the PR body, not in chat.
- Never trade accuracy for brevity: failures, skipped steps and unverified
  claims are always stated.

The owner writes in Italian: answer the owner in Italian. Code, commits, PR
texts and repository documents follow the language already used in each file.

## Process: review tiers

The orchestrator picks one tier per task, from the owner's request. When in
doubt between two tiers, it uses the stricter one and says which it chose.

| Tier | When | Model | Reviews | CI and merge |
|---|---|---|---|---|
| Simple | A trivial change: one property, a colour, a size, a label. | Sonnet | None. | Merged straight into `main`, without waiting for CI. |
| Low risk | Not complex and with a low security risk (no auth, network, storage, deletion, logging, CI or dependency changes). | Sonnet | `ponytail-review` in `full` mode only; no security audit. | Regular pull request, merged on green CI. |
| Standard | Everything else. | Opus, medium effort | `ponytail-review` in `full` mode and the security audit, in parallel. | Regular pull request, merged on green CI. |

- `ponytail-review` runs in `full` mode, no longer `ultra`.
- A Simple change is still checked after the merge: the full CI run on `main`
  must be green, and a red run is fixed at once.

## Product default: do as Gmail does

When a request leaves a choice open and an assumption is needed (behaviour,
defaults, wording, placement, what a setting applies to), take what Gmail
does, on the web first, as the assumption. State the assumption in the same
message that starts the work, and do not stop to ask.

Decisions already recorded in `docs/registro-decisioni.md` come first: where
one of them differs from Gmail on purpose (for example generic notifications
by default, or "deleted means gone"), it stands.

## Commits: no personal e-mail addresses

The owner keeps his e-mail addresses private on GitHub and has push
protection on for commits that expose them. A commit made in a session uses
the session's own author identity; no commit, trailer, file or pull request
text carries one of the owner's personal addresses. Where the owner must be
named as author, use `bateman@users.noreply.github.com`.
