import Foundation

/// Utility for working with the standard HuggingFace Hub cache layout.
///
/// Layout:
/// ```
/// ~/.cache/huggingface/hub/
/// └── models--{org}--{repo}/
///     ├── blobs/
///     │   └── {sha256}              # actual file, named by content hash
///     ├── refs/
///     │   └── main                  # text file containing commit hash
///     └── snapshots/
///         └── {commit}/
///             └── filename.gguf -> ../../blobs/{sha256}
/// ```
enum HFCache {

  /// Name of the hidden dir under the HF cache that holds a placeholder per
  /// unfinished download (and the `.partial` files of downloads earlier
  /// versions ran themselves). Tied to the app's "llama" identity;
  /// `RenameMigration` moves the pre-rename `.llamabarn-partial` dir here on
  /// first launch.
  static let partialRootDirName = ".llama-partial"

  // MARK: - Path Helpers (pure, no I/O)

  /// Parses a HF download URL and returns the repo directory name.
  /// e.g. `https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/file.gguf`
  /// → `"models--unsloth--Qwen3.5-2B-GGUF"`
  static func repoDirName(from url: URL) -> String? {
    // Path components: ["", "unsloth", "Qwen3.5-2B-GGUF", "resolve", "main", "file.gguf"]
    let components = url.pathComponents
    guard components.count >= 4,
      components[3] == "resolve"
    else { return nil }
    let org = components[1]
    let repo = components[2]
    return "models--\(org)--\(repo)"
  }

  /// Directory that holds a model's download placeholder.
  static func partialDir(cacheDir: URL, modelId: String) -> URL {
    cacheDir
      .appendingPathComponent(partialRootDirName)
      .appendingPathComponent(modelId)
  }

  /// Removes the model's partial directory (and any files under it).
  /// Silently ignores missing dirs — used by cancel/delete/cleanup paths.
  static func removePartials(cacheDir: URL, modelId: String) {
    let dir = partialDir(cacheDir: cacheDir, modelId: modelId)
    try? FileManager.default.removeItem(at: dir)

    // A model id has a slash (`org/repo:quant`), so its dir sits inside an org
    // dir that would otherwise be left behind empty. Remove that one level, but
    // only if it's empty -- POSIX `rmdir` refuses a non-empty dir, so this
    // can't take another download's partials with it, even one that creates
    // its dir under the same org between our check and the delete (which
    // `FileManager.removeItem`, being recursive, could).
    let orgDir = dir.deletingLastPathComponent()
    if orgDir.path != cacheDir.appendingPathComponent(partialRootDirName).path {
      rmdir(orgDir.path)
    }
  }

