import AppKit
import Foundation
import Network
import Security

// MARK: - Google Drive upload (zIPE-inspired)
//
// Capture → upload → copy share link. Uses the installed-app OAuth flow:
// opens Google in the user's browser, listens on 127.0.0.1 for the redirect,
// exchanges the code for tokens. The refresh token lives in the Keychain;
// nothing else is stored.
//
// Setup: the user creates a "Desktop app" OAuth client in Google Cloud
// Console and pastes the client ID into SnapMark Settings. No client secret
// is needed for installed apps.

enum DriveError: LocalizedError {
    case notConfigured
    case notConnected
    case unauthorized
    case authFailed(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Enter your Google OAuth client ID in SnapMark Settings first."
        case .notConnected:
            return "Connect your Google account in SnapMark Settings first."
        case .unauthorized:
            return "Google rejected the request."
        case .authFailed(let message):
            return message
        case .uploadFailed(let message):
            return message
        }
    }
}

// MARK: - Keychain

/// Refresh-token storage. Service/account only — no bundle id dependency.
enum DriveKeychain {
    private static let service = "com.snapmark.googledrive"
    private static let account = "refreshToken"

    static func saveRefreshToken(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Loopback redirect receiver

/// Tiny one-shot HTTP listener on 127.0.0.1 for the OAuth redirect.
/// No Info.plist URL scheme needed.
final class LoopbackReceiver: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    /// Starts listening and returns the redirect URI to use in the auth URL.
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(rawValue: 0)!
                )
                let listener = try NWListener(using: params)
                self.listener = listener
                var didResume = false
                let resume: (Result<String, Error>) -> Void = { result in
                    guard !didResume else { return }
                    didResume = true
                    switch result {
                    case .success(let uri): cont.resume(returning: uri)
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            resume(.success("http://127.0.0.1:\(port.rawValue)/"))
                        } else {
                            resume(.failure(DriveError.authFailed("Could not bind a local port.")))
                        }
                    case .failed(let error):
                        resume(.failure(error))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Waits for the `?code=` redirect. Times out after five minutes.
    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            self.continuation = cont
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(throwing: DriveError.authFailed(
                    "Timed out waiting for Google sign-in."))
            }
        }
    }

    func stop() {
        if let pending = continuation {
            continuation = nil
            pending.resume(throwing: CancellationError())
        }
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.receive(on: connection)
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let code = Self.authCode(from: request)
            let authError = Self.authError(from: request)
            if code == nil && authError == nil {
                // Probe or preconnect without a redirect — keep waiting.
                connection.cancel()
                return
            }
            // Answer so the browser tab can show "done".
            let message = authError.map { "Sign-in failed: \($0)." }
                ?? "SnapMark is connected to Google Drive.<br>You can close this tab."
            let body = """
                <html><body style="font-family:-apple-system,sans-serif;padding:40px">
                <h3>\(message)</h3>
                </body></html>
                """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" +
                "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: response.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
            guard let pending = self.continuation else { return }
            self.continuation = nil
            if let code {
                pending.resume(returning: code)
            } else {
                pending.resume(throwing: DriveError.authFailed(
                    "Google sign-in failed (\(authError ?? "unknown error"))."))
            }
        }
    }

    /// Pulls `code` out of a raw HTTP request line like
    /// `GET /?code=XXXX&scope=... HTTP/1.1`.
    private static func authCode(from request: String) -> String? {
        queryValue(from: request, named: "code")
    }

    /// Pulls Google's `error` param (e.g. access_denied) out of the redirect.
    private static func authError(from request: String) -> String? {
        queryValue(from: request, named: "error")
    }

    private static func queryValue(from request: String, named name: String) -> String? {
        guard let line = request.components(separatedBy: "\r\n").first,
              line.hasPrefix("GET ") else { return nil }
        let path = line.dropFirst(4).prefix(while: { $0 != " " })
        guard let comps = URLComponents(string: "http://localhost/\(path)") else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }
}

// MARK: - OAuth

enum DriveOAuth {
    struct Tokens {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Full installed-app flow: browser → loopback redirect → token exchange.
    static func authorize(clientID: String) async throws -> Tokens {
        let receiver = LoopbackReceiver()
        let redirectURI = try await receiver.start()
        defer { receiver.stop() }

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = comps.url else {
            throw DriveError.authFailed("Could not build the Google sign-in URL.")
        }
        NSWorkspace.shared.open(url)

        let code = try await receiver.waitForCode()
        return try await postToken(clientID: clientID, params: [
            "code": code,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ], previousRefreshToken: nil)
    }

    static func refresh(refreshToken: String, clientID: String) async throws -> Tokens {
        try await postToken(clientID: clientID, params: [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ], previousRefreshToken: refreshToken)
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double
    }

