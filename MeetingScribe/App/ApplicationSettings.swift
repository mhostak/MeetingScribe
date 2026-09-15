import Foundation

enum AppLanguage: String, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case slovak = "sk"
    case czech = "cs"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .slovak: return "Slovenčina"
        case .czech: return "Čeština"
        case .english: return "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .slovak: return Locale(identifier: "sk")
        case .czech: return Locale(identifier: "cs")
        case .english: return Locale(identifier: "en")
        }
    }

    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("sk") { return .slovak }
        if preferred.hasPrefix("cs") || preferred.hasPrefix("cz") { return .czech }
        return .english
    }
}

enum AppUserMessage: Equatable, Sendable {
    case outputFolderSave(String)
    case launchAtLogin(String)
    case fluidAudioModelDownload(String, String)
    case fluidAudioModelImport(String, String)
    case fluidAudioModelDelete(String, String)
    case fluidAudioModelInvalid
    case legacyModelDelete(String)
    case recoveryIssues
    case recoveryScan(String)
    case sourceCAFPreserved(String)
    case fluidAudioTranscriptionModelRequired
    case recordingSaved(String)
    case recordingSavedTranscription(String)
    case transcriptSavedMarkdown(String)
    case transcriptSavedAnalysisFailed(String)
    case unsupportedToken(String)
    case unknownError
    case captureFailedSafeStop
    case captureStalledSafeStop
    case lowStorageSafeStop
    case storageCheckFailedSafeStop
    case chooseOutputFolderTitle
    case chooseAnalysisExecutableTitle(String)
    case choose
    case analysisAvailabilityNotChecked
    case analysisExecutableNotFound
    case analysisAuthenticationRequired
    case importFluidAudioModelTitle(String)
    case importAction
}

