import AppKit

/// Minimal base class for interactive menu items.
/// Provides a shared background container with selection highlight and a content area for subclasses.
///
/// Uses NSTrackingArea to handle hover events for highlighting.
/// This is necessary because we use disabled NSMenuItems (to prevent menu closing on click),
/// which do not receive standard NSMenu highlighting events.
class ItemView: NSView {
  let backgroundView = NSView()
  let contentView = NSView()

  private var trackingArea: NSTrackingArea?
  private(set) var isHighlighted = false

  // MARK: - Customization hooks

  /// Override to disable selection highlight based on dynamic state (e.g., only when server is running).
  var highlightEnabled: Bool { true }
  /// Called whenever the selection highlight changes.
  func highlightDidChange(_ highlighted: Bool) {}

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    setupContainers()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setupContainers() {
    wantsLayer = true
    backgroundView.wantsLayer = true

    addSubview(backgroundView)
    backgroundView.addSubview(contentView)

    backgroundView.pinToSuperview(
      leading: Layout.outerHorizontalPadding,
      trailing: Layout.outerHorizontalPadding
    )
    contentView.pinToSuperview(
      top: Layout.verticalPadding,
      leading: Layout.innerHorizontalPadding,
      trailing: Layout.innerHorizontalPadding,
      bottom: Layout.verticalPadding
    )
  }

  // MARK: - Highlight handling

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
    trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(trackingArea!)

    // Sync highlight to the actual mouse position. NSTrackingArea doesn't fire
    // mouseEntered if the area is created while the mouse is already inside, and
    // it doesn't fire mouseExited when the view moves out from under a stationary
    // cursor (e.g. scrolling a tall menu) -- both cases land here instead, since
    // scrolling re-invokes updateTrackingAreas. Setting both directions keeps at
    // most one row highlighted while scrolling.
    if let window = window {
      let mouseLocation = window.mouseLocationOutsideOfEventStream
      let localPoint = convert(mouseLocation, from: nil)
      setHighlight(bounds.contains(localPoint))
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    setHighlight(true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    setHighlight(false)
  }

  /// Programmatically set selection highlight.
  func setHighlight(_ highlighted: Bool) {
    let shouldHighlight = highlighted && highlightEnabled
    guard shouldHighlight != isHighlighted else { return }
    isHighlighted = shouldHighlight
    backgroundView.setHighlight(shouldHighlight, cornerRadius: Layout.cornerRadius)
    highlightDidChange(shouldHighlight)
  }

  // MARK: - Helpers

  /// Opens a URL in the default browser and closes the menu. Use this for any
  /// link handler rather than calling `NSWorkspace` directly: the menu won't
  /// close on its own (see `dismissMenu`), and pairing the two here keeps a new
  /// link from silently forgetting to dismiss.
  func openInBrowser(_ url: URL) {
    // Async on purpose. The synchronous `open(_:)` sends LaunchServices a
    // sync XPC message and sleeps until it replies, which doesn't happen until
    // the handler app is up -- a cold browser start blocks the main thread long
    // enough to be reported as an app hang. Nothing here needs the result, so
    // there's no reason to wait for it.
    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
    dismissMenu()
  }

  /// Opens the WebUI as a Safari Web App when the user has installed one for
  /// this server, otherwise falls back to the default browser.
  func openChat(_ url: URL) {
    if let app = SafariWebApp.installed(matching: url) {
      openWebApp(app)
      return
    }
    openInBrowser(url)
  }

  /// Opens an installed Safari Web App bundle and closes the menu. Async like
  /// `openInBrowser`: a cold template launch must not hold the main thread.
  func openWebApp(_ appURL: URL) {
    NSWorkspace.shared.open(appURL, configuration: NSWorkspace.OpenConfiguration())
    dismissMenu()
  }

  /// Opens `url` in the installed Safari Web App: the link is delivered as an
  /// open-URL event, which the app's host turns into webview navigation --
  /// the one way a web app takes a URL other than its pinned start URL, so
  /// the webui reads the same query a browser visit would.
  func openInWebApp(_ url: URL, app: URL) {
    // The web app lives on the same-machine host (what installs pin, and
    // what the server always answers on); the LAN address the menu shows
    // would be a different origin to navigate to.
    var link = URLComponents(url: url, resolvingAgainstBaseURL: false)
    link?.host = LlamaServer.localHost
    guard let linkURL = link?.url else {
      openInBrowser(url)
      return
    }
    Self.navigateWebApp(to: linkURL, app: app, bundleID: SafariWebApp.bundleIdentifier(of: app))
    dismissMenu()
  }

  /// Gets the web app showing `url` -- launching (or activating) it first,
  /// then delivering the link.
  ///
  /// The delivery is split because a cold start swallows the event: it lands
  /// during launch, before there is a webview to navigate, and the app stays
  /// on its pinned start URL. Once the process is up and its page under way,
  /// the same event navigates. An app that is already running gets the event
  /// right away.
  private static func navigateWebApp(to url: URL, app: URL, bundleID: String?) {
    let running = bundleID != nil && NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == bundleID
    }

    Task {
      if !running {
        NSWorkspace.shared.open(app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        // Wait for the process, then for the page it opens to be under way.
        if let bundleID {
          for _ in 0..<20 where !NSWorkspace.shared.runningApplications.contains(
            where: { $0.bundleIdentifier == bundleID }) {
            try? await Task.sleep(nanoseconds: 250_000_000)
          }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
      NSWorkspace.shared.open(
        [url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
  }

  /// Dismisses the enclosing menu. Our menu items are disabled so clicks don't
  /// auto-close the menu (see the class note), which means a handler that
  /// navigates away has to close the menu itself. Without this the menu lingers;
  /// it only appeared to close before by luck, when launching the browser
  /// happened to deactivate the app.
  ///
  /// Closes without the fade animation -- the link handlers all switch to
  /// another app (the browser), so an instant close reads cleaner than watching
  /// the menu fade out while that app comes forward.
  func dismissMenu() {
    enclosingMenuItem?.menu?.cancelTrackingWithoutAnimation()
  }

  /// Helper to add a click gesture recognizer to a view (defaults to self).
  @discardableResult
  func addGesture(
    to view: NSView? = nil,
    action: Selector,
    buttonMask: Int = 0x1
  ) -> NSClickGestureRecognizer {
    let targetView = view ?? self
    let click = NSClickGestureRecognizer(target: self, action: action)
    click.buttonMask = buttonMask
    targetView.addGestureRecognizer(click)
    return click
  }
}
