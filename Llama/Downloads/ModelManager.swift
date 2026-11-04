import Foundation
import os.log

/// Represents the current status of a model
enum ModelStatus: Equatable {
  case available
  case downloading(Progress)
  /// Partial files exist on disk but no transfer is active.
  /// `bytesOnDisk` is the size of the server's partial files for the model's
  /// repo; `totalBytes` is the resolved-from-HF full size on the `Model` entry.
  case paused(bytesOnDisk: Int64, totalBytes: Int64)
  case installed
}

/// Manages the high-level state of available and downloaded models.
@MainActor
class ModelManager {
  static let shared = ModelManager()

  var downloadedModels: [Model] = []

  /// Resolved file paths for each downloaded model, keyed by model ID.
  /// Populated during refreshDownloadedModels(). Used for models.ini generation,
  /// deletion, and determining whether a model still needs downloading.
  var resolvedPaths: [String: ResolvedPaths] = [:]

  /// Returns a sorted list of all models that are either installed, currently
  /// downloading, or paused (have a leftover placeholder from a previous
  /// session). This is the primary list shown in the "Installed" section of
  /// the menu.
  var managedModels: [Model] {
    (downloadedModels + downloadingModels + pausedModels)
      .sorted(by: Model.displayOrder(_:_:))
  }

  var downloadingModels: [Model] {
    activeDownloads.values.map { $0.model }
  }

  /// Entries with partial bytes on disk but no in-flight transfer.
  /// `apply(_:)` excludes ids that are installed or actively downloading at
  /// refresh time.
  var pausedModels: [Model] {
    pausedDownloads.values.map(\.model)
  }

  var activeDownloads: [String: ActiveDownload] = [:]

  /// Model id → paused-download state (bytes on disk + the `Model` the row
  /// will render from). Sources: `pauseModelDownload` (manually paused this
  /// session), a stop requested by another client, and the failure paths.
  /// Carrying the entry here means paused deeplinks survive teardown without a
  /// separate placeholder registry.
  /// Rehydrated across restarts from the on-disk `.model.json` placeholder each
  /// download writes (see `persistPlaceholder` / `HFCache.scanPlaceholders`), so
  /// an interrupted download reappears as a paused row rather than vanishing.
  var pausedDownloads: [String: PausedDownload] = [:]

  private let serverAPI = LlamaServerAPI()

  /// Reads the server's `/models/sse` feed into `activeDownloads`. Nil while
  /// not connected.
  private var downloadEvents: Task<Void, Never>?

  let logger = Logger(subsystem: Logging.subsystem, category: "ModelManager")

  /// Minimum interval between progress notifications, to prevent excessive UI
  /// refreshes. The per-download timestamp lives on the `ActiveDownload` entry.
  let notificationThrottleInterval: TimeInterval = 0.1

  /// Downloads a model through llama-server (router mode): the server pulls the
  /// files into the HF cache and reports progress on `/models/sse`, the feed
  /// the Chat web UI follows too -- so a download started here shows there.
  func downloadModel(_ model: Model) throws {
    // Prevent duplicate downloads if user clicks download multiple times or if called from multiple code paths.
    if activeDownloads[model.id] != nil {
      logger.info("Download already in progress for model: \(model.displayName)")
      return
    }

    // Transition paused → downloading. The partial bytes stay on disk for the
    // server to resume from; the count is kept to pre-seed the Progress below,
    // so the row doesn't flash 0% until the first progress event arrives.
    let resumedBytes = pausedDownloads.removeValue(forKey: model.id)?.bytesOnDisk ?? 0

    // Already installed.
    guard resolvedPaths[model.id] == nil else { return }
    try validateCompatibility(for: model)
    try validateDiskSpace(for: model, remainingBytes: model.fileSize)

    logger.info("Starting download for model: \(model.displayName)")

    // Persist a placeholder so an interrupted download (app quit/crash/update
    // mid-transfer) reappears as a paused row on next launch instead of
    // silently vanishing. The partial bytes already survive; this just keeps
    // the `Model` needed to render and resume the row without a network resolve.
    persistPlaceholder(for: model)

    // Add the entry immediately so the model appears as "downloading" before
    // the server answers.
    let modelId = model.id
    let totalUnitCount = max(model.fileSize, 1)
    let progress = Progress(totalUnitCount: totalUnitCount)
    progress.completedUnitCount = min(resumedBytes, totalUnitCount)
    activeDownloads[modelId] = ActiveDownload(model: model, progress: progress)
    postDownloadsDidChange()

    // The sidecars the app picked for this model, by kind -- the server picks
    // the files themselves, the way `-hf` does.
    let sidecars =
      (model.mmprojUrl != nil ? ["mmproj"] : [])
      + (model.draftUrl != nil ? model.draftHead.map { [$0.rawValue] } ?? [] : [])
    // The stream is opened first so no early event is missed.
    Task {
      do {
        try await self.connectDownloadEvents()
      } catch {
        self.failDownload(
          model: model, reason: "Couldn't reach the llama server to start the download.")
        return
      }
      // Cancelled while the stream was connecting.
      guard self.activeDownloads[modelId] != nil else { return }
      if let error = await self.serverAPI.downloadModel(id: modelId, sidecars: sidecars) {
        self.failDownload(model: model, reason: error)
      }
    }
  }

