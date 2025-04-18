import SwiftUI
import AVKit
import WhisperKit
import CoreML
import AppKit // <-- Import AppKit for NSEvent

// Define a struct to hold word timing info (Matches WhisperKit.WordTiming ideally)
// If WhisperKit.WordTiming is directly usable and Codable, you might not need this,
// but having our own struct gives flexibility. Let's assume we need it for now.
struct TranscriptWord: Identifiable, Hashable {
    let id = UUID() // Make identifiable for ForEach
    var text: String // Make text mutable
    let start: Float
    let end: Float
    // Add any other relevant data from WhisperKit.WordTiming if needed
}

struct ContentView: View {
    // --- State variables ---
    @State private var selectedVideoURL: URL?
    @State private var player: AVPlayer?
    // Remove the old transcript string state
    // @State private var transcript: String = "Transcript will appear here..."
    @State private var transcriptWords: [TranscriptWord] = [] // <-- New state for structured words
    @State private var isTranscribing: Bool = false
    @State private var transcriptionProgress: Double = 0.0
    @State private var showingFileImporter = false
    @State private var statusMessage: String = "Select a video and click Transcribe."
    @State private var whisperPipe: WhisperKit?
    @State private var isWhisperKitInitialized = false
    @State private var whisperKitInitError: String? = nil
    @State private var transcriptionTask: Task<Void, Never>? = nil
    @State private var accessedURL: URL? = nil
    
    // --- Hold the current composition state ---
    @State private var currentComposition: AVComposition? = nil // Holds the latest edited state

    // State for text selection and highlighting
    @State private var selectedWordIDs: Set<UUID> = [] // Store IDs of selected words
    @State private var selectionAnchorID: UUID? = nil // ID of the first word clicked in a potential range selection
    
    // --- State for Inline Editing ---

       @State private var editingWordID: UUID? = nil

       @State private var editText: String = ""

       @FocusState private var focusedWordID: UUID? // For managing TextField focus
    
