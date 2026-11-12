import CryptoKit
import Foundation

// Updates from the GitHub releases of tadeaskaminsky/ejaj. The app asks for the latest release, and when its tag is a
// newer version than the running one, offers it. Installing downloads the release's EJAJ-macOS.zip, checks it against
// the SHA-256 GitHub lists for the file, unpacks it, checks that it is an EJAJ bundle of the offered version with an
// intact signature, then swaps it in place of the running app and opens it again.
//
// The app is signed ad hoc, so the signature only proves the bundle wasn't damaged, not who made it. Trust rests on
// the HTTPS download from the repository itself. A download through URLSession isn't quarantined, so Gatekeeper
// doesn't stop the new copy the way it stops one downloaded in a browser.

struct ReleaseInfo: Equatable {
  var version: String
  var notes: String
  var zip: URL
  var page: URL?
  var sha256: String?  // lowercase hex, from the asset's "digest"
}

// The body of GET /repos/{owner}/{repo}/releases/latest. Drafts, prereleases, tags that aren't versions and
// releases without EJAJ-macOS.zip are not offered.
func parseLatestRelease(_ data: Data) -> ReleaseInfo? {
  guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    r["draft"] as? Bool != true, r["prerelease"] as? Bool != true, let tag = r["tag_name"] as? String
  else { return nil }
  let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
  guard versionParts(version) != nil, let assets = r["assets"] as? [[String: Any]],
    let asset = assets.first(where: { $0["name"] as? String == "EJAJ-macOS.zip" }),
    let link = asset["browser_download_url"] as? String, let zip = URL(string: link), zip.scheme == "https"
      || isLocalTestURL(zip)
  else { return nil }
  var sha: String?
  if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
    let hex = digest.dropFirst(7).lowercased()
    guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    sha = hex
  }
  return ReleaseInfo(
    version: version, notes: r["body"] as? String ?? "", zip: zip,
    page: (r["html_url"] as? String).flatMap(URL.init(string:)), sha256: sha)
}
// "1.12.0" → [1, 12, 0]. Anything but dot-separated numbers is not a version.
func versionParts(_ v: String) -> [Int]? {
  let parts = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
  guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
  return parts.map { $0! }
}
// 1.12.0 is newer than 1.9.3; 1.12 and 1.12.0 are the same.
func isNewer(_ candidate: String, than current: String) -> Bool {
  guard var a = versionParts(candidate), var b = versionParts(current) else { return false }
  while a.count < b.count { a.append(0) }
  while b.count < a.count { b.append(0) }
  return a.lexicographicallyPrecedes(b) == false && a != b
}
// Plain http is accepted only from this Mac, for testing the updater against a local server.
func isLocalTestURL(_ url: URL) -> Bool {
  url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")
}
func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// The script that swaps the bundle once the app has quit: it waits for the old process, moves the old bundle aside,
// copies the new one in, removes the download and opens the app. If the swap fails, the old bundle goes back and the
// script leaves a note that the next launch shows, because the app that could say so has already quit. Paths come in
// as arguments, never spliced into the script. The last argument is the command that opens the app; tests pass one
// that only records the call.
let swapScript = """
  pid=$1; app=$2; new=$3; old=$4; work=$5; note=$6; version=$7; opener=${8:-open}
  for i in {1..150}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
  rm -rf "$old"
  if ! mv "$app" "$old"; then
    print -r -- "EJAJ $version couldn't be installed: the old version couldn't be moved aside" > "$note"
    rm -rf "$work"; ${=opener} "$app"; exit 1
  fi
  if ditto "$new" "$app"; then
    rm -rf "$old"
  else
    rm -rf "$app"; mv "$old" "$app"
    print -r -- "EJAJ $version couldn't be installed: copying it into $(dirname "$app") failed, so this version stayed" > "$note"
  fi
  rm -rf "$work"
  ${=opener} "$app"
  """

