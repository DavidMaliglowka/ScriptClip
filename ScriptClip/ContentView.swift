import SwiftUI
import AVKit // Player
import WhisperKit // Transcription
import CoreML // ML models
import AppKit // For NSEvent (Shift key)

// MARK: - Data Structures

struct TranscriptWord: Identifiable, Hashable {
    let id = UUID()
    var text: String // Mutable for editing
    let start: Float
    let end: Float
}

// Custom error for editing operations
struct EditError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Main Content View

struct ContentView: View {

    // MARK: - State Variables

    // File & Player State
    @State private var selectedVideoURL: URL?
    @State private var player: AVPlayer?
    @State private var accessedURL: URL? // For security-scoped access
    // NOTE: Removed currentComposition state to simplify and avoid concurrency issues for now.
    // Edits are currently NOT cumulative. Each delete operates on the original file.

    // Transcription State
    @State private var transcriptWords: [TranscriptWord] = []
    @State private var isTranscribing: Bool = false
    @State private var transcriptionProgress: Double = 0.0
    @State private var transcriptionTask: Task<Void, Never>? = nil

    // WhisperKit State
    @State private var whisperPipe: WhisperKit?
    @State private var isWhisperKitInitialized = false
    @State private var whisperKitInitError: String? = nil

    // UI State
    @State private var showingFileImporter = false
    @State private var statusMessage: String = "Select a video file."

    // Selection State
    @State private var selectedWordIDs: Set<UUID> = []
    @State private var selectionAnchorID: UUID? = nil

    // Inline Editing State
    @State private var editingWordID: UUID? = nil
    @State private var editText: String = ""
    @FocusState private var focusedWordID: UUID?

    // MARK: - Body

