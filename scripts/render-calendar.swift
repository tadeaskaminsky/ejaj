import Cocoa
import SwiftUI

// Renders the dashboard's calendar panel to a PNG from the cached history
// (~/Library/Application Support/EJAJ/history.json), without opening a window.
// Built and run by scripts/render-calendar.sh.
@main struct RenderCalendar {
  @MainActor static func main() {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    let out = args.count > 1 ? args[1] : "build/calendar.png"
    let width = args.count > 2 ? Double(args[2]) ?? 880 : 880
    let store = UsageStore()
    let view = CalendarPanel(store: store, costMode: false).padding(20).frame(width: width).background(canvas)
      .foregroundStyle(ink).environment(\.colorScheme, store.colorScheme ?? .dark)
    let renderer = ImageRenderer(content: view); renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { fatalError("render failed") }
    try! png.write(to: URL(fileURLWithPath: out))
    print("rendered \(out) (\(store.dataset?.rows.count ?? 0) cached rows)")
  }
}
