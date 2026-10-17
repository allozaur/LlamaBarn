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
      // Async like `openInBrowser`: a cold template launch must not hold the
      // main thread. A detected bundle isn't guaranteed launchable (a copy
      // from another Mac reads as damaged; LaunchServices can refuse the
      // registration), so the WebUI URL rides along and the browser takes
      // over when the launch fails -- the click must still open something.
      SafariWebApp.launch(app, fallbackURL: url)
      dismissMenu()
      return
    }
    openInBrowser(url)
  }

  /// Opens `url` in the installed Safari Web App and closes the menu: the
  /// link is delivered as an open-URL event, which the app's host turns into
  /// webview navigation -- the one way a web app takes a URL other than its
  /// pinned start URL, so the webui reads the same query a browser visit
  /// would. Falls back to the browser when the link can't be delivered (see
  /// `SafariWebApp.open`).
  func openInWebApp(_ url: URL, app: URL) {
    guard SafariWebApp.open(url, inWebAppAt: app) else {
      openInBrowser(url)
      return
    }
    dismissMenu()
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