enum AppLocalization {
    static func message(_ message: AppUserMessage, language: AppLanguage) -> String {
        let language = language.resolved
        switch message {
        case let .outputFolderSave(detail):
            return pick(
                "The output folder could not be saved: \(detail)",
                "Výstupný priečinok sa nepodarilo uložiť: \(detail)",
                "Výstupní složku se nepodařilo uložit: \(detail)",
                language
            )
        case let .launchAtLogin(detail):
            return pick(
                "Launch at login could not be updated: \(detail)",
                "Spúšťanie po prihlásení sa nepodarilo aktualizovať: \(detail)",
                "Spouštění po přihlášení se nepodařilo aktualizovat: \(detail)",
                language
            )
        case let .fluidAudioModelDownload(model, detail):
            return pick(
                "The FluidAudio model \(model) could not be installed: \(detail)",
                "Model FluidAudio \(model) sa nepodarilo nainštalovať: \(detail)",
                "Model FluidAudio \(model) se nepodařilo nainstalovat: \(detail)",
                language
            )
        case let .fluidAudioModelImport(model, detail):
            return pick(
                "The FluidAudio model \(model) could not be imported: \(detail)",
                "Model FluidAudio \(model) sa nepodarilo importovať: \(detail)",
                "Model FluidAudio \(model) se nepodařilo importovat: \(detail)",
                language
            )
        case let .fluidAudioModelDelete(model, detail):
            return pick(
                "The FluidAudio model \(model) could not be deleted: \(detail)",
                "Model FluidAudio \(model) sa nepodarilo odstrániť: \(detail)",
                "Model FluidAudio \(model) se nepodařilo odstranit: \(detail)",
                language
            )
        case .fluidAudioModelInvalid:
            return pick(
                "The installed model is incomplete or does not match the pinned revision.",
                "Nainštalovaný model je neúplný alebo nezodpovedá pripnutej revízii.",
                "Nainstalovaný model je neúplný nebo neodpovídá připnuté revizi.",
                language
            )
        case let .legacyModelDelete(detail):
            return pick(
                "Unused legacy models could not be removed: \(detail)",
                "Nepoužívané staré modely sa nepodarilo odstrániť: \(detail)",
                "Nepoužívané staré modely se nepodařilo odstranit: \(detail)",
                language
            )
        case .recoveryIssues:
            return pick(
                "Some recording folders could not be recovered. Open the recordings folder for details.",
                "Niektoré priečinky nahrávok sa nepodarilo obnoviť. Podrobnosti nájdete v priečinku nahrávok.",
                "Některé složky nahrávek se nepodařilo obnovit. Podrobnosti najdete ve složce nahrávek.",
                language
            )
        case let .recoveryScan(detail):
            return pick(
                "Recovery scan failed: \(detail)",
                "Kontrola obnovy zlyhala: \(detail)",
                "Kontrola obnovy selhala: \(detail)",
                language
            )
        case let .sourceCAFPreserved(detail):
            return pick(
                "Processing completed, but source CAF files were preserved: \(detail)",
                "Spracovanie sa dokončilo, ale zdrojové súbory CAF zostali zachované: \(detail)",
                "Zpracování bylo dokončeno, ale zdrojové soubory CAF zůstaly zachované: \(detail)",
                language
            )
        case .fluidAudioTranscriptionModelRequired:
            return pick(
                "Recording saved. Download or import the verified Parakeet v3 model to transcribe this recording.",
                "Nahrávka bola uložená. Na jej prepis stiahnite alebo importujte overený model Parakeet v3.",
                "Nahrávka byla uložena. Pro její přepis stáhněte nebo importujte ověřený model Parakeet v3.",
                language
            )
        case let .recordingSaved(detail):
            return pick(
                "Recording saved. \(detail)",
                "Nahrávka bola uložená. \(detail)",
                "Nahrávka byla uložena. \(detail)",
                language
            )
        case let .recordingSavedTranscription(detail):
            return pick(
                "Recording saved. Transcription failed: \(detail)",
                "Nahrávka bola uložená. Prepis zlyhal: \(detail)",
                "Nahrávka byla uložena. Přepis selhal: \(detail)",
                language
            )
        case let .transcriptSavedMarkdown(detail):
            return pick(
                "Transcript saved. Markdown export failed: \(detail)",
                "Prepis bol uložený. Export do Markdownu zlyhal: \(detail)",
                "Přepis byl uložen. Export do Markdownu selhal: \(detail)",
                language
            )
        case let .transcriptSavedAnalysisFailed(detail):
            return pick(
                "Transcript saved. AI analysis failed: \(detail)",
                "Prepis bol uložený. AI analýza zlyhala: \(detail)",
                "Přepis byl uložen. AI analýza selhala: \(detail)",
                language
            )
        case let .unsupportedToken(detail):
            return pick(
                "Unsupported token: \(detail)",
                "Nepodporovaný token: \(detail)",
                "Nepodporovaný token: \(detail)",
                language
            )
        case .unknownError:
            return pick("Unknown error", "Neznáma chyba", "Neznámá chyba", language)
        case .captureFailedSafeStop:
            return pick(
                "Recording was stopped safely because system audio capture failed. Existing audio was preserved.",
                "Nahrávanie bolo bezpečne zastavené, pretože zlyhalo zachytávanie systémového zvuku. Existujúce audio zostalo zachované.",
                "Nahrávání bylo bezpečně zastaveno, protože selhalo zachytávání systémového zvuku. Existující audio zůstalo zachované.",
                language
            )
        case .captureStalledSafeStop:
            return pick(
                "Recording was stopped safely because system audio capture stalled. Existing audio was preserved.",
                "Nahrávanie bolo bezpečne zastavené, pretože zachytávanie systémového zvuku prestalo prijímať dáta. Existujúce audio zostalo zachované.",
                "Nahrávání bylo bezpečně zastaveno, protože zachytávání systémového zvuku přestalo přijímat data. Existující audio zůstalo zachované.",
                language
            )
        case .lowStorageSafeStop:
            return pick(
                "Recording was stopped safely because free disk space became critically low. Existing audio was preserved.",
                "Nahrávanie bolo bezpečne zastavené pre kriticky nízke voľné miesto na disku. Existujúce audio zostalo zachované.",
                "Nahrávání bylo bezpečně zastaveno kvůli kriticky nízkému volnému místu na disku. Existující audio zůstalo zachované.",
                language
            )
        case .storageCheckFailedSafeStop:
            return pick(
                "Recording was stopped safely because free disk space could not be verified. Existing audio was preserved.",
                "Nahrávanie bolo bezpečne zastavené, pretože voľné miesto na disku nebolo možné overiť. Existujúce audio zostalo zachované.",
                "Nahrávání bylo bezpečně zastaveno, protože volné místo na disku nebylo možné ověřit. Existující audio zůstalo zachované.",
                language
            )
        case .chooseOutputFolderTitle:
            return pick("Choose Markdown output folder", "Vyberte výstupný priečinok pre Markdown", "Vyberte výstupní složku pro Markdown", language)
        case let .chooseAnalysisExecutableTitle(tool):
            return pick(
                "Choose \(tool) executable",
                "Vyberte spustiteľný súbor \(tool)",
                "Vyberte spustitelný soubor \(tool)",
                language
            )
        case .choose:
            return pick("Choose", "Vybrať", "Vybrat", language)
        case .analysisAvailabilityNotChecked:
            return pick(
                "Availability has not been checked",
                "Dostupnosť nebola overená",
                "Dostupnost nebyla ověřena",
                language
            )
        case .analysisExecutableNotFound:
            return pick(
                "Executable not found",
                "Spustiteľný súbor sa nenašiel",
                "Spustitelný soubor nebyl nalezen",
                language
            )
        case .analysisAuthenticationRequired:
            return pick(
                "Authentication required",
                "Vyžaduje sa prihlásenie",
                "Je vyžadováno přihlášení",
                language
            )
        case let .importFluidAudioModelTitle(model):
            return pick(
                "Import \(model)",
                "Importovať \(model)",
                "Importovat \(model)",
                language
            )
        case .importAction:
            return pick("Import", "Importovať", "Importovat", language)
        }
    }

