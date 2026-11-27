import Foundation

// Claude plan limits: how much of the 5-hour and weekly allowance is used, as Claude Code's /usage shows it.
// The numbers come from the endpoint Claude Code itself calls, signed in with Claude Code's own OAuth token from
// the login Keychain. Neither the endpoint nor the token refresh is documented, so every step fails quietly into a
// PlanState that says what to do, and the calendar keeps showing the last numbers it had.

struct PlanWindow: Equatable {
  var label: String
  var used: Double  // percent, 0...100
  var resetsAt: Date?
}
struct PlanLimits: Equatable {
  var fiveHour: PlanWindow?
  var weekly: PlanWindow?
  var models: [PlanWindow] = []
}

private let isoFractional: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
private let isoPlain = ISO8601DateFormatter()
func isoDate(_ s: String?) -> Date? { s.flatMap { isoFractional.date(from: $0) ?? isoPlain.date(from: $0) } }

// A JSON number that isn't true or false (JSONSerialization hands booleans over as NSNumber too).
func jsonNumber(_ v: Any?) -> Double? {
  guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
  return n.doubleValue
}

// The body of GET /api/oauth/usage: {"five_hour": {"utilization": 32.0, "resets_at": "..."}, "seven_day": {...},
// "seven_day_opus": ..., "seven_day_sonnet": ..., "model_scoped": [{"display_name": "Fable", ...}]}.
// Windows the plan doesn't have are null. An account without plan limits (an API key) has both the 5-hour and the
// weekly key present and null. Anything else without either window is a shape EJAJ doesn't know, not "no plan".
enum PlanParse: Equatable {
  case limits(PlanLimits)
  case noPlan
  case unexpected
}
func parsePlanUsage(_ data: Data) -> PlanParse {
  guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unexpected }
  if let limits = parsePlanLimits(data) { return .limits(limits) }
  return o["five_hour"] is NSNull && o["seven_day"] is NSNull ? .noPlan : .unexpected
}
func parsePlanLimits(_ data: Data) -> PlanLimits? {
  guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
  func window(_ label: String, _ value: Any?) -> PlanWindow? {
    guard let w = value as? [String: Any], let used = jsonNumber(w["utilization"]) else { return nil }
    return PlanWindow(label: label, used: min(max(used, 0), 100), resetsAt: isoDate(w["resets_at"] as? String))
  }
  var models = (o["model_scoped"] as? [[String: Any]] ?? []).compactMap { m in
    (m["display_name"] as? String).flatMap { window($0, m) }
  }
  // Newer responses list the per-model weekly limits as "limits": [{"kind": "weekly_scoped", "percent": 68,
  // "resets_at": ..., "scope": {"model": {"display_name": "Fable"}}}], next to the session and weekly_all entries.
  for l in o["limits"] as? [[String: Any]] ?? [] where l["kind"] as? String == "weekly_scoped" {
    guard let name = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
      !models.contains(where: { $0.label == name }), let used = jsonNumber(l["percent"])
    else { continue }
    models.append(PlanWindow(label: name, used: min(max(used, 0), 100), resetsAt: isoDate(l["resets_at"] as? String)))
  }
  for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")]
  where !models.contains(where: { $0.label == name }) {
    if let w = window(name, o[key]) { models.append(w) }
  }
  let limits = PlanLimits(
    fiveHour: window("5-hour", o["five_hour"]), weekly: window("Weekly", o["seven_day"]), models: models)
  return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
}

// How far through its 7-day window the week is, 0...1, from the time it resets.
func weekElapsed(resetsAt: Date, now: Date) -> Double {
  min(max(1 - resetsAt.timeIntervalSince(now) / 604_800, 0), 1)
}
// The weekly percentage the week ends at if the rest of it goes like the part so far. nil in its first
// 12 hours, when a few requests would project to nonsense.
func weekProjection(used: Double, resetsAt: Date, now: Date) -> Double? {
  // Compared in seconds: 12.0 / 168 as a fraction misses exactly 12 hours by a rounding error.
  guard 604_800 - resetsAt.timeIntervalSince(now) >= 43_200 else { return nil }
  return used / weekElapsed(resetsAt: resetsAt, now: now)
}
// When the weekly limit runs out if the rest of the week goes like the part so far. nil when it lasts to the reset,
// nothing is used yet, or there is no projection yet.
func weekRunsOut(used: Double, resetsAt: Date, now: Date) -> Date? {
  guard used > 0, let projected = weekProjection(used: used, resetsAt: resetsAt, now: now), projected >= 100
  else { return nil }
  let start = resetsAt.addingTimeInterval(-604_800)
  return min(start.addingTimeInterval(now.timeIntervalSince(start) * 100 / used), resetsAt)
}

