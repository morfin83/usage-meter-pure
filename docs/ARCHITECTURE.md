# Architektura

## Komponenty (`macos/UsageMeter.swift`, jeden soubor)
- `AppDelegate` — stavová položka, plovoucí panel, časovače, předvolby (`UserDefaults`), ukončení.
- `SystemSampler` — CPU celkem a po jádrech, paměť, GPU (`IOAccelerator`), aktivní síťové rozhraní.
- UI: `MeterRow`, `PastelBar`, `DragHeader`, `OverlayPanel`, `Palette`.
- `CodexUsage` — hledání binárky Codexu a sestavení očištěného snímku.
- `AppServerLink` — jeden podproces `codex app-server --stdio --disable hooks`, JSON-RPC přes roury.
- `ClaudeUsage` — Claude zdroje (viz níže).
- Lokalizace: `macos/Resources/cs.json`, `en.json`.

## Tok dat: Codex
1. Časovač (60 s a na požádání) volá `fetchUsage()`. Zámek brání paralelnímu čtení.
2. `CodexUsage.codexBinary()` hledá v `PATH` plus `/opt/homebrew/bin` a `/usr/local/bin`, pak v balíčcích ChatGPT/Codex.
3. `CodexUsage.read()` spustí app-server a pošle `initialize`, `initialized`, `account/rateLimits/read`. Požadavky serveru odmítne. Timeout 12 s.
4. `CodexUsage.snapshot()` povolí jen známá pole, ořízne procenta, odmítne boolean jako číslo, prošlý reset označí jako čekající a zahodí id účtu a tokeny.
5. Hlavní fronta: `applyUsage()` aktualizuje řádky; stará hodnota se označí po 120 s nebo při selhání.
6. `applicationWillTerminate` ukončí podproces.

## Tok dat: Claude
Limity, v tomto pořadí:
1. **Status line.** Claude Code spustí `"<cesta k aplikaci>" --statusline` a pošle JSON na stdin. Aplikace uloží `five_hour` a `seven_day` (`used_percentage`, `resets_at`) a čas pozorování do `~/Library/Application Support/Usage Meter Pure/claude-statusline.json`. Data jsou čerstvá 1 hodinu. Pak (řetězení) spustí původní status line uživatele.
2. **Záloha.** `~/Library/Application Support/Claude/plan-usage-history.json` (nezdokumentovaný; využité procento; bez časů resetu; po 1 hodině označeno jako staré).

Tokeny: `ClaudeUsage.tokenTotals` sčítá `message.usage` z `~/.claude/projects/**/*.jsonl` (podle id zprávy, platí poslední záznam). Zahrnuje cache tokeny a není limitem předplatného.

Obojí běží na pozadí spolu se čtením Codexu; `applyClaude` aktualizuje řádky na hlavní frontě.

## Automatické nastavení status line
Při každém spuštění aplikace zajistí položku `statusLine` v `~/.claude/settings.json` s příkazem `"<cesta k aplikaci>" --statusline`.
- Ostatní klíče se zachovají.
- Originál se jednou zálohuje do `~/.claude/settings.json.usage-meter-backup.json`.
- Existující status line uživatele se zachová a spouští se po kroku aplikace.
- Po přesunu aplikace se cesta opraví při dalším spuštění.
- Bez složky `~/.claude` se nic nezapíše, panel to oznámí a nastavení se zopakuje při dalším spuštění.
- Neplatný JSON v `settings.json` se nemění.
- Odinstalace: `UsageMeter --claude-setup uninstall` vrátí předchozí status line nebo klíč odstraní a smaže vlastní soubory aplikace.

## Umístění souborů
| Soubor | Účel |
|---|---|
| `~/.claude/settings.json` | zde aplikace zapisuje `statusLine` |
| `~/.claude/settings.json.usage-meter-backup.json` | jednorázová záloha originálu |
| `~/Library/Application Support/Usage Meter Pure/claude-statusline.json` | data status line |
| `~/Library/Application Support/Claude/plan-usage-history.json` | záloha limitů (čte se, nezapisuje) |
| `~/.claude/projects/**/*.jsonl` | logy pro součty tokenů (čtou se) |

## Referenční adaptér
`scripts/usage_meter.py` implementuje stejnou logiku čtečky v Pythonu pro testy. Není v balíčku.

## Testovací přepínače
`--usage-check`, `--usage-find-codex`, `--claude-check` slouží testům. Normální spuštění nemění.

## Sestavení
`scripts/build_macos.sh` kompiluje přes `xcrun swiftc -target arm64-apple-macos13.0`, zkopíruje zdroje, zapíše `Info.plist`, vyčistí rozšířené atributy a podepíše ad-hoc. `scripts/make_dmg.sh` vytvoří DMG.

## Codex activity (feat/codex-activity)
- `CodexActivity.latest` reads the tail (256 KB) of the newest `~/.codex/sessions/**/*.jsonl` file of the last 24 h.
- Events used: `task_started`, `task_complete`, `turn_aborted`, `function_call` / `custom_tool_call` and their outputs, `agent_message`. A call with no output after 20 s is shown as waiting (an estimate).
- `CodexActivityWindow` refreshes every 2 s while open. The session id is the UUID at the end of the file name.
- `CodexTokens.cachedTotals` sums `last_token_usage.total_tokens` across the logs, cached for five minutes; it runs after the limits are shown.
- Test hooks: `--codex-activity <root> <now>`, `--codex-tokens <root> <now>`.