  private func connectDownloadEvents() async throws {
    if downloadEvents != nil { return }
    let bytes = try await serverAPI.modelEvents()
    // Another download connected while this one was waiting.
    if downloadEvents != nil {
      bytes.task.cancel()
      return
    }
    downloadEvents = Task { [weak self] in
      do {
        for try await line in bytes.lines {
          self?.handleDownloadEvent(line)
        }
      } catch {}
      guard let self else { return }
      self.downloadEvents = nil
      // The server went away (restart, crash) and its downloads with it, so
      // nothing more will be heard about them: show them as paused.
      for id in Array(self.activeDownloads.keys) {
        self.tearDownActiveDownload(modelId: id, outcome: .pause)
      }
    }
  }

  /// Applies one `/models/sse` event to the download it names, if this app is
  /// tracking it.
  private func handleDownloadEvent(_ line: String) {
    guard line.hasPrefix("data:"),
      let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))
        as? [String: Any],
      let event = json["event"] as? String,
      let modelId = json["model"] as? String,
      let download = activeDownloads[modelId]
    else { return }
    let data = json["data"] as? [String: Any]

    switch event {
    case "download_progress":
      // One entry per file: { <url>: { done, total } }.
      let files = (data?["progress"] as? [String: [String: Any]] ?? [:]).values
      let done = files.reduce(Int64(0)) { $0 + (($1["done"] as? NSNumber)?.int64Value ?? 0) }
      let total = files.reduce(Int64(0)) { $0 + (($1["total"] as? NSNumber)?.int64Value ?? 0) }
      activeDownloads[modelId]?.refreshProgress(bytes: done, expectedBytes: total)
      if Date().timeIntervalSince(download.lastNotified) >= notificationThrottleInterval {
        activeDownloads[modelId]?.lastNotified = Date()
        postDownloadsDidChange()
      }
    case "download_finished":
      logger.info("Server finished downloading model: \(download.model.displayName)")
      activeDownloads.removeValue(forKey: modelId)
      HFCache.removePartials(cacheDir: UserSettings.hfCacheDirectory, modelId: modelId)
      // Optimistically mark the model installed before the async cache re-scan
      // lands. Without this, the model is neither downloading nor installed for
      // a beat, so its row hops back to the catalog list and then reappears.
      if !downloadedModels.contains(where: { $0.id == modelId }) {
        downloadedModels.append(download.model)
        downloadedModels.sort(by: Model.displayOrder(_:_:))
      }
      refreshDownloadedModels()
      // Let the menu bar flag the finished download on its icon, in case the
      // user walked away during a long download and isn't watching the menu.
      NotificationCenter.default.post(name: .LBModelDownloadDidComplete, object: nil)
      postDownloadsDidChange()
    case "download_failed":
      // A stop some client asked for (pause/cancel, e.g. from the web UI) is
      // not an error. Older servers don't say, and read as a failure.
      if data?["stopped"] as? Bool == true {
        tearDownActiveDownload(modelId: modelId, outcome: .pause)
      } else {
        failDownload(
          model: download.model,
          reason: "The llama server couldn't download the model. Its log has the details.")
      }
    default:
      break
    }
  }

  /// Writes the model's placeholder JSON into its partial dir so the paused row
  /// can be rebuilt at launch. Best-effort: a failure only means the download
  /// won't reappear after a restart (re-clicking still resumes), so it's logged,
  /// not surfaced. The placeholder dies with the partial dir on completion/cancel.
  private func persistPlaceholder(for model: Model) {
    let url = HFCache.placeholderURL(cacheDir: UserSettings.hfCacheDirectory, modelId: model.id)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(model).write(to: url, options: .atomic)
    } catch {
      logger.error(
        "Failed to write download placeholder for \(model.displayName): \(error.localizedDescription)"
      )
    }
  }

  /// Gets the current status of a model.
  func status(for model: Model) -> ModelStatus {
    if downloadedModels.contains(where: { $0.id == model.id }) {
      return .installed
    }
    if let download = activeDownloads[model.id] {
      return .downloading(download.progress)
    }
    if let paused = pausedDownloads[model.id] {
      return .paused(bytesOnDisk: paused.bytesOnDisk, totalBytes: model.fileSize)
    }
    return .available
  }

  /// Current transfer rate for an in-flight download, in bytes/sec.
  /// Nil when the model isn't actively downloading or the rate window hasn't
  /// filled yet (see `ActiveDownload.bytesPerSecond`).
  func downloadRate(for model: Model) -> Int64? {
    activeDownloads[model.id]?.bytesPerSecond
  }

  /// Safely deletes a downloaded model and its associated files.
  func deleteDownloadedModel(_ model: Model) {
    cancelModelDownload(model)

    // If the model being deleted is the active one, the server restart triggered
    // below (via reload() once models.ini changes) drops it; status polling then
    // reconciles modelStatuses, clearing the derived activeModelId.

    let paths = resolvedPaths[model.id]

    // Optimistically update state immediately for responsive UI
    downloadedModels.removeAll { $0.id == model.id }
    resolvedPaths.removeValue(forKey: model.id)
    // Files the other installed models use, which deletion has to leave alone
    // (see `deleteModelFiles`). Read here, while `resolvedPaths` is on hand.
    let inUse = resolvedPaths.values.flatMap(\.allPaths)
    syncServer()
    NotificationCenter.default.post(name: .LBModelDownloadedListDidChange, object: self)

    // Move file deletion to background queue to avoid blocking main thread
    let modelId = model.id
    let cacheDir = UserSettings.hfCacheDirectory
    Task.detached { [weak self] in
      do {
        // Clean up any lingering partial files for this model.
        HFCache.removePartials(cacheDir: cacheDir, modelId: modelId)

        if let paths {
          try HFCache.deleteModelFiles(
            cacheDir: cacheDir,
            repoDir: paths.hfRepoDirName,
            paths: paths,
            keeping: inUse
          )
        }
      } catch {
        // If deletion failed, restore the model in the list
        guard let self else { return }
        await MainActor.run {
          self.restoreDeletedModel(model, error: error)
        }
      }
    }
  }

  private func restoreDeletedModel(_ model: Model, error: Error) {
    downloadedModels.append(model)
    downloadedModels.sort(by: Model.displayOrder(_:_:))
    // Re-scan to rebuild resolvedPaths
    refreshDownloadedModels()
    logger.error("Failed to delete model: \(error.localizedDescription)")
  }

  /// Regenerates `models.ini` and restarts the server only when the content
  /// actually changed — the single "model list changed, tell the server" path.
  func syncServer() {
    if updateModelsFile() {
      LlamaServer.shared.syncModelList()
    }
  }

  /// Updates the `models.ini` file required for using llama-server in Router Mode.
  /// Returns true if the file was changed, false if content was identical.
  @discardableResult
  func updateModelsFile() -> Bool {
    let content = generateModelsFileContent()
    let destinationURL = UserSettings.appSupportDir.appendingPathComponent("models.ini")

    // Skip write if content is identical
    if let existingData = try? Data(contentsOf: destinationURL),
      let existingContent = String(data: existingData, encoding: .utf8),
      existingContent == content
    {
      return false
    }

    do {
      try content.write(to: destinationURL, atomically: true, encoding: .utf8)
      logger.info("Updated models.ini at \(destinationURL.path)")
      return true
    } catch {
      logger.error("Failed to write models.ini: \(error)")
      return false
    }
  }

  private func generateModelsFileContent() -> String {
    // User overrides are layered on top of everything the scan produces, so the
    // generated values below are only ever defaults. See `UserModelOverrides`.
    UserModelOverrides.reload()
    let merged = ModelAliases.removeConflicts(
      from: UserModelOverrides.apply(
        to: generatedModelSections(), overrides: UserModelOverrides.current))
    return UserModelOverrides.generatedFileHeader + merged.map { $0.serialized() }.joined()
  }

  /// The app's own view of `models.ini`, derived purely from the cache scan and
  /// memory profiling -- before any user overrides are applied.
  private func generatedModelSections() -> [UserModelOverrides.Section] {
    var sections: [UserModelOverrides.Section] = []

    // Enable larger batch size for better performance on high-memory devices (>=32 GB RAM)
    let useLargeBatch = Double(SystemMemory.memoryMb) / 1024.0 >= 32.0

    for model in downloadedModels {
      // Use the effective tier (user selection or max compatible)
      guard let tier = model.effectiveCtxTier else { continue }

      guard let paths = resolvedPaths[model.id] else { continue }
      let modelPath = paths.modelFile
      let mmprojPath = paths.mmprojFile

      var section = UserModelOverrides.Section(name: model.id, pairs: [])
      section.set("model", modelPath)
      section.set("ctx-size", "\(tier.rawValue)")

      if let mmprojPath {
        section.set("mmproj", mmprojPath)
      }

      // Wire up speculative decoding -- a free speedup on models that ship a
      // draft head (Qwen3.6/3.8 etc.). Two shapes: a separate sidecar
      // (`dflash-….gguf` or `mtp-….gguf`, passed as the draft model), or an
      // MTP head embedded in the main weights (reused via its own MTP context,
      // no draft file). Sidecar wins when both look present. Each kind gets
      // its own draft depth (`DraftHead.draftNMax`).
      if let draftKind = paths.draftSidecarKind ?? (paths.usesMTP ? .mtp : nil) {
        section.set("spec-type", draftKind.specType)
        if let sidecar = paths.draftSidecarFile {
          section.set("spec-draft-model", sidecar)
        }
        section.set("spec-draft-n-max", "\(draftKind.draftNMax)")
      }

      if useLargeBatch {
        section.set("ubatch-size", "2048")
      }

      // What kind of model this is, for clients reading `/v1/models`: the
      // OpenAI-style listing has no field for it, and its `architecture`
      // modalities read text-in/text-out for every kind alike.
      // llama-server passes `tags` through to each listing entry verbatim
      // (it doesn't route on them), so a client can offer only `chat` models
      // in a chat picker. Untagged models -- written by earlier app versions
      // -- were all chat models, so clients can read a missing tag as `chat`.
      section.set("tags", model.kind.rawValue)

      // llama-server only serves `/v1/embeddings` for a model started with
      // `--embeddings`. The flag also restricts the instance to embedding
      // (it can't generate), which is all an embedding model does anyway.
      if model.kind == .embedding {
        section.set("embeddings", "true")
      }

      // Some models have to take each input in one batch (embedding models,
      // and decision models like Laya and Clef -- see
      // `ResolvedPaths.batchesWholeInput`), so the longest input they accept
      // is the batch size, not the context ("input is too large to process.
      // increase the physical batch size"). Left at the defaults that's 512
      // tokens (2048 with the large ubatch above), well under the context.
      // Sizing both batches to the context makes the context the real input
      // limit. It costs memory, so these models stay at the default context
      // (see `Model.effectiveCtxTier`). A `ctx-size` in models.user.ini is
      // followed, so raising it there raises the input limit with it.
      if paths.batchesWholeInput {
        let ctx = UserModelOverrides.overriddenCtxSize(for: model.id) ?? "\(tier.rawValue)"
        section.set("batch-size", ctx)
        section.set("ubatch-size", ctx)
      }

      // Names the user pointed at this model in Settings > Aliases.
      ModelAliases.apply(to: &section)

      sections.append(section)
    }
    return sections
  }

  /// Active mem-profile enrichment task. Cancelled on refresh to avoid stale updates.
  private var memProfileTask: Task<Void, Never>?

  /// Everything one cache scan produces, ready to be applied to state.
  private struct ScanResult {
    var models: [Model]
    var resolvedPaths: [String: ResolvedPaths]
    var needsProfile: [(id: String, path: String)]
    var paused: [(model: Model, bytesOnDisk: Int64)]
  }

  /// The scan itself: pure disk work, no state touched, so it can run on the
  /// main actor at launch or off it for every later refresh.
  nonisolated private static func scan(cacheDir hfCacheDir: URL) -> ScanResult {
    let discovered = HFCache.scanForSideloaded(cacheDir: hfCacheDir)

    // Apply cached mem-profile when available; queue the rest for async probing.
    var resolvedPaths: [String: ResolvedPaths] = [:]
    var models: [Model] = []
    var needsProfile: [(id: String, path: String)] = []
    for (entry, paths) in discovered {
      var entry = entry
      if let cached = MemProfileCache.get(modelId: entry.id) {
        entry.ctxBytesPer1kTokens = cached.ctxBytesPer1kTokens
        entry.residentBytes = cached.residentBytes
      } else {
        needsProfile.append((id: entry.id, path: paths.modelFile))
      }
      resolvedPaths[entry.id] = paths
      models.append(entry)
    }

    // Garbage-collect partial dirs whose target is now installed.
    let installedIds = Set(models.map(\.id))
    HFCache.cleanInstalledPartials(cacheDir: hfCacheDir, installedIds: installedIds)

    // Rehydrate paused rows for downloads interrupted in a previous session:
    // decode each on-disk placeholder back into a `Model` and pair it with its
    // current bytes-on-disk. No network resolve needed — the placeholder
    // carries the full `Model`.
    let pausedEntries = HFCache.scanPlaceholders(cacheDir: hfCacheDir).compactMap {
      url -> (model: Model, bytesOnDisk: Int64)? in
      guard let data = try? Data(contentsOf: url),
        let model = try? JSONDecoder().decode(Model.self, from: data)
      else { return nil }
      return (model, Self.partialBytes(of: model, cacheDir: hfCacheDir))
    }

    return ScanResult(
      models: models, resolvedPaths: resolvedPaths, needsProfile: needsProfile,
      paused: pausedEntries)
  }

  /// Scans the HF cache for installed models. Every model is treated as a
  /// sideloaded discovery — metadata comes from the repo dir + filename.
  func refreshDownloadedModels() {
    if applySimulatedModelsIfEnabled() { return }

    let hfCacheDir = UserSettings.hfCacheDirectory

    // Move directory reading to background queue to avoid blocking main thread
    Task.detached { [weak self] in
      let result = Self.scan(cacheDir: hfCacheDir)
      guard let self else { return }
      await MainActor.run { self.apply(result) }
    }
  }

  /// Scans on the calling (main) thread and applies the result before
  /// returning, so `models.ini` is on disk by the time this call ends.
  ///
  /// Launch uses this rather than the async refresh above. `llama serve` reads
  /// `models.ini` exactly once, at start, so it has to be current *before* the
  /// server is spawned -- otherwise the session runs on the previous launch's
  /// config, which is how an edit to `models.user.ini` used to need two
  /// restarts to take effect. Sequencing that with an async scan means the
  /// launch has to wait on it, and a menu-bar app with nothing on screen gets
  /// suspended mid-launch: measured, the server sat unstarted for 24s after the
  /// scan had already landed. Blocking is what keeps the process running, and
  /// the ordering falls out of plain statement order.
  ///
  /// Costs roughly a second of launch on a large cache -- the menu bar icon
  /// appears that much later. Worth it for a server that starts on the config
  /// the user actually has.
  func scanNow() {
    if applySimulatedModelsIfEnabled() { return }
    apply(Self.scan(cacheDir: UserSettings.hfCacheDirectory))
  }

  /// DEBUG fixture: replaces the real cache scan with a large, realistic list so
  /// the long-list UI can be worked on without downloading any weights. Skips
  /// mem-profiling, models.ini, and the server reload entirely. Returns true
  /// when it took over.
  private func applySimulatedModelsIfEnabled() -> Bool {
    #if DEBUG
      if SimulatedModels.isEnabled {
        downloadedModels = SimulatedModels.all.sorted(by: Model.displayOrder(_:_:))
        resolvedPaths = [:]
        NotificationCenter.default.post(name: .LBModelDownloadedListDidChange, object: self)
        return true
      }
    #endif
    return false
  }

  /// Folds a finished scan into state: model list, paused rows, `models.ini`,
  /// and the async mem-profile probes for anything without a cached profile.
  private func apply(_ result: ScanResult) {
    downloadedModels = result.models.sorted(by: Model.displayOrder(_:_:))
    resolvedPaths = result.resolvedPaths
    // Drop paused entries that are now installed or actively downloading, then
    // fold in the rehydrated on-disk placeholders. The merge is idempotent: a
    // download paused this session has both an in-memory entry and a placeholder
    // carrying the same `Model`, and an active download's id is excluded below.
    let excluded = Set(downloadedModels.map(\.id))
      .union(activeDownloads.keys)
    pausedDownloads = pausedDownloads.filter { !excluded.contains($0.key) }
    for entry in result.paused where !excluded.contains(entry.model.id) {
      pausedDownloads[entry.model.id] = PausedDownload(
        model: entry.model, bytesOnDisk: entry.bytesOnDisk)
    }

    // Only reload server if models.ini actually changed
    syncServer()

    NotificationCenter.default.post(name: .LBModelDownloadedListDidChange, object: self)

    // Kick off async mem-profile probing for models without cached results
    if !result.needsProfile.isEmpty {
      enrichWithMemProfiles(result.needsProfile)
    }
  }

  /// Probes sideloaded models that don't have a cached MemProfile.
  /// Updates each model's ctxBytesPer1kTokens as results come in, refreshing the UI.
  /// Runs sequentially (one model at a time) to avoid GPU contention.
  private func enrichWithMemProfiles(_ models: [(id: String, path: String)]) {
    // Cancel any previous enrichment task (e.g. from a previous refresh).
    // The withTaskCancellationHandler in MemProfileRunner.run() ensures the
    // subprocess is terminated when the task is cancelled.
    memProfileTask?.cancel()

    memProfileTask = Task.detached { [weak self] in
      for (modelId, modelPath) in models {
        guard !Task.isCancelled else { return }

        let profile = await MemProfileRunner.run(modelPath: modelPath)
        guard !Task.isCancelled else { return }

        // On failure, use a sentinel (-1) in memory so the UI drops out of
        // "estimating..." for this session — but don't persist it. A transient
        // failure (e.g. a broken-build window after a llama.cpp update where
        // llama fit-params can't dyld-link) would otherwise stick across
        // launches and never re-probe. Cost of not persisting: a few seconds
        // of "estimating..." next launch for genuinely unprobable models.
        let resolved = profile ?? MemProfile(ctxBytesPer1kTokens: -1)

        // Only cache successful probes to disk.
        if profile != nil {
          MemProfileCache.set(resolved, for: modelId)
        }

        // Update the in-memory model entry and refresh the UI
        guard let mgr = self else { return }
        await MainActor.run {
          if let idx = mgr.downloadedModels.firstIndex(where: { $0.id == modelId }) {
            mgr.downloadedModels[idx].ctxBytesPer1kTokens = resolved.ctxBytesPer1kTokens
            mgr.downloadedModels[idx].residentBytes = resolved.residentBytes
          }

          // Regenerate models.ini now that we have accurate memory info
          mgr.syncServer()

          NotificationCenter.default.post(name: .LBModelDownloadedListDidChange, object: mgr)
        }
      }
    }
  }

  /// Discards an ongoing or paused download — the server stops it and drops its
  /// partial files (`DELETE /models`). A subsequent start begins from byte zero.
  func cancelModelDownload(_ model: Model) {
    // Only a download the server knows of: an installed model is deleted
    // by `deleteDownloadedModel`, which keeps files other models share.
    if activeDownloads[model.id] != nil || pausedDownloads[model.id] != nil {
      Task { await serverAPI.deleteDownload(id: model.id) }
    }
    tearDownActiveDownload(modelId: model.id, outcome: .discard)
  }

  /// Stops an in-flight download but keeps its partial bytes on disk so the user
  /// can resume it later. The model reappears in the Installed section as paused.
  func pauseModelDownload(_ model: Model) {
    guard activeDownloads[model.id] != nil else { return }
    tearDownActiveDownload(modelId: model.id, outcome: .pause)
    // The server keeps its partial files; downloading again resumes them.
    Task { _ = await serverAPI.unloadModel(id: model.id) }
  }

  // MARK: - Convenience Methods

  /// Returns true if the model is installed (fully downloaded).
  func isInstalled(_ model: Model) -> Bool {
    status(for: model) == .installed
  }

  /// Returns true if the model is currently downloading.
  func isDownloading(_ model: Model) -> Bool {
    if case .downloading = status(for: model) { return true }
    return false
  }

  // MARK: - Helpers

  /// What to do with the app's bookkeeping when tearing down an active download.
  /// The partial files themselves are the server's: `cancelModelDownload` asks it
  /// to drop them.
  enum TeardownOutcome {
    /// User asked to throw the download away — remove the placeholder, drop any paused state.
    case discard
    /// Stop tracking the transfer but show the model as paused when it has
    /// partial bytes on disk. Used by the user "pause" action, a stop another
    /// client asked for, the server going away, and failures.
    case pause
  }

  /// Clears in-memory bookkeeping for a model's download and either surfaces the
  /// leftover bytes as a paused row or discards it.
  /// The single teardown path means cancel, pause, and failure all behave
  /// identically except for what happens to the paused row.
  func tearDownActiveDownload(modelId: String, outcome: TeardownOutcome) {
    let model = activeDownloads[modelId]?.model
    activeDownloads.removeValue(forKey: modelId)

    switch outcome {
    case .discard:
      pausedDownloads.removeValue(forKey: modelId)
      HFCache.removePartials(cacheDir: UserSettings.hfCacheDirectory, modelId: modelId)
    case .pause:
      let bytes = model.map { Self.partialBytes(of: $0, cacheDir: UserSettings.hfCacheDirectory) } ?? 0
      if bytes > 0, let model {
        pausedDownloads[modelId] = PausedDownload(model: model, bytesOnDisk: bytes)
      } else {
        // Nothing on disk to resume, so don't leave a ghost entry in pausedDownloads.
        pausedDownloads.removeValue(forKey: modelId)
      }
    }

    // Every teardown changes the Installed section shape AND progress state.
    // Posting here keeps the callers (cancel / pause / failure) from having to
    // remember to fire the right notifications.
    NotificationCenter.default.post(name: .LBModelDownloadsDidChange, object: self)
    NotificationCenter.default.post(name: .LBModelDownloadedListDidChange, object: self)
  }

  /// Single failure-reporting path: tears down the download (keeping partials so
  /// the row resurfaces as paused where possible) and posts the failure alert.
  func failDownload(model: Model, reason: String) {
    logger.error("Model download failed (\(reason)) for model: \(model.displayName)")
    tearDownActiveDownload(modelId: model.id, outcome: .pause)
    NotificationCenter.default.post(
      name: .LBModelDownloadDidFail,
      object: self,
      userInfo: ["model": model, "error": reason]
    )
  }

  /// Bytes of the server's partial files for the model's repo -- what a paused
  /// row shows. Per repo, not per model: the server names partials by blob, so
  /// two quants of one repo paused at once share the figure.
  nonisolated private static func partialBytes(of model: Model, cacheDir: URL) -> Int64 {
    guard let repoDir = model.hfRepoDir else { return 0 }
    return HFCache.partialBytes(cacheDir: cacheDir, repoDir: repoDir)
  }

  private func validateCompatibility(for model: Model) throws {
    guard model.isCompatible() else {
      let reason =
        model.incompatibilitySummary()
        ?? "Not compatible with this Mac's memory"
      throw DownloadError.notCompatible(reason: reason)
    }
  }

  private func validateDiskSpace(for model: Model, remainingBytes: Int64) throws {
    guard remainingBytes > 0 else { return }

    // Check disk space at the HF cache directory (where new downloads go)
    let targetDir = UserSettings.hfCacheDirectory
    let available = DiskSpace.availableBytes(at: targetDir)

    if available > 0 && remainingBytes > available {
      let needStr = Format.gigabytes(remainingBytes)
      let haveStr = Format.gigabytes(available)
      throw DownloadError.notEnoughDiskSpace(required: needStr, available: haveStr)
    }
  }

  func postDownloadsDidChange() {
    NotificationCenter.default.post(name: .LBModelDownloadsDidChange, object: self)
  }
}