// Claude Code's login, as it keeps it in the "Claude Code-credentials" Keychain item:
// {"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt" (ms), "refreshTokenExpiresAt" (ms), "scopes", ...},
//  "mcpOAuth": {...}}. Only claudeAiOauth is read or changed; everything else is written back as it was.
struct ClaudeToken: Equatable {
  var access: String
  var refresh: String?
  var expiresAt: Date
  var refreshExpiresAt: Date?
  var scopes: [String]
  func expired(at now: Date) -> Bool { expiresAt.timeIntervalSince(now) < 120 }
  func canRefresh(at now: Date) -> Bool { refresh != nil && (refreshExpiresAt.map { $0 > now } ?? true) }
}
func parseClaudeToken(_ credentials: Data) -> ClaudeToken? {
  guard let root = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
    let o = root["claudeAiOauth"] as? [String: Any], let access = o["accessToken"] as? String, !access.isEmpty
  else { return nil }
  func ms(_ v: Any?) -> Date? { jsonNumber(v).map { Date(timeIntervalSince1970: $0 / 1000) } }
  return ClaudeToken(
    access: access, refresh: (o["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
    expiresAt: ms(o["expiresAt"]) ?? .distantPast, refreshExpiresAt: ms(o["refreshTokenExpiresAt"]),
    scopes: o["scopes"] as? [String] ?? [])
}
// Merges a token endpoint response ({"access_token", "refresh_token"?, "expires_in", "refresh_token_expires_in"?})
// into the stored credentials. A response without a new refresh token keeps the old one, as Claude Code does.
func applyTokenRefresh(_ credentials: Data, response: Data, now: Date) -> Data? {
  guard var root = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
    var o = root["claudeAiOauth"] as? [String: Any],
    let r = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
    let access = r["access_token"] as? String, !access.isEmpty, let expiresIn = jsonNumber(r["expires_in"]),
    expiresIn > 0
  else { return nil }
  let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
  o["accessToken"] = access
  o["expiresAt"] = Int64(nowMs + expiresIn * 1000)
  if let refresh = r["refresh_token"] as? String, !refresh.isEmpty { o["refreshToken"] = refresh }
  if let refreshIn = jsonNumber(r["refresh_token_expires_in"]), refreshIn > 0 {
    o["refreshTokenExpiresAt"] = Int64(nowMs + refreshIn * 1000)
  }
  root["claudeAiOauth"] = o
  return try? JSONSerialization.data(withJSONObject: root)
}

enum PlanState: Error, Equatable {
  case loading
  case ok
  case signedOut  // no Claude Code login on this Mac, or its refresh token has run out
  case notSubscription  // signed in with an API key or similar: plan limits don't apply
  case failed(String)
}

// The account name in `security find-generic-password` output: the line `    "acct"<blob>="name"`.
// nil when there is none or it is printed as hex (`"acct"<blob>=0x...`), which `security -i` can't be given safely.
func keychainAccount(fromAttributes text: String) -> String? {
  guard let regex = try? NSRegularExpression(pattern: #""acct"<blob>="([^"\n]*)""#),
    let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
    let range = Range(match.range(at: 1), in: text)
  else { return nil }
  return String(text[range])
}

// Reads and writes the Keychain item through /usr/bin/security, the tool Claude Code uses for it. The item's access
// list already trusts that tool, so macOS doesn't ask again.
enum ClaudeKeychain {
  static let service = "Claude Code-credentials"
  static let itemNotFound: Int32 = 44  // errSecItemNotFound (-25300) as security's exit code
  // A locked keychain makes `security` wait on the unlock dialog. Give up after 15 seconds rather than hold the
  // banner on the old numbers for as long as the dialog stays open.
  private static func run(_ args: [String], input: String? = nil) -> (status: Int32, out: Data) {
    let p = Process(), out = Pipe(), inPipe = Pipe(), done = DispatchSemaphore(value: 0)
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    if input != nil { p.standardInput = inPipe }
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return (-1, Data()) }
    if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)); try? inPipe.fileHandleForWriting.close() }
    // The output is a few KB at most, well under a pipe's buffer, so waiting before reading can't deadlock.
    if done.wait(timeout: .now() + 15) == .timedOut { p.terminate(); return (-2, Data()) }
    return (p.terminationStatus, out.fileHandleForReading.readDataToEndOfFile())
  }
  enum ReadResult { case found(Data), missing, failed(String) }
  static func read() -> ReadResult {
    let r = run(["find-generic-password", "-s", service, "-w"])
    if r.status == itemNotFound { return .missing }
    if r.status == -2 { return .failed("Keychain didn't answer (locked?)") }
    guard r.status == 0 else { return .failed("Keychain read failed (status \(r.status))") }
    var d = r.out; if d.last == 0x0A { d.removeLast() }
    return d.isEmpty ? .missing : .found(d)
  }
  static func account() -> String? {
    let r = run(["find-generic-password", "-s", service])
    guard r.status == 0 else { return nil }
    return keychainAccount(fromAttributes: String(decoding: r.out, as: UTF8.self))
  }
  // Same command Claude Code sends: the value as hex, through `security -i` so it stays out of the process list,
  // or as arguments when the line is too long for -i (Claude Code falls back the same way).
  static func write(_ credentials: Data, account: String) -> Bool {
    guard !account.contains("\"") else { return false }
    let hex = credentials.map { String(format: "%02x", $0) }.joined()
    let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
    if line.utf8.count <= 4000 { return run(["-i"], input: line).status == 0 }
    return run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]).status == 0
  }
}

