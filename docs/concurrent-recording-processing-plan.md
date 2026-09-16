# Souběžné nahrávání a transkripce dokončeného záznamu

Implementačný plán pre agentov Tera · 2026-09-16 · stav: pripravené na implementáciu.

## 1. Východiská a cieľ

Zdroj požiadavky: `/Users/martin_hostak/Documents/md-wiki/MeetingScribe/napady-na-vylepseni.md`, sekcia „Souběžné nahrávání a transkripce dokončeného záznamu“.

Plán bol overený proti lokálnemu commitu `7109bd92132ed0d917fdaed48fb75b6133e4cba4` („Notify users when processing completes“). Lokálny ref `origin/main` ukazuje na rovnaký commit; pri príprave plánu nebol vykonaný fetch. Pred implementáciou aktualizovať remote a skontrolovať rozdiely. Vault opisuje aj implementovanú diarizáciu, ale tento checkout jej runtime výslovne označuje za vyradený a zachováva kompatibilné artefakty. Obnova diarizácie nie je súčasťou tejto úlohy; ak nový základ obsahuje aktívnu diarizáciu, zaradiť ju do toho istého spracovacieho slotu a ochrany zdrojov.

**Výsledok:** používateľ zastaví záznam A, aplikácia bezpečne uzavrie audio a uloží požiadavku na spracovanie. Potom môže okamžite začať B, hoci A ešte finalizuje audio, transkribuje, analyzuje alebo exportuje. Ďalšie dokončené záznamy čakajú vo fronte. Chyba A nemení nahrávanie B.

Prvá verzia podporuje jednu aktívnu capture reláciu a najviac jeden spracovávací job cez celú pipeline. Jednotlivé audio stopy sa naďalej prepisujú sekvenčne. Nepridávať live transcript, viac súbežných ASR jobov, priorizáciu pretiahnutím ani nový ASR engine.

## 2. Zistenia v existujúcom kóde

| Miesto | Súčasné správanie | Dôsledok pre implementáciu |
|---|---|---|
| `App/AppState.swift`: `performStopRecording`, `processStoppedSession`, `completeProcessedSession` | Stop čaká na celú pipeline. Dokončenie volá `stopSession()`, nuluje `currentSession`, titulok a kalendár. | Oddeliť stop/handoff od jobu; starý job nikdy nesmie resetovať nový capture ani jeho formulár. |
| `Sessions/SessionManager.swift` | `activeSession` slúži capture aj recovery; stop/fail nemajú parameter ID. | Uvoľniť capture pri odovzdaní; dokončovať a zapisovať podľa ID a pokusu. |
| `App/AppStatus.swift` | Jeden globálny automat, ikona vyberá jeden prioritný stav. | Samostatný capture stav a stavy jobov; odvodená kombinovaná ikona. |
| `App/AppState.swift`: reprocess/reanalyze/recovery | Globálne busy guardy, ID revízie a notifikačného pokusu. | Všetky vstupy spracovania musia používať jeden scheduler. |
| `Transcription/SessionTranscriber.swift` | Sekvenčné stopy, release modelu po relácii; ukladanie artefaktov medzi krokmi. | Zachovať, doplniť bezpečné checkpointy a job kontext. |
| `Transcription/FluidAudioTranscriptionService.swift` | `parallelChunkConcurrency = 4`; `manager.transcribe(audioURL, …)` spracúva celú stopu; cache managera porovnáva URL modelu. | Overiť reálne rušenie a zmeny konfigurácie; cache musí zohľadniť aj profil výkonu. |
| `Capture/CaptureCoordinator.swift` | Má samostatný lifecycle a zdieľané start/stop tasky. | Znovu použiť existujúcu ochranu; nevytvárať druhý nezávislý capture engine. |
| `Sessions/RecordingSession.swift` | Audio, manifest a log sú už viazané na adresár relácie. | Zachovať izoláciu; problém je vlastníctvo mutácií, nie chýbajúce adresáre. |
| `App/RecordingsWindow.swift`, `MeetingScribeApp.swift` | Obnova UI a ikony závisí od globálneho statusu. | Pozorovať capture aj frontu; status každého riadku podľa session ID. |
| `Capture/AudioFinalizer.swift` a cleanup v `AppState` | Retencia/cleanup tiež zapisujú manifesty. | Zahrnúť do jedného pravidla vlastníctva, zabrániť prepisu čerstvých údajov. |

