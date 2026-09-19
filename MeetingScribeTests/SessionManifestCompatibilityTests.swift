import Foundation
import XCTest
@testable import MeetingScribe

/// Every recording on disk was written by whichever build was installed at
/// the time, and is read by whichever build is installed now.
///
/// A manifest that fails to decode is not a degraded recording, it is a lost
/// one: `SessionCatalog` reports it as unreadable and `loadSession` throws,
/// so the audio, transcript and analysis beside it can no longer be opened,
/// recovered, reprocessed or reanalysed. Nothing in the type system says so,
/// which is why these fixtures are real manifests rather than values this
/// build encodes and decodes back.
final class SessionManifestCompatibilityTests: XCTestCase {
    func testEveryShippedSchemaStillDecodes() throws {
        let fixtures: [(version: Int, json: String)] = [
            (9, ManifestFixtures.schema9),
            (11, ManifestFixtures.schema11),
            (13, ManifestFixtures.schema13),
            (14, ManifestFixtures.schema14),
            (15, ManifestFixtures.schema15),
            (16, ManifestFixtures.schema16),
        ]

        for fixture in fixtures {
            let data = Data(fixture.json.utf8)
            let metadata = try SessionJSONCoder.makeDecoder().decode(
                SessionMetadata.self,
                from: data
            )
            XCTAssertEqual(metadata.schemaVersion, fixture.version)
            XCTAssertFalse(metadata.id.isEmpty)
            XCTAssertFalse(metadata.title.isEmpty)
        }
    }

    func testAStatusThisBuildDoesNotKnowKeepsTheRestOfTheManifest() throws {
        // `SessionAnalysisStatus` carried a `missingAPIKey` case between
        // 2026-07-11 and 2026-08-12. Removing it made every manifest written
        // in that window undecodable in its entirety — an intact recording
        // that could never be opened again.
        let json = ManifestFixtures.schema16.replacingOccurrences(
            of: #""status":"completed""#,
            with: #""status":"missingAPIKey""#
        )
        XCTAssertNotEqual(json, ManifestFixtures.schema16, "the fixture must contain a status")

        let metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: Data(json.utf8)
        )

        XCTAssertFalse(metadata.id.isEmpty, "the recording is still readable")
        XCTAssertFalse(metadata.title.isEmpty)
        // Unknown is not complete: the recording stays eligible for work.
        XCTAssertNotEqual(metadata.analysis?.status, .completed)
        XCTAssertNotEqual(metadata.transcription?.status, .completed)
    }

    func testAKnownStatusIsStillDecodedAsItself() throws {
        let metadata = try SessionJSONCoder.makeDecoder().decode(
            SessionMetadata.self,
            from: Data(ManifestFixtures.schema16.utf8)
        )

        XCTAssertEqual(metadata.transcription?.status, .completed)
        XCTAssertEqual(metadata.output?.status, .completed)
        XCTAssertNotEqual(metadata.transcription?.status, .unrecognized)
    }

    func testAManifestSurvivesADecodeEncodeDecodeRoundTrip() throws {
        let decoder = SessionJSONCoder.makeDecoder()
        let encoder = SessionJSONCoder.makeEncoder()

        for json in [ManifestFixtures.schema9, ManifestFixtures.schema13, ManifestFixtures.schema16] {
            let first = try decoder.decode(SessionMetadata.self, from: Data(json.utf8))
            let second = try decoder.decode(SessionMetadata.self, from: try encoder.encode(first))
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(first.schemaVersion, second.schemaVersion)
            XCTAssertEqual(first.transcription?.status, second.transcription?.status)
            XCTAssertEqual(first.output?.status, second.output?.status)
        }
    }
}

