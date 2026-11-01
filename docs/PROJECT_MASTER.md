# Usage Meter Pure — project master

Stav k 2026-11-01. Autoritativní zdroj: kód v tomto repozitáři a rozhodnutí v [DECISIONS.md](DECISIONS.md). Starší dokumenty jsou jen historie.

## Co to je
Nativní panel pro macOS (Apple Silicon, macOS 13+). Ukazuje limity Codexu a Claude a lokální CPU, jádra, paměť, GPU a síť. Licence MIT. Studio Pure Sound / MORfin83.

## Stav
- Verze 0.6.1 build 12 (barové ukazatele, křivky, automatické napojení Claude Code) je sloučená do `main`, nainstalovaná lokálně z DMG. Vydání čeká na schválení vlastníka.
- Naposledy vydáno: 0.6.0 build 8. Pre-release: 0.6.1 RC3 build 10 (viz [RELEASES.md](../RELEASES.md)).
- Pracovní větev: `release/0.6.1`.

## Ověřeno
- 38 Python testů prošlo (viz [TEST_REPORT.md](TEST_REPORT.md)).
- Aplikace se sestaví a je ad-hoc podepsaná.
- Limity Codexu se čtou živě přes `account/rateLimits/read`; tokeny se neutrácí.

## Otevřené
Viz [BACKLOG.md](BACKLOG.md) a [KNOWN_ISSUES.md](KNOWN_ISSUES.md). Hlavní body: test na čistém Macu a živá session Claude Code se status line jsou NEOVĚŘENO.

## Zálohy
Před milníkem (kandidát, tag, veřejné vydání) uložte kopii dokumentace a artefaktů mimo repozitář a zapište kontrolní součty.