Cesty v tabuľke sú relatívne ku `MeetingScribe/`.

## 3. Záväzné invarianty

1. Najviac jedna capture relácia a jeden aktívny worker. Actor sám o sebe negarantuje serializáciu cez `await`; slot sa rezervuje pred prvým suspension pointom.
2. Po odovzdaní A všetky jej callbacky, chyby, zápisy a notifikácie nesú `sessionID`, `jobID` a `attemptID`. Oneskorená udalosť starého pokusu sa ignoruje.
3. Spracovanie nikdy nevolá operáciu typu „fail aktuálnu reláciu“. Capture operácie majú očakávané ID; nezhoda nesmie mutovať inú reláciu.
4. Nový capture sa povolí až po ukončení a flushnutí oboch writerov a úspešnom trvalom handoff zápise. Nečaká na ASR, AI ani export.
5. Chyba ASR/AI/exportu nezastavuje capture a nemaže jeho diagnostiku, názov, kalendár ani nastavenia.
6. Fronta prežije reštart. Žiadny automatický nekonečný retry; zlyhaný job uvoľní slot pre ďalší.
7. Audio aktívnych, čakajúcich, pozastavených a opakovaných jobov sa nesmie zmazať retenciou.
8. Pozastavenie má pravdivú sémantiku: rozlišovať `pauseRequested` od skutočného `paused`. Slot sa uvoľní až po ukončení worker tasku a uvoľnení jeho zdrojov.
9. `endedAt` je čas konca nahrávania, nie konca pipeline. Diagnostika A je nemenný snapshot pri stopnutí.
10. Úspech jobu vyplýva z výsledkov krokov. Existujúce `.recorded` v manifeste samo neznamená úspešnú transkripciu či export.

## 4. Architektúra a kontrakty

Navrhnuté nové súbory sú cieľový návrh, nie existujúce API.

### Capture vrstva

`App/CaptureController.swift`: `@MainActor` model vlastní capture stav, session ID, diagnostiku a start/stop tasky. Volá existujúci `CaptureCoordinator` a per-session repository. Presunúť doň monitoring úložiska, výpadkov zdrojov a stop z dôvodu chyby. Alternatívne prvý integračný commit môže ponechať tenkú delegáciu v `AppState`, ale jediným vlastníkom capture stavu je controller.

`CaptureState`: `idle`, `preparing`, `recording`, `stopping`, `failed`. Stav nesie vhodný session kontext; chyba sa dá zobraziť a resetovať bez zásahu do jobov.

`stopAndEnqueue()` vráti až po trvalom handoff. Dvojitý Stop zdieľa jednu operáciu. Reset formulára pre ďalšiu schôdzku sa vykoná tu, nie pri dokončení A. Reentrantné start/stop/rename/calendar operácie kontrolujú očakávané ID po každom relevantnom `await`.

### Repository a persistencia

Rozšíriť `SessionManager` na autoritatívny prístup k manifestom podľa ID; podľa rozsahu ho rozdeliť na capture správu a `SessionRepository`. Nesmú vzniknúť dva súbežné zapisovače toho istého manifestu.

Navrhované kontrakty:

- `finishCaptureAndQueue(expectedSessionID:endedAt:diagnostics:configuration:) -> ProcessingJobSnapshot`
- `commitProcessing(sessionID:jobID:attemptID:patch:)`
- `loadPendingJobs() -> [ProcessingJobSnapshot]`
- `beginRecovery(sessionID:configuration:) -> ProcessingJobSnapshot`
- `acquireMutationLease(sessionID:purpose:)` pre revízie/cleanup, ak nie sú všetky mutácie vykonané priamo repository.

Repository načíta najnovší manifest, overí ID/pokus a aplikuje patch. Nepersistovať starú celú kópiu `RecordingSession`, ktorá by prepísala novšie `keepsRecordingAudio`, kalendár alebo výsledky. Atomický zápis súboru rieši poškodenie pri páde, nie stratené aktualizácie.

