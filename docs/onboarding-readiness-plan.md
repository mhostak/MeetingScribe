# Onboarding a kontrola pripravenosti

Návrh a zadanie pre BlueCode, 16. 9. 2026. Implementácia bola delegovaná cez BlueCode Responses transport v Codex CLI po tom, čo preklad OpenAI → Anthropic v gatewayi blokoval viacstupňový tool-use cez `xclaude`. Poskytovateľ BlueCode zostal zachovaný. Kód všetkých troch úloh je integrovaný s novšou frontou spracovania z `origin/main` (`cb11b9f`). Nezávisle prešlo 319 SwiftPM testov (6 preskočených) a nepodpísané CI zostavenie schémy MeetingScribe. Manuálny zvukový test na podpísanej aplikácii ešte neprebehol.

## Podklad a súčasný stav

Zdroj: `/Users/martin_hostak/Documents/md-wiki/MeetingScribe/napady-na-vylepseni.md`, položka „Onboarding a kontrola připravenosti“ a priorita A „Onboarding při prvním spuštění“.
Overený lokálny HEAD: `7109bd92132ed0d917fdaed48fb75b6133e4cba4`.

Vault žiada vysvetlenie aplikácie, oprávnenia, výstup, modely, kontrolu pripravenosti a krátky test. Jeho zmienka o inštalácii **oboch modelov** nezodpovedá tomuto checkoutu: `FluidAudioModelDescriptor.supported` a nastavenia teraz ponúkajú jeden transkripčný model Parakeet v3. Návrh preto používa aktuálny register podporovaných modelov; nepridáva druhý model podľa historického textu.

Existujúce stavebné prvky:

- `AppWindowCoordinator` spravuje samostatné okná a menu-bar popover.
- `SettingsView` poskytuje správu modelu, výstupu a AI; `refreshAnalysisToolStatus()` overuje CLI a prihlásenie.
- `OutputFolderStore` obnovuje bookmark a spravuje security-scoped prístup. Bez vlastnej zložky sa výstup ukladá do zložky relácie.
- `StorageGuard` stráži úložisko nahrávok, minimálne 1 GiB. `SessionManager.startSession()` dnes vytvára režim systém + mikrofón.
- Chýbajúci model neblokuje nahrávanie; odhalí sa pri následnom prepise. Online capture toleruje nedostupný mikrofón.

## Navrhované používateľské riešenie

Jedno samostatné okno **Pripraviť MeetingScribe** so štyrmi krokmi a trvalý vstup **Kontrola pripravenosti** v nastaveniach a popoveri. Okno zostane otvorené pri prechode do systémových nastavení. Každý krok možno opustiť a neskôr pokračovať.

1. **Vitajte.** Stručne: nahrávanie → lokálny prepis → Markdown; AI je voliteľná a môže odosielať transcript poskytovateľovi. Výber jazyka rozhrania; jazyk prepisu a výstupu zostanú samostatné existujúce voľby.
2. **Zvuk a oprávnenia.** Samostatné riadky pre systémový zvuk a mikrofón s dôvodom prístupu, stavom a akciou „Povoliť“ alebo „Otvoriť systémové nastavenia“. Systémový dialóg až po kliknutí. Po návrate obnoviť stav; ak sa zmena ešte neprejavila, ponúknuť opätovnú kontrolu a vysvetliť možnú potrebu reštartu. Nevykonávať automatický reštart.
3. **Prepis a miesto uloženia.** Existujúce ovládanie stiahnutia/importu/opravy modelu s veľkosťou a priebehom. Explicitná voľba „Použiť zložku nahrávky“ alebo „Vybrať zložku“. Overiť zápis, nielen existenciu cesty. AI zostane voliteľným odkazom na existujúce nastavenia.
4. **Kontrola a skúška.** Zoznam výsledkov s konkrétnou opravnou akciou a tlačidlá „Spustiť 10-sekundový test“, „Dokončiť“ a „Dokončiť bez testu“. Test nie je podmienkou používania aplikácie.