    static func error(_ error: Error, language: AppLanguage) -> String {
        let language = language.resolved
        switch error {
        case let error as AudioCaptureServiceError:
            return captureError(error, language: language)
        case let error as SessionManagerError:
            switch error {
            case .sessionAlreadyActive:
                return pick("A recording session is already active.", "Nahrávacia relácia už prebieha.", "Nahrávací relace již probíhá.", language)
            case .noActiveSession:
                return pick("There is no active recording session to stop.", "Nie je aktívna žiadna nahrávacia relácia, ktorú by bolo možné zastaviť.", "Není aktivní žádná nahrávací relace, kterou by bylo možné zastavit.", language)
            case .emptyTitle:
                return pick("The meeting title cannot be empty.", "Názov stretnutia nemôže byť prázdny.", "Název setkání nemůže být prázdný.", language)
            }
        case let error as SessionRecoveryError:
            return recoveryError(error, language: language)
        case let error as StorageGuardError:
            return storageError(error, language: language)
        case let error as AnalysisError:
            return analysisError(error, language: language)
        case let error as AnalysisRevisionError:
            return analysisRevisionError(error, language: language)
        case let error as MarkdownAnalysisUpdateError:
            return markdownAnalysisUpdateError(error, language: language)
        case let error as TranscriptionRevisionError:
            return transcriptionRevisionError(error, language: language)
        case let error as OutputExportError:
            return outputError(error, language: language)
        case let error as TranscriptionError:
            return transcriptionError(error, language: language)
        case let error as FluidAudioModelManagerError:
            return fluidAudioModelError(error, language: language)
        case let error as AudioFinalizerError:
            return audioFinalizerError(error, language: language)
        case let error as AudioSourceCleanupError:
            return audioCleanupError(error, language: language)
        case let error as AudioConversionError:
            return audioConversionError(error, language: language)
        case let error as PCMFileWriterError:
            return pcmWriterError(error, language: language)
        case let error as TranscriptMergeError:
            return transcriptMergeError(error, language: language)
        case let error as AppStateTransitionError:
            switch error {
            case let .invalidTransition(from, to):
                return pick(
                    "Invalid application state transition from \(from.rawValue) to \(to.rawValue).",
                    "Neplatný prechod stavu aplikácie z \(from.rawValue) na \(to.rawValue).",
                    "Neplatný přechod stavu aplikace z \(from.rawValue) na \(to.rawValue).",
                    language
                )
            }
        case let error as CalendarIntegrationError:
            return calendarError(error, language: language)
        default:
            return error.localizedDescription
        }
    }

    private static func calendarError(
        _ error: CalendarIntegrationError,
        language: AppLanguage
    ) -> String {
        switch error {
        case .integrationDisabled:
            return pick(
                "Apple Calendar integration is disabled.",
                "Integrácia Apple Kalendára je vypnutá.",
                "Integrace Apple Kalendáře je vypnutá.",
                language
            )
        case .fullAccessRequired:
            return pick(
                "Full Calendar access is required to read events.",
                "Na čítanie udalostí je potrebný úplný prístup ku Kalendáru.",
                "Pro čtení událostí je vyžadován úplný přístup ke Kalendáři.",
                language
            )
        case let .accessRequestFailed(detail):
            return pick(
                "Calendar access could not be requested: \(detail)",
                "Prístup ku Kalendáru sa nepodarilo vyžiadať: \(detail)",
                "Přístup ke Kalendáři se nepodařilo vyžádat: \(detail)",
                language
            )
        case let .eventLoadingFailed(detail):
            return pick(
                "Calendar events could not be loaded: \(detail)",
                "Udalosti Kalendára sa nepodarilo načítať: \(detail)",
                "Události Kalendáře se nepodařilo načíst: \(detail)",
                language
            )
        }
    }

    private static func captureError(_ error: AudioCaptureServiceError, language: AppLanguage) -> String {
        switch error {
        case .alreadyCapturing:
            return pick("System audio capture is already running.", "Zachytávanie systémového zvuku už prebieha.", "Zachytávání systémového zvuku již probíhá.", language)
        case .screenRecordingPermissionDenied:
            return pick(
                "MeetingScribe does not have Screen Recording permission. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen MeetingScribe.",
                "MeetingScribe nemá povolenie na nahrávanie obrazovky. Povoľte ho v Systémových nastaveniach → Súkromie a bezpečnosť → Nahrávanie obrazovky a systémového zvuku, potom MeetingScribe ukončite a znovu otvorte.",
                "MeetingScribe nemá oprávnění k nahrávání obrazovky. Povolte ho v Nastavení systému → Soukromí a zabezpečení → Nahrávání obrazovky a systémového zvuku, potom MeetingScribe ukončete a znovu otevřete.",
                language
            )
        case .microphonePermissionDenied:
            return pick(
                "MeetingScribe does not have Microphone permission. Enable it in System Settings → Privacy & Security → Microphone, then quit and reopen MeetingScribe. System audio recording can continue.",
                "MeetingScribe nemá povolenie na používanie mikrofónu. Povoľte ho v Systémových nastaveniach → Súkromie a bezpečnosť → Mikrofón, potom MeetingScribe ukončite a znovu otvorte. Nahrávanie systémového zvuku môže pokračovať.",
                "MeetingScribe nemá oprávnění k používání mikrofonu. Povolte ho v Nastavení systému → Soukromí a zabezpečení → Mikrofon, potom MeetingScribe ukončete a znovu otevřete. Nahrávání systémového zvuku může pokračovat.",
                language
            )
        case .microphoneUnavailable:
            return pick("No usable microphone input is available. System audio recording can continue.", "Nie je dostupný použiteľný mikrofónový vstup. Nahrávanie systémového zvuku môže pokračovať.", "Není dostupný použitelný mikrofonní vstup. Nahrávání systémového zvuku může pokračovat.", language)
        case .microphoneProducedNoData:
            return pick("The audio engine started, but the microphone produced no audio buffers.", "Zvukový engine sa spustil, ale mikrofón neposkytol žiadne zvukové dáta.", "Zvukový engine se spustil, ale mikrofon neposkytl žádná zvuková data.", language)
        case .noDisplayAvailable:
            return pick("No display is available for system audio capture.", "Na zachytávanie systémového zvuku nie je dostupný žiadny displej.", "Pro zachytávání systémového zvuku není dostupný žádný displej.", language)
        case .invalidAudioFormat:
            return pick("ScreenCaptureKit returned an unsupported audio format.", "ScreenCaptureKit vrátil nepodporovaný formát zvuku.", "ScreenCaptureKit vrátil nepodporovaný formát zvuku.", language)
        case .unableToCreateAudioBuffer:
            return pick("ScreenCaptureKit returned audio data that could not be written.", "ScreenCaptureKit vrátil zvukové dáta, ktoré nebolo možné zapísať.", "ScreenCaptureKit vrátil zvuková data, která nebylo možné zapsat.", language)
        case .notCapturing:
            return pick("System audio capture is not running.", "Zachytávanie systémového zvuku neprebieha.", "Zachytávání systémového zvuku neprobíhá.", language)
        }
    }

