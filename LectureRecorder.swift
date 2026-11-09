import AppIntents
import AVFoundation
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct LectureRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            RecorderView()
        }
    }
}

private struct LectureContext: Codable {
    let className: String
    let week: String?
    let lectureDate: String
}

private struct LectureResult: Codable {
    let className: String
    let week: String?
    let lectureDate: String
    let transcript: String
}

private enum LectureFiles {
    static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("Lectures", isDirectory: true)
    }

    static func context(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("context.json")
    }

    static func transcript(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("transcript.json")
    }
}

private enum LectureError: LocalizedError {
    case microphoneDenied
    case couldNotStart
    case noActiveRecording
    case unsupportedDevice
    case unsupportedLanguage
    case noSpeech
    case invalidRecordingID
    case couldNotOpenShortcut

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Allow microphone access in Settings to record."
        case .couldNotStart:
            return "The recorder couldn’t start."
        case .noActiveRecording:
            return "There’s no recording in progress."
        case .unsupportedDevice:
            return "On-device transcription requires iOS 26 and a supported iPhone."
        case .unsupportedLanguage:
            return "US English transcription is unavailable on this device."
        case .noSpeech:
            return "No speech was detected in this recording."
        case .invalidRecordingID:
            return "Use Shortcut Input as the Recording ID."
        case .couldNotOpenShortcut:
            return "Couldn’t open Finish Class. Your audio and transcript are saved."
        }
    }
}

