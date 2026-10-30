---
name: show-panel
description: Open the Usage Meter floating macOS panel for Codex account limits and local CPU, RAM, GPU and network percentages. Use when the user asks to show or launch the installed Usage Meter panel.
---

# Show Usage Meter

Resolve `../../dist/Usage Meter.app` relative to this skill directory. On macOS,
open that app using the available app-launch capability. If the app has not been
built, run `sh ../../scripts/build_macos.sh` relative to this directory first;
building needs Xcode Command Line Tools. The binary is built for the current Mac's
architecture. Other platforms are not supported by this prototype.

The panel appears at the bottom right when Codex or ChatGPT is foreground. Its
menu-bar gauge remains available in other apps. The menu can also show the panel
over other apps. Do not change autostart settings or install launch agents.

Controls:
- Zobrazit: hide/show the body while keeping the header and switch visible.
- Všechny parametry: show/hide local CPU, RAM, GPU and network readings.
- CPU/GPU switches: show/hide individual cores. CPU uses live logical-core counters; GPU core readings are unavailable on this Mac and shown as dashes.
- Menu-bar gauge: refresh limits, toggle visibility, or quit the helper app.

Account data comes from the locally signed-in Codex CLI, using a read-only
App Server metadata request every 60 seconds. Local hardware readings refresh
every two seconds. No model turn is started. The account may differ from a remote
task's account. Never assume the panel measures the model's remote server.

Use the visible labels: allowance percentages mean remaining Codex quota;
hardware percentages mean utilization. Credits are a balance, not a percentage.
An exact remaining token count is unavailable. Network utilization is relative
to the reported interface speed and uses the busier of RX/TX; it is not the
internet subscription speed. A dash means unavailable, never zero. Older quota
data is marked when refresh fails. Hover quota rows for reset times.

Verify the running panel and switches when computer-use tools are available.
Do not claim it was opened or installed based only on building the executable.
