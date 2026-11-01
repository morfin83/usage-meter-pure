# Známé problémy

## Otevřené
- **Claude procenta jsou čerstvá jen při používání Claude Code.** Status line se spouští jen když Claude Code běží. Jinak panel ukáže upozornění na stáří.
- **Záložní soubor Claude desktop aplikace je nezdokumentovaný** a může se změnit. Nemá časy resetu a po 1 hodině se označí jako starý.
- **Časy resetu Claude** jsou vidět jen při přítomných datech status line.
- **Součty tokenů Claude zahrnují cache tokeny**, které dominují objemu. Nejsou limitem předplatného.
- **Čistý Mac nevyzkoušen.** macOS 13+ bez vývojářských nástrojů, první otevření přes Gatekeeper, přetažení do Aplikací: NEOVĚŘENO.
- **Živá session Claude Code se status line** na čistém stroji: NEOVĚŘENO.
- **Odinstalace jen z Terminálu.** Přepínač v aplikaci zatím chybí.
- **Codex se vyvíjí.** Aplikace závisí na detailech `codex app-server` (`--disable hooks`, tvar `account/rateLimits/read`). Testováno s codex-cli 0.165.0. Nová verze Codexu se musí znovu ověřit.
- **Osiřelý podproces po pádu.** Při tvrdém ukončení může app-server chvíli přežít; má skončit na EOF, neověřeno.
- **`build_macos.sh` maže cílovou složku.** Vždy zadejte prázdnou pracovní složku.
- **Nepopsaný lokální DMG** `…RC-build9.dmg` (SHA-256 `62f14860…`) nesouhlasí s žádným záznamem. Nepoužívá se.