**Zdroj pravdy fronty:** nový voliteľný `processing` blok v `session.json`; žiadny druhý autoritatívny globálny queue súbor. Jeden atomický zápis uloží endedAt, diagnostiku, `.recorded` a pending job. Až po úspechu uvoľniť capture vlastníctvo. Ak zápis zlyhá, zachovať zastavenú reláciu ako čakajúcu na opakovanie handoff; opakovanie nesmie znovu spustiť audio ani vytvoriť druhý job. Pri páde pred zápisom funguje legacy recovery; po zápise sa obnoví fronta.

`processing` obsahuje `schemaVersion`, `jobID`, `attemptID`, `kind`, `enqueuedAt`, stav, posledný dokončený checkpoint, časové údaje, chybu a konfiguračný snapshot. FIFO zoradiť podľa `(enqueuedAt, jobID)`; opakovaný pokus ide na koniec. Predchádzajúce pokusy ostávajú v logu, manifest obsahuje aktuálny pokus. Staré manifesty bez bloku musia zostať čitateľné. Neznámu budúcu verziu nezaraďovať automaticky; zobraziť problém konkrétnej relácie.

### Fronta a worker

`Processing/ProcessingQueue.swift`: actor vlastní pending joby, worker task, rezervovaný slot a stream snapshotov. `enqueue`, `retry`, `requestPause`, `resume` nemenia capture stav. Rovnaká relácia nemá dva neterminálne joby; duplicitná požiadavka vráti existujúci job. Revízia a reanalysis idú rovnakým slotom ako bežné spracovanie.

`Processing/ProcessingJob.swift`: `ProcessingJobKind = initial | recovery | retranscribe | reanalyze`; `ProcessingJobState = queued | running(stage) | pauseRequested(reason) | paused(reason) | completed | failed(error)`. Kroky znovu využívajú `ProcessingStepID`. Percentá zobrazovať iba tam, kde ich engine skutočne poskytuje; inak fázu a čakajúce poradie.

`Processing/SessionProcessor.swift`: injektovateľný `SessionProcessing` protokol. Vstup tvorí nemenný job kontext, výstup výsledok a udalosti identifikované pokusom. Žiadna referencia na mutable UI `AppState`. Pipeline: finalizácia → transkripcia → voliteľná analýza → export → bezpečný cleanup → terminal commit/notifikácia. Recovery môže preskočiť validné checkpointy; reanalysis musí zachovať pôvodný transcript.

Pre každý krok perzistovať výsledok až po atomickom uložení validných artefaktov. Po páde medzi artefaktom a checkpointom možno krok bezpečne zopakovať alebo artefakt validovať; nikdy iba veriť existencii súboru. Pri retry exportu zachovať identitu výstupu a existujúce kolízne pravidlá, aby nevznikali duplicity alebo prepis inej schôdzky.

Konfigurácia relácie sa zmrazí pri štarte: jazyk, AI nastavenia, titulok/kalendár podľa doterajších pravidiel. Pri enqueue zmraziť aj výstupný adresár a politiku automatického source cleanup. Pri reanalysis/retranscribe použiť explicitný snapshot požiadavky. Neskoršia zmena Settings ovplyvní nové požiadavky. Nepersistovať tajomstvá ani tokeny do manifestu. Nedostupný výstupný adresár je chyba konkrétneho jobu, nie dôvod zapisovať inde.

### UI fasáda

`AppState` zostane fasádou pre settings, capture snapshot a `[ProcessingJobSnapshot]`. Nahradiť behaviorálne guardy odvodenými capabilities: `canStartRecording`, `canStopRecording`, `canEnqueueProcessing(sessionID:)`, `canMutateSession(sessionID:)`, `canDeleteModel`. Globálny `AppStatus` môže krátko zostať kompatibilnou projekciou pre migráciu, ale nesmie rozhodovať o povolení súbehu.

## 5. Ochrana nahrávania a zdrojov

Toto je samostatný blokujúci technický spike pred produktovým zapnutím súbehu.