    private static func postToken(clientID: String,
                                 params: [String: String],
                                 previousRefreshToken: String?) async throws -> Tokens {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "client_id", value: clientID)]
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DriveError.authFailed("Google token request failed (HTTP \(code)).")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refresh = decoded.refresh_token ?? previousRefreshToken else {
            throw DriveError.authFailed("Google did not return a refresh token.")
        }
        return Tokens(accessToken: decoded.access_token,
                      refreshToken: refresh,
                      expiresAt: Date().addingTimeInterval(decoded.expires_in))
    }
}

// MARK: - Folder parsing

/// Accepts a bare folder ID or a full Drive folder URL, returns the ID.
enum DriveFolderParser {
    static func id(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for pattern in ["folders/([a-zA-Z0-9_-]+)", "[?&]id=([a-zA-Z0-9_-]+)"] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text,
                                            range: NSRange(text.startIndex..<text.endIndex, in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        if text.range(of: "^[a-zA-Z0-9_-]{10,}$", options: .regularExpression) != nil {
            return text
        }
        return nil
    }
}

// MARK: - Uploader

/// Shared uploader used by Settings (connect/disconnect) and the editor.
@MainActor
final class DriveUploader: ObservableObject {
    static let shared = DriveUploader()

    @Published var isConnected = false
    @Published var isWorking = false
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: "driveClientID") }
    }
    @Published var folderInput: String {
        didSet { UserDefaults.standard.set(folderInput, forKey: "driveFolderID") }
    }
    @Published var makePublic: Bool {
        didSet { UserDefaults.standard.set(makePublic, forKey: "driveMakePublic") }
    }

    private var accessToken: String?
    private var accessTokenExpiry: Date?

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        self.clientID = UserDefaults.standard.string(forKey: "driveClientID") ?? ""
        self.folderInput = UserDefaults.standard.string(forKey: "driveFolderID") ?? ""
        self.makePublic = UserDefaults.standard.object(forKey: "driveMakePublic") as? Bool ?? true
        self.isConnected = DriveKeychain.loadRefreshToken() != nil
    }

    // MARK: Auth

    func connect() async throws {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw DriveError.notConfigured }
        isWorking = true
        defer { isWorking = false }
        let tokens = try await DriveOAuth.authorize(clientID: id)
        DriveKeychain.saveRefreshToken(tokens.refreshToken)
        accessToken = tokens.accessToken
        accessTokenExpiry = tokens.expiresAt
        isConnected = true
    }

    func disconnect() {
        DriveKeychain.deleteRefreshToken()
        accessToken = nil
        accessTokenExpiry = nil
        isConnected = false
    }

    private func validAccessToken() async throws -> String {
        if let token = accessToken,
           let expiry = accessTokenExpiry,
           expiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refresh = DriveKeychain.loadRefreshToken() else {
            isConnected = false
            throw DriveError.notConnected
        }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw DriveError.notConfigured }
        let tokens = try await DriveOAuth.refresh(refreshToken: refresh, clientID: id)
        accessToken = tokens.accessToken
        accessTokenExpiry = tokens.expiresAt
        return tokens.accessToken
    }

    // MARK: Upload

    /// Uploads the PNG and returns the share link. Retries once on 401.
    func upload(pngData: Data, filename: String, description: String) async throws -> String {
        isWorking = true
        defer { isWorking = false }
        do {
            return try await performUpload(pngData: pngData, filename: filename,
                                           description: description)
        } catch DriveError.unauthorized {
            // Token may have been revoked server-side; refresh once and retry.
            accessToken = nil
            return try await performUpload(pngData: pngData, filename: filename,
                                           description: description)
        }
    }

    private struct UploadResponse: Decodable {
        var id: String
        var webViewLink: String?
    }

    private func performUpload(pngData: Data, filename: String,
                               description: String) async throws -> String {
        let token = try await validAccessToken()
        let boundary = "snapmark-\(UUID().uuidString)"

        var metadata: [String: Any] = [
            "name": filename,
            "mimeType": "image/png",
            "description": description,
        ]
        if let folder = DriveFolderParser.id(from: folderInput) {
            metadata["parents"] = [folder]
        }
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append(string: "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadataJSON)
        body.append(string: "\r\n--\(boundary)\r\nContent-Type: image/png\r\n\r\n")
        body.append(pngData)
        body.append(string: "\r\n--\(boundary)--")

        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 { throw DriveError.unauthorized }
        guard (200..<300).contains(status) else {
            throw DriveError.uploadFailed("Drive upload failed (HTTP \(status)).")
        }
        let uploaded = try JSONDecoder().decode(UploadResponse.self, from: data)
        if makePublic {
            // Best effort: without this the link only works for the owner.
            try? await makeAnyoneReader(fileID: uploaded.id, token: token)
        }
        return uploaded.webViewLink ?? "https://drive.google.com/file/d/\(uploaded.id)/view"
    }

    private func makeAnyoneReader(fileID: String, token: String) async throws {
        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["type": "anyone", "role": "reader"])
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw DriveError.uploadFailed("Could not make the link public (HTTP \(status)).")
        }
    }
}

private extension Data {
    mutating func append(string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
