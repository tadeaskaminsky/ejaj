import Foundation

struct UsageRow: Codable, Identifiable {
  var date: String; var provider: String; var model: String; var source: String
  var input: Int = 0; var cached: Int = 0; var write: Int = 0; var write1h: Int = 0; var output: Int = 0;
  var requests: Int = 0
  // Set only on the hourly rows (Dataset.hourly); daily rows leave it nil.
  var hour: Int? = nil
  // Price modifiers every request in the row shares, joined with "+": "fast", "long" and "us". nil is the list price.
  var tier: String? = nil
  // Server-side web searches, billed per search on top of the tokens.
  var searches: Int? = nil
  var id: String {
    "\(date)|\(provider)|\(model)|\(source)" + (tier.map { "|\($0)" } ?? "") + (hour.map { "|\($0)" } ?? "")
  }
  var tokens: Int { input + cached + write + write1h + output }
  // The API cost by category in USD, with the row's modifiers applied. nil when the model has no price.
  var costParts: CostParts? {
    guard let p = Pricing.rates(model, on: date) else { return nil }
    let m = Pricing.multipliers(model, tier: tier)
    return CostParts(
      input: Double(input) * p[0] * m.input / 1_000_000,
      write: (Double(write) * p[2] + Double(write1h) * p[4]) * m.input / 1_000_000,
      read: Double(cached) * p[1] * m.input / 1_000_000, output: Double(output) * p[3] * m.output / 1_000_000,
      search: Double(searches ?? 0) * Pricing.webSearch)
  }
  var cost: Double? { costParts?.total }
}
struct CostParts: Equatable {
  var input = 0.0; var write = 0.0; var read = 0.0; var output = 0.0; var search = 0.0
  var total: Double { input + write + read + output + search }
  static func + (a: CostParts, b: CostParts) -> CostParts {
    CostParts(
      input: a.input + b.input, write: a.write + b.write, read: a.read + b.read, output: a.output + b.output,
      search: a.search + b.search)
  }
}
// Tokens and API cost of some rows by category. Cache writes add the 5-minute and 1-hour writes together.
struct Breakdown: Equatable {
  var input = 0; var write = 0; var read = 0; var output = 0; var searches = 0; var cost = CostParts()
  var tokens: Int { input + write + read + output }
}
func breakdown(_ rows: [UsageRow]) -> Breakdown {
  rows.reduce(into: Breakdown()) { b, r in
    b.input += r.input; b.write += r.write + r.write1h; b.read += r.cached; b.output += r.output
    b.searches += r.searches ?? 0
    if let c = r.costParts { b.cost = b.cost + c }
  }
}
struct Dataset: Codable {
  var version: Int = 1; var updatedAt: String; var timezone: String = "Europe/Bratislava"; var rows: [UsageRow];
  var skipped: Int = 0; var unreadable: Int = 0
  // Per-hour rows for every day, for the calendar and the Today chart. Older snapshots have none.
  var hourly: [UsageRow]? = nil
  // One entry per agent session, for the Analytics tab. Snapshots before 1.11 have none.
  var sessions: [SessionUsage]? = nil
}
// One agent session: a Claude Code conversation with its subagents, or a Codex thread with the threads it spawned.
// Its rows are per day, model and tier, like Dataset.rows. Only the session's title and the project's name and folder
// are kept, never a prompt.
struct SessionUsage: Codable, Identifiable {
  var provider: String; var session: String
  var project: String
  var folder: String? = nil  // the project's folder, ~ for the home folder; nil for scratch and temporary folders
  var title: String? = nil
  var start: Date; var end: Date  // the first and the last request
  var rows: [UsageRow]
  var id: String { provider + "|" + session }
}
// The project a working folder belongs to: the git repository around it, with a Claude Code worktree counted as the
// repository it came from. Folders outside a repository are their own project. Claude's and Codex's scratch folders
// are grouped as Scratch, temporary folders as Temporary.
struct ProjectRef: Equatable { var name: String; var folder: String? }
func projectOf(cwd: String?, home: String, isRepo: (String) -> Bool) -> ProjectRef {
  guard var path = cwd, path.hasPrefix("/") else { return ProjectRef(name: "Unknown folder", folder: nil) }
  while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
  if path.contains("/Library/Application Support/Claude/scratch-workspaces/") || path.hasPrefix(home + "/Documents/Codex/")
  {
    return ProjectRef(name: "Scratch", folder: nil)
  }
  let inHome = path == home || path.hasPrefix(home + "/")
  for tmp in ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
  where !inHome && (path == tmp || path.hasPrefix(tmp + "/")) {
    return ProjectRef(name: "Temporary", folder: nil)
  }
  if let r = path.range(of: "/.claude/worktrees/") { path = String(path[..<r.lowerBound]) }
  var root = path, dir = path
  while dir != home, dir != "/", !dir.isEmpty {
    if isRepo(dir) { root = dir; break }
    dir = (dir as NSString).deletingLastPathComponent
  }
  if root == home { return ProjectRef(name: "Home folder", folder: "~") }
  let folder = root.hasPrefix(home + "/") ? "~" + root.dropFirst(home.count) : root
  return ProjectRef(name: (root as NSString).lastPathComponent, folder: folder)
}
// A session's rows in the chosen days and platform. Sessions without any are left out.
struct SessionTotal: Identifiable {
  var session: SessionUsage; var rows: [UsageRow]
  var cost = 0.0; var tokens = 0; var requests = 0
  // Some rows are of a model without a price, so the cost leaves them out.
  var unpriced = false
  var id: String { session.id }
}
func totalsBySession(_ sessions: [SessionUsage], from: String?, through: String, provider: String) -> [SessionTotal] {
  sessions.compactMap { s -> SessionTotal? in
    guard provider == "all" || s.provider == provider else { return nil }
    let rows = s.rows.filter { r in r.date >= (from ?? "") && r.date <= through }
    guard !rows.isEmpty else { return nil }
    return SessionTotal(
      session: s, rows: rows, cost: rows.reduce(0) { $0 + ($1.cost ?? 0) }, tokens: rows.reduce(0) { $0 + $1.tokens },
      requests: rows.reduce(0) { $0 + $1.requests }, unpriced: rows.contains { $0.cost == nil })
  }
}
// Sessions grouped by project name, most expensive first. Two folders with the same name count as one project.
struct ProjectTotal: Identifiable {
  var name: String; var folders: [String] = []; var sessions: [SessionTotal] = []
  var cost = 0.0; var tokens = 0; var last = Date.distantPast
  var unpriced: Bool { sessions.contains(where: \.unpriced) }
  var id: String { name }
}
func totalsByProject(_ sessions: [SessionTotal]) -> [ProjectTotal] {
  var byName: [String: ProjectTotal] = [:]
  for s in sessions {
    var p = byName[s.session.project] ?? ProjectTotal(name: s.session.project)
    if let f = s.session.folder, !p.folders.contains(f) { p.folders.append(f) }
    p.sessions.append(s); p.cost += s.cost; p.tokens += s.tokens; p.last = max(p.last, s.session.end)
    byName[p.name] = p
  }
  return byName.values.map { p in
    var p = p; p.folders.sort(); p.sessions.sort { $0.cost == $1.cost ? $0.session.end > $1.session.end : $0.cost > $1.cost }
    return p
  }.sorted { $0.cost == $1.cost ? ($0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens) : $0.cost > $1.cost }
}
// What the prompt cache did to the bill: cache reads cost less than fresh input (saved), cache writes cost more
// (premium). Both are measured against paying the input price for those tokens, with the row's modifiers.
struct CacheEffect: Equatable {
  var saved = 0.0; var premium = 0.0
  var net: Double { saved - premium }
  static func + (a: CacheEffect, b: CacheEffect) -> CacheEffect {
    CacheEffect(saved: a.saved + b.saved, premium: a.premium + b.premium)
  }
}
extension UsageRow {
  var cacheEffect: CacheEffect? {
    guard let p = Pricing.rates(model, on: date) else { return nil }
    let m = Pricing.multipliers(model, tier: tier).input
    return CacheEffect(
      saved: Double(cached) * (p[0] - p[1]) * m / 1_000_000,
      premium: (Double(write) * (p[2] - p[0]) + Double(write1h) * (p[4] - p[0])) * m / 1_000_000)
  }
}
func cacheEffect(_ rows: [UsageRow]) -> CacheEffect { rows.reduce(CacheEffect()) { $0 + ($1.cacheEffect ?? CacheEffect()) } }
// Hourly rows summed into a week: [weekday][hour], Monday first, Bratislava time. Also how many distinct days of each
// weekday had any usage, for per-day averages.
struct WeekHour: Equatable { var cost = 0.0; var tokens = 0; var requests = 0 }
func weekHourGrid(_ hourly: [UsageRow]) -> (cells: [[WeekHour]], days: [Int]) {
  var cells = Array(repeating: Array(repeating: WeekHour(), count: 24), count: 7)
  var seen = Array(repeating: Set<String>(), count: 7)
  let cal = bratislava
  for r in hourly {
    guard let h = r.hour, (0..<24).contains(h), let d = dayFormatter.date(from: r.date) else { continue }
    let w = (cal.component(.weekday, from: d) + 5) % 7
    cells[w][h].cost += r.cost ?? 0; cells[w][h].tokens += r.tokens; cells[w][h].requests += r.requests
    seen[w].insert(r.date)
  }
  return (cells, seen.map(\.count))
}
// Sessions whose last request is at most `within` seconds before `now`, newest first.
func runningSessions(_ sessions: [SessionTotal], now: Date, within: TimeInterval = 600) -> [SessionTotal] {
  sessions.filter { now.timeIntervalSince($0.session.end) <= within && $0.session.end <= now.addingTimeInterval(60) }
    .sorted { $0.session.end > $1.session.end }
}
// The Christmas edition's season in Bratislava: 1 December to 6 January (Epiphany), both included.
func christmasSeason(_ date: Date) -> Bool {
  let c = bratislava.dateComponents([.month, .day], from: date)
  return c.month == 12 || (c.month == 1 && (c.day ?? 99) <= 6)
}
// "45 min", "2 h 13 min", "3 d 4 h". Under a minute is "<1 min".
func durationText(_ seconds: TimeInterval) -> String {
  let minutes = Int(max(0, seconds) / 60)
  if minutes < 1 { return "<1 min" }
  if minutes < 60 { return "\(minutes) min" }
  let hours = minutes / 60
  if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
  return hours % 24 == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(hours % 24) h"
}
// Prices per 1M tokens: [input, cache read, cache write (5 min), output, cache write (1 h)].
struct PriceEntry: Equatable { var from: String; var rates: [Double] }
// A prompt over `above` tokens, cache reads and writes included, multiplies the input-side rates by `input` and the
// output rate by `output`. Each request is judged on its own prompt.
struct LongContext: Equatable { var above: Int; var input: Double; var output: Double }
// Fast mode multiplies every rate of the model by `fast`.
struct Modifiers: Equatable { var fast: Double = 1; var long: LongContext? = nil }
enum Pricing {
  // Standard API prices, checked against Anthropic's and OpenAI's pricing pages on 2026-11-05
  // (Fable 5.2 on 2026-11-10). gpt-5.3-codex-spark
  // and gpt-5-codex are not on OpenAI's page; their rates come from third-party price lists. For OpenAI models the
  // fifth rate is unused: Codex logs report one kind of cache write.
  static let bundled: [String: [Double]] = [
    "gpt-6-astra": [10, 1, 12.5, 50, 20], "gpt-5.6-sol": [4, 0.4, 5, 20, 8], "gpt-5.6-terra": [2, 0.2, 2.5, 12, 4],
    "gpt-5.6-luna": [0.2, 0.02, 0.25, 1.2, 0.4], "claude-opus-5": [5, 0.5, 6.25, 25, 10],
    "claude-opus-4-8": [5, 0.5, 6.25, 25, 10], "claude-sonnet-5": [2, 0.2, 2.5, 10, 4],
    "claude-fable-5": [10, 1, 12.5, 50, 20], "claude-fable-5-1": [10, 0.25, 12.5, 50, 20],
    "claude-fable-5-2": [8, 0.2, 10, 40, 16],
    "claude-opus-5-5": [4, 0.2, 5, 20, 8], "claude-sonnet-5-5": [2, 0.1, 2.5, 10, 4],
    "claude-haiku-5-5": [0.1, 0.01, 0.125, 0.5, 0.2], "gpt-6-sol": [2, 0.2, 2.5, 10, 4],
    "gpt-6.1-sol": [2, 0.1, 2.5, 10, 4], "gpt-6.1-terra": [1, 0.05, 1.25, 5, 2],
    "gpt-6-luna": [0.1, 0.01, 0.125, 0.5, 0.2],
    "gpt-5.5": [5, 0.5, 6.25, 30, 10], "gpt-5.3-codex-spark": [1.75, 0.175, 2.1875, 14, 3.5],
    "gpt-5-codex": [1.25, 0.125, 1.5625, 10, 2.5], "codex-auto-review": [0, 0, 0, 0, 0],
  ]
  // Fast mode: Fable 5.2 $16/$80, Opus 5.5 $8/$40, Opus 5 and 4.8 $10/$50; OpenAI's fast tier (priority in Codex logs) doubles the
  // GPT-6 and GPT-5.6 rates and charges 2.5x on gpt-5.5. Haiku 5.5 costs 5x for prompts over 100K tokens, and OpenAI
  // charges 2x input and 1.5x output for prompts over 272K.
  static let bundledModifiers: [String: Modifiers] = {
    let openAILong = LongContext(above: 272_000, input: 2, output: 1.5)
    var m: [String: Modifiers] = [
      "claude-fable-5-2": Modifiers(fast: 2),
      "claude-opus-5-5": Modifiers(fast: 2), "claude-opus-5": Modifiers(fast: 2), "claude-opus-4-8": Modifiers(fast: 2),
      "claude-haiku-5-5": Modifiers(long: LongContext(above: 100_000, input: 5, output: 5)),
      "gpt-5.5": Modifiers(fast: 2.5, long: openAILong),
    ]
    for id in [
      "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra",
      "gpt-5.6-luna",
    ] { m[id] = Modifiers(fast: 2, long: openAILong) }
    return m
  }()
  // US-only inference (inference_geo "us") multiplies every Claude rate; a web search costs $10 per 1,000.
  static let bundledUSOnly = 1.1
  static let bundledWebSearch = 0.01
  // ~/Library/Application Support/EJAJ/pricing.json adds or overrides models without a rebuild:
  //   {"gpt-7": [5, 0.5, 6.25, 30, 10],
  //    "claude-opus-5-5": [{"from": "2026-04-01", "rates": [4, 0.2, 5, 20, 8]}, {"from": "2027-01-01", "rates": [...]}],
  //    "claude-haiku-5-5": {"rates": [0.1, 0.01, 0.125, 0.5, 0.2], "longContext": {"above": 100000, "input": 5, "output": 5}},
  //    "claude-opus-5": {"fast": 2}, "usOnlyMultiplier": 1.1, "webSearch": 0.01}
  // A bare array applies to every date. Dated entries apply from their day on; the latest one not after the row wins,
  // and days before the first entry fall back to the bundled price. The object form also sets the fast multiplier
  // and the long-context premium ("longContext": null removes it). A model keeps its bundled modifiers otherwise.
  nonisolated(unsafe) private(set) static var table: [String: [PriceEntry]] = bundledTable
  nonisolated(unsafe) private(set) static var modifiers: [String: Modifiers] = bundledModifiers
  nonisolated(unsafe) private(set) static var usOnly = bundledUSOnly
  nonisolated(unsafe) private(set) static var webSearch = bundledWebSearch
  nonisolated(unsafe) private(set) static var fileError: String?
  // Goes up whenever a load changes the modifiers. The collector sorts requests into tiers by the long-context
  // thresholds, so it sorts them again when this changes.
  nonisolated(unsafe) private(set) static var revision = 0
  static var bundledTable: [String: [PriceEntry]] { bundled.mapValues { [PriceEntry(from: "", rates: $0)] } }
  static var fileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EJAJ/pricing.json")
  }
  static func load(_ url: URL = fileURL) {
    let before = modifiers
    table = bundledTable; modifiers = bundledModifiers; usOnly = bundledUSOnly; webSearch = bundledWebSearch
    fileError = nil
    defer { if modifiers != before { revision += 1 } }
    guard let data = try? Data(contentsOf: url) else { return }
    guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      fileError = "pricing.json is not a JSON object of model → prices."; return
    }
    // Every broken entry is named, and the rest of the file still applies.
    var problems: [String] = []
    for (model, value) in raw.sorted(by: { $0.key < $1.key }) {
      switch model {
      case "usOnlyMultiplier":
        if let n = number(value), n > 0 { usOnly = n } else { problems.append("usOnlyMultiplier needs a number above 0.") }
      case "webSearch":
        if let n = number(value), n >= 0 { webSearch = n } else { problems.append("webSearch needs a price in USD.") }
      default:
        if let problem = apply(model, value) { problems.append(problem) }
      }
    }
    if !problems.isEmpty { fileError = "pricing.json: " + problems.joined(separator: " ") }
  }
  // Applies one model's entry, or says what is wrong with it and leaves the model as it was.
  private static func apply(_ model: String, _ value: Any) -> String? {
    guard let object = value as? [String: Any] else {
      guard let parsed = parseRates(value) else {
        return value is [[String: Any]] ? "invalid entry for \(model)." : "\(model) needs 5 prices or a list of {from, rates}."
      }
      setRates(model, parsed); return nil
    }
    var m = modifiers[model] ?? Modifiers()
    var valid = Set(object.keys).isSubset(of: ["rates", "fast", "longContext"])
    if let f = object["fast"] { if let n = number(f), n > 0 { m.fast = n } else { valid = false } }
    if let l = object["longContext"] {
      if l is NSNull {
        m.long = nil
      } else if let o = l as? [String: Any], Set(o.keys).isSubset(of: ["above", "input", "output"]),
        let above = number(o["above"]), above >= 1, above < 1e9, let i = number(o["input"]), i > 0,
        let out = number(o["output"]), out > 0
      {
        m.long = LongContext(above: Int(above), input: i, output: out)
      } else {
        valid = false
      }
    }
    var rates: (entries: [PriceEntry], dated: Bool)?
    if let r = object["rates"] { rates = parseRates(r); if rates == nil { valid = false } }
    guard valid else { return "invalid entry for \(model)." }
    modifiers[model] = m
    if let rates { setRates(model, rates) }
    return nil
  }
  // A JSON number that is not true or false.
  private static func number(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
  }
  // Five prices, none negative.
  private static func fiveRates(_ value: Any?) -> [Double]? {
    guard let list = value as? [Any], list.count == 5 else { return nil }
    let rates = list.compactMap { number($0) }.filter { $0 >= 0 }
    return rates.count == 5 ? rates : nil
  }
  // Five rates for every date, or dated entries added after the bundled price.
  private static func parseRates(_ value: Any) -> (entries: [PriceEntry], dated: Bool)? {
    if let rates = fiveRates(value) { return ([PriceEntry(from: "", rates: rates)], false) }
    guard let list = value as? [[String: Any]], !list.isEmpty else { return nil }
    let entries = list.compactMap { e -> PriceEntry? in
      guard let from = e["from"] as? String, dayFormatter.date(from: from) != nil, let rates = fiveRates(e["rates"])
      else { return nil }
      return PriceEntry(from: from, rates: rates)
    }
    return entries.count == list.count ? (entries.sorted { $0.from < $1.from }, true) : nil
  }
  private static func setRates(_ model: String, _ parsed: (entries: [PriceEntry], dated: Bool)) {
    table[model] = parsed.dated ? (table[model] ?? []) + parsed.entries : parsed.entries
  }
  static func rates(_ model: String, on date: String) -> [Double]? {
    table[model]?.last { $0.from <= date }?.rates
  }
  static func isLong(_ model: String, prompt: Int) -> Bool {
    modifiers[model]?.long.map { prompt > $0.above } ?? false
  }
  // What a row's tier does to its input-side and output rates.
  static func multipliers(_ model: String, tier: String?) -> (input: Double, output: Double) {
    guard let tier else { return (1, 1) }
    let m = modifiers[model] ?? Modifiers()
    var input = 1.0, output = 1.0
    for flag in tier.split(separator: "+") {
      switch flag {
      case "fast": input *= m.fast; output *= m.fast
      case "long": if let l = m.long { input *= l.input; output *= l.output }
      case "us": input *= usOnly; output *= usOnly
      default: break
      }
    }
    return (input, output)
  }
  // What Edit prices writes the first time: every bundled model with its modifiers, and the two flat prices.
  static func seedJSON() -> Data {
    var object: [String: Any] = ["usOnlyMultiplier": bundledUSOnly, "webSearch": bundledWebSearch]
    for (model, rates) in bundled {
      guard let m = bundledModifiers[model] else { object[model] = rates; continue }
      var entry: [String: Any] = ["rates": rates]
      if m.fast != 1 { entry["fast"] = m.fast }
      if let l = m.long { entry["longContext"] = ["above": l.above, "input": l.input, "output": l.output] }
      object[model] = entry
    }
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
  }
}
func compact(_ n: Int) -> String {
  if n >= 1_000_000_000 { return String(format: "%.2f B", Double(n) / 1_000_000_000) };
  if n >= 1_000_000 { return String(format: "%.1f M", Double(n) / 1_000_000) };
  if n >= 1000 { return String(format: "%.1f k", Double(n) / 1000) }; return String(n)
}
func dollars(_ n: Double) -> String {
  let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.locale = Locale(identifier: "en_US");
  f.maximumFractionDigits = 2; return f.string(from: NSNumber(value: n)) ?? "$0"
}
// Display names. The provider dot already says Claude or Codex, so "claude-" is dropped:
// claude-opus-5-5 → Opus 5.5, gpt-5.6-sol → GPT-5.6 Sol, gpt-5.3-codex-spark → GPT-5.3 Codex Spark.
// A single-digit pair is a version; longer numbers (dates) are left alone.
let modelDisplayNames: [String: String] = ["codex-auto-review": "Codex Auto Review", "unknown": "Unknown model"]
func modelName(_ s: String) -> String {
  if let name = modelDisplayNames[s] { return name }
  var id = s
  if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
  id = id.replacingOccurrences(of: "(?<!\\d)(\\d)-(\\d)(?!\\d)", with: "$1.$2", options: .regularExpression)
  var words = id.split(separator: "-").map(String.init)
  if words.first == "gpt" {
    words[0] = "GPT"
    if words.count > 1, words[1].first?.isNumber == true { words[0] = "GPT-" + words[1]; words.remove(at: 1) }
  }
  return words.map { w in w.first?.isNumber == true ? w : w.prefix(1).uppercased() + w.dropFirst() }
    .joined(separator: " ")
}
var bratislava: Calendar {
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Bratislava")!; return cal
}
let dayFormatter: DateFormatter = {
  let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX");
  f.timeZone = TimeZone(identifier: "Europe/Bratislava"); return f
}()

// Days the history can be counted from, besides the first record: each day of use that follows at least
// `minIdle` days without any. Count from in the gear menu offers them, so a lone test session months before
// regular use doesn't stretch All time.
struct Restart: Equatable { var day: String; var idle: Int }
func restarts(_ rows: [UsageRow], minIdle: Int = 30) -> [Restart] {
  let days = Set(rows.map(\.date)).sorted()
  return zip(days, days.dropFirst()).compactMap { before, day in
    guard let a = dayFormatter.date(from: before), let b = dayFormatter.date(from: day),
      let gap = bratislava.dateComponents([.day], from: a, to: b).day, gap - 1 >= minIdle
    else { return nil }
    return Restart(day: day, idle: gap - 1)
  }
}
// The rows from `day` on. nil keeps them all.
func counted(_ rows: [UsageRow], from day: String?) -> [UsageRow] {
  guard let day else { return rows }; return rows.filter { $0.date >= day }
}

// A calendar day's API cost against the same weekday in the 12 weeks before it. When that weekday has no
// history yet, the 30 days before it are used. Days without any cost are left out of the average.
struct DayAverage {
  var cost: Double; var average: Double; var days: Int
  var weekday: String?  // nil when the 30-day average is used
  var ratio: Double { cost / average }
  var difference: Double { cost - average }
  var percent: Int { Int(((ratio - 1) * 100).rounded()) }
  var level: String { averageLevel(ratio) }
  var basis: String { weekday.map { "average \($0)" } ?? "30-day average" }
}
func averageLevel(_ ratio: Double) -> String {
  switch ratio {
  case 1.5...: return "Way above average"
  case 1.1...: return "Above average"
  case 0.9...: return "Average"
  case 0.5...: return "Below average"
  default: return "Way below average"
  }
}
// The Monday–Sunday week of a calendar day against the 12 weeks before it. A week still running is compared
// with the same days of the earlier weeks (Mon–Wed against Mon–Wed). Weeks without any cost are left out.
struct WeekAverage {
  var monday: String; var cost: Double; var average: Double; var fullAverage: Double; var weeks: Int
  var days: Int  // 7 for a finished week, fewer while it is running
  var ratio: Double { cost / average }
  var difference: Double { cost - average }
  var percent: Int { Int(((ratio - 1) * 100).rounded()) }
  var level: String { averageLevel(ratio) }
  var span: String {
    let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    return days == 7 ? "week" : days == 1 ? "Mon" : "Mon–" + names[days - 1]
  }
}
func weekAverage(_ costByDay: [String: Double], on date: String, today: String) -> WeekAverage? {
  guard let day = dayFormatter.date(from: date), let now = dayFormatter.date(from: today) else { return nil }
  let cal = bratislava
  let monday = cal.date(byAdding: .day, value: -((cal.component(.weekday, from: day) + 5) % 7), to: day)!
  guard monday <= now else { return nil }
  let elapsed = cal.dateComponents([.day], from: monday, to: now).day! + 1
  let days = min(7, elapsed)
  func sum(_ start: Date, _ count: Int) -> Double {
    (0..<count).reduce(0) { $0 + (costByDay[dayFormatter.string(from: cal.date(byAdding: .day, value: $1, to: start)!)] ?? 0) }
  }
  var partial: [Double] = [], full: [Double] = []
  for i in 1...12 {
    let start = cal.date(byAdding: .day, value: -7 * i, to: monday)!
    let total = sum(start, 7)
    if total > 0 { full.append(total); partial.append(sum(start, days)) }
  }
  let average = partial.reduce(0, +) / Double(max(partial.count, 1))
  guard !full.isEmpty, average > 0 else { return nil }
  return WeekAverage(
    monday: dayFormatter.string(from: monday), cost: sum(monday, days), average: average,
    fullAverage: full.reduce(0, +) / Double(full.count), weeks: full.count, days: days)
}
func dayAverage(_ costByDay: [String: Double], on date: String) -> DayAverage? {
  guard let day = dayFormatter.date(from: date) else { return nil }
  let cal = bratislava, weekday = cal.component(.weekday, from: day)
  func before(_ days: Int) -> String { dayFormatter.string(from: cal.date(byAdding: .day, value: -days, to: day)!) }
  let past = costByDay.filter { $0.key < date && $0.value > 0 }
  let sameDay = past.filter {
    $0.key >= before(84) && dayFormatter.date(from: $0.key).map { cal.component(.weekday, from: $0) } == weekday
  }.map(\.value)
  let base = sameDay.isEmpty ? past.filter { $0.key >= before(30) }.map(\.value) : sameDay
  guard !base.isEmpty else { return nil }
  let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  return DayAverage(
    cost: costByDay[date] ?? 0, average: base.reduce(0, +) / Double(base.count), days: base.count,
    weekday: sameDay.isEmpty ? nil : names[weekday - 1])
}