/// Real manifests, captured from recordings made by earlier builds. The
/// meeting titles, prompts, participant names, file paths and failure texts
/// were replaced; nothing structural was.
private enum ManifestFixtures {
    /// A manifest really written by the build that used schema 9. Only the
    /// meeting's own words are replaced; every structure, key and enum value
    /// is exactly what shipped.
    static let schema9 = [
        #"{"audioFiles":{"microphone":"microphone-16k.wav","mixed":"mixed.wav","system":"system-16k.wa"#,
        #"v"},"audioFinalization":{"completedAt":"2026-07-15T07:15:04Z","microphone":{"channelCount":1"#,
        #","durationSeconds":875,"fileName":"microphone-16k.wav","sampleRate":16000,"timelineOffsetSec"#,
        #"onds":0.11690708401147276,"totalFrames":14000000},"system":{"channelCount":1,"durationSecond"#,
        #"s":876.18,"fileName":"system-16k.wav","sampleRate":16000,"timelineOffsetSeconds":0,"totalFra"#,
        #"mes":14018880},"timelineOrigin":421623.373542791,"warnings":[]},"createdAt":"2026-07-15T07:0"#,
        #"0:27Z","endedAt":"2026-07-15T07:15:04Z","id":"schema-9-recording","language":"auto","microph"#,
        #"oneAudio":{"bufferCount":8750,"capturedDurationSeconds":876.0758285833369,"channelCount":1,""#,
        #"fileName":"microphone-16k.wav","firstPresentationTimestamp":421623.490449875,"lastPresentati"#,
        #"onTimestamp":422499.46227845835,"sampleRate":16000,"totalFrames":13999968},"output":{"export"#,
        #"edAt":"2026-07-15T07:20:13Z","markdownFileName":"Recording.md","markdownPath":"/redacted/Rec"#,
        #"ording.md","status":"completed"},"outputFileNameTemplate":"{date} {time} - {title}","outputL"#,
        #"anguage":"cs","schemaVersion":9,"startedAt":"2026-07-15T07:00:27Z","status":"recorded","syst"#,
        #"emAudio":{"bufferCount":43809,"capturedDurationSeconds":876.1958124590269,"channelCount":1,""#,
        #"fileName":"system-16k.wav","firstPresentationTimestamp":421623.373542791,"lastPresentationTi"#,
        #"mestamp":422499.54935525,"sampleRate":16000,"totalFrames":14018874},"title":"Recording","tra"#,
        #"nscriptFiles":{"analysis":"analysis.json","merged":"transcript.json","microphoneTrack":"micr"#,
        #"ophone-transcript.json","systemTrack":"system-transcript.json"},"transcription":{"completedA"#,
        #"t":"2026-07-15T07:20:13Z","mergedSegmentCount":377,"microphonePerformance":{"activeDurationS"#,
        #"econds":206.288,"audioDurationSeconds":875,"chunkCount":1,"inferenceInputDurationSeconds":20"#,
        #"8.538,"skippedDurationSeconds":668.712,"wallTimeSeconds":62.667764624988195},"microphoneSegm"#,
        #"entCount":37,"model":"ggml-large-v3-turbo.bin","startedAt":"2026-07-15T07:15:04Z","status":""#,
        #"completed","systemPerformance":{"activeDurationSeconds":639.576,"audioDurationSeconds":876.1"#,
        #"8,"chunkCount":3,"inferenceInputDurationSeconds":643.826,"skippedDurationSeconds":236.603999"#,
        #"99999993,"wallTimeSeconds":245.91813325003022},"systemSegmentCount":340,"warnings":[]}}"#,
    ].joined()

