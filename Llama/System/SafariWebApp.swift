import AppKit
import Foundation
import os.log

/// A Safari Web App ("Add to Dock", Safari 17+) installed for the WebUI.
///
/// A web app is an app bundle under `~/Applications` whose Info.plist embeds
/// the manifest Safari captured at install time, including the `start_url` it
/// was pinned to. An app whose `start_url` origin matches the running server
/// is the WebUI in a window of its own, so "Open chat" launches it instead of
/// a browser tab.
///
/// Detection only, never installation: LaunchServices opens template bundles
/// solely when Safari created them (it validates each one's signature against
/// a registry in a Safari-only data vault), and the install itself is a user
/// gesture in Safari.
@MainActor
enum SafariWebApp {

  private nonisolated static let logger = Logger(subsystem: Logging.subsystem, category: "SafariWebApp")

  /// The prefix Safari stamps on every web app's bundle identifier; the UUID
  /// that follows is per-install.
  private static let bundleIDPrefix = "com.apple.Safari.WebApp."

  /// Where "Add to Dock" installs, plus `/Applications` for a bundle moved
  /// there.
  private static let searchDirectories: [URL] = [
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    URL(fileURLWithPath: "/Applications"),
  ]

  /// The installed web app pinned to `url`'s origin, if any.
  static func installed(matching url: URL) -> URL? {
    installedApps(matching: url).first
  }

  /// Every installed web app pinned to `url`'s origin -- one per install, so
  /// a user can have several (two names, two Dock icons).
  ///
  /// URLs with a query never match: a plain launch always opens the pinned
  /// `start_url`, so a deep link like `?model=...` needs the open-URL
  /// delivery (`openInWebApp`) or the browser.
  static func installedApps(matching url: URL) -> [URL] {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.queryItems == nil else { return [] }
    let origin = Origin(components)
    var matches: [URL] = []

    for directory in searchDirectories {
      let contents = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
      for appURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      where appURL.pathExtension == "app" {
        // `Manifest`/`start_url` are Safari's own plist keys -- undocumented
        // (reverse-engineered, verified against Safari 17+), so a format
        // change on some future OS degrades to "no match" and the browser.
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID.hasPrefix(bundleIDPrefix),
              let manifest = info["Manifest"] as? [String: Any],
              let startURLString = manifest["start_url"] as? String,
              let start = URLComponents(string: startURLString) else { continue }
        if Origin(start) == origin { matches.append(appURL) }
      }
    }
    return matches
  }

