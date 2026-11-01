# Usage Meter Pure

Malý nativní panel pro macOS (lišta nabídek a plovoucí panel; Apple Silicon, macOS 13+). Ukazuje zbývající limity Codexu a Claude vedle lokálního zatížení CPU, jader, paměti, GPU a sítě.

- Bundle identifier: `cz.pure.usagemeter`
- Aktuální verze: 0.6.1 build 11 (finální kandidát 0.6.1, zatím nevydáno)
- Naposledy vydáno: 0.6.0 build 8; pre-release [v0.6.1-rc3](https://github.com/morfin83/usage-meter-pure/releases/tag/v0.6.1-rc3) (viz [RELEASES.md](RELEASES.md))
- Jazyky: čeština a angličtina
- Licence: MIT ([LICENSE](LICENSE)); licence třetích stran v [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## Co panel ukazuje

Panel má dvě skupiny.

### Codex

Limity (5 hodin a týden) se čtou přes `codex app-server` jediným požadavkem `account/rateLimits/read`. Požadavek je jen pro čtení. Nezakládá konverzace a neutrácí tokeny. Zbytek čte nativní Swift kód v `macos/UsageMeter.swift`. Python není potřeba.

### Claude

Limity (5 hodin a 7 dní) se berou v tomto pořadí:

1. **Data status line z Claude Code.** Aplikace je ukládá do `~/Library/Application Support/Usage Meter Pure/claude-statusline.json`. Jde o oficiální JSON status line (`five_hour` a `seven_day`: `used_percentage`, `resets_at`). Data existují jen když Claude Code běží se session na plánu Pro/Max. Jsou čerstvá 1 hodinu.
2. **Záloha: soubor Claude desktop aplikace** `~/Library/Application Support/Claude/plan-usage-history.json`. Je nezdokumentovaný, ukazuje využité procento a nemá časy resetu. Po 1 hodině se označí jako starý.

Procenta se ukazují jako zbývající.

Součty tokenů Claude (5 h a 7 dní) se sčítají z logů Claude Code v `~/.claude/projects` (podle id zprávy, platí poslední záznam). Zahrnují cache tokeny a **nejsou** limitem předplatného.

Při prvním spuštění si aplikace sama nastaví status line v `~/.claude/settings.json`. Podrobnosti jsou v [INSTALLATION.md](INSTALLATION.md).

## Struktura repozitáře

- `macos/UsageMeter.swift` — aplikace (AppKit, IOKit, SystemConfiguration), nativní čtečka limitů a režim status line (`--statusline`).
- `macos/Resources/` — ikona aplikace, české a anglické texty.
- `scripts/build_macos.sh` — sestaví a ad-hoc podepíše `.app` do zvolené složky.
- `scripts/make_dmg.sh` — vytvoří DMG.
- `scripts/make_app_icon.sh` — vygeneruje ikonu.
- `scripts/usage_meter.py` — pouze referenční implementace čtečky pro testy. Není součástí aplikace.
- `tests/` — testy čtečky, adaptéru a Claude zdrojů.
- `docs/` — dokumentace projektu.

## Sestavení a testy

```sh
python3 -m unittest discover -s tests -v
sh scripts/build_macos.sh /cesta/k/prazdne/slozce
sh scripts/make_dmg.sh "/cesta/k/Usage Meter Pure.app" /cesta/k/vystupni/slozce Usage-Meter-Pure-0.6.1-build11
```

Testy kompilují Swift přes `xcrun swiftc`, Command Line Tools tedy potřebuje jen sestavovací Mac. Koncový uživatel je nepotřebuje.

## Soukromí

Aplikace sama nepoužívá síť. Nepoužívá cookies, tokeny ani Klíčenku. Režim status line ukládá jen čtyři čísla na okno (využité procento, čas resetu, čas pozorování), ne id session, cesty ani přepisy. Viz [INSTALLATION.md](INSTALLATION.md).

## Hlášení chyb

Použijte [issue tracker](https://github.com/morfin83/usage-meter-pure/issues) a [šablonu hlášení chyb](.github/ISSUE_TEMPLATE/bug_report.md).