    /// A manifest really written by the build that used schema 11. Only the
    /// meeting's own words are replaced; every structure, key and enum value
    /// is exactly what shipped.
    static let schema11 = [
        #"{"audioFiles":{"microphone":"microphone-16k.wav","mixed":"mixed.wav","system":"system-16k.wa"#,
        #"v"},"calendarEvent":{"endsAt":"2026-07-15T11:55:00Z","participants":[{"displayName":"Partici"#,
        #"pant"},{"displayName":"Participant"},{"displayName":"Participant"},{"displayName":"Participa"#,
        #"nt"},{"displayName":"Participant"},{"displayName":"Participant"}],"selectedAt":"2026-07-15T1"#,
        #"1:01:16Z","shareParticipantNamesWithAnalysis":false,"source":"appleCalendar","startsAt":"202"#,
        #"6-07-15T11:00:00Z","title":"Recording"},"createdAt":"2026-07-15T11:02:11Z","endedAt":"2026-0"#,
        #"7-15T11:03:07Z","failureReason":"Redacted failure.","id":"schema-11-recording","language":"a"#,
        #"uto","outputFileNameTemplate":"{date} {time} - {title}","outputLanguage":"cs","recovery":{"a"#,
        #"ttemptCount":0,"completedAt":"2026-07-15T11:03:21Z","detectedAt":"2026-07-15T11:03:21Z","fai"#,
        #"lureReason":"Redacted failure.","originalStatus":"recording","status":"closed"},"schemaVersi"#,
        #"on":11,"startedAt":"2026-07-15T11:02:11Z","status":"failed","title":"Recording","transcriptF"#,
        #"iles":{"analysis":"analysis.json","merged":"transcript.json","microphoneTrack":"microphone-t"#,
        #"ranscript.json","speakerTurns":"speaker-turns.json","systemTrack":"system-transcript.json",""#,
        #"utterances":"utterance-transcript.json"}}"#,
    ].joined()