Pri prvom spustení otvoriť sprievodcu raz. „Neskôr“ uloží rozpracovanosť a ponechá nenásilnú pripomienku v popoveri. Pri existujúcej inštalácii ponúknuť kontrolu v popoveri bez vynúteného okna; migráciu rozlíšiť podľa existujúcich nastavení alebo záznamov až po načítaní úložiska. Prebiehajúce nahrávanie alebo recovery nesmie prekryť onboarding.

## Význam stavov a blokovanie

Každá položka má stav „Kontrolujem“, „Pripravené“, „Vyžaduje zásah“, „Neoverené“ alebo „Voliteľné“. Oddelene nesie dopad: blokuje nahrávanie, obmedzuje následné spracovanie alebo iba informuje. Farbu vždy dopĺňa text a ikona.

| Kontrola | Výsledok pri probléme | Akcia |
| --- | --- | --- |
| Systémový zvuk pri systémovom capture | Blokuje daný režim nahrávania | Povoliť prístup / systémové nastavenia |
| Mikrofón pri systém + mikrofón | Varovanie: zaznamená sa iba systémový zvuk | Povoliť mikrofón; zachovať existujúci fallback |
| Mikrofón pri prípadnom podporovanom microphone-only režime | Blokuje daný režim | Povoliť / pripojiť vstup; nepridávať nový výber režimu v tomto projekte |
| Zápis a kapacita úložiska relácií | Blokuje nahrávanie podľa existujúceho StorageGuard | Uvoľniť miesto / opraviť prístup |
| Transkripčný model | Nahrávanie možné, automatický prepis nepripravený | Stiahnuť / importovať / opraviť |
| Cieľ exportu a šablóna názvu | Export nepripravený; zachovať existujúcu validáciu pred štartom | Vybrať cieľ / použiť zložku relácie / opraviť šablónu |
| AI zapnutá, CLI alebo prihlásenie nefunkčné | AI nepripravená, lokálny prepis môže fungovať | Existujúce nastavenia AI / vypnúť AI |
| AI vypnutá | Voliteľné | Žiadna povinná akcia |
| Kalendár a notifikácie | Voliteľné, neblokujú | Odkaz na nastavenia, bez automatickej žiadosti |

Súhrn v popoveri: **Pripravené na nahrávanie a prepis**, **Nahrávanie pripravené · prepis vyžaduje nastavenie** alebo **Nahrávanie vyžaduje nastavenie**. Stav AI zobrazovať osobitne. Nikdy neoznačiť oprávnenie za dôkaz funkčného zvuku.

Kontrolu obnoviť pri otvorení prehľadu, aktivácii aplikácie, zmene relevantných nastavení a dokončení inštalácie modelu. Pred nahrávaním vykonať rýchle lokálne kontroly; existujúce kontroly počas skutočného štartu capture a zápisu zostávajú rozhodujúce. Neznámy stav vysvetliť, nepremeniť ho automaticky na zamietnuté oprávnenie. Pomalé CLI kontroly nesmú držať tlačidlo nahrávania.

## Krátky test

Po výslovnom kliknutí spustiť bežnú capture cestu na najviac 10 sekúnd s viditeľným odpočtom a tlačidlom „Zastaviť test“. Požiadať používateľa, aby povedal krátku vetu a pri systémovom teste spustil zvuk. Ticho nie je automaticky chyba oprávnenia: rozlíšiť príchod bufferov a zaznamenanú zvukovú aktivitu.

Test vytvorí vlastnú reláciu označenú ako testovacia, bez prevzatia rozpracovaného názvu alebo vybranej kalendárovej udalosti. Po ukončení zobrazí výsledok každej stopy; pri dostupnom modeli aj prepis a overenie Markdown exportu. AI sa pri teste nespúšťa. Výsledky sa uložia ako bežné lokálne artefakty a používateľ vopred vidí miesto uloženia; nesľubovať automatické mazanie. Test podlieha bežným pravidlám obnovy a uchovania audia.

