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
| Barové ukazatele se šipkou (zelená/oranžová/červená), klik přepíná na 24h křivku, volba se pamatuje | DONE | ruční ověření na běžící aplikaci; klik a restart |
| Křivky za 24 h pro Codex (lokální historie 7 dní) | DONE | `test_codex_history.py` |
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
| Okno „Codex · aktivita": stav (běží, dokončeno, přerušeno, nečinný), posledních 12 kroků, ikony | DONE | `test_codex_activity.py`; ruční ověření |
| Odpočet „Obnova za …" u každého limitu Codex i Claude | DONE | ruční ověření |
| Proklik „Otevřít v Codexu" a „Otevřít v Terminálu" (`codex resume <id>`) | PARTIAL | Terminál vyžaduje oprávnění k ovládání Terminálu; ověřeno bez AppleScriptu |
| Tokeny Codex z lokálních logů (5 h, 7 dní) | DONE | `test_codex_tokens.py`; shoda s nezávislým výpočtem |
| Výsuvný šuflík „Aktivity Codexu za 24 h": běžící položky nahoře, scrollování, klik otevře vlákno v desktopové aplikaci Codex (`codex://threads/<id>`) | DONE | `test_codex_list.py`; ruční ověření klikem |
| Otevření vlákna na konkrétním místě (ne jen na vlákně) | NOT POSSIBLE | aplikace nemá odkaz na konkrétní zprávu; otevře se vlákno |

