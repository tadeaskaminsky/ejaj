import SwiftUI
import Charts
import AppKit
import ServiceManagement

// Use the property wrapper with the command-line SDK.
typealias ViewState<Value> = SwiftUI.State<Value>

func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
  Color(
    nsColor: NSColor(
      name: nil,
      dynamicProvider: { appearance in
        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
      }))
}
let ink = adaptive((0.15, 0.18, 0.23), (0.91, 0.93, 0.96))
let muted = adaptive((0.51, 0.55, 0.61), (0.59, 0.64, 0.71))
let blue = Color(red: 0.38, green: 0.68, blue: 0.94)
let orange = Color(red: 0.88, green: 0.53, blue: 0.31)
let canvas = adaptive((0.96, 0.97, 0.985), (0.065, 0.075, 0.095))
let surface = adaptive((1, 1, 1), (0.105, 0.12, 0.145))
// The selected pill in a picker and pressed chips: one step above the panel.
let raised = adaptive((1, 1, 1), (0.21, 0.23, 0.275))
func providerColor(_ p: String) -> Color { p == "gpt" ? blue : orange }
func providerName(_ p: String) -> String { p == "gpt" ? "Codex" : "Claude" }

@MainActor final class UsageStore: ObservableObject {
  @Published var theme = UserDefaults.standard.string(forKey: "appearance") ?? "dark" {
    didSet { UserDefaults.standard.set(theme, forKey: "appearance"); applyTheme() }
  }
  var colorScheme: ColorScheme? { theme == "system" ? nil : (theme == "dark" ? .dark : .light) }
  func applyTheme() {
    NSApp.appearance = theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
  }
  @Published var currency = UserDefaults.standard.string(forKey: "currency") == "USD" ? "USD" : "EUR" {
    didSet { UserDefaults.standard.set(currency, forKey: "currency"); onChange?() }
  }
  // Registered with launchd through SMAppService; macOS lists it under Login Items.
  @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
    didSet {
      guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
      do {
        if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch { self.error = "Launch at login: \(error.localizedDescription)"; launchAtLogin = !launchAtLogin }
    }
  }
  // Opens pricing.json in the default editor, seeding it with the bundled prices on first use.
  func editPricing() {
    let url = Pricing.fileURL
    if !FileManager.default.fileExists(atPath: url.path) { try? Pricing.seedJSON().write(to: url, options: .atomic) }
    NSWorkspace.shared.open(url)
  }
  @Published var exchangeRate: ExchangeRate = {
    if let data = UserDefaults.standard.data(forKey: "exchangeRate"),
      let rate = try? JSONDecoder().decode(ExchangeRate.self, from: data), rate.usdPerEUR.isFinite, rate.usdPerEUR > 0
    {
      return rate
    }
    return .bundled
  }()
  private var lastExchangeAttempt = Date.distantPast
  func money(_ usd: Double) -> String { currencyAmount(exchangeRate.convert(usd, currency: currency), currency) }
  // Price lists and other tools count in dollars, so euros come with the USD figure next to them.
  func moneyWithUSD(_ usd: Double) -> String {
    currency == "EUR" ? money(usd) + " (" + currencyAmount(usd, "USD") + ")" : money(usd)
  }
  // The line under a big euro figure: the USD amount and the ECB rate it was converted at.
  func usdLine(_ usd: Double) -> String? {
    currency == "EUR" ? usdNote(usd, rate: exchangeRate) : nil
  }
  func refreshExchange() {
    guard Date().timeIntervalSince(lastExchangeAttempt) > 21600 else { return }; lastExchangeAttempt = Date()
    Task {
      do {
        let request = URLRequest(
          url: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
          let rate = ExchangeRate.parse(data)
        else { return }
        if rate.date >= exchangeRate.date {
          exchangeRate = rate;
          if let encoded = try? JSONEncoder().encode(rate) {
            UserDefaults.standard.set(encoded, forKey: "exchangeRate")
          }
        }
        onChange?()
      } catch {}
    }
  }
  // Claude plan limits (5-hour and weekly), read every 5 minutes. A failed read keeps the last numbers.
  @Published var plan: PlanLimits?
  @Published var planState = PlanState.loading
  @Published var planFetched: Date?
  private var lastPlanAttempt = Date.distantPast
  private var planBusy = false
  func refreshPlan(force: Bool = false) {
    guard !planBusy, force || Date().timeIntervalSince(lastPlanAttempt) >= 300 else { return }
    planBusy = true; lastPlanAttempt = Date()
    Task.detached(priority: .utility) {
      let result = await ClaudePlan.fetch()
      await MainActor.run { [weak self] in
        guard let self else { return }; self.planBusy = false
        switch result {
        case .success(let limits): self.plan = limits; self.planState = .ok; self.planFetched = Date()
        case .failure(let state):
          self.planState = state
          // A network or server error keeps the last numbers; a lost login or a non-subscription account clears them.
          if case .failed = state {} else { self.plan = nil; self.planFetched = nil }
        }
      }
    }
  }
  @Published var dataset: Dataset?
  @Published var busy = false
  // The last range is remembered between launches.
  @Published var days =
    [1, 7, 30, 90, 0].contains(UserDefaults.standard.integer(forKey: "range"))
      && UserDefaults.standard.object(forKey: "range") != nil ? UserDefaults.standard.integer(forKey: "range") : 30
  {
    didSet { UserDefaults.standard.set(days, forKey: "range") }
  }
  @Published var provider = "all"
  @Published var error: String?
  @Published var lastRefresh: Date?
  @Published var archiving = false
  @Published var archiveResult: (text: String, failed: Bool)?
  var timer: Timer?
  var onChange: (() -> Void)?
  let collector = Collector()
  let collectionQueue = DispatchQueue(label: "local.tadeas.ejaj.collection", qos: .utility)
  let cacheURL: URL
  init() {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EJAJ", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    cacheURL = dir.appendingPathComponent("history.json")
    Pricing.load()
    applyTheme()
    if let d = try? Data(contentsOf: cacheURL), let value = try? JSONDecoder().decode(Dataset.self, from: d) {
      dataset = value
    }
  }
  func start() {
    refresh();
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  func refresh() {
    refreshExchange(); refreshPlan()
    guard !busy else { return }; busy = true; error = nil
    Pricing.load()
    let collector = self.collector
    collectionQueue.async { [weak self] in
      let value = collector.collect()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }; self.busy = false
        if value.unreadable > 0 { self.error = "Some local files could not be read (\(value.unreadable))." }
        if let e = Pricing.fileError { self.error = e }
        if !value.rows.isEmpty || self.dataset == nil {
          self.dataset = value;
          if let json = try? JSONEncoder().encode(value) { try? json.write(to: self.cacheURL, options: .atomic) }
        } else {
          self.error = "No local usage logs found. Showing the last saved history."
        }
        self.lastRefresh = Date(); self.onChange?()
      }
    }
  }
  var rows: [UsageRow] { filtered(days: days, provider: provider) }
  // Count from in the gear menu: days before it are left out everywhere. nil counts every record.
  // A hand-edited value that isn't a real yyyy-MM-dd day would hide every row, so it counts as unset.
  @Published var countFrom = UserDefaults.standard.string(forKey: "countFrom").flatMap {
    dayFormatter.date(from: $0).map(dayFormatter.string) == $0 ? $0 : nil
  } {
    didSet { UserDefaults.standard.set(countFrom, forKey: "countFrom"); onChange?() }
  }
  var countedRows: [UsageRow] { counted(dataset?.rows ?? [], from: countFrom) }
  func filtered(days: Int, provider: String = "all") -> [UsageRow] {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!
    let start = dayFormatter.string(from: cal.date(byAdding: .day, value: 1 - days, to: Date())!);
    let end = dayFormatter.string(from: Date())
    return countedRows.filter {
      (days == 0 || $0.date >= start) && $0.date <= end && (provider == "all" || $0.provider == provider)
    }
  }
  func hourlyRows(on date: String, provider: String = "all") -> [UsageRow] {
    counted(dataset?.hourly ?? [], from: countFrom).filter {
      $0.date == date && (provider == "all" || $0.provider == provider)
    }
  }
  func hourlyToday(provider: String = "all") -> [UsageRow] {
    hourlyRows(on: dayFormatter.string(from: Date()), provider: provider)
  }
  // The sessions' usage in the chosen range and platform, after Count from. nil before the first scan that read them.
  func sessionTotals() -> [SessionTotal]? {
    guard let sessions = dataset?.sessions else { return nil }
    return totalsBySession(sessions, from: rangeStart, through: dayFormatter.string(from: Date()), provider: provider)
  }
  // The first day the range counts, after Count from. nil counts every day.
  var rangeStart: String? {
    let start = days == 0 ? nil : dayFormatter.string(from: bratislava.date(byAdding: .day, value: 1 - days, to: Date())!)
    return [start, countFrom].compactMap { $0 }.max()
  }
  // Today's part of every session on the chosen platform, whatever the range, for Running now.
  func todayTotals() -> [SessionTotal] {
    let today = dayFormatter.string(from: Date())
    return totalsBySession(dataset?.sessions ?? [], from: today, through: today, provider: provider)
  }
  // The hourly rows of the chosen range and platform, for the Patterns tab.
  func hourlyInRange() -> [UsageRow] {
    let from = rangeStart ?? "", today = dayFormatter.string(from: Date())
    return (dataset?.hourly ?? []).filter {
      $0.date >= from && $0.date <= today && (provider == "all" || $0.provider == provider)
    }
  }
  func allRows(provider: String = "all") -> [UsageRow] {
    countedRows.filter { provider == "all" || $0.provider == provider }
  }
  func total(_ rows: [UsageRow]) -> Int { rows.reduce(0) { $0 + $1.tokens } }
  func cost(_ rows: [UsageRow]) -> Double { rows.reduce(0) { $0 + ($1.cost ?? 0) } }
  // Runs ~/projects/token-archive/archive.py, which counts, commits (GPG-signed) and pushes.
  // Apps start with a bare PATH, so Homebrew comes first: its python3 reads .zst and git needs its gpg.
  func archive() {
    guard !archiving else { return }; archiving = true; archiveResult = nil
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "projects/token-archive/archive.py"
      ).path
      let result: (String, Bool)
      if !FileManager.default.fileExists(atPath: script) {
        result = ("Not found: ~/projects/token-archive/archive.py", true)
      } else {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env");
        p.arguments = ["python3", script]
        var env = ProcessInfo.processInfo.environment;
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin");
        p.environment = env
        p.standardOutput = pipe; p.standardError = pipe
        do {
          try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
          let output = String(decoding: data, as: UTF8.self)
          let total =
            output.range(of: "archive [0-9,]+", options: .regularExpression).map { output[$0].dropFirst(8) } ?? ""
          let last =
            output.split(separator: "\n").last.map(String.init) ?? "archive.py exited with \(p.terminationStatus)"
          result = p.terminationStatus == 0 ? ("Archived and pushed: \(total) tokens", false) : (last, true)
        } catch { result = (error.localizedDescription, true) }
      }
      DispatchQueue.main.async { [weak self] in
        self?.archiving = false; self?.archiveResult = result
      }
    }
  }
}
// A row of choices in a capsule track; the chosen one sits on a raised pill that slides between them. Drawn in
// SwiftUI rather than AppKit's segmented control, so it matches the panels and shows up in renders.
struct PillPicker<Value: Hashable>: View {
  @Binding var selection: Value
  var options: [(value: Value, label: String, dot: Color?)]
  var size: CGFloat = 12
  @Namespace private var pill
  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(options.enumerated()), id: \.offset) { _, option in
        let on = selection == option.value
        Button {
          withAnimation(.easeOut(duration: 0.18)) { selection = option.value }
        } label: {
          HStack(spacing: 6) {
            if let dot = option.dot { Dot(color: dot) }
            Text(option.label)
          }.font(.system(size: size, weight: on ? .semibold : .medium)).foregroundStyle(on ? ink : muted)
            .padding(.horizontal, size * 0.95).frame(height: size * 2.2)
            .background {
              if on {
                Capsule().fill(raised).shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                  .matchedGeometryEffect(id: "pill", in: pill)
              }
            }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
      }
    }.padding(3).background(Capsule().fill(ink.opacity(0.055)))
      .overlay(Capsule().strokeBorder(ink.opacity(0.06)))
  }
}
// Toolbar buttons: a soft rounded square that lights up under the pointer and darkens while pressed.
struct ChipStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { Chip(pressed: configuration.isPressed) { configuration.label } }
}
struct Chip<Label: View>: View {
  var pressed = false
  @ViewBuilder var label: Label
  @Environment(\.isEnabled) private var enabled
  @ViewState private var hovered = false
  var body: some View {
    label.font(.system(size: 12, weight: .medium)).foregroundStyle(enabled ? ink : muted)
      .padding(.horizontal, 9).frame(minWidth: 30, minHeight: 30)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(pressed ? raised : ink.opacity(hovered && enabled ? 0.1 : 0.055)))
      .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ink.opacity(0.07)))
      .contentShape(RoundedRectangle(cornerRadius: 9)).onHover { hovered = $0 }
  }
}
// The app's mark next to the tabs: the menu-bar waveform on the icon's dark tile.
struct Wordmark: View {
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "waveform.path").font(.system(size: 12, weight: .bold)).foregroundStyle(blue)
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(red: 0.12, green: 0.16, blue: 0.22)))
        .overlay(alignment: .topTrailing) { Circle().fill(orange).frame(width: 5, height: 5).offset(x: -4, y: 4) }
      Text("EJAJ").font(.system(size: 17, weight: .heavy, design: .rounded)).tracking(0.5)
    }
  }
}
struct Dot: View { var color: Color; var body: some View { Circle().fill(color).frame(width: 6, height: 6) } }
struct Panel<Content: View>: View {
  let content: Content; init(@ViewBuilder content: () -> Content) { self.content = content() };
  var body: some View {
    content.padding(20).background(surface, in: RoundedRectangle(cornerRadius: 14)).overlay(
      RoundedRectangle(cornerRadius: 14).strokeBorder(ink.opacity(0.06)))
  }
}
// One big number, split by provider underneath when both are shown, then by category.
struct Total: View {
  var title: String; var value: String; var subtitle: String? = nil; var parts: [(String, String)]
  var note: String? = nil; var details: [(String, String)] = []
  // Each platform's share of the value, drawn as one split bar under it. Left out with fewer than two.
  var shares: [(String, Double)] = []
  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(muted);
        Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-0.6).lineLimit(1)
          .minimumScaleFactor(0.5)
        if let subtitle {
          Text(subtitle).font(.system(size: 11).monospacedDigit()).foregroundStyle(muted).padding(.top, -6)
        }
        let total = shares.reduce(0) { $0 + max(0, $1.1) }
        if shares.count > 1, total > 0 {
          GeometryReader { g in
            HStack(spacing: 2) {
              ForEach(shares.filter { $0.1 > 0 }, id: \.0) { p in
                Capsule().fill(providerColor(p.0))
                  .frame(width: max(3, (g.size.width - 2 * Double(shares.count - 1)) * p.1 / total))
              }
            }
          }.frame(height: 5).padding(.vertical, 2)
        }
        ForEach(parts, id: \.0) { p in
          HStack(spacing: 7) {
            Dot(color: providerColor(p.0)); Text(providerName(p.0)).foregroundStyle(muted); Spacer(); Text(p.1)
          }.font(.system(size: 12).monospacedDigit())
        }
        if !details.isEmpty {
          Divider().opacity(0.5)
          ForEach(details, id: \.0) { d in
            HStack(spacing: 7) { Text(d.0).foregroundStyle(muted); Spacer(); Text(d.1) }
              .font(.system(size: 12).monospacedDigit())
          }
        }
        if let note { Text(note).font(.system(size: 11)).foregroundStyle(muted) }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
}
struct Daily: Identifiable {
  let date: Date; let provider: String; let tokens: Int; let cost: Double; var id: String { "\(date)|\(provider)" }
}
func chartData(_ rows: [UsageRow]) -> [Daily] {
  guard let first = rows.map({ $0.date }).min(), let last = rows.map({ $0.date }).max(),
    var d = dayFormatter.date(from: first), let end = dayFormatter.date(from: last)
  else { return [] }
  var map: [String: (Int, Double)] = [:];
  for r in rows {
    let key = r.date + r.provider; let v = map[key] ?? (0, 0); map[key] = (v.0 + r.tokens, v.1 + (r.cost ?? 0))
  }
  var result: [Daily] = []; var cal = Calendar(identifier: .gregorian);
  cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!
  while d <= end {
    for p in Set(rows.map { $0.provider }).sorted() {
      let v = map[dayFormatter.string(from: d) + p] ?? (0, 0);
      result.append(Daily(date: d, provider: p, tokens: v.0, cost: v.1))
    }; d = cal.date(byAdding: .day, value: 1, to: d)!
  }; return result
}
private let chartDateFormatter: DateFormatter = {
  let f = DateFormatter(); f.locale = Locale(identifier: "en_US");
  f.timeZone = TimeZone(identifier: "Europe/Bratislava"); f.dateFormat = "MMM d"; return f
}()
struct Trend: View {
  @ObservedObject var store: UsageStore; @ViewState private var hovered: Date? = nil
  var rows: [UsageRow]; var costMode = false
  func usage(_ r: Daily) -> Double {
    costMode ? store.exchangeRate.convert(r.cost, currency: store.currency) : Double(r.tokens)
  }
  var body: some View {
    let points = chartData(rows)
    let dates = Array(Set(points.map(\.date))).sorted()
    let step = max(1, Int(ceil(Double(max(0, dates.count - 1)) / 6)))
    let ticks = dates.enumerated().filter { $0.offset % step == 0 || $0.offset == dates.count - 1 }.map(\.element)
    let singleProviders = Set(Dictionary(grouping: points, by: \.provider).filter { $0.value.count == 1 }.keys)
    VStack(alignment: .leading, spacing: 10) {
      // Each platform is its own series with a fill that fades towards the axis. Monotone curves never dip
      // below zero between two days.
      Chart {
        ForEach(points) { r in
          let color = providerColor(r.provider)
          AreaMark(
            x: .value("Date", r.date), y: .value("Usage", usage(r)), series: .value("Platform", r.provider),
            stacking: .unstacked
          ).foregroundStyle(
            LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
          ).interpolationMethod(.monotone)
          LineMark(x: .value("Date", r.date), y: .value("Usage", usage(r)), series: .value("Platform", r.provider))
            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
          if singleProviders.contains(r.provider) {
            PointMark(x: .value("Date", r.date), y: .value("Usage", usage(r))).foregroundStyle(color).symbolSize(45)
          }
        }
        // The hovered day: a dashed rule and a ringed point on each line.
        if let date = hovered {
          RuleMark(x: .value("Date", date)).foregroundStyle(muted.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          ForEach(points.filter { $0.date == date }) { r in
            PointMark(x: .value("Date", r.date), y: .value("Usage", usage(r))).foregroundStyle(surface).symbolSize(150)
            PointMark(x: .value("Date", r.date), y: .value("Usage", usage(r)))
              .foregroundStyle(providerColor(r.provider)).symbolSize(55)
          }
        }
      }.chartLegend(.hidden).chartYScale(
        domain: .automatic(includesZero: true)
      ).chartXScale(range: .plotDimension(startPadding: 12, endPadding: 12)).chartXAxis {
        AxisMarks(values: ticks) { value in
          if let date = value.as(Date.self) {
            AxisValueLabel(
              anchor: date == dates.first ? .topLeading : (date == dates.last ? .topTrailing : .top),
              collisionResolution: .disabled
            ) { Text(chartDateFormatter.string(from: date)).font(.system(size: 9)) }
          }
        }
      }.chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(ink.opacity(0.09));
          AxisValueLabel {
            if let v = value.as(Double.self) {
              Text(costMode ? currencyAmount(v, store.currency) : compact(Int(v))).font(.system(size: 9))
                .foregroundStyle(muted)
            }
          }
        }
      }.chartOverlay { proxy in
        GeometryReader { geometry in
          let plot = geometry[proxy.plotAreaFrame]
          ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).contentShape(Rectangle()).onHover { inside in if !inside { hovered = nil } }
              .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                  guard plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX) else {
                    hovered = nil; return
                  }
                  hovered = dates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
                case .ended: hovered = nil
                }
              }
          }
        }
      }.frame(height: 220); detailBar(points: points)
    }
  }
  // Details sit under the chart so they never cover the hovered day.
  @ViewBuilder private func detailBar(points: [Daily]) -> some View {
    let date = hovered; let selected = date.map { d in points.filter { $0.date == d } } ?? []
    let sourceRows = date.map { d in rows.filter { $0.date == dayFormatter.string(from: d) } } ?? []
    HStack(spacing: 16) {
      if let date {
        Text(dayFormatter.string(from: date)).font(.system(size: 11, weight: .semibold))
        ForEach(selected) { p in
          HStack(spacing: 6) {
            Dot(color: providerColor(p.provider)); Text(providerName(p.provider)).foregroundStyle(muted);
            Text(store.money(p.cost)).monospacedDigit()
          }
        }
        Text("Total " + store.money(selected.reduce(0) { $0 + $1.cost })).bold()
        Spacer()
        Text(
          exact(selected.reduce(0) { $0 + $1.tokens }) + " tokens"
            + (sourceRows.contains { $0.cost == nil } ? " · excludes unpriced" : "")
        ).foregroundStyle(muted)
      } else {
        Spacer()
      }
    }.font(.system(size: 11)).lineLimit(1).frame(height: 20)
  }
}
struct HourPoint: Identifiable {
  let hour: Int; let provider: String; let tokens: Int; let cost: Double; var id: String { "\(hour)|\(provider)" }
}
func hourLabel(_ h: Int) -> String { String(format: "%02d:00", h) }
let hourLabels = (0..<24).map(hourLabel)
// Today, hour by hour: stacked bars per provider, details for the hovered hour underneath.
struct Hourly: View {
  @ObservedObject var store: UsageStore; @ViewState private var hovered: Int? = nil
  var rows: [UsageRow]; var costMode = false
  // Hour described under the chart when nothing is hovered; today's current hour unless the caller says otherwise.
  var fallbackHour: Int? = nil
  func usage(_ p: HourPoint) -> Double {
    costMode ? store.exchangeRate.convert(p.cost, currency: store.currency) : Double(p.tokens)
  }
  var points: [HourPoint] {
    var map: [String: (Int, Double)] = [:]
    for r in rows {
      let key = "\(r.hour ?? 0)|\(r.provider)"; let v = map[key] ?? (0, 0)
      map[key] = (v.0 + r.tokens, v.1 + (r.cost ?? 0))
    }
    return map.map { k, v in
      let parts = k.split(separator: "|")
      return HourPoint(hour: Int(parts[0]) ?? 0, provider: String(parts[1]), tokens: v.0, cost: v.1)
    }.sorted { ($0.hour, $0.provider) < ($1.hour, $1.provider) }
  }
  var body: some View {
    let points = points
    let currentHour = fallbackHour ?? bratislava.component(.hour, from: Date())
    VStack(alignment: .leading, spacing: 10) {
      // Hours are categories so every one of the 24 slots keeps its place, used or not.
      Chart(points) { p in
        BarMark(x: .value("Hour", hourLabel(p.hour)), y: .value("Usage", usage(p)), width: .ratio(0.62))
          .foregroundStyle(by: .value("Platform", p.provider)).cornerRadius(3)
          .opacity(hovered == nil || hovered == p.hour ? 1 : 0.4)
      }.chartForegroundStyleScale(["gpt": blue, "claude": orange]).chartLegend(.hidden)
        .chartXScale(domain: hourLabels).chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
          AxisMarks(values: stride(from: 0, through: 23, by: 3).map(hourLabel)) { value in
            if let label = value.as(String.self) {
              AxisValueLabel { Text(label).font(.system(size: 9)).foregroundStyle(muted) }
            }
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(ink.opacity(0.09))
            AxisValueLabel {
              if let v = value.as(Double.self) {
                Text(costMode ? currencyAmount(v, store.currency) : compact(Int(v))).font(.system(size: 9))
                  .foregroundStyle(muted)
              }
            }
          }
        }
        .chartOverlay { proxy in
          GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            Rectangle().fill(Color.clear).contentShape(Rectangle())
              .onHover { inside in if !inside { hovered = nil } }
              .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                  guard plot.contains(location), let label: String = proxy.value(atX: location.x - plot.minX),
                    let h = hourLabels.firstIndex(of: label)
                  else { hovered = nil; return }
                  hovered = h
                case .ended: hovered = nil
                }
              }
          }
        }.frame(height: 220)
      detailBar(points: points, fallback: currentHour)
    }
  }
  // Without a hover the bar describes the current hour.
  @ViewBuilder private func detailBar(points: [HourPoint], fallback: Int) -> some View {
    let hour = hovered ?? fallback; let selected = points.filter { $0.hour == hour }
    let unpriced = rows.contains { $0.hour == hour && $0.cost == nil }
    HStack(spacing: 16) {
      Text(String(format: "%02d:00–%02d:00", hour, hour + 1)).font(.system(size: 11, weight: .semibold))
      ForEach(selected) { p in
        HStack(spacing: 6) {
          Dot(color: providerColor(p.provider)); Text(providerName(p.provider)).foregroundStyle(muted)
          Text(store.money(p.cost)).monospacedDigit()
        }
      }
      Text("Total " + store.money(selected.reduce(0) { $0 + $1.cost })).bold()
      Spacer()
      Text(exact(selected.reduce(0) { $0 + $1.tokens }) + " tokens" + (unpriced ? " · excludes unpriced" : ""))
        .foregroundStyle(muted)
    }.font(.system(size: 11)).lineLimit(1).frame(height: 20)
  }
}
// Month grid with the API cost of every day; the chosen day is shown hour by hour underneath.
struct CalendarPanel: View {
  @ObservedObject var store: UsageStore
  var costMode: Bool
  @ViewState private var month = CalendarPanel.startOfMonth(Date())
  @ViewState private var selected = dayFormatter.string(from: Date())
  @ViewState private var hoveredDay: String?
  static func startOfMonth(_ d: Date) -> Date {
    bratislava.date(from: bratislava.dateComponents([.year, .month], from: d))!
  }
  private static let monthFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  private static let dayFormatterLong: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  struct DayTotal { var tokens = 0; var cost = 0.0; var unpriced = false; var byProvider: [String: Double] = [:] }
  var rows: [UsageRow] { store.allRows(provider: store.provider) }
  var totals: [String: DayTotal] {
    var byDay: [String: DayTotal] = [:]
    for r in rows {
      var t = byDay[r.date] ?? DayTotal(); t.tokens += r.tokens
      if let c = r.cost { t.cost += c; t.byProvider[r.provider, default: 0] += c } else { t.unpriced = true }
      byDay[r.date] = t
    }
    return byDay
  }
  var body: some View {
    let rows = rows, totals = totals
    let cal = bratislava, today = dayFormatter.string(from: Date())
    let monthKey = String(dayFormatter.string(from: month).prefix(7))
    let days = cal.range(of: .day, in: .month, for: month)!.count
    // Monday first: weekday 1 is Sunday.
    let leading = (cal.component(.weekday, from: month) + 5) % 7
    let maxCost = totals.filter { $0.key.hasPrefix(monthKey) }.map { $0.value.cost }.max() ?? 0
    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    Panel {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          Text("Calendar").font(.system(size: 14, weight: .semibold))
          Spacer()
          // Back to today, shown only once you have moved away from it.
          if monthKey != today.prefix(7) || selected != today {
            Button("Today") {
              month = CalendarPanel.startOfMonth(Date()); selected = today
            }.buttonStyle(ChipStyle())
          }
          Button {
            month = cal.date(byAdding: .month, value: -1, to: month)!
          } label: {
            Image(systemName: "chevron.left")
          }.buttonStyle(ChipStyle()).help("Previous month")
          Text(CalendarPanel.monthFormatter.string(from: month)).font(.system(size: 13, weight: .semibold))
            .frame(width: 124)
          Button {
            month = cal.date(byAdding: .month, value: 1, to: month)!
          } label: {
            Image(systemName: "chevron.right")
          }.buttonStyle(ChipStyle()).disabled(monthKey == today.prefix(7)).help("Next month")
        }
        PlanBanner(store: store)
        LazyVGrid(columns: columns, spacing: 6) {
          ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { d in
            Text(d).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
          }
          ForEach(-leading..<0, id: \.self) { _ in Color.clear.frame(height: 58) }
          ForEach(1...days, id: \.self) { d in
            let key = monthKey + String(format: "-%02d", d)
            dayCell(
              d, key: key, total: totals[key], maxCost: maxCost, today: today,
              top: maxCost > 0 && totals[key]?.cost == maxCost)
          }
        }
        if totals.contains(where: { $0.key.hasPrefix(monthKey) && $0.value.unpriced }) {
          Text("* includes tokens of unpriced models").font(.system(size: 10)).foregroundStyle(muted)
        }
        Divider().opacity(0.5)
        let costs = totals.mapValues(\.cost)
        dayDetail(
          selected, total: totals[selected], rows: rows.filter { $0.date == selected },
          average: dayAverage(costs, on: selected), week: weekAverage(costs, on: selected, today: today))
      }
    }
  }
  // One day of the grid. The fill deepens with the day's cost (square root, so cheap days still show), the
  // month's most expensive day gets a flame, and with both platforms shown a thin bar splits the cost between them.
  private func dayCell(_ d: Int, key: String, total: DayTotal?, maxCost: Double, today: String, top: Bool)
    -> some View
  {
    let ratio = maxCost > 0 ? (total?.cost ?? 0) / maxCost : 0
    let future = key > today, isToday = key == today, on = selected == key
    let fill: Color = future ? .clear : total == nil ? ink.opacity(0.035) : blue.opacity(0.08 + 0.52 * ratio.squareRoot())
    let parts = ["claude", "gpt"].compactMap { p in total?.byProvider[p].flatMap { $0 > 0 ? (p, $0) : nil } }
    return Button {
      selected = key
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
          Text(String(d)).font(.system(size: 11, weight: isToday ? .bold : .medium).monospacedDigit())
            .foregroundStyle(isToday ? canvas : future ? muted.opacity(0.45) : (total == nil ? muted : ink))
            .padding(.horizontal, isToday ? 5 : 0).frame(minWidth: isToday ? 20 : nil, minHeight: 18)
            .background { if isToday { Capsule().fill(ink) } }
          Spacer(minLength: 0)
          if top { Image(systemName: "flame.fill").font(.system(size: 9)).foregroundStyle(orange) }
        }
        Spacer(minLength: 0)
        if let total {
          Text(store.money(total.cost) + (total.unpriced ? "*" : ""))
            .font(.system(size: 12, weight: ratio > 0.6 ? .semibold : .regular, design: .rounded).monospacedDigit())
            .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        if store.provider == "all", parts.count > 1 {
          let sum = parts.reduce(0) { $0 + $1.1 }
          GeometryReader { g in
            HStack(spacing: 1.5) {
              ForEach(parts, id: \.0) { p in
                Capsule().fill(providerColor(p.0)).frame(width: max(2, (g.size.width - 1.5) * p.1 / sum))
              }
            }
          }.frame(height: 3).padding(.top, 4)
        }
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading).frame(height: 58)
        .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(
            on ? ink : future ? ink.opacity(0.07) : ink.opacity(hoveredDay == key ? 0.25 : 0),
            style: StrokeStyle(lineWidth: on ? 1.5 : 1, dash: future && !on ? [3, 3] : []))
        }
        .contentShape(Rectangle())
    }.buttonStyle(.plain).onHover { inside in hoveredDay = inside ? key : (hoveredDay == key ? nil : hoveredDay) }
  }
  private static let shortDay: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "d MMM"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  private func difference(_ amount: Double, _ percent: Int) -> String {
    let sign = amount >= 0 ? "+" : "−"
    return "\(sign)\(store.money(abs(amount))) (\(sign)\(abs(percent))%)"
  }
  @ViewBuilder private func dayDetail(
    _ date: String, total: DayTotal?, rows: [UsageRow], average: DayAverage?, week: WeekAverage?
  ) -> some View {
    let hourly = store.hourlyRows(on: date, provider: store.provider)
    let both = store.provider == "all"
    let title = dayFormatter.date(from: date).map(CalendarPanel.dayFormatterLong.string) ?? date
    HStack(spacing: 16) {
      Text(title).font(.system(size: 13, weight: .semibold))
      Spacer()
      if let total {
        if both {
          ForEach(["claude", "gpt"], id: \.self) { p in
            HStack(spacing: 6) {
              Dot(color: providerColor(p)); Text(providerName(p)).foregroundStyle(muted)
              Text(store.money(store.cost(rows.filter { $0.provider == p }))).monospacedDigit()
            }
          }
        }
        Text(store.money(total.cost)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        Text(exact(total.tokens) + " tokens").foregroundStyle(muted).monospacedDigit()
      }
    }.font(.system(size: 12))
    if total != nil, let a = average {
      AverageBanner(
        title: "Day", ratio: a.ratio, level: a.level,
        detail: difference(a.difference, a.percent) + " vs the \(a.basis)",
        trailing: (a.weekday.map { "Average \($0)" } ?? "30-day average") + ": " + store.money(a.average)
          + " · \(a.days) \(a.days == 1 ? "day" : "days")")
    }
    if let w = week {
      let start = dayFormatter.date(from: w.monday)!, end = bratislava.date(byAdding: .day, value: 6, to: start)!
      let sameMonth = bratislava.component(.month, from: start) == bratislava.component(.month, from: end)
      AverageBanner(
        title: "Week "
          + (sameMonth
            ? bratislava.component(.day, from: start).description + "–" + CalendarPanel.shortDay.string(from: end)
            : CalendarPanel.shortDay.string(from: start) + " – " + CalendarPanel.shortDay.string(from: end)),
        ratio: w.ratio, level: w.level,
        detail: store.money(w.cost) + ", " + difference(w.difference, w.percent) + " vs the average \(w.span)",
        trailing: "Average week: " + store.money(w.fullAverage) + " · \(w.weeks) \(w.weeks == 1 ? "week" : "weeks")")
    }
    if hourly.isEmpty {
      Text(rows.isEmpty ? "No usage on this day" : "No hourly data for this day yet, refresh to collect it")
        .font(.system(size: 12)).foregroundStyle(muted).frame(maxWidth: .infinity).frame(height: 120)
    } else {
      Hourly(
        store: store, rows: hourly, costMode: costMode, fallbackHour: hourly.compactMap(\.hour).max()
      ).id(date)
    }
  }
}
// One line under the calendar day: how a day or week compares with its average, coloured by the ratio.
struct AverageBanner: View {
  var title: String; var ratio: Double; var level: String; var detail: String; var trailing: String
  var body: some View {
    let color =
      ratio >= 1.1
      ? Color(red: 0.30, green: 0.74, blue: 0.45)
      : ratio >= 0.9 ? blue : ratio >= 0.5 ? orange : Color(red: 0.93, green: 0.33, blue: 0.33)
    HStack(spacing: 8) {
      Image(systemName: ratio >= 1.1 ? "arrow.up.right" : ratio >= 0.9 ? "equal.circle.fill" : "arrow.down.right")
        .frame(width: 14)
      Text(title).fontWeight(.semibold).foregroundStyle(ink)
      Text(level).fontWeight(.semibold)
      Text(detail).foregroundStyle(ink).monospacedDigit().layoutPriority(1)
      Spacer(minLength: 12)
      Text(trailing).foregroundStyle(muted).monospacedDigit()
    }.font(.system(size: 12)).foregroundStyle(color).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 8)
      .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
  }
}
// The Claude plan's weekly limit above the calendar: what is left, when it resets, and where the week is heading.
// Red when the week is on course to hit the limit, orange when it would leave a good part of it unused.
struct PlanBanner: View {
  @ObservedObject var store: UsageStore
  var now = Date()
  private static let resetFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  private static let red = Color(red: 0.93, green: 0.33, blue: 0.33)
  private func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
  var body: some View {
    // Numbers from before the weekly reset describe a week that is over, so they give way to a note.
    if let plan = store.plan, let week = plan.weekly, !(week.resetsAt.map { $0 <= now } ?? false) {
      let projected = week.resetsAt.flatMap { weekProjection(used: week.used, resetsAt: $0, now: now) }
      let color =
        projected.map { $0 >= 100 ? PlanBanner.red : $0 >= 85 ? blue : orange }
        ?? (week.used >= 90 ? PlanBanner.red : blue)
      HStack(spacing: 10) {
        Image(systemName: "gauge.with.dots.needle.67percent").frame(width: 14)
        Text("Claude week").fontWeight(.semibold).foregroundStyle(ink)
        Text(pct(100 - week.used) + " left").fontWeight(.semibold)
        // Drawn by hand: ProgressView is AppKit-backed and ImageRenderer leaves it blank in renders.
        Capsule().fill(color.opacity(0.25)).frame(width: 90, height: 6).overlay(alignment: .leading) {
          Capsule().fill(color).frame(width: 90 * week.used / 100, height: 6)
        }
        Text(pace(week, projected: projected)).foregroundStyle(ink).layoutPriority(1)
        Spacer(minLength: 12)
        Text(trailing(plan)).foregroundStyle(muted)
      }.font(.system(size: 12).monospacedDigit()).foregroundStyle(color).lineLimit(1).padding(.horizontal, 12)
        .padding(.vertical, 8).background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
        .help("Claude plan usage as Claude Code's /usage reports it, read every 5 minutes. Click to refresh.")
        .onTapGesture { store.refreshPlan(force: true) }
    } else if let note = note {
      HStack(spacing: 10) {
        Image(systemName: "gauge.with.dots.needle.0percent").frame(width: 14)
        Text("Claude week").fontWeight(.semibold)
        Text(note)
        Spacer(minLength: 0)
      }.font(.system(size: 12)).foregroundStyle(muted).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 8)
        .background(ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .onTapGesture { store.refreshPlan(force: true) }
    }
  }
  private var note: String? {
    if let reset = store.plan?.weekly?.resetsAt, reset <= now {
      return "The week reset " + PlanBanner.resetFormatter.string(from: reset) + ", waiting for new numbers"
        + (store.planState == .ok ? "" : " (" + stateText + ")")
    }
    switch store.planState {
    case .loading, .ok, .notSubscription: return nil
    case .signedOut: return "Sign in to Claude Code to see the limit: run claude in Terminal, then /login"
    case .failed(let message): return "Limit unavailable: " + message
    }
  }
  private var stateText: String {
    if case .failed(let message) = store.planState { return message }
    return store.planState == .signedOut ? "sign in to Claude Code" : "no data"
  }
  private func pace(_ week: PlanWindow, projected: Double?) -> String {
    var text = pct(week.used) + " used"
    // The API gives the reset as 05:59:59.555, so round to the minute: "resets Sat 07:00", not 06:59.
    if let reset = week.resetsAt {
      let minute = Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded() * 60)
      text += " · resets " + PlanBanner.resetFormatter.string(from: minute)
    }
    if week.used >= 100 { return text + " · limit reached" }
    guard let projected, let reset = week.resetsAt else { return text }
    if let out = weekRunsOut(used: week.used, resetsAt: reset, now: now) {
      return text + " · runs out ~" + PlanBanner.resetFormatter.string(from: out)
    }
    return text + " · on pace for " + pct(projected)
  }
  private func trailing(_ plan: PlanLimits) -> String {
    var parts = plan.models.map { "\($0.label) " + pct($0.used) }
    if let five = plan.fiveHour { parts.append("5-hour " + pct(five.used)) }
    // Old numbers say how old they are: after a failed read, or when no read has worked for 10 minutes.
    if let at = store.planFetched, store.planState != .ok || now.timeIntervalSince(at) > 600 {
      let sameDay = dayFormatter.string(from: at) == dayFormatter.string(from: now)
      parts.append("as of " + (sameDay ? PlanBanner.timeFormatter : PlanBanner.resetFormatter).string(from: at))
    }
    return parts.joined(separator: " · ")
  }
}
struct QuickView: View {
  @ObservedObject var store: UsageStore; var open: () -> Void; var quit: () -> Void
  var body: some View {
    let today = store.filtered(days: 1)
    VStack(alignment: .leading, spacing: 18) {
      Text("DNES SI PREJEBAL").font(.system(size: 24, weight: .heavy)).tracking(-0.4)
      VStack(alignment: .leading, spacing: 2) {
        Text(store.money(store.cost(today))).font(
          .system(size: 46, weight: .bold, design: .rounded)
        ).tracking(-1.2).lineLimit(1).minimumScaleFactor(0.5)
        if let usd = store.usdLine(store.cost(today)) {
          Text(usd).font(.system(size: 12).monospacedDigit()).foregroundStyle(muted)
        }
      }
      VStack(spacing: 10) {
        ForEach(["claude", "gpt"], id: \.self) { p in
          HStack {
            Dot(color: providerColor(p));
            Text(p == "gpt" ? "Codex" : "Claude").font(.system(size: 14, weight: .medium)); Spacer();
            Text(exact(store.total(today.filter { $0.provider == p })) + " tokenov").font(
              .system(size: 14, weight: .semibold, design: .rounded))
          }
        }
      }
      let v = dayVerdict(store.countedRows);
      HStack(spacing: 9) {
        Image(systemName: v.icon); Text(v.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
      }.font(.system(size: 12, weight: .semibold)).foregroundStyle(v.color).padding(.horizontal, 12).padding(
        .vertical, 9
      ).frame(maxWidth: .infinity, alignment: .leading).background(
        v.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
      Button(action: open) {
        HStack {
          Text("Dashboard"); Spacer(); Image(systemName: "arrow.right")
        }.font(.system(size: 13, weight: .medium)).foregroundStyle(ink).padding(.horizontal, 15).frame(height: 40)
          .background(blue.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
      }.buttonStyle(.plain).keyboardShortcut("o")
    }.padding(22).frame(width: 340).background(canvas).foregroundStyle(ink).preferredColorScheme(store.colorScheme)
  }
}
// Spending more is the goal here. Today's API cost against the same weekday over the last 12 weeks,
// falling back to the last 30 days when that weekday has no history yet.
func dayVerdict(_ rows: [UsageRow]) -> (text: String, icon: String, color: Color) {
  var cal = Calendar(identifier: .gregorian); cal.timeZone = dayFormatter.timeZone
  let today = dayFormatter.string(from: Date()), weekday = cal.component(.weekday, from: Date())
  func since(_ days: Int) -> String { dayFormatter.string(from: cal.date(byAdding: .day, value: -days, to: Date())!) }
  var byDay: [String: Double] = [:]; for r in rows { byDay[r.date, default: 0] += r.cost ?? 0 }
  let now = byDay[today] ?? 0
  let past = byDay.filter { $0.key < today && $0.value > 0 }
  let sameDay = past.filter {
    $0.key >= since(84) && dayFormatter.date(from: $0.key).map { cal.component(.weekday, from: $0) } == weekday
  }.map(\.value)
  let recent = past.filter { $0.key >= since(30) }.map(\.value)
  // Sunday=1 … Saturday=7: (nominative, dative)
  let names = [
    ("priemerná nedeľa", "priemernej nedeli"), ("priemerný pondelok", "priemernému pondelku"),
    ("priemerný utorok", "priemernému utorku"), ("priemerná streda", "priemernej strede"),
    ("priemerný štvrtok", "priemernému štvrtku"), ("priemerný piatok", "priemernému piatku"),
    ("priemerná sobota", "priemernej sobote"),
  ]
  let (like, against) =
    sameDay.isEmpty ? ("priemer", "priemeru") : (names[weekday - 1].0, "oproti " + names[weekday - 1].1)
  let green = Color(red: 0.30, green: 0.74, blue: 0.45), red = Color(red: 0.93, green: 0.33, blue: 0.33)
  if now <= 0 { return ("Ani cent? Hanba, choď niečo prejebať", "zzz", red) }
  if let record = past.values.max(), now > record { return ("NOVÝ REKORD! Najlepší deň vôbec", "trophy.fill", green) }
  let base = sameDay.isEmpty ? recent : sameDay
  guard !base.isEmpty else { return ("Zatiaľ nemám s čím porovnať", "questionmark.circle", muted) }
  let avg = base.reduce(0, +) / Double(base.count), ratio = now / avg, pct = Int((abs(ratio - 1) * 100).rounded())
  let vs = sameDay.isEmpty ? "oproti priemeru" : against
  if ratio >= 1.5 { return (String(format: "Popiči deň: %.1f× viac ", ratio) + vs, "flame.fill", green) }
  if ratio > 1.1 { return ("Masaker deň: +\(pct) % " + vs, "arrow.up.right", green) }
  if ratio >= 0.9 {
    return ((sameDay.isEmpty ? "Priemerný deň" : "Ako " + like) + ". Dá sa aj viac", "equal.circle.fill", blue)
  }
  if ratio >= 0.5 { return ("Napiču deň: −\(pct) % " + vs, "arrow.down.right", orange) }
  return ("Fess napiču deň: −\(pct) % " + vs + ", pridaj", "hand.thumbsdown.fill", red)
}
// Tokens of models without a known price are missing from every cost figure; say so next to the total.
func unpricedNote(_ rows: [UsageRow]) -> String? {
  let unpriced = rows.filter { $0.cost == nil }.reduce(0) { $0 + $1.tokens }
  return unpriced > 0 ? "Excludes \(exact(unpriced)) tokens of unpriced models" : nil
}
struct Dashboard: View {
  @ObservedObject var store: UsageStore
  @ViewState var costMode = false
  // The last tab is remembered; 1.11 called the Projects tab Analytics.
  @ViewState var tab: String = {
    let saved = UserDefaults.standard.string(forKey: "tab") ?? ""
    return saved == "analytics" ? "projects" : Dashboard.tabs.contains { $0.value == saved } ? saved : "overview"
  }()
  static let tabs: [(value: String, label: String, dot: Color?)] = [
    ("overview", "Overview", nil), ("calendar", "Calendar", nil), ("projects", "Projects", nil),
    ("sessions", "Sessions", nil), ("patterns", "Patterns", nil),
  ]
  private static let readableDay: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  static func readable(_ day: String) -> String { dayFormatter.date(from: day).map(readableDay.string) ?? day }
  var body: some View {
    let rows = store.rows; let both = store.provider == "all"
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 18) {
          Wordmark()
          PillPicker(selection: $tab, options: Dashboard.tabs, size: 13)
          Spacer()
          HStack(spacing: 8) {
            Button {
              store.refresh()
            } label: {
              Image(systemName: "arrow.clockwise").rotationEffect(.degrees(store.busy ? 360 : 0))
                .animation(store.busy ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.busy)
            }.buttonStyle(ChipStyle()).disabled(store.busy)
              .help("Read the logs again" + (store.lastRefresh.map { ", last read " + Stamp.time.string(from: $0) } ?? ""))
            settingsMenu
            Button {
              store.archive()
            } label: {
              Label(store.archiving ? "Archiving…" : "Archive", systemImage: "archivebox")
            }.buttonStyle(ChipStyle()).disabled(store.archiving).help("Archive the token counts to GitHub")
          }
        }.onChange(of: tab) { UserDefaults.standard.set($0, forKey: "tab") }
        HStack(spacing: 12) {
          PillPicker(
            selection: $store.provider,
            options: [("all", "All", nil), ("claude", "Claude", orange), ("gpt", "Codex", blue)])
          Spacer()
          // The calendar moves by month, so the range doesn't apply there; its day chart gets the metric instead.
          if tab == "calendar" {
            PillPicker(selection: $costMode, options: [(false, "Tokens", nil), (true, "Cost", nil)])
              .help("What the day's hourly chart measures")
          } else {
          PillPicker(
            selection: $store.days,
            options: [(1, "Today", nil), (7, "7 days", nil), (30, "30 days", nil), (90, "90 days", nil), (0, "All time", nil)])
          }
        }.frame(height: 32)
        if let error = store.error { Text(error).font(.system(size: 11)).foregroundStyle(orange) }
        if let r = store.archiveResult {
          Text(r.text).font(.system(size: 11)).foregroundStyle(r.failed ? orange : muted).lineLimit(2).textSelection(
            .enabled)
        }
        if store.days == 0, tab != "calendar", let from = store.countFrom {
          Text("All time starts on \(Dashboard.readable(from)), as Count from in the gear menu says.")
            .font(.system(size: 11)).foregroundStyle(muted)
        }
        switch tab {
        case "calendar": CalendarPanel(store: store, costMode: costMode)
        case "projects": ProjectsView(store: store)
        case "sessions": SessionsView(store: store)
        case "patterns": PatternsView(store: store)
        default: overview(rows: rows, both: both)
        }
      // No width cap: NSHostingView turns the content's maximum size into the window's, and a 1200 cap
      // stopped a title-bar double-click from filling the screen.
      }.padding(28).frame(maxWidth: .infinity)
    }.background(canvas)
      .foregroundStyle(ink).preferredColorScheme(store.colorScheme).frame(minWidth: 880, minHeight: 560)
  }
  // Currency, appearance, Count from, login item and prices. The chip is drawn around the menu, because a
  // borderless menu button ignores a styled label.
  private var settingsMenu: some View {
    Menu {
      Picker("Currency", selection: $store.currency) {
        Text("USD").tag("USD"); Text("EUR").tag("EUR")
      }
      .pickerStyle(.inline)
      Picker("Appearance", selection: $store.theme) {
        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
      }.pickerStyle(.inline)
      let all = store.dataset?.rows ?? [], starts = restarts(all)
      if !starts.isEmpty || store.countFrom != nil {
        Picker("Count from", selection: $store.countFrom) {
          Text("First record" + (all.map(\.date).min().map { ", " + Dashboard.readable($0) } ?? ""))
            .tag(String?.none)
          ForEach(starts, id: \.day) { s in
            Text("\(Dashboard.readable(s.day)), after \(s.idle) idle days").tag(String?.some(s.day))
          }
          if let from = store.countFrom, !starts.contains(where: { $0.day == from }) {
            Text(Dashboard.readable(from)).tag(String?.some(from))
          }
        }.pickerStyle(.inline)
      }
      Toggle("Launch at login", isOn: $store.launchAtLogin)
      Divider()
      Button("Edit prices (pricing.json)…") { store.editPricing() }
    } label: {
      Image(systemName: "gearshape")
    }.menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundStyle(ink)
      .frame(width: 30, height: 30).contentShape(Rectangle()).background(Chip { Color.clear.frame(width: 12, height: 12) }.allowsHitTesting(false))
      .help("Currency, appearance, Count from, login item, prices")
  }
  @ViewBuilder private func overview(rows: [UsageRow], both: Bool) -> some View {
          let split = breakdown(rows), cost = store.cost(rows)
          HStack(spacing: 16) {
            Total(
              title: "Tokens", value: exact(store.total(rows)),
              parts: both
                ? ["claude", "gpt"].map { p in (p, exact(store.total(rows.filter { $0.provider == p }))) } : [],
              details: tokenDetails(split),
              shares: both ? ["claude", "gpt"].map { p in (p, Double(store.total(rows.filter { $0.provider == p }))) } : [])
            Total(
              title: "API cost", value: store.money(cost), subtitle: store.usdLine(cost),
              parts: both
                ? ["claude", "gpt"].map { p in (p, store.money(store.cost(rows.filter { $0.provider == p }))) } : [],
              note: unpricedNote(rows), details: costDetails(split, store.money),
              shares: both ? ["claude", "gpt"].map { p in (p, store.cost(rows.filter { $0.provider == p })) } : [])
            // Measured against paying the input price for every token the cache read or wrote.
            let cache = cacheEffect(rows), without = cost + cache.net
            Total(
              title: "Cache saved", value: store.money(cache.net),
              subtitle: without > 0 ? percent(cache.net / without) + " off the bill" : nil, parts: [],
              note: unpricedNote(rows) ?? "Against paying the input price for every cached token",
              details: [
                ("Cheaper cache reads", store.money(cache.saved)), ("Dearer cache writes", "−" + store.money(cache.premium)),
                ("Bill without the cache", store.money(without)),
              ])
          }.fixedSize(horizontal: false, vertical: true)
          let hourly = store.hourlyToday(provider: store.provider)
          Panel {
            VStack(alignment: .leading, spacing: 14) {
              HStack(spacing: 16) {
                Text(store.days == 1 ? "Per hour" : "Per day").font(.system(size: 14, weight: .semibold))
                if both {
                  ForEach(["claude", "gpt"], id: \.self) { p in
                    HStack(spacing: 6) {
                      Dot(color: providerColor(p)); Text(providerName(p))
                    }.font(.system(size: 11)).foregroundStyle(muted)
                  }
                }
                Spacer()
                PillPicker(selection: $costMode, options: [(false, "Tokens", nil), (true, "Cost", nil)], size: 11)
              }
              if store.days == 1 {
                if hourly.isEmpty {
                  Text("No data yet").foregroundStyle(muted).frame(maxWidth: .infinity).frame(height: 250)
                } else {
                  Hourly(store: store, rows: hourly, costMode: costMode)
                }
              } else if rows.isEmpty {
                Text("No data").foregroundStyle(muted).frame(maxWidth: .infinity).frame(height: 250)
              } else {
                Trend(store: store, rows: rows, costMode: costMode)
              }
            }
          }
        ModelPanel(store: store)
  }
}
// One line per model over the selected range. Costs are summed per day so dated prices apply correctly.
struct ModelTotal: Identifiable {
  let provider: String; let model: String
  var tokens = 0; var prompt = 0; var cached = 0; var requests = 0; var cost: Double? = nil
  var id: String { provider + "|" + model }
  // Share of prompt tokens that were served from the cache.
  var cacheHit: Double? { prompt > 0 ? Double(cached) / Double(prompt) : nil }
}
struct ModelPanel: View {
  @ObservedObject var store: UsageStore
  // The rows to sum; nil uses the dashboard's range and platform.
  var rows: [UsageRow]? = nil
  @ViewState var sort = "tokens"; @ViewState var ascending = false
  @ViewState private var hovered: String?
  var models: [ModelTotal] {
    var m: [String: ModelTotal] = [:]
    for r in rows ?? store.rows {
      var x = m[r.provider + "|" + r.model] ?? ModelTotal(provider: r.provider, model: r.model)
      x.tokens += r.tokens; x.prompt += r.input + r.cached + r.write + r.write1h; x.cached += r.cached;
      x.requests += r.requests
      if let c = r.cost { x.cost = (x.cost ?? 0) + c }
      m[x.id] = x
    }
    return m.values.filter { $0.tokens > 0 }.sorted(by: order)
  }
  // Ties fall back to tokens; models without a value stay at the bottom in either direction.
  func order(_ a: ModelTotal, _ b: ModelTotal) -> Bool {
    func optional(_ x: Double?, _ y: Double?) -> Bool {
      guard let x, let y else { return x == nil && y == nil ? a.tokens > b.tokens : x != nil }
      return x == y ? a.tokens > b.tokens : (ascending ? x < y : x > y)
    }
    switch sort {
    case "model":
      let c = modelName(a.model).localizedStandardCompare(modelName(b.model))
      return c == .orderedSame ? a.tokens > b.tokens : (c == (ascending ? .orderedAscending : .orderedDescending))
    case "cost": return optional(a.cost, b.cost)
    case "cache": return optional(a.cacheHit, b.cacheHit)
    case "requests": return ascending ? a.requests < b.requests : a.requests > b.requests
    default: return ascending ? a.tokens < b.tokens : a.tokens > b.tokens
    }
  }
  // Clicking the active column flips the direction; a new column starts A→Z for names, largest first for numbers.
  func header(_ title: String, _ key: String) -> some View {
    Button {
      if sort == key { ascending.toggle() } else { sort = key; ascending = key == "model" }
    } label: {
      HStack(spacing: 3) {
        Text(title)
        if sort == key {
          Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
        }
      }.foregroundStyle(sort == key ? ink : muted).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  var body: some View {
    let list = models
    let totalCost = list.reduce(0) { $0 + ($1.cost ?? 0) }, maxCost = list.compactMap(\.cost).max() ?? 0
    Panel {
      VStack(alignment: .leading, spacing: 4) {
        Text("Models").font(.system(size: 14, weight: .semibold)).padding(.bottom, 6)
        HStack(spacing: 12) {
          header("Model", "model").frame(maxWidth: .infinity, alignment: .leading)
          header("Tokens", "tokens").frame(width: 130, alignment: .trailing)
          header("Cache hit", "cache").frame(width: 70, alignment: .trailing)
            .help("Share of prompt tokens served from the cache")
          header("Requests", "requests").frame(width: 70, alignment: .trailing)
          Text("Share of cost").foregroundStyle(muted).frame(width: 150, alignment: .leading)
          header("API cost", "cost").frame(width: 90, alignment: .trailing)
        }.font(.system(size: 10, weight: .medium)).foregroundStyle(muted).padding(.horizontal, 8).padding(.bottom, 2)
        ForEach(list) { r in
          HStack(spacing: 12) {
            HStack(spacing: 8) {
              Dot(color: providerColor(r.provider)); Text(modelName(r.model)).fontWeight(.medium).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(exact(r.tokens)).frame(width: 130, alignment: .trailing)
            Text(r.cacheHit.map(percent) ?? "–").foregroundStyle(r.cacheHit == nil ? muted : ink)
              .frame(width: 70, alignment: .trailing)
            Text(exact(r.requests)).frame(width: 70, alignment: .trailing)
            // The bar is scaled to the dearest model, the number is the model's share of the whole bill.
            HStack(spacing: 8) {
              GeometryReader { g in
                Capsule().fill(ink.opacity(0.07)).overlay(alignment: .leading) {
                  Capsule().fill(providerColor(r.provider))
                    .frame(width: maxCost > 0 && (r.cost ?? 0) > 0 ? max(3, g.size.width * (r.cost ?? 0) / maxCost) : 0)
                }
              }.frame(width: 100, height: 5)
              Text(totalCost > 0 && r.cost != nil ? share(Int(((r.cost ?? 0) * 100).rounded()), of: Int((totalCost * 100).rounded())) : "–")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(muted)
            }.frame(width: 150, alignment: .leading)
            Text(r.cost.map(store.money) ?? "–").foregroundStyle(r.cost == nil ? muted : ink)
              .frame(width: 90, alignment: .trailing)
          }.font(.system(size: 12).monospacedDigit()).padding(.horizontal, 8).frame(height: 32)
            .background(
              hovered == r.id ? ink.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .onHover { inside in hovered = inside ? r.id : (hovered == r.id ? nil : hovered) }
        }
        if list.isEmpty { Text("No data").font(.system(size: 12)).foregroundStyle(muted) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
// The Analytics tab: what each project cost in the chosen range and platform, then the sessions of one project,
// Shared pieces of the Projects, Sessions and Patterns tabs.
enum Stamp {
  static let short: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  static let long: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  static let time: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
}
func rangeText(_ days: Int) -> String {
  switch days {
  case 1: return "today"
  case 0: return "all time"
  default: return "last \(days) days"
  }
}
func sessionCount(_ n: Int) -> String { "\(n) \(n == 1 ? "session" : "sessions")" }
func sessionTitle(_ s: SessionUsage) -> String { s.title ?? "Untitled · " + String(s.session.prefix(8)) }
struct UnpricedFootnote: View {
  var body: some View {
    Text("* excludes tokens of unpriced models").font(.system(size: 10)).foregroundStyle(muted).padding(.top, 4)
  }
}
struct EmptyNote: View {
  var text: String
  var body: some View {
    Text(text).font(.system(size: 12)).foregroundStyle(muted).frame(maxWidth: .infinity).frame(height: 100)
  }
}
// A light bar whose length is the share of the largest figure in its list.
struct ShareBar: View {
  var ratio: Double
  var body: some View {
    GeometryReader { g in
      Capsule().fill(ink.opacity(0.85)).frame(width: max(4, g.size.width * min(1, max(0, ratio))), height: 6)
        .frame(maxHeight: .infinity)
    }.frame(height: 14)
  }
}
// A whole row that opens something, lit under the pointer.
struct ClickRow<Content: View>: View {
  var action: () -> Void
  @ViewBuilder var content: Content
  @ViewState private var hovered = false
  var body: some View {
    Button(action: action) {
      content.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? ink.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).onHover { hovered = $0 }
  }
}
// Back links: every step but the last is a link.
struct Breadcrumb: View {
  var trail: [(label: String, action: () -> Void)]
  var current: String
  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(trail.enumerated()), id: \.offset) { i, step in
        if i > 0 { Text("/").foregroundStyle(muted.opacity(0.6)) }
        Button(action: step.action) {
          HStack(spacing: 4) {
            if i == 0 { Image(systemName: "chevron.left") }
            Text(step.label)
          }
        }.buttonStyle(.plain).foregroundStyle(muted)
      }
      Text("/").foregroundStyle(muted.opacity(0.6))
      Text(current).lineLimit(1)
    }.font(.system(size: 12, weight: .medium))
  }
}
// A column title that sorts the table; a second click flips the order.
struct SortHeader: View {
  var title: String; var key: String
  @Binding var sort: String; @Binding var ascending: Bool
  var body: some View {
    Button {
      if sort == key { ascending.toggle() } else { sort = key; ascending = key == "session" || key == "project" }
    } label: {
      HStack(spacing: 3) {
        Text(title)
        if sort == key {
          Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
        }
      }.foregroundStyle(sort == key ? ink : muted).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}
// Sessions as a sortable table. In the Sessions tab it names each session's project; inside a project it draws
// cost bars instead.
struct SessionTable: View {
  @ObservedObject var store: UsageStore
  var sessions: [SessionTotal]
  var showProject = false
  var select: (String) -> Void
  @ViewState private var sort = "cost"
  @ViewState private var ascending = false
  private var sorted: [SessionTotal] {
    sessions.sorted { a, b in
      switch sort {
      case "session", "project":
        let x = sort == "project" ? a.session.project : sessionTitle(a.session)
        let y = sort == "project" ? b.session.project : sessionTitle(b.session)
        let c = x.localizedStandardCompare(y)
        return c == .orderedSame ? a.cost > b.cost : (c == (ascending ? .orderedAscending : .orderedDescending))
      case "started": return ascending ? a.session.start < b.session.start : a.session.start > b.session.start
      case "length":
        let x = a.session.end.timeIntervalSince(a.session.start), y = b.session.end.timeIntervalSince(b.session.start)
        return ascending ? x < y : x > y
      case "tokens": return ascending ? a.tokens < b.tokens : a.tokens > b.tokens
      default: return a.cost == b.cost ? a.tokens > b.tokens : (ascending ? a.cost < b.cost : a.cost > b.cost)
      }
    }
  }
  var body: some View {
    let list = sorted, maxCost = sessions.map(\.cost).max() ?? 0
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        SortHeader(title: "Session", key: "session", sort: $sort, ascending: $ascending)
          .frame(maxWidth: .infinity, alignment: .leading)
        if showProject {
          SortHeader(title: "Project", key: "project", sort: $sort, ascending: $ascending)
            .frame(width: 120, alignment: .leading)
        }
        SortHeader(title: "Started", key: "started", sort: $sort, ascending: $ascending)
          .frame(width: 96, alignment: .leading)
        SortHeader(title: "Length", key: "length", sort: $sort, ascending: $ascending)
          .frame(width: 76, alignment: .trailing)
        SortHeader(title: "Tokens", key: "tokens", sort: $sort, ascending: $ascending)
          .frame(width: 104, alignment: .trailing)
        if !showProject { Color.clear.frame(width: 90) }
        SortHeader(title: "API cost", key: "cost", sort: $sort, ascending: $ascending)
          .frame(width: 84, alignment: .trailing)
        Color.clear.frame(width: 8)
      }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 10)
      ForEach(list) { s in
        Divider().opacity(0.5)
        ClickRow(action: { select(s.id) }) {
          HStack(spacing: 12) {
            HStack(spacing: 8) {
              Dot(color: providerColor(s.session.provider))
              Text(sessionTitle(s.session)).foregroundStyle(s.session.title == nil ? muted : ink).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showProject {
              Text(s.session.project).foregroundStyle(muted).lineLimit(1).frame(width: 120, alignment: .leading)
            }
            Text(Stamp.short.string(from: s.session.start)).foregroundStyle(muted).frame(width: 96, alignment: .leading)
            Text(durationText(s.session.end.timeIntervalSince(s.session.start))).foregroundStyle(muted)
              .frame(width: 76, alignment: .trailing)
            Text(exact(s.tokens)).frame(width: 104, alignment: .trailing)
            if !showProject { ShareBar(ratio: maxCost > 0 ? s.cost / maxCost : 0).frame(width: 90) }
            Text(store.money(s.cost) + (s.unpriced ? "*" : "")).frame(width: 84, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(muted)
              .frame(width: 8)
          }.font(.system(size: 12).monospacedDigit())
        }.help(sessionTitle(s.session))
      }
      if sessions.contains(where: \.unpriced) { UnpricedFootnote() }
    }
  }
}
// One session: what it cost, its tokens, when it ran and the models it used.
struct SessionDetail: View {
  @ObservedObject var store: UsageStore
  var s: SessionTotal
  var body: some View {
    let split = breakdown(s.rows), info = s.session
    VStack(alignment: .leading, spacing: 4) {
      Text(sessionTitle(info)).font(.system(size: 20, weight: .semibold)).lineLimit(2)
      HStack(spacing: 8) {
        Dot(color: providerColor(info.provider))
        Text(info.provider == "gpt" ? "Codex" : "Claude Code")
        Text("·"); Text(info.project)
        Text("·"); Text(info.session).textSelection(.enabled)
      }.font(.system(size: 11).monospacedDigit()).foregroundStyle(muted)
    }
    HStack(spacing: 16) {
      Total(
        title: "API cost" + (store.days == 0 ? "" : " · " + rangeText(store.days)), value: store.money(s.cost),
        subtitle: store.usdLine(s.cost), parts: [], note: unpricedNote(s.rows), details: costDetails(split, store.money))
      Total(title: "Tokens", value: exact(s.tokens), parts: [], details: tokenDetails(split))
      Total(
        title: "Session", value: durationText(info.end.timeIntervalSince(info.start)), parts: [],
        details: [
          ("Started", Stamp.long.string(from: info.start)),
          ("Last request", Stamp.long.string(from: info.end)),
          ("Requests", exact(s.requests)),
          ("Folder", info.folder ?? info.project),
        ])
    }.fixedSize(horizontal: false, vertical: true)
    if store.days != 0, s.rows.count < info.rows.count {
      Text("Counts only the part of the session in the \(rangeText(store.days)). All time shows the whole session.")
        .font(.system(size: 11)).foregroundStyle(muted)
    }
    ModelPanel(store: store, rows: s.rows)
  }
}
struct NoSessions: View {
  @ObservedObject var store: UsageStore
  var body: some View {
    Panel { EmptyNote(text: store.busy ? "Reading sessions…" : "No session data yet. Refresh to read the sessions.") }
  }
}
// The Projects tab: what each project cost in the chosen range and platform, then one project's sessions, then
// one session. Projects come from the session's working folder (see projectOf).
struct ProjectsView: View {
  @ObservedObject var store: UsageStore
  @ViewState private var project: String?
  @ViewState private var session: String?
  init(store: UsageStore, project: String? = nil, session: String? = nil) {
    self.store = store; _project = ViewState(initialValue: project); _session = ViewState(initialValue: session)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let totals = store.sessionTotals() {
        let projects = totalsByProject(totals)
        if let p = projects.first(where: { $0.name == project }) {
          if let s = p.sessions.first(where: { $0.id == session }) {
            Breadcrumb(
              trail: [("Projects", { project = nil; session = nil }), (p.name, { session = nil })],
              current: sessionTitle(s.session))
            SessionDetail(store: store, s: s)
          } else {
            Breadcrumb(trail: [("Projects", { project = nil })], current: p.name)
            projectDetail(p)
          }
        } else {
          projectList(projects)
        }
      } else {
        NoSessions(store: store)
      }
    }
  }
  @ViewBuilder private func projectList(_ projects: [ProjectTotal]) -> some View {
    let maxCost = projects.map(\.cost).max() ?? 0
    let total = projects.reduce(0) { $0 + $1.cost }
    Panel {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "folder").foregroundStyle(muted)
          Text("Projects").font(.system(size: 14, weight: .semibold))
          Spacer()
          Text(
            "\(projects.count) \(projects.count == 1 ? "project" : "projects") · "
              + sessionCount(projects.reduce(0) { $0 + $1.sessions.count }) + " · " + store.money(total)
              + (projects.contains(where: \.unpriced) ? "*" : "") + " · " + rangeText(store.days)
          ).font(.system(size: 11).monospacedDigit()).foregroundStyle(muted)
        }.padding(.bottom, 6)
        if projects.isEmpty { EmptyNote(text: "No sessions in this range") }
        ForEach(projects) { p in
          ClickRow(action: { project = p.name; session = nil }) {
            HStack(spacing: 16) {
              VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(sessionCount(p.sessions.count) + " · " + compact(p.tokens) + " tokens")
                  .font(.system(size: 11).monospacedDigit()).foregroundStyle(muted).lineLimit(1)
              }.frame(width: 230, alignment: .leading)
              ShareBar(ratio: maxCost > 0 ? p.cost / maxCost : 0)
              Text(store.money(p.cost) + (p.unpriced ? "*" : "")).font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(muted).frame(width: 100, alignment: .trailing)
              Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            }
          }.help(p.folders.isEmpty ? p.name : p.folders.joined(separator: "\n"))
        }
        if projects.contains(where: \.unpriced) { UnpricedFootnote() }
      }
    }
  }
  private func providerParts(_ sessions: [SessionTotal], _ value: (SessionTotal) -> Double, _ text: (Double) -> String)
    -> [(String, String)]
  {
    guard Set(sessions.map(\.session.provider)).count > 1 else { return [] }
    return ["claude", "gpt"].map { p in
      (p, text(sessions.filter { $0.session.provider == p }.reduce(0) { $0 + value($1) }))
    }
  }
  @ViewBuilder private func projectDetail(_ p: ProjectTotal) -> some View {
    let rows = p.sessions.flatMap(\.rows), split = breakdown(rows)
    HStack(spacing: 16) {
      Total(
        title: "API cost · " + rangeText(store.days), value: store.money(p.cost), subtitle: store.usdLine(p.cost),
        parts: providerParts(p.sessions, \.cost, store.money), note: unpricedNote(rows),
        details: costDetails(split, store.money))
      Total(
        title: "Tokens", value: exact(p.tokens),
        parts: providerParts(p.sessions, { Double($0.tokens) }, { exact(Int($0)) }), details: tokenDetails(split))
      Total(
        title: "Sessions", value: exact(p.sessions.count), parts: [],
        details: [
          ("Requests", exact(p.sessions.reduce(0) { $0 + $1.requests })),
          ("Average session", store.money(p.cost / Double(max(1, p.sessions.count)))),
          ("Last activity", Stamp.short.string(from: p.last)),
        ] + p.folders.prefix(3).map { ("Folder", $0) })
    }.fixedSize(horizontal: false, vertical: true)
    Panel {
      VStack(alignment: .leading, spacing: 6) {
        Text("Sessions").font(.system(size: 14, weight: .semibold)).padding(.bottom, 4)
        SessionTable(store: store, sessions: p.sessions) { session = $0 }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
// The Sessions tab: what is running now, the range's record sessions, and every session across projects.
struct SessionsView: View {
  @ObservedObject var store: UsageStore
  @ViewState private var session: String?
  @ViewState private var search = ""
  var now = Date()
  init(store: UsageStore, session: String? = nil, now: Date = Date()) {
    self.store = store; _session = ViewState(initialValue: session); self.now = now
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let totals = store.sessionTotals() {
        if let s = totals.first(where: { $0.id == session }) {
          Breadcrumb(trail: [("Sessions", { session = nil })], current: sessionTitle(s.session))
          SessionDetail(store: store, s: s)
        } else {
          running(store.todayTotals(), all: totals)
          if !totals.isEmpty { records(totals) }
          all(totals)
        }
      } else {
        NoSessions(store: store)
      }
    }
  }
  // Sessions with a request in the last 10 minutes, with what they cost today and in total. This ignores the
  // range: a session resumed after days is still running now. There is no rate per hour, because the logs don't
  // say how long a session actually worked between its first and last request.
  @ViewBuilder private func running(_ today: [SessionTotal], all totals: [SessionTotal]) -> some View {
    let live = runningSessions(today, now: now)
    let todayKey = dayFormatter.string(from: now)
    Panel {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          LiveDot(on: !live.isEmpty)
          Text("Running now").font(.system(size: 14, weight: .semibold))
          Spacer()
          if live.isEmpty, let last = (today + totals).max(by: { $0.session.end < $1.session.end }) {
            Text(
              "Last request " + Stamp.short.string(from: last.session.end) + " in " + sessionTitle(last.session)
            ).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
          } else if !live.isEmpty {
            Text("Requests in the last 10 minutes").font(.system(size: 11)).foregroundStyle(muted)
          }
        }
        ForEach(live) { s in
          let started = dayFormatter.string(from: s.session.start) == todayKey
          let total = s.session.rows.reduce(0) { $0 + ($1.cost ?? 0) }
          ClickRow(action: { session = s.id }) {
            HStack(spacing: 14) {
              Dot(color: providerColor(s.session.provider))
              VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(s.session)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(
                  s.session.project + " · since "
                    + (started ? Stamp.time : Stamp.short).string(from: s.session.start)
                )
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(muted).lineLimit(1)
              }.frame(maxWidth: .infinity, alignment: .leading)
              VStack(alignment: .trailing, spacing: 2) {
                Text(store.money(s.cost) + " today")
                  .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                if !started { Text(store.money(total) + " in total").font(.system(size: 11).monospacedDigit()).foregroundStyle(muted) }
              }
              Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            }
          }
        }
      }
    }
  }
  // The range's record sessions; each opens the session. No "longest": a session resumed weeks later spans weeks
  // without running for them, and the logs don't say how long it actually worked.
  @ViewBuilder private func records(_ totals: [SessionTotal]) -> some View {
    let dearest = totals.max { $0.cost < $1.cost }!
    let busiest = totals.max { $0.requests < $1.requests }!
    let biggest = totals.max { $0.tokens < $1.tokens }!
    HStack(spacing: 16) {
      record("Most expensive", icon: "flame.fill", value: store.money(dearest.cost), dearest)
      record("Most requests", icon: "arrow.left.arrow.right", value: exact(busiest.requests), busiest)
      record("Most tokens", icon: "square.stack.3d.up.fill", value: compact(biggest.tokens), biggest)
    }.fixedSize(horizontal: false, vertical: true)
  }
  private func record(_ title: String, icon: String, value: String, _ s: SessionTotal) -> some View {
    Button {
      session = s.id
    } label: {
      Panel {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(orange)
            Text(title).foregroundStyle(muted)
          }.font(.system(size: 12, weight: .medium))
          Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
          Text(sessionTitle(s.session)).font(.system(size: 12, weight: .medium)).lineLimit(1)
          Text(s.session.project + " · " + Stamp.short.string(from: s.session.start))
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(muted).lineLimit(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).help("Open this session")
  }
  @ViewBuilder private func all(_ totals: [SessionTotal]) -> some View {
    let query = search.trimmingCharacters(in: .whitespaces)
    let shown = query.isEmpty ? totals : totals.filter {
      sessionTitle($0.session).localizedCaseInsensitiveContains(query)
        || $0.session.project.localizedCaseInsensitiveContains(query)
    }
    Panel {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Text("All sessions").font(.system(size: 14, weight: .semibold))
          Text(sessionCount(shown.count) + " · " + store.money(shown.reduce(0) { $0 + $1.cost }) + " · "
            + rangeText(store.days)).font(.system(size: 11).monospacedDigit()).foregroundStyle(muted)
          Spacer()
          SearchField(text: $search, prompt: "Search titles and projects")
        }
        if shown.isEmpty {
          EmptyNote(text: query.isEmpty ? "No sessions in this range" : "No session matches “\(query)”")
        } else {
          SessionTable(store: store, sessions: shown, showProject: true) { session = $0 }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
// Green and breathing while something runs, grey otherwise.
struct LiveDot: View {
  var on: Bool
  @ViewState private var pulse = false
  var body: some View {
    Circle().fill(on ? Color(red: 0.30, green: 0.74, blue: 0.45) : muted.opacity(0.5)).frame(width: 8, height: 8)
      .overlay {
        if on {
          Circle().stroke(Color(red: 0.30, green: 0.74, blue: 0.45), lineWidth: 1.5).scaleEffect(pulse ? 2.2 : 1)
            .opacity(pulse ? 0 : 0.8)
        }
      }
      .onAppear { if on { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } } }
  }
}
struct SearchField: View {
  @Binding var text: String
  var prompt: String
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(muted)
      TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(muted)
        }.buttonStyle(.plain).help("Clear the search")
      }
    }.padding(.horizontal, 10).frame(width: 240, height: 30)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ink.opacity(0.055)))
      .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(ink.opacity(0.07)))
  }
}
// The Patterns tab: when in the week the money goes, as a weekday × hour heatmap with totals along both edges.
struct PatternsView: View {
  @ObservedObject var store: UsageStore
  @ViewState private var hovered: (day: Int, hour: Int)?
  private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  private static let longDays = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
  var body: some View {
    let rows = store.hourlyInRange()
    let grid = weekHourGrid(rows)
    let maxCell = grid.cells.flatMap { $0.map(\.cost) }.max() ?? 0
    let dayTotals = grid.cells.map { $0.reduce(0) { $0 + $1.cost } }
    let hourTotals = (0..<24).map { h in grid.cells.reduce(0) { $0 + $1[h].cost } }
    let maxDay = dayTotals.max() ?? 0, maxHour = hourTotals.max() ?? 0
    Panel {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "clock").foregroundStyle(muted)
          Text("When you work").font(.system(size: 14, weight: .semibold))
          Spacer()
          if maxCell > 0, let peak = peak(grid.cells) {
            Text("Busiest hour: \(PatternsView.days[peak.0]) \(hourLabel(peak.1)) · " + rangeText(store.days))
              .font(.system(size: 11).monospacedDigit()).foregroundStyle(muted)
          }
        }
        if rows.isEmpty {
          EmptyNote(text: "No hourly data in this range")
        } else {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { d in
              HStack(spacing: 3) {
                Text(PatternsView.days[d]).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                  .frame(width: 30, alignment: .leading)
                ForEach(0..<24, id: \.self) { h in
                  let c = grid.cells[d][h].cost
                  let on = hovered.map { $0.day == d && $0.hour == h } ?? false
                  RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(c > 0 ? orange.opacity(0.12 + 0.88 * (c / maxCell).squareRoot()) : ink.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? ink : .clear, lineWidth: 1.5))
                    .frame(height: 22).frame(maxWidth: .infinity)
                    .onHover { inside in
                      if inside { hovered = (d, h) } else if hovered.map({ $0.day == d && $0.hour == h }) ?? false { hovered = nil }
                    }
                }
                // The weekday's total, scaled to the busiest weekday.
                HStack(spacing: 6) {
                  Capsule().fill(orange.opacity(0.8)).frame(width: dayTotals[d] > 0 ? max(2, 70 * dayTotals[d] / maxDay) : 0, height: 5)
                  Spacer(minLength: 0)
                  Text(store.money(dayTotals[d])).font(.system(size: 10).monospacedDigit()).foregroundStyle(muted)
                }.frame(width: 140)
              }
            }
            // The hour's total across the week, as small columns under the grid.
            HStack(alignment: .bottom, spacing: 3) {
              Color.clear.frame(width: 30, height: 1)
              ForEach(0..<24, id: \.self) { h in
                VStack(spacing: 3) {
                  RoundedRectangle(cornerRadius: 2).fill(orange.opacity(0.8))
                    .frame(height: maxHour > 0 ? max(hourTotals[h] > 0 ? 2 : 0, 28 * hourTotals[h] / maxHour) : 0)
                  Text(h % 3 == 0 ? String(format: "%02d", h) : " ").font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(muted)
                }.frame(maxWidth: .infinity, alignment: .bottom).frame(height: 44, alignment: .bottom)
              }
              Color.clear.frame(width: 140, height: 1)
            }.padding(.top, 4)
          }
          detail(grid)
        }
      }
    }
  }
  private func peak(_ cells: [[WeekHour]]) -> (Int, Int)? {
    var best: (Int, Int)?; var top = 0.0
    for d in 0..<7 { for h in 0..<24 where cells[d][h].cost > top { top = cells[d][h].cost; best = (d, h) } }
    return best
  }
  // Under the grid: the hovered cell, or how to read the grid.
  @ViewBuilder private func detail(_ grid: (cells: [[WeekHour]], days: [Int])) -> some View {
    HStack(spacing: 12) {
      if let h = hovered {
        let cell = grid.cells[h.day][h.hour], n = grid.days[h.day]
        Text(PatternsView.longDays[h.day] + String(format: " %02d:00–%02d:00", h.hour, h.hour + 1)).fontWeight(.semibold)
        Text(store.money(cell.cost)).monospacedDigit()
        if n > 0 {
          Text(
            "about " + store.money(cell.cost / Double(n)) + " a day over \(n) "
              + (n == 1 ? String(PatternsView.longDays[h.day].dropLast()) : PatternsView.longDays[h.day]).lowercased())
            .foregroundStyle(muted)
        }
        Spacer()
        Text(exact(cell.tokens) + " tokens · " + exact(cell.requests) + " requests").foregroundStyle(muted)
          .monospacedDigit()
      } else {
        Text("Each square is one hour of the week, darker for more spent in the chosen range. Hover one for details.")
          .foregroundStyle(muted)
        Spacer()
      }
    }.font(.system(size: 11)).lineLimit(1).frame(height: 18)
  }
}
