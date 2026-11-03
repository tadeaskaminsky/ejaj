import Foundation
@main struct Tests {
  static func main() throws {
    precondition(exact(1234567890) == "1,234,567,890")
    let fx = ExchangeRate.parse(
      Data("<Cube><Cube time='2026-09-15'><Cube currency='USD' rate='1.1539'/></Cube></Cube>".utf8))!
    precondition(abs(fx.convert(115.39, currency: "EUR") - 100) < 0.000001)
    precondition(fx.convert(115.39, currency: "USD") == 115.39)
    precondition(ExchangeRate.parse(Data("<Cube time='2026-09-15' currency='USD' rate='0'/>".utf8)) == nil)
    precondition(ExchangeRate.parse(Data("invalid".utf8)) == nil)
    precondition(currencyAmount(fx.convert(115.39, currency: "EUR"), "EUR") == "€100.00")
    print("PASS: exact token formatting, ECB rate parsing, conversion direction, invalid rates")
    for (id, name) in [
      ("claude-opus-5-5", "Opus 5.5"), ("claude-fable-5-1", "Fable 5.1"), ("claude-opus-5", "Opus 5"),
      ("claude-opus-4-8", "Opus 4.8"), ("claude-haiku-5-5", "Haiku 5.5"), ("gpt-5.6-sol", "GPT-5.6 Sol"),
      ("gpt-6-astra", "GPT-6 Astra"), ("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark"), ("gpt-5.5", "GPT-5.5"),
      ("gpt-5-codex", "GPT-5 Codex"), ("codex-auto-review", "Codex Auto Review"), ("unknown", "Unknown model"),
      ("claude-opus-4-5-20251101", "Opus 4.5 20251101"),
    ] { precondition(modelName(id) == name, "\(id) → \(modelName(id))") }
    print("PASS: model display names")
    // 2026-11-03 is a Tuesday. Earlier Tuesdays 10 and 20, a Monday 100, a zero day and a Tuesday too old to count.
    let costs = [
      "2026-10-27": 10.0, "2026-10-20": 20.0, "2026-10-26": 100.0, "2026-10-13": 0, "2026-08-04": 500,
      "2026-11-03": 12, "2026-11-10": 999,
    ]
    let tue = dayAverage(costs, on: "2026-11-03")!
    precondition(tue.weekday == "Tuesday" && tue.average == 15 && tue.days == 2 && tue.difference == -3)
    precondition(tue.percent == -20 && tue.level == "Below average" && tue.basis == "average Tuesday")
    // No earlier Sunday: falls back to the 30 days before it (10, 20, 100, 12).
    let sun = dayAverage(costs, on: "2026-11-08")!
    precondition(sun.weekday == nil && sun.days == 4 && sun.average == 35.5 && sun.cost == 0)
    precondition(sun.level == "Way below average" && sun.basis == "30-day average")
    precondition(dayAverage(["2026-11-03": 5], on: "2026-11-03") == nil && dayAverage(costs, on: "bad") == nil)
    precondition(dayAverage(costs, on: "2026-11-10")!.level == "Way above average")
    print("PASS: calendar day against the weekday and 30-day average")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);
    defer { try? FileManager.default.removeItem(at: root) }
    let c = root.appendingPathComponent(".codex/sessions"), a = root.appendingPathComponent(".claude/projects")
    try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true);
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    func event(_ i: Int, _ o: Int) -> [String: Any] {
      [
        "timestamp": "2026-09-05T12:00:00Z", "type": "event_msg",
        "payload": [
          "type": "token_count",
          "info": [
            "total_token_usage": ["input_tokens": i, "cached_input_tokens": 20, "output_tokens": o],
            "last_token_usage": ["input_tokens": i, "cached_input_tokens": 20, "output_tokens": o],
          ],
        ],
      ]
    }
    // The first token_count arrives before turn_context names the model; it must still count for gpt-5.6-sol.
    let events: [[String: Any]] = [
      event(100, 10), ["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]], event(100, 10), event(150, 15),
    ]
    let lines = try events.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
      .joined(separator: "\n");
    try lines.write(to: c.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
    let msg: [String: Any] = [
      "timestamp": "2026-09-05T12:00:00Z", "requestId": "req",
      "message": [
        "id": "m", "model": "claude-opus-5",
        "usage": [
          "input_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 40,
          "cache_creation": ["ephemeral_1h_input_tokens": 30], "output_tokens": 10,
        ],
      ],
    ]
    let line = String(data: try JSONSerialization.data(withJSONObject: msg), encoding: .utf8)!;
    try (line + "\n" + line).write(to: a.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
    let collector = Collector(); let data = collector.collect(home: root);
    let g = data.rows.first { $0.provider == "gpt" }!; let cl = data.rows.first { $0.provider == "claude" }!
    precondition(g.input == 130 && g.cached == 20 && g.output == 15 && g.requests == 2)
    precondition(g.model == "gpt-5.6-sol" && !data.rows.contains { $0.model == "unknown" })
    // Hourly rows: 12:00Z is 14:00 in Bratislava; per-hour totals add up to the daily rows and stay out of rows.
    let hours = data.hourly ?? []
    precondition(hours.count == 2 && hours.allSatisfy { $0.hour == 14 && $0.date == "2026-09-05" })
    precondition(hours.reduce(0) { $0 + $1.tokens } == data.rows.reduce(0) { $0 + $1.tokens })
    precondition(data.rows.allSatisfy { $0.hour == nil })
    let legacy = try JSONDecoder().decode(
      Dataset.self,
      from: Data(
        "{\"version\":1,\"updatedAt\":\"x\",\"timezone\":\"Europe/Bratislava\",\"rows\":[],\"skipped\":0,\"unreadable\":0}"
          .utf8))
    precondition(legacy.hourly == nil)
    print("PASS: hourly rows, legacy snapshots without them")
    precondition(cl.write == 10 && cl.write1h == 30 && cl.requests == 1)
    let p = UsageRow(
      date: "", provider: "claude", model: "claude-opus-5", source: "test", input: 1_000_000, cached: 1_000_000,
      write: 1_000_000, write1h: 1_000_000, output: 1_000_000)
    precondition(p.cost == 46.75 && p.tokens == 5_000_000)
    // Dated prices: before the first entry the bundled price applies, afterwards the latest entry not after the row.
    let priceFile = root.appendingPathComponent("pricing.json")
    try """
    {"claude-opus-5": [{"from": "2026-10-01", "rates": [1, 1, 1, 1, 1]}, {"from": "2026-11-01", "rates": [2, 2, 2, 2, 2]}],
     "gpt-7": [10, 1, 12.5, 50, 20], "broken": "x"}
    """.write(to: priceFile, atomically: true, encoding: .utf8)
    Pricing.load(priceFile)
    precondition(Pricing.fileError?.contains("broken") == true)
    func priced(_ date: String, _ model: String = "claude-opus-5") -> Double? {
      UsageRow(date: date, provider: "claude", model: model, source: "test", input: 1_000_000).cost
    }
    precondition(priced("2026-09-30") == 5 && priced("2026-10-01") == 1 && priced("2026-10-31") == 1)
    precondition(
      priced("2026-11-01") == 2 && priced("2026-12-01", "gpt-7") == 10 && priced("2026-12-01", "gpt-8") == nil)
    Pricing.load(root.appendingPathComponent("missing.json"))
    precondition(Pricing.fileError == nil && priced("2026-12-01") == 5 && priced("2026-12-01", "gpt-7") == nil)
    print("PASS: pricing.json overrides, dated prices, bundled fallback")
    let out = String(data: try JSONEncoder().encode(data), encoding: .utf8)!;
    precondition(!out.contains("requestId") && !out.contains(root.path))
    func rowsJSON(_ d: Dataset) throws -> Data {
      let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(d.rows)
    }
    let baseline = try rowsJSON(data)
    let cached = collector.collect(home: root)
    precondition(collector.scans == 1 && collector.filesRead == 2 && (try! rowsJSON(cached)) == baseline)
    // Irrelevant records larger than a read chunk must not affect token totals.
    let large = String(
      data: try JSONSerialization.data(withJSONObject: [
        "type": "irrelevant", "content": String(repeating: "x", count: 200_000),
      ]), encoding: .utf8)!
    try (large + "\n" + lines).write(to: c.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
    let changed = collector.collect(home: root)
    precondition(collector.scans == 2 && collector.filesRead == 3 && (try! rowsJSON(changed)) == baseline)
    let appended = String(data: try JSONSerialization.data(withJSONObject: event(180, 20)), encoding: .utf8)!
    let handle = try FileHandle(forWritingTo: c.appendingPathComponent("one.jsonl")); try handle.seekToEnd();
    try handle.write(contentsOf: Data(("\n" + appended).utf8)); try handle.close()
    let updated = collector.collect(home: root).rows.first { $0.provider == "gpt" }!
    precondition(collector.scans == 3 && updated.input == 160 && updated.output == 20 && updated.requests == 3)
    // Truncation and removal must invalidate the cache, without accumulating old totals.
    try lines.write(to: c.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
    precondition((try! rowsJSON(collector.collect(home: root))) == baseline && collector.scans == 4)
    try FileManager.default.removeItem(at: a.appendingPathComponent("one.jsonl"))
    precondition(collector.collect(home: root).rows.allSatisfy { $0.provider == "gpt" } && collector.scans == 5)
    try line.write(to: a.appendingPathComponent("new.jsonl"), atomically: true, encoding: .utf8)
    precondition((try! rowsJSON(collector.collect(home: root))) == baseline && collector.scans == 6)
    // Duplicate sessions across cached files must still be counted only once.
    try lines.write(to: c.appendingPathComponent("two.jsonl"), atomically: true, encoding: .utf8)
    // Both files must identify the same session for cross-file deduplication.
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"shared-session\"}}\n"
    try (meta + lines).write(to: c.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
    try (meta + lines).write(to: c.appendingPathComponent("two.jsonl"), atomically: true, encoding: .utf8)
    precondition((try! rowsJSON(collector.collect(home: root))) == baseline)
    let reads = collector.filesRead
    try line.write(to: a.appendingPathComponent("duplicate.jsonl"), atomically: true, encoding: .utf8)
    precondition((try! rowsJSON(collector.collect(home: root))) == baseline && collector.filesRead == reads + 1)
    precondition(collector.groups.isEmpty && collector.seen.isEmpty)
    // Codex compresses finished rollouts to .jsonl.zst; totals must not change.
    func zst(_ text: String) -> Data {
      let src = Data(text.utf8); var dst = Data(count: ZSTD_compressBound(src.count))
      let n = dst.withUnsafeMutableBytes { d in
        src.withUnsafeBytes { s in ZSTD_compress(d.baseAddress, d.count, s.baseAddress, s.count, 3) }
      }
      precondition(ZSTD_isError(n) == 0); return dst.prefix(n)
    }
    let z = root.appendingPathComponent("zst"), zc = z.appendingPathComponent(".codex/sessions");
    try FileManager.default.createDirectory(at: zc, withIntermediateDirectories: true)
    let plain = zc.appendingPathComponent("rollout.jsonl"), packed = zc.appendingPathComponent("rollout.jsonl.zst")
    try lines.write(to: plain, atomically: true, encoding: .utf8)
    let zcollector = Collector(), plainRows = try rowsJSON(zcollector.collect(home: z))
    // Mid-compression both copies exist, here without session_meta, so only the file name identifies the session.
    try zst(lines).write(to: packed)
    precondition(
      (try! rowsJSON(zcollector.collect(home: z))) == plainRows && zcollector.filesRead == 2 && zcollector.scans == 2)
    try FileManager.default.removeItem(at: plain)
    precondition(
      (try! rowsJSON(zcollector.collect(home: z))) == plainRows && zcollector.filesRead == 2 && zcollector.scans == 3)
    precondition((try! rowsJSON(zcollector.collect(home: z))) == plainRows && zcollector.scans == 3)
    // Incompressible records span several input and output chunks; concatenated frames decode in order.
    let noise = String(
      data: try JSONSerialization.data(withJSONObject: [
        "type": "irrelevant", "content": (0..<20_000).map { _ in UUID().uuidString }.joined(),
      ]), encoding: .utf8)!
    let grown = zst(meta + noise + "\n" + lines) + zst("\n" + appended)
    precondition(grown.count > 2 * ZSTD_DStreamInSize())
    try grown.write(to: packed)
    let zrow = zcollector.collect(home: z).rows.first { $0.provider == "gpt" }!
    precondition(
      zcollector.filesRead == 3 && zcollector.scans == 4 && zrow.input == 160 && zrow.output == 20 && zrow.requests == 3
    )
    // A truncated archive is reported and reread on the next refresh, never cached.
    try grown.prefix(grown.count / 2).write(to: packed)
    precondition(zcollector.collect(home: z).unreadable == 1 && zcollector.filesRead == 4)
    precondition(zcollector.collect(home: z).unreadable == 1 && zcollector.filesRead == 5)
    try grown.write(to: packed)
    let restored = zcollector.collect(home: z)
    precondition(
      restored.unreadable == 0 && restored.rows.first { $0.provider == "gpt" }!.requests == 3
        && zcollector.filesRead == 6)
    print(
      "PASS: .jsonl.zst rollouts, .jsonl/.zst deduplication, multi-chunk and multi-frame decoding, truncated archives")
    print("PASS: refresh caching, append, truncation, creation, deletion, large records, released scratch state")
    print("PASS: native collector deduplication, cumulative deltas, cache split, pricing, metadata-only export")
  }
}
