---
name: steer-queue
description: Steer a running turn or queue a follow-up.
metadata:
  display-name: Steer / queue
  order: "1"
  expected-tools: '{}'
---

Deliver steering and queued follow-ups from the composer while a turn is running.

tool_schemas() must return an empty vector: this feature exposes no agent tools.
run_tool must accept any name and return an empty string.

on_key!(menu, event, state) is the whole feature:
- Ignore key releases: return false when event.action is App.Tachikoma.key_release.
- While menu.busy and event.key is :enter: read the composer with App.Tachikoma.text(menu.prompt).
  When its stripped text is empty, consume the key and return true without doing more. Otherwise call
  App.queue_prompt!(menu, :steer) and return true.
- While menu.busy and event.key is :ctrl with event.char equal to 'g': call
  App.queue_prompt!(menu, :queue) and return true. Do not advertise Option+Enter; terminals may not
  distinguish its modifiers.
- In every other case return false, so ordinary typing, Enter while idle, arrows, scrolling, Escape
  and focus keys keep working.

footer returns exactly "enter steer  ctrl+g queue" while menu.busy and an empty string otherwise.
The host adds its own composer and scrolling keys, so do not repeat them. The host agent loop
already implements delivery, interruption and the composer clearing performed by App.queue_prompt!;
do not store prompts in state and do not add notices of your own. on_frame!, on_reload! and
shutdown! are no-ops.