@MainActor
private final class LectureRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = LectureRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var lastRecording: URL?
    @Published private(set) var transcript = ""
    @Published private(set) var isTranscribing = false
    @Published private(set) var errorMessage: String?

    private var recorder: AVAudioRecorder?

    func start(context: LectureContext? = nil) async throws {
        guard recorder == nil, !isTranscribing else { return }

        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else { throw LectureError.microphoneDenied }
        guard recorder == nil, !isTranscribing else { return }

        try FileManager.default.createDirectory(
            at: LectureFiles.directory,
            withIntermediateDirectories: true
        )

        let audio = LectureFiles.directory
            .appendingPathComponent("Lecture-\(UUID().uuidString).m4a")
        let session = AVAudioSession.sharedInstance()

        do {
            if let context {
                let data = try JSONEncoder().encode(context)
                try data.write(to: LectureFiles.context(for: audio), options: .atomic)
            }

            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let newRecorder = try AVAudioRecorder(url: audio, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            newRecorder.delegate = self

            guard newRecorder.record() else {
                throw LectureError.couldNotStart
            }

            recorder = newRecorder
            isRecording = true
            errorMessage = nil
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: LectureFiles.context(for: audio))
            throw error
        }
    }

    func stop() throws -> URL {
        guard let recorder else { throw LectureError.noActiveRecording }

        let audio = recorder.url
        recorder.stop()
        finishRecording(audio)
        return audio
    }

    private func finishRecording(_ audio: URL?) {
        recorder = nil
        isRecording = false

        if let audio {
            lastRecording = audio
            transcript = ""
        }

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        let audio = recorder.url
        Task { @MainActor in
            guard self.recorder?.url == audio else { return }
            self.finishRecording(flag ? audio : nil)
        }
    }

    func toggleRecording() async {
        errorMessage = nil

        do {
            if isRecording {
                let audio = try stop()
                if hasClassContext(for: audio) {
                    await transcribe(audio, launchFinishClass: true)
                }
            } else {
                try await start()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func hasClassContext(for audio: URL) -> Bool {
        FileManager.default.fileExists(atPath: LectureFiles.context(for: audio).path)
    }

    func transcribe(_ audio: URL, launchFinishClass: Bool) async {
        guard !isTranscribing, !isRecording else { return }
        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }

        do {
            let resultURL = LectureFiles.transcript(for: audio)
            if FileManager.default.fileExists(atPath: resultURL.path) {
                let saved = try JSONDecoder().decode(
                    LectureResult.self,
                    from: Data(contentsOf: resultURL)
                )
                transcript = saved.transcript
            } else {
                transcript = try await LectureTranscriber.transcribe(audio)

                if hasClassContext(for: audio) {
                    let context = try JSONDecoder().decode(
                        LectureContext.self,
                        from: Data(contentsOf: LectureFiles.context(for: audio))
                    )
                    let result = LectureResult(
                        className: context.className,
                        week: context.week,
                        lectureDate: context.lectureDate,
                        transcript: transcript
                    )
                    try JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
                }
            }

            guard launchFinishClass else { return }

            var callback = URLComponents()
            callback.scheme = "shortcuts"
            callback.host = "run-shortcut"
            callback.queryItems = [
                URLQueryItem(name: "name", value: "Finish Class"),
                URLQueryItem(name: "input", value: "text"),
                URLQueryItem(
                    name: "text",
                    value: audio.deletingPathExtension().lastPathComponent
                )
            ]

            guard let url = callback.url, await UIApplication.shared.open(url) else {
                throw LectureError.couldNotOpenShortcut
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RecorderView: View {
    @ObservedObject private var recorder = LectureRecorder.shared

    var body: some View {
        VStack(spacing: 20) {
            Text("Lecture Recorder")
                .font(.largeTitle.bold())

            Text(recorder.isRecording ? "Recording…" : "Ready to record")
                .foregroundStyle(recorder.isRecording ? Color.red : Color.secondary)

            Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
                Task { await recorder.toggleRecording() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(recorder.isTranscribing)

            if let audio = recorder.lastRecording, !recorder.isRecording {
                ShareLink("Share Last Recording", item: audio)

                let hasClass = recorder.hasClassContext(for: audio)
                Button(hasClass ? "Run Finish Class" : "Transcribe Last Recording") {
                    Task {
                        await recorder.transcribe(audio, launchFinishClass: hasClass)
                    }
                }
                .disabled(recorder.isTranscribing)
            }

            if recorder.isTranscribing {
                ProgressView("Preparing or transcribing audio…")
            }

            if let errorMessage = recorder.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if !recorder.transcript.isEmpty, !recorder.isRecording {
                ScrollView {
                    Text(recorder.transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)

                ShareLink("Share Transcript", item: recorder.transcript)
            }
        }
        .padding()
    }
}

struct StartLectureRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Lecture Recording"
    static let openAppWhenRun = true

    @Parameter(title: "Class Name")
    var className: String?

    @Parameter(title: "Week")
    var week: String?

    @Parameter(title: "Lecture Date")
    var lectureDate: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let name = className?.trimmingCharacters(in: .whitespacesAndNewlines)
        let context: LectureContext?

        if let name, !name.isEmpty {
            context = LectureContext(
                className: name,
                week: week,
                lectureDate: lectureDate ?? Date.now.formatted(.iso8601)
            )
        } else {
            context = nil
        }

        try await LectureRecorder.shared.start(context: context)
        return .result()
    }
}

struct StopAndGetLectureAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop and Get Lecture Audio"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let audio = try LectureRecorder.shared.stop()
        return .result(value: IntentFile(
            fileURL: audio,
            filename: "lecture.m4a",
            type: .mpeg4Audio
        ))
    }
}

struct GetLectureTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Lecture Transcript"

    @Parameter(title: "Recording ID")
    var recordingID: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let prefix = "Lecture-"
        guard recordingID.hasPrefix(prefix),
              let id = UUID(uuidString: String(recordingID.dropFirst(prefix.count)))
        else {
            throw LectureError.invalidRecordingID
        }

        let audio = LectureFiles.directory
            .appendingPathComponent("Lecture-\(id.uuidString).m4a")
        let data = try Data(contentsOf: LectureFiles.transcript(for: audio))
        return .result(value: String(decoding: data, as: UTF8.self))
    }
}

private enum LectureTranscriber {
    static func transcribe(_ audio: URL) async throws -> String {
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable else {
            throw LectureError.unsupportedDevice
        }

        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en-US")
        ) else {
            throw LectureError.unsupportedLanguage
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let transcript: String = collectResults(from: transcriber)

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            return try await transcript
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    @available(iOS 26.0, *)
    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> String {
        var passages: [String] = []

        for try await result in transcriber.results {
            let passage = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !passage.isEmpty {
                passages.append(passage)
            }
        }

        guard !passages.isEmpty else { throw LectureError.noSpeech }
        return passages.joined(separator: " ")
    }
}

struct TranscribeLectureAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Lecture Audio"
    static let openAppWhenRun = true

    @Parameter(title: "Audio File")
    var audioFile: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let url = audioFile.fileURL {
            return .result(value: try await LectureTranscriber.transcribe(url))
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let filename = URL(fileURLWithPath: audioFile.filename).lastPathComponent
        let url = folder.appendingPathComponent(filename)
        try audioFile.data.write(to: url)

        return .result(value: try await LectureTranscriber.transcribe(url))
    }
}