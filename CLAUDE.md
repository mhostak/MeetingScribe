# MeetingScribe — pokyny pre Claude

Lokálna macOS aplikácia (menu-bar) na nahrávanie schôdzok a lokálny prepis.
Repozitár: `/Users/martin_hostak/Dev/projects/MeetingScribe`.
Zámerne **mimo** `~/Documents`, ktorý synchronizuje iCloud Drive — dôvody a
postup pri zmene umiestnenia sú v [docs/repository-location.md](docs/repository-location.md).

`AGENTS.md` je záväzný aj pre Claude. Tento súbor ho **dopĺňa**, neruší ani
neduplikuje. Pri konflikte platí `AGENTS.md`.

Výnimka je jediná a je v `AGENTS.md` označená: sekcie, ktoré predpisujú
konkrétny nástroj daného agenta (delegovanie cez wrapper `xclaude`), platia len
pre agenta, ktorý ten nástroj má. Claude ho tu nemá. Pravidlá o projekte —
podpis, inštalácia, testy, Git — platia pre každého agenta rovnako.

- BlueCode delegovanie → `AGENTS.md`, sekcia *BlueCode coding delegation*
  (vyžaduje `xclaude`; bez neho sa nedeleguje a implementuje sa priamo)
- Podpísaný lokálny build a spustenie → `AGENTS.md`, sekcia *Runnable local macOS builds*
- Postup po aktualizácii `main` → `AGENTS.md`, sekcia *After updating `main`*
- Architektúra, invarianty, build/test príkazy → `README.md`
- Plány a evidencia k rozpracovaným témam → `docs/`

## Komunikácia

Odpovedaj po slovensky, stručne a vecne. Technické názvy, príkazy, cesty
a identifikátory nechávaj v pôvodnom jazyku. Bez zbytočných úvodov a zhrnutí.

## Spôsob práce

- Pred zmenami si prečítaj aktuálny `AGENTS.md` a relevantnú dokumentáciu
  v `README.md` a `docs/`. Nevymýšľaj si architektúru ani existujúce funkcie.
- Najprv skontroluj vetvu, stav pracovného adresára a existujúce zmeny.
  Rozpracovanú prácu používateľa aj iných agentov zachovaj.
- Pri konkrétnej požiadavke prácu vykonaj a over výsledok. Neostaň pri návrhu
  postupu.
- Pýtaj sa len vtedy, keď chýbajúce rozhodnutie zásadne mení výsledok. Bežné
  technické rozhodnutia rob samostatne.
- Zmeny drž v rozsahu zadania — žiadne nesúvisiace refaktoringy, závislosti
  ani funkcie.
- Pri súbežnej implementácii používaj izolované Git worktrees.

## Git

- Bez výslovného zadania nepushuj, nemerguj ani nenasadzuj.
- Žiadne deštruktívne príkazy (`reset --hard`, `checkout --force`, `clean -fd`,
  `push --force`, `stash drop`, …) a neprepisuj cudzie zmeny.
- `Config/Signing.local.xcconfig` a osobné podpisové hodnoty nikdy nekomituj.
  Ignorované cesty sú v `.gitignore`.

## Kvalita a overenie

- Dodržuj existujúcu architektúru a štýl kódu. Invarianty capture/transcript
  pipeline sú popísané v `README.md` — neporušuj ich bez explicitného zadania.
- Pri oprave chyby hľadaj príčinu a over konkrétny scenár, ktorý ju vyvoláva.
- Spúšťaj kontroly a testy primerané zmene. Netvrď, že niečo funguje, ak si to
  neoveril.
- Rozlišuj medzi úspešnou kompiláciou, úspešnými testami a overením správania
  aplikácie. To nie sú zameniteľné tvrdenia.
- Po dokončení stručne uveď: čo sa zmenilo, čo bolo overené, čo zostáva
  blokované.

CI-štýl kontrola kompilácie a testov (nepodpísaný build, **nikdy** neinštalovať
ani nespúšťať):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project MeetingScribe.xcodeproj \
  -scheme MeetingScribe \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Prostredie a prístup k nástrojom