    private static func recoveryError(_ error: SessionRecoveryError, language: AppLanguage) -> String {
        switch error {
        case .candidateNotFound:
            return pick("The recovery candidate no longer exists.", "Kandidát na obnovu už neexistuje.", "Kandidát na obnovu již neexistuje.", language)
        case .issueNotFound:
            return pick("The recovery issue no longer exists.", "Problém obnovy už neexistuje.", "Problém obnovy již neexistuje.", language)
        case .sessionNotRecoverable:
            return pick("This session is no longer eligible for recovery.", "Túto reláciu už nie je možné obnoviť.", "Tuto relaci již není možné obnovit.", language)
        case .requiredSystemAudioMissing:
            return pick("The interrupted session has no recoverable system-audio file. Existing artifacts were preserved.", "Prerušená relácia nemá obnoviteľný súbor systémového zvuku. Existujúce súbory zostali zachované.", "Přerušená relace nemá obnovitelný soubor systémového zvuku. Existující soubory zůstaly zachované.", language)
        case .requiredMicrophoneAudioMissing:
            return pick("The interrupted offline session has no recoverable microphone file. Existing artifacts were preserved.", "Prerušená offline relácia nemá obnoviteľný súbor mikrofónu. Existujúce súbory zostali zachované.", "Přerušená offline relace nemá obnovitelný soubor mikrofonu. Existující soubory zůstaly zachovány.", language)
        case let .audioUnreadable(fileName, reason):
            return pick("Recovered audio \(fileName) is unreadable: \(reason). Existing artifacts were preserved.", "Obnovený zvuk \(fileName) sa nedá prečítať: \(reason). Existujúce súbory zostali zachované.", "Obnovený zvuk \(fileName) nelze přečíst: \(reason). Existující soubory zůstaly zachované.", language)
        case let .audioEmpty(fileName):
            return pick("Recovered audio \(fileName) is empty. Existing artifacts were preserved.", "Obnovený zvuk \(fileName) je prázdny. Existujúce súbory zostali zachované.", "Obnovený zvuk \(fileName) je prázdný. Existující soubory zůstaly zachované.", language)
        case .mergedTranscriptUnreadable:
            return pick("The recovered merged transcript is unreadable. Existing artifacts were preserved.", "Obnovený zlúčený prepis sa nedá prečítať. Existujúce súbory zostali zachované.", "Obnovený sloučený přepis nelze přečíst. Existující soubory zůstaly zachované.", language)
        case .pendingRecoveryMustBeResolved:
            return pick("Recover or close the unfinished recording before starting a new one.", "Pred spustením novej nahrávky obnovte alebo zatvorte nedokončenú nahrávku.", "Před spuštěním nové nahrávky obnovte nebo zavřete nedokončenou nahrávku.", language)
        }
    }

    private static func storageError(_ error: StorageGuardError, language: AppLanguage) -> String {
        switch error {
        case .capacityUnavailable:
            return pick("MeetingScribe could not determine the available recording storage.", "MeetingScribe nedokázal zistiť dostupné miesto na nahrávanie.", "MeetingScribe nedokázal zjistit dostupné místo pro nahrávání.", language)
        case let .insufficientCapacity(availableBytes, requiredBytes):
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            return pick("Not enough free space to record safely. Available: \(available); required: \(required).", "Na bezpečné nahrávanie nie je dosť voľného miesta. Dostupné: \(available); požadované: \(required).", "Pro bezpečné nahrávání není dost volného místa. Dostupné: \(available); požadované: \(required).", language)
        }
    }

    private static func analysisError(_ error: AnalysisError, language: AppLanguage) -> String {
        switch error {
        case let .executableNotFound(path):
            return pick("The AI tool executable was not found at \(path).", "Spustiteľný súbor AI nástroja sa nenašiel na \(path).", "Spustitelný soubor AI nástroje nebyl nalezen na \(path).", language)
        case let .executableNotRunnable(path):
            return pick("The selected AI tool is not executable: \(path).", "Vybraný AI nástroj nie je spustiteľný: \(path).", "Vybraný AI nástroj není spustitelný: \(path).", language)
        case let .processLaunchFailed(tool, message):
            return pick("\(tool.displayName) could not be started: \(message)", "\(tool.displayName) sa nepodarilo spustiť: \(message)", "\(tool.displayName) se nepodařilo spustit: \(message)", language)
        case let .processFailed(tool, exitCode, message):
            return pick("\(tool.displayName) failed with exit code \(exitCode): \(message)", "\(tool.displayName) zlyhal s kódom \(exitCode): \(message)", "\(tool.displayName) selhal s kódem \(exitCode): \(message)", language)
        case let .authenticationRequired(tool, loginCommand):
            return pick(
                "\(tool.displayName) sign-in has expired or is invalid. Open Terminal and run:\n\(loginCommand)\nComplete sign-in, then retry AI analysis. Your recording and transcript are saved.",
                "Prihlásenie do \(tool.displayName) vypršalo alebo je neplatné. Otvorte Terminál a spustite:\n\(loginCommand)\nDokončite prihlásenie a znova spustite AI analýzu. Nahrávka aj prepis sú uložené.",
                "Přihlášení do \(tool.displayName) vypršelo nebo je neplatné. Otevřete Terminál a spusťte:\n\(loginCommand)\nDokončete přihlášení a znovu spusťte AI analýzu. Nahrávka i přepis jsou uložené.",
                language
            )
        case let .processTimedOut(tool):
            return pick("\(tool.displayName) analysis timed out.", "Analýza cez \(tool.displayName) prekročila časový limit.", "Analýza přes \(tool.displayName) překročila časový limit.", language)
        case .transcriptChunkTooLarge:
            return pick("A transcript segment or partial analysis is too large to process safely.", "Časť prepisu alebo čiastková analýza je príliš veľká na bezpečné spracovanie.", "Část přepisu nebo dílčí analýza je příliš velká pro bezpečné zpracování.", language)
        case .emptyOutput:
            return pick("The AI tool returned an empty analysis.", "AI nástroj vrátil prázdnu analýzu.", "AI nástroj vrátil prázdnou analýzu.", language)
        case .outputTooLarge:
            return pick("The AI tool returned an analysis that is too large.", "AI nástroj vrátil príliš veľkú analýzu.", "AI nástroj vrátil příliš velkou analýzu.", language)
        case .reservedMarkerInOutput:
            return pick("The AI analysis contains a reserved MeetingScribe marker.", "AI analýza obsahuje vyhradenú značku MeetingScribe.", "AI analýza obsahuje vyhrazenou značku MeetingScribe.", language)
        case let .invalidStructuredOutput(reason):
            return pick("The structured AI analysis could not be decoded: \(reason)", "Štruktúrovanú AI analýzu sa nepodarilo dekódovať: \(reason)", "Strukturovanou AI analýzu se nepodařilo dekódovat: \(reason)", language)
        }
    }

    private static func analysisRevisionError(
        _ error: AnalysisRevisionError,
        language: AppLanguage
    ) -> String {
        switch error {
        case .applicationBusy:
            return pick(
                "Wait for the current recording or processing task to finish before running AI analysis.",
                "Pred spustením AI analýzy počkajte na dokončenie aktuálneho nahrávania alebo spracovania.",
                "Před spuštěním AI analýzy počkejte na dokončení aktuálního nahrávání nebo zpracování.",
                language
            )
        case .transcriptMissing:
            return pick(
                "The recording has no transcript that can be analyzed.",
                "Záznam nemá prepis, ktorý by bolo možné analyzovať.",
                "Záznam nemá přepis, který by bylo možné analyzovat.",
                language
            )
        case .markdownMissing:
            return pick(
                "The recording's Markdown file is missing or unavailable.",
                "Súbor Markdown pre tento záznam chýba alebo nie je dostupný.",
                "Soubor Markdown pro tento záznam chybí nebo není dostupný.",
                language
            )
        }
    }

    private static func markdownAnalysisUpdateError(
        _ error: MarkdownAnalysisUpdateError,
        language: AppLanguage
    ) -> String {
        switch error {
        case .invalidStructure:
            return pick(
                "The Markdown file does not contain a valid MeetingScribe AI analysis block.",
                "Súbor Markdown neobsahuje platný blok AI analýzy MeetingScribe.",
                "Soubor Markdown neobsahuje platný blok AI analýzy MeetingScribe.",
                language
            )
        case .couldNotDecode:
            return pick(
                "The Markdown file could not be decoded as UTF-8.",
                "Súbor Markdown sa nepodarilo dekódovať ako UTF-8.",
                "Soubor Markdown se nepodařilo dekódovat jako UTF-8.",
                language
            )
        case .couldNotEncode:
            return pick(
                "The updated Markdown file could not be encoded as UTF-8.",
                "Aktualizovaný súbor Markdown sa nepodarilo zakódovať ako UTF-8.",
                "Aktualizovaný soubor Markdown se nepodařilo zakódovat jako UTF-8.",
                language
            )
        }
    }