    var body: some View {
        HSplitView {
            // --- Left Panel: Player & Controls ---
            playerAndControlsView

            // --- Right Panel: Transcript ---
            transcriptEditorView
        }
        // --- Modifiers ---
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.movie, .video, .audio], allowsMultipleSelection: false, onCompletion: handleFileSelection)
        .navigationTitle("ScriptClip")
        .frame(minWidth: 700, minHeight: 450)
        .task { await initializeWhisperKit() } // Initialize WhisperKit on appear
        .onDisappear { // Cleanup on view disappear
            cancelTranscription()
            stopAccessingURL()
            commitEdit() // Commit any pending text edit
        }
    }

    // MARK: - UI Components

    private var playerAndControlsView: some View {
        VStack {
            // Video Player
            if let player = player {
                VideoPlayer(player: player)
                    .frame(minHeight: 200)
                    // Attempt to address layout warnings
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                videoPlaceholderView
            }

            // Progress/Cancel Bar (during transcription)
            transcriptionProgressView

            // Edit Controls Bar
            editControlsView

            // Status Message
            Text(statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .frame(minWidth: 300)
    }

    private var videoPlaceholderView: some View {
        ZStack {
            Rectangle().fill(.black).frame(minHeight: 200)
            Text(selectedVideoURL == nil ? "Select a video file" : "Loading video...")
                .foregroundColor(.secondary)
        }
        // Attempt to address layout warnings
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var transcriptionProgressView: some View {
        // Shows Select Video button or Transcription Progress/Cancel
        HStack {
            Button { showingFileImporter = true } label: { Label("Select Video", systemImage: "video.fill") }
            Spacer()
            if isTranscribing {
                ProgressView(value: transcriptionProgress).frame(width: 100)
                Text("\(Int(transcriptionProgress * 100))%")
                Button("Cancel", role: .destructive) { cancelTranscription() }
            }
        }
        .padding([.horizontal, .bottom])
        .frame(minHeight: 25) // Keep a minimum height
    }

    private var editControlsView: some View {
        HStack {
            Button(role: .destructive) {
                deleteSelectedWords()
            } label: {
                Label("Delete Selection", systemImage: "trash")
            }
             // Disable if no media loaded or nothing selected
            .disabled(selectedWordIDs.isEmpty || selectedVideoURL == nil)

            Spacer()
        }
        .padding(.horizontal)
        .frame(minHeight: 25) // Keep consistent height
    }

    private var transcriptEditorView: some View {
        VStack(alignment: .leading) {
            Text("Transcript:")
                .font(.headline)
                .padding(.top)
                .padding(.horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if transcriptWords.isEmpty && !isTranscribing && selectedVideoURL != nil {
                         Text("Transcript will appear here.")
                            .foregroundColor(.secondary).padding()
                    } else if isTranscribing && transcriptWords.isEmpty {
                         Text("Transcription in progress...")
                            .foregroundColor(.secondary).padding()
                    } else {
                        displayTranscriptWords() // The main transcript view builder
                    }
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 250, minHeight: 200)
            .border(Color.gray.opacity(0.5))
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 300)
    }

    // --- Transcript Word Display ---
    @ViewBuilder
    private func displayTranscriptWords() -> some View {
        let lines = groupWordsIntoLines(words: transcriptWords, charactersPerLine: 60)

        ForEach(lines.indices, id: \.self) { lineIndex in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(lines[lineIndex]) { wordData in
                    if let wordIndex = transcriptWords.firstIndex(where: { $0.id == wordData.id }) {
                        WordView( // Use the helper struct
                            word: $transcriptWords[wordIndex],
                            selectedWordIDs: $selectedWordIDs,
                            editingWordID: $editingWordID,
                            editText: $editText,
                            focusedWordID: $focusedWordID,
                            onTap: handleTap,
                            onBeginEdit: beginEditing,
                            onCommitEdit: commitEdit
                        )
                    } else { EmptyView() }
                }
            }
        }
    }

    // MARK: - File Handling & Security Scope

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        stopAccessingURL() // Stop accessing previous URL if any
        // currentComposition = nil // Removed state
        player?.replaceCurrentItem(with: nil) // Clear player
        player = nil
        transcriptWords = [] // Clear transcript
        selectedWordIDs = []
        selectionAnchorID = nil

        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                statusMessage = "Error: Could not get permission to access the file."
                print("Error: Failed to start accessing security scoped resource for \(url.path)")
                selectedVideoURL = nil; accessedURL = nil
                return
            }

            accessedURL = url
            selectedVideoURL = url // Set the URL state AFTER getting access
            print("Successfully started accessing: \(url.path)")

            // Initialize player with the original asset URL
            player = AVPlayer(url: url)
            statusMessage = "Video loaded. Preparing transcription..."
            print("Selected file: \(url.path)")

            // Trigger auto-transcription
            triggerAutoTranscription(url: url)

        case .failure(let error):
            print("Error selecting file: \(error.localizedDescription)")
            statusMessage = "Error loading video: \(error.localizedDescription)"
            selectedVideoURL = nil; accessedURL = nil
        }
    }

    private func stopAccessingURL() {
        if let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
            print("Stopped accessing security scoped resource for \(url.path)")
            accessedURL = nil
        }
    }

    // MARK: - Transcription Logic

    private func triggerAutoTranscription(url: URL) {
         if isWhisperKitInitialized && whisperKitInitError == nil {
            cancelTranscription() // Cancel any previous task
            transcriptionTask = Task {
                 print("Auto-transcribing...")
                 await performTranscription(url: url)
            }
         } else {
             statusMessage = "Video loaded. Initialize engine to transcribe."
             print("WhisperKit not ready, skipping auto-transcription.")
         }
    }

    func initializeWhisperKit() async {
         guard whisperPipe == nil && whisperKitInitError == nil else { return }
         await MainActor.run { statusMessage = "Initializing transcription engine..." }
         print("Initializing WhisperKit...")
         do {
             let pipe = try await WhisperKit(model: "base.en", verbose: true, logLevel: .debug)
             await MainActor.run {
                 self.whisperPipe = pipe; self.isWhisperKitInitialized = true
                 self.statusMessage = "Transcription engine ready."
                 print("WhisperKit initialized successfully.")
             }
         } catch {
             print("Error initializing WhisperKit: \(error)")
             await MainActor.run {
                 self.whisperKitInitError = "Failed to init engine: \(error.localizedDescription)"
                 self.statusMessage = self.whisperKitInitError!
                 self.isWhisperKitInitialized = false
             }
         }
    }

    func cancelTranscription() {
         print("Cancellation requested.")
         transcriptionTask?.cancel() // Request Task cancellation
         if isTranscribing {
             // If actively transcribing when cancelled, update state immediately
             Task { await MainActor.run { cleanupAfterTranscription(status: "Transcription cancelled.") } }
         }
    }

    @MainActor
    func performTranscription(url: URL) async {
         guard isWhisperKitInitialized, let activeWhisperPipe = whisperPipe else {
              statusMessage = "Transcription engine not ready."
              print("Attempted transcription but WhisperKit not ready.")
              isTranscribing = false // Ensure this is reset
              return
         }
         guard !isTranscribing else {
              print("Transcription already in progress, ignoring duplicate request.")
              return
         }

         print("Starting transcription process for: \(url.path)")
         isTranscribing = true // Set flag immediately
         transcriptionProgress = 0.0
         transcriptWords = [] // Clear previous results
         statusMessage = "Extracting audio..."

         // --- Audio Extraction ---
         guard let audioFrames = await extractAndConvertAudio(from: url, isCancelled: { Task.isCancelled }) else {
             if Task.isCancelled { print("Audio extraction cancelled."); cleanupAfterTranscription(status: "Transcription cancelled.") }
             else { print("Audio extraction failed."); cleanupAfterTranscription(status: "Error: Failed to extract audio.") }
             return
         }
         // Silence 'unused' warning
         _ = audioFrames.count

         // --- Check for Cancellation After Extraction ---
         if Task.isCancelled { cleanupAfterTranscription(status: "Transcription cancelled."); return }

         // --- Transcription ---
         statusMessage = "Transcribing audio..."
         do {
             print("Passing \(audioFrames.count) audio frames to WhisperKit.")
             let decodingOptions = DecodingOptions(verbose: true, wordTimestamps: true)
             let transcriptionCallback: TranscriptionCallback = { progress in Task { @MainActor in guard self.isTranscribing else { return }; let currentProgress = self.transcriptionProgress + 0.01; self.transcriptionProgress = min(currentProgress, 0.95); self.statusMessage = "Transcribing... \(Int(self.transcriptionProgress * 100))%" }; return !Task.isCancelled }

             let transcriptionResults: [TranscriptionResult] = try await activeWhisperPipe.transcribe( audioArray: audioFrames, decodeOptions: decodingOptions, callback: transcriptionCallback )
             if Task.isCancelled { cleanupAfterTranscription(status: "Transcription cancelled."); return }

             // --- Process Results ---
             let mergedResult = mergeTranscriptionResults(transcriptionResults)
             if let finalWords = mergedResult?.allWords { self.transcriptWords = finalWords.map { TranscriptWord(text: $0.word, start: $0.start, end: $0.end) }; print("Transcription finished with \(self.transcriptWords.count) words."); cleanupAfterTranscription(status: "Transcription complete.") }
             else { print("Transcription finished but produced no words/text."); self.transcriptWords = []; cleanupAfterTranscription(status: "Transcription complete (no text).") }
             self.transcriptionProgress = 1.0 // Ensure progress hits 100%

         } catch is CancellationError { print("Transcription task explicitly cancelled."); cleanupAfterTranscription(status: "Transcription cancelled.") }
           catch { print("WhisperKit transcription failed: \(error)"); cleanupAfterTranscription(status: "Error during transcription."); self.transcriptWords = [] }
    }

    @MainActor
    private func cleanupAfterTranscription(status: String) {
         print("Cleaning up transcription task. Final Status: \(status)")
         if status == "Transcription complete." || status.contains("no text") { transcriptionProgress = 1.0 }
         else { transcriptionProgress = 0.0 } // Failed or cancelled
         isTranscribing = false
         statusMessage = status
         transcriptionTask = nil
    }

    // MARK: - AVFoundation Logic

    // --- Audio Extraction ---
     func extractAndConvertAudio(from url: URL, isCancelled: @escaping () -> Bool) async -> [Float]? {
         print("[Audio Extraction] Starting for: \(url.path)")
         let asset = AVURLAsset(url: url)
         do {
             // Check properties concurrently
             async let isPlayable = try asset.load(.isPlayable)
             async let hasProtectedContent = try asset.load(.hasProtectedContent)
             async let tracks = try asset.loadTracks(withMediaType: .audio)
             async let duration = try asset.load(.duration)

             let playable = try await isPlayable
             let protected = try await hasProtectedContent
             print("[Audio Extraction] Properties: isPlayable=\(playable), hasProtectedContent=\(protected)")
             if protected { throw EditError("Asset has protected content.") }
             if !playable { throw EditError("Asset is not playable.") }

             guard let assetTrack = try await tracks.first else { throw EditError("No audio track found.") }
             print("[Audio Extraction] Track duration: \(try await duration.seconds) seconds")

             // Setup reader
             guard let reader = try? AVAssetReader(asset: asset) else { throw EditError("Error creating AVAssetReader.") }
             let outputSettings: [String: Any] = [ AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false ]
             let trackOutput = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: outputSettings)
             guard reader.canAdd(trackOutput) else { throw EditError("Cannot add track output.") }
             reader.add(trackOutput)

             guard reader.startReading() else { throw EditError("Error starting reader: \(reader.error?.localizedDescription ?? "Unknown")") }
             print("[Audio Extraction] AVAssetReader started reading...")

             // Read samples in background Task
             return try await Task.detached(priority: .userInitiated) {
                 var audioFrames: [Float] = []
                 var bufferCount = 0
                 let bufferReadQueue = DispatchQueue(label: "audio-buffer-read-queue", qos: .userInitiated)

                 var readError: Error? = nil
                 var cancelled = false

                 bufferReadQueue.sync { // Ensure reading finishes before Task returns
                     while reader.status == .reading {
                         if isCancelled() { reader.cancelReading(); cancelled = true; break }
                         if let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                             bufferCount += 1
                             if let samples = convertSampleBuffer(sampleBuffer) { audioFrames.append(contentsOf: samples) }
                             else { readError = EditError("Failed to convert sample buffer"); reader.cancelReading(); break }
                             CMSampleBufferInvalidate(sampleBuffer)
                         } else { break } // End of stream or error during copy
                     }
                     // Capture reader error if reading failed
                     if reader.status == .failed { readError = reader.error }
                 } // End sync block

                 // Check final status
                 if cancelled { throw CancellationError() }
                 if let error = readError { throw EditError("Reader failed: \(error.localizedDescription)") }
                 guard reader.status == .completed else { throw EditError("Reader finished with unexpected status: \(reader.status.rawValue)") }

                 print("[Audio Extraction Task] Complete. Read \(bufferCount) buffers. Frames: \(audioFrames.count)")
                 return audioFrames
             }.value

         } catch is CancellationError {
              print("[Audio Extraction] Cancelled during async operations.")
              return nil
         } catch {
              print("[Audio Extraction] Failed: \(error.localizedDescription)")
              return nil
         }
     }

    // --- Convert Sample Buffer ---
    private func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
         guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
         let length = CMBlockBufferGetDataLength(blockBuffer)
         guard length > 0, length % MemoryLayout<Float>.stride == 0 else { return nil } // Added length > 0 check
         let numFloats = length / MemoryLayout<Float>.stride
         var data = [Float](repeating: 0.0, count: numFloats)
         let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
         guard status == kCMBlockBufferNoErr else { print("Error copying buffer data: \(status)"); return nil }
         return data
    }

    // MARK: - Editing Logic

    @MainActor
    private func deleteSelectedWords() {
        guard !selectedWordIDs.isEmpty else { print("[Delete] No words selected."); return }
        guard let originalURL = selectedVideoURL else { print("[Delete] No original URL."); return }
        guard let (startTime, endTime) = getTimeRangeForSelection() else { print("[Delete] Could not get time range."); return }

        let timeRangeToRemove = CMTimeRangeFromTimeToTime(start: CMTime(seconds: Double(startTime), preferredTimescale: 600),
                                                          end: CMTime(seconds: Double(endTime), preferredTimescale: 600))
        print("[Delete] Removing range: \(CMTimeRangeShow(timeRangeToRemove)) from ORIGINAL asset.") // Non-cumulative edit
        statusMessage = "Processing deletion..."

        Task.detached(priority: .userInitiated) {
            var accessStarted = false // Track if access needs to be stopped
            do {
                // --- Resource Access ---
                 guard originalURL.startAccessingSecurityScopedResource() else { throw EditError("Could not re-access file.") }
                 accessStarted = true
                 print("[Delete Task] Started access: \(originalURL.path)")

                // --- Always create composition from the ORIGINAL URL Asset ---
                 let originalAsset = AVURLAsset(url: originalURL)
                 let composition = AVMutableComposition()

                 // --- Populate NEW composition from original ---
                 print("[Delete Task] Creating new composition from AVURLAsset...")
                 async let videoTrack = originalAsset.loadTracks(withMediaType: .video).first
                 async let audioTrack = originalAsset.loadTracks(withMediaType: .audio).first
                 async let duration = originalAsset.load(.duration)

                 guard let originalVideoTrack = try await videoTrack,
                       let originalAudioTrack = try await audioTrack else { throw EditError("Cannot load tracks.") }
                 let originalDuration = try await duration

                 let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                 let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                 try compVideoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: originalDuration), of: originalVideoTrack, at: .zero)
                 try compAudioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: originalDuration), of: originalAudioTrack, at: .zero)
                 print("[Delete Task] Tracks added.")
                 // --- End Populate ---

                // --- Modify Composition ---
                 let editAssetDuration = try await composition.load(.duration) // Await duration load
                 let editAssetTimeRange = CMTimeRange(start: .zero, duration: editAssetDuration)
                 print("[Delete Task] Duration before removal: \(CMTimeGetSeconds(editAssetDuration))s")

                 guard CMTimeRangeContainsTimeRange(editAssetTimeRange, otherRange: timeRangeToRemove) else { throw EditError("Selected time range invalid.") }

                 composition.removeTimeRange(timeRangeToRemove)
                 print("[Delete Task] Time range removed. New duration: \(CMTimeGetSeconds(composition.duration))s")

                 guard try await composition.load(.isPlayable) else { throw EditError("Edited composition not playable.") } // Await playability
                 print("[Delete Task] Edited composition playable.")
                 // --- End Modify ---

                // --- Create PlayerItem ---
                guard let immutableAsset = composition.copy() as? AVAsset else {
                     throw EditError("Failed to create immutable copy of composition.")
                }
                
                print("[Delete Task] Created immutable copy for PlayerItem.")
                
                // Create player item from the IMMUTABLE copy, using await

                let newPlayerItem = await AVPlayerItem(asset: immutableAsset)
                print("[Delete Task] New player item created.")

                // --- Stop access before returning to MainActor ---
                 if accessStarted { originalURL.stopAccessingSecurityScopedResource(); print("[Delete Task] Stopped access.") }
                 accessStarted = false // Mark as stopped

                 // --- Update Main Actor State ---
                 await MainActor.run {
                      print("[Delete MainActor] Replacing player item...")
                      player?.pause()
                      // currentComposition = nil // Removed state
                      player?.replaceCurrentItem(with: newPlayerItem) // Replace with the new item

                      // Update Transcript & Selection
                      transcriptWords.removeAll { selectedWordIDs.contains($0.id) }
                      selectedWordIDs = []; selectionAnchorID = nil
                      print("[Delete MainActor] Transcript state updated.")

                      // Playback logic
                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                           guard let currentItem = self.player?.currentItem else { return }
                           print("[Delete MainActor Post-Delay] Item status: \(currentItem.status.rawValue)")
                           if currentItem.status == .readyToPlay { self.player?.play(); self.statusMessage = "Selection deleted." }
                           else if currentItem.status == .failed { self.statusMessage = "Error playing edited video: \(currentItem.error?.localizedDescription ?? "unknown")" }
                           else { self.statusMessage = "Edited video loaded..." }
                      }
                 } // End MainActor.run

            } catch { // Catch errors from async/await or thrown EditErrors
                 print("[Delete Task] Error during AVComposition editing/loading: \(error)")
                 // Ensure access is stopped even on error
                 if accessStarted { originalURL.stopAccessingSecurityScopedResource(); print("[Delete Task] Stopped access after error.") }
                 let errorMessage = (error as? EditError)?.message ?? error.localizedDescription
                 await MainActor.run { statusMessage = "Error during editing: \(errorMessage)" }
            }
        } // End Task
    }

    private func getTimeRangeForSelection() -> (start: Float, end: Float)? {
         guard !selectedWordIDs.isEmpty else { return nil }
         let selectedWords = transcriptWords.filter { selectedWordIDs.contains($0.id) }
         guard !selectedWords.isEmpty else { return nil }
         let startTime = selectedWords.min(by: { $0.start < $1.start })?.start ?? 0.0
         let endTime = selectedWords.max(by: { $0.end < $1.end })?.end ?? startTime
         return (startTime, endTime)
    }

    // MARK: - Text Editing & Selection

    // --- ADD THIS FUNCTION BACK ---
    private func seekPlayer(to time: Float) {
        guard let player = player else { return }
        let cmTime = CMTime(seconds: Double(time), preferredTimescale: 600)
        let rate = player.rate // Get rate before seeking
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] finished in
            guard finished, let player = player else { print("Seek cancelled."); return }
            print("Seek finished to \(time)s")
            if rate == 0 { player.play() } // Play only if was paused
        }
    }

    private func handleTap(on word: TranscriptWord) {
         if editingWordID != nil { commitEdit() }
         guard editingWordID == nil else { return }

         let shiftPressed = NSEvent.modifierFlags.contains(.shift)
         if shiftPressed, let anchorId = selectionAnchorID,
            let anchorIndex = transcriptWords.firstIndex(where: { $0.id == anchorId }),
            let currentIndex = transcriptWords.firstIndex(where: { $0.id == word.id }) {
             let startIndex = min(anchorIndex, currentIndex); let endIndex = max(anchorIndex, currentIndex)
             let newSelection = Set(transcriptWords[startIndex...endIndex].map { $0.id })
             if selectedWordIDs != newSelection { selectedWordIDs = newSelection }
         } else {
             if selectedWordIDs != [word.id] { seekPlayer(to: word.start) } else { seekPlayer(to: word.start) }
             selectedWordIDs = [word.id]
             selectionAnchorID = word.id
         }
    }

    private func beginEditing(word: TranscriptWord) {
         if editingWordID != nil && editingWordID != word.id { commitEdit() }
         guard editingWordID != word.id else { return }

         print("[beginEditing] Word: \(word.text) (ID: \(word.id))")
         editText = word.text; editingWordID = word.id
         selectedWordIDs = []; selectionAnchorID = nil

         DispatchQueue.main.async { self.focusedWordID = word.id }
    }

    private func commitEdit() {
        guard let wordIdToCommit = editingWordID else { return }
        print("[commitEdit] Committing ID \(wordIdToCommit)")
        defer { editingWordID = nil; editText = "" } // Reset state regardless

        guard let wordIndex = transcriptWords.firstIndex(where: { $0.id == wordIdToCommit }) else { return }
        let originalText = transcriptWords[wordIndex].text
        let newText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if originalText != newText && !newText.isEmpty { transcriptWords[wordIndex].text = newText }
    }

    // MARK: - Helpers

    private func groupWordsIntoLines(words: [TranscriptWord], charactersPerLine: Int) -> [[TranscriptWord]] {
         var lines: [[TranscriptWord]] = []; var currentLine: [TranscriptWord] = []; var currentLineLength = 0
         for word in words { let wordLength = word.text.count + 1; if currentLine.isEmpty || currentLineLength + wordLength <= charactersPerLine { currentLine.append(word); currentLineLength += wordLength } else { lines.append(currentLine); currentLine = [word]; currentLineLength = wordLength } }; if !currentLine.isEmpty { lines.append(currentLine) }; return lines
    }

    private func mergeTranscriptionResults(_ results: [TranscriptionResult]) -> TranscriptionResult? {
         guard !results.isEmpty else { return nil }; if results.count == 1 { return results.first }
         let combinedText = results.map { $0.text }.joined(separator: " "); let combinedSegments = results.flatMap { $0.segments }; let language = results.first!.language; var mergedTimings = results.first!.timings; mergedTimings.fullPipeline = results.reduce(TimeInterval(0)) { $0 + $1.timings.fullPipeline }; return TranscriptionResult(text: combinedText, segments: combinedSegments, language: language, timings: mergedTimings)
    }

} // End ContentView


