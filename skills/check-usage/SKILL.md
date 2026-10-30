---
name: check-usage
description: Show current Codex account usage limits, remaining percentages and reset times. Use when the user asks how much Codex allowance remains or invokes Usage Meter. Does not measure ordinary ChatGPT message limits or a conversation's context window.
---

# Usage Meter

Use the built-in `get_usage_limits` capability when available. Otherwise run
`python3 ../../scripts/usage_meter.py --live` resolved relative to this skill's
directory; quote the absolute path. This fallback needs a ChatGPT-authenticated
Codex CLI and network access. Do not start model turns or read credential files.

Prefer `rateLimitsByLimitId` over the legacy `rateLimits`. Calculate remaining
as `max(0, min(100, 100 - usedPercent))`; null/missing is unavailable. Label each
window from its actual `windowDurationMins`. Show reset dates in the user's
timezone when known, otherwise explicitly use the system timezone or UTC.
Report past reset timestamps as awaiting refresh, not a newly replenished limit.
State that these are shared Codex account limits and when the snapshot was taken.
Do not convert them into tokens or minutes of remaining work. A missing window
does not imply an unlimited allowance. Respect spend-control/reached flags when present.

For a persistent display, use the companion panel in `../../dist/Usage Meter.app`
relative to this skill's directory. Launch it only when the user requests the panel.
The `show-panel` skill describes its controls. Do not add automatic chat footers.

If unavailable, report that plainly and continue the user's task. Do not retry
repeatedly, log in, change accounts, spend credits, or redeem resets. No external
messages or publication are authorized by this skill.