Claude beží v tomto projekte vo viacerých prostrediach a líšia sa v tom, čo
shell dosiahne. **Najprv zisti, kde si, až potom si vyberaj postup.** Stačí
`uname -s` a `ls /Applications/Xcode.app`.

- **Shell priamo na hostiteľskom macOS** (Claude Code v desktopovej aplikácii):
  `xcodebuild`, `swift test` aj `codesign` sú k dispozícii priamo. Build daemon
  nepotrebuješ, hoci ho použiť môžeš.
- **Izolovaný Linux sandbox** (`mcp__workspace__bash`): nemá Xcode, `codesign`,
  login Keychain ani wrapper `xclaude`. Build a podpis rieš cez build daemon
  nižšie. Sandboxové zlyhanie podpisu (napr. `CSSMERR_TP_NOT_TRUSTED`) nie je
  dôkaz o chybnom certifikáte — zopakuj kontrolu mimo sandboxu.

Nepodpísaný CI-štýl build a obe testovacie sady sú bezpečné v oboch
prostrediach. Inštaláciu a spustenie aplikácie rob len tam, kde vieš splniť
podpisové kontroly z `AGENTS.md`. Ak k nástroju prístup nemáš, otvorene to
povedz a vyžiadaj si len to, čo je pre danú úlohu potrebné.

### Build daemon

Keď shell nedosiahne Xcode, máš k dispozícii súborovú frontu, ktorú na hoste
vykonáva LaunchAgent `com.meetingscribe.assistant-build`. Používaj ju namiesto
tvrdenia, že si build neoveril:

```sh
python3 scripts/assistant_build_client.py status
python3 scripts/assistant_build_client.py ping
python3 scripts/assistant_build_client.py fetch
python3 scripts/assistant_build_client.py test --ref <vetva>
python3 scripts/assistant_build_client.py test --only-testing MeetingScribeTests/ProcessingQueueTests
python3 scripts/assistant_build_client.py build-signed --ref origin/main
python3 scripts/assistant_build_client.py codesign-verify
python3 scripts/assistant_build_client.py install
python3 scripts/assistant_build_client.py session-report
python3 scripts/assistant_build_client.py push-branch --branch codex/<vetva>
python3 scripts/assistant_build_client.py await <id>
```

`push-branch` prijíma **iba vetvy `codex/*`**
(`scripts/assistant_build_daemon.py`, `PUSHABLE_BRANCH_PATTERN`), takže vetvu
`claude/*` cez daemon nepushneš — buď ju pomenuj inak, alebo pushni ručne mimo
sandboxu. `session-report` je read-only prehľad stavu spracovania nahrávok;
obsah schôdzok nevydáva.

Exit kód 0 znamená `succeeded`. Klient vypíše kroky, padnuté testy, kompilačné
chyby a chvost logu; plný log je v `.claude/build-queue/logs/<id>.log`. Joby
`test` a `build-signed` môžu trvať desiatky minút — `mcp__workspace__bash` volaj
s dostatočným `timeout_ms`, alebo pošli request s `--no-wait` a dopolluj
príkazom `await <id>`.

Ak `status` ukáže, že daemon nebeží, požiadaj používateľa o
`scripts/install-assistant-build-daemon.sh` a dovtedy neoverené tvrdenia
označuj ako neoverené. Protokol, joby a bezpečnostný model sú v
`docs/assistant-build-daemon.md`.

`install` nahradí `/Applications/MeetingScribe.app` a daemon ho povolí len pre
commit, ktorý je práve na `origin/main` (lokálny `main` nestačí; ak je
remote-tracking ref zastaraný, spusti najprv `fetch`). Non-main inštaláciu
odomkne iba používateľ
súborom `.claude/build-queue/ALLOW_NONMAIN_INSTALL` — nepýtaj si ju bez dôvodu
a nikdy ju neobchádzaj.

Nikdy netvrď, že si upravil súbory, spustil testy alebo zostavil aplikáciu, ak
si tie kroky skutočne nevykonal.
