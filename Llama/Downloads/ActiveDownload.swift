import Foundation

/// Paused download state. Carries the `Model` so deeplink-sideload
/// placeholders can still render a paused row after their active download
/// is torn down.
struct PausedDownload {
  let model: Model
  let bytesOnDisk: Int64
}

/// Tracks the progress of a model download that llama-server is running. The
/// byte counts come from its `download_progress` events (see
/// `ModelManager.handleDownloadEvent`).
struct ActiveDownload {
  let model: Model
  var progress: Progress
  /// When the last progress notification was posted (UI refresh throttle).
  var lastNotified: Date = .distantPast
  /// Recent (time, completed-bytes) samples backing the live rate readout.
  /// Appended on every `refreshProgress` tick, pruned to `rateWindow`. A
  /// trailing-window average keeps the displayed figure lively but not jumpy.
  var rateSamples: [(time: Date, bytes: Int64)] = []

  /// How far back the rate average looks.
  private static let rateWindow: TimeInterval = 5

  /// Current transfer rate in bytes/sec, averaged over `rateWindow`.
  /// Nil until the window holds at least a second of data — a shorter span
  /// makes the first readouts wildly noisy.
  var bytesPerSecond: Int64? {
    guard let first = rateSamples.first, let last = rateSamples.last else { return nil }
    let span = last.time.timeIntervalSince(first.time)
    guard span >= 1 else { return nil }
    // Clamp: a retry can rewind the byte count (a discarded partial), and a
    // negative rate must never reach the UI.
    return max(0, Int64(Double(last.bytes - first.bytes) / span))
  }

  /// Refreshes `progress` from the server's byte sums across the files it's
  /// downloading. `expectedBytes` is 0 for a file until its size is known.
  mutating func refreshProgress(bytes: Int64, expectedBytes: Int64) {
    // Don't shrink totalUnitCount — it's seeded from the HF resolve's
    // aggregated byte count, and a file's size is unknown until its response
    // arrives.
    progress.totalUnitCount = max(progress.totalUnitCount, expectedBytes, 1)
    progress.completedUnitCount = bytes

    // Feed the rate window.
    let now = Date()
    rateSamples.append((time: now, bytes: bytes))
    rateSamples.removeAll { now.timeIntervalSince($0.time) > Self.rateWindow }
  }
}
