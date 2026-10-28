# Inbox example

A small, fictional Lua inbox used to demonstrate `review.nvim`.

## Messages

Each message contains a `subject`, a `read` flag and a `received_at` timestamp.

## Filtering

```lua
local inbox = require("demo.inbox")
local matches = inbox.filter(messages, { query = "release" })
```

Search is case-insensitive and matches part of a subject.
Results are ordered by their received timestamp, newest first.
Filtering leaves the input collection unchanged.

## Summary

```lua
print(inbox.summary(messages))
```

The summary reports the total number of messages and the unread count.

## Purpose

This example is screenshot material, separate from the plugin implementation.
The associated draft pull request is for documentation demonstrations.