// MARK: - Preview
#Preview {
    ContentView()
}

// MARK: - Helper View: WordView
struct WordView: View {
    @Binding var word: TranscriptWord
    @Binding var selectedWordIDs: Set<UUID>
    @Binding var editingWordID: UUID?
    @Binding var editText: String
    @FocusState.Binding var focusedWordID: UUID?

    let onTap: (TranscriptWord) -> Void
    let onBeginEdit: (TranscriptWord) -> Void
    let onCommitEdit: () -> Void

    var body: some View {
        Group {
            if editingWordID == word.id {
                TextField("Edit", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                    .padding(.vertical, 1)
                    .padding(.horizontal, 2)
                    .fixedSize()
                    .focused($focusedWordID, equals: word.id)
                    .onSubmit(onCommitEdit)
                    // Removed .onDisappear commit for stability
                    .onChange(of: focusedWordID) {
                        if focusedWordID != word.id && editingWordID == word.id {
                            print("[onChange.Focus] Focus changed away from '\(word.text)'. Committing.")
                            onCommitEdit()
                        }
                    }
            } else {
                Text(word.text)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 2)
                    .background(selectedWordIDs.contains(word.id) ? Color.yellow.opacity(0.5) : Color.clear)
                    .cornerRadius(3)
                    .onTapGesture(count: 2) { onBeginEdit(word) }
                    .onTapGesture(count: 1) { onTap(word) }
            }
        }
    }
} // End WordView