    /// A manifest really written by the build that used schema 13. Only the
    /// meeting's own words are replaced; every structure, key and enum value
    /// is exactly what shipped.
    static let schema13 = [
        #"{"audioFiles":{"microphone":"microphone-16k.wav","mixed":"mixed.wav","system":"system-16k.wa"#,
        #"v"},"audioFinalization":{"completedAt":"2026-07-16T09:41:36Z","microphone":{"channelCount":1"#,
        #","durationSeconds":6123.1,"fileName":"microphone-16k.wav","sampleRate":16000,"timelineOffset"#,
        #"Seconds":0.19675941666355357,"totalFrames":97969600},"system":{"channelCount":1,"durationSec"#,
        #"onds":6122.54,"fileName":"system-16k.wav","sampleRate":16000,"timelineOffsetSeconds":0,"tota"#,
        #"lFrames":97960640},"timelineOrigin":496795.569629375,"warnings":[]},"calendarEvent":{"endsAt"#,
        #"":"2026-07-16T09:25:00Z","participants":[{"displayName":"Participant"},{"displayName":"Parti"#,
        #"cipant"},{"displayName":"Participant"},{"displayName":"Participant"},{"displayName":"Partici"#,
        #"pant"},{"displayName":"Participant"},{"displayName":"Participant"},{"displayName":"Participa"#,
        #"nt"},{"displayName":"Participant"},{"displayName":"Participant"}],"selectedAt":"2026-07-16T0"#,
        #"8:17:27Z","shareParticipantNamesWithAnalysis":false,"source":"appleCalendar","startsAt":"202"#,
        #"6-07-16T08:00:00Z","title":"Recording"},"createdAt":"2026-07-16T07:59:32Z","diarization":{"a"#,
        #"udioDurationSeconds":6122.54,"completedAt":"2026-07-16T09:49:48Z","configurationRevision":"c"#,
        #"ommunity-1-offline-v1","engine":"FluidAudio","model":"community-1","segmentCount":936,"sourc"#,
        #"eAudioFingerprint":"8de5f9136b1f46fe64f52a836099fdef6ba75cf7ef30aaa3bebeca93cc8b7349","speak"#,
        #"erCount":2,"startedAt":"2026-07-16T09:46:43Z","status":"completed","wallTimeSeconds":184.354"#,
        #"57491665147,"warnings":[]},"endedAt":"2026-07-16T09:41:36Z","id":"schema-13-recording","lang"#,
        #"uage":"auto","microphoneAudio":{"bufferCount":61231,"capturedDurationSeconds":6123.084926541"#,
        #"67,"channelCount":1,"fileName":"microphone-16k.wav","firstPresentationTimestamp":496795.7663"#,
        #"887917,"lastPresentationTimestamp":502918.74731533334,"sampleRate":16000,"totalFrames":97969"#,
        #"386},"output":{"exportedAt":"2026-07-16T09:49:48Z","markdownFileName":"Recording.md","markdo"#,
        #"wnPath":"/redacted/Recording.md","status":"completed"},"outputFileNameTemplate":"{date} {tim"#,
        #"e} - {title}","outputLanguage":"cs","recordingAudioRetention":{"candidateFiles":["microphone"#,
        #"-16k.wav","system-16k.wav"],"cleanupCompletedAt":"2026-08-19T08:31:59Z","cleanupStartedAt":""#,
        #"2026-08-19T08:31:59Z","cleanupStatus":"purged","cleanupTrigger":"automatic","deletedFiles":["#,
        #""microphone-16k.wav","system-16k.wav"],"keepAudio":false,"reclaimedBytes":391864320},"schema"#,
        #"Version":13,"startedAt":"2026-07-16T07:59:32Z","status":"recorded","systemAudio":{"bufferCou"#,
        #"nt":306127,"capturedDurationSeconds":6123.2399999999725,"channelCount":1,"fileName":"system-"#,
        #"16k.wav","firstPresentationTimestamp":496795.569629375,"lastPresentationTimestamp":502918.78"#,
        #"9629375,"sampleRate":16000,"totalFrames":97960634},"title":"Recording","transcriptFiles":{"a"#,
        #"nalysis":"analysis.json","merged":"transcript.json","microphoneTrack":"microphone-transcript"#,
        #".json","resolved":"resolved-transcript.json","speakerDiarization":"speaker-diarization.json""#,
        #","speakerTurns":"speaker-turns.json","systemTrack":"system-transcript.json","utterances":"ut"#,
        #"terance-transcript.json"},"transcription":{"completedAt":"2026-07-16T09:46:43Z","mergedSegme"#,
        #"ntCount":973,"microphonePerformance":{"activeDurationSeconds":662.7999999998651,"audioDurati"#,
        #"onSeconds":6123.1,"chunkCount":409,"inferenceInputDurationSeconds":6123.1,"skippedDurationSe"#,
        #"conds":5460.300000000136,"wallTimeSeconds":121.26876770833042},"microphoneSegmentCount":158,"#,
        #""model":"FluidInference/parakeet-tdt-0.6b-v3-coreml","provenance":{"configurationRevision":""#,
        #"parakeet-v3-int8-longform-v1","engine":"FluidAudio","engineVersion":"0.15.5","model":"FluidI"#,
        #"nference/parakeet-tdt-0.6b-v3-coreml","modelRevision":"aed02740059203c4a87495924f685de3722ae"#,
        #"9ce","modelVariant":"v3-int8"},"startedAt":"2026-07-16T09:41:36Z","status":"completed","syst"#,
        #"emPerformance":{"activeDurationSeconds":2678.959999999436,"audioDurationSeconds":6122.54,"ch"#,
        #"unkCount":409,"inferenceInputDurationSeconds":6122.54,"skippedDurationSeconds":3443.58000000"#,
        #"0564,"wallTimeSeconds":185.32675779168494},"systemSegmentCount":815,"utteranceCount":535,"ut"#,
        #"teranceFallbackUsed":true,"warnings":[]}}"#,
    ].joined()