    private static func transcriptionRevisionError(
        _ error: TranscriptionRevisionError,
        language: AppLanguage
    ) -> String {
        switch error {
        case .finalizedAudioMissing:
            return pick(
                "The recording has no finalized audio that can be reprocessed.",
                "Záznam nemá dokončený zvuk, z ktorého by bolo možné zopakovať prepis.",
                "Záznam nemá dokončený zvuk, ze kterého by bylo možné zopakovat přepis.",
                language
            )
        case .applicationBusy:
            return pick(
                "Wait for the current recording or processing task to finish before reprocessing.",
                "Pred opakovaním prepisu počkajte na dokončenie aktuálneho nahrávania alebo spracovania.",
                "Před opakováním přepisu počkejte na dokončení aktuálního nahrávání nebo zpracování.",
                language
            )
        case let .revisionAlreadyExists(id):
            return pick(
                "The transcription revision \(id) already exists.",
                "Revízia prepisu \(id) už existuje.",
                "Revize přepisu \(id) již existuje.",
                language
            )
        }
    }

    private static func outputError(_ error: OutputExportError, language: AppLanguage) -> String {
        switch error {
        case let .destinationIsNotDirectory(path):
            return pick("The Markdown output folder is unavailable: \(path)", "Výstupný priečinok pre Markdown nie je dostupný: \(path)", "Výstupní složka pro Markdown není dostupná: \(path)", language)
        case .couldNotEncodeMarkdown:
            return pick("The Markdown output could not be encoded as UTF-8.", "Výstup Markdown sa nepodarilo zakódovať ako UTF-8.", "Výstup Markdown se nepodařilo zakódovat jako UTF-8.", language)
        case .couldNotCreateUniqueFileName:
            return pick("A unique Markdown file name could not be created.", "Nepodarilo sa vytvoriť jedinečný názov súboru Markdown.", "Nepodařilo se vytvořit jedinečný název souboru Markdown.", language)
        }
    }

    private static func transcriptionError(_ error: TranscriptionError, language: AppLanguage) -> String {
        switch error {
        case let .invalidAudioFormat(sampleRate, channelCount):
            return pick("Transcription requires 16 kHz mono audio, but received \(sampleRate) Hz with \(channelCount) channels.", "Prepis vyžaduje mono zvuk 16 kHz, ale dostal \(sampleRate) Hz s \(channelCount) kanálmi.", "Přepis vyžaduje mono zvuk 16 kHz, ale dostal \(sampleRate) Hz s \(channelCount) kanály.", language)
        case .emptyAudio:
            return pick("The working audio file contains no samples.", "Pracovný zvukový súbor neobsahuje žiadne vzorky.", "Pracovní zvukový soubor neobsahuje žádné vzorky.", language)
        case let .modelBundleCouldNotBeLoaded(name):
            return pick("The transcription model bundle \(name) could not be loaded.", "Balík modelu prepisu \(name) sa nepodarilo načítať.", "Balík modelu přepisu \(name) se nepodařilo načíst.", language)
        case let .engineInferenceFailed(engine, detail):
            return pick("\(engine) transcription failed: \(detail)", "Prepis pomocou \(engine) zlyhal: \(detail)", "Přepis pomocí \(engine) selhal: \(detail)", language)
        case let .unsupportedEngine(engine):
            return pick("The transcription engine \(engine) is not supported.", "Engine prepisu \(engine) nie je podporovaný.", "Engine přepisu \(engine) není podporovaný.", language)
        }
    }

    private static func fluidAudioModelError(
        _ error: FluidAudioModelManagerError,
        language: AppLanguage
    ) -> String {
        switch error {
        case let .invalidRemoteURL(path):
            return pick(
                "The pinned model URL is invalid for \(path).",
                "Pripnutá adresa modelu pre \(path) je neplatná.",
                "Připnutá adresa modelu pro \(path) je neplatná.",
                language
            )
        case let .downloadFailed(path):
            return pick(
                "The model download failed for \(path).",
                "Sťahovanie modelu pre \(path) zlyhalo.",
                "Stahování modelu pro \(path) selhalo.",
                language
            )
        case .manifestMissing:
            return pick(
                "The verified model manifest is missing.",
                "Chýba overený manifest modelu.",
                "Chybí ověřený manifest modelu.",
                language
            )
        case .manifestMismatch:
            return pick(
                "The installed model does not match the pinned revision.",
                "Nainštalovaný model nezodpovedá pripnutej revízii.",
                "Nainstalovaný model neodpovídá připnuté revizi.",
                language
            )
        case let .fileMissing(path):
            return pick(
                "The model file \(path) is missing.",
                "Chýba súbor modelu \(path).",
                "Chybí soubor modelu \(path).",
                language
            )
        case let .invalidSize(path, expected, actual):
            return pick(
                "The model file \(path) has size \(actual), expected \(expected).",
                "Súbor modelu \(path) má veľkosť \(actual), očakávaná je \(expected).",
                "Soubor modelu \(path) má velikost \(actual), očekávána je \(expected).",
                language
            )
        case let .checksumMismatch(path, expected, actual):
            return pick(
                "The model file \(path) has SHA-256 \(actual), expected \(expected).",
                "Súbor modelu \(path) má SHA-256 \(actual), očakávaný je \(expected).",
                "Soubor modelu \(path) má SHA-256 \(actual), očekáván je \(expected).",
                language
            )
        }
    }

