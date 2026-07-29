// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Fails fast (exit 1 with a ::error annotation) when the target marketing
// version is not strictly higher than the latest approved version on the App
// Store, i.e. when App Store Connect would reject the upload with "train
// closed" / "must contain a higher version". Run by the App Store workflow
// before archiving.
//
// Environment:
//   ASC_KEY_ID, ASC_ISSUER_ID  App Store Connect API key identifiers
//   ASC_KEY_PATH               Path to the AuthKey .p8 file
//   ASC_BUNDLE_ID              App bundle identifier
//   ASC_PLATFORM               IOS or MAC_OS
//   TARGET_VERSION             Marketing version about to be uploaded

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    print("::error::\(message)")
    exit(1)
}

func environment(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        fail("missing environment variable \(name)")
    }
    return value
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - Inputs

let keyID = environment("ASC_KEY_ID")
let issuerID = environment("ASC_ISSUER_ID")
let keyPath = environment("ASC_KEY_PATH")
let bundleID = environment("ASC_BUNDLE_ID")
let platform = environment("ASC_PLATFORM")
let targetVersion = environment("TARGET_VERSION")

guard targetVersion.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil else {
    fail("TARGET_VERSION '\(targetVersion)' is not a plain version number (expected e.g. 1.2)")
}

// MARK: - App Store Connect JWT (ES256)

guard let keyPEM = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM) else {
    fail("could not read an ES256 private key from \(keyPath)")
}

let now = Int(Date().timeIntervalSince1970)
let header = #"{"alg":"ES256","kid":"\#(keyID)","typ":"JWT"}"#
let payload = #"{"iss":"\#(issuerID)","iat":\#(now),"exp":\#(now + 600),"aud":"appstoreconnect-v1"}"#
let signingInput = "\(base64URL(Data(header.utf8))).\(base64URL(Data(payload.utf8)))"
guard let signature = try? privateKey.signature(for: Data(signingInput.utf8)) else {
    fail("failed to sign the App Store Connect API token")
}
let token = "\(signingInput).\(base64URL(signature.rawRepresentation))"

// MARK: - API helpers

func fetchJSON(_ urlString: String) -> [String: Any] {
    guard let url = URL(string: urlString) else {
        fail("bad URL \(urlString)")
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<[String: Any], Error> = .failure(URLError(.unknown))

    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result = .failure(error)
            return
        }
        guard let http = response as? HTTPURLResponse, let data else {
            result = .failure(URLError(.badServerResponse))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            result = .failure(NSError(domain: "asc", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) from \(urlString): \(body.prefix(400))"
            ]))
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            result = .failure(URLError(.cannotParseResponse))
            return
        }
        result = .success(object)
    }.resume()
    semaphore.wait()

    switch result {
    case .success(let object):
        return object
    case .failure(let error):
        fail("App Store Connect request failed: \(error.localizedDescription)")
    }
}

// MARK: - Look up the app, then its versions for this platform

let appsResponse = fetchJSON("https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=\(bundleID)")
guard let apps = appsResponse["data"] as? [[String: Any]], let appID = apps.first?["id"] as? String else {
    fail("no App Store Connect app found for bundle id \(bundleID)")
}

let versionsResponse = fetchJSON(
    "https://api.appstoreconnect.apple.com/v1/apps/\(appID)/appStoreVersions?filter[platform]=\(platform)&limit=200"
)
let versions = (versionsResponse["data"] as? [[String: Any]]) ?? []

// States whose version train no longer accepts new builds ("previously
// approved" in App Store Connect's rejection message).
let closedStates: Set<String> = [
    "READY_FOR_SALE",
    "PROCESSING_FOR_APP_STORE",
    "PENDING_DEVELOPER_RELEASE",
    "PENDING_APPLE_RELEASE",
    "REPLACED_WITH_NEW_VERSION",
    "REMOVED_FROM_SALE",
]

func components(_ version: String) -> [Int] {
    version.split(separator: ".").map { Int($0) ?? 0 }
}

func isHigher(_ a: String, than b: String) -> Bool {
    let lhs = components(a)
    let rhs = components(b)
    for index in 0..<max(lhs.count, rhs.count) {
        let l = index < lhs.count ? lhs[index] : 0
        let r = index < rhs.count ? rhs[index] : 0
        if l != r { return l > r }
    }
    return false
}

var latestClosed: String?
for version in versions {
    guard let attributes = version["attributes"] as? [String: Any],
          let versionString = attributes["versionString"] as? String,
          let state = attributes["appStoreState"] as? String else {
        continue
    }
    if closedStates.contains(state) {
        if let current = latestClosed {
            if isHigher(versionString, than: current) { latestClosed = versionString }
        } else {
            latestClosed = versionString
        }
    }
}

if let latestClosed, !isHigher(targetVersion, than: latestClosed) {
    fail("""
    Version \(targetVersion) (\(platform)) is not higher than \(latestClosed), the latest approved App Store version — \
    that train is closed for new builds. Tag a higher version (e.g. v\(components(latestClosed).dropLast().map(String.init).joined(separator: ".")).\((components(latestClosed).last ?? 0) + 1)) or bump MARKETING_VERSION.
    """)
}

print("Version \(targetVersion) (\(platform)) is open for new builds" + (latestClosed.map { " (latest approved: \($0))" } ?? ""))
