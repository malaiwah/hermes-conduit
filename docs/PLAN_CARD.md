# Plan card

A small floating card at the top right of an open chat shows what the
agent is working through right now: its plan, titled "Tasks". It isn't
shown in a chat that has none.

(An artifact card that popped up for new files was tried with it and
dropped on the owner's review, 2026-10-22.)

## What Hermes sends (checked against Hermes 0.21.0, tag v2026.8.31)

Hermes has one planning tool, `todo` (`tools/todo_tool.py`):

- Arguments: `todos: [{id, content, status, parent?}]` and `merge: bool`.
  `merge: false` (the default) replaces the list; `merge: true` updates
  items by id and appends new ones. No `todos` reads the list.
- Statuses: `pending`, `in_progress`, `completed`, `cancelled`. List order
  is priority. `parent` nests a subtask under another item.
- **Every call returns the full list** as JSON:
  `{"todos": [...], "revision": N, "summary": {...}}`. The revision goes up
  by one on every write that changes the list. An error returns
  `{"error": ...}`.
- The gateway always sends `tool.start` / `tool.complete` for `todo`,
  even with tool progress turned off, and the completion's `result` is that
  full list. It also sends a `todo.updated` event with the same snapshot.
- `session.resume` attaches `todo_state: {todos, revision}`. The gateway
  works it out from the latest `todo` result in the whole stored history,
  not only the page Conduit loads.

Other things named "plan" in Hermes (the `plan-mode` plugin, `/plan`
prompts, billing plans) aren't task lists. Subagents keep their own
`todo` lists, and those don't reach the parent chat's events.

## Working out the current plan

Each source below takes over from the one before it:

1. **The transcript.** Walking back from the newest `todo` row:
   - A row whose output is a full list is the plan. Stop there.
   - A row with no output yet (still running, or a compact resume row)
     uses its arguments. A replace write is a full list, so stop there. A
     merge write is kept and applied on top of the full list found further
     back.
   - A read call, or an error, is skipped.

   This is the "find the last full plan, then replay the updates after it"
   walk. Since Hermes returns the full list every time, it usually stops at
   the first row.
2. **`todo_state` on `session.resume`.** It covers a chat whose last plan
   is older than the history page Conduit loaded.

The loaded page is the tail of the history, so a plan it shows is the
newest one: the transcript wins whenever it has one. Otherwise the resume
snapshot stands.

**The plugin isn't needed.** Hermes 0.21 already gives Conduit the newest
plan when a chat opens, without working anything out on the phone. The
conduit_push plugin doesn't change.

## Plan card

- **Hidden** when the chat has no plan, or the plan is empty.
- **Expanded** card: title "Tasks", a count ("3 of 5"), a thin progress
  bar, and the items. A spinner marks the item in progress, an empty
  circle marks a pending one, a check marks a completed one (dimmed), and
  a struck-through dash marks a cancelled one. Subtasks are indented.
- **Collapsed** chip: a small progress ring, "Tasks" and "3/5", or a
  green check, "Tasks" and "5/5" when the plan is finished. It reads as a
  label; a lone "Done" looked like a button. Tapping it expands the card.
- **A new plan pops up.** A plan counts as new when it's the first in the
  chat, or when fewer than half of its items match the previous plan's
  (same id and same text). An update to a plan the user collapsed stays
  collapsed: the chip updates its count in place.
- **A finished plan collapses** 60 seconds after its last item is
  completed or cancelled. If new work is added later, the card opens
  again.
- **Reopening a chat:** an unfinished plan shows expanded and a finished
  one shows collapsed. Nothing animates in.
- **Too many items:** the card shows at most 5 rows. They're picked around
  the active item: the one just before it, the active item, then the next
  pending ones. Completed items above that window fold into one "✓ 4 done"
  row, and the rest fold into "+6 more". Each item is at most 2 lines.
  Tapping the header or "more" opens a sheet with the whole plan.
- **Pin:** a pin button keeps the card expanded and turns off the
  auto-collapse. The pin is a preference for every chat (pinning means
  "I always want to see the plan"), not a setting of one chat. Collapsing
  a pinned card unpins it.

## Layout

- Top right of the transcript, under the pinned-replies bar. Expanded,
  the card is at most 300 pt wide (iPhone: the width minus 32 pt).
- **It never hides the top-most message.** The transcript's top padding
  grows to the card's height (expanded or chip), so the first message
  starts under the card. Once the chat scrolls, the card floats over the
  messages, as on iPad.
- **It pops in**: a new card or chip scales up from the top right corner
  with a slight overshoot; folding and unfolding use the same spring.
  Under Reduce Motion it fades in and out without moving.
- Liquid Glass (`conduitGlassControl`) on iOS 26, and a material
  background before that.
- It doesn't show in the saved offline copy, a pending New Chat, or a
  group room.
- VoiceOver reads the card as one element: "Tasks, 3 of 5 done, now:
  …".
