# Usage Meter Pure — pravidla pro Claude

Veřejný repozitář aplikace (MIT). Zdroje: `macos/UsageMeter.swift`, `scripts/usage_meter.py`, testy v `tests/`.

## Build a testy
- Testy: `python3 -m unittest discover -s tests`
- Sestavení aplikace: `sh scripts/build_macos.sh <výstupní složka>` (arm64, minimum macOS 13). Výchozí podpis je ad-hoc.
- DMG: `bash create_release_dmg.command` s proměnnými `APP` a `OUTPUT` (spusť přes `bash`, ne `sh`). Vzniklé DMG nekommituj.

## Vydání
- Vydání, nová verze a publikace DMG vyžadují výslovný souhlas. Podpis Developer ID a notarizace jsou vyřazené, dokud vlastník neřekne jinak.
- Při změně verze uprav `scripts/build_macos.sh` i `macos/Resources` a ověř shodu verze.

## Soukromí
- Aplikace nic neodesílá (kromě čtení účtu Codex přes lokální CLI). Nepřidávej síťové volání bez schválení a aktualizace popisu soukromí.

## Komunikace a stavy
- S uživatelem komunikuj česky, pokud nepíše jiným jazykem. Texty pro uživatele zachovávej v jazyce webu (cs/en).
- Označuj stav: OVĚŘENO, PROVEDENO, NEOVĚŘENO, NAVRŽENO, VYŽADUJE SCHVÁLENÍ. Nic neoznačuj jako hotové bez ověření.

## Schvalování (bez výslovného souhlasu NEDĚLAT)
- push na `main`, vydání (release, tag, DMG pro veřejnost), nasazení na produkci, změna viditelnosti repozitáře
- publikace osobních údajů, zdrojů nebo binárních souborů, které nejsou určené k veřejnému zveřejnění
- mazání nebo přepisování historie (force push, reset sdílených větví)
- placené kroky, stahování velkých obrazů, vytváření virtuálních strojů

## Bezpečnost a soukromí
- Nikdy necommituj tajemství: klíče, tokeny, hesla, certifikáty, osobní údaje, soukromé exporty chatů, obnovovací důkazy.
- Binární distribuční soubory (DMG, ZIP, média větší než běžné assety) do Gitu nepatří. Jsou v `.gitignore`.
- Před každým commitem zkontroluj `git status` a `git diff --cached`.

## Git
- Práce na větvi, ne přímo na `main`. Commit zprávy končí řádkem `Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>`.
- Záznam změn a nasazení patří do `RELEASES.md` (pokud repo má), záznam stavu do dokumentace projektu.

## Hlášení chyb
- Hlášení od uživatelů se čtou z GitHub Issues (automatizace v Claude Desktopu). Odpovědi na hlášení řídí pravidla v `~/Documents/PURE-bugs/`.
