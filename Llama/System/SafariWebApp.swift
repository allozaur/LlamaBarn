import AppKit
import Foundation

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
enum SafariWebApp {

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
  ///
  /// URLs with a query never match: a plain launch always opens the pinned
  /// `start_url`, so a deep link like `?model=...` needs the open-URL
  /// delivery (`openInWebApp`) or the browser.
  static func installed(matching url: URL) -> URL? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.queryItems == nil else { return nil }
    let origin = Self.origin(of: components)

    for directory in searchDirectories {
      let contents = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
      for appURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
      where appURL.pathExtension == "app" {
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID.hasPrefix(bundleIDPrefix),
              let manifest = info["Manifest"] as? [String: Any],
              let startURLString = manifest["start_url"] as? String,
              let start = URLComponents(string: startURLString) else { continue }
        if Self.origin(of: start) == origin { return appURL }
      }
    }
    return nil
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

  /// The scheme://host:port identity of a URL, with every host that names
  /// this machine folded together: `localhost`, its loopback spellings, and
  /// its current LAN address. The menu builds its URL from the LAN IP while a
  /// web app installed from a `localhost` URL keeps that spelling, and both
  /// name the same server. Hosts compare case-insensitively per RFC 3986.
  private static func origin(of components: URLComponents) -> String {
    let scheme = components.scheme ?? "http"
    let port = components.port ?? (scheme == "https" ? 443 : 80)
    let host = (components.host ?? "").lowercased()
    let local = host == "localhost" || host == "127.0.0.1"
      || host == "::1" || host == "[::1]"
      || host == LocalNetwork.ipAddress()?.lowercased()
    return "\(scheme)://\(local ? "localhost" : host):\(port)"
  }
}