// A refreshed login that couldn't be saved, kept so the next read doesn't spend the refresh token again.
// Calls are one at a time (UsageStore.planBusy), the lock only makes that safe to rely on.
private final class TokenMemory: @unchecked Sendable {
  private let lock = NSLock(); private var value: (replaced: String, fresh: ClaudeToken)?
  func get(replacing access: String) -> ClaudeToken? {
    lock.lock(); defer { lock.unlock() }; return value?.replaced == access ? value?.fresh : nil
  }
  func set(_ fresh: ClaudeToken, replacing access: String) { lock.lock(); value = (access, fresh); lock.unlock() }
}

enum ClaudePlan {
  static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
  static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  private static let memory = TokenMemory()

  static func storedToken() -> Result<ClaudeToken, PlanState> {
    switch ClaudeKeychain.read() {
    case .missing: return .failure(.signedOut)
    case .failed(let message): return .failure(.failed(message))
    case .found(let data): return parseClaudeToken(data).map { .success($0) } ?? .failure(.signedOut)
    }
  }

  // A token that is still good. Only an expired one is refreshed, and the new login is saved for Claude Code.
  static func token() async -> Result<ClaudeToken, PlanState> {
    let token: ClaudeToken
    switch storedToken() {
    case .success(let t): token = t
    case .failure(let state): return .failure(state)
    }
    let now = Date()
    if !token.expired(at: now) { return .success(token) }
    if let kept = memory.get(replacing: token.access), !kept.expired(at: now) { return .success(kept) }
    guard token.canRefresh(at: now), let refresh = token.refresh else { return .failure(.signedOut) }
    // Refresh tokens can rotate, so don't spend one unless the result can be saved back.
    guard let account = ClaudeKeychain.account() else { return .failure(.failed("Keychain account not readable")) }
    var request = URLRequest(url: tokenURL, timeoutInterval: 30); request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]
    if !token.scopes.isEmpty { body["scope"] = token.scopes.joined(separator: " ") }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let data: Data, status: Int
    do {
      let (d, response) = try await URLSession.shared.data(for: request)
      data = d; status = (response as? HTTPURLResponse)?.statusCode ?? 0
    } catch { return .failure(.failed("Token refresh: \(error.localizedDescription)")) }
    // 400/401 mean the refresh token was turned down. Claude Code may have rotated it a moment ago, so look again.
    if status == 400 || status == 401 {
      if case .success(let again) = storedToken(), again.access != token.access, !again.expired(at: Date()) {
        return .success(again)
      }
      return .failure(.signedOut)
    }
    guard status == 200 else { return .failure(.failed("Token refresh returned HTTP \(status)")) }
    // Merge into the item as it is now, so a change Claude Code made meanwhile (an MCP login) isn't undone.
    guard case .found(let current) = ClaudeKeychain.read() else {
      return .failure(.failed("Keychain changed during the token refresh"))
    }
    guard let merged = applyTokenRefresh(current, response: data, now: now), let fresh = parseClaudeToken(merged)
    else { return .failure(.failed("Unexpected token refresh response")) }
    // Claude Code stored a newer login meanwhile: its copy wins, ours is only used for this read.
    if parseClaudeToken(current)?.access != token.access { return .success(fresh) }
    if !ClaudeKeychain.write(merged, account: account) { memory.set(fresh, replacing: token.access) }
    return .success(fresh)
  }

  static func fetch() async -> Result<PlanLimits, PlanState> {
    var tried: Set<String> = []
    for attempt in 0..<2 {
      let token: ClaudeToken
      switch await self.token() {
      case .success(let t): token = t
      case .failure(let state): return .failure(state)
      }
      tried.insert(token.access)
      var request = URLRequest(url: usageURL, timeoutInterval: 20)
      request.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
      request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      request.setValue("EJAJ", forHTTPHeaderField: "User-Agent")
      let data: Data, status: Int
      do {
        let (d, response) = try await URLSession.shared.data(for: request)
        data = d; status = (response as? HTTPURLResponse)?.statusCode ?? 0
      } catch { return .failure(.failed(error.localizedDescription)) }
      // A 401 on a token that hasn't expired doesn't justify spending the refresh token. Try again only when
      // Claude Code has stored a different token since.
      if status == 401 {
        if attempt == 0, case .success(let again) = storedToken(), !tried.contains(again.access) { continue }
        return .failure(.failed("Usage returned HTTP 401"))
      }
      guard status == 200 else { return .failure(.failed("Usage returned HTTP \(status)")) }
      switch parsePlanUsage(data) {
      case .limits(let limits): return .success(limits)
      case .noPlan: return .failure(.notSubscription)
      case .unexpected: return .failure(.failed("Unexpected usage response"))
      }
    }
    return .failure(.failed("Usage returned HTTP 401"))
  }
}