    var body: some View {
        HSplitView {
            // --- Left Side: Video Player and Controls (Keep mostly the same) ---
            VStack {
                if let player = player {
                    VideoPlayer(player: player)
                        .frame(minHeight: 200)
                        // No need for onAppear/onDisappear play/pause if managed elsewhere
                } else {
                    ZStack {
                        Rectangle().fill(.black).frame(minHeight: 200)
                        Text(selectedVideoURL == nil ? "Select a video file" : "Loading video...")
                            .foregroundColor(.secondary)
                    }
                }
                // --- Controls Bar ---
                HStack {
                    Button { showingFileImporter = true } label: { Label("Select Video", systemImage: "video.fill") }
                    Spacer()
                    if isTranscribing { /* ... Progress/Cancel ... */
                         ProgressView(value: transcriptionProgress).frame(width: 100)
                         Text("\(Int(transcriptionProgress * 100))%")
                         Button("Cancel", role: .destructive) { cancelTranscription() }
                    }
                    // Remove manual Transcribe button if auto-transcribe is reliable
                    // else { /* ... Transcribe Button ... */ }
                }
                .padding([.horizontal, .bottom])
                
                // --- Edit Controls ---
                        HStack {
                            Button(role: .destructive) {
                                deleteSelectedWords()
                            } label: {
                                Label("Delete Selection", systemImage: "trash")
                            }
                            .disabled(selectedWordIDs.isEmpty)

                            Spacer()
                        }
                        .padding(.horizontal)
                        // --- End Add Edit Controls ---
                
                // --- Status Message Area ---
                Text(statusMessage)
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 300)

            // --- Right Side: Transcript View ---
            VStack(alignment: .leading) {
                Text("Transcript:")
                    .font(.headline)
                    .padding(.top)
                    .padding(.horizontal)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if transcriptWords.isEmpty && !isTranscribing && selectedVideoURL != nil {
                             Text("Transcript will appear here after processing.")
                                .foregroundColor(.secondary)
                                .padding()
                        } else if isTranscribing && transcriptWords.isEmpty {
                             Text("Transcription in progress...")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            displayTranscriptWords()
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
        // --- Modifiers ---
        .fileImporter(
                   isPresented: $showingFileImporter,
                   allowedContentTypes: [.movie, .video, .audio],
                   allowsMultipleSelection: false,
                   onCompletion: { result in
                       stopAccessingURL() // Stop accessing previous URL if any
                       switch result {
                       case .success(let urls):
                           guard let url = urls.first else { return }
                           guard url.startAccessingSecurityScopedResource() else { /* ... error handling ... */ return }
                           
                           accessedURL = url // Keep track of the URL we have access to
                           print("Successfully started accessing security scoped resource for \(url.path)")
                           
                           // --- Reset state for new file ---
                           selectedVideoURL = url
                           currentComposition = nil // Reset composition on new file load
                           player = AVPlayer(url: url) // Use the original URL initially
                           transcriptWords = []
                           selectedWordIDs = []
                           selectionAnchorID = nil
                           statusMessage = "Video loaded. Preparing transcription..."
                           print("Selected file: \(url.path)")
                           
                           // --- Auto-Transcribe ---
                           if isWhisperKitInitialized && whisperKitInitError == nil {
                               cancelTranscription()
                               transcriptionTask = Task {
                                    print("Auto-transcribing...")
                                    await performTranscription(url: url)
                               }
                           } else { /* ... handle not ready ... */ }
                           
                       case .failure(let error):
                           /* ... existing error handling ... */
                            print("Error selecting file: \(error.localizedDescription)")
                            selectedVideoURL = nil; player = nil; transcriptWords = []; statusMessage = "Error loading video: \(error.localizedDescription)"; accessedURL = nil; currentComposition = nil
                       }
                   }
               ) // End of .fileImporter

        .navigationTitle("ScriptClip")
        .frame(minWidth: 700, minHeight: 450)
        .task { await initializeWhisperKit() }
        .onDisappear { cancelTranscription(); stopAccessingURL(); commitEdit() }
    } // End of body View

    // --- Helper View Struct for displaying/editing a single word ---
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
                        .fixedSize()
                        .focused($focusedWordID, equals: word.id)
                        .onSubmit(onCommitEdit)
                        .onDisappear(perform: onCommitEdit)
                        .onChange(of: focusedWordID) {
                            if focusedWordID != editingWordID && editingWordID == word.id {
                                 onCommitEdit()
                            }
                        }
                } else {
                    Text(word.text)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 2)
                        .background(selectedWordIDs.contains(word.id) ? Color.yellow.opacity(0.5) : Color.clear)
                        .cornerRadius(3)
                        .onTapGesture(count: 2) { onBeginEdit(word) } // Corrected call
                        .onTapGesture(count: 1) { onTap(word) }       // Corrected call
                }
            }
        }
    }

    // --- Display Transcript Words function ---
    @ViewBuilder
    private func displayTranscriptWords() -> some View {
        let lines = groupWordsIntoLines(words: transcriptWords, charactersPerLine: 60)

        ForEach(lines.indices, id: \.self) { lineIndex in
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(lines[lineIndex]) { wordData in
                    if let wordIndex = transcriptWords.firstIndex(where: { $0.id == wordData.id }) {
                        WordView(
                            word: $transcriptWords[wordIndex],
                            selectedWordIDs: $selectedWordIDs,
                            editingWordID: $editingWordID,
                            editText: $editText,
                            focusedWordID: $focusedWordID,
                            onTap: handleTap,           // Correct label matching WordView init
                            onBeginEdit: beginEditing,  // Correct label matching WordView init
                            onCommitEdit: commitEdit    // Correct label matching WordView init
                        )
                    } else { EmptyView() }
                }
            }
        }
    }
    
    // --- Tap Handling Logic ---
    private func handleTap(on word: TranscriptWord) {
         if editingWordID != nil { commitEdit() } // Commit edit first
         guard editingWordID == nil else { return } // Ignore taps while editing

         let shiftPressed = NSEvent.modifierFlags.contains(.shift)
         if shiftPressed, let anchorId = selectionAnchorID,
            let anchorIndex = transcriptWords.firstIndex(where: { $0.id == anchorId }),
            let currentIndex = transcriptWords.firstIndex(where: { $0.id == word.id }) {
             // Extend selection
             let startIndex = min(anchorIndex, currentIndex)
             let endIndex = max(anchorIndex, currentIndex)
             let newSelection = Set(transcriptWords[startIndex...endIndex].map { $0.id })
             if selectedWordIDs != newSelection { selectedWordIDs = newSelection }
         } else {
             // Select single word
             if selectedWordIDs != [word.id] { seekPlayer(to: word.start) }
             else { seekPlayer(to: word.start) } // Re-seek if same word clicked
             selectedWordIDs = [word.id]
             selectionAnchorID = word.id // Set anchor
         }
    }
    
    // --- Editing Functions ---
    private func beginEditing(word: TranscriptWord) {
         if editingWordID != nil && editingWordID != word.id { commitEdit() }
         guard editingWordID != word.id else { return } // Don't re-edit same word

         print("[beginEditing] Starting edit for word: \(word.text) (ID: \(word.id))")
         editText = word.text
         editingWordID = word.id
         selectedWordIDs = []
         selectionAnchorID = nil
         
         // Delay focus setting slightly
         DispatchQueue.main.async {
             self.focusedWordID = word.id
             print("[beginEditing] Focus requested for ID \(word.id)")
         }
    }

    private func commitEdit() {
        guard let wordIdToCommit = editingWordID else { return } // Exit if not editing
        print("[commitEdit] Attempting to commit edit for ID \(wordIdToCommit)")
        
        guard let wordIndex = transcriptWords.firstIndex(where: { $0.id == wordIdToCommit }) else {
            print("[commitEdit] Error: Could not find word with ID \(wordIdToCommit). Resetting state.")
            editingWordID = nil; focusedWordID = nil; editText = ""; return
        }

        let originalText = transcriptWords[wordIndex].text
        let newText = editText.trimmingCharacters(in: .whitespacesAndNewlines)

        if originalText != newText && !newText.isEmpty {
            print("[commitEdit] Updating word at index \(wordIndex): '\(originalText)' -> '\(newText)'")
            transcriptWords[wordIndex].text = newText
        } else if newText.isEmpty {
             print("[commitEdit] Edit resulted in empty text. Reverting.")
        } else { print("[commitEdit] No text change for '\(originalText)'.") }
        
        editingWordID = nil // Exit editing mode
        editText = ""
        // Don't reset focusedWordID, let system manage focus
    }

    // --- Helper to group words into lines ---
    private func groupWordsIntoLines(words: [TranscriptWord], charactersPerLine: Int) -> [[TranscriptWord]] {
        // ... (Implementation remains the same) ...
         var lines: [[TranscriptWord]] = []; var currentLine: [TranscriptWord] = []; var currentLineLength = 0
         for word in words { let wordLength = word.text.count + 1; if currentLine.isEmpty || currentLineLength + wordLength <= charactersPerLine { currentLine.append(word); currentLineLength += wordLength } else { lines.append(currentLine); currentLine = [word]; currentLineLength = wordLength } }; if !currentLine.isEmpty { lines.append(currentLine) }; return lines
    }

    // --- Helper function to seek player ---
    private func seekPlayer(to time: Float) {
        guard let player = player else { return }
        let cmTime = CMTime(seconds: Double(time), preferredTimescale: 600)
        // Seek and only play if the player wasn't already playing near that time
        let rate = player.rate
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] finished in
            guard finished, let player = player else { print("Seek cancelled or interrupted."); return }
            print("Seek finished to \(time)s")
            if rate == 0 { // Only play if it was paused
                player.play()
            }
        }
    }

    // --- Helper function to stop accessing URL ---
    private func stopAccessingURL() {
        if let url = accessedURL {
            url.stopAccessingSecurityScopedResource()
            print("Stopped accessing security scoped resource for \(url.path)")
            accessedURL = nil
        }
    }

    // --- Initialize WhisperKit ---
    func initializeWhisperKit() async { /* ... implementation ... */
         guard whisperPipe == nil && whisperKitInitError == nil else { return }
         await MainActor.run { statusMessage = "Initializing transcription engine..." }; print("Initializing WhisperKit...")
         do { let pipe = try await WhisperKit(model: "base.en", verbose: true, logLevel: .debug); await MainActor.run { self.whisperPipe = pipe; self.isWhisperKitInitialized = true; self.statusMessage = "Transcription engine ready."; print("WhisperKit initialized successfully.") }
         } catch { print("Error initializing WhisperKit: \(error)"); await MainActor.run { self.whisperKitInitError = "Failed... \(error.localizedDescription)"; self.statusMessage = self.whisperKitInitError!; self.isWhisperKitInitialized = false } }
    }

    // --- Cancel Transcription ---
     func cancelTranscription() { /* ... implementation ... */
          print("Cancellation requested."); transcriptionTask?.cancel(); Task { await MainActor.run { if isTranscribing { statusMessage = "Cancellation requested..." } } }
     }

    // --- Perform Transcription ---
    @MainActor
    func performTranscription(url: URL) async { /* ... implementation ... */
         guard isWhisperKitInitialized, let activeWhisperPipe = whisperPipe else { return }
         guard transcriptionTask != nil && !transcriptionTask!.isCancelled && !isTranscribing else { return }
         print("Starting transcription for: \(url.path)"); isTranscribing = true; transcriptionProgress = 0.0; transcriptWords = []; statusMessage = "Starting transcription: Extracting audio..."
         if Task.isCancelled { cleanupAfterTranscription(status: "Transcription cancelled."); return }
         guard let audioFrames = await extractAndConvertAudio(from: url, isCancelled: { Task.isCancelled }) else { if Task.isCancelled { cleanupAfterTranscription(status: "Audio extraction cancelled.") } else { cleanupAfterTranscription(status: "Error: Failed to extract audio.") }; return }
         if Task.isCancelled { cleanupAfterTranscription(status: "Transcription cancelled."); return }
         statusMessage = "Transcribing audio..."
         do { print("Passing \(audioFrames.count) audio frames to WhisperKit."); let decodingOptions = DecodingOptions(verbose: true, wordTimestamps: true ); let transcriptionCallback: TranscriptionCallback = { progress in Task { @MainActor in guard self.isTranscribing else { return }; self.transcriptionProgress += 0.01; if self.transcriptionProgress > 1.0 { self.transcriptionProgress = 1.0 }; self.statusMessage = "Transcribing... \(Int(self.transcriptionProgress * 100))%" }; return !Task.isCancelled }; let transcriptionResults: [TranscriptionResult] = try await activeWhisperPipe.transcribe(audioArray: audioFrames, decodeOptions: decodingOptions, callback: transcriptionCallback ); if Task.isCancelled { cleanupAfterTranscription(status: "Transcription cancelled."); return }; let mergedResult = mergeTranscriptionResults(transcriptionResults); if let finalWords = mergedResult?.allWords { self.transcriptWords = finalWords.map { TranscriptWord(text: $0.word, start: $0.start, end: $0.end) }; print("Transcription finished with \(self.transcriptWords.count) words."); self.statusMessage = "Transcription complete." } else { print("Transcription finished but produced no words/text."); self.transcriptWords = []; self.statusMessage = "Transcription complete (no text)." }; self.transcriptionProgress = 1.0; cleanupAfterTranscription(status: self.statusMessage)
         } catch is CancellationError { cleanupAfterTranscription(status: "Transcription cancelled.") }
           catch { print("WhisperKit transcription failed: \(error)"); cleanupAfterTranscription(status: "Error during transcription."); self.transcriptWords = [] }
    }

    // --- Cleanup After Transcription ---
    @MainActor
    private func cleanupAfterTranscription(status: String) { /* ... implementation ... */
         print("Cleaning up transcription task. Final Status: \(status)"); isTranscribing = false; statusMessage = status; if status != "Transcription complete." && !status.contains("no text") { transcriptionProgress = 0.0 } else { transcriptionProgress = 1.0 }; transcriptionTask = nil
    }

    // --- AVFoundation Audio Extraction Function ---
     func extractAndConvertAudio(from url: URL, isCancelled: @escaping () -> Bool) async -> [Float]? { /* ... implementation ... */
         print("Starting audio extraction for: \(url.path)"); let asset = AVURLAsset(url: url); let isPlayable = try? await asset.load(.isPlayable); let hasProtectedContent = try? await asset.load(.hasProtectedContent); print("Asset properties: isPlayable=\(isPlayable ?? false), hasProtectedContent=\(hasProtectedContent ?? false)"); if hasProtectedContent == true { print("Error: Asset has protected content."); return nil }; guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first else { print("Error: Could not load audio track from asset."); do { _ = try await asset.loadTracks(withMediaType: .audio); print("Debug: Loaded tracks successfully, but couldn't get first?") } catch { print("Error loading tracks: \(error)") }; return nil }; let duration = try? await asset.load(.duration); let totalSeconds = duration?.seconds ?? 0; print("Track duration: \(totalSeconds) seconds"); guard let reader = try? AVAssetReader(asset: asset) else { return nil }; let outputSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]; let trackOutput = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: outputSettings); guard reader.canAdd(trackOutput) else { return nil }; reader.add(trackOutput); guard reader.startReading() else { return nil }; print("AVAssetReader started reading..."); var audioFrames: [Float] = []; var bufferCount = 0; let bufferReadQueue = DispatchQueue(label: "audio-buffer-read-queue"); return await Task { var frames: [Float]? = []; bufferReadQueue.sync { while reader.status == .reading { if isCancelled() { reader.cancelReading(); frames = nil; break }; if let sampleBuffer = trackOutput.copyNextSampleBuffer() { bufferCount += 1; if let samples = self.convertSampleBuffer(sampleBuffer) { frames?.append(contentsOf: samples) }; CMSampleBufferInvalidate(sampleBuffer) } else { break } } }; if reader.status == .cancelled { return nil } else if reader.status == .failed { return nil } else if reader.status == .completed && frames != nil { print("Extraction complete. Read \(bufferCount) buffers. Total frames: \(frames!.count)"); return frames } else { return nil } }.value
     }

    // --- Convert Sample Buffer ---
    private func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> [Float]? { /* ... implementation ... */
         guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }; let length = CMBlockBufferGetDataLength(blockBuffer); guard length % MemoryLayout<Float>.stride == 0 else { return nil }; let numFloats = length / MemoryLayout<Float>.stride; var data = [Float](repeating: 0.0, count: numFloats); let status = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data); guard status == kCMBlockBufferNoErr else { return nil }; return data
    }

    // --- Merge Transcription Results ---
    private func mergeTranscriptionResults(_ results: [TranscriptionResult]) -> TranscriptionResult? { /* ... implementation ... */
         guard !results.isEmpty else { return nil }; if results.count == 1 { return results.first }; let combinedText = results.map { $0.text }.joined(separator: " "); let combinedSegments = results.flatMap { $0.segments }; let language = results.first!.language; var mergedTimings = results.first!.timings; mergedTimings.fullPipeline = results.reduce(TimeInterval(0)) { $0 + $1.timings.fullPipeline }; return TranscriptionResult(text: combinedText, segments: combinedSegments, language: language, timings: mergedTimings)
    }
    
    // --- Delete Functionality ---
    @MainActor
    private func deleteSelectedWords() {
            guard !selectedWordIDs.isEmpty else { print("[Delete] No words selected."); return }
            guard let originalURL = selectedVideoURL else { print("[Delete] No original URL."); return }
            guard let (startTime, endTime) = getTimeRangeForSelection() else { print("[Delete] Could not get time range."); return }

            let timeRangeToRemove = CMTimeRangeFromTimeToTime(start: CMTime(seconds: Double(startTime), preferredTimescale: 600),
                                                              end: CMTime(seconds: Double(endTime), preferredTimescale: 600))
            print("[Delete] Attempting to remove time range: \(CMTimeRangeShow(timeRangeToRemove))")
            statusMessage = "Processing deletion..."

            // --- Determine the asset to edit (allow cumulative edits) ---
            // Use the currently stored composition if it exists, otherwise use the original URL asset
            let baseAsset = currentComposition ?? AVURLAsset(url: originalURL)
            print("[Delete] Base asset for edit duration: \(CMTimeGetSeconds(baseAsset.duration))s")

            Task { // Perform composition asynchronously
                // --- Access Resource within Task if using original URL ---
                var didStartAccess = false
                if currentComposition == nil { // Only need to access if using original URL
                    guard originalURL.startAccessingSecurityScopedResource() else {
                         await MainActor.run { statusMessage = "Error: Could not re-access file for editing." }
                         print("[Delete Task] Failed to start access for \(originalURL.path)")
                         return
                    }
                    didStartAccess = true
                    print("[Delete Task] Started accessing resource: \(originalURL.path)")
                    defer {
                        if didStartAccess {
                            originalURL.stopAccessingSecurityScopedResource()
                            print("[Delete Task] Stopped accessing resource: \(originalURL.path)")
                        }
                    }
                }

                // --- Create Mutable Composition Correctly ---
                let composition: AVMutableComposition

                // If the baseAsset is already a composition, make a mutable copy
                if let existingComposition = baseAsset as? AVComposition {
                     print("[Delete Task] Base asset is AVComposition, creating mutable copy...")
                     guard let mutableComp = existingComposition.mutableCopy() as? AVMutableComposition else {
                          print("[Delete Task] Failed to create mutable copy from existing AVComposition.")
                          await MainActor.run { statusMessage = "Error preparing video for editing (copy failed)." }
                          return
                     }
                     composition = mutableComp
                }
                // If the baseAsset is the original AVURLAsset, create a *new* mutable composition
                // and add the tracks from the original asset.
                else if let urlAsset = baseAsset as? AVURLAsset {
                     print("[Delete Task] Base asset is AVURLAsset, creating new AVMutableComposition...")
                     composition = AVMutableComposition()
                     do {
                          // Load tracks from the original URL asset
                          guard let originalVideoTrack = try await urlAsset.loadTracks(withMediaType: .video).first,
                                let originalAudioTrack = try await urlAsset.loadTracks(withMediaType: .audio).first else {
                               throw EditError("Cannot load tracks from original AVURLAsset.")
                          }
                          let originalDuration = try await urlAsset.load(.duration)

                          // Add tracks to the new composition
                          let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                          let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

                          try compositionVideoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: originalDuration), of: originalVideoTrack, at: .zero)
                          try compositionAudioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: originalDuration), of: originalAudioTrack, at: .zero)
                          print("[Delete Task] Tracks from original AVURLAsset added to new composition.")
                     } catch {
                          print("[Delete Task] Failed to load tracks or duration from original AVURLAsset: \(error)")
                          await MainActor.run { statusMessage = "Error preparing video for editing (track loading failed)." }
                          return
                     }
                }
                // Should not happen, but handle unexpected asset types
                else {
                      print("[Delete Task] Error: Base asset is of unexpected type.")
                      await MainActor.run { statusMessage = "Error: Unexpected video format for editing." }
                      return
                }
                // --- End Create Mutable Composition ---


                // --- Now modify the 'composition' (which is guaranteed to be mutable) ---
                do {
                    let editAssetDuration = try await composition.load(.duration) // Load from the mutable comp
                    let editAssetTimeRange = CMTimeRange(start: .zero, duration: editAssetDuration)
                    print("[Delete Task] Mutable composition duration before removal: \(CMTimeGetSeconds(editAssetDuration))s")

                    guard CMTimeRangeContainsTimeRange(editAssetTimeRange, otherRange: timeRangeToRemove) else {
                        print("[Delete Task] Error: Time range invalid for asset duration.")
                        throw EditError("Selected time range is invalid.")
                    }

                    composition.removeTimeRange(timeRangeToRemove)
                    print("[Delete Task] Time range removed. New duration: \(CMTimeGetSeconds(composition.duration))s")

                    guard try await composition.load(.isPlayable) else { throw EditError("Edited composition not playable.") }
                    print("[Delete Task] Edited composition playable.")

                    let newPlayerItem = AVPlayerItem(asset: composition) // Create item from the modified composition
                    print("[Delete Task] New player item created.")

                    await MainActor.run {
                         print("[Delete MainActor] Replacing player item...")
                         player?.pause()
                         player?.replaceCurrentItem(with: newPlayerItem)
                         self.currentComposition = composition // *** Store the latest valid composition state ***

                         // Update Transcript & Selection State
                         transcriptWords.removeAll { selectedWordIDs.contains($0.id) }
                         selectedWordIDs = []
                         selectionAnchorID = nil
                         print("[Delete MainActor] Transcript state updated.")

                        // Check status & play after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            guard let currentItem = self.player?.currentItem else { return }
                            print("[Delete MainActor Post-Delay] New item status: \(currentItem.status.rawValue)")
                            if currentItem.status == .readyToPlay { self.player?.play(); self.statusMessage = "Selection deleted." }
                            else if currentItem.status == .failed { self.statusMessage = "Error playing edited video: \(currentItem.error?.localizedDescription ?? "unknown")" }
                            else { self.statusMessage = "Edited video loaded..." }
                        }
                    } // End MainActor.run

                } catch {
                     print("[Delete Task] Error during AVComposition editing: \(error)")
                     let errorMessage = (error as? EditError)?.message ?? error.localizedDescription
                     await MainActor.run { statusMessage = "Error during editing: \(errorMessage)" }
                }
            } // End Task
        }

    // Helper struct for custom errors during editing
    struct EditError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // --- Get Time Range For Selection ---
    private func getTimeRangeForSelection() -> (start: Float, end: Float)? {
        // ... (Implementation remains the same) ...
         guard !selectedWordIDs.isEmpty else { return nil }; let selectedWords = transcriptWords.filter { selectedWordIDs.contains($0.id) }; guard !selectedWords.isEmpty else { return nil }; let startTime = selectedWords.min(by: { $0.start < $1.start })?.start ?? 0.0; let endTime = selectedWords.max(by: { $0.end < $1.end })?.end ?? startTime; return (startTime, endTime)
    }
} //End ContentView

#Preview {
    ContentView()
}