Chýbajúci model umožní audio test s označením „Prepis nebol overený“. Test sa nesmie spustiť počas nahrávania, spracovania alebo obnovy. Zatvorenie okna musí bezpečne ukončiť capture testu; pokračujúce spracovanie je viditeľné v existujúcom prehľade. Timeout, dvojklik ani zatvorenie nesmú spustiť druhú reláciu alebo dvakrát finalizovať súbory.

## Technický návrh

- `ReadinessService` zbiera nemenný snapshot jednotlivých kontrol cez injektovateľné adaptéry; `ReadinessEvaluator` čisto vyhodnocuje dopad podľa skutočného capture režimu a konfigurácie.
- `ReadinessCheck` nesie stabilné ID, stav, lokalizačný kľúč, dopad a typovanú opravnú akciu. Snapshot má čas kontroly; starší async výsledok nesmie prepísať novšiu konfiguráciu.
- `OnboardingStore` persistuje verziu sprievodcu, aktuálny krok a dokončenie/odloženie. Oprávnenia a výsledky kontrol sa nepersistujú ako trvalá pravda.
- `OnboardingView` a `ReadinessView` používajú rovnaké výsledky. Spoločné ovládanie modelu a výstupu extrahovať z existujúcich nastavení iba v nevyhnutnom rozsahu.
- `AppWindowCoordinator` vlastní jedno onboarding okno. `AppState` iba koordinuje služby a existujúce capture/processing operácie; nepridávať ďalšiu monolitickú kontrolnú vetvu.
- Pri kontrole výstupu vytvoriť a odstrániť iba vlastný náhodne pomenovaný skúšobný súbor v security-scoped prístupe, bez prepisovania obsahu. Chybu upratovania oznámiť.
- Pasívny refresh nesmie nahrávať, sťahovať model, žiadať oprávnenia ani posielať transcript. Explicitné CLI overenie používa existujúci adaptér a jeho timeouty.

Mimo rozsahu: výber audio zariadení/aplikácií, nový capture režim, súbežné spracovanie, nové modely, správa rečníkov a distribúcia aplikácie.

## Zadanie pre BlueCode

Použi existujúci wrapper `bash /Users/martin_hostak/.local/bin/xclaude -p '<zadanie>' --model DeepSeek-V4-Flash --output-format text`. Pre komplexné ladenie/refaktoring použi `GLM-5.3`, ak je dostupný. Do každého zadania vlož tento dokument a aktuálny `AGENTS.md`; neodovzdávaj prihlasovacie údaje. Pri nedostupnom BlueCode oznám blocker, nemen poskytovateľa.

Pracuj postupne v samostatnej vetve/izolovanom worktree s overeným východiskovým commitom. Zachovaj existujúce používateľské zmeny vrátane AGENTS.md, dist/ a ostatných návrhov v docs/. Pri súbežných úlohách je oddelený worktree povinný. Nepushuj, nenasadzuj a nemeň globálnu konfiguráciu poskytovateľa. Nepoužívaj XCLAUDE_BYPASS ani permission-bypass flags.

### Úloha 1 — služba pripravenosti

Rozsah: dátové typy, adaptéry existujúcich kontrol, čisté vyhodnocovanie, obnova snapshotu a jednotkové testy. Bez nového UI a bez zmeny capture pipeline.

Akceptácia: tabuľka vyššie je pokrytá testami; AI off a chýbajúci model neblokujú audio; nedostatok miesta a zamietnuté povinné oprávnenie majú správny dopad; pasívna kontrola nemá aktívne vedľajšie účinky; oneskorený výsledok sa nepriradí novej konfigurácii. Testy používajú adaptéry, bez skutočných TCC dialógov, sťahovania alebo loginu.

Overenie: `swift test --filter Readiness` a `swift test --filter StorageGuardTests`.