- Overiť pripnutú FluidAudio verziu a jej lokálny zdroj: ruší sa naozaj bežiaca inferencia? Aká je latencia? Dá sa meniť chunk paralelizmus počas existujúceho managera? Sú dostupné bezpečné hranice na pause/resume? Neodvodzovať z toho, že API je `async`.
- Prvá kandidátna politika: jeden ASR worker s `parallelChunkConcurrency = 1` aj pred začiatkom ďalšieho capture. Tým nevznikne problém rozbehnutého jobu s profilom 4 práve pri štarte B. Predvolenú 4 možno neskôr obnoviť iba mimo capture po meraní a bezpečnej zmene managera.
- Worker spúšťať s utility prioritou a mimo MainActor. Priorita tasku sama negarantuje CPU/GPU/pamäťový limit; nie je splnením požiadavky na ochranu capture.
- `ProcessingResourceGovernor` vyhodnocuje capture lifecycle, memory pressure, thermal state, storage reserve a dostupné capture diagnostiky. CPU/GPU vyťaženie a disk I/O merať pri záťažových testoch; nepredstierať pevný limit GPU pomocou task priority.
- Pri tlaku zastaviť prijímanie ďalšieho náročného kroku. Bežiaci krok kooperatívne zrušiť/pozastaviť, počkať na jeho skončenie, uvoľniť model a potom zobraziť `paused`. Pri resume obnoviť od posledného validného checkpointu; v MVP môže byť hranicou celá stopa, nie ASR chunk.
- Ak SDK nedokáže včas prerušiť inferenciu, spike musí navrhnúť a overiť izolovaný worker proces alebo skutočné checkpointy podporované SDK. Bez toho neoznačiť ochranu za hotovú. Konzervatívny režim „počas nahrávania čaká“ je bezpečný fallback, ale nesplní plnú akceptáciu súbežnej transkripcie.
- Rovnaké pravidlo zahrnúť pre finalizáciu audia a lokálny CLI proces AI analýzy. Prerušenie CLI musí skutočne ukončiť vlastnený proces a zachovať platné predošlé výsledky. Neprerušovať cudzie procesy podľa mena.
- Disková rezerva musí počítať s pracovnými artefaktmi a nahrávaním. Pri nízkej kapacite najprv pozastaviť background zápisy; existujúci bezpečný stop capture pri vyčerpávaní miesta zostáva poslednou ochranou.
- Hromadný scan a retenciu v MVP odložiť, kým capture aj fronta nie sú nečinné. Pri resume používať hysteréziu, aby stav nekmital; limity a intervaly sú injektovateľné a finálne hodnoty sa odvodia z meraní.

## 6. Recovery, retry a ukončenie aplikácie

Pri štarte najskôr rekonštruovať frontu z manifestov. `queued` obnoviť v poradí; `running` a `pauseRequested` po páde zmeniť na prerušené/čakajúce od posledného validného checkpointu, so zaznamenaním novej execution generácie. Ručne pozastavené položky ponechať pozastavené; resource pause znovu vyhodnotiť. `failed` vyžaduje Retry. Dokončené nepúšťať znovu.

Legacy recovery zostáva dostupné pre manifest bez novej fronty a poškodené artefakty. Scanner musí vylúčiť všetky relácie vlastnené capture/frontou, nielen jednu `activeSession`. Pending recovery inej relácie prestane globálne blokovať nový capture. Problém adresára alebo kapacity samotného recordings root ho naďalej blokuje.

Recovery nesmie nastavovať spracovávanú reláciu ako aktívne nahrávanie. Opätovná analýza, retranskripcia, close recovery, rename historickej relácie a cleanup používajú zámok/mutácie konkrétneho ID. Mazanie modelu je nedostupné, pokiaľ ho job používa alebo má rezervovaný; import/replace toho istého modelu má rovnakú ochranu.

Zatvorenie popoveru alebo okna frontu neruší. Pri Quit počas capture aplikácia ponúkne bezpečné zastavenie a uloženie; pri background práci uloží checkpoint/stav a riadene ukončí vlastnené tasky/procesy. Vynútené ukončenie pokrýva startup recovery. Nepotrebovať aktívne UI na životnosť worker tasku.

Notifikácia používa per-job attempt ID a odkaz na správnu reláciu aj počas nahrávania B. Deduplikovať v rámci behu; terminal stav uložiť pred notifikáciou. Pri štarte neposielať spätne všetky dokončenia. Presne-jeden externý notifikačný side effect cez pád procesu nie je transakčne garantovaný; nesľubovať ho.

