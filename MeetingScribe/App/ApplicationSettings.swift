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
    case openAIKeyLoad(String)
    case outputFolderSave(String)
    case openAIKeySave(String)
    case openAIKeyRemove(String)
    case launchAtLogin(String)
    case whisperModelDownload(String)
    case whisperModelImport(String)
    case whisperModelDelete(String)
    case whisperModelInvalidFile
    case recoveryIssues
    case recoveryScan(String)
    case sourceCAFPreserved(String)
    case recordingSavedModelCheck(String)
    case whisperModelRequired
    case recordingSaved(String)
    case recordingSavedTranscription(String)
    case transcriptSavedMarkdown(String)
    case transcriptSavedAnalysisSkipped(String)
    case transcriptSavedAnalysisFailed(String)
    case vadModelPreparation(String)
    case unsupportedToken(String)
    case unknownError
    case captureFailedSafeStop
    case captureStalledSafeStop
    case lowStorageSafeStop
    case chooseOutputFolderTitle
    case choose
    case importWhisperModelTitle
    case importAction
}

enum AppLocalization {
    static func message(_ message: AppUserMessage, language: AppLanguage) -> String {
        let language = language.resolved
        switch message {
        case let .openAIKeyLoad(detail):
            return pick(
                "The OpenAI API key could not be loaded: \(detail)",
                "Kľúč OpenAI API sa nepodarilo načítať: \(detail)",
                "Klíč OpenAI API se nepodařilo načíst: \(detail)",
                language
            )
        case let .outputFolderSave(detail):
            return pick(
                "The output folder could not be saved: \(detail)",
                "Výstupný priečinok sa nepodarilo uložiť: \(detail)",
                "Výstupní složku se nepodařilo uložit: \(detail)",
                language
            )
        case let .openAIKeySave(detail):
            return pick(
                "The OpenAI API key could not be saved: \(detail)",
                "Kľúč OpenAI API sa nepodarilo uložiť: \(detail)",
                "Klíč OpenAI API se nepodařilo uložit: \(detail)",
                language
            )
        case let .openAIKeyRemove(detail):
            return pick(
                "The OpenAI API key could not be removed: \(detail)",
                "Kľúč OpenAI API sa nepodarilo odstrániť: \(detail)",
                "Klíč OpenAI API se nepodařilo odstranit: \(detail)",
                language
            )
        case let .launchAtLogin(detail):
            return pick(
                "Launch at login could not be updated: \(detail)",
                "Spúšťanie po prihlásení sa nepodarilo aktualizovať: \(detail)",
                "Spouštění po přihlášení se nepodařilo aktualizovat: \(detail)",
                language
            )
        case let .whisperModelDownload(detail):
            return pick(
                "The Whisper model could not be downloaded: \(detail)",
                "Model Whisper sa nepodarilo stiahnuť: \(detail)",
                "Model Whisper se nepodařilo stáhnout: \(detail)",
                language
            )
        case let .whisperModelImport(detail):
            return pick(
                "The Whisper model could not be imported: \(detail)",
                "Model Whisper sa nepodarilo importovať: \(detail)",
                "Model Whisper se nepodařilo importovat: \(detail)",
                language
            )
        case let .whisperModelDelete(detail):
            return pick(
                "The Whisper model could not be deleted: \(detail)",
                "Model Whisper sa nepodarilo odstrániť: \(detail)",
                "Model Whisper se nepodařilo odstranit: \(detail)",
                language
            )
        case .whisperModelInvalidFile:
            return pick(
                "The model file is empty or is not a regular file.",
                "Súbor modelu je prázdny alebo nejde o bežný súbor.",
                "Soubor modelu je prázdný nebo nejde o běžný soubor.",
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
        case let .recordingSavedModelCheck(detail):
            return pick(
                "Recording saved. Whisper model check failed: \(detail)",
                "Nahrávka bola uložená. Kontrola modelu Whisper zlyhala: \(detail)",
                "Nahrávka byla uložena. Kontrola modelu Whisper selhala: \(detail)",
                language
            )
        case .whisperModelRequired:
            return pick(
                "Recording saved. Download or import the selected Whisper model to transcribe this recording.",
                "Nahrávka bola uložená. Na jej prepis stiahnite alebo importujte vybraný model Whisper.",
                "Nahrávka byla uložena. Pro její přepis stáhněte nebo importujte vybraný model Whisper.",
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
        case let .transcriptSavedAnalysisSkipped(detail):
            return pick(
                "Transcript saved. AI analysis was skipped: \(detail)",
                "Prepis bol uložený. AI analýza bola preskočená: \(detail)",
                "Přepis byl uložen. AI analýza byla přeskočena: \(detail)",
                language
            )
        case let .transcriptSavedAnalysisFailed(detail):
            return pick(
                "Transcript saved. AI analysis failed: \(detail)",
                "Prepis bol uložený. AI analýza zlyhala: \(detail)",
                "Přepis byl uložen. AI analýza selhala: \(detail)",
                language
            )
        case let .vadModelPreparation(detail):
            return pick(
                "The voice activity detection model could not be prepared: \(detail)",
                "Model detekcie hlasovej aktivity sa nepodarilo pripraviť: \(detail)",
                "Model detekce hlasové aktivity se nepodařilo připravit: \(detail)",
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
        case .chooseOutputFolderTitle:
            return pick("Choose Markdown output folder", "Vyberte výstupný priečinok pre Markdown", "Vyberte výstupní složku pro Markdown", language)
        case .choose:
            return pick("Choose", "Vybrať", "Vybrat", language)
        case .importWhisperModelTitle:
            return pick("Import Whisper model", "Importovať model Whisper", "Importovat model Whisper", language)
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
        case let error as OutputExportError:
            return outputError(error, language: language)
        case let error as TranscriptionError:
            return transcriptionError(error, language: language)
        case let error as WhisperModelManagerError:
            return whisperModelError(error, language: language)
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
        case let error as KeychainStoreError:
            return keychainError(error, language: language)
        default:
            return error.localizedDescription
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
        case .sessionNotRecoverable:
            return pick("This session is no longer eligible for recovery.", "Túto reláciu už nie je možné obnoviť.", "Tuto relaci již není možné obnovit.", language)
        case .requiredSystemAudioMissing:
            return pick("The interrupted session has no recoverable system-audio file. Existing artifacts were preserved.", "Prerušená relácia nemá obnoviteľný súbor systémového zvuku. Existujúce súbory zostali zachované.", "Přerušená relace nemá obnovitelný soubor systémového zvuku. Existující soubory zůstaly zachované.", language)
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
        case .missingAPIKey:
            return pick("Add an OpenAI API key before enabling AI analysis.", "Pred zapnutím AI analýzy pridajte kľúč OpenAI API.", "Před zapnutím AI analýzy přidejte klíč OpenAI API.", language)
        case .transcriptChunkTooLarge:
            return pick("A transcript segment or partial analysis is too large to process safely.", "Časť prepisu alebo čiastková analýza je príliš veľká na bezpečné spracovanie.", "Část přepisu nebo dílčí analýza je příliš velká pro bezpečné zpracování.", language)
        case .invalidHTTPResponse:
            return pick("OpenAI returned an invalid HTTP response.", "OpenAI vrátil neplatnú HTTP odpoveď.", "OpenAI vrátil neplatnou HTTP odpověď.", language)
        case let .network(code, message):
            return pick("OpenAI network error \(code.rawValue): \(message)", "Sieťová chyba OpenAI \(code.rawValue): \(message)", "Síťová chyba OpenAI \(code.rawValue): \(message)", language)
        case let .rateLimited(message, retryAfterSeconds):
            let retry = retryAfterSeconds.map { pick(" Retry after \($0.formatted()) seconds.", " Skúste znova o \($0.formatted()) sekúnd.", " Zkuste to znovu za \($0.formatted()) sekund.", language) } ?? ""
            return pick("OpenAI rate limit: \(message).\(retry)", "Limit požiadaviek OpenAI: \(message).\(retry)", "Limit požadavků OpenAI: \(message).\(retry)", language)
        case let .serverError(statusCode, message):
            return pick("OpenAI server error \(statusCode): \(message)", "Chyba servera OpenAI \(statusCode): \(message)", "Chyba serveru OpenAI \(statusCode): \(message)", language)
        case let .apiError(statusCode, message):
            return pick("OpenAI API error \(statusCode): \(message)", "Chyba OpenAI API \(statusCode): \(message)", "Chyba OpenAI API \(statusCode): \(message)", language)
        case let .incompleteResponse(status):
            return pick("OpenAI analysis did not complete (status: \(status)).", "Analýza OpenAI sa nedokončila (stav: \(status)).", "Analýza OpenAI se nedokončila (stav: \(status)).", language)
        case let .refusal(message):
            return pick("OpenAI declined the analysis: \(message)", "OpenAI odmietol analýzu: \(message)", "OpenAI odmítl analýzu: \(message)", language)
        case .missingStructuredOutput:
            return pick("OpenAI returned no structured meeting analysis.", "OpenAI nevrátil štruktúrovanú analýzu stretnutia.", "OpenAI nevrátil strukturovanou analýzu schůzky.", language)
        case let .invalidStructuredOutput(reason):
            return pick("The structured meeting analysis could not be decoded: \(reason)", "Štruktúrovanú analýzu stretnutia sa nepodarilo dekódovať: \(reason)", "Strukturovanou analýzu schůzky se nepodařilo dekódovat: \(reason)", language)
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
            return pick("Whisper requires 16 kHz mono audio, but received \(sampleRate) Hz with \(channelCount) channels.", "Whisper vyžaduje mono zvuk 16 kHz, ale dostal \(sampleRate) Hz s \(channelCount) kanálmi.", "Whisper vyžaduje mono zvuk 16 kHz, ale dostal \(sampleRate) Hz s \(channelCount) kanály.", language)
        case .emptyAudio:
            return pick("The working audio file contains no samples.", "Pracovný zvukový súbor neobsahuje žiadne vzorky.", "Pracovní zvukový soubor neobsahuje žádné vzorky.", language)
        case let .modelCouldNotBeLoaded(fileName):
            return pick("The Whisper model \(fileName) could not be loaded.", "Model Whisper \(fileName) sa nepodarilo načítať.", "Model Whisper \(fileName) se nepodařilo načíst.", language)
        case let .inferenceFailed(code):
            return pick("Whisper transcription failed with code \(code).", "Prepis Whisper zlyhal s kódom \(code).", "Přepis Whisper selhal s kódem \(code).", language)
        }
    }

    private static func whisperModelError(_ error: WhisperModelManagerError, language: AppLanguage) -> String {
        switch error {
        case .downloadFailed:
            return pick("The Whisper model download failed.", "Sťahovanie modelu Whisper zlyhalo.", "Stahování modelu Whisper selhalo.", language)
        case .invalidResumeResponse:
            return pick("The Whisper model server returned an invalid resume response.", "Server modelu Whisper vrátil neplatnú odpoveď pri pokračovaní sťahovania.", "Server modelu Whisper vrátil neplatnou odpověď při pokračování stahování.", language)
        case let .checksumMismatch(expected, actual):
            return pick("The Whisper model checksum is invalid. Expected \(expected), received \(actual).", "Kontrolný súčet modelu Whisper je neplatný. Očakávaný: \(expected), prijatý: \(actual).", "Kontrolní součet modelu Whisper je neplatný. Očekávaný: \(expected), přijatý: \(actual).", language)
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
        case let .unexpectedTrackSource(expected, actual):
            return pick("Expected a \(expected.rawValue) transcript, received \(actual.rawValue).", "Očakával sa prepis \(expected.rawValue), ale prijatý bol \(actual.rawValue).", "Očekával se přepis \(expected.rawValue), ale přijat byl \(actual.rawValue).", language)
        case let .segmentSourceMismatch(segmentID, track, segment):
            return pick("Segment \(segmentID) belongs to \(segment.rawValue), not \(track.rawValue).", "Segment \(segmentID) patrí do \(segment.rawValue), nie do \(track.rawValue).", "Segment \(segmentID) patří do \(segment.rawValue), ne do \(track.rawValue).", language)
        case let .invalidTimestamp(segmentID):
            return pick("Segment \(segmentID) contains a non-finite timestamp.", "Segment \(segmentID) obsahuje neplatnú časovú značku.", "Segment \(segmentID) obsahuje neplatnou časovou značku.", language)
        }
    }

    private static func keychainError(_ error: KeychainStoreError, language: AppLanguage) -> String {
        switch error {
        case .invalidUTF8:
            return pick("The OpenAI API key could not be encoded.", "Kľúč OpenAI API sa nepodarilo zakódovať.", "Klíč OpenAI API se nepodařilo zakódovat.", language)
        case let .status(status):
            return pick("Keychain error \(status).", "Chyba Kľúčenky \(status).", "Chyba Klíčenky \(status).", language)
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
        return max(value?.int64Value ?? StorageGuard.defaultMinimumBytes, 1)
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
        defaults.set(max(bytes, 1), forKey: Key.minimumStorageBytes)
    }
}
