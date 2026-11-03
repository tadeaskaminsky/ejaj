import Foundation

struct UsageRow: Codable, Identifiable {
  var date: String; var provider: String; var model: String; var source: String
  var input: Int = 0; var cached: Int = 0; var write: Int = 0; var write1h: Int = 0; var output: Int = 0;
  var requests: Int = 0
  // Set only on the hourly rows kept for the last two days (Dataset.hourly); daily rows leave it nil.
  var hour: Int? = nil
  var id: String { "\(date)|\(provider)|\(model)|\(source)" + (hour.map { "|\($0)" } ?? "") }
  var tokens: Int { input + cached + write + write1h + output }
  var cost: Double? {
    guard let p = Pricing.rates(model, on: date) else { return nil };
    return
      (Double(input) * p[0] + Double(cached) * p[1] + Double(write) * p[2] + Double(output) * p[3] + Double(write1h)
      * p[4]) / 1_000_000
  }
}
struct Dataset: Codable {
  var version: Int = 1; var updatedAt: String; var timezone: String = "Europe/Bratislava"; var rows: [UsageRow];
  var skipped: Int = 0; var unreadable: Int = 0
  // Per-hour rows for yesterday and today, for the Today chart. Older snapshots have none.
  var hourly: [UsageRow]? = nil
}
// Prices per 1M tokens: [input, cache read, cache write (5 min), output, cache write (1 h)].
struct PriceEntry: Equatable { var from: String; var rates: [Double] }
enum Pricing {
  // Standard API prices. gpt-5.3-codex-spark and gpt-5-codex are not on OpenAI's pricing page; their rates come from
  // third-party price lists and can be corrected in pricing.json.
  static let bundled: [String: [Double]] = [
    "gpt-6-astra": [10, 1, 12.5, 50, 20], "gpt-5.6-sol": [4, 0.4, 5, 20, 8], "gpt-5.6-terra": [2, 0.2, 2.5, 12, 4],
    "gpt-5.6-luna": [0.2, 0.02, 0.25, 1.2, 0.4], "claude-opus-5": [5, 0.5, 6.25, 25, 10],
    "claude-opus-4-8": [5, 0.5, 6.25, 25, 10], "claude-sonnet-5": [2, 0.2, 2.5, 10, 4],
    "claude-fable-5": [10, 1, 12.5, 50, 20], "claude-fable-5-1": [10, 0.25, 12.5, 50, 20],
    "claude-opus-5-5": [4, 0.2, 5, 20, 8], "claude-sonnet-5-5": [2, 0.2, 2.5, 10, 4],
    "claude-haiku-5-5": [0.1, 0.01, 0.125, 0.5, 0.2], "gpt-6-sol": [2, 0.2, 2.5, 10, 4],
    "gpt-6.1-sol": [2, 0.1, 2.5, 10, 4], "gpt-6.1-terra": [1, 0.05, 1.25, 5, 2],
    "gpt-6-luna": [0.1, 0.01, 0.125, 0.5, 0.2],
    "gpt-5.5": [5, 0.5, 6.25, 30, 10], "gpt-5.3-codex-spark": [1.75, 0.175, 2.1875, 14, 3.5],
    "gpt-5-codex": [1.25, 0.125, 1.5625, 10, 2.5], "codex-auto-review": [0, 0, 0, 0, 0],
  ]
  // ~/Library/Application Support/EJAJ/pricing.json adds or overrides models without a rebuild:
  //   {"gpt-7": [5, 0.5, 6.25, 30, 10],
  //    "claude-opus-5-5": [{"from": "2026-04-01", "rates": [4, 0.2, 5, 20, 8]}, {"from": "2027-01-01", "rates": [...]}]}
  // A bare array applies to every date. Dated entries apply from their day on; the latest one not after the row wins,
  // and days before the first entry fall back to the bundled price.
  nonisolated(unsafe) private(set) static var table: [String: [PriceEntry]] = bundledTable
  nonisolated(unsafe) private(set) static var fileError: String?
  static var bundledTable: [String: [PriceEntry]] { bundled.mapValues { [PriceEntry(from: "", rates: $0)] } }
  static var fileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EJAJ/pricing.json")
  }
  static func load(_ url: URL = fileURL) {
    table = bundledTable; fileError = nil
    guard let data = try? Data(contentsOf: url) else { return }
    guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      fileError = "pricing.json is not a JSON object of model → prices."; return
    }
    for (model, value) in raw.sorted(by: { $0.key < $1.key }) {
      if let rates = value as? [NSNumber], rates.count == 5 {
        table[model] = [PriceEntry(from: "", rates: rates.map(\.doubleValue))]
      } else if let list = value as? [[String: Any]], !list.isEmpty {
        let entries = list.compactMap { e -> PriceEntry? in
          guard let from = e["from"] as? String, dayFormatter.date(from: from) != nil,
            let rates = e["rates"] as? [NSNumber], rates.count == 5
          else { return nil }
          return PriceEntry(from: from, rates: rates.map(\.doubleValue))
        }
        guard entries.count == list.count else { fileError = "pricing.json: invalid entry for \(model)."; continue }
        table[model] = (table[model] ?? []) + entries.sorted { $0.from < $1.from }
      } else {
        fileError = "pricing.json: \(model) needs 5 prices or a list of {from, rates}."
      }
    }
  }
  static func rates(_ model: String, on date: String) -> [Double]? {
    table[model]?.last { $0.from <= date }?.rates
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
  var hourGroups: [String: UsageRow] = [:]; private var hourlyFrom = ""
  // Tests pin the first day that gets hourly rows; the app uses yesterday.
  var hourlyFromOverride: String?
  private struct FileStamp: Equatable { let size: UInt64; let modified: Date; let created: Date; let inode: UInt64 }
  private enum CodexRecord {
    case session(String), model(String)
    case usage(String, [String: Int], [String: Int]?)
  }
  private struct Message { let key: String; let ts: String; let model: String; let vals: [Int]; let score: Int }
  private struct FileRecords<T> { let stamp: FileStamp; let records: [T]; let skipped: Int }
  private var codexCache: [String: FileRecords<CodexRecord>] = [:]
  private var claudeCache: [String: FileRecords<Message>] = [:]
  private(set) var filesRead = 0
  private var lastFiles: [String: FileStamp]?
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
    lines(url) { r in
      let type = r["type"] as? String ?? "", p = r["payload"] as? [String: Any] ?? [:]
      if type == "session_meta", let id = p["id"] as? String { records.append(.session(id)) }
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
  private func claudeRecords(_ url: URL, stamp: FileStamp?) -> [Message] {
    if let cached = claudeCache[url.path], cached.stamp == stamp { skipped += cached.skipped; return cached.records }
    filesRead += 1
    let beforeSkipped = skipped, beforeUnreadable = unreadable
    var records: [Message] = []
    lines(url) { r in
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
      records.append(Message(key: key, ts: r["timestamp"] as? String ?? "", model: model, vals: vals, score: score))
    }
    if let stamp, beforeUnreadable == unreadable {
      claudeCache[url.path] = FileRecords(stamp: stamp, records: records, skipped: skipped - beforeSkipped)
    } else {
      claudeCache.removeValue(forKey: url.path)
    }
    return records
  }
  func add(_ ts: String, _ provider: String, _ model: String, _ source: String, _ vals: [Int]) {
    guard ts.count >= 10 else { skipped += 1; return }
    let date = iso.date(from: ts) ?? plainISO.date(from: ts)
    guard let d = date else { skipped += 1; return }; let day = dayFormatter.string(from: d)
    var r = UsageRow(date: day, provider: provider, model: model, source: source); let key = r.id; r = groups[key] ?? r
    r.input += max(0, vals[0]); r.cached += max(0, vals[1]); r.write += max(0, vals[2]); r.write1h += max(0, vals[3]);
    r.output += max(0, vals[4]); r.requests += 1; groups[key] = r
    if day >= hourlyFrom {
      var h = UsageRow(
        date: day, provider: provider, model: model, source: source, hour: bratislava.component(.hour, from: d))
      h = hourGroups[h.id] ?? h
      h.input += max(0, vals[0]); h.cached += max(0, vals[1]); h.write += max(0, vals[2]); h.write1h += max(0, vals[3]);
      h.output += max(0, vals[4]); h.requests += 1; hourGroups[h.id] = h
    }
  }
  func collect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Dataset {
    collectionLock.lock(); defer { collectionLock.unlock() }
    return autoreleasepool { collectSnapshot(home: home) }
  }
  private func collectSnapshot(home: URL) -> Dataset {
    groups.removeAll(); seen.removeAll(); hourGroups.removeAll(); skipped = 0; unreadable = 0
    hourlyFrom =
      hourlyFromOverride ?? dayFormatter.string(from: bratislava.date(byAdding: .day, value: -1, to: Date())!)
    // Retain only the small aggregate snapshot between refreshes.
    defer {
      groups.removeAll(keepingCapacity: false); seen.removeAll(keepingCapacity: false)
      hourGroups.removeAll(keepingCapacity: false)
    }
    let codexFiles = files(home.appendingPathComponent(".codex/sessions"))
    let claudeFiles = files(home.appendingPathComponent(".claude/projects"))
    var stamps: [String: FileStamp] = [:]
    for url in codexFiles + claudeFiles {
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
    if unreadable == 0, stamps == lastFiles, var value = cachedDataset {
      value.updatedAt = plainISO.string(from: Date()); return value
    }
    scans += 1
    codexCache = codexCache.filter { stamps[$0.key] != nil }
    claudeCache = claudeCache.filter { stamps[$0.key] != nil }
    for path in codexFiles {
      // While Codex compresses, a rollout exists as .jsonl and .jsonl.zst; both must name the same session.
      var prev: [String: Int] = [:]; var model: String?
      var sid = Collector.compressed(path) ? String(path.lastPathComponent.dropLast(4)) : path.lastPathComponent
      // The first token_count can precede the first turn_context; hold those until the model is known.
      var pending: [(String, [Int])] = []
      func flush(_ name: String) { for (ts, vals) in pending { add(ts, "gpt", name, "Codex", vals) }; pending = [] }
      defer { flush("unknown") }
      for record in codexRecords(path, stamp: stamps[path.path]) {
        switch record {
        case .session(let id): sid = id
        case .model(let name): model = name; flush(name)
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
          if let model { add(ts, "gpt", model, "Codex", vals) } else { pending.append((ts, vals)) }
        }
      }
    }
    var messages: [String: Message] = [:]
    for path in claudeFiles {
      for message in claudeRecords(path, stamp: stamps[path.path]) {
        if message.score >= (messages[message.key]?.score ?? -1) { messages[message.key] = message }
      }
    }
    for m in messages.values { add(m.ts, "claude", m.model, "Claude Code", m.vals) }
    let result = Dataset(
      updatedAt: plainISO.string(from: Date()), rows: groups.values.sorted { $0.id < $1.id }, skipped: skipped,
      unreadable: unreadable, hourly: hourGroups.values.sorted { $0.id < $1.id })
    // Retry unreadable files next time; a growing log may finish its last record later.
    lastFiles = unreadable == 0 ? stamps : nil; cachedDataset = result
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