## 7. Užívateľské rozhranie

Menu má dve nezávislé sekcie: ovládanie aktuálneho/nového záznamu a „Spracovanie“. Sekcia spracovania ukazuje aktívny job s názvom a krokmi, počet čakajúcich, kompaktný zoznam a prechod do prehľadu. Pri idle capture je tlačidlo Start dostupné aj počas ASR/AI/exportu. Stop sa vždy vzťahuje iba na capture.

Prehľad záznamov zobrazuje pri každej relácii čaká / konkrétny krok / pozastavuje sa / pozastavené s dôvodom / dokončené / chyba a Retry. Úspešné dokončenie A neprepne výber záznamu B. Zmena fronty aktualizuje riadky bez závislosti od `appState.status`; pri reload počas prebiehajúceho loadu naplánovať ďalší refresh, aby sa udalosť nestratila existujúcim `isLoading` guardom.

Ikona pridá kombinovaný stav `recordingAndProcessing`. Pri nahrávaní s pozastavenou frontou zostáva viditeľné nahrávanie; tooltip/accessibility doplní čakajúce položky a chybu. Pozornosť nesmie prekryť indikátor aktívneho nahrávania. Matica projekcie zahŕňa aj preparing/stopping a chybu iného jobu. Overiť svetlý/tmavý režim a malý status bar rozmer. Nové texty doplniť do `Localizable.xcstrings` pre existujúce jazyky.

## 8. Rozdelenie práce pre agentov Tera

Každý balík je samostatná odovzdateľná úloha. Agenti majú vlastný worktree a vetvu `codex/concurrent-<id>`. Jeden integrátor vlastní `AppState.swift` a projektový súbor; ostatní navrhujú potrebné integračné body v handoff. Najprv dohodnúť kontrakty, až potom paralelné implementácie. Nezadávať viacerým agentom súčasnú úpravu rovnakého manifestového modelu.

| ID | Úloha a vlastník súborov | Závislosti | Povinný výsledok |
|---|---|---|---|
| T0 | Audit základu a kontrakty; `docs/` | — | Commit základu, potvrdený runtime/SDK, typy a signatúry, testovací baseline, zoznam migrovaných guardov. |
| T1 | Spike zdrojov; izolovaný prototyp runnera a evidence | T0 | Merania cancellation/pamäte/capture, realizovateľná politika pause, rozhodnutie go/no-go. |
| T2 | Job model a repository; `Sessions/SessionManager.swift`, `SessionMetadata.swift`, nové processing typy | T0 | Atomický handoff, per-ID patch, kompatibilita manifestov, idempotencia, testy pádu. |
| T3 | Extrakcia pipeline; nový `SessionProcessor`, processing adapters | T2 | Pipeline nezávislá od UI, per-attempt udalosti, snapshot nastavení, testy každého výsledku. Integrátor odstráni pôvodné metódy z AppState. |
| T4 | Scheduler; nový `ProcessingQueue` a testy | T2 | FIFO, jeden slot aj pri reentrancii, duplicate enqueue/retry, failure isolation, trvalá obnova. Použiť fake processor, nečakať na T3. |
| T5 | Capture integrácia; `CaptureController`, `AppState`, state machine testy | T2–T4 | Stop končí handoffom, nový Start počas A, monitoring oddelený, cleanup A nezmení B. |
| T6 | Resource governor a produkčný runner; ASR/AI/finalizer hooks | T1, T3, T4 | Reálne obmedzenie/pause/resume, uvoľnenie modelov, resource testy a evidencia. |
| T7 | Recovery/revízie/retencia/notifikácie; príslušné služby | T4, T5 | Všetky vstupy cez scheduler, per-ID ochrany, startup/Quit/retry a notifikačné testy. Zmeny AppState odovzdať integrátorovi. |
| T8 | UI; `MenuBarView`, `RecordingsWindow`, model, ikona, lokalizácia | T5, stabilné snapshoty | Súčasné sekcie, per-row stavy, kombinovaná ikona, správne capabilities. `MeetingScribeApp` koordinovať s T7. |
| T9 | Integrácia, regresie, záťaž a release evidencia | T6–T8 | Celá akceptačná matica, podpísaný manuálny test, audit invariantov a zostávajúcich rizík. |