  /// `installed(matching:)` on `url`'s origin alone -- for callers whose deep
  /// link carries its state another way (the model page loads through the
  /// server), so the query that blocks the match is theirs to drop.
  static func installed(forOriginOf url: URL) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.queryItems = nil
    guard let originURL = components.url else { return nil }
    return installed(matching: originURL)
  }

  /// The web app's bundle identifier, for finding its running instance.
  static func bundleIdentifier(of appURL: URL) -> String? {
    NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
  }

  /// `url` re-addressed to the origin `appURL` is pinned to.
  ///
  /// A web app navigates only within its own origin; a URL outside it is
  /// handed to the default browser instead. A link meant for the app
  /// therefore has to arrive on the origin the app was installed from --
  /// `localhost` or the LAN address, whichever the user added it from --
  /// which only the bundle knows.
  static func rehosted(_ url: URL, forWebAppAt appURL: URL) -> URL? {
    guard
      let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
      let manifest = info["Manifest"] as? [String: Any],
      let startURLString = manifest["start_url"] as? String,
      let pinned = URLComponents(string: startURLString),
      let host = pinned.host,
      var link = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }

    link.scheme = pinned.scheme ?? link.scheme
    link.host = host
    link.port = pinned.port
    return link.url
  }

  /// Shows `url` in the web app at `appURL` -- launching (or activating) it
  /// first, then delivering the link as an open-URL event, the one way a web
  /// app takes a URL other than its pinned start URL, so the webui reads the
  /// same query a browser visit would.
  ///
  /// The delivery is split because a cold start swallows the event: it lands
  /// during launch, before there is a webview to navigate, and the app stays
  /// on its pinned start URL. Once the process is up and its page under way,
  /// the same event navigates. An app that is already running gets the event
  /// right away. The link is rehosted to the app's pinned origin first (a web
  /// app navigates only within it); when that fails there is no way to
  /// deliver, and `false` tells the caller to fall back to the browser.
  @discardableResult
  static func open(_ url: URL, inWebAppAt appURL: URL) -> Bool {
    guard let linkURL = rehosted(url, forWebAppAt: appURL) else { return false }
    let bundleID = bundleIdentifier(of: appURL)
    let running = bundleID != nil && NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == bundleID
    }

    Task {
      if !running {
        NSWorkspace.shared.open(appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
          if let error {
            logger.error("Launching web app: \(error.localizedDescription, privacy: .public)")
          }
        }
        // Wait for the process, then for the page it opens to be under way.
        if let bundleID {
          var waited: UInt64 = 0
          while waited < launchPollLimit,
                !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID })
          {
            try? await Task.sleep(nanoseconds: launchPollInterval)
            waited += launchPollInterval
          }
        }
        try? await Task.sleep(nanoseconds: pageSettleDelay)
      }
      NSWorkspace.shared.open(
        [linkURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        if let error {
          logger.error("Delivering link to web app: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
    return true
  }

  /// Cold-start delivery tuning: the open-URL event has to land after the
  /// launch, once the process is up (poll for it at most `launchPollLimit`)
  /// and its first page under way (`pageSettleDelay`) -- sent during the
  /// launch it lands before there is a webview to navigate, and the app stays
  /// on its start URL.
  private static let launchPollInterval: UInt64 = 250_000_000  // 0.25 s
  private static let launchPollLimit: UInt64 = 5_000_000_000  // 5 s
  private static let pageSettleDelay: UInt64 = 2_000_000_000  // 2 s

  /// Quits the running instances of every web app installed for `url`'s
  /// origin, for when the app goes away: a web app without its server is a
  /// window of connection errors. `terminate()` is a quit request rather than
  /// a kill -- the web app takes a few seconds and saves its state on the way
  /// out, and it quits whether or not the requester is still around.
  static func quitRunningInstances(matching url: URL) {
    let bundleIDs = Set(installedApps(matching: url).compactMap(bundleIdentifier(of:)))
    for app in NSWorkspace.shared.runningApplications {
      guard let bundleID = app.bundleIdentifier, bundleIDs.contains(bundleID) else { continue }
      app.terminate()
    }
  }

  /// The scheme://host:port identity of a URL, for matching a web app's
  /// pinned origin against the URL a caller hands in. Hosts that reach the
  /// running server (`LlamaServer.reachableHosts`) all name the same server,
  /// so they compare equal to each other and only to each other -- the menu
  /// builds its URLs from the resolved host while a web app stays pinned to
  /// whatever spelling the user installed it from, and the bind is what
  /// decides whether two spellings are the same server: `localhost` and the
  /// LAN address fold while the server answers on both, and stop folding the
  /// moment it doesn't (an app pinned to an address the server doesn't serve
  /// is left alone -- its window would be connection errors; the browser
  /// still works). Hosts compare case-insensitively per RFC 3986.
  private struct Origin: Equatable {
    let scheme: String
    let port: Int
    /// The host as written, lowercased -- compared only when neither side is
    /// `local`, so two hosts outside the reachable set match only by name.
    let host: String
    /// Whether the host reaches the running server right now.
    let local: Bool

    init(_ components: URLComponents) {
      scheme = components.scheme ?? "http"
      port = components.port ?? (scheme == "https" ? 443 : 80)
      host = (components.host ?? "").lowercased()
      local = LlamaServer.reachableHosts.contains(host)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.scheme == rhs.scheme && lhs.port == rhs.port
        && ((lhs.local && rhs.local) || lhs.host == rhs.host)
    }
  }
}
