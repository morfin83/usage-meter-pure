# Zpráva o testech

Datum: 2026-11-01. Větev: `feat/gauge-bars` (sloučena do `main`). Verze 0.6.1 build 12. Testů: 48 OK.

## Příkazy a výsledky
- `python3 -m unittest discover -s tests -v` — **38 testů prošlo.**
- `sh scripts/build_macos.sh <prázdná složka>` — sestavení a ad-hoc podpis v pořádku.

## Testovací soubory
- `tests/test_usage_meter.py` — referenční Python čtečka Codexu.
- `tests/test_native_adapter.py` — nativní Swift čtečka (kompilace přes `xcrun swiftc`, falešné app-servery).
- `tests/test_claude_sources.py` — Claude zdroje: soubor desktop aplikace a součty tokenů.
- `tests/test_claude_statusline.py` — režim status line a automatické nastavení.

## Pokryto testy
Handshake a jedno čtení; odmítnutí požadavků serveru; omezený timeout; chyby bez úniku obsahu; oříznutí procent; boolean není číslo; prošlý reset je "čeká"; zahozená soukromá pole; hledání v `PATH`; Claude zdroje; status line a nastavení `settings.json`.

## NEOVĚŘENO
- Čistý Mac s macOS 13+ bez vývojářských nástrojů, první otevření přes Gatekeeper, instalace přetažením.
- Živá session Claude Code se zobrazenou status line.
- Interakce GUI (panel, obnovení, ukončení) v celém rozsahu.
- Revize lokalizace a vzhled ve všech velikostech.
- Jiné verze Codexu než 0.165.0.