Odporúčané vlny: T0 → paralelne T1/T2 → paralelne T3/T4 → T5 → T6/T7/T8 podľa oddeleného vlastníctva → T9. T1 musí uzavrieť technické rozhodnutie pred implementáciou T6. Nezlúčiť produktové povolenie súbehu pred dokončením T6 a záťažového overenia.

### Šablóna zadania pre každého agenta

> Implementuj iba balík Tn z `docs/concurrent-recording-processing-plan.md` na dohodnutom základnom commite. Prečítaj AGENTS.md a kapitoly 3–6. Dodrž dohodnuté kontrakty, vlastnené súbory a závislosti. Použi injektované služby a deterministické testy; testy nesmú sťahovať ASR model ani spúšťať reálnu AI analýzu. Pri zmene kontraktu najprv odovzdaj presný návrh integrátorovi. Výstup: commit, zoznam zmien, vykonané testy a výsledok, nesplnené akceptačné kritériá a integračné kroky. Neoznačuj mock test za dôkaz produkčného pause ani audio spoľahlivosti. Nevykonávaj merge/push na main ani inštaláciu v rámci čiastkového balíka.

T0 musí každé zadanie doplniť konkrétnymi signatúrami a cestami nových testov. Ak agent narazí na nejasnosť, dokumentuje ju spolu s reprodukciou; nesmie potichu obísť invariant globálnym busy guardom. Integrátor po každom balíku overí build a relevantné testy, až potom sprístupní základ závislým agentom.

## 9. Testovacia a akceptačná matica

Automatické súbehové testy používajú riadené continuations/barriers a fake clock, nie časované sleep ako dôkaz poradia. Fake processor umožňuje držať ľubovoľný krok a doručiť oneskorený callback. Fault-injection repository simuluje zlyhanie atomického zápisu.

| Scenár | Očakávaný dôkaz |
|---|---|
| A v každom kroku; Start B | B nahráva pred uvoľnením bariéry A; údaje B ostávajú nezmenené po dokončení A. |
| A ASR, B stop, C start | A jediný worker, B trvalo queued, C jediný capture; po A beží B. |
| Dvojitý Stop/enqueue/retry a reentrantný drain | Jediný handoff/job/pokus a maximálne jeden procesor. |
| Chyba A vo finalizácii, ASR, AI, exporte alebo cleanup | B pokračuje; chyba patrí A; ďalší oprávnený job beží. Zachovať existujúci použiteľný partial transcript/output. |
| Starý callback A po retry alebo štarte B | Nezmení B ani nový attempt A. |
| Rename/kalendár/nastavenia pri súbehu | Žiadny stale manifest overwrite; job používa svoj snapshot. |
| Pád pred/po handoff a po artefakte pred checkpointom | Ani stratená relácia, ani dvojité zaradenie; recovery pokračuje bezpečne. |
| Reštart s queued/running/paused/failed/completed | Obnoví správne poradie a politiku; completed sa neopakuje. |
| Legacy/poškodený/neznámy manifest | Historické relácie sú čitateľné; chyba izolovaná; B sa zbytočne neblokuje. |
| Reprocess/reanalysis/recovery počas B | Zaradenie do rovnakého slotu; bez druhej inferencie a bez zabratie capture slotu. |
| Retencia, source cleanup a model delete | Aktívne/pending zdroje chránené, žiadne stratené polia manifestu. |
| Resource pause, resume a cancellation | `paused` až po skončení práce; model uvoľnený; validné checkpointy ostávajú; bez duplicitných segmentov. |
| Zlyhanie zápisu handoff | Capture je fyzicky zastavený, stav jasný, opakovaný handoff je bezpečný a Start nepreskočí trvalé uloženie. |
| Disk full počas A aj B | Background práca ustúpi, prípadný stop B zachová audio a samostatnú chybu. |
| Notifikácia A počas B; zavretie UI; Quit | Notifikácia naviguje na A, B nemení; worker žije mimo view; reštart zachová frontu. |
| Rovnaký názov/export čas dvoch relácií | Výstupy sa neprepíšu a retry nevytvára nekontrolované kópie. |

