# Fronta spracovania zostala trvalo pozastavená

Základ: `codex/concurrent-integration` @ `715caf0`. Vetva opravy:
`codex/concurrent-queue-pause-visibility`.

## Reprodukcia

Relácia „Test session - souběžná transkriopce a nahrávání“ (17. 9. 2026, 13:15)
zostala v stave `Zvuk ✅ / Transcript ⊖ / Markdown ⊖` s badgeom „Vo fronte“.
Panel ukazoval „Front spracovania 1“, hlavička „Pripravené“. Nahrávanie predtým
ukončil bezpečný stop pre zlyhanie zachytávania systémového zvuku.

## Príčina

1. `AppState.updateResourcePolicy()` pri `captureIsHealthy == false` zavolá
   `processingQueue.pause(reason:)`.
2. `ProcessingQueue.pause` patchuje na `pauseRequested` iba **bežiaci** job.
   Zaradený job zostane `queued`, takže v manifeste ani v UI nie je stopa po
   pozastavení frontu. `pauseReason` bol iba in-memory.
3. Odpauzovanie záviselo od `canResume`, ktorý vracal `.hold([])` — bez dôvodu.
   Pri nesplnenej podmienke front stál bez akéhokoľvek prejavu v UI.
4. Kandidáti na trvalé nesplnenie: `resourceMemoryPressure` sa aktualizoval len
   v handleri `DispatchSourceMemoryPressure` (chýbajúci prechod späť na
   `.normal` ho nechal na `.warning`), `resumeAboveStorageBytes` bol hardcoded
   3 GiB bez väzby na `minimumStorageBytes`.
5. `resourcePauseActive` v `AppState` duplikoval stav frontu. Ak `resume()`
   hodil chybu, flag už bol `false` a resume sa nikdy nezopakoval.
6. `shutdown()` nastavil `shuttingDown = true` natrvalo. Zrušené ukončenie
   aplikácie nechalo scheduler mŕtvy do konca procesu.

V UI neexistoval žiadny prvok, ktorý by `queued` job rozhýbal. „Opakovať prepis“
padol na `canEnqueueProcessing` a vrátil sa ticho.

## Zmeny

| Súbor | Zmena |
|---|---|
| `Processing/ProcessingQueue.swift` | `ProcessingPauseKind`, `ProcessingQueuePause`, `ProcessingQueueStatus`; pause sa publikuje cez `ChangeHandler`; `status()`; zlyhaný `resume()` pause zachová; `cancelShutdown()`; shutdown pause sa neprepíše resource pauzou |
| `Processing/ProcessingResourceGovernor.swift` | `hold` nesie nesplnené resume podmienky namiesto `[]`; `ProcessingResourceLimits.backgroundReserve(captureMinimumBytes:)` |
| `Processing/ProcessingPresentation.swift` | `statusLabel(queueStatus:)` a `statusDetail(queueStatus:)` — zaradený job pri pozastavenom fronte už nehlási „Queued“ |
| `App/AppState.swift` | `processingQueueStatus` ako jediný zdroj pravdy (`resourcePauseActive` odstránený); lokalizované dôvody pauzy; `resumeProcessing()`; `abortTermination()`; memory pressure sa pollie cez `kern.memorystatus_vm_pressure_level`; `memoryPressureSource` sa priradí pred `resume()`; limity sa odvodia z `minimumStorageBytes` |
| `App/MenuBarView.swift` | Banner s dôvodom pauzy a tlačidlo „Resume processing“ |
| `App/RecordingsWindow.swift` | Per-row stav a dôvod z queue statusu, „Resume processing“ pre držaný job |
| `App/MeetingScribeApp.swift` | Zrušené ukončenie volá `abortTermination()` |
| `Resources/Localizable.xcstrings` | `Processing paused`, `Resume processing` (cs, sk) |

Nezmenené zámerne: `ProcessingResourceLimits` zostáva samostatná rezerva pre
background prácu, `minimumStorageBytes` ju len zdvihne na podlahu capture
rezervy. Prahy pre thermal, memory a capture health boli už komplementárne,
menila sa len ich reportovateľnosť.

## Testy

Pridané / upravené:

- `ProcessingQueueTests.testPauseIsPublishedWhileQueuedJobStaysQueued`
- `ProcessingQueueTests.testFailedResumeKeepsPauseVisibleAndRetryable`
  (fault injection presunom `session.json`)
- `ProcessingQueueTests.testCancelledShutdownRestartsTheScheduler`
- `ProcessingQueueTests.testResourcePauseDoesNotOverwriteShutdownPause`
- `ProcessingResourceGovernorTests.testBackgroundReserveRespectsCaptureMinimumAndKeepsHysteresis`
- `ProcessingResourceGovernorTests.testHoldInsideResumeBandStillReportsTheBlockingReason`
- `ProcessingResourceGovernorTests.testStoragePauseUsesHysteresisBeforeResuming`
  — očakávanie `.hold([])` zmenené na `.hold([.storageReserve])`

## Stav overenia

**Neoverené.** Kód nebol skompilovaný ani testovaný. Zmeny vznikli v prostredí
bez Xcode a bez Swift toolchainu (viď `AGENTS.md`, *Sandbox a prístup
k nástrojom*), takže build a testy musia prebehnúť mimo sandboxu:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MeetingScribe.xcodeproj -scheme MeetingScribe \
  -destination 'platform=macOS' -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO test
```

Otvorené body, ktoré test suite nepokrýva:

- Skutočná dostupnosť `kern.memorystatus_vm_pressure_level` pre podpísaný
  proces bez root práv. Pri zlyhaní sysctl kód spadne na hodnotu z eventu, teda
  na pôvodné správanie.
- Ktorý z dôvodov (memory / thermal / storage) držal front v reprodukovanom
  prípade. Pause reason nebol persistovaný, takže to z manifestu spätne zistiť
  nemožno. Po tejto zmene bude dôvod viditeľný v UI aj v `failureDescription`
  pozastaveného jobu.
- Manuálne overenie súbehu podľa `docs/concurrent-recording-processing-plan.md`,
  kapitola 9, vrátane podpísaného buildu.
