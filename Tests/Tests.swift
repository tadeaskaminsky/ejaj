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
      ("claude-opus-5-5", "Opus 5.5"), ("claude-fable-5-1", "Fable 5.1"), ("claude-fable-5-2", "Fable 5.2"), ("claude-opus-5", "Opus 5"),
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
    // Week of Mon 2026-11-02. Earlier weeks: 26 Oct (100 + 10), 19 Oct (20), 12 Oct (0, skipped); 3 Aug is too old.
    let running = weekAverage(costs, on: "2026-11-03", today: "2026-11-04")!
    precondition(running.monday == "2026-11-02" && running.days == 3 && running.span == "Mon–Wed")
    precondition(running.cost == 12 && running.average == 65 && running.fullAverage == 65 && running.weeks == 2)
    precondition(running.level == "Way below average")
    let monOnly = weekAverage(costs, on: "2026-11-02", today: "2026-11-02")!
    precondition(monOnly.days == 1 && monOnly.span == "Mon" && monOnly.average == 50 && monOnly.fullAverage == 65)
    let finished = weekAverage(costs, on: "2026-11-08", today: "2026-11-20")!
    precondition(finished.days == 7 && finished.span == "week" && finished.cost == 12 && finished.monday == "2026-11-02")
    let next = weekAverage(costs, on: "2026-11-12", today: "2026-11-20")!
    precondition(next.monday == "2026-11-09" && next.cost == 999 && next.weeks == 3 && next.level == "Way above average")
    precondition(weekAverage(costs, on: "2026-11-20", today: "2026-11-04") == nil)
    precondition(weekAverage(["2026-11-03": 5], on: "2026-11-03", today: "2026-11-04") == nil)
    print("PASS: calendar week against the average week, running weeks against the same days")

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
    let collector = Collector(environment: [:]); let data = collector.collect(home: root);
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
    let zcollector = Collector(environment: [:]), plainRows = try rowsJSON(zcollector.collect(home: z))
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

    // Price modifiers: each row's tier multiplies the model's list rates.
    Pricing.load(root.appendingPathComponent("missing.json"))
    func row(_ model: String, _ tier: String?, provider: String = "claude", searches: Int? = nil) -> UsageRow {
      UsageRow(
        date: "2026-11-05", provider: provider, model: model, source: "test", input: 1_000_000, cached: 1_000_000,
        write: 1_000_000, write1h: 1_000_000, output: 1_000_000, tier: tier, searches: searches)
    }
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
    // Opus 5.5: $4 input, $0.20 cache read, $5 and $8 writes, $20 output; fast mode doubles all of it.
    precondition(near(row("claude-opus-5-5", nil).cost, 37.2) && near(row("claude-opus-5-5", "fast").cost, 74.4))
    precondition(near(row("claude-opus-5-5", "fast+us").cost, 74.4 * 1.1))
    precondition(near(row("claude-opus-5-5", "us").cost, 37.2 * 1.1))
    // Haiku 5.5 over 100K: $0.50 input, $0.05 cache read, $0.625 and $1 writes, $2.50 output.
    precondition(near(row("claude-haiku-5-5", nil).cost, 0.935) && near(row("claude-haiku-5-5", "long").cost, 4.675))
    // Sonnet 5.5 cache reads are 0.05x input. A model without a fast price keeps its list price.
    precondition(near(row("claude-sonnet-5-5", nil).costParts?.read, 0.1))
    precondition(row("claude-fable-5-1", "fast").cost == row("claude-fable-5-1", nil).cost)
    // Fable 5.2: $8 input, $0.20 cache read, $10 and $16 writes, $40 output; fast mode doubles all of it.
    precondition(near(row("claude-fable-5-2", nil).cost, 74.2) && near(row("claude-fable-5-2", "fast").cost, 148.4))
    precondition(near(row("claude-fable-5-2", "fast+us").cost, 148.4 * 1.1))
    let fable = row("claude-fable-5-2", nil).costParts
    precondition(near(fable?.input, 8) && near(fable?.read, 0.2) && near(fable?.write, 26) && near(fable?.output, 40))
    var fable5m = row("claude-fable-5-2", nil)
    fable5m.write1h = 0
    precondition(near(fable5m.costParts?.write, 10))
    // OpenAI long context: 2x input-side, 1.5x output. gpt-5.5 fast is 2.5x.
    let longRow = row("gpt-6.1-sol", "long", provider: "gpt")
    precondition(near(longRow.costParts?.input, 4) && near(longRow.costParts?.output, 15))
    precondition(near(longRow.costParts?.read, 0.2) && near(row("gpt-5.5", "fast", provider: "gpt").costParts?.output, 75))
    // Web searches: $10 per 1,000, on top of the tokens.
    let searched = row("claude-opus-5-5", nil, searches: 1000)
    precondition(near(searched.cost, 47.2) && near(searched.costParts?.search, 10) && searched.tokens == 5_000_000)
    let split = breakdown([searched, row("claude-unpriced", "fast")])
    precondition(split.input == 2_000_000 && split.write == 4_000_000 && split.read == 2_000_000)
    precondition(split.output == 2_000_000 && split.searches == 1000 && near(split.cost.total, 47.2))
    precondition(near(split.cost.write, 13) && split.tokens == 10_000_000)
    precondition(
      usdNote(307.58, rate: ExchangeRate(usdPerEUR: 1.1267, date: "2026-11-04")) == "$307.58 · ECB 1.1267 (2026-11-04)")
    print("PASS: fast, US-only, long-context and web search prices, cost breakdown, USD note")

    // The collector sorts every request into its tier.
    let t = root.appendingPathComponent("tiers"), tc = t.appendingPathComponent(".codex/sessions")
    let tp = t.appendingPathComponent(".claude/projects/p")
    try FileManager.default.createDirectory(at: tc, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tp, withIntermediateDirectories: true)
    func json(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
    func claude(_ id: String, _ model: String, _ usage: [String: Any]) -> String {
      json(["timestamp": "2026-11-05T09:00:00Z", "requestId": "r-" + id, "message": ["id": id, "model": model, "usage": usage]])
    }
    let claudeLines = [
      // A streamed response: the first copy reports the searches, the fuller second copy wins on tokens.
      claude(
        "fast", "claude-opus-5-5",
        ["input_tokens": 1, "output_tokens": 1, "speed": "fast", "server_tool_use": ["web_search_requests": 2]]),
      claude("fast", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 10, "speed": "fast"]),
      claude("us", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 1, "inference_geo": "us"]),
      claude("big", "claude-haiku-5-5", ["input_tokens": 5, "cache_read_input_tokens": 150_000, "output_tokens": 1]),
      claude("small", "claude-haiku-5-5", ["input_tokens": 5, "cache_read_input_tokens": 50_000, "output_tokens": 1]),
      claude("plain", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 1, "speed": "standard", "inference_geo": "global"]),
    ]
    try claudeLines.joined(separator: "\n").write(to: tp.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    func tokenCount(_ ts: String, _ input: Int, _ cached: Int, _ output: Int, total: (Int, Int, Int)) -> String {
      json([
        "timestamp": ts, "type": "event_msg",
        "payload": [
          "type": "token_count",
          "info": [
            "total_token_usage": ["input_tokens": total.0, "cached_input_tokens": total.1, "output_tokens": total.2],
            "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
          ],
        ],
      ])
    }
    let codexLines = [
      json(["type": "session_meta", "payload": ["id": "tiered"]]),
      json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol", "service_tier": "priority"]]),
      tokenCount("2026-11-05T09:00:00Z", 300_000, 280_000, 10, total: (300_000, 280_000, 10)),
      json(["type": "event_msg", "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": "default"]]]),
      tokenCount("2026-11-05T09:01:00Z", 1000, 0, 5, total: (301_000, 280_000, 15)),
      // A turn without a tier keeps the last one.
      json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]]),
      tokenCount("2026-11-05T09:02:00Z", 1000, 0, 5, total: (302_000, 280_000, 20)),
    ]
    try codexLines.joined(separator: "\n").write(to: tc.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
    let tcollector = Collector(environment: [:])
    func tiers(_ d: Dataset) -> [String: UsageRow] {
      Dictionary(uniqueKeysWithValues: d.rows.map { ($0.model + "|" + ($0.tier ?? "-"), $0) })
    }
    var byTier = tiers(tcollector.collect(home: t))
    precondition(byTier.count == 7, "\(byTier.keys.sorted())")
    let fastRow = byTier["claude-opus-5-5|fast"]!
    precondition(fastRow.output == 10 && fastRow.requests == 1 && fastRow.searches == 2)
    precondition(byTier["claude-opus-5-5|us"]!.requests == 1 && byTier["claude-opus-5-5|-"]!.searches == nil)
    precondition(byTier["claude-haiku-5-5|long"]!.cached == 150_000 && byTier["claude-haiku-5-5|-"]!.cached == 50_000)
    let fastLong = byTier["gpt-6.1-sol|fast+long"]!, standard = byTier["gpt-6.1-sol|-"]!
    precondition(fastLong.input == 20_000 && fastLong.cached == 280_000 && fastLong.requests == 1)
    precondition(standard.requests == 2 && standard.input == 2000)
    let hourlyTiers = Set((tcollector.collect(home: t).hourly ?? []).compactMap(\.tier))
    precondition(hourlyTiers == ["fast", "us", "long", "fast+long"] && tcollector.scans == 1)
    print("PASS: speed, inference_geo, web searches, long prompts and Codex fast tier sorted into tiers")

    // pricing.json object form: rates with modifiers, flat prices, and errors that leave the model alone.
    try """
    {"claude-haiku-5-5": {"longContext": {"above": 200000, "input": 3, "output": 3}},
     "claude-opus-5-5": {"rates": [1, 1, 1, 1, 1], "fast": 3},
     "claude-opus-5": {"fast": true}, "claude-sonnet-5-5": {"rates": [1, 1, 1, 1]},
     "usOnlyMultiplier": 1.2, "webSearch": 0.02}
    """.write(to: priceFile, atomically: true, encoding: .utf8)
    let revision = Pricing.revision
    Pricing.load(priceFile)
    precondition(Pricing.fileError?.contains("claude-") == true && Pricing.revision == revision + 1)
    precondition(near(row("claude-opus-5-5", "fast").cost, 15) && near(row("claude-opus-5-5", "us").cost, 6))
    precondition(near(row("claude-opus-5", "fast").cost, 2 * 46.75) && near(row("claude-sonnet-5-5", nil).costParts?.read, 0.1))
    precondition(near(row("claude-opus-5-5", nil, searches: 10).costParts?.search, 0.2))
    // A higher threshold moves the 150K Haiku prompt back to the list price on the next refresh.
    byTier = tiers(tcollector.collect(home: t))
    precondition(tcollector.scans == 2 && byTier["claude-haiku-5-5|long"] == nil && byTier["claude-haiku-5-5|-"]!.requests == 2)
    try #"{"claude-haiku-5-5": {"longContext": null}, "gpt-6.1-sol": {"longContext": {"above": 1}}}"#
      .write(to: priceFile, atomically: true, encoding: .utf8)
    Pricing.load(priceFile)
    precondition(!Pricing.isLong("claude-haiku-5-5", prompt: 10_000_000) && Pricing.isLong("gpt-6.1-sol", prompt: 272_001))
    precondition(Pricing.fileError?.contains("gpt-6.1-sol") == true)
    precondition(tiers(tcollector.collect(home: t))["claude-haiku-5-5|long"] == nil && tcollector.scans == 3)
    // The file Edit prices writes the first time loads back to exactly the bundled prices.
    let seed = root.appendingPathComponent("seed.json"); try Pricing.seedJSON().write(to: seed)
    Pricing.load(seed)
    precondition(Pricing.fileError == nil && Pricing.table == Pricing.bundledTable)
    precondition(Pricing.modifiers == Pricing.bundledModifiers && Pricing.usOnly == 1.1 && Pricing.webSearch == 0.01)
    precondition(tiers(tcollector.collect(home: t))["claude-haiku-5-5|long"] != nil)
    print("PASS: pricing.json modifiers, flat prices, invalid entries, re-sorting tiers, seeded file")

    // Archived Codex sessions, ~/.config/claude, CLAUDE_CONFIG_DIR and CODEX_HOME; a linked folder counts once.
    let f = root.appendingPathComponent("folders")
    let custom = f.appendingPathComponent("custom"), codexHome = f.appendingPathComponent("codex-home")
    for dir in [
      f.appendingPathComponent(".codex/archived_sessions"), f.appendingPathComponent(".config/claude/projects/p"),
      custom.appendingPathComponent("projects/p"), codexHome.appendingPathComponent("sessions"),
    ] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    try FileManager.default.createSymbolicLink(at: f.appendingPathComponent(".claude"), withDestinationURL: custom)
    func session(_ id: String) -> String {
      json(["type": "session_meta", "payload": ["id": id]]) + "\n"
        + json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]]) + "\n"
        + tokenCount("2026-11-05T09:00:00Z", 100, 0, 1, total: (100, 0, 1))
    }
    try session("archived").write(
      to: f.appendingPathComponent(".codex/archived_sessions/a.jsonl"), atomically: true, encoding: .utf8)
    try session("home").write(to: codexHome.appendingPathComponent("sessions/h.jsonl"), atomically: true, encoding: .utf8)
    try claude("config", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 1]).write(
      to: f.appendingPathComponent(".config/claude/projects/p/x.jsonl"), atomically: true, encoding: .utf8)
    // The broken line counts as skipped once: a folder reached through a link and an environment variable is read once.
    try (claude("custom", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 1]) + "\nnot json").write(
      to: custom.appendingPathComponent("projects/p/y.jsonl"), atomically: true, encoding: .utf8)
    let fcollector = Collector(environment: ["CLAUDE_CONFIG_DIR": custom.path, "CODEX_HOME": codexHome.path])
    let found = fcollector.collect(home: f)
    precondition(fcollector.filesRead == 4 && found.skipped == 1, "\(fcollector.filesRead) \(found.skipped)")
    precondition(found.rows.first { $0.provider == "gpt" }!.requests == 2)
    precondition(found.rows.first { $0.provider == "claude" }!.requests == 2)
    let plainHome = Collector(environment: [:]).collect(home: f)
    precondition(plainHome.rows.first { $0.provider == "gpt" }!.requests == 1)
    precondition(plainHome.rows.first { $0.provider == "claude" }!.requests == 2)
    print("PASS: archived Codex sessions, ~/.config/claude, CLAUDE_CONFIG_DIR, CODEX_HOME, linked folders once")

    // Codex writes thread_settings_applied before each turn, and builds before 0.163 skip the first turn.
    // A log starts in its first snapshot's tier; a spawned subagent runs in its parent's tier when it was spawned.
    let s = root.appendingPathComponent("spawn"), sc = s.appendingPathComponent(".codex/sessions")
    try FileManager.default.createDirectory(at: sc, withIntermediateDirectories: true)
    func sessionMeta(_ id: String, _ ts: String, parent: String? = nil) -> String {
      var p: [String: Any] = ["id": id]
      if let parent { p["parent_thread_id"] = parent }
      return json(["timestamp": ts, "type": "session_meta", "payload": p])
    }
    func settings(_ ts: String, _ tier: String) -> String {
      json([
        "timestamp": ts, "type": "event_msg",
        "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": tier]],
      ])
    }
    let context = json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]])
    func one(_ ts: String) -> String { tokenCount(ts, 100, 0, 1, total: (100, 0, 1)) }
    let spawnLogs: [String: [String]] = [
      // Turn 1 runs before the first snapshot, turn 2 after it, turn 3 after a switch back to the standard tier.
      "parent": [
        sessionMeta("parent", "2026-11-05T09:00:00Z"), context, one("2026-11-05T09:01:00Z"),
        settings("2026-11-05T09:05:00Z", "priority"), tokenCount("2026-11-05T09:06:00Z", 100, 0, 1, total: (200, 0, 2)),
        settings("2026-11-05T09:10:00Z", "default"), tokenCount("2026-11-05T09:11:00Z", 100, 0, 1, total: (300, 0, 3)),
      ],
      // Spawned during the parent's first turn, before its first snapshot.
      "early": [sessionMeta("early", "2026-11-05T09:02:00Z", parent: "parent"), context, one("2026-11-05T09:03:00Z")],
      // Spawned after the parent switched back.
      "late": [sessionMeta("late", "2026-11-05T09:12:00Z", parent: "parent"), context, one("2026-11-05T09:13:00Z")],
      // A subagent of a subagent follows the chain up.
      "nested": [sessionMeta("nested", "2026-11-05T09:04:00Z", parent: "early"), context, one("2026-11-05T09:04:30Z")],
      // Neither a snapshot nor a parent.
      "alone": [sessionMeta("alone", "2026-11-05T09:00:00Z"), context, one("2026-11-05T09:01:00Z")],
    ]
    for (name, content) in spawnLogs {
      try content.joined(separator: "\n").write(
        to: sc.appendingPathComponent(name + ".jsonl"), atomically: true, encoding: .utf8)
    }
    let spawned = Collector(environment: [:]).collect(home: s).rows
    let fastRequests = spawned.filter { $0.tier == "fast" }.reduce(0) { $0 + $1.requests }
    let listRequests = spawned.filter { $0.tier == nil }.reduce(0) { $0 + $1.requests }
    // Fast: parent turns 1 and 2, early, nested. Standard: parent turn 3, late, alone.
    precondition(fastRequests == 4 && listRequests == 3, "fast \(fastRequests), standard \(listRequests)")
    print("PASS: Codex start tier from the first snapshot, subagents in their parent's tier at spawn")

    // Review probes: prompt sizes, merged flags, the tier kept across turns, CLAUDE_CONFIG_DIR on its own.
    let q = root.appendingPathComponent("probe"), qc = q.appendingPathComponent(".codex/sessions")
    let qp = q.appendingPathComponent(".claude/projects/p")
    try FileManager.default.createDirectory(at: qc, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: qp, withIntermediateDirectories: true)
    try [
      // Cache writes count toward Haiku's prompt; the winning copy of a stream lacks the flags the first one had.
      claude("w", "claude-haiku-5-5", ["input_tokens": 5, "cache_creation_input_tokens": 120_000, "output_tokens": 1]),
      claude("s", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 1, "speed": "fast", "inference_geo": "us"]),
      claude("s", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 10]),
    ].joined(separator: "\n").write(to: qp.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    try [
      json(["type": "session_meta", "payload": ["id": "probe"]]),
      json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol", "service_tier": "fast"]]),
      tokenCount("2026-11-05T09:00:00Z", 1000, 0, 5, total: (1000, 0, 5)),
      json(["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]]),
      tokenCount("2026-11-05T09:01:00Z", 1000, 0, 5, total: (2000, 0, 10)),
      // The totals grew by 400K, but the last request's own prompt was 100K: not a long prompt.
      tokenCount("2026-11-05T09:02:00Z", 100_000, 0, 5, total: (402_000, 0, 15)),
    ].joined(separator: "\n").write(to: qc.appendingPathComponent("c.jsonl"), atomically: true, encoding: .utf8)
    let probe = tiers(Collector(environment: [:]).collect(home: q))
    precondition(probe["claude-haiku-5-5|long"]?.requests == 1, "\(probe.keys.sorted())")
    precondition(probe["claude-opus-5-5|fast+us"]?.output == 10, "\(probe.keys.sorted())")
    precondition(probe["gpt-6.1-sol|fast+long"] == nil && probe["gpt-6.1-sol|fast"]?.requests == 3, "\(probe.keys.sorted())")
    let e = root.appendingPathComponent("envonly"), ecustom = e.appendingPathComponent("custom")
    try FileManager.default.createDirectory(
      at: ecustom.appendingPathComponent("projects/p"), withIntermediateDirectories: true)
    try claude("env", "claude-opus-5-5", ["input_tokens": 1, "output_tokens": 1]).write(
      to: ecustom.appendingPathComponent("projects/p/z.jsonl"), atomically: true, encoding: .utf8)
    let envOnly = Collector(environment: ["CLAUDE_CONFIG_DIR": ecustom.path]).collect(home: e.appendingPathComponent("home"))
    precondition(envOnly.rows.first { $0.provider == "claude" }?.requests == 1)
    print("PASS: prompt sizes with cache writes and last requests, merged stream flags, CLAUDE_CONFIG_DIR alone")

    // Fast prices per family, cache writes under OpenAI's long context, and the "over" boundaries.
    let missing = root.appendingPathComponent("missing.json")
    Pricing.load(missing)
    precondition(near(row("gpt-6.1-sol", "fast", provider: "gpt").costParts?.output, 20))
    precondition(near(row("gpt-5.6-sol", "fast", provider: "gpt").costParts?.input, 8))
    precondition(near(row("claude-opus-4-8", "fast").cost, 2 * 46.75))
    precondition(near(row("gpt-6.1-sol", "long", provider: "gpt").costParts?.write, 13))
    precondition(!Pricing.isLong("claude-haiku-5-5", prompt: 100_000) && Pricing.isLong("claude-haiku-5-5", prompt: 100_001))
    precondition(!Pricing.isLong("gpt-6.1-sol", prompt: 272_000) && Pricing.isLong("gpt-6.1-sol", prompt: 272_001))
    // Removing an override from pricing.json takes it away on the next load.
    try #"{"claude-opus-5-5": {"fast": 3}, "usOnlyMultiplier": 1.5, "webSearch": 1}"#
      .write(to: priceFile, atomically: true, encoding: .utf8)
    Pricing.load(priceFile)
    precondition(near(row("claude-opus-5-5", "fast").cost, 111.6) && Pricing.usOnly == 1.5 && Pricing.webSearch == 1)
    Pricing.load(missing)
    precondition(near(row("claude-opus-5-5", "fast").cost, 74.4) && Pricing.usOnly == 1.1 && Pricing.webSearch == 0.01)
    // Every broken entry is named and leaves its model, or the flat price, as bundled.
    try """
    {"claude-opus-5-5": {"fast": 3, "rates": [1, 1, 1, 1]}, "claude-opus-5": [true, 0.5, 6.25, 25, 10],
     "claude-fable-5": [-1, 1, 12.5, 50, 20],
     "claude-haiku-5-5": {"longContext": {"above": 1, "input": 2, "output": 2, "cacheRead": 2}},
     "claude-sonnet-5": [{"from": "2026-01-01", "rates": [1, 1, 1, 1, 1]}, {"from": "bad", "rates": [1, 1, 1, 1, 1]}],
     "usOnlyMultiplier": 0, "webSearch": "free"}
    """.write(to: priceFile, atomically: true, encoding: .utf8)
    Pricing.load(priceFile)
    for name in [
      "claude-opus-5-5", "claude-opus-5", "claude-fable-5", "claude-haiku-5-5", "claude-sonnet-5", "usOnlyMultiplier",
      "webSearch",
    ] { precondition(Pricing.fileError?.contains(name) == true, "\(name): \(Pricing.fileError ?? "nil")") }
    precondition(near(row("claude-opus-5-5", "fast").cost, 74.4) && near(row("claude-opus-5", nil).cost, 46.75))
    precondition(near(row("claude-fable-5", nil).costParts?.input, 10) && Pricing.isLong("claude-haiku-5-5", prompt: 100_001))
    precondition(near(row("claude-sonnet-5", nil).costParts?.input, 2) && Pricing.usOnly == 1.1 && Pricing.webSearch == 0.01)
    Pricing.load(missing)
    // Edit prices writes the modifiers and the flat prices, not only the rates.
    let seedObject = try JSONSerialization.jsonObject(with: Pricing.seedJSON()) as! [String: Any]
    let haikuSeed = seedObject["claude-haiku-5-5"] as? [String: Any]
    precondition((haikuSeed?["longContext"] as? [String: Any])?["above"] as? Int == 100_000)
    precondition((seedObject["claude-opus-5-5"] as? [String: Any])?["fast"] as? Double == 2)
    precondition(seedObject["usOnlyMultiplier"] as? Double == 1.1 && seedObject["webSearch"] as? Double == 0.01)
    precondition(seedObject["claude-fable-5-1"] is [Any])
    print("PASS: fast prices per family, boundaries, overrides removed on reload, every broken entry named, seed shape")

    // A row saved by 1.8 has no tier or searches and keeps its price.
    let oldRow = try JSONDecoder().decode(
      UsageRow.self,
      from: Data(
        #"{"date":"2026-11-01","provider":"claude","model":"claude-opus-5-5","source":"Claude Code","input":1000000,"cached":0,"write":0,"write1h":0,"output":0,"requests":1}"#
          .utf8))
    precondition(oldRow.tier == nil && oldRow.searches == nil && near(oldRow.cost, 4))
    // Shares keep a decimal below 10 %, and tiny ones read "<0.1 %".
    precondition(share(1, of: 10_000) == "<0.1 %" && share(994, of: 10_000) == "9.9 %" && share(999, of: 10_000) == "10 %")
    precondition(share(0, of: 10) == "0 %" && share(5, of: 0) == "")
    let details = tokenDetails(Breakdown(input: 1, write: 0, read: 9_999, output: 0, searches: 1))
    precondition(details.map { $0.0 } == ["Input", "Cache write", "Cache read", "Output", "Web search"])
    precondition(details[0].1 == "1 · <0.1 %" && details[2].1 == "9,999 · 100 %" && details[4].1 == "1 search")
    let costLines = costDetails(Breakdown(cost: CostParts(input: 1, write: 2, read: 3, output: 4)), { String($0) })
    precondition(costLines.map { $0.1 } == ["1.0", "2.0", "3.0", "4.0"])
    print("PASS: rows saved by 1.8, share formatting, card details")

    // Count from: a day of use after 30 or more idle days can start the history. This Mac's own gaps: one
    // test session on 1 Oct 2025, regular use from 28 Apr 2026, and 37 idle days before 3 Jul 2026.
    func day(_ date: String, _ provider: String = "gpt") -> UsageRow {
      UsageRow(date: date, provider: provider, model: "gpt-5.5", source: "test", input: 1)
    }
    let history = ["2025-10-01", "2026-04-28", "2026-05-18", "2026-05-26", "2026-07-03"].map { day($0) }
    precondition(
      restarts(history) == [Restart(day: "2026-04-28", idle: 208), Restart(day: "2026-07-03", idle: 37)])
    precondition(restarts(history, minIdle: 38) == [Restart(day: "2026-04-28", idle: 208)])
    // 30 idle days count, 29 don't. Across the October clock change a day is still a day.
    precondition(restarts([day("2026-09-30"), day("2026-10-31")]) == [Restart(day: "2026-10-31", idle: 30)])
    precondition(restarts([day("2026-10-01"), day("2026-10-31")]).isEmpty)
    // Two providers on one day and an unsorted history give the same days.
    precondition(restarts([day("2026-07-03"), day("2026-04-28", "claude"), day("2026-04-28")]).map(\.day) == ["2026-07-03"])
    precondition(restarts([]).isEmpty && restarts([day("2026-11-06")]).isEmpty)
    precondition(counted(history, from: "2026-04-28").map(\.date) == Array(history.map(\.date).dropFirst()))
    precondition(counted(history, from: nil).count == 5 && counted(history, from: "2026-12-01").isEmpty)
    print("PASS: Count from days after 30 idle days, days left out before it")
    try planTests()
  }
  static func planTests() throws {
    let usage = Data(
      #"""
      {"five_hour": {"utilization": 32.0, "resets_at": "2026-11-06T17:09:59.555Z"},
       "seven_day": {"utilization": 76, "resets_at": "2026-11-07T05:59:59+00:00"},
       "seven_day_opus": null, "seven_day_sonnet": {"utilization": 140, "resets_at": null},
       "model_scoped": [{"display_name": "Fable", "utilization": 68.5, "resets_at": "2026-11-07T05:59:59.555Z"},
                        {"display_name": "Broken", "utilization": true}]}
      """#.utf8)
    let limits = parsePlanLimits(usage)!
    precondition(limits.fiveHour?.used == 32 && limits.weekly?.used == 76)
    precondition(limits.fiveHour?.resetsAt == isoDate("2026-11-06T17:09:59.555Z") && limits.fiveHour?.resetsAt != nil)
    precondition(limits.weekly?.resetsAt == Date(timeIntervalSince1970: 1_794_031_199))
    // Booleans aren't numbers, null windows are skipped, values are clamped to 0...100.
    precondition(limits.models.map(\.label) == ["Fable", "Sonnet"] && limits.models[1].used == 100)
    precondition(limits.models[0].used == 68.5 && limits.models[1].resetsAt == nil)
    precondition(parsePlanLimits(Data(#"{"five_hour": null, "seven_day": null}"#.utf8)) == nil)
    precondition(parsePlanLimits(Data("[]".utf8)) == nil && parsePlanLimits(Data("nope".utf8)) == nil)
    // Only an all-null answer means "no plan". A shape EJAJ doesn't know is a failure, which keeps the old numbers.
    precondition(parsePlanUsage(usage) == .limits(limits))
    precondition(parsePlanUsage(Data(#"{"five_hour": null, "seven_day": null}"#.utf8)) == .noPlan)
    for odd in [#"{"fiveHour": {"utilization": 3}}"#, #"{"five_hour": {"utilization": "3"}, "seven_day": null}"#,
      #"{"five_hour": null}"#, "[]", "<html>"]
    {
      precondition(parsePlanUsage(Data(odd.utf8)) == .unexpected, odd)
    }
    // One window is enough: a plan with only the 5-hour or only the weekly window still shows it.
    let onlyFive = parsePlanLimits(Data(#"{"five_hour": {"utilization": 10}, "seven_day": null}"#.utf8))!
    precondition(onlyFive.fiveHour?.used == 10 && onlyFive.weekly == nil)
    let onlyWeek = parsePlanLimits(Data(#"{"five_hour": null, "seven_day": {"utilization": 20}}"#.utf8))!
    precondition(onlyWeek.weekly?.used == 20 && onlyWeek.fiveHour == nil)
    // model_scoped wins over the older per-model keys, and values below 0 clamp to 0.
    let scopedJSON =
      #"{"seven_day": {"utilization": -3}, "seven_day_sonnet": {"utilization": 50},"#
      + #" "model_scoped": [{"display_name": "Sonnet", "utilization": 5}]}"#
    let scoped = parsePlanLimits(Data(scopedJSON.utf8))!
    precondition(scoped.models.map(\.label) == ["Sonnet"] && scoped.models[0].used == 5 && scoped.weekly?.used == 0)
    // The shape the endpoint returned on 6 Nov 2026: per-model limits only in "limits", microsecond timestamps.
    let real = parsePlanLimits(
      Data(
        #"""
        {"five_hour": {"utilization": 38.0, "resets_at": "2026-11-06T17:10:00.213324+00:00"},
         "seven_day": {"utilization": 77.0, "resets_at": "2026-11-07T06:00:00.213343+00:00"},
         "seven_day_opus": null, "seven_day_sonnet": null,
         "limits": [
          {"kind": "session", "percent": 38, "resets_at": "2026-11-06T17:10:00.213324+00:00", "scope": null},
          {"kind": "weekly_all", "percent": 77, "resets_at": "2026-11-07T06:00:00.213343+00:00", "scope": null},
          {"kind": "weekly_scoped", "percent": 68, "resets_at": "2026-11-07T06:00:00.213483+00:00",
           "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}},
          {"kind": "weekly_scoped", "percent": 5, "scope": {"model": null, "surface": "cowork"}}]}
        """#.utf8))!
    precondition(real.fiveHour?.used == 38 && real.weekly?.used == 77)
    precondition(real.models.map(\.label) == ["Fable"] && real.models[0].used == 68)
    precondition(real.weekly?.resetsAt.map { abs($0.timeIntervalSince1970 - 1_794_031_200.213) < 0.001 } == true)
    // A week that resets in 24 hours is 6/7 through; 60 % used by then projects to 70 %.
    let reset = Date(timeIntervalSince1970: 1_794_031_199)
    precondition(abs(weekElapsed(resetsAt: reset, now: reset.addingTimeInterval(-86_400)) - 6.0 / 7) < 1e-9)
    precondition(abs(weekProjection(used: 60, resetsAt: reset, now: reset.addingTimeInterval(-86_400))! - 70) < 1e-9)
    precondition(weekElapsed(resetsAt: reset, now: reset.addingTimeInterval(-700_000)) == 0)
    precondition(weekElapsed(resetsAt: reset, now: reset.addingTimeInterval(10)) == 1)
    // Under 12 hours into the week there is no projection; at exactly 12 there is.
    precondition(weekProjection(used: 5, resetsAt: reset, now: reset.addingTimeInterval(-604_800 + 43_000)) == nil)
    precondition(weekProjection(used: 5, resetsAt: reset, now: reset.addingTimeInterval(-604_800 + 43_200)) != nil)
    // Runs out: a day into the week with 50 % used runs out 2 days in; 10 % a day in lasts to the reset.
    let dayIn = reset.addingTimeInterval(-604_800 + 86_400)
    precondition(weekRunsOut(used: 50, resetsAt: reset, now: dayIn) == reset.addingTimeInterval(-604_800 + 172_800))
    precondition(weekRunsOut(used: 10, resetsAt: reset, now: dayIn) == nil)
    precondition(weekRunsOut(used: 0, resetsAt: reset, now: dayIn) == nil)
    precondition(weekRunsOut(used: 90, resetsAt: reset, now: reset.addingTimeInterval(-604_800 + 3_600)) == nil)
    print("PASS: plan usage parsing, clamping, week elapsed, projection and runs-out time")

    let stored = Data(
      #"""
      {"claudeAiOauth": {"accessToken": "old", "refreshToken": "r1", "expiresAt": 1793200000000,
        "refreshTokenExpiresAt": 1795000000000, "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "team"},
       "mcpOAuth": {"server": {"accessToken": "keep"}}}
      """#.utf8)
    let token = parseClaudeToken(stored)!
    precondition(token.access == "old" && token.refresh == "r1" && token.scopes == ["user:inference", "user:profile"])
    precondition(token.expiresAt == Date(timeIntervalSince1970: 1_793_200_000))
    precondition(token.expired(at: Date(timeIntervalSince1970: 1_793_199_900)))  // inside the 2-minute margin
    precondition(!token.expired(at: Date(timeIntervalSince1970: 1_793_199_000)))
    precondition(token.canRefresh(at: Date(timeIntervalSince1970: 1_794_000_000)))
    precondition(!token.canRefresh(at: Date(timeIntervalSince1970: 1_795_000_001)))
    // The broken login on this Mac in November 2026: expiresAt 0 is expired, no refresh token means signed out.
    let dead = parseClaudeToken(Data(#"{"claudeAiOauth": {"accessToken": "x", "expiresAt": 0}}"#.utf8))!
    precondition(dead.expired(at: Date()) && !dead.canRefresh(at: Date()))
    precondition(parseClaudeToken(Data(#"{"claudeAiOauth": {"accessToken": ""}}"#.utf8)) == nil)
    precondition(parseClaudeToken(Data(#"{"other": {}}"#.utf8)) == nil)
    // A refresh token without a stored lifetime can still be used.
    let noLifetime = parseClaudeToken(
      Data(#"{"claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 0}}"#.utf8))!
    precondition(noLifetime.canRefresh(at: Date()) && noLifetime.refreshExpiresAt == nil)
    precondition(
      parseClaudeToken(Data(#"{"claudeAiOauth": {"accessToken": "a", "refreshToken": ""}}"#.utf8))!.refresh == nil)
    // The account in `security find-generic-password` output; a quote-free name only.
    let attributes = """
      keychain: "/Users/x/Library/Keychains/login.keychain-db"
      attributes:
          "acct"<blob>="tadeas"
          "svce"<blob>="Claude Code-credentials"
      """
    precondition(keychainAccount(fromAttributes: attributes) == "tadeas")
    precondition(keychainAccount(fromAttributes: #"    "acct"<blob>=0x74616465  "tade""#) == nil)
    precondition(keychainAccount(fromAttributes: #"    "acct"<blob>="""#) == "")
    precondition(keychainAccount(fromAttributes: "nothing here") == nil)

    let now = Date(timeIntervalSince1970: 1_793_300_000)
    let merged = applyTokenRefresh(
      stored, response: Data(#"{"access_token": "new", "refresh_token": "r2", "expires_in": 28800}"#.utf8), now: now)!
    let fresh = parseClaudeToken(merged)!
    precondition(fresh.access == "new" && fresh.refresh == "r2")
    precondition(fresh.expiresAt == now.addingTimeInterval(28_800) && fresh.refreshExpiresAt == token.refreshExpiresAt)
    let root = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
    let oauth = root["claudeAiOauth"] as! [String: Any]
    precondition(oauth["subscriptionType"] as? String == "team" && oauth["expiresAt"] as? Int64 == 1_793_328_800_000)
    precondition(((root["mcpOAuth"] as? [String: Any])?["server"] as? [String: Any])?["accessToken"] as? String == "keep")
    // No new refresh token keeps the old one; a new lifetime for it is stored.
    let kept = parseClaudeToken(
      applyTokenRefresh(
        stored,
        response: Data(
          #"{"access_token": "n", "refresh_token": "", "expires_in": 60, "refresh_token_expires_in": 100}"#.utf8),
        now: now)!)!
    precondition(kept.refresh == "r1" && kept.refreshExpiresAt == now.addingTimeInterval(100))
    for bad in [#"{"expires_in": 60}"#, #"{"access_token": "n"}"#, #"{"access_token": "n", "expires_in": 0}"#, "x"] {
      precondition(applyTokenRefresh(stored, response: Data(bad.utf8), now: now) == nil, bad)
    }
    print("PASS: Claude Code credentials, refresh merge keeps other keys")
    try sessionTests()
    try updateTests()
  }
  static func updateTests() throws {
    for (a, b, newer) in [
      ("1.12.0", "1.9.3", true), ("1.12.0", "1.12.0", false), ("1.12", "1.12.0", false), ("1.12.1", "1.12", true),
      ("2.0.0", "1.99.9", true), ("1.12.0", "1.12", false), ("1.8.1", "1.12.0", false), ("1.12.0-beta", "1.0", false), ("v1.2", "1.0", false),
    ] { precondition(isNewer(a, than: b) == newer, "\(a) vs \(b)") }
    precondition(versionParts("1..2") == nil && versionParts("") == nil && versionParts("1.2.3.4.5") == nil)
    let digest = String(repeating: "ab", count: 32)
    func release(_ extra: [String: Any] = [:], asset: [String: Any]? = nil) -> Data {
      var r: [String: Any] = [
        "tag_name": "v1.13.0", "draft": false, "prerelease": false, "body": "**New** tab",
        "html_url": "https://github.com/tadeaskaminsky/ejaj/releases/tag/v1.13.0",
        "assets": [
          ["name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"],
          asset ?? [
            "name": "EJAJ-macOS.zip", "digest": "sha256:" + digest.uppercased(),
            "browser_download_url": "https://github.com/tadeaskaminsky/ejaj/releases/download/v1.13.0/EJAJ-macOS.zip",
          ],
        ],
      ]
      for (k, v) in extra { r[k] = v }
      return try! JSONSerialization.data(withJSONObject: r)
    }
    let r = parseLatestRelease(release())!
    precondition(r.version == "1.13.0" && r.sha256 == digest && r.notes == "**New** tab")
    precondition(r.zip.lastPathComponent == "EJAJ-macOS.zip" && r.page?.host == "github.com")
    precondition(parseLatestRelease(release(["draft": true])) == nil)
    precondition(parseLatestRelease(release(["prerelease": true])) == nil)
    precondition(parseLatestRelease(release(["tag_name": "nightly"])) == nil)
    precondition(parseLatestRelease(release(asset: ["name": "Other.zip", "browser_download_url": "https://x.y/z"])) == nil)
    // Plain http only from this Mac; a malformed digest refuses the release; no digest is allowed (older releases).
    let httpAsset: [String: Any] = ["name": "EJAJ-macOS.zip", "browser_download_url": "http://example.com/EJAJ-macOS.zip"]
    precondition(parseLatestRelease(release(asset: httpAsset)) == nil)
    let local: [String: Any] = ["name": "EJAJ-macOS.zip", "browser_download_url": "http://127.0.0.1:8765/EJAJ-macOS.zip"]
    let localRelease = parseLatestRelease(release(asset: local))
    precondition(localRelease != nil && localRelease?.sha256 == nil)
    precondition(isLocalTestURL(URL(string: "http://localhost:8765/x")!) && !isLocalTestURL(URL(string: "http://localhost@evil.com/x")!))
    for bad in ["sha256:" + String(repeating: "a", count: 63), "sha256:" + String(repeating: "g", count: 64)] {
      var asset = local; asset["digest"] = bad
      precondition(parseLatestRelease(release(asset: asset)) == nil, bad)
    }
    let badDigest: [String: Any] = [
      "name": "EJAJ-macOS.zip", "digest": "sha256:xyz", "browser_download_url": "https://x.y/EJAJ-macOS.zip",
    ]
    precondition(parseLatestRelease(release(asset: badDigest)) == nil && parseLatestRelease(Data("[]".utf8)) == nil)
    precondition(sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    // The swap: waits for the old process, replaces the bundle, removes the leftovers and opens the new one.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Apps/EJAJ.app"), work = root.appendingPathComponent("work")
    let new = work.appendingPathComponent("unpacked/EJAJ.app"), old = root.appendingPathComponent("Apps/.EJAJ.app.old")
    let opened = root.appendingPathComponent("opened"), note = root.appendingPathComponent("update-failed.txt")
    for (dir, text) in [(app, "1.12.0"), (new, "1.13.0")] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try text.write(to: dir.appendingPathComponent("version"), atomically: true, encoding: .utf8)
    }
    // The old process is still running for a second; the swap has to wait for it.
    let running = Process(); running.executableURL = URL(fileURLWithPath: "/bin/sleep"); running.arguments = ["1"]
    try running.run()
    func swap(_ opener: String) {
      let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
      p.arguments = [
        "-c", swapScript, "t", String(running.processIdentifier), app.path, new.path, old.path, work.path, note.path,
        "1.13.0", opener,
      ]
      p.standardError = FileHandle.nullDevice
      try! p.run(); p.waitUntilExit()
    }
    let started = Date()
    swap("touch \(opened.path)")
    precondition(Date().timeIntervalSince(started) > 0.7, "the swap didn't wait for the old process")
    running.waitUntilExit()
    precondition((try? String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8)) == "1.13.0")
    precondition(!FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: work.path))
    precondition(FileManager.default.fileExists(atPath: opened.path) && Updater.takeFailureNote(note) == nil)
    // A copy that fails puts the old bundle back and leaves a note for the next launch, read once.
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    swap(":")
    precondition((try? String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8)) == "1.13.0")
    precondition(!FileManager.default.fileExists(atPath: work.path))
    precondition(Updater.takeFailureNote(note)?.hasPrefix("EJAJ 1.13.0 couldn't be installed") == true)
    precondition(Updater.takeFailureNote(note) == nil)
    print("PASS: release parsing, version order, checksums, swapping the bundle and putting it back on failure")
  }
  static func sessionTests() throws {
    let home = "/Users/me", repos: Set<String> = ["/Users/me/work/shop", "/Users/me/work/shop/.claude/worktrees/x"]
    func project(_ cwd: String?) -> ProjectRef { projectOf(cwd: cwd, home: home) { repos.contains($0) } }
    precondition(project("/Users/me/work/shop") == ProjectRef(name: "shop", folder: "~/work/shop"))
    precondition(project("/Users/me/work/shop/packages/api/") == ProjectRef(name: "shop", folder: "~/work/shop"))
    // A worktree is its repository, even though the worktree has its own .git.
    precondition(project("/Users/me/work/shop/.claude/worktrees/x/src") == ProjectRef(name: "shop", folder: "~/work/shop"))
    precondition(project("/Users/me/notes/drafts") == ProjectRef(name: "drafts", folder: "~/notes/drafts"))
    precondition(project("/Users/me") == ProjectRef(name: "Home folder", folder: "~"))
    precondition(project("/opt/tool") == ProjectRef(name: "tool", folder: "/opt/tool"))
    precondition(
      project("/Users/me/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1").name == "Scratch")
    precondition(project("/Users/me/Documents/Codex/2026-10-16/spr") == ProjectRef(name: "Scratch", folder: nil))
    precondition(project("/private/tmp/claude-501/x") == ProjectRef(name: "Temporary", folder: nil))
    precondition(project("/var/folders/ab/T/x").name == "Temporary" && project("/tmp").name == "Temporary")
    precondition(project(nil).name == "Unknown folder" && project("relative").name == "Unknown folder")
    for (seconds, text) in [(20.0, "<1 min"), (45 * 60, "45 min"), (3600, "1 h"), (2 * 3600 + 13 * 60, "2 h 13 min"),
      (76 * 3600, "3 d 4 h"), (48 * 3600, "2 d"), (-5, "<1 min")] as [(Double, String)]
    {
      precondition(durationText(seconds) == text, "\(seconds) → \(durationText(seconds))")
    }
    // Ranges, platforms and grouping by name, most expensive first.
    func row(_ date: String, _ provider: String, _ input: Int) -> UsageRow {
      UsageRow(
        date: date, provider: provider, model: provider == "gpt" ? "gpt-5.6-sol" : "claude-opus-5", source: "t",
        input: input, requests: 1)
    }
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let list = [
      SessionUsage(
        provider: "claude", session: "a", project: "shop", folder: "~/work/shop", start: t0, end: t0,
        rows: [row("2026-11-01", "claude", 1_000_000), row("2026-11-10", "claude", 2_000_000)]),
      SessionUsage(
        provider: "gpt", session: "b", project: "shop", folder: "~/old/shop", start: t0, end: t0.addingTimeInterval(60),
        rows: [row("2026-11-10", "gpt", 1_000_000)]),
      SessionUsage(
        provider: "claude", session: "c", project: "blog", folder: "~/blog", start: t0, end: t0,
        rows: [row("2026-10-01", "claude", 10_000_000)]),
    ]
    let all = totalsByProject(totalsBySession(list, from: nil, through: "2026-11-12", provider: "all"))
    precondition(all.map(\.name) == ["blog", "shop"] && all[0].cost == 50 && all[1].cost == 19)
    precondition(all[1].folders == ["~/old/shop", "~/work/shop"] && all[1].sessions.map(\.session.session) == ["a", "b"])
    precondition(all[1].last == t0.addingTimeInterval(60) && all[1].tokens == 4_000_000)
    let recent = totalsBySession(list, from: "2026-11-05", through: "2026-11-12", provider: "all")
    precondition(recent.map(\.session.session) == ["a", "b"] && recent[0].cost == 10 && recent[0].requests == 1)
    let codex = totalsBySession(list, from: nil, through: "2026-11-12", provider: "gpt")
    precondition(codex.count == 1 && codex[0].cost == 4)
    precondition(totalsBySession(list, from: nil, through: "2026-10-31", provider: "all").map(\.session.session) == ["c"])
    // Both ends of the range count: today's rows are on `through`, Count from's day is on `from`.
    let edges = totalsBySession(list, from: "2026-11-01", through: "2026-11-01", provider: "all")
    precondition(edges.map(\.session.session) == ["a"] && edges[0].cost == 5)
    // A model without a price leaves the cost out and marks the session and its project.
    var unknown = row("2026-11-10", "gpt", 1_000_000); unknown.model = "gpt-unpriced"
    var mixed = list[1]; mixed.rows.append(unknown)
    let marked = totalsByProject(totalsBySession([list[0], mixed], from: nil, through: "2026-11-12", provider: "all"))
    precondition(marked[0].cost == 19 && marked[0].unpriced && marked[0].sessions.filter(\.unpriced).count == 1)
    precondition(!all.contains(where: \.unpriced))
    print("PASS: projects from working folders, worktrees, scratch; session totals by range, platform and project")
    // Opus 5: input 5, read 0.5, write 6.25, write 1h 10. A million of each: reads save 4.5, writes add 1.25 + 5.
    let cachedRow = UsageRow(
      date: "2026-11-10", provider: "claude", model: "claude-opus-5", source: "t", input: 1_000_000, cached: 1_000_000,
      write: 1_000_000, write1h: 1_000_000)
    precondition(cachedRow.cacheEffect == CacheEffect(saved: 4.5, premium: 6.25))
    var fastRow = cachedRow; fastRow.tier = "fast"
    precondition(fastRow.cacheEffect == CacheEffect(saved: 9, premium: 12.5) && cacheEffect([cachedRow, fastRow]).net == -5.25)
    // The 5-minute and the 1-hour writes have their own rates: 1M at 6.25 and 2M at 10, less input, add 1.25 + 10.
    var mixedWrites = cachedRow; mixedWrites.write1h = 2_000_000
    precondition(mixedWrites.cacheEffect == CacheEffect(saved: 4.5, premium: 11.25))
    var unpricedRow = cachedRow; unpricedRow.model = "nope"
    precondition(unpricedRow.cacheEffect == nil && cacheEffect([unpricedRow, cachedRow]).saved == 4.5)
    // 2026-11-09 is a Monday, 2026-11-15 a Sunday.
    func hourRow(_ date: String, _ hour: Int?, _ input: Int) -> UsageRow {
      UsageRow(date: date, provider: "claude", model: "claude-opus-5", source: "t", input: input, requests: 1, hour: hour)
    }
    let grid = weekHourGrid([
      hourRow("2026-11-09", 9, 1_000_000), hourRow("2026-11-16", 9, 1_000_000), hourRow("2026-11-15", 23, 2_000_000),
      hourRow("2026-11-09", 14, 1_000_000),
      hourRow("2026-11-15", nil, 5), hourRow("bad", 3, 5),
    ])
    // Two hours on the same Monday are one day.
    precondition(grid.cells[0][9] == WeekHour(cost: 10, tokens: 2_000_000, requests: 2) && grid.days[0] == 2)
    precondition(grid.cells[6][23].cost == 10 && grid.days[6] == 1 && grid.cells[3].allSatisfy { $0 == WeekHour() })
    let now = t0.addingTimeInterval(3600)
    // Ten minutes is the edge; newest first; a clock ahead by more than a minute doesn't count as running.
    var live = list[0]; live.end = now.addingTimeInterval(-120)
    var edge = list[1]; edge.end = now.addingTimeInterval(-600)
    var stale = list[2]; stale.end = now.addingTimeInterval(-601)
    var ahead = list[0]; ahead.session = "d"; ahead.end = now.addingTimeInterval(120)
    let running = runningSessions(
      totalsBySession([edge, stale, live, ahead], from: nil, through: "2026-11-12", provider: "all"), now: now)
    precondition(running.map(\.session.session) == ["a", "b"])
    print("PASS: cache savings and write premium, week-hour grid, running sessions")
    // 23:30 UTC on 30 November is already 1 December in Bratislava; 6 January is the last day.
    let iso = ISO8601DateFormatter()
    for (t, on) in [
      ("2026-11-30T22:59:00Z", false), ("2026-11-30T23:30:00Z", true), ("2026-12-24T12:00:00Z", true),
      ("2027-01-06T22:00:00Z", true), ("2027-01-06T23:30:00Z", false), ("2026-07-01T12:00:00Z", false),
    ] { precondition(christmasSeason(iso.date(from: t)!) == on, t) }
    print("PASS: Christmas season from 1 December to 6 January, Bratislava time")

    // The collector: a Claude session with a subagent file, titles, and a Codex thread with a subagent under it.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("code/shop"), sub = repo.appendingPathComponent("api")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let claude = root.appendingPathComponent(".claude/projects/shop"), codexDir = root.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(
      at: claude.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: codexDir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    func json(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
    func message(_ id: String, _ ts: String, cwd: String, session: String = "s1") -> String {
      json([
        "timestamp": ts, "requestId": "r" + id, "sessionId": session, "cwd": cwd,
        "message": ["id": id, "model": "claude-opus-5", "usage": ["input_tokens": 1_000_000, "output_tokens": 0]],
      ])
    }
    try [
      json(["type": "ai-title", "aiTitle": "Generated", "sessionId": "s1"]),
      message("m1", "2026-11-10T09:00:00Z", cwd: sub.path),
      json(["type": "custom-title", "customTitle": "Fix checkout", "sessionId": "s1"]),
      json(["type": "ai-title", "aiTitle": "Generated later", "sessionId": "s1"]),
    ].joined(separator: "\n").write(to: claude.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
    try message("m2", "2026-11-10T11:30:00Z", cwd: repo.path).write(
      to: claude.appendingPathComponent("s1/subagents/agent-1.jsonl"), atomically: true, encoding: .utf8)
    // A session that moved from notes to the repo belongs to the repo, whatever order the file lists the requests in.
    try [
      message("m4", "2026-11-10T15:00:00Z", cwd: repo.path, session: "s2"),
      message("m3", "2026-11-10T14:00:00Z", cwd: root.appendingPathComponent("notes").path, session: "s2"),
    ].joined(separator: "\n").write(to: claude.appendingPathComponent("s2.jsonl"), atomically: true, encoding: .utf8)
    func rollout(_ id: String, session: String, parent: String?) -> String {
      var meta: [String: Any] = ["id": id, "session_id": session, "cwd": root.appendingPathComponent("notes").path]
      if let parent { meta["parent_thread_id"] = parent }
      return [
        json(["type": "session_meta", "timestamp": "2026-11-11T08:00:00Z", "payload": meta]),
        json(["type": "turn_context", "payload": ["model": "gpt-5.6-sol"]]),
        json([
          "timestamp": "2026-11-11T08:05:00Z", "type": "event_msg",
          "payload": [
            "type": "token_count",
            "info": ["total_token_usage": ["input_tokens": 1_000_000], "last_token_usage": ["input_tokens": 1_000_000]],
          ],
        ]),
      ].joined(separator: "\n")
    }
    try rollout("t1", session: "t1", parent: nil).write(
      to: codexDir.appendingPathComponent("sessions/a.jsonl"), atomically: true, encoding: .utf8)
    try rollout("t2", session: "t1", parent: "t1").write(
      to: codexDir.appendingPathComponent("sessions/b.jsonl"), atomically: true, encoding: .utf8)
    try [json(["id": "t1", "thread_name": "Old name"]), "broken", json(["id": "t1", "thread_name": "Notes cleanup"])]
      .joined(separator: "\n").write(to: codexDir.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
    let collector = Collector(environment: [:])
    let data = collector.collect(home: root)
    let sessions = data.sessions ?? []
    precondition(sessions.count == 3 && data.skipped == 0, "\(sessions.map(\.id)) skipped \(data.skipped)")
    let s1 = sessions.first { $0.id == "claude|s1" }!
    precondition(s1.title == "Fix checkout" && s1.project == "shop" && s1.folder == "~/code/shop")
    precondition(s1.rows.reduce(0) { $0 + $1.requests } == 2 && s1.end.timeIntervalSince(s1.start) == 9000)
    precondition(sessions.first { $0.id == "claude|s2" }?.project == "shop")
    let t1 = sessions.first { $0.id == "gpt|t1" }!
    precondition(t1.title == "Notes cleanup" && t1.project == "notes" && t1.rows.reduce(0) { $0 + $1.requests } == 2)
    // Session rows add up to the daily rows.
    precondition(sessions.flatMap(\.rows).reduce(0) { $0 + $1.tokens } == data.rows.reduce(0) { $0 + $1.tokens })
    // A rename in the index alone is picked up on the next refresh.
    try json(["id": "t1", "thread_name": "Renamed"]).write(
      to: codexDir.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
    let renamed = collector.collect(home: root).sessions ?? []
    precondition(renamed.first { $0.id == "gpt|t1" }?.title == "Renamed")
    // The Claude log didn't change, so its titles come from the collector's cache and must still be there.
    precondition(renamed.first { $0.id == "claude|s1" }?.title == "Fix checkout" && collector.scans == 2)
    // Saved and read back. Snapshots without sessions load too (see the legacy snapshot above).
    let back = try JSONDecoder().decode(Dataset.self, from: try JSONEncoder().encode(data))
    precondition(back.sessions?.count == 3 && back.sessions?.first { $0.id == "claude|s1" }?.title == "Fix checkout")
    print("PASS: sessions with subagents, titles, Codex thread names and renames, project folders")
  }
}