### Úloha 2 — sprievodca a trvalý prehľad

Závisí od úlohy 1. Rozsah: onboarding store, štyri kroky, jediné samostatné okno, vstupy z popoveru a nastavení, SK/CZ/EN lokalizácia. Opätovne použiť model/output/AI služby.

Akceptácia: nový používateľ vidí sprievodcu raz; odloženie a pokračovanie fungujú po reštarte; existujúci používateľ dostane nenásilnú ponuku; návrat zo systémových nastavení aktualizuje výsledky; povolenia a download sa spustia iba po explicitnej akcii; recovery má prednosť. Klávesnicové ovládanie a textové rozlíšenie stavov fungujú bez farieb.

Overenie: `swift test --filter Onboarding`, `swift test --filter OutputFolderAndObsidianTests`, CI compile príkaz nižšie a manuálna kontrola troch jazykov na podpísanej aplikácii.

### Úloha 3 — desaťsekundový test a integrácia

Závisí od úlohy 2. Rozsah: bezpečne ohraničený test cez existujúcu capture/finalization cestu, výsledky stôp, voliteľný lokálny prepis/export, dokumentácia v README. Nenahrádzať normálne nahrávanie vlastnou implementáciou.

Akceptácia: timer aj ručné zastavenie finalizujú reláciu práve raz; súbeh je odmietnutý; zatvorenie okna zastaví capture; model missing je zrozumiteľný čiastočný výsledok; AI sa nespustí; rozpracovaný názov a kalendár sa zachovajú; zlyhanie testu zostane obnoviteľné. Ticho sa nezamieňa s chýbajúcimi buffermi.

Overenie: `swift test --filter Onboarding`, `swift test --filter CaptureCoordinatorTests`, `swift test --filter AppStateResilienceTests`, potom `swift test` a CI compile.

### Spoločné overenie, podpis a odovzdanie

CI compile bez spúšťania aplikácie:

```sh
xcodebuild -project MeetingScribe.xcodeproj -scheme MeetingScribe -configuration Debug -derivedDataPath /private/tmp/MeetingScribe-onboarding-ci CODE_SIGNING_ALLOWED=NO build
```

Tento unsigned bundle je iba compile validácia. Každý build odovzdaný alebo spustený používateľovi musí dodržať celý aktuálny AGENTS.md: čistý checkout požadovaného commitu, lokálny ignorovaný Signing.local.xcconfig, overenie presnej identity a Team ID mimo sandboxu, manuálne podpisovanie, `codesign --verify --deep --strict --verbose=4`, kontrola Authority/TeamIdentifier a SHA-1 extrahovaného certifikátu. Identity lookup, signed build aj codesign trust checks vykonať escalated mimo sandboxu. Nedostupná nakonfigurovaná identita je blocker, bez fallbacku. Pred výmenou ukončiť staré procesy a po spustení overiť jedinú zamýšľanú cestu.

Push nie je súčasťou zadania. Ak bude neskôr výslovne autorizované pristátie na main, workflow musí pokračovať presným origin/main commitom, podpísaným buildom, overením, náhradou /Applications/MeetingScribe.app, opätovným overením a spustením podľa AGENTS.md.

Manuálna akceptácia na podpísanom builde: čerstvý profil; odloženie a reštart; odmietnuté a dodatočne povolené oprávnenie; systémový záznam bez mikrofónu; chýbajúci model; nedostupný externý export; AI off a nezalogovaná AI; test s rečou aj tichom; zatvorenie testu; recovery; existujúca inštalácia. TCC oprávnenia používateľa neresetovať automaticky.

BlueCode po každej úlohe odovzdá zoznam zmien, výsledky príkazov a zostávajúce obmedzenia. Orchestrátor nezávisle skontroluje diff a zopakuje relevantné testy. Za dokončené sa riešenie považuje až po kontrole všetkých troch úloh; compile úspech nenahrádza manuálny audio test.
