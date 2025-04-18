import SwiftUI
import AVKit // Player
import WhisperKit // Transcription
import CoreML // ML models
import AppKit // For NSEvent (Shift key)
import Combine // For Timer publisher (export progress)

// MARK: - Data Structures

struct TranscriptWord: Identifiable, Hashable {
    let id = UUID()
    var text: String // Mutable for editing
    let start: Float
    let end: Float
}

// Custom error for editing operations
struct EditError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Main Content View

@MainActor // Ensures UI updates happen on main thread by default
struct ContentView: View {

    // MARK: - State Variables

    // File & Player State
    @State private var selectedVideoURL: URL?
    @State private var player: AVPlayer?
    @State private var accessedURL: URL?
    @State private var currentEditedAsset: AVAsset? = nil // Holds the latest edited state (AVURLAsset or AVComposition)

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

    // Export State
    @State private var showingExportProgress = false
    @State private var exportProgressValue: Double = 0.0
    @State private var showingSavePanel = false
    @State private var exportError: String? = nil
    @State private var exportProgressTimer: AnyCancellable? // Timer for export progress polling

    // MARK: - Body

    var body: some View {
        HSplitView {
            playerAndControlsView
            transcriptEditorView
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.movie, .video, .audio], allowsMultipleSelection: false, onCompletion: handleFileSelection)
        .navigationTitle("ScriptClip")
        .frame(minWidth: 700, minHeight: 450)
        .task { await initializeWhisperKit() }
        .onDisappear { cancelTranscription(); stopAccessingURL(); commitEdit() }
        .sheet(isPresented: $showingSavePanel) { exportStatusView }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectionNotification)) { _ in
             if !selectedWordIDs.isEmpty && player?.currentItem != nil { deleteSelectedWords() }
        }
    }

    // MARK: - UI Components

    private var playerAndControlsView: some View {
        VStack {
            if let player = player {
                 VideoPlayer(player: player)
                    .frame(minHeight: 200, maxHeight: .infinity) // Allow vertical expansion
                    .frame(maxWidth: .infinity)
            } else {
                 videoPlaceholderView
            }
            transcriptionProgressView
            editControlsView
            statusMessageView
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoPlaceholderView: some View {
        ZStack {
             Rectangle().fill(.black).frame(minHeight: 200)
             Text(selectedVideoURL == nil ? "Select a video file" : "Loading video...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var transcriptionProgressView: some View {
        HStack {
             Button { showingFileImporter = true } label: { Label("Select Video", systemImage: "video.fill") }
             Spacer()
             if isTranscribing {
                 ProgressView(value: transcriptionProgress).frame(width: 100)
                 Text("\(Int(transcriptionProgress * 100))%")
                 Button("Cancel", role: .destructive) { cancelTranscription() }
             }
        }.padding([.horizontal, .bottom]).frame(height: 25)
    }

    private var editControlsView: some View {
        HStack {
             Button(role: .destructive) { deleteSelectedWords() } label: { Label("Delete Selection", systemImage: "trash") }
            .disabled(selectedWordIDs.isEmpty || player?.currentItem == nil)
             Button { exportVideo() } label: { Label("Export Video", systemImage: "square.and.arrow.up") }
            .disabled(player?.currentItem == nil)
             Spacer()
        }.padding(.horizontal).frame(height: 25)
    }

    private var statusMessageView: some View {
         Text(statusMessage).font(.caption).foregroundColor(.secondary).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).id(statusMessage)
    }

    private var transcriptEditorView: some View {
        VStack(alignment: .leading) {
             Text("Transcript:").font(.headline).padding(.top).padding(.horizontal)
             ScrollView {
                 LazyVStack(alignment: .leading, spacing: 2) {
                     if transcriptWords.isEmpty && !isTranscribing && selectedVideoURL != nil { Text("Transcript will appear here.").foregroundColor(.secondary).padding() }
                     else if isTranscribing && transcriptWords.isEmpty { Text("Transcription in progress...").foregroundColor(.secondary).padding() }
                     else { displayTranscriptWords() }
                 }.padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading)
             }.frame(minWidth: 250, minHeight: 200).border(Color.gray.opacity(0.5)).padding([.horizontal, .bottom])
        }.frame(minWidth: 300)
    }

    @ViewBuilder private func displayTranscriptWords() -> some View {
        let lines = groupWordsIntoLines(words: transcriptWords, charactersPerLine: 60)
        ForEach(lines.indices, id: \.self) { lineIndex in
             HStack(alignment: .firstTextBaseline, spacing: 4) {
                 ForEach(lines[lineIndex]) { wordData in
                     if let wordIndex = transcriptWords.firstIndex(where: { $0.id == wordData.id }) {
                         WordView(word: $transcriptWords[wordIndex], selectedWordIDs: $selectedWordIDs, editingWordID: $editingWordID, editText: $editText, focusedWordID: $focusedWordID, onTap: handleTap, onBeginEdit: beginEditing, onCommitEdit: commitEdit)
                     } else { EmptyView() }
                 }
             }
        }
    }

    private var exportStatusView: some View {
        VStack {
             if showingExportProgress { ProgressView("Exporting...", value: exportProgressValue, total: 1.0).progressViewStyle(.linear).padding().frame(width: 250) }
             else if let error = exportError { Text("Export Error").font(.headline).padding(.bottom, 2); Text(error).foregroundColor(.red).padding(); Button("Dismiss") { showingSavePanel = false } }
             else { Text("Export Complete!").font(.headline).padding(); Button("Done") { showingSavePanel = false } }
        }.padding().frame(minWidth: 300, minHeight: 100)
    }

    // MARK: - File Handling & Security Scope

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        stopAccessingURL(); currentEditedAsset = nil; player?.replaceCurrentItem(with: nil); player = nil; transcriptWords = []; selectedWordIDs = []; selectionAnchorID = nil
        switch result {
        case .success(let urls):
             guard let url = urls.first, url.startAccessingSecurityScopedResource() else { updateStatus("Error accessing file."); selectedVideoURL = nil; accessedURL = nil; return }
             accessedURL = url; selectedVideoURL = url; print("Started access: \(url.path)")
             let asset = AVURLAsset(url: url); currentEditedAsset = asset // Start with original
             player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
             updateStatus("Video loaded. Transcribing...")
             triggerAutoTranscription(url: url)
        case .failure(let error): print("File selection error: \(error)"); updateStatus("Error loading video."); selectedVideoURL = nil; accessedURL = nil
        }
    }

    private func stopAccessingURL() { accessedURL?.stopAccessingSecurityScopedResource(); if accessedURL != nil { print("Stopped access.") }; accessedURL = nil }

    // MARK: - Transcription Logic

    private func triggerAutoTranscription(url: URL) { /* ... same as before ... */ if isWhisperKitInitialized && whisperKitInitError == nil { cancelTranscription(); transcriptionTask = Task { await performTranscription(url: url) } } else { updateStatus("Engine not ready.") } }
    func initializeWhisperKit() async { /* ... same as before ... */ guard whisperPipe == nil && whisperKitInitError == nil else { return }; await updateStatus("Initializing..."); print("Initializing..."); do { let p = try await WhisperKit(model: "base.en", verbose: true, logLevel: .debug); await updateWhisperKitState(pipe: p, error: nil) } catch { print("WhisperKit init error: \(error)"); await updateWhisperKitState(pipe: nil, error: error) } }
    func cancelTranscription() { /* ... same as before ... */ print("Cancel requested."); transcriptionTask?.cancel(); if isTranscribing { Task { await cleanupAfterTranscription(status: "Cancelled.") } } }

    @MainActor func performTranscription(url: URL) async { /* ... implementation largely same, ensure await/try used correctly ... */
         guard isWhisperKitInitialized, let pipe = whisperPipe else { updateStatus("Engine not ready."); isTranscribing = false; return }
         guard !isTranscribing else { print("Already transcribing."); return }
         print("Transcription start: \(url.path)"); isTranscribing = true; transcriptionProgress = 0.0; transcriptWords = []; updateStatus("Extracting audio...")
         guard let frames = await Self.extractAndConvertAudio(from: url, isCancelled: { Task.isCancelled }) else { cleanupAfterTranscription(status: Task.isCancelled ? "Cancelled." : "Error: Audio extraction failed."); return }
         _ = frames.count
         if Task.isCancelled { cleanupAfterTranscription(status: "Cancelled."); return }
         updateStatus("Transcribing...")
         do { let opts = DecodingOptions(verbose: true, wordTimestamps: true); let cb: TranscriptionCallback = { _ in Task { @MainActor in guard self.isTranscribing else { return }; let p = self.transcriptionProgress + 0.01; self.transcriptionProgress = min(p, 0.95); self.updateStatus("Transcribing... \(Int(p * 100))%") }; return !Task.isCancelled }; let results = try await pipe.transcribe(audioArray: frames, decodeOptions: opts, callback: cb); if Task.isCancelled { cleanupAfterTranscription(status: "Cancelled."); return }; let merged = mergeTranscriptionResults(results); if let words = merged?.allWords { self.transcriptWords = words.map { TranscriptWord(text: $0.word, start: $0.start, end: $0.end) }; print("Transcription ok (\(words.count) words).") } else { self.transcriptWords = []; print("Transcription ok (no words).") }; cleanupAfterTranscription(status: "Complete.")
         } catch is CancellationError { print("Transcription cancelled."); cleanupAfterTranscription(status: "Cancelled.") }
           catch { print("Transcription failed: \(error)"); cleanupAfterTranscription(status: "Error."); self.transcriptWords = [] }
    }
    @MainActor private func cleanupAfterTranscription(status: String) { /* ... same as before ... */ print("Cleanup. Status: \(status)"); if status.starts(with: "Complete") { transcriptionProgress = 1.0 } else { transcriptionProgress = 0.0 }; isTranscribing = false; updateStatus(status); transcriptionTask = nil }
    @MainActor private func updateWhisperKitState(pipe: WhisperKit?, error: Error?) { /* Helper to update WhisperKit state */
         self.whisperPipe = pipe
         self.isWhisperKitInitialized = (pipe != nil)
         if let error = error { self.whisperKitInitError = "Failed init: \(error.localizedDescription)"; self.statusMessage = self.whisperKitInitError! }
         else { self.whisperKitInitError = nil; self.statusMessage = "Engine ready." }
    }

    // MARK: - AVFoundation Logic

    static func extractAndConvertAudio(from url: URL, isCancelled: @escaping () -> Bool) async -> [Float]? { /* ... same as before, ensure all loads awaited ... */
         print("[Audio Extract] Start: \(url.path)"); let asset = AVURLAsset(url: url)
         do {
             async let isPlayable = try asset.load(.isPlayable); async let hasProtectedContent = try asset.load(.hasProtectedContent); async let tracks = try asset.loadTracks(withMediaType: .audio); async let durationResult = try asset.load(.duration)
             guard try await isPlayable else { throw EditError("Asset not playable.") }; if try await hasProtectedContent { throw EditError("Asset protected.") }; guard let assetTrack = try await tracks.first else { throw EditError("No audio track.") }; let trackDuration = try await durationResult; print("[Audio Extract] Duration: \(trackDuration.seconds) seconds")
             guard let reader = try? AVAssetReader(asset: asset) else { throw EditError("Cannot create reader.") }; let outputSettings: [String: Any] = [ AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false ]; let trackOutput = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: outputSettings); guard reader.canAdd(trackOutput) else { throw EditError("Cannot add track output.") }; reader.add(trackOutput); guard reader.startReading() else { throw EditError("Cannot start reading: \(reader.error?.localizedDescription ?? "?")") }; print("[Audio Extract] Reader started...")
             return try await Task.detached(priority: .userInitiated) {
                 var frames: [Float] = []; var bufferCount = 0; var readError: Error? = nil; var cancelled = false; let queue = DispatchQueue(label: "audio-read", qos: .userInitiated)
                 queue.sync { while reader.status == .reading { if isCancelled() { reader.cancelReading(); cancelled = true; break }; guard let sBuf = trackOutput.copyNextSampleBuffer() else { break }; bufferCount += 1; if let samps = ContentView.convertSampleBuffer(sBuf) { frames.append(contentsOf: samps) } else { readError = EditError("Buffer conversion failed."); reader.cancelReading(); break }; CMSampleBufferInvalidate(sBuf) }; if reader.status == .failed { readError = reader.error } }
                 if cancelled { throw CancellationError() }; if let error = readError { throw error }; guard reader.status == .completed else { throw EditError("Reader status: \(reader.status.rawValue)") }; print("[Audio Extract Task] Complete (\(bufferCount) buffers, \(frames.count) frames)."); return frames
             }.value
         } catch is CancellationError { print("[Audio Extract] Cancelled."); return nil }
           catch { print("[Audio Extract] Failed: \(error.localizedDescription)"); return nil }
     }
    static private func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> [Float]? { /* ... same as before ... */ guard let b = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }; let l = CMBlockBufferGetDataLength(b); guard l > 0, l % MemoryLayout<Float>.stride == 0 else { return nil }; let n = l / MemoryLayout<Float>.stride; var d = [Float](repeating: 0, count: n); let s = CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: l, destination: &d); guard s == kCMBlockBufferNoErr else { print("Err copying: \(s)"); return nil }; return d }

    // MARK: - Editing Logic

    @MainActor
        private func deleteSelectedWords() {
            guard !selectedWordIDs.isEmpty else { print("[Delete] No words selected."); return }
            // Use currentEditedAsset if available, otherwise the original URL Asset
            guard let assetToEdit = self.currentEditedAsset ?? selectedVideoURL.map(AVURLAsset.init) else {
                print("[Delete] No asset available (original URL or edited asset)."); return
            }
            guard let (startTime, endTime) = getTimeRangeForSelection() else { print("[Delete] Could not get time range."); return }
            let maybeOriginalURL = (assetToEdit is AVURLAsset) ? selectedVideoURL : nil // Needed only if accessing original

            let timeRangeToRemove = CMTimeRangeFromTimeToTime(start: CMTime(seconds: Double(startTime), preferredTimescale: 600), end: CMTime(seconds: Double(endTime), preferredTimescale: 600))
            print("[Delete] Removing range: \(CMTimeRangeShow(timeRangeToRemove)) from \(type(of: assetToEdit))")
            updateStatus("Processing deletion...")

            Task.detached(priority: .userInitiated) {
                var accessStarted = false
                let originalURL = maybeOriginalURL // Capture for use within Task if needed

                do {
                    // --- Resource Access ---
                     if let url = originalURL { // Only access if base asset is AVURLAsset
                         guard url.startAccessingSecurityScopedResource() else { throw EditError("Cannot access file.") }
                         accessStarted = true; print("[Delete Task] Started access.")
                         // Defer removed, stop explicitly
                     }

                    // --- Create Mutable Composition ---
                     print("[Delete Task] Preparing composition...")
                     let composition: AVMutableComposition // Declare the variable

                     // --- FIX: Check type *before* calling mutableCopy ---
                     if let existingComposition = assetToEdit as? AVComposition {
                         print("[Delete Task] Base is AVComposition. Creating mutable copy...")
                         guard let mutableComp = existingComposition.mutableCopy() as? AVMutableComposition else {
                             throw EditError("Failed to create mutable copy from AVComposition.")
                         }
                         composition = mutableComp
                     }
                     else if let urlAsset = assetToEdit as? AVURLAsset {
                         print("[Delete Task] Base is AVURLAsset. Building new composition...")
                         composition = AVMutableComposition() // Create new empty one
                         // Load tracks/duration from original asset and add to new composition
                         async let videoTrack = urlAsset.loadTracks(withMediaType: .video).first
                         async let audioTrack = urlAsset.loadTracks(withMediaType: .audio).first
                         async let duration = urlAsset.load(.duration)

                         guard let originalVideoTrack = try await videoTrack,
                               let originalAudioTrack = try await audioTrack else {
                             throw EditError("Cannot load tracks from original file.")
                         }
                         let originalDuration = try await duration

                         let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                         let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                         try compVideoTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: originalDuration), of: originalVideoTrack, at: .zero)
                         try compAudioTrack?.insertTimeRange(CMTimeRange(start: .zero, duration: originalDuration), of: originalAudioTrack, at: .zero)
                         print("[Delete Task] New composition populated from AVURLAsset.")
                     }
                     else {
                          // This case should ideally not be reachable if baseAsset is determined correctly
                          throw EditError("Unsupported asset type for editing.")
                     }
                     // --- End Create Mutable Composition ---

                    // --- Modify Composition ---
                     let duration = try await composition.load(.duration)
                     let editRange = CMTimeRange(start: .zero, duration: duration)
                     print("[Delete Task] Duration before removal: \(CMTimeGetSeconds(duration))s")
                     guard CMTimeRangeContainsTimeRange(editRange, otherRange: timeRangeToRemove) else { throw EditError("Time range invalid.") }
                     composition.removeTimeRange(timeRangeToRemove)
                     print("[Delete Task] Range removed. New duration: \(CMTimeGetSeconds(composition.duration))s")
                     guard try await composition.load(.isPlayable) else { throw EditError("Result not playable.") }
                     print("[Delete Task] Result playable.")
                     // --- End Modify ---

                    // --- Create Immutable Copy & PlayerItem ---
                     guard let immutableAsset = composition.copy() as? AVAsset else { throw EditError("Failed copy.") }
                     print("[Delete Task] Created immutable copy.")
                     let newPlayerItem = await AVPlayerItem(asset: immutableAsset)
                     print("[Delete Task] Player item created.")

                    // --- Stop access ---
                     if accessStarted, let url = originalURL { url.stopAccessingSecurityScopedResource(); print("[Delete Task] Stopped access.") }

                     // --- Update Main Actor ---
                     // Pass back the immutable asset which is the result of this edit
                     await updatePlayerAndState(with: newPlayerItem, resultingAsset: immutableAsset)

                } catch { // Catch all errors
                     print("[Delete Task] Error: \(error)")
                     if accessStarted, let url = originalURL { url.stopAccessingSecurityScopedResource(); print("[Delete Task] Stopped access after error.") }
                     let msg = (error as? EditError)?.message ?? error.localizedDescription
                     await updateStatus("Error editing: \(msg)")
                }
            } // End Task
        }

    @MainActor private func updatePlayerAndState(with newItem: AVPlayerItem, resultingAsset: AVAsset) { /* ... same as before ... */
         print("[MainActor Update] Replacing player item..."); player?.pause(); self.currentEditedAsset = resultingAsset; player?.replaceCurrentItem(with: newItem); print("[MainActor Update] Stored updated 'currentEditedAsset'."); transcriptWords.removeAll { selectedWordIDs.contains($0.id) }; selectedWordIDs = []; selectionAnchorID = nil; print("[MainActor Update] Transcript state updated."); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { guard let item = self.player?.currentItem else { return }; print("[MainActor Update Post-Delay] Item status: \(item.status.rawValue)"); if item.status == .readyToPlay { self.player?.play(); self.updateStatus("Selection deleted.") } else { self.updateStatus("Error playing edited video: \(item.error?.localizedDescription ?? "?")") } }
    }
    @MainActor private func updateStatus(_ message: String) { self.statusMessage = message }
    private func getTimeRangeForSelection() -> (start: Float, end: Float)? { /* ... same as before ... */ guard !selectedWordIDs.isEmpty else { return nil }; let words = transcriptWords.filter { selectedWordIDs.contains($0.id) }; guard !words.isEmpty else { return nil }; let start = words.min { $0.start < $1.start }?.start ?? 0; let end = words.max { $0.end < $1.end }?.end ?? start; return (start, end) }

    // MARK: - Export Logic

    private func exportVideo() { /* ... same as before ... */ guard let assetToExport = player?.currentItem?.asset else { updateStatus("No video loaded."); return }; exportError = nil; showingSavePanel = true; showingExportProgress = true; exportProgressValue = 0.0; updateStatus("Preparing export..."); DispatchQueue.main.async { let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = (selectedVideoURL?.deletingPathExtension().lastPathComponent ?? "exported") + "_edited.mp4"; panel.begin { response in if response == .OK, let url = panel.url { print("Export URL: \(url.path)"); Task { await self.runExportSession(asset: assetToExport, outputURL: url) } } else { print("Save cancelled."); Task { await MainActor.run { self.showingSavePanel = false; self.showingExportProgress = false; self.updateStatus("Export cancelled.") } } } } } }

    private func runExportSession(asset: AVAsset, outputURL: URL) async {
        await updateStatus("Exporting video...")
        do {
             // --- FIX: Use await for presets ---
             let presets = await AVAssetExportSession.exportPresets(compatibleWith: asset)
             let preset = presets.contains(AVAssetExportPresetHEVCHighestQuality) ? AVAssetExportPresetHEVCHighestQuality : presets.contains(AVAssetExportPresetHighestQuality) ? AVAssetExportPresetHighestQuality : AVAssetExportPreset1920x1080
             print("Using export preset: \(preset)")
             guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw EditError("Failed export session init.") }
             session.outputURL = outputURL; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true

             print("Starting async export...")
             // --- FIX: Use polling, await export ---
             async let exportTask: Void = session.export()
             async let progressTask: Void = pollExportProgress(session: session)
             _ = try await (exportTask, progressTask) // Await both

             print("Export completed.")
             await updateExportState(progress: 1.0, error: nil, message: "Export complete!")
        } catch is CancellationError { print("Export cancelled."); await updateExportState(error: "Export cancelled.", message: "Export cancelled.", closeSheet: true) }
          catch { print("Export failed: \(error)"); await updateExportState(error: error.localizedDescription, message: "Export Failed.") }
    }

    private func pollExportProgress(session: AVAssetExportSession) async { // Poll progress instead of using progressUpdates
        print("Polling export progress...")
        while session.status == .exporting || session.status == .waiting {
             let currentProgress = Double(session.progress)
             await MainActor.run { if abs(self.exportProgressValue - currentProgress) > 0.01 || currentProgress == 0.0 { self.exportProgressValue = currentProgress; print(String(format: "Export progress: %.0f%%", currentProgress * 100)) } }
             if Task.isCancelled { break }; try? await Task.sleep(for: .milliseconds(250))
        }
        await MainActor.run { self.exportProgressValue = Double(session.progress) }; print("Progress polling finished: \(session.status.rawValue)")
    }

    @MainActor private func updateExportState(progress: Double? = nil, error: String? = nil, message: String, closeSheet: Bool = false) { /* ... same as before ... */ if let p = progress { exportProgressValue = p }; exportError = error; updateStatus(message); showingExportProgress = false; if closeSheet { showingSavePanel = false } }

    // MARK: - Text Editing & Selection

    private func seekPlayer(to time: Float) { /* ... same as before, ensure Task dispatch if needed ... */ guard let player = player else { return }; let cmTime = CMTime(seconds: Double(time), preferredTimescale: 600); let rate = player.rate; player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in guard finished else { print("Seek cancelled."); return }; print("Seek finished to \(time)s"); Task { @MainActor in if rate == 0 { self.player?.play() } } } }
    private func handleTap(on word: TranscriptWord) { /* ... same as before ... */ if editingWordID != nil { commitEdit() }; guard editingWordID == nil else { return }; let shift = NSEvent.modifierFlags.contains(.shift); if shift, let anchorId = selectionAnchorID, let anchorIdx = transcriptWords.firstIndex(where: { $0.id == anchorId }), let currentIdx = transcriptWords.firstIndex(where: { $0.id == word.id }) { let start = min(anchorIdx, currentIdx); let end = max(anchorIdx, currentIdx); let newSel = Set(transcriptWords[start...end].map { $0.id }); if selectedWordIDs != newSel { selectedWordIDs = newSel } } else { if selectedWordIDs != [word.id] { seekPlayer(to: word.start) } else { seekPlayer(to: word.start) }; selectedWordIDs = [word.id]; selectionAnchorID = word.id } }
    private func beginEditing(word: TranscriptWord) { /* ... same as before ... */ if editingWordID != nil && editingWordID != word.id { commitEdit() }; guard editingWordID != word.id else { return }; print("[beginEditing] Word: \(word.text)"); editText = word.text; editingWordID = word.id; selectedWordIDs = []; selectionAnchorID = nil; DispatchQueue.main.async { self.focusedWordID = word.id } }
    private func commitEdit() { /* ... same as before ... */ guard let wordId = editingWordID else { return }; print("[commitEdit] ID \(wordId)"); defer { editingWordID = nil; editText = "" }; guard let idx = transcriptWords.firstIndex(where: { $0.id == wordId }) else { return }; let orig = transcriptWords[idx].text; let new = editText.trimmingCharacters(in: .whitespacesAndNewlines); if orig != new && !new.isEmpty { transcriptWords[idx].text = new } }

    // MARK: - Helpers

    private func groupWordsIntoLines(words: [TranscriptWord], charactersPerLine: Int) -> [[TranscriptWord]] { /* ... same as before ... */ var l: [[TranscriptWord]] = []; var cL: [TranscriptWord] = []; var cLen = 0; for w in words { let len = w.text.count + 1; if cL.isEmpty || cLen + len <= charactersPerLine { cL.append(w); cLen += len } else { l.append(cL); cL = [w]; cLen = len } }; if !cL.isEmpty { l.append(cL) }; return l }
    private func mergeTranscriptionResults(_ results: [TranscriptionResult]) -> TranscriptionResult? { /* ... same as before ... */ guard !results.isEmpty else { return nil }; if results.count == 1 { return results.first }; let txt = results.map { $0.text }.joined(separator: " "); let segs = results.flatMap { $0.segments }; let lang = results.first!.language; var tmg = results.first!.timings; tmg.fullPipeline = results.reduce(0) { $0 + $1.timings.fullPipeline }; return TranscriptionResult(text: txt, segments: segs, language: lang, timings: tmg) }

} // End ContentView


// MARK: - Preview
#Preview { ContentView() }

// MARK: - Helper View: WordView
struct WordView: View { /* ... same as before ... */
    @Binding var word: TranscriptWord; @Binding var selectedWordIDs: Set<UUID>; @Binding var editingWordID: UUID?; @Binding var editText: String; @FocusState.Binding var focusedWordID: UUID?; let onTap: (TranscriptWord) -> Void; let onBeginEdit: (TranscriptWord) -> Void; let onCommitEdit: () -> Void
    var body: some View { Group { if editingWordID == word.id { TextField("Edit", text: $editText).textFieldStyle(.plain).font(.system(.body)).padding(.vertical, 1).padding(.horizontal, 2).fixedSize().focused($focusedWordID, equals: word.id).onSubmit(onCommitEdit).onChange(of: focusedWordID) { if focusedWordID != word.id && editingWordID == word.id { onCommitEdit() } } } else { Text(word.text).padding(.vertical, 1).padding(.horizontal, 2).background(selectedWordIDs.contains(word.id) ? Color.yellow.opacity(0.5) : Color.clear).cornerRadius(3).onTapGesture(count: 2) { onBeginEdit(word) }.onTapGesture(count: 1) { onTap(word) } } } }
} // End WordView
