# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

Because issues are local markdown files, a "label" is the value on the `Status:` line near the top of the issue file — not a tracker-side label object.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

## `done` — the terminal state, and only a human writes it

Beyond the five roles this repo uses one more value, and it was in the files long before it was in this table:

| Label | Meaning |
| ----- | ------- |
| `done` | Finished **and accepted**. Set by the human, never by an agent. |

The rule behind it is the point. An agent that finishes a ticket sets `ready-for-human`, not `done`: «сделано» must not be the worker's own opinion of its own work. `done` is what the person says after they have looked — and in this project that has meant a live run, not a green test suite. Twenty-two tickets went from `ready-for-human` to `done` in one edit on 11 August 2026, after the MVP was walked end to end.

A ticket in `done` is not a record of a task; it is where the archaeology lives — the measured numbers, the wrong turns, the reason a threshold is 0.83 and not 0.9. Statuses are hygiene; the body is the value.

Edit the right-hand column to match whatever vocabulary you actually use.
