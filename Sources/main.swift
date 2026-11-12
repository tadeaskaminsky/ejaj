import Cocoa
import SwiftUI

final class QuickPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var status: NSStatusItem!; var popover: QuickPanel!; var outsideMonitor: Any?; var localMonitor: Any?;
  var window: NSWindow?; var store: UsageStore!
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    store = UsageStore()
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = status.button {
      button.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "EJAJ — AI usage")
      button.image?.isTemplate = true; button.imagePosition = .imageOnly; button.title = "";
      button.font = NSFont.systemFont(ofSize: 11, weight: .semibold); button.target = self;
      button.action = #selector(togglePopover); button.sendAction(on: [.leftMouseUp, .rightMouseUp]);
      button.toolTip = "EJAJ · ChatGPT and Claude"
    }
    popover = QuickPanel(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 362), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    popover.title = "EJAJ · quick view"; popover.isFloatingPanel = true; popover.level = .popUpMenu;
    popover.hidesOnDeactivate = false; popover.isReleasedWhenClosed = false; popover.isOpaque = false;
    popover.backgroundColor = .clear; popover.hasShadow = true;
    popover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let host = NSHostingView(
      rootView: QuickView(store: store, open: { [weak self] in self?.openDashboard() }, quit: { NSApp.terminate(nil) })
        .environment(\.locale, Locale(identifier: "en_US")).frame(maxHeight: .infinity, alignment: .top).background(
          canvas
        ).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(
          RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12))))
    host.sizingOptions = []; popover.contentView = host
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      self?.popover.orderOut(nil)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      if let self, self.popover.isVisible, event.window != self.popover, event.window != self.status.button?.window {
        self.popover.orderOut(nil)
      }
      return event
    }
    let menu = NSMenu(); let root = NSMenuItem(); let appMenu = NSMenu();
    appMenu.addItem(withTitle: "About EJAJ", action: #selector(about), keyEquivalent: "");
    appMenu.addItem(withTitle: "Open dashboard", action: #selector(openDashboard), keyEquivalent: "o");
    appMenu.addItem(withTitle: "Quick view", action: #selector(togglePopover), keyEquivalent: "u");
    appMenu.addItem(.separator());
    appMenu.addItem(withTitle: "Quit EJAJ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q");
    root.submenu = appMenu; menu.addItem(root)
    let edit = NSMenuItem(); let editMenu = NSMenu(title: "Edit");
    for (title, action, key) in [("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
      editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
    }; edit.submenu = editMenu; menu.addItem(edit); NSApp.mainMenu = menu
    store.onChange = { [weak self] in
      guard let self else { return }; let r = self.store.filtered(days: 1);
      self.status.button?.toolTip =
        "EJAJ · today \(exact(self.store.total(r))) tokens · API estimate \(self.store.moneyWithUSD(self.store.cost(r)))"
    }
    store.start()
    if !UserDefaults.standard.bool(forKey: "hasOpenedEJAJ") {
      UserDefaults.standard.set(true, forKey: "hasOpenedEJAJ"); openDashboard()
    }
  }
  @objc func about() {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "EJAJ",
      .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
    ]); NSApp.activate(ignoringOtherApps: true)
  }
  @objc func togglePopover() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      let m = NSMenu(); let today = store.filtered(days: 1)
      let summary = m.addItem(
        withTitle: "Today \(store.moneyWithUSD(store.cost(today))) · \(exact(store.total(today))) tokens", action: nil,
        keyEquivalent: "");
      summary.isEnabled = false
      m.addItem(.separator())
      m.addItem(withTitle: "Open EJAJ", action: #selector(openDashboard), keyEquivalent: "").target = self
      m.addItem(withTitle: "Refresh data", action: #selector(refresh), keyEquivalent: "").target = self
      let archive = m.addItem(
        withTitle: store.archiving ? "Archiving…" : "Archive to GitHub", action: #selector(archive),
        keyEquivalent: "");
      archive.target = self; archive.isEnabled = !store.archiving
      m.addItem(.separator())
      let login = m.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
      login.target = self; login.state = store.launchAtLogin ? .on : .off
      m.addItem(.separator());
      m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); status.menu = m;
      status.button?.performClick(nil); status.menu = nil; return
    }
    if popover.isVisible {
      popover.orderOut(nil)
    } else if let button = status.button, let barWindow = button.window {
      let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
      let screen = barWindow.screen ?? NSScreen.main!
      let available = screen.visibleFrame
      // Keep the whole panel below both the visible menu bar and the display cutout.
      let safeTop = min(available.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
      let panelTop = min(anchor.minY, safeTop) - 6
      // 362 fits the USD line under the euro figure and a two-line verdict.
      let height = min(CGFloat(362), max(1, panelTop - available.minY - 4))
      let width: CGFloat = 340
      let x = min(max(anchor.midX - width / 2, available.minX + 6), available.maxX - width - 6)
      // Anchor below the safe area; never overlap a MacBook notch.
      let y = panelTop - height
      popover.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
      popover.makeKeyAndOrderFront(nil)
    }
  }
  @objc func refresh() { store.refresh() }
  @objc func archive() { store.archive() }
  @objc func toggleLogin() { store.launchAtLogin.toggle() }
  @objc func openDashboard() {
    popover?.orderOut(nil)
    // A window that is already up keeps its size. A minimized one comes back as it was.
    let fill = window.map { !$0.isVisible && !$0.isMiniaturized } ?? true
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      w.title = "EJAJ"; w.titlebarAppearsTransparent = true; w.backgroundColor = NSColor.windowBackgroundColor;
      w.contentView = NSHostingView(
        rootView: Dashboard(store: store).environment(\.locale, Locale(identifier: "en_US")));
      w.minSize = NSSize(width: 880, height: 560); w.isReleasedWhenClosed = false; w.delegate = self; window = w
    }
    // Open filling the screen between the menu bar and the Dock, on the display the click came from. Zooming
    // from a smaller frame leaves AppKit that frame to return to, so a title-bar double-click shrinks the
    // window to the size it last had (1000 x 760 the first time) instead of 20 pt off the full screen.
    if fill, let w = window {
      // NSMouseInRect counts the top pixel row, where the pointer sits after a click on the menu bar.
      let mouse = NSEvent.mouseLocation
      if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
        let v = screen.visibleFrame
        let last = w.isZoomed ? NSSize(width: 1000, height: 760) : w.frame.size
        if w.isZoomed { w.zoom(nil) }  // forget the frame an earlier open left to return to
        let size = NSSize(width: min(last.width, v.width), height: min(last.height, v.height))
        w.setFrame(
          NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height),
          display: false)
        if !w.isZoomed { w.zoom(nil) }
      }
    }
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows && !popover.isVisible { openDashboard() }; return true
  }
}
func makeIcon(_ path: String) {
  let size = NSSize(width: 1024, height: 1024);
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { return }; NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context; NSColor.clear.setFill();
  NSRect(origin: .zero, size: size).fill(); let rect = NSRect(x: 40, y: 40, width: 944, height: 944);
  NSColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1).setFill();
  NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220).fill(); let line = NSBezierPath();
  line.move(to: NSPoint(x: 210, y: 500)); line.line(to: NSPoint(x: 350, y: 500));
  line.line(to: NSPoint(x: 435, y: 715)); line.line(to: NSPoint(x: 565, y: 310));
  line.line(to: NSPoint(x: 670, y: 520)); line.line(to: NSPoint(x: 815, y: 520)); line.lineWidth = 47;
  line.lineCapStyle = .round; line.lineJoinStyle = .round;
  NSColor(red: 0.48, green: 0.75, blue: 0.96, alpha: 1).setStroke(); line.stroke();
  NSColor(red: 0.94, green: 0.63, blue: 0.39, alpha: 1).setFill();
  NSBezierPath(ovalIn: NSRect(x: 760, y: 712, width: 67, height: 67)).fill(); NSGraphicsContext.restoreGraphicsState();
  if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
}
if CommandLine.arguments.contains("--snapshot") {
  // pricing.json moves long-context thresholds, which decide the rows' tiers, so load it as the app does.
  Pricing.load()
  let result = Collector().collect(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys];
  let data = try encoder.encode(result);
  if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
  } else {
    FileHandle.standardOutput.write(data)
  }
} else if CommandLine.arguments.contains("--self-update") {
  // The update the dashboard offers, without the window: checks GitHub (or EJAJ_UPDATE_FEED) and installs a newer
  // release over this bundle. The swap starts once this process has exited.
  // The swap waits for this process only, so a dashboard running from the same bundle would be swapped under it.
  let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .filter { $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
  if !others.isEmpty { print("Quit the running EJAJ first: it runs from this bundle"); exit(1) }
  let done = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var status: Int32 = 1
  Task.detached {
    switch await Updater.check() {
    case .success(let release?):
      do {
        try await Updater.install(release); print("installing EJAJ \(release.version)"); status = 0
      } catch {
        print((error as? UpdateError)?.message ?? error.localizedDescription)
      }
    case .success(nil): print("EJAJ \(Updater.currentVersion) is the latest version"); status = 0
    case .failure(let e): print(e.message)
    }
    done.signal()
  }
  done.wait()
  exit(status)
} else if let i = CommandLine.arguments.firstIndex(of: "--icon"), CommandLine.arguments.count > i + 1 {
  makeIcon(CommandLine.arguments[i + 1])
} else {
  MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate(); application.delegate = delegate
    application.run()
  }
}
