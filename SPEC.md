# Agent event spec

This adapter follows Haunt's agent-neutral event spec (v1): one compact JSON object per line (NDJSON) on Haunt's socket, with an OSC 777 status-only fallback. The spec lives in one place and is not copied here.

- Core side, what Haunt accepts and verifies: [`docs/core-api.md`](../../haunt/docs/core-api.md) in the haunt repo.
- "Agent event spec v1", being written alongside the Codex adapter: [`CORE-CHANGES.md`](../haunt-codex/CORE-CHANGES.md) in haunt-codex.

The Claude-specific part (which Claude Code hook emits which event, the fields, truncation and the OSC fallback) is in this repo's [README](README.md#protocol-v1).