    /// A manifest really written by the build that used schema 14. Only the
    /// meeting's own words are replaced; every structure, key and enum value
    /// is exactly what shipped.
    static let schema14 = [
        #"{"analysis":{"completedAt":"2026-08-12T22:02:18Z","model":"opus","promptHash":"76060dbc66aba"#,
        #"b4925e163ae3ea4ef09bb22244ddb9701a436bd295260b17384","provider":"claude","requestCount":1,"s"#,
        #"tartedAt":"2026-08-12T22:01:38Z","status":"completed","toolVersion":"2.1.119 (Claude Code)","#,
        #""transcriptChunkCount":1},"analysisConfiguration":{"executablePath":"/redacted/tool","model""#,
        #":"opus","prompt":"Prompt","promptHash":"05832663ba4bb0c4a6eaf9c5acc6daaa6f09c99c4494ffd7bb6e"#,
        #"a40900588246","tool":"claude"},"audioFiles":{"microphone":"microphone-16k.wav","mixed":"mixe"#,
        #"d.wav","system":"system-16k.wav"},"audioFinalization":{"completedAt":"2026-08-12T21:15:56Z","#,
        #""microphone":{"channelCount":1,"durationSeconds":32.4,"fileName":"microphone-16k.wav","sampl"#,
        #"eRate":16000,"timelineOffsetSeconds":0.1623515840037726,"totalFrames":518400},"system":{"cha"#,
        #"nnelCount":1,"durationSeconds":32.62,"fileName":"system-16k.wav","sampleRate":16000,"timelin"#,
        #"eOffsetSeconds":0,"totalFrames":521920},"timelineOrigin":62624.881996916,"warnings":[]},"cre"#,
        #"atedAt":"2026-08-12T21:15:23Z","endedAt":"2026-08-12T21:15:56Z","id":"schema-14-recording",""#,
        #"language":"auto","microphoneAudio":{"bufferCount":324,"capturedDurationSeconds":32.403873291"#,
        #"66033,"channelCount":1,"fileName":"microphone-16k.wav","firstPresentationTimestamp":62625.04"#,
        #"434850001,"lastPresentationTimestamp":62657.34422179167,"sampleRate":16000,"totalFrames":518"#,
        #"201},"output":{"exportedAt":"2026-08-12T21:16:02Z","markdownFileName":"Recording.md","markdo"#,
        #"wnPath":"/redacted/Recording.md","status":"completed"},"outputFileNameTemplate":"{date} {tim"#,
        #"e} - {title}","outputLanguage":"cs","schemaVersion":14,"startedAt":"2026-08-12T21:15:23Z","s"#,
        #"tatus":"recorded","systemAudio":{"bufferCount":1631,"capturedDurationSeconds":32.61999999999"#,
        #"855,"channelCount":1,"fileName":"system-16k.wav","firstPresentationTimestamp":62624.88199691"#,
        #"6,"lastPresentationTimestamp":62657.481996916,"sampleRate":16000,"totalFrames":521914},"titl"#,
        #"e":"Recording","transcriptFiles":{"analysis":"analysis.json","merged":"transcript.json","mic"#,
        #"rophoneTrack":"microphone-transcript.json","resolved":"resolved-transcript.json","speakerDia"#,
        #"rization":"speaker-diarization.json","speakerTurns":"speaker-turns.json","systemTrack":"syst"#,
        #"em-transcript.json","utterances":"utterance-transcript.json"},"transcription":{"completedAt""#,
        #":"2026-08-12T21:15:59Z","mergedSegmentCount":8,"microphonePerformance":{"activeDurationSecon"#,
        #"ds":24.159999999999958,"audioDurationSeconds":32.4,"chunkCount":3,"inferenceInputDurationSec"#,
        #"onds":32.4,"skippedDurationSeconds":8.240000000000041,"wallTimeSeconds":0.6593510416641948},"#,
        #""microphoneSegmentCount":5,"model":"FluidInference/parakeet-tdt-0.6b-v3-coreml","provenance""#,
        #":{"configurationRevision":"parakeet-v3-int8-longform-v1","engine":"FluidAudio","engineVersio"#,
        #"n":"0.15.5","model":"FluidInference/parakeet-tdt-0.6b-v3-coreml","modelRevision":"aed0274005"#,
        #"9203c4a87495924f685de3722ae9ce","modelVariant":"v3-int8"},"startedAt":"2026-08-12T21:15:56Z""#,
        #","status":"completed","systemPerformance":{"activeDurationSeconds":13.359999999999946,"audio"#,
        #"DurationSeconds":32.62,"chunkCount":3,"inferenceInputDurationSeconds":32.62,"skippedDuration"#,
        #"Seconds":19.26000000000005,"wallTimeSeconds":2.0088547083360027},"systemSegmentCount":3,"utt"#,
        #"eranceCount":7,"utteranceFallbackUsed":false,"warnings":[]}}"#,
    ].joined()

