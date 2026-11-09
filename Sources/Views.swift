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
    refreshExchange()
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
  var body: some View {
    Panel {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(muted);
        Text(value).font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-0.6).lineLimit(1)
          .minimumScaleFactor(0.5)
        if let subtitle {
          Text(subtitle).font(.system(size: 11).monospacedDigit()).foregroundStyle(muted).padding(.top, -6)
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
      Chart(points) { r in
        AreaMark(x: .value("Date", r.date), y: .value("Usage", usage(r)), stacking: .unstacked).foregroundStyle(
          by: .value("Platform", r.provider)
        ).opacity(0.1).interpolationMethod(.linear)
        LineMark(x: .value("Date", r.date), y: .value("Usage", usage(r))).foregroundStyle(
          by: .value("Platform", r.provider)
        ).lineStyle(StrokeStyle(lineWidth: 2.4)).interpolationMethod(.linear)
        if singleProviders.contains(r.provider) {
          PointMark(x: .value("Date", r.date), y: .value("Usage", usage(r))).foregroundStyle(
            by: .value("Platform", r.provider)
          ).symbolSize(45)
        }
      }.chartForegroundStyleScale(["gpt": blue, "claude": orange]).chartLegend(.hidden).chartYScale(
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
            if let date = hovered, dates.contains(date), let x = proxy.position(forX: date) {
              Rectangle().fill(muted.opacity(0.6)).frame(width: 1, height: plot.height).offset(
                x: plot.minX + x, y: plot.minY
              ).allowsHitTesting(false)
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
        BarMark(x: .value("Hour", hourLabel(p.hour)), y: .value("Usage", usage(p)), width: .ratio(0.7))
          .foregroundStyle(by: .value("Platform", p.provider)).opacity(hovered == nil || hovered == p.hour ? 1 : 0.45)
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
  struct DayTotal { var tokens = 0; var cost = 0.0; var unpriced = false }
  var rows: [UsageRow] { store.allRows(provider: store.provider) }
  var totals: [String: DayTotal] {
    var byDay: [String: DayTotal] = [:]
    for r in rows {
      var t = byDay[r.date] ?? DayTotal(); t.tokens += r.tokens
      if let c = r.cost { t.cost += c } else { t.unpriced = true }
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
          Button {
            month = cal.date(byAdding: .month, value: -1, to: month)!
          } label: {
            Image(systemName: "chevron.left")
          }.buttonStyle(.plain).foregroundStyle(muted)
          Text(CalendarPanel.monthFormatter.string(from: month)).font(.system(size: 12, weight: .medium))
            .frame(width: 130)
          Button {
            month = cal.date(byAdding: .month, value: 1, to: month)!
          } label: {
            Image(systemName: "chevron.right")
          }.buttonStyle(.plain).foregroundStyle(monthKey == today.prefix(7) ? muted.opacity(0.3) : muted)
            .disabled(monthKey == today.prefix(7))
        }
        LazyVGrid(columns: columns, spacing: 6) {
          ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { d in
            Text(d).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
          }
          ForEach(-leading..<0, id: \.self) { _ in Color.clear.frame(height: 54) }
          ForEach(1...days, id: \.self) { d in
            let key = monthKey + String(format: "-%02d", d)
            let total = totals[key]
            let ratio = maxCost > 0 ? (total?.cost ?? 0) / maxCost : 0
            let future = key > today
            Button {
              selected = key
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(String(d)).font(.system(size: 11, weight: key == today ? .bold : .medium))
                  .foregroundStyle(future ? muted.opacity(0.5) : (total == nil ? muted : ink))
                Spacer(minLength: 0)
                if let total {
                  Text(store.money(total.cost) + (total.unpriced ? "*" : "")).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.7)
                }
              }.padding(8).frame(maxWidth: .infinity, alignment: .leading).frame(height: 54)
                .background(
                  total == nil ? ink.opacity(0.03) : blue.opacity(0.1 + 0.55 * ratio),
                  in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 8).strokeBorder(selected == key ? ink : Color.clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
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
  private static let readableDay: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "en_US")
    f.timeZone = dayFormatter.timeZone; return f
  }()
  static func readable(_ day: String) -> String { dayFormatter.date(from: day).map(readableDay.string) ?? day }
  var body: some View {
    let rows = store.rows; let both = store.provider == "all"
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          Picker("Platform", selection: $store.provider) {
            Text("All").tag("all"); Text("Claude").tag("claude"); Text("Codex").tag("gpt")
          }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
          Spacer()
          Picker("Range", selection: $store.days) {
            Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90);
            Text("All time").tag(0)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
          if let d = store.lastRefresh {
            Text(d.formatted(date: .omitted, time: .shortened)).font(.system(size: 11).monospacedDigit())
              .foregroundStyle(muted)
          }
          Button {
            store.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }.disabled(store.busy)
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
          }.menuStyle(.borderlessButton).fixedSize().help("Currency, appearance, Count from, login item, prices")
          Button {
            store.archive()
          } label: {
            Label(store.archiving ? "Archiving…" : "Archive", systemImage: "archivebox")
          }.disabled(store.archiving)
        }
        if let error = store.error { Text(error).font(.system(size: 11)).foregroundStyle(orange) }
        if let r = store.archiveResult {
          Text(r.text).font(.system(size: 11)).foregroundStyle(r.failed ? orange : muted).lineLimit(2).textSelection(
            .enabled)
        }
        if store.days == 0, let from = store.countFrom {
          Text("All time starts on \(Dashboard.readable(from)), as Count from in the gear menu says.")
            .font(.system(size: 11)).foregroundStyle(muted)
        }
        // swiftc -D CALENDAR_ONLY builds a debug binary that shows the calendar at the top, for screenshots.
        #if !CALENDAR_ONLY
          let split = breakdown(rows), cost = store.cost(rows)
          HStack(spacing: 16) {
            Total(
              title: "Tokens", value: exact(store.total(rows)),
              parts: both
                ? ["claude", "gpt"].map { p in (p, exact(store.total(rows.filter { $0.provider == p }))) } : [],
              details: tokenDetails(split))
            Total(
              title: "API cost", value: store.money(cost), subtitle: store.usdLine(cost),
              parts: both
                ? ["claude", "gpt"].map { p in (p, store.money(store.cost(rows.filter { $0.provider == p }))) } : [],
              note: unpricedNote(rows), details: costDetails(split, store.money))
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
                Picker("Metric", selection: $costMode) {
                  Text("Tokens").tag(false); Text("Cost").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
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
        #endif
        CalendarPanel(store: store, costMode: costMode)
        ModelPanel(store: store)
      // No width cap: NSHostingView turns the content's maximum size into the window's, and a 1200 cap
      // stopped a title-bar double-click from filling the screen.
      }.padding(28).frame(maxWidth: .infinity)
    }.background(canvas)
      .foregroundStyle(ink).preferredColorScheme(store.colorScheme).frame(minWidth: 880, minHeight: 560)
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
  @ViewState var sort = "tokens"; @ViewState var ascending = false
  var models: [ModelTotal] {
    var m: [String: ModelTotal] = [:]
    for r in store.rows {
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
    Panel {
      VStack(alignment: .leading, spacing: 10) {
        Text("Models").font(.system(size: 14, weight: .semibold))
        HStack(spacing: 12) {
          header("Model", "model").frame(maxWidth: .infinity, alignment: .leading)
          header("Tokens", "tokens").frame(width: 140, alignment: .trailing)
          header("Cache hit", "cache").frame(width: 80, alignment: .trailing)
            .help("Share of prompt tokens served from the cache")
          header("Requests", "requests").frame(width: 80, alignment: .trailing)
          header("API cost", "cost").frame(width: 110, alignment: .trailing)
        }.font(.system(size: 10, weight: .medium)).foregroundStyle(muted).padding(.top, 4)
        ForEach(list) { r in
          Divider().opacity(0.5)
          HStack(spacing: 12) {
            HStack(spacing: 8) {
              Dot(color: providerColor(r.provider)); Text(modelName(r.model)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(exact(r.tokens)).frame(width: 140, alignment: .trailing)
            Text(r.cacheHit.map(percent) ?? "–").foregroundStyle(r.cacheHit == nil ? muted : ink)
              .frame(width: 80, alignment: .trailing)
            Text(exact(r.requests)).frame(width: 80, alignment: .trailing)
            Text(r.cost.map(store.money) ?? "–").foregroundStyle(r.cost == nil ? muted : ink)
              .frame(width: 110, alignment: .trailing)
          }.font(.system(size: 12).monospacedDigit())
        }
        if list.isEmpty { Text("No data").font(.system(size: 12)).foregroundStyle(muted) }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
