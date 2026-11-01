# Usage Meter Pure — instalace

## Co potřebujete

- Mac s Apple Silicon M1 nebo novějším
- macOS 13 nebo novější
- aktuální ChatGPT desktop aplikaci

Python, Homebrew, OpenAI API klíč ani Terminál nejsou k instalaci potřeba.

Aplikace čte limity přes Codex, který je součástí ChatGPT desktop aplikace (nebo samostatné Codex CLI, pokud ji máte nainstalovanou). Musíte být přihlášeni ke stejnému účtu.

## Instalace

1. Stáhněte DMG z [GitHub Releases](https://github.com/morfin83/usage-meter-pure/releases/tag/v0.6.1-rc3) (soubor `Usage-Meter-Pure-0.6.1-RC3-build10-arm64.dmg`).
2. Otevřete stažený DMG.
3. Přetáhněte Usage Meter Pure do složky Aplikace (Applications).
4. Vysuňte DMG.
5. Spusťte Usage Meter Pure ze složky Aplikace.

## Pokud macOS aplikaci zablokuje

Tato verze (RC3) nemá Apple Developer ID podpis ani Apple notarizaci, takže macOS může první spuštění zablokovat.

Otevřete **Nastavení systému → Soukromí a zabezpečení** a u Usage Meter Pure zvolte **Přesto otevřít (Open Anyway)**. Zabezpečení macOS není potřeba vypínat ani obcházet.

## Ověření staženého souboru

SHA-256:

`73a0e327b4aefda7a442dbc9b7d2284efac30ec1f9888801576b305266f538bb`

Kontrola je volitelná a určená pokročilým uživatelům. Terminál není povinnou součástí instalace.

## Stav verze

Usage Meter Pure 0.6.1 RC3, build 10.

Jde o Release Candidate, tedy testovací verzi před finálním vydáním.

## Nezávislost

Usage Meter Pure je nezávislá aplikace a není produktem ani oficiální součástí OpenAI nebo Apple.

## Licence

Usage Meter Pure je distribuován pod licencí MIT (soubor [LICENSE](LICENSE)). Kódy a licence třetích stran jsou uvedeny v [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