    /// A manifest really written by the build that used schema 15. Only the
    /// meeting's own words are replaced; every structure, key and enum value
    /// is exactly what shipped.
    static let schema15 = [
        #"{"analysis":{"completedAt":"2026-08-14T07:32:26Z","model":"opus","promptHash":"76060dbc66aba"#,
        #"b4925e163ae3ea4ef09bb22244ddb9701a436bd295260b17384","provider":"claude","requestCount":1,"s"#,
        #"tartedAt":"2026-08-14T07:32:06Z","status":"completed","toolVersion":"2.1.119 (Claude Code)","#,
        #""transcriptChunkCount":1},"analysisConfiguration":{"executablePath":"/redacted/tool","model""#,
        #":"opus","prompt":"Prompt","promptHash":"05832663ba4bb0c4a6eaf9c5acc6daaa6f09c99c4494ffd7bb6e"#,
        #"a40900588246","tool":"claude"},"audioFiles":{"microphone":"microphone-16k.wav","mixed":"mixe"#,
        #"d.wav","system":"system-16k.wav"},"audioFinalization":{"completedAt":"2026-08-14T07:32:03Z","#,
        #""microphone":{"channelCount":1,"durationSeconds":55.3,"fileName":"microphone-16k.wav","sampl"#,
        #"eRate":16000,"timelineOffsetSeconds":0.26576399999612477,"totalFrames":884800},"system":{"ch"#,
        #"annelCount":1,"durationSeconds":54.78,"fileName":"system-16k.wav","sampleRate":16000,"timeli"#,
        #"neOffsetSeconds":0,"totalFrames":876480},"timelineOrigin":87024.475343875,"warnings":[]},"ca"#,
        #"ptureMode":"systemAndMicrophone","createdAt":"2026-08-14T07:31:07Z","endedAt":"2026-08-14T07"#,
        #":32:03Z","id":"schema-15-recording","language":"auto","microphoneAudio":{"bufferCount":553,""#,
        #"capturedDurationSeconds":55.30380745833891,"channelCount":1,"fileName":"microphone-16k.wav","#,
        #""firstPresentationTimestamp":87024.741107875,"lastPresentationTimestamp":87079.94091533334,""#,
        #"sampleRate":16000,"totalFrames":884606},"output":{"exportedAt":"2026-08-14T07:32:26Z","markd"#,
        #"ownFileName":"Recording.md","markdownPath":"/redacted/Recording.md","status":"completed"},"o"#,
        #"utputFileNameTemplate":"{date} {time} - {title}","outputLanguage":"cs","recordingAudioRetent"#,
        #"ion":{"candidateFiles":["microphone-16k.wav","system-16k.wav"],"cleanupCompletedAt":"2026-08"#,
        #"-21T09:57:08Z","cleanupStartedAt":"2026-08-21T09:57:08Z","cleanupStatus":"purged","cleanupTr"#,
        #"igger":"automatic","deletedFiles":["microphone-16k.wav","system-16k.wav"],"keepAudio":false,"#,
        #""reclaimedBytes":3526656},"schemaVersion":15,"startedAt":"2026-08-14T07:31:07Z","status":"re"#,
        #"corded","systemAudio":{"bufferCount":2739,"capturedDurationSeconds":55.52,"channelCount":1,""#,
        #"fileName":"system-16k.wav","firstPresentationTimestamp":87024.475343875,"lastPresentationTim"#,
        #"estamp":87079.975343875,"sampleRate":16000,"totalFrames":876474},"title":"Recording","transc"#,
        #"riptFiles":{"analysis":"analysis.json","merged":"transcript.json","microphoneTrack":"microph"#,
        #"one-transcript.json","resolved":"resolved-transcript.json","speakerDiarization":"speaker-dia"#,
        #"rization.json","speakerTurns":"speaker-turns.json","systemTrack":"system-transcript.json","u"#,
        #"tterances":"utterance-transcript.json"},"transcription":{"completedAt":"2026-08-14T07:32:06Z"#,
        #"","mergedSegmentCount":17,"microphonePerformance":{"activeDurationSeconds":23.99999999999988"#,
        #","audioDurationSeconds":55.3,"chunkCount":4,"inferenceInputDurationSeconds":55.3,"skippedDur"#,
        #"ationSeconds":31.300000000000118,"wallTimeSeconds":1.0860503333387896},"microphoneSegmentCou"#,
        #"nt":9,"model":"FluidInference/parakeet-tdt-0.6b-v3-coreml","provenance":{"configurationRevis"#,
        #"ion":"parakeet-v3-int8-longform-v1","engine":"FluidAudio","engineVersion":"0.15.5","model":""#,
        #"FluidInference/parakeet-tdt-0.6b-v3-coreml","modelRevision":"aed02740059203c4a87495924f685de"#,
        #"3722ae9ce","modelVariant":"v3-int8"},"startedAt":"2026-08-14T07:32:03Z","status":"completed""#,
        #","systemPerformance":{"activeDurationSeconds":24.639999999999837,"audioDurationSeconds":54.7"#,
        #"8,"chunkCount":4,"inferenceInputDurationSeconds":54.78,"skippedDurationSeconds":30.140000000"#,
        #"000164,"wallTimeSeconds":1.8023785416735336},"systemSegmentCount":8,"utteranceCount":13,"utt"#,
        #"eranceFallbackUsed":false,"warnings":[]}}"#,
    ].joined()