// Readings of the plan limits over the last 7 days, kept across launches, for telling how fast the limits are going
// right now and how many tokens a whole limit holds. Work comes in bursts, so the pace since a window began says
// little about the next hour.
struct PlanSample: Codable, Equatable {
  var at: Date
  var five: Double? = nil; var fiveReset: Date? = nil
  var week: Double? = nil; var weekReset: Date? = nil
}
// The readings with a new one added: older than 7 days dropped, and one taken under 4 minutes after the last
// replacing it, so forced refreshes don't crowd the list.
func addPlanSample(_ samples: [PlanSample], _ limits: PlanLimits, at now: Date) -> [PlanSample] {
  var kept = samples.filter { now.timeIntervalSince($0.at) <= 604_800 && $0.at <= now }
  if let last = kept.last, now.timeIntervalSince(last.at) < 240 { kept.removeLast() }
  return kept + [
    PlanSample(
      at: now, five: limits.fiveHour?.used, fiveReset: limits.fiveHour?.resetsAt, week: limits.weekly?.used,
      weekReset: limits.weekly?.resetsAt)
  ]
}
enum LimitKind { case fiveHour, weekly }
// How many Claude Code tokens a whole limit holds, from the hours whose start and end both have a reading of the
// same window: the tokens of those hours over the points the limit rose in them. Hours are whole Bratislava hours,
// as the hourly rows count them, and only those the dataset has fully read (ending by `through`) count. Usage
// outside Claude Code (claude.ai, the desktop app) raises the limit without adding tokens, so it can only make the
// estimate lower. Hours that end at 100 % are left out: the API caps the figure there, so with extra usage the tokens
// would go on while the points stop. nil below `minPoints`, where the rounding of whole percents would swamp it.
struct LimitCapacity: Equatable {
  var tokens: Double; var output: Double  // per 100 %
  var points: Double  // what the estimate rests on
}
func limitCapacity(
  _ samples: [PlanSample], _ kind: LimitKind, hourly: [UsageRow], through: Date, minPoints: Double
) -> LimitCapacity? {
  let readings: [(at: Date, value: Double, reset: Date)] = samples.compactMap { s in
    let (value, reset) = kind == .fiveHour ? (s.five, s.fiveReset) : (s.week, s.weekReset)
    guard let value, let reset else { return nil }
    return (s.at, value, reset)
  }
  guard let first = readings.map(\.at).min(), let last = readings.map(\.at).max() else { return nil }
  // The reading closest to a moment, within 5.5 minutes of it (they come every 5).
  func reading(_ t: Date) -> (at: Date, value: Double, reset: Date)? {
    readings.filter { abs($0.at.timeIntervalSince(t)) <= 330 }
      .min { abs($0.at.timeIntervalSince(t)) < abs($1.at.timeIntervalSince(t)) }
  }
  var byHour: [TimeInterval: (tokens: Double, output: Double)] = [:]
  let cal = bratislava
  var days: [String: Date] = [:]
  for r in hourly where r.provider == "claude" {
    guard let hour = r.hour, let day = days[r.date] ?? dayFormatter.date(from: r.date),
      let start = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    else { continue }
    days[r.date] = day
    let old = byHour[start.timeIntervalSince1970] ?? (0, 0)
    byHour[start.timeIntervalSince1970] = (old.tokens + Double(r.tokens), old.output + Double(r.output))
  }
  var tokens = 0.0, output = 0.0, points = 0.0
  var hour = (first.timeIntervalSince1970 / 3600).rounded(.down) * 3600
  while hour < last.timeIntervalSince1970 {
    defer { hour += 3600 }
    let start = Date(timeIntervalSince1970: hour), end = start.addingTimeInterval(3600)
    guard end <= through, let a = reading(start), let b = reading(end),
      abs(a.reset.timeIntervalSince(b.reset)) < 600, b.value >= a.value, b.value < 100
    else { continue }
    points += b.value - a.value
    tokens += byHour[hour]?.tokens ?? 0; output += byHour[hour]?.output ?? 0
  }
  guard points >= minPoints, tokens > 0 else { return nil }
  return LimitCapacity(tokens: tokens * 100 / points, output: output * 100 / points, points: points)
}
// Percentage points per hour over the readings of the last `span`, counting only readings of the same window (the
// same reset, give or take 10 minutes). nil when they cover less than `minSpan`.
func recentPace(
  _ samples: [PlanSample], _ kind: LimitKind, used: Double, resetsAt: Date, now: Date, span: TimeInterval,
  minSpan: TimeInterval
) -> Double? {
  let first = samples.first { s in
    let (value, reset) = kind == .fiveHour ? (s.five, s.fiveReset) : (s.week, s.weekReset)
    guard value != nil, let reset, abs(reset.timeIntervalSince(resetsAt)) < 600 else { return false }
    return s.at >= now.addingTimeInterval(-span) && s.at < now
  }
  guard let first, let from = kind == .fiveHour ? first.five : first.week else { return nil }
  let hours = now.timeIntervalSince(first.at) / 3600
  guard hours * 3600 >= minSpan else { return nil }
  return max(0, used - from) / hours
}
// Percentage points per hour since the window began. nil until `minElapsed` of it has passed.
func windowPace(used: Double, resetsAt: Date, length: TimeInterval, now: Date, minElapsed: TimeInterval) -> Double? {
  let elapsed = length - resetsAt.timeIntervalSince(now)
  guard elapsed >= minElapsed, elapsed <= length else { return nil }
  return used / (elapsed / 3600)
}
// When a limit runs out at a given pace, or what it ends the window at when it lasts.
struct LimitForecast: Equatable {
  enum Basis: Equatable { case recent, window }
  var used: Double; var resetsAt: Date
  var runsOut: Date?  // nil: it lasts to the reset
  var atReset: Double  // percent at the reset at this pace, can pass 100
  var basis: Basis
}
func limitForecast(used: Double, resetsAt: Date, now: Date, pace: Double, basis: LimitForecast.Basis) -> LimitForecast {
  let hoursLeft = max(0, resetsAt.timeIntervalSince(now) / 3600)
  if used >= 100 { return LimitForecast(used: used, resetsAt: resetsAt, runsOut: now, atReset: used, basis: basis) }
  var out: Date? = nil
  if pace > 0 {
    let at = now.addingTimeInterval((100 - used) / pace * 3600)
    if at < resetsAt { out = at }
  }
  return LimitForecast(used: used, resetsAt: resetsAt, runsOut: out, atReset: used + pace * hoursLeft, basis: basis)
}
// The 5-hour window goes by the last 45 minutes (at least 10 of them read), and falls back to the pace since the
// window began once 15 minutes of it have passed.
func fiveHourForecast(_ w: PlanWindow, samples: [PlanSample], now: Date) -> LimitForecast? {
  guard let reset = w.resetsAt, reset > now else { return nil }
  if let p = recentPace(samples, .fiveHour, used: w.used, resetsAt: reset, now: now, span: 2_700, minSpan: 600) {
    return limitForecast(used: w.used, resetsAt: reset, now: now, pace: p, basis: .recent)
  }
  guard let p = windowPace(used: w.used, resetsAt: reset, length: 18_000, now: now, minElapsed: 900) else {
    return w.used >= 100 ? limitForecast(used: w.used, resetsAt: reset, now: now, pace: 0, basis: .window) : nil
  }
  return limitForecast(used: w.used, resetsAt: reset, now: now, pace: p, basis: .window)
}
// The week goes by whichever is faster: the pace since it began (from 12 hours in) or the last 24 hours (at least 3
// of them read), so a heavy day warns early rather than late.
func weeklyForecast(_ w: PlanWindow, samples: [PlanSample], now: Date) -> LimitForecast? {
  guard let reset = w.resetsAt, reset > now else { return nil }
  let whole = windowPace(used: w.used, resetsAt: reset, length: 604_800, now: now, minElapsed: 43_200)
  let recent = recentPace(samples, .weekly, used: w.used, resetsAt: reset, now: now, span: 86_400, minSpan: 10_800)
  if let recent, recent > (whole ?? 0) {
    return limitForecast(used: w.used, resetsAt: reset, now: now, pace: recent, basis: .recent)
  }
  guard let whole else {
    return w.used >= 100 ? limitForecast(used: w.used, resetsAt: reset, now: now, pace: 0, basis: .window) : nil
  }
  return limitForecast(used: w.used, resetsAt: reset, now: now, pace: whole, basis: .window)
}
// "Celý limit ≈ 108.0 M tokenov (937.6 k output)": what a whole limit holds, for the quick view.
func capacityText(_ c: LimitCapacity) -> String {
  "Celý limit ≈ " + compact(Int(c.tokens.rounded())) + " tokenov (" + compact(Int(c.output.rounded())) + " output)"
}
// The same in English for the calendar banner's tooltip.
func weekCapacityHelp(_ c: LimitCapacity) -> String {
  "A whole week holds about " + compact(Int(c.tokens.rounded())) + " Claude Code tokens ("
    + compact(Int(c.output.rounded())) + " output) at the last 7 days' mix."
}
// "1 h 10 min", "25 min", "2 d 4 h": how long until something, for the quick view.
func untilText(_ seconds: TimeInterval) -> String {
  let minutes = max(1, Int((seconds / 60).rounded()))
  if minutes < 60 { return "\(minutes) min" }
  if minutes < 1_440 { return "\(minutes / 60) h" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min") }
  return "\(minutes / 1_440) d" + (minutes % 1_440 / 60 == 0 ? "" : " \(minutes % 1_440 / 60) h")
}
// The Slovak line under a limit in the quick view, and how it is going. `time` writes a moment ("14:20", "št 18:00").
enum LimitMood: Equatable { case out, runsOut, lasts, unknown }
func limitText(_ w: PlanWindow, _ f: LimitForecast?, now: Date, time: @escaping (Date) -> String) -> (text: String, mood: LimitMood) {
  guard let reset = w.resetsAt, reset > now else { return ("Čakám na nové čísla po resete.", .unknown) }
  let minute = { (d: Date) in time(Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)) }
  if w.used >= 100 { return ("Minuté. Reset \(minute(reset)), o \(untilText(reset.timeIntervalSince(now))).", .out) }
  guard let f else { return ("Na odhad je ešte priskoro. Reset \(minute(reset)).", .unknown) }
  if let out = f.runsOut {
    return ("Dôjde ~\(minute(out)), o \(untilText(out.timeIntervalSince(now))). Reset až \(minute(reset)).", .runsOut)
  }
  return ("Vydrží do resetu \(minute(reset)), skončíš na ~\(Int(min(f.atReset, 100).rounded())) %.", .lasts)
}