enum UpdateError: Error, Equatable {
  case network(String), noRelease, download(String), checksum, unpack, notEJAJ(String), signature, notWritable(String)
  case launch
  var message: String {
    switch self {
    case .network(let m): return "Couldn't reach GitHub: " + m
    case .noRelease: return "GitHub has no release EJAJ can install"
    case .download(let m): return "Download failed: " + m
    case .checksum: return "The download doesn't match the checksum GitHub lists, so it wasn't installed"
    case .unpack: return "Couldn't unpack the download"
    case .notEJAJ(let m): return "The download isn't the expected EJAJ: " + m
    case .signature: return "The downloaded app's signature is broken, so it wasn't installed"
    case .notWritable(let p): return "Can't replace the app in " + p + ". Move EJAJ to a folder you can write to."
    case .launch: return "Couldn't start the installer"
    }
  }
}

enum Updater {
  static let repository = "tadeaskaminsky/ejaj"
  // EJAJ_UPDATE_FEED points the check at a server on this Mac, for testing.
  static var feed: URL {
    if let raw = ProcessInfo.processInfo.environment["EJAJ_UPDATE_FEED"], let url = URL(string: raw), isLocalTestURL(url)
    {
      return url
    }
    return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
  }
  static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }
  // The latest release when it is newer than `current`, nil when EJAJ is up to date.
  static func check(current: String = currentVersion) async -> Result<ReleaseInfo?, UpdateError> {
    var request = URLRequest(url: feed, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("EJAJ-updater", forHTTPHeaderField: "User-Agent")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 404 { return .failure(.noRelease) }
      if status == 403 || status == 429 { return .failure(.network("GitHub's rate limit, try again in an hour")) }
      guard status == 200, data.count < 2_000_000 else { return .failure(.network("HTTP \(status)")) }
      guard let release = parseLatestRelease(data) else { return .failure(.noRelease) }
      return .success(isNewer(release.version, than: current) ? release : nil)
    } catch {
      return .failure(.network(error.localizedDescription))
    }
  }
  // Where a failed swap leaves its note for the next launch.
  static var failureNote: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EJAJ/update-failed.txt")
  }
  // The note a failed swap left, removed once read.
  static func takeFailureNote(_ url: URL = failureNote) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: url)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  // Downloads and checks the release, then starts the swap and returns. The caller quits the app right after; the
  // swap waits for that. `app` is the running bundle. Anything that fails before the swap removes the download.
  static func install(_ release: ReleaseInfo, over app: URL = Bundle.main.bundleURL) async throws {
    let parent = app.deletingLastPathComponent()
    guard app.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path) else {
      throw UpdateError.notWritable(parent.path)
    }
    let data: Data
    do {
      let (d, response) = try await URLSession.shared.data(from: release.zip)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download("HTTP error") }
      data = d
    } catch let e as UpdateError { throw e } catch { throw UpdateError.download(error.localizedDescription) }
    if let expected = release.sha256, sha256Hex(data) != expected { throw UpdateError.checksum }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("ejaj-update-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    var started = false
    defer { if !started { try? FileManager.default.removeItem(at: work) } }
    let zip = work.appendingPathComponent("EJAJ-macOS.zip"), unpacked = work.appendingPathComponent("unpacked")
    do { try data.write(to: zip) } catch { throw UpdateError.unpack }
    guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw UpdateError.unpack }
    let new = unpacked.appendingPathComponent("EJAJ.app")
    let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist"))
    let id = Bundle.main.bundleIdentifier ?? "local.tadeas.ejaj"
    guard info?["CFBundleIdentifier"] as? String == id else { throw UpdateError.notEJAJ("wrong bundle identifier") }
    guard info?["CFBundleShortVersionString"] as? String == release.version else {
      throw UpdateError.notEJAJ("its version isn't \(release.version)")
    }
    guard run("/usr/bin/codesign", ["--verify", "--strict", new.path]) == 0 else { throw UpdateError.signature }
    let old = parent.appendingPathComponent("." + app.lastPathComponent + ".old")
    let swap = Process()
    swap.executableURL = URL(fileURLWithPath: "/bin/zsh")
    swap.arguments = [
      "-c", swapScript, "ejaj-update", String(getpid()), app.path, new.path, old.path, work.path, failureNote.path,
      release.version,
    ]
    swap.standardOutput = FileHandle.nullDevice; swap.standardError = FileHandle.nullDevice
    do { try swap.run() } catch { throw UpdateError.launch }
    started = true
  }
  @discardableResult static func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit(); return p.terminationStatus
  }
}