  /// Sum of the sizes of llama-server's partial files in a repo: the
  /// `blobs/<hash>.downloadInProgress` files it resumes from. Returns 0 if
  /// there are none.
  static func partialBytes(cacheDir: URL, repoDir: String) -> Int64 {
    let blobsDir = cacheDir.appendingPathComponent(repoDir).appendingPathComponent("blobs")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: blobsDir.path)) ?? []
    return files.filter { $0.hasSuffix(".downloadInProgress") }.reduce(0) {
      $0 + FileManager.default.fileSize(atPath: blobsDir.appendingPathComponent($1).path)
    }
  }

  /// File name of the per-download placeholder. Hidden (leading dot); it rides
  /// inside the partial dir so `removePartials` disposes of it on
  /// completion/cancel.
  static let placeholderFileName = ".model.json"

  /// Path to a download's placeholder file (the serialized `Model`). Written
  /// when a download starts so the app can rebuild the paused row at launch
  /// without a network resolve; see `scanPlaceholders`.
  static func placeholderURL(cacheDir: URL, modelId: String) -> URL {
    partialDir(cacheDir: cacheDir, modelId: modelId)
      .appendingPathComponent(placeholderFileName)
  }

  /// Finds every download placeholder under the partial root — one per
  /// interrupted/paused download from a previous session. Used at launch to
  /// rehydrate paused rows. Returns the placeholder file URLs; the caller
  /// decodes the `Model` (HFCache stays model-agnostic).
  static func scanPlaceholders(cacheDir: URL) -> [URL] {
    let root = cacheDir.appendingPathComponent(partialRootDirName)
    guard
      let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent == placeholderFileName {
      result.append(url)
    }
    return result
  }

  /// Cleans up `<partialRootDirName>/<id>` subdirs for ids that are already
  /// installed (e.g. a deeplink download that landed but left its partial dir
  /// behind). Interrupted (not-yet-installed) downloads are kept and surfaced
  /// as paused rows at launch via `scanPlaceholders`.
  static func cleanInstalledPartials(cacheDir: URL, installedIds: Set<String>) {
    // Delete by id, not by listing the root: a model id contains a slash, and
    // `appendingPathComponent` treats it as a separator rather than escaping it,
    // so a partial lives at `<root>/<org>/<repo>:<quant>` -- two levels down.
    // Listing the root only ever yields org names, which never match an id.
    // Going through `partialDir` reuses the builder that created the dir, so
    // the two sides can't disagree about the layout.
    for modelId in installedIds {
      removePartials(cacheDir: cacheDir, modelId: modelId)
    }

    // Deleting the id dir can leave its org dir behind empty.
    cleanEmptyDirs(at: cacheDir.appendingPathComponent(partialRootDirName))
  }

  // MARK: - Deletion

  /// Deletes a model's files from the HF cache.
  /// Removes blobs (resolved from symlinks), snapshot symlinks, and cleans up empty dirs.
  ///
  /// Leaves alone anything in `inUse` -- the paths of the other installed
  /// models. Quants of one repo share their mmproj and draft head: the very
  /// same snapshot symlink when installed at one commit, the same blob when
  /// installed at different ones. Deleting one quant mustn't take the other's
  /// sidecars with it -- the scan would then pair the other with nothing, and
  /// it'd lose image input (or drafting) without a word.
  static func deleteModelFiles(
    cacheDir: URL, repoDir: String, paths: ResolvedPaths, keeping inUse: [String]
  ) throws {
    let fm = FileManager.default
    var blobsToDelete: Set<String> = []
    var symlinksToDelete: [String] = []

    let keptPaths = Set(inUse)
    let keptBlobs = Set(inUse.compactMap(blobPath(ofSymlink:)))

    // Collect blob paths by following symlinks
    for path in paths.allPaths where !keptPaths.contains(path) {
      // Check if it's a symlink and resolve the blob
      if let blob = blobPath(ofSymlink: path) {
        blobsToDelete.insert(blob)
        symlinksToDelete.append(path)
      } else if fm.fileExists(atPath: path) {
        // Direct file (not a symlink) — just delete it
        try fm.removeItem(atPath: path)
      }
    }

    // Delete symlinks first, then blobs
    for symlink in symlinksToDelete {
      try? fm.removeItem(atPath: symlink)
    }
    for blob in blobsToDelete.subtracting(keptBlobs) {
      if fm.fileExists(atPath: blob) {
        try fm.removeItem(atPath: blob)
      }
    }

    // Clean up empty directories
    let repoBase = cacheDir.appendingPathComponent(repoDir)
    cleanEmptyDirs(at: repoBase)
  }

  /// The absolute path of the blob a snapshot symlink points at, nil when
  /// `path` isn't a symlink. Both sides of `deleteModelFiles`' in-use check go
  /// through here, so the paths they compare are built the same way.
  private static func blobPath(ofSymlink path: String) -> String? {
    guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
      return nil
    }
    // dest is relative like "../../blobs/{hash}", resolve it
    let symlinkDir = URL(fileURLWithPath: path).deletingLastPathComponent()
    return symlinkDir.appendingPathComponent(dest).standardized.path
  }

  /// Recursively removes empty directories under the given path.
  /// Removes the path itself if it becomes empty.
  private static func cleanEmptyDirs(at url: URL) {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(atPath: url.path) else { return }

    for item in contents {
      let itemUrl = url.appendingPathComponent(item)
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: itemUrl.path, isDirectory: &isDir), isDir.boolValue {
        cleanEmptyDirs(at: itemUrl)
      }
    }

    // Check again after cleaning subdirs
    if let remaining = try? fm.contentsOfDirectory(atPath: url.path), remaining.isEmpty {
      try? fm.removeItem(at: url)
    }
  }

  // MARK: - Discovery

  /// Scans the HF cache for GGUF files and builds a `Model` + `ResolvedPaths`
  /// per discovered file (or shard group).
  ///
  /// For each GGUF, metadata is parsed from the repo directory name and
  /// filename using the same approach as llama.cpp's WebUI model selector.
  /// Split GGUFs (e.g. -00001-of-00003.gguf) are grouped as single entries.
  static func scanForSideloaded(
    cacheDir: URL
  ) -> [(entry: Model, paths: ResolvedPaths)] {
    let fm = FileManager.default
    var results: [(entry: Model, paths: ResolvedPaths)] = []

    guard let repoDirs = try? fm.contentsOfDirectory(atPath: cacheDir.path) else {
      return results
    }

    for repoDir in repoDirs {
      guard repoDir.hasPrefix("models--") else { continue }

      let snapshotsDir =
        cacheDir
        .appendingPathComponent(repoDir)
        .appendingPathComponent("snapshots")

      guard let commits = try? fm.contentsOfDirectory(atPath: snapshotsDir.path) else {
        continue
      }

      // Track which model IDs we've already found in this repo
      // (same model may appear in multiple snapshots)
      var seenIds: Set<String> = []

      // Check all snapshot commits, not just the first — a repo may have
      // multiple commits with different files. `seenIds` keeps duplicates out
      // of the result list.
      for commit in commits {
        let snapshotDir = snapshotsDir.appendingPathComponent(commit)
        // `allFiles` keeps the sidecars the runnable list drops -- the sidecar
        // pickers rank across the whole snapshot, not just one directory.
        let allFiles = allGgufFiles(in: snapshotDir, fm: fm)
        let ggufFiles = allFiles.filter(isRunnableModel)
        guard !ggufFiles.isEmpty else { continue }

        // Group split shards: "model-00001-of-00003.gguf" etc.
        // Key: shard base name → [all shard filenames sorted]
        var shardGroups: [String: [String]] = [:]
        var standaloneFiles: [String] = []

        for filename in ggufFiles {
          if HFRepoParser.isSplitShard(filename) {
            if let baseName = HFRepoParser.splitShardBaseName(filename) {
              shardGroups[baseName, default: []].append(filename)
            }
          } else {
            standaloneFiles.append(filename)
          }
        }

        // Process standalone GGUF files (one entry per file)
        for filename in standaloneFiles {
          if let result = buildSideloadedEntry(
            repoDir: repoDir, filename: filename, shardFiles: nil,
            snapshotDir: snapshotDir, siblings: allFiles, fm: fm
          ), seenIds.insert(result.entry.id).inserted {
            results.append(result)
          }
        }

        // Process split shard groups (one entry per group, using first shard)
        for (_, shardFilenames) in shardGroups {
          let sorted = shardFilenames.sorted()
          // Only include complete groups: first shard present AND every shard of
          // the declared `-of-NNNNN` count on disk. Shards are promoted into the
          // snapshot one by one as each finishes downloading, so a mid-download
          // scan can see a partial set — treating that as installed would make
          // the model appear twice (installed + downloading) and lets the
          // partials GC delete the in-flight download's staging files.
          guard let firstShard = sorted.first,
            HFRepoParser.isFirstShard(firstShard),
            sorted.count == HFRepoParser.shardTotal(firstShard)
          else { continue }

          if let result = buildSideloadedEntry(
            repoDir: repoDir, filename: firstShard, shardFiles: sorted,
            snapshotDir: snapshotDir, siblings: allFiles, fm: fm
          ), seenIds.insert(result.entry.id).inserted {
            results.append(result)
          }
        }
      }
    }

    return results
  }

  /// Collects every GGUF in a snapshot dir and one level of subdirs, sidecars
  /// included. Some repos (e.g. unsloth) store sharded quants in per-quant
  /// subdirs like Q4_K_M/model-00001-of-00003.gguf. Returned paths are relative
  /// to `snapshotDir` (e.g. "file.gguf" or "Q4_K_M/file.gguf").
  private static func allGgufFiles(in snapshotDir: URL, fm: FileManager) -> [String] {
    guard let topFiles = try? fm.contentsOfDirectory(atPath: snapshotDir.path) else {
      return []
    }

    var allFiles: [String] = []
    for item in topFiles {
      let itemPath = snapshotDir.appendingPathComponent(item).path
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue {
        if let subFiles = try? fm.contentsOfDirectory(atPath: itemPath) {
          for subFile in subFiles {
            allFiles.append("\(item)/\(subFile)")
          }
        }
      } else {
        allFiles.append(item)
      }
    }

    return allFiles.filter { $0.lowercased().hasSuffix(".gguf") }
  }

  /// True for a GGUF that can stand on its own as a model entry.
  ///
  /// Skips mmproj (vision projection) and every speculative draft head -- none
  /// is a runnable model on its own. A draft head parses to the same quant tag
  /// as the main weights it ships beside, so leaving one in here doesn't just
  /// add a bogus entry: it collides on `{org}/{repo}:{TAG}` and the dedupe
  /// downstream can keep the sidecar and drop the real model.
  private static func isRunnableModel(_ relativePath: String) -> Bool {
    !SidecarPicker.isMmproj(relativePath) && !SidecarPicker.isDraftHead(relativePath)
  }

  /// Builds a `Model` + `ResolvedPaths` from a discovered GGUF file.
  ///
  /// Quant tags come from `GGUFQuant.tag(forPath:)` — the same derivation the
  /// deeplink resolver uses, so deeplink-originated installs and
  /// scan-discovered installs agree on `{org}/{repo}:{TAG}` and round-trip.
  private static func buildSideloadedEntry(
    repoDir: String,
    filename: String,
    shardFiles: [String]?,
    snapshotDir: URL,
    siblings: [String],
    fm: FileManager
  ) -> (entry: Model, paths: ResolvedPaths)? {
    // Org and repo from the repo dir name
    guard let parsed = HFRepoParser.parse(repoDir: repoDir) else { return nil }

    // Derive the quant tag. This is load-bearing for identity: the deeplink
    // resolver builds `{org}/{repo}:{TAG}` through the same function, and
    // `updateDownloadedModels` cleans up pending rows by id match — a
    // diverging derivation here means pending entries never get reaped.
    let quant = GGUFQuant.tag(forPath: filename)

    // Locate the vision projector (`mmproj*.gguf`) sidecar, if the repo ships
    // one. Vision models can't do image input without it, and this scan path is
    // the sole source of `resolvedPaths` for `models.ini` — so if we don't
    // attach it here, the `mmproj =` line never gets written and vision
    // silently fails even though the sidecar is on disk.
    let mmprojFile = SidecarPicker.mmproj(among: siblings, mainPath: filename)
      .map { snapshotDir.appendingPathComponent($0).path }

    // Calculate file size (sum all shards if split, plus the mmproj sidecar so
    // it matches `Model.fileSize`'s contract: main + shards + mmproj).
    var filePaths: [String]
    if let shardFiles {
      filePaths = shardFiles.map { snapshotDir.appendingPathComponent($0).path }
    } else {
      filePaths = [snapshotDir.appendingPathComponent(filename).path]
    }
    if let mmprojFile {
      filePaths.append(mmprojFile)
    }

    // Resolve symlinks before reading attributes — HF cache stores symlinks in
    // snapshot dirs pointing to blobs, and attributesOfItem returns the symlink
    // size (not the target file size) for symlinks.
    let totalFileSize: Int64 = filePaths.reduce(0) { sum, path in
      let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
      return sum + fm.fileSize(atPath: resolved)
    }

    // Generate the stable ID via the shared grammar: the verbatim
    // "{org}/{repo}:{QUANT}", matching llama-server's `-hf` shorthand so power
    // users can switch b/w llama-server and Llama w/o changing model IDs in
    // their code.
    let modelId = Model.makeId(org: parsed.org, repo: parsed.repo, tag: quant)

    // The model's native context window, read from the GGUF header (metadata
    // lives in the first shard, which `filename` points at for split models).
    // This drives which tiers the picker offers -- without it every model was
    // capped at 128k regardless of what it natively supports.
    //
    // The two nil cases mean different things. A header we couldn't parse falls
    // back to 128k, matching the prior fixed behavior -- misreading a file must
    // never hide a model. But a header that parsed cleanly and simply has no
    // `<arch>.context_length` is a GGUF llama.cpp can't run: the key is required
    // for every arch it supports, so its absence marks a non-LLM sharing the
    // cache (speech-to-text models dropped there by other apps, say). Those get
    // skipped -- we can't serve them, and their memory estimates are nonsense.
    let ctxWindow: Int
    switch GGUFMetadata.contextLength(path: snapshotDir.appendingPathComponent(filename).path) {
    case .some(.some(let length)): ctxWindow = length
    case .some(.none): return nil  // header parsed, key absent -- not an LLM
    case .none: ctxWindow = 131_072  // header unparseable -- fall back
    }

    let mainFilePath = snapshotDir.appendingPathComponent(filename).path

    // A sidecar draft head shipped beside the main weights, if any -- DFlash
    // before MTP, quant-matched to the main (see `SidecarPicker.draftHead`).
    // Present takes precedence over an embedded head. An install from before
    // DFlash support has only the MTP sidecar on disk and keeps drafting
    // with it; this picks up a DFlash sidecar as soon as one lands.
    let draftSidecar = SidecarPicker.draftHead(among: siblings, mainPath: filename, tag: quant)
      .map { snapshotDir.appendingPathComponent($0).path }

    // Embedded-head detection reads the GGUF metadata (the ground truth --
    // unsloth's MTP builds carry no filename marker at all), falling back to
    // the filename heuristic only when the header can't be parsed. This must
    // stay conservative: wrongly emitting `spec-type = draft-mtp` for a
    // headless model makes llama-server fail to load it entirely.
    let hasEmbeddedHead =
      GGUFMetadata.hasEmbeddedMTPHead(path: mainFilePath)
      ?? fileHasMTPHead(URL(fileURLWithPath: filename).lastPathComponent)

    // Decision and embedding models don't chat -- they answer `/v1/systemone`
    // and `/v1/embeddings`. The menu hides chat actions for them, and
    // `models.ini` tags them apart and turns embeddings on (see
    // `ModelManager.generatedModelSections`).
    let kind = GGUFMetadata.kind(path: mainFilePath)
    // Models llama.cpp takes in one batch per input (see
    // `ResolvedPaths.batchesWholeInput`): embedding models, and the decision
    // types it scores from the embeddings output in a single pass.
    let batchesWholeInput =
      kind == .embedding
      || (kind == .decision
        && ["laya", "clef", "lfm2-d1-omni"].contains(GGUFMetadata.decisionType(path: mainFilePath)))

    let entry = Model(
      id: modelId,
      ctxWindow: ctxWindow,
      fileSize: totalFileSize,
      // ctxBytesPer1kTokens stays 0 until the async MemProfile probe runs.
      downloadUrl: URL(string: "file:///")!,
      // Either shape counts for the row's chip; `ResolvedPaths` below keeps
      // them apart because they produce different `models.ini` lines.
      scannedDraftHead: draftSidecar.flatMap { DraftHead(sidecarPath: $0) }
        ?? (hasEmbeddedHead ? .mtp : nil),
      kind: kind
    )

    // Build resolved paths
    let additionalParts: [String]
    if let shardFiles, shardFiles.count > 1 {
      // Additional shards = everything except the first shard
      additionalParts = shardFiles.dropFirst().map {
        snapshotDir.appendingPathComponent($0).path
      }
    } else {
      additionalParts = []
    }

    let paths = ResolvedPaths(
      modelFile: mainFilePath,
      additionalParts: additionalParts,
      mmprojFile: mmprojFile,
      usesMTP: draftSidecar == nil && hasEmbeddedHead,
      draftSidecarFile: draftSidecar,
      batchesWholeInput: batchesWholeInput,
      hfRepoDirName: repoDir
    )

    return (entry: entry, paths: paths)
  }

  /// Filename fallback for embedded-MTP detection, used only when the GGUF
  /// header can't be parsed (see `GGUFMetadata.hasEmbeddedMTPHead`). Some
  /// builds tag themselves with an `mtp` token delimited by the usual filename
  /// separators -- e.g. `Qwen3.6-27B-Q4_K_M-mtp.gguf` or
  /// `Qwen3.6-27B-MTP-Q8_0.gguf`. We match the delimited token (not a bare
  /// substring) so an unrelated name can't trip it. There's no separate sidecar
  /// to download: the head rides inside the main file.
  private static func fileHasMTPHead(_ fileBaseName: String) -> Bool {
    fileBaseName.range(
      of: #"(^|[-_.])mtp([-_.]|$)"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

}