    private static func audioFinalizerError(_ error: AudioFinalizerError, language: AppLanguage) -> String {
        switch error {
        case let .requiredTrackFailed(trackName, reason):
            return pick("\(trackName) capture failed: \(reason)", "Zachytávanie stopy \(trackName) zlyhalo: \(reason)", "Zachytávání stopy \(trackName) selhalo: \(reason)", language)
        case let .emptyRequiredTrack(trackName):
            return pick("\(trackName) track is empty. The original recording files were preserved.", "Stopa \(trackName) je prázdna. Pôvodné súbory nahrávky zostali zachované.", "Stopa \(trackName) je prázdná. Původní soubory nahrávky zůstaly zachované.", language)
        case let .missingTimeline(trackName):
            return pick("\(trackName) has no presentation timestamp. The original recording files were preserved.", "Stopa \(trackName) nemá časovú značku prezentácie. Pôvodné súbory nahrávky zostali zachované.", "Stopa \(trackName) nemá časovou značku prezentace. Původní soubory nahrávky zůstaly zachované.", language)
        }
    }

    private static func audioCleanupError(_ error: AudioSourceCleanupError, language: AppLanguage) -> String {
        switch error {
        case .exportMissing:
            return pick("The completed Markdown export could not be verified.", "Dokončený export do Markdownu sa nepodarilo overiť.", "Dokončený export do Markdownu se nepodařilo ověřit.", language)
        case let .trackWasNotTranscribed(fileName):
            return pick("Source audio \(fileName) was preserved because its transcription is incomplete.", "Zdrojový zvuk \(fileName) zostal zachovaný, pretože jeho prepis nie je dokončený.", "Zdrojový zvuk \(fileName) zůstal zachován, protože jeho přepis není dokončený.", language)
        case let .artifactMissing(fileName):
            return pick("Source audio was preserved because \(fileName) is missing or empty.", "Zdrojový zvuk zostal zachovaný, pretože súbor \(fileName) chýba alebo je prázdny.", "Zdrojový zvuk zůstal zachován, protože soubor \(fileName) chybí nebo je prázdný.", language)
        case let .artifactUnreadable(fileName, reason):
            return pick("Source audio was preserved because \(fileName) is unreadable: \(reason)", "Zdrojový zvuk zostal zachovaný, pretože súbor \(fileName) sa nedá prečítať: \(reason)", "Zdrojový zvuk zůstal zachován, protože soubor \(fileName) nelze přečíst: \(reason)", language)
        }
    }

    private static func audioConversionError(_ error: AudioConversionError, language: AppLanguage) -> String {
        switch error {
        case let .unreadableInput(fileName, reason):
            return pick("Unable to read \(fileName): \(reason)", "Súbor \(fileName) sa nedá prečítať: \(reason)", "Soubor \(fileName) nelze přečíst: \(reason)", language)
        case let .emptyInput(fileName):
            return pick("Audio track \(fileName) is empty.", "Zvuková stopa \(fileName) je prázdna.", "Zvuková stopa \(fileName) je prázdná.", language)
        case let .unsupportedFormat(fileName):
            return pick("Audio track \(fileName) has an unsupported format.", "Zvuková stopa \(fileName) má nepodporovaný formát.", "Zvuková stopa \(fileName) má nepodporovaný formát.", language)
        case .unableToAllocateBuffer:
            return pick("Unable to allocate an audio conversion buffer.", "Nepodarilo sa vyhradiť vyrovnávaciu pamäť na konverziu zvuku.", "Nepodařilo se vyhradit vyrovnávací paměť pro převod zvuku.", language)
        case let .readFailed(reason):
            return pick("Audio conversion could not read input data: \(reason)", "Konverzia zvuku nedokázala prečítať vstupné dáta: \(reason)", "Převod zvuku nedokázal přečíst vstupní data: \(reason)", language)
        case let .conversionFailed(reason):
            return pick("Audio conversion failed: \(reason)", "Konverzia zvuku zlyhala: \(reason)", "Převod zvuku selhal: \(reason)", language)
        case let .emptyOutput(fileName):
            return pick("Converted audio track \(fileName) is empty.", "Skonvertovaná zvuková stopa \(fileName) je prázdna.", "Převedená zvuková stopa \(fileName) je prázdná.", language)
        }
    }

    private static func pcmWriterError(_ error: PCMFileWriterError, language: AppLanguage) -> String {
        switch error {
        case .writerFinished:
            return pick("The audio writer has already finished.", "Zapisovanie zvuku už bolo ukončené.", "Zapisování zvuku již bylo ukončeno.", language)
        case .unavailablePCMData:
            return pick("The converted PCM buffer has no readable sample data.", "Skonvertovaná vyrovnávacia pamäť PCM neobsahuje čitateľné vzorky.", "Převedená vyrovnávací paměť PCM neobsahuje čitelné vzorky.", language)
        case .fileTooLarge:
            return pick("The PCM WAV file exceeded the supported RIFF size.", "Súbor PCM WAV prekročil podporovanú veľkosť RIFF.", "Soubor PCM WAV překročil podporovanou velikost RIFF.", language)
        }
    }

