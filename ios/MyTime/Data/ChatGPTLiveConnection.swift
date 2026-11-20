import Foundation
import Observation
import Security
import UIKit
import MyTimeCore

@MainActor
@Observable
final class ChatGPTLiveConnection {
    struct Proposal: Identifiable {
        let id: String
        let created: EpochMs
        let payload: JSONValue
    }

    private static let endpoint = URL(string: "https://mytime-chatgpt.at5tram98.workers.dev")!
    private static let keychain: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mytime.chatgpt.live",
        kSecAttrAccount as String: "iphone",
    ]
    private static let resultsKey = "iosChatGPTLiveResults"
    private var token = ChatGPTLiveConnection.loadToken()
    private var sent: JSONValue?
    private var running = false
    private var active = false
    private var loop: Task<Void, Never>?
    private var update: Task<Void, Never>?
    private var connectingKey: String?
    private var backgroundSync: Task<Void, Never>?

    private(set) var proposals: [Proposal] = []
    private(set) var lastSent: Date?
    private(set) var failure: String?
    var connected: Bool { token != nil }

    func scene(active isActive: Bool, model: AppModel) {
        active = isActive
        loop?.cancel()
        if !isActive {
            guard connected, backgroundSync == nil else { return }
            let application = UIApplication.shared
            let background = application.beginBackgroundTask(withName: "My Time sync") { [weak self] in
                Task { @MainActor in self?.backgroundSync?.cancel() }
            }
            guard background != .invalid else { return }
            backgroundSync = Task { [weak self, weak model] in
                defer { application.endBackgroundTask(background); self?.backgroundSync = nil }
                guard let self, let model else { return }
                for _ in 0..<20 where self.running {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
                await self.sync(model)
            }
            return
        }
        loop = Task { [weak self, weak model] in
            while !Task.isCancelled {
                if let self, let model { await self.sync(model) }
                do { try await Task.sleep(for: .seconds(15)) }
                catch { break }
            }
        }
    }

    func changed(_ model: AppModel) {
        guard active, connected else { return }
        update?.cancel()
        update = Task { [weak self, weak model] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            if let self, let model { await self.sync(model) }
        }
    }

    func connect(_ code: String, model: AppModel) async throws {
        let key: String
        if let connectingKey {
            key = connectingKey
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw RepositoryError("接続キーを作成できませんでした")
            }
            key = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            connectingKey = key
        }
        _ = try await request("/device/connect", data: .object(["code": .string(code), "deviceToken": .string(key)]), authenticated: false)
        var insert = Self.keychain
        insert[kSecValueData as String] = Data(key.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            token = key
            do { try await disconnect() }
            catch { token = nil }
            throw RepositoryError("接続情報をキーチェーンに保存できませんでした")
        }
        token = key
        connectingKey = nil
        await sync(model)
    }

    func pairingCode() async throws -> String {
        let result = try await request("/device/pair")
        guard let code = result["code"]?.stringValue else { throw RepositoryError("接続コードを発行できませんでした") }
        return code
    }

    func disconnect() async throws {
        _ = try await request("/device/disconnect")
        SecItemDelete(Self.keychain as CFDictionary)
        token = nil
        proposals = []
        lastSent = nil
        sent = nil
        failure = nil
    }

    func recordResult(_ id: String, applied: Bool, repo: Repository) {
        repo.updateSettings { settings in
            let results = settings.raw[Self.resultsKey] ?? .object([:])
            settings.raw = settings.raw.merging(.object([
                Self.resultsKey: results.merging(.object([id: .string(applied ? "applied" : "rejected")]))
            ]))
        }
    }

    func sync(_ model: AppModel) async {
        guard connected, !running, model.storeFailure == nil else { return }
        running = true
        defer { running = false }
        do {
            let snapshot = makeSnapshot(model)
            let shouldSend = snapshot != sent || (lastSent?.timeIntervalSinceNow ?? -.infinity) < -120
            let generation = token
            let data = try await request("/device/sync", data: .object(shouldSend ? ["snapshot": snapshot] : [:]))
            guard token == generation else { return }
            if shouldSend {
                sent = snapshot
                lastSent = .now
            }
            let results = model.repo.settings().raw[Self.resultsKey]?.objectValue ?? [:]
            var sentResults: [String] = []
            for (id, status) in results {
                _ = try await request("/device/result", data: .object(["id": .string(id), "status": status]))
                sentResults.append(id)
            }
            if !sentResults.isEmpty {
                try model.repo.store.transaction {
                    model.repo.updateSettings { settings in
                        var current = settings.raw[Self.resultsKey]?.objectValue ?? [:]
                        for id in sentResults { current.removeValue(forKey: id) }
                        settings.raw = settings.raw.merging(.object([Self.resultsKey: .object(current)]))
                    }
                }
            }
            guard token == generation else { return }
            proposals = (data["pending"]?.arrayValue ?? []).compactMap { row in
                guard let id = row["id"]?.stringValue, results[id] == nil,
                      let created = row["created"]?.intValue, let payload = row["payload"] else { return nil }
                return Proposal(id: id, created: created, payload: payload)
            }
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? RepositoryError)?.description ?? error.localizedDescription
        }
    }

    private func makeSnapshot(_ model: AppModel) -> JSONValue {
        let today = model.time.startOfDay(model.now)
        let from = model.time.addDays(today, -30)
        let to = model.time.addDays(today, 91)
        let snapshot = ChatGPTTransfer.snapshot(model.repo, kinds: Set(ChatGPTTransfer.Kind.allCases), from: from, to: to)
        let events = snapshot["event"]?.arrayValue ?? []
        let summaries = Dictionary(events.compactMap { item in item["id"]?.stringValue.map { ($0, item) } },
                                   uniquingKeysWith: { first, _ in first })
        let occurrences: [JSONValue] = expandAll(model.events, from: from, to: to, time: model.time).compactMap { occurrence in
            guard !occurrence.isStruck, let summary = summaries[occurrence.masterId] else { return nil }
            var fields = summary.objectValue ?? [:]
            fields.removeValue(forKey: "exceptions")
            fields["title"] = .string(occurrence.title)
            fields["occurrenceId"] = .string(occurrence.id)
            fields["start"] = .number(Double(occurrence.start))
            fields["end"] = .number(Double(occurrence.end))
            return .object(fields)
        }
        var wire = snapshot.objectValue ?? [:]
        wire.removeValue(forKey: "event")
        wire["occurrences"] = .array(occurrences)
        return .object(wire)
    }

    private func request(_ path: String, data: JSONValue = .object([:]), authenticated: Bool = true) async throws -> JSONValue {
        var req = URLRequest(url: Self.endpoint.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        req.httpMethod = "POST"
        req.httpBody = data.data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token else { throw RepositoryError("iPhoneの接続が必要です") }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await URLSession.shared.data(for: req)
        let decoded = try JSONValue.parse(bytes)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RepositoryError(decoded["error"]?.stringValue ?? "連携サーバーに接続できませんでした")
        }
        return decoded
    }

    private static func loadToken() -> String? {
        var lookup = keychain
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
