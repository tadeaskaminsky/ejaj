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
    // A third argument shows the plan banner: "plan" with sample numbers, "signedout" with the sign-in note,
    // "live" with the real numbers.
    // Without it the banner stays hidden, as in the app before the first read.
    switch args.count > 3 ? args[3] : "" {
    case "plan":
      let reset = Date().addingTimeInterval(53_000)
      store.plan = PlanLimits(
        fiveHour: PlanWindow(label: "5-hour", used: 32, resetsAt: Date().addingTimeInterval(7_200)),
        weekly: PlanWindow(label: "Weekly", used: 76, resetsAt: reset),
        models: [PlanWindow(label: "Fable", used: 68, resetsAt: reset)])
      store.planState = .ok
    case "signedout": store.planState = .signedOut
    case "live":
      // The real numbers, read the way the app reads them (Claude Code's login from the Keychain).
      let done = DispatchSemaphore(value: 0); var result: Result<PlanLimits, PlanState> = .failure(.loading)
      Task.detached { result = await ClaudePlan.fetch(); done.signal() }
      done.wait()
      switch result {
      case .success(let limits): store.plan = limits; store.planState = .ok; store.planFetched = Date()
      case .failure(let state): store.planState = state
      }
    default: break
    }
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
