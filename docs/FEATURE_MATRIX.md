# Matice funkcí

Stavy: DONE = hotovo a kryto kontrolou v repozitáři; PARTIAL = hotovo, ne zcela ověřeno; PLANNED = neimplementováno; DEFERRED = odloženo; REJECTED = zamítnuto.

| Funkce | Stav | Doklad |
|---|---|---|
| Limity Codexu 5 h a týden, zbývající procenta | DONE | živé čtení; `test_native_adapter.py` |
| Čas resetu, stav "čeká" po resetu | DONE | `test_usage_meter.py` |
| Zůstatek kreditů, když ho účet hlásí | DONE | `test_usage_meter.py` |
| Claude limity ze status line (`five_hour`, `seven_day`, procento a reset) | DONE | `test_claude_statusline.py`; živá session NEOVĚŘENO |
| Záloha: soubor Claude desktop aplikace (bez resetu, staré po 1 h) | DONE | `test_claude_sources.py`; soubor je nezdokumentovaný |
| Součty tokenů Claude z logů Claude Code (5 h, 7 dní) | DONE | `test_claude_sources.py` |
| Automatické nastavení status line při prvním spuštění | DONE | `test_claude_statusline.py` |
| Řetězení stávající status line, záloha `settings.json` | DONE | `test_claude_statusline.py` |
| Odinstalace přes CLI (`--claude-setup uninstall`) | DONE | příkaz v Terminálu; přepínač v aplikaci chybí |
| Přepínač nastavení status line v aplikaci | PLANNED | viz BACKLOG |
| Automatické (60 s) a ruční obnovení | PARTIAL | kód je; GUI neprověřeno |
| CPU celkem a po jádrech | PARTIAL | `--sample` |
| Paměť, GPU, síť | PARTIAL | kód je; závisí na ovladači |
| Skládací panel, zapamatovaná nastavení | PARTIAL | `UserDefaults` |
| Čeština a angličtina | PARTIAL | `cs.json`/`en.json`; angličtina bez revize rodilým mluvčím |
| Běh bez Pythonu | DONE | nativní čtečka |
| Čistá instalace na macOS 13+ | PLANNED | NEOVĚŘENO |
| Developer ID a notarizace | DEFERRED | jen ad-hoc (rozhodnutí vlastníka) |
| Účtování tokenů jedné konverzace | REJECTED | aplikace ukazuje limity účtu |