// Codex compresses finished rollouts to .jsonl.zst. Decoded in chunks by the statically linked libzstd.
final class ZstdStream {
  struct Failure: Error {}
  private let handle: FileHandle; private let stream: OpaquePointer; private let output: UnsafeMutableRawPointer;
  private let capacity = ZSTD_DStreamOutSize()
  private var input = Data(); private var position = 0; private var ended = false; private var pending = 0
  init?(_ handle: FileHandle) {
    guard let s = ZSTD_createDStream() else { return nil }; self.handle = handle; stream = s;
    output = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
  }
  deinit { ZSTD_freeDStream(stream); output.deallocate() }
  // Next decoded chunk, empty at the end. Corrupt or truncated frames throw.
  func read() throws -> Data {
    while true {
      if position == input.count && !ended {
        input = try handle.read(upToCount: ZSTD_DStreamInSize()) ?? Data(); position = 0; ended = input.isEmpty
      }
      var out = ZSTD_outBuffer(dst: output, size: capacity, pos: 0); let before = position
      let code = input.withUnsafeBytes { raw -> Int in
        var inb = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: position);
        let c = ZSTD_decompressStream(stream, &out, &inb); position = inb.pos; return c
      }
      guard ZSTD_isError(code) == 0 else { throw Failure() }
      // A call without progress only asks for the next frame header; 0 from the last real call means the frame is complete.
      if position > before || out.pos > 0 { pending = code }
      if out.pos > 0 { return Data(bytes: output, count: out.pos) }
      if ended { if pending != 0 { throw Failure() }; return Data() }
    }
  }
}