Rozšíriť existujúce `SessionManagerTests`, `AppStateMachineTests`, `AppStateResilienceTests`, `CaptureCoordinatorTests`, `SessionRecoveryTests`, `SessionTranscriberTests`, `FluidAudioTranscriptionServiceTests`, `ProcessingNotificationsTests`, `SessionCatalogTests` a retention/export testy. Pridať `ProcessingQueueTests`, `SessionProcessorTests`, `ProcessingResourceGovernorTests` a `ConcurrentRecordingProcessingTests` podľa finálneho členenia.

Na macOS spustiť relevantné testy priebežne a celý scheme na konci, napríklad:

```sh
xcodebuild -project MeetingScribe.xcodeproj -scheme MeetingScribe \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/MeetingScribe-concurrent-tests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual test
```

Podpis a prístup ku Keychain riešiť podľa AGENTS.md mimo sandboxu. Pred prvým behom overiť dostupnosť nakonfigurovanej identity. Konkrétne test targety a dostupnú konfiguráciu potvrdí T0.

### Manuálne záťažové overenie T9

Použiť syntetické alebo výslovne určené testovacie audio. Zmerať baseline capture bez spracovania a rovnaký vstup s dlhým A vo fronte, B nahrávaním oboch zdrojov a následným C. Aspoň 60 minút aktívneho capture; zahrnúť veľký backlog, CPU/I/O záťaž, memory pressure, zmenu audio zariadenia a nedostatok miesta v kontrolovanom testovacom prostredí.

Do `docs/evidence/concurrent-recording-processing-<date>.md` uložiť: commit, podpis, Mac/RAM/macOS, SDK/model a profil, dĺžky vstupov, start/stop latencie, buffer/frame diagnostiky, výslednú dĺžku a kontinuitu audia, peak RSS, CPU/GPU/disk merania, ASR wall time a pause latenciu. Diagnostické počítadlá samy nevylúčia tiché výpadky; overiť aj výsledné audio proti známemu vstupu.

Predbežný UX cieľ: Start dostupný do 2 s po bezpečnom uzavretí writerov a handoff zápise; žiadne čakanie na pipeline. Čas samotného capture stopu merať zvlášť. Limit reakcie governor/cancellation a pamäťový rozpočet musí T1 číselne stanoviť pre podporovaný hardware pred T6; otvorené limity znamenajú neuzavretý release gate. Požadovať žiadne nové straty frameov, stalls ani zlyhania capture pripísateľné spracovaniu oproti baseline. Prepis nesmie obsahovať duplicity spôsobené resume a musí zachovať časovanie existujúcich fixtures.

## 10. Dokončenie a uvedenie do používania

Hotovo znamená splnené invarianty, úspešnú automatickú maticu, preukázaný súbeh na podpísanej aplikácii a overené reálne riadenie zdrojov. Testovacia evidencia jasne oddeľuje automatické testy, manuálne merania a neoverené scenáre. Odhad trvania nedávať pred T1; najväčšia neistota je produkčné prerušenie inferencie, nie samotná FIFO fronta.

Finálny PR vedie konkrétnou zmenou: po Stop možno nahrávať ďalšiu schôdzku počas spracovania predchádzajúcej. Uviesť manifest kompatibilitu, recovery a merania capture spoľahlivosti. Aktualizácia stavu nápadu vo vaulte patrí až po overení implementácie, nie po vzniku tohto plánu.

Ak implementačný workflow aktualizuje remote main, inštalácia je podľa AGENTS.md súčasťou dokončenia: potvrdiť presný origin/main commit, čistý checkout/worktree, manuálne podpísaný build s lokálne nakonfigurovanou identitou, mimo sandboxu overiť `codesign --verify --deep --strict --verbose=4`, Authority/TeamIdentifier a SHA-1 extrahovaného certifikátu. Potom ukončiť staré inštancie, nahradiť `/Applications/MeetingScribe.app`, znovu overiť nainštalovaný podpis, spustiť a potvrdiť jedinú správnu cestu procesu. Pri chybe žiadny fallback na starý alebo inak podpísaný build.

Tento dokument je plán; implementácia, testy ani build aplikácie počas jeho prípravy neprebehli.
