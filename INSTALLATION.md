# Usage Meter Pure — instalace

Verze 0.6.2 build 13 (zatím nevydáno).

## Co potřebujete

- Mac s Apple Silicon M1 nebo novějším
- macOS 13 nebo novější
- pro limity Codexu: ChatGPT desktop aplikaci nebo Codex CLI
- pro limity Claude: Claude Code

Python, Homebrew ani OpenAI API klíč nejsou potřeba. Terminál také ne (kromě odinstalace, viz níže).

## Instalace

1. Otevřete DMG `Usage-Meter-Pure-0.6.1-build13` (soubor dostanete od autora; zatím není veřejně vydán).
2. Přetáhněte Usage Meter Pure do složky Aplikace (Applications).
3. Vysuňte DMG.
4. Spusťte Usage Meter Pure ze složky Aplikace.

Soubor: `Usage-Meter-Pure-0.6.1-build13-arm64.dmg`

SHA-256: 8c848bb1f98fc5b74611b4f2168d5875bfa83bc682acdf9dd872c0e8b26c6581

## Pokud macOS aplikaci zablokuje

Aplikace má jen ad-hoc podpis a není notarizovaná. macOS může první otevření zablokovat.

Otevřete **Nastavení systému → Soukromí a zabezpečení** a u Usage Meter Pure zvolte **Přesto otevřít (Open Anyway)**. Zabezpečení macOS není potřeba vypínat.

## Co aplikace udělá sama při prvním spuštění

Nemusíte nic nastavovat. Aplikace zapíše položku `statusLine` do `~/.claude/settings.json` s příkazem `"<cesta k aplikaci>" --statusline`.

- Ostatní klíče v souboru zůstanou beze změny.
- Původní soubor se jednou zálohuje do `~/.claude/settings.json.usage-meter-backup.json`.
- Pokud už máte vlastní status line, zůstane zachovaná. Spustí se po kroku aplikace (řetězení).
- Když aplikaci přesunete, cesta se při dalším spuštění opraví.
- Když složka `~/.claude` neexistuje (Claude Code není nainstalovaný), nic se nezapíše a panel to řekne. Nastavení se zopakuje při dalších spuštěních.
- Když `settings.json` není platný JSON, aplikace ho nechá být.

## Co uvidíte

Panel se dvěma skupinami: Codex a Claude. Procenta jsou zbývající.

- Limity Codexu přijdou z `codex app-server` (jen čtení).
- Limity Claude přijdou z dat status line. Ta se objeví po prvním použití Claude Code se session na plánu Pro/Max. Do té doby (nebo když jsou starší než 1 hodinu) panel použije soubor Claude desktop aplikace a ukáže upozornění na stáří.
- Časy resetu Claude jsou vidět jen když jsou data status line.
- Součty tokenů Claude (5 h a 7 dní) pocházejí z logů Claude Code. Zahrnují cache tokeny a nejsou limitem předplatného.

## Soukromí

- Režim status line ukládá jen čtyři čísla na okno: využité procento, čas resetu a čas pozorování.
- Neukládá id session, cesty ani data přepisů.
- Aplikace sama nepoužívá síť. Nepoužívá cookies, tokeny ani Klíčenku.

## Odinstalace

Přepínač v aplikaci zatím není. Spusťte v Terminálu:

```sh
"/Applications/Usage Meter Pure.app/Contents/MacOS/UsageMeter" --claude-setup uninstall
```

Příkaz vrátí vaši původní status line nebo klíč odstraní a smaže vlastní soubory aplikace. Potom můžete aplikaci smazat ze složky Aplikace.

## Známá omezení

- Procenta Claude jsou čerstvá jen při používání Claude Code. Jinak panel ukáže upozornění na stáří.
- Soubor Claude desktop aplikace je nezdokumentovaný a může se změnit.
- Nově neověřeno: čistý Mac s macOS 13+ a živá session Claude Code se status line.

## Nezávislost

Usage Meter Pure je nezávislá aplikace a není produktem ani oficiální součástí OpenAI, Anthropic ani Apple.

## Licence

MIT (soubor [LICENSE](LICENSE)). Licence třetích stran jsou v [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
