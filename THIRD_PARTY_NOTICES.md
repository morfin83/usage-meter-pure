# Third-party notices — Usage Meter Pure 0.6.1

Stav: návrh k ověření. Ověřeno 2026-10-30 kontrolou zdrojového kódu (`git ls-files`).

## Co se distribuuje

- **Python:** pouze standardní knihovna (`pathlib`, `json`, `subprocess`, `hashlib`, `zipfile`, `urllib` atd.). Žádný balíček třetí strany není vendorován ani vyžadován.
- **Swift / macOS:** pouze systémové frameworky Apple (`AppKit`, `Foundation`, `IOKit`, `SystemConfiguration`, `CoreImage`, `Darwin`). Ty nejsou součástí distribuce a řídí se licencemi Apple.
- **Webové soubory:** žádné CDN, žádné fonty ani npm balíčky. Ověřeno: v `web/public` a `web/build.py` nejsou externí knihovny.
- **Grafika a ikony:** logo a ikona PURE jsou vlastní materiály Studio Pure Sound.

## Externí programy, které aplikace používá (nedistribuují se)

- **Codex CLI** (OpenAI) — aplikace jej vyhledá v `PATH` nebo v `ChatGPT.app` a volá read-only. Licence: podle OpenAI. Uživatel si jej instaluje sám.
- **ChatGPT / Codex desktop** (OpenAI) — volitelný zdroj binárky. Uživatel si jej instaluje sám.

## Externí služby na webu (nedistribuují se)

- **YouTube (youtube-nocookie.com)** — přehrávání embedovaných videí. Podmínky služby YouTube.

## Závěr

Distribuce neobsahuje kód třetích stran pod copyleft licencí. Licence MIT pro Usage Meter Pure se vztahuje na kód Studio Pure Sound.
