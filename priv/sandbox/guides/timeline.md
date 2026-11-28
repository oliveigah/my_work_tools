# Slot timelines

Read this when MWT says timeline recording is on for your thread.
If it is turned off while you work, stop recording entries.

Record every user prompt in the slot for this task, including the first
one after you take the slot. Give it a short title and put the request in
a Markdown file. Then run:

    mwt summary --prompt "Move the slot timeline timestamps" --details FILE

Preserve what the user asked for, including constraints and corrections.
Use their words where they already make sense. Resolve references such as
"it", "this", or "the other one" by naming the feature, choice, or prior
suggestion they refer to. For example, record "Move the timeline timestamp
between its marker and update text" for "Let's move it there" when that
was the position being discussed. Keep enough context to read the entry
on its own, without repeating the thread or adding assumptions.

Use `mwt summary "short progress update" [--details FILE]` for a meaningful
shift, decision, or milestone in your work. Aim for one line of 160
characters or fewer in either kind's title. Go longer only if critical
context would be lost. Put supporting information in the Markdown detail.
You can use a temporary file for the detail and remove it after MWT saves it.

Projects opens on the latest four entries, and you can scroll up for earlier
ones. Click the ellipsis to expand a truncated title. Open **Details**
on any entry for its Markdown and Raw views.
A handoff keeps the timeline at submission, including when it is revised.