// Local token metadata only. Prompts and tool output never leave this reader.
// All collection state is protected by collectionLock.
final class Collector: @unchecked Sendable {
  private let collectionLock = NSLock()
  var groups: [String: UsageRow] = [:]; var seen = Set<String>(); var skipped = 0; var unreadable = 0
  // Per-hour rows for every day, for the calendar and the Today chart; a few thousand rows at most.
  var hourGroups: [String: UsageRow] = [:]
  // Per-session rows, keyed provider|session, with the session's first and last request and its latest folder.
  private struct SessionGroup { var rows: [String: UsageRow] = [:]; var start: Date; var end: Date; var cwd: String?; var cwdAt: Date? }
  private var sessionGroups: [String: SessionGroup] = [:]
  // The process environment, for CLAUDE_CONFIG_DIR and CODEX_HOME. Tests pass their own.
  let environment: [String: String]
  init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }
  private struct FileStamp: Equatable { let size: UInt64; let modified: Date; let created: Date; let inode: UInt64 }
  private enum CodexRecord {
    case session(String), model(String)
    // The thread a subagent was spawned from, and when this log started.
    case parent(String, String)
    // A settings snapshot: whether the thread runs in OpenAI's fast tier ("priority" in the logs), and when.
    case fast(Bool, String)
    // The session this log belongs to (the root thread for a subagent) and its working folder.
    case meta(String, String?)
    case usage(String, [String: Int], [String: Int]?)
  }
  private struct Message {
    let key: String; let ts: String; let model: String; let vals: [Int]; let score: Int
    // speed "fast", inference_geo "us" and the web searches the response ran.
    var fast: Bool; var us: Bool; var searches: Int
    // The Claude Code session (subagents carry their parent's) and the working folder of the request.
    var session: String?; var cwd: String?
  }
  // Claude Code names a session twice: the title the user set and the one it generated. The user's wins.
  private struct SessionTitle { var custom: String?; var ai: String? }
  static func tier(fast: Bool, long: Bool, us: Bool) -> String? {
    let flags = [fast ? "fast" : nil, long ? "long" : nil, us ? "us" : nil].compactMap { $0 }
    return flags.isEmpty ? nil : flags.joined(separator: "+")
  }
  // Where the agents keep their logs. Claude Code writes to ~/.claude, ~/.config/claude or CLAUDE_CONFIG_DIR, and
  // Codex to ~/.codex or CODEX_HOME, moving old sessions to archived_sessions. A folder reached twice through a link
  // is read once; records repeated across folders are deduplicated like any other.
  func roots(home: URL) -> (codex: [URL], claude: [URL]) {
    func folder(_ key: String) -> [URL] {
      guard let path = environment[key], !path.isEmpty else { return [] }
      return [URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)]
    }
    // realpath gives one spelling per folder (/var and /private/var included); a missing folder keeps its path.
    func unique(_ urls: [URL]) -> [URL] {
      var seen = Set<String>()
      return urls.map { url -> URL in
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
      }.filter { seen.insert($0.path).inserted }
    }
    let codex = ([home.appendingPathComponent(".codex")] + folder("CODEX_HOME")).flatMap {
      [$0.appendingPathComponent("sessions"), $0.appendingPathComponent("archived_sessions")]
    }
    let claude = ([home.appendingPathComponent(".claude"), home.appendingPathComponent(".config/claude")]
      + folder("CLAUDE_CONFIG_DIR")).map { $0.appendingPathComponent("projects") }
    return (unique(codex), unique(claude))
  }
  private struct FileRecords<T> {
    let stamp: FileStamp; let records: [T]; let skipped: Int; var titles: [String: SessionTitle] = [:]
  }
  private var codexCache: [String: FileRecords<CodexRecord>] = [:]
  private var claudeCache: [String: FileRecords<Message>] = [:]
  private(set) var filesRead = 0
  private var lastFiles: [String: FileStamp]?
  private var lastRevision = -1
  private var cachedDataset: Dataset?
  private(set) var scans = 0
  let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
  }()
  let plainISO = ISO8601DateFormatter()
  func integer(_ o: [String: Any], _ key: String) -> Int { max(0, (o[key] as? NSNumber)?.intValue ?? 0) }
  func lines(_ url: URL, _ block: ([String: Any]) -> Void) {
    guard let h = try? FileHandle(forReadingFrom: url) else { unreadable += 1; return }; defer { try? h.close() }
    let read: () throws -> Data
    if Collector.compressed(url) {
      guard let z = ZstdStream(h) else { unreadable += 1; return }; read = z.read
    } else {
      read = { try h.read(upToCount: 65536) ?? Data() }
    }
    var buffer = Data()
    func consume(_ line: Data) {
      // Foundation JSON objects must be released per record, not after a gigabyte scan.
      autoreleasepool {
        guard !line.isEmpty else { return }
        if let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
          block(value)
        } else {
          skipped += 1
        }
      }
    }
    while true {
      let hasData: Bool = autoreleasepool {
        let part: Data
        do { part = try read() } catch { unreadable += 1; return false }
        guard !part.isEmpty else { return false }
        buffer.append(part)
        // Remove consumed bytes once per chunk, avoiding repeated buffer mutations.
        var start = buffer.startIndex
        while let end = buffer[start...].firstIndex(of: 10) {
          consume(buffer.subdata(in: start..<end)); start = end + 1
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        return true
      }
      if !hasData { break }
    }
    if !buffer.isEmpty { consume(buffer) }
  }
  static func compressed(_ url: URL) -> Bool { url.lastPathComponent.hasSuffix(".jsonl.zst") }
  func files(_ root: URL) -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] };
    guard
      let e = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        errorHandler: { _, _ in
          self.unreadable += 1; return true
        })
    else { unreadable += 1; return [] };
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" || Collector.compressed($0) }.sorted {
      $0.path < $1.path
    }
  }
  // Cache token metadata only, never prompts, attachments, or tool output.
  private func codexRecords(_ url: URL, stamp: FileStamp?) -> [CodexRecord] {
    if let cached = codexCache[url.path], cached.stamp == stamp { skipped += cached.skipped; return cached.records }
    filesRead += 1
    let beforeSkipped = skipped, beforeUnreadable = unreadable
    var records: [CodexRecord] = []
    var metaSeen = false
    lines(url) { r in
      let type = r["type"] as? String ?? "", p = r["payload"] as? [String: Any] ?? [:]
      if type == "session_meta", let id = p["id"] as? String { records.append(.session(id)) }
      // Copied history repeats other threads' metadata; only the first session_meta describes this log.
      if type == "session_meta", !metaSeen {
        metaSeen = true
        if let parent = p["parent_thread_id"] as? String, !parent.isEmpty {
          records.append(.parent(parent, r["timestamp"] as? String ?? ""))
        }
        let root = (p["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? p["id"] as? String
        if let root { records.append(.meta(root, p["cwd"] as? String)) }
      }
      // Codex writes thread_settings_applied, a snapshot of the settings, before each turn. Older builds skip it
      // before the first turn. turn_context may carry the tier too.
      let tier =
        type == "turn_context"
        ? p["service_tier"] : (p["type"] as? String == "thread_settings_applied"
          ? (p["thread_settings"] as? [String: Any])?["service_tier"] : nil)
      if let tier = tier as? String {
        records.append(.fast(["fast", "priority"].contains(tier.lowercased()), r["timestamp"] as? String ?? ""))
      }
      if type == "turn_context" { records.append(.model(p["model"] as? String ?? "unknown")) }
      guard type == "event_msg", p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
        let raw = info["total_token_usage"] as? [String: Any]
      else { return }
      let total = raw.mapValues { ($0 as? NSNumber)?.intValue ?? 0 }
      let last = (info["last_token_usage"] as? [String: Any])?.mapValues { ($0 as? NSNumber)?.intValue ?? 0 }
      records.append(.usage(r["timestamp"] as? String ?? "", total, last))
    }
    if let stamp, beforeUnreadable == unreadable {
      codexCache[url.path] = FileRecords(stamp: stamp, records: records, skipped: skipped - beforeSkipped)
    } else {
      codexCache.removeValue(forKey: url.path)
    }
    return records
  }
  // The tier each Codex log starts in. A log with its own snapshots starts in the first one: older builds write
  // none before the first turn, and turns 1 and 2 nearly always share a tier. A subagent without snapshots runs in
  // its parent's tier when it was spawned; before the parent's first snapshot that is the parent's start tier.
  // Anything else starts in the standard tier.
  private static func startTiers(_ logs: [[CodexRecord]], date: (String) -> Date?) -> [Bool] {
    struct Log {
      var thread: String?; var parent: String?; var spawned: Date?; var snapshots: [(at: Date?, fast: Bool)] = []
    }
    let parsed = logs.map { records -> Log in
      var log = Log()
      for record in records {
        switch record {
        case .session(let id): if log.thread == nil { log.thread = id }
        case .parent(let id, let ts): log.parent = id; log.spawned = date(ts)
        case .fast(let value, let ts): log.snapshots.append((date(ts), value))
        default: break
        }
      }
      return log
    }
    // A rollout being compressed exists twice; either copy describes the thread.
    var byThread: [String: Log] = [:]
    for log in parsed {
      if let t = log.thread, byThread[t]?.snapshots.isEmpty ?? true { byThread[t] = log }
    }
    func tier(_ thread: String, at time: Date?, depth: Int) -> Bool? {
      guard depth < 8, let log = byThread[thread] else { return nil }
      if let first = log.snapshots.first {
        guard let time else { return first.fast }
        return log.snapshots.last { ($0.at ?? .distantPast) <= time }?.fast ?? first.fast
      }
      return log.parent.flatMap { tier($0, at: time ?? log.spawned, depth: depth + 1) }
    }
    return parsed.map { log in
      log.snapshots.first?.fast ?? log.parent.flatMap { tier($0, at: log.spawned, depth: 1) } ?? false
    }
  }
  private func claudeRecords(_ url: URL, stamp: FileStamp?) -> (
    records: [Message], titles: [String: SessionTitle]
  ) {
    if let cached = claudeCache[url.path], cached.stamp == stamp {
      skipped += cached.skipped; return (cached.records, cached.titles)
    }
    filesRead += 1
    let beforeSkipped = skipped, beforeUnreadable = unreadable
    var records: [Message] = []; var titles: [String: SessionTitle] = [:]
    lines(url) { r in
      if let type = r["type"] as? String, type == "custom-title" || type == "ai-title", let sid = r["sessionId"] as? String {
        var t = titles[sid] ?? SessionTitle()
        if let v = r["customTitle"] as? String, !v.isEmpty { t.custom = v }
        if let v = r["aiTitle"] as? String, !v.isEmpty { t.ai = v }
        titles[sid] = t; return
      }
      guard let m = r["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
        let model = m["model"] as? String, model != "<synthetic>", let id = m["id"] as? String ?? r["uuid"] as? String
      else { return }
      let key = (r["requestId"] as? String ?? "") + "|" + id, creation = u["cache_creation"] as? [String: Any] ?? [:]
      let w1 = self.integer(creation, "ephemeral_1h_input_tokens")
      let vals = [
        self.integer(u, "input_tokens"), self.integer(u, "cache_read_input_tokens"),
        max(0, self.integer(u, "cache_creation_input_tokens") - w1), w1, self.integer(u, "output_tokens"),
      ]
      let score = u.values.compactMap { ($0 as? NSNumber)?.intValue }.reduce(0, +)
      records.append(
        Message(
          key: key, ts: r["timestamp"] as? String ?? "", model: model, vals: vals, score: score,
          fast: u["speed"] as? String == "fast", us: u["inference_geo"] as? String == "us",
          searches: self.integer(u["server_tool_use"] as? [String: Any] ?? [:], "web_search_requests"),
          session: r["sessionId"] as? String, cwd: r["cwd"] as? String))
    }
    if let stamp, beforeUnreadable == unreadable {
      claudeCache[url.path] = FileRecords(
        stamp: stamp, records: records, skipped: skipped - beforeSkipped, titles: titles)
    } else {
      claudeCache.removeValue(forKey: url.path)
    }
    return (records, titles)
  }
  // Codex keeps thread names in session_index.jsonl next to sessions/, one line per rename; the last one wins.
  private func codexTitles(_ files: [URL]) -> [String: String] {
    var titles: [String: String] = [:]
    for url in files {
      guard let data = try? Data(contentsOf: url) else { continue }
      for line in data.split(separator: 10) {
        guard let r = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = r["id"] as? String,
          let name = r["thread_name"] as? String, !name.isEmpty
        else { continue }
        titles[id] = name
      }
    }
    return titles
  }
  func add(
    _ ts: String, _ provider: String, _ model: String, _ source: String, _ vals: [Int], tier: String? = nil,
    searches: Int = 0, session: String? = nil, cwd: String? = nil
  ) {
    guard ts.count >= 10 else { skipped += 1; return }
    let date = iso.date(from: ts) ?? plainISO.date(from: ts)
    guard let d = date else { skipped += 1; return }; let day = dayFormatter.string(from: d)
    func count(_ row: inout UsageRow) {
      row.input += max(0, vals[0]); row.cached += max(0, vals[1]); row.write += max(0, vals[2])
      row.write1h += max(0, vals[3]); row.output += max(0, vals[4]); row.requests += 1
      if searches > 0 { row.searches = (row.searches ?? 0) + searches }
    }
    var r = UsageRow(date: day, provider: provider, model: model, source: source, tier: tier)
    r = groups[r.id] ?? r; count(&r); groups[r.id] = r
    var h = UsageRow(
      date: day, provider: provider, model: model, source: source, hour: bratislava.component(.hour, from: d),
      tier: tier)
    h = hourGroups[h.id] ?? h; count(&h); hourGroups[h.id] = h
    guard let session, !session.isEmpty else { return }
    let key = provider + "|" + session
    var g = sessionGroups[key] ?? SessionGroup(start: d, end: d)
    g.start = min(g.start, d); g.end = max(g.end, d)
    if let cwd, !cwd.isEmpty, g.cwdAt.map({ d >= $0 }) ?? true { g.cwd = cwd; g.cwdAt = d }
    var s = UsageRow(date: day, provider: provider, model: model, source: source, tier: tier)
    s = g.rows[s.id] ?? s; count(&s); g.rows[s.id] = s
    sessionGroups[key] = g
  }
  func collect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Dataset {
    collectionLock.lock(); defer { collectionLock.unlock() }
    return autoreleasepool { collectSnapshot(home: home) }
  }
  private func collectSnapshot(home: URL) -> Dataset {
    groups.removeAll(); seen.removeAll(); hourGroups.removeAll(); sessionGroups.removeAll(); skipped = 0
    unreadable = 0
    // Retain only the small aggregate snapshot between refreshes.
    defer {
      groups.removeAll(keepingCapacity: false); seen.removeAll(keepingCapacity: false)
      hourGroups.removeAll(keepingCapacity: false); sessionGroups.removeAll(keepingCapacity: false)
    }
    let folders = roots(home: home)
    let codexFiles = folders.codex.flatMap(files), claudeFiles = folders.claude.flatMap(files)
    // A renamed Codex thread changes only the index, so it counts as a changed file too.
    var indexPaths = Set<String>()
    let indexFiles = folders.codex.map { $0.deletingLastPathComponent().appendingPathComponent("session_index.jsonl") }
      .filter { FileManager.default.fileExists(atPath: $0.path) && indexPaths.insert($0.path).inserted }
    var stamps: [String: FileStamp] = [:]
    for url in codexFiles + claudeFiles + indexFiles {
      if let a = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = a[.size] as? NSNumber, let modified = a[.modificationDate] as? Date,
        let created = a[.creationDate] as? Date, let inode = a[.systemFileNumber] as? NSNumber
      {
        stamps[url.path] = FileStamp(
          size: size.uint64Value, modified: modified, created: created, inode: inode.uint64Value)
      } else {
        unreadable += 1
      }
    }
    let revision = Pricing.revision
    if unreadable == 0, stamps == lastFiles, revision == lastRevision, var value = cachedDataset {
      value.updatedAt = plainISO.string(from: Date()); return value
    }
    scans += 1
    codexCache = codexCache.filter { stamps[$0.key] != nil }
    claudeCache = claudeCache.filter { stamps[$0.key] != nil }
    let codexLogs = codexFiles.map { ($0, codexRecords($0, stamp: stamps[$0.path])) }
    let startTier = Collector.startTiers(
      codexLogs.map { $0.1 }, date: { self.iso.date(from: $0) ?? self.plainISO.date(from: $0) })
    for (index, (path, records)) in codexLogs.enumerated() {
      // While Codex compresses, a rollout exists as .jsonl and .jsonl.zst; both must name the same session.
      var prev: [String: Int] = [:]; var model: String?; var fast = startTier[index]
      var session: String?; var cwd: String?
      var sid = Collector.compressed(path) ? String(path.lastPathComponent.dropLast(4)) : path.lastPathComponent
      // The first token_count can precede the first turn_context; hold those until the model is known.
      var pending: [(ts: String, vals: [Int], prompt: Int, fast: Bool)] = []
      func usage(_ ts: String, _ name: String, _ vals: [Int], prompt: Int, fast: Bool) {
        add(
          ts, "gpt", name, "Codex", vals,
          tier: Collector.tier(fast: fast, long: Pricing.isLong(name, prompt: prompt), us: false),
          session: session ?? sid, cwd: cwd)
      }
      func flush(_ name: String) {
        for p in pending { usage(p.ts, name, p.vals, prompt: p.prompt, fast: p.fast) }; pending = []
      }
      defer { flush("unknown") }
      for record in records {
        switch record {
        case .session(let id): sid = id
        case .model(let name): model = name; flush(name)
        case .parent: break
        case .meta(let root, let folder): session = root; cwd = folder
        case .fast(let value, _): fast = value
        case .usage(let ts, let t, let last):
          let signature = t.keys.sorted().map { "\($0):\(t[$0]!)" }.joined(separator: ","), key = sid + ts + signature
          guard !seen.contains(key) else { prev = t; continue }; seen.insert(key); guard t != prev else { continue }
          var delta = t.mapValues { _ in 0 }; for (k, v) in t { delta[k] = max(0, v - (prev[k] ?? 0)) }
          if prev.isEmpty || t.contains(where: { $0.value < (prev[$0.key] ?? 0) }) { if let last { delta = last } };
          prev = t
          guard delta.values.contains(where: { $0 > 0 }) else { continue }
          let inp = delta["input_tokens"] ?? 0, cache = delta["cached_input_tokens"] ?? 0,
            write = delta["cache_write_input_tokens"] ?? 0
          let vals = [inp - cache - write, cache, write, 0, delta["output_tokens"] ?? 0]
          // The last request's own prompt decides the long-context price; a delta can span several requests.
          let prompt = last?["input_tokens"] ?? inp
          if let model {
            usage(ts, model, vals, prompt: prompt, fast: fast)
          } else {
            pending.append((ts, vals, prompt, fast))
          }
        }
      }
    }
    var messages: [String: Message] = [:]
    var claudeTitles: [String: SessionTitle] = [:]
    for path in claudeFiles {
      let file = claudeRecords(path, stamp: stamps[path.path])
      for (sid, t) in file.titles {
        var title = claudeTitles[sid] ?? SessionTitle()
        title.custom = t.custom ?? title.custom; title.ai = t.ai ?? title.ai; claudeTitles[sid] = title
      }
      for message in file.records {
        guard let old = messages[message.key] else { messages[message.key] = message; continue }
        // The fullest copy of a streamed response wins; its modifiers and searches hold for every copy.
        var m = message.score >= old.score ? message : old
        m.fast = old.fast || message.fast; m.us = old.us || message.us
        m.searches = max(old.searches, message.searches)
        m.session = m.session ?? old.session ?? message.session; m.cwd = m.cwd ?? old.cwd ?? message.cwd
        messages[message.key] = m
      }
    }
    for m in messages.values {
      let prompt = m.vals[0] + m.vals[1] + m.vals[2] + m.vals[3]
      add(
        m.ts, "claude", m.model, "Claude Code", m.vals,
        tier: Collector.tier(fast: m.fast, long: Pricing.isLong(m.model, prompt: prompt), us: m.us),
        searches: m.searches, session: m.session, cwd: m.cwd)
    }
    let titles = codexTitles(indexFiles)
    var projects: [String: ProjectRef] = [:]
    func project(_ cwd: String?) -> ProjectRef {
      let key = cwd ?? ""
      if let p = projects[key] { return p }
      let p = projectOf(cwd: cwd, home: home.path) {
        FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git"))
      }
      projects[key] = p; return p
    }
    var sessions: [SessionUsage] = []
    for (key, g) in sessionGroups {
      let provider = String(key.prefix { $0 != "|" })
      let id = String(key.dropFirst(provider.count + 1))
      let ref: ProjectRef = project(g.cwd)
      var title: String? = titles[id]
      if provider == "claude" { title = claudeTitles[id]?.custom ?? claudeTitles[id]?.ai }
      let rows: [UsageRow] = g.rows.values.sorted { (a: UsageRow, b: UsageRow) -> Bool in a.id < b.id }
      sessions.append(
        SessionUsage(
          provider: provider, session: id, project: ref.name, folder: ref.folder, title: title, start: g.start,
          end: g.end, rows: rows))
    }
    sessions.sort { (a: SessionUsage, b: SessionUsage) -> Bool in a.start == b.start ? a.id < b.id : a.start < b.start }
    let result = Dataset(
      updatedAt: plainISO.string(from: Date()), rows: groups.values.sorted { $0.id < $1.id }, skipped: skipped,
      unreadable: unreadable, hourly: hourGroups.values.sorted { $0.id < $1.id }, sessions: sessions)
    // Retry unreadable files next time; a growing log may finish its last record later.
    lastFiles = unreadable == 0 ? stamps : nil; lastRevision = revision; cachedDataset = result
    return result
  }
}

func exact(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: "en_US"))) }
struct ExchangeRate: Codable {
  let usdPerEUR: Double
  let date: String
  static let bundled = ExchangeRate(usdPerEUR: 1.1539, date: "2026-09-15")
  func convert(_ usd: Double, currency: String) -> Double { currency == "EUR" ? usd / usdPerEUR : usd }
  static func parse(_ data: Data) -> ExchangeRate? {
    final class Reader: NSObject, XMLParserDelegate {
      var day: String?; var rate: Double?
      func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
      ) {
        if let date = attributes["time"] { day = date }
        if attributes["currency"] == "USD", let raw = attributes["rate"] { rate = Double(raw) }
      }
    }
    let reader = Reader(), parser = XMLParser(data: data); parser.delegate = reader
    guard parser.parse(), let rate = reader.rate, rate.isFinite, rate > 0, let day = reader.day,
      dayFormatter.date(from: day) != nil
    else { return nil }
    return ExchangeRate(usdPerEUR: rate, date: day)
  }
}
func currencyAmount(_ value: Double, _ currency: String) -> String {
  value.formatted(.currency(code: currency).locale(Locale(identifier: "en_US")))
}
// "$307.58 · ECB 1.1267 (2026-11-04)": the dollars behind a euro figure and the rate it was converted at.
func usdNote(_ usd: Double, rate: ExchangeRate) -> String {
  currencyAmount(usd, "USD") + " · ECB " + String(format: "%.4f", rate.usdPerEUR) + " (" + rate.date + ")"
}

