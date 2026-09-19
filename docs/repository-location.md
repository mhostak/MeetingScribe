# Kde repozitár leží a prečo

Kanonické umiestnenie na tomto stroji:

```
/Users/martin_hostak/Dev/projects/MeetingScribe
```

Presunuté z `/Users/martin_hostak/Documents/MeetingScribe` dňa 2026-09-19.

## Prečo nie `~/Documents`

iCloud Drive má na tomto Macu zapnutú synchronizáciu priečinkov Desktop
a Documents, čo overí `brctl status`. Repozitár s `.build` a `.derivedData` nesie
niekoľko gigabajtov odvodených dát, ktoré sa neustále menia, takže sync engine
ich stále nahráva. Tri konkrétne následky, všetky pozorované na tomto projekte
a zapísané v [docs/meeting-notes-plan.md](meeting-notes-plan.md) v sekcii
*Prostredie*:

- Konfliktné kópie `Nazov 2.swift`. V jednom momente ich bolo 532 priamo
  v `.build/checkouts/FluidAudio`. FluidAudio si cieľ definuje cez
  `path: "Sources/FluidAudio"` bez zoznamu súborov, takže SwiftPM zoberie aj
  duplikáty a `swift build` s predvoleným scratch path padne na kolíziách
  deklarácií. Tie isté duplikáty sa objavovali aj v `docs/` a `scripts/`.
- Zlyhanie ad-hoc podpisu testovacieho bundlu na `resource fork, Finder
  information, or similar detritus not allowed`, lebo sync zapisuje Finder
  metadáta na build produkty.
- Saturovaný stroj počas nahrávania. Desaťsekundový záznam sa raz spracovával
  štyri minúty.

`~/Dev` sa nesynchronizuje, takže žiadna z týchto príčin tam nevzniká.

## Čo je na cestu naviazané

Samotný repozitár je takmer prenositeľný. `MeetingScribe.xcodeproj` neobsahuje
ani jednu absolútnu cestu a Git si cestu nikde nepamätá. Naviazané je len toto:

| Miesto | Čo tam je | Ako sa to opraví |
|---|---|---|
| `CLAUDE.md` | cesta k repozitáru v úvode | v repozitári, verzované |
| `~/.codex/config.toml` | sekcia `[projects."<cesta>"]` | ručne, mimo repozitára |
| `.claude/settings.local.json` | povolenia `Bash(git -C <cesta> …)` | v repozitári, ignorované Gitom |
| `~/Applications/MeetingScribeBuildDaemon.app` | cesta k `assistant_build_daemon.py` **zapečená v binárke** cez `-DDAEMON_SCRIPT` | znovu spustiť `scripts/install-assistant-build-daemon.sh` z nového umiestnenia |
| `~/.claude/projects/-Users-…-MeetingScribe/` | história sessions a pamäť agenta, kľúčované cestou | premenovať priečinok, inak sa história javí ako stratená |

Mimo to nič: nahrávky sú v `~/Library/Application Support/MeetingScribe`,
modely tamtiež, nainštalovaná aplikácia v `/Applications`, build daemon si
pracovné adresáre robí v `/private/tmp`.

## Postup pri ďalšom presune

1. Over, že fronta daemona je prázdna: `python3 scripts/assistant_build_client.py status`.
2. Zastav LaunchAgent: `launchctl bootout gui/$(id -u)/com.meetingscribe.assistant-build`.
3. Presuň priečinok.
4. Z nového umiestnenia spusti `scripts/install-assistant-build-daemon.sh`.
   Installer si `REPO` odvodí z vlastnej polohy, prekompiluje launcher s novou
   cestou a LaunchAgent nahodí znova. Ak macOS vypýta Full Disk Access znova,
   udeľ ho novej binárke.
5. Uprav `~/.codex/config.toml` a `.claude/settings.local.json`.
6. Premenuj priečinok v `~/.claude/projects/`, aby sa nestratila história.
7. Over: `git status`, `git remote -v`, obe testovacie sady.

---

# Pokyny pre ChatGPT Codex

Tvoj `~/.codex/config.toml` má sekciu kľúčovanú starou cestou. Kým ju
neopravíš, Codex bude tento projekt považovať za neznámy a tvoje nastavenia
dôvery či schválení sa naň neuplatnia.

**1. Oprav zápis projektu.** V `~/.codex/config.toml` nahraď

```toml
[projects."/Users/martin_hostak/Documents/MeetingScribe"]
```

za

```toml
[projects."/Users/martin_hostak/Dev/projects/MeetingScribe"]
```

Obsah sekcie nechaj nezmenený. Iné výskyty starej cesty v tom súbore nie sú.

**2. Nechaj archívy na pokoji.** Stará cesta sa vyskytuje aj v
`~/.codex/sessions/**` a `~/.codex/archived_sessions/**`. Sú to záznamy
minulých konverzácií, teda historický fakt. Neprepisuj ich.

**3. Pri práci v repozitári.** Nová pracovná cesta je
`/Users/martin_hostak/Dev/projects/MeetingScribe`. Ak ti niekde zostala stará
zapamätaná, prepíš ju. Relatívne cesty vnútri repozitára sa nemenili, takže
žiadny príkaz z `README.md` ani `AGENTS.md` sa inak nespúšťa.

**4. Čo neplatí, ak si to mal zapamätané.** Poznámka, že `swift test` zlyháva
na podpise testovacieho bundlu, platila pre umiestnenie pod `~/Documents`. Nové
umiestnenie sa nesynchronizuje, takže by sa to už nemalo stávať. Používanie
scratch path mimo checkoutu je aj tak lepší zvyk a `AGENTS.md` ho stále
odporúča.

**5. Build daemon.** Ak `python3 scripts/assistant_build_client.py status`
ohlási, že daemon nebeží, znamená to, že launcher má ešte starú cestu zapečenú
v binárke. Nezapisuj do fronty a nepokúšaj sa to obísť. Požiadaj používateľa,
aby spustil `scripts/install-assistant-build-daemon.sh` z nového umiestnenia,
a dovtedy neoverené tvrdenia označuj ako neoverené.