    /// A manifest really written by the build that used schema 16. Only the
    /// meeting's own words are replaced; every structure, key and enum value
    /// is exactly what shipped.
    static let schema16 = [
        #"{"analysis":{"completedAt":"2026-08-20T14:03:41Z","model":"opus","promptHash":"81359819ffa2c"#,
        #"ca4f3609967a2e48a09f3f0998ace74778afa1259fd104bc339","provider":"claude","requestCount":3,"s"#,
        #"tartedAt":"2026-08-20T13:59:49Z","status":"completed","toolVersion":"2.1.119 (Claude Code)","#,
        #""transcriptChunkCount":2},"analysisConfiguration":{"executablePath":"/redacted/tool","model""#,
        #":"opus","prompt":"Prompt","promptHash":"8d2ed9d3d55fff22494769848e4eb3f7d3eda4d5b09bd36bf128"#,
        #"12fc673dc3f7","tool":"claude"},"audioFiles":{"microphone":"microphone-16k.wav","mixed":"mixe"#,
        #"d.wav","system":"system-16k.wav"},"audioFinalization":{"completedAt":"2026-08-19T12:57:19Z","#,
        #""microphone":{"channelCount":1,"durationSeconds":3444.8,"fileName":"microphone-16k.wav","sam"#,
        #"pleRate":16000,"timelineOffsetSeconds":2.4478420416999143,"totalFrames":55116800},"system":{"#,
        #""channelCount":1,"durationSeconds":3446.38,"fileName":"system-16k.wav","sampleRate":16000,"t"#,
        #"imelineOffsetSeconds":0,"totalFrames":55142080},"timelineOrigin":202145.54622425,"warnings":"#,
        #"[]},"calendarEvent":{"endsAt":"2026-08-19T12:55:00Z","participants":[{"displayName":"Partici"#,
        #"pant"}],"selectedAt":"2026-08-19T11:59:49Z","shareParticipantNamesWithAnalysis":true,"source"#,
        #"":"appleCalendar","startsAt":"2026-08-19T12:00:00Z","title":"Recording"},"captureMode":"syst"#,
        #"emAndMicrophone","createdAt":"2026-08-19T11:59:51Z","endedAt":"2026-08-19T12:57:19Z","id":"s"#,
        #"chema-16-recording","language":"auto","microphoneAudio":{"bufferCount":34448,"capturedDurati"#,
        #"onSeconds":3444.7931109166607,"channelCount":1,"fileName":"microphone-16k.wav","firstPresent"#,
        #"ationTimestamp":202147.9940662917,"lastPresentationTimestamp":205592.68317720835,"sampleRate"#,
        #"":16000,"totalFrames":55116641},"output":{"exportedAt":"2026-08-19T13:02:34Z","markdownFileN"#,
        #"ame":"Recording.md","markdownPath":"/redacted/Recording.md","status":"completed"},"outputFil"#,
        #"eNameTemplate":"{date} {time} - {title}","outputLanguage":"cs","recordingAudioRetention":{"c"#,
        #"andidateFiles":["microphone-16k.wav","system-16k.wav"],"cleanupCompletedAt":"2026-08-25T14:4"#,
        #"8:39Z","cleanupStartedAt":"2026-08-25T14:48:39Z","cleanupStatus":"purged","cleanupTrigger":""#,
        #"manual","deletedFiles":["microphone-16k.wav","system-16k.wav"],"keepAudio":false,"reclaimedB"#,
        #"ytes":220520448},"schemaVersion":16,"startedAt":"2026-08-19T11:59:51Z","status":"recorded",""#,
        #"systemAudio":{"bufferCount":172319,"capturedDurationSeconds":3447.199999999993,"channelCount"#,
        #"":1,"fileName":"system-16k.wav","firstPresentationTimestamp":202145.54622425,"lastPresentati"#,
        #"onTimestamp":205592.72622425,"sampleRate":16000,"totalFrames":55142074},"title":"Recording","#,
        #""transcriptFiles":{"analysis":"analysis.json","merged":"transcript.json","microphoneTrack":""#,
        #"microphone-transcript.json","resolved":"resolved-transcript.json","speakerDiarization":"spea"#,
        #"ker-diarization.json","speakerTurns":"speaker-turns.json","systemTrack":"system-transcript.j"#,
        #"son","utterances":"utterance-transcript.json"},"transcription":{"completedAt":"2026-08-19T12"#,
        #":58:59Z","mergedSegmentCount":589,"microphonePerformance":{"activeDurationSeconds":1137.9999"#,
        #"999998909,"audioDurationSeconds":3444.8,"chunkCount":230,"inferenceInputDurationSeconds":344"#,
        #"4.8,"skippedDurationSeconds":2306.8000000001093,"wallTimeSeconds":38.584026041673496},"micro"#,
        #"phoneSegmentCount":255,"model":"FluidInference/parakeet-tdt-0.6b-v3-coreml","provenance":{"c"#,
        #"onfigurationRevision":"parakeet-v3-int8-longform-v1","engine":"FluidAudio","engineVersion":""#,
        #"0.15.5","model":"FluidInference/parakeet-tdt-0.6b-v3-coreml","modelRevision":"aed02740059203"#,
        #"c4a87495924f685de3722ae9ce","modelVariant":"v3-int8"},"startedAt":"2026-08-19T12:57:19Z","st"#,
        #"atus":"completed","systemPerformance":{"activeDurationSeconds":1468.4799999997997,"audioDura"#,
        #"tionSeconds":3446.38,"chunkCount":230,"inferenceInputDurationSeconds":3446.38,"skippedDurati"#,
        #"onSeconds":1977.9000000002004,"wallTimeSeconds":61.18605558332638},"systemSegmentCount":334,"#,
        #""utteranceCount":137,"utteranceFallbackUsed":false,"warnings":[]}}"#,
    ].joined()
}