func percent(_ v: Double) -> String { String(format: "%.0f %%", v * 100) }
// A category's share of all tokens. Input and output are often under 1 %, which a whole percent would round to 0,
// so shares that would print below 10 keep one decimal.
func share(_ n: Int, of total: Int) -> String {
  guard total > 0, n > 0 else { return total > 0 ? "0 %" : "" }
  let v = Double(n) / Double(total)
  if v < 0.001 { return "<0.1 %" }
  return v * 100 < 9.95 ? String(format: "%.1f %%", v * 100) : percent(v)
}
// The categories under the token and cost totals. Web search shows only when there was one.
func tokenDetails(_ b: Breakdown) -> [(String, String)] {
  func line(_ n: Int) -> String { exact(n) + (b.tokens > 0 ? " · " + share(n, of: b.tokens) : "") }
  return [
    ("Input", line(b.input)), ("Cache write", line(b.write)), ("Cache read", line(b.read)), ("Output", line(b.output)),
  ] + (b.searches > 0 ? [("Web search", exact(b.searches) + (b.searches == 1 ? " search" : " searches"))] : [])
}
func costDetails(_ b: Breakdown, _ money: (Double) -> String) -> [(String, String)] {
  [
    ("Input", money(b.cost.input)), ("Cache write", money(b.cost.write)), ("Cache read", money(b.cost.read)),
    ("Output", money(b.cost.output)),
  ] + (b.searches > 0 ? [("Web search", money(b.cost.search))] : [])
}