    private static func transcriptMergeError(_ error: TranscriptMergeError, language: AppLanguage) -> String {
        switch error {
        case .noTracks:
            return pick("No finalized audio track was available for transcription.", "Na prepis nebola dostupná žiadna finalizovaná zvuková stopa.", "Pro přepis nebyla dostupná žádná finalizovaná zvuková stopa.", language)
        case let .unexpectedTrackSource(expected, actual):
            return pick("Expected a \(expected.rawValue) transcript, received \(actual.rawValue).", "Očakával sa prepis \(expected.rawValue), ale prijatý bol \(actual.rawValue).", "Očekával se přepis \(expected.rawValue), ale přijat byl \(actual.rawValue).", language)
        case let .segmentSourceMismatch(segmentID, track, segment):
            return pick("Segment \(segmentID) belongs to \(segment.rawValue), not \(track.rawValue).", "Segment \(segmentID) patrí do \(segment.rawValue), nie do \(track.rawValue).", "Segment \(segmentID) patří do \(segment.rawValue), ne do \(track.rawValue).", language)
        case let .invalidTimestamp(segmentID):
            return pick("Segment \(segmentID) contains a non-finite timestamp.", "Segment \(segmentID) obsahuje neplatnú časovú značku.", "Segment \(segmentID) obsahuje neplatnou časovou značku.", language)
        }
    }

    private static func pick(
        _ english: String,
        _ slovak: String,
        _ czech: String,
        _ language: AppLanguage
    ) -> String {
        switch language {
        case .slovak: return slovak
        case .czech: return czech
        case .english, .system: return english
        }
    }
}

enum OutputLanguage: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case slovak = "sk"
    case czech = "cs"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slovak: return "Slovenčina"
        case .czech: return "Čeština"
        case .english: return "English"
        }
    }

    var analysisLanguageDescription: String {
        switch self {
        case .slovak: return "Slovak (slovenčina, ISO 639-1: sk)"
        case .czech: return "Czech (čeština, ISO 639-1: cs)"
        case .english: return "English (ISO 639-1: en)"
        }
    }
}

enum MarkdownFileNameTemplate {
    static let defaultValue = "{date} {time} - {title}"
    static let supportedTokens = ["{date}", "{time}", "{title}", "{id}"]

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : trimmed
    }

    static func unsupportedTokens(in value: String) -> [String] {
        let expression = try? NSRegularExpression(pattern: #"\{[^{}]+\}"#)
        let range = NSRange(value.startIndex..., in: value)
        let tokens = expression?.matches(in: value, range: range).compactMap { match -> String? in
            guard let tokenRange = Range(match.range, in: value) else { return nil }
            return String(value[tokenRange])
        } ?? []
        return Array(Set(tokens.filter { !supportedTokens.contains($0) })).sorted()
    }
}

@MainActor
final class ApplicationSettingsStore {
    private enum Key {
        static let appLanguage = "applicationLanguage"
        static let outputLanguage = "meetingOutputLanguage"
        static let markdownFileNameTemplate = "markdownFileNameTemplate"
        static let minimumStorageBytes = "minimumRecordingStorageBytes"
        static let calendarIntegrationEnabled = "appleCalendarIntegrationEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appLanguage: AppLanguage {
        defaults.string(forKey: Key.appLanguage)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var outputLanguage: OutputLanguage {
        defaults.string(forKey: Key.outputLanguage)
            .flatMap(OutputLanguage.init(rawValue:)) ?? .slovak
    }

    var markdownFileNameTemplate: String {
        MarkdownFileNameTemplate.normalized(
            defaults.string(forKey: Key.markdownFileNameTemplate)
                ?? MarkdownFileNameTemplate.defaultValue
        )
    }

    var minimumStorageBytes: Int64 {
        let value = defaults.object(forKey: Key.minimumStorageBytes) as? NSNumber
        return max(value?.int64Value ?? StorageGuard.defaultMinimumBytes, StorageGuard.defaultMinimumBytes)
    }

    var calendarIntegrationEnabled: Bool {
        defaults.bool(forKey: Key.calendarIntegrationEnabled)
    }

    func setAppLanguage(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Key.appLanguage)
    }

    func setOutputLanguage(_ language: OutputLanguage) {
        defaults.set(language.rawValue, forKey: Key.outputLanguage)
    }

    func setMarkdownFileNameTemplate(_ template: String) {
        defaults.set(MarkdownFileNameTemplate.normalized(template), forKey: Key.markdownFileNameTemplate)
    }

    func setMinimumStorageBytes(_ bytes: Int64) {
        defaults.set(max(bytes, StorageGuard.defaultMinimumBytes), forKey: Key.minimumStorageBytes)
    }

    func setCalendarIntegrationEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.calendarIntegrationEnabled)
    }
}
