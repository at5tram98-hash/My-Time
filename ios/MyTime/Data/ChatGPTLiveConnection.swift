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

    /// ChatGPT が変えた内容の記録（新しい順・50件まで。この端末だけ）
    struct Activity: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var at: Date
        var kind: String
        var action: String
        var title: String
    }

    private(set) var proposals: [Proposal] = []
    /// 確認なしで反映できなかった依頼（形が合わない・そのあと端末で変わったなど）
    private(set) var held: [String: String] = [:]
    private(set) var activity: [Activity] = ChatGPTLiveConnection.loadActivity()
    /// ChatGPT からの変更を確認なしで反映する（既定でオン）
    var autoApply: Bool {
        get { UserDefaults.standard.object(forKey: "chatgpt.autoApply") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "chatgpt.autoApply"); objectWillChangeTick += 1 }
    }
    private(set) var objectWillChangeTick = 0
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
        held = [:]
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
            // 確認なしで反映して、結果をすぐ ChatGPT に返す
            if autoApply, !proposals.isEmpty, applyPending(model) {
                running = false
                await sync(model)
            }
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? RepositoryError)?.description ?? error.localizedDescription
        }
    }

    /// 届いた依頼を順に反映する。1件でも反映したら true。
    /// 反映できなかった依頼は「確認が必要」に残す（ほかの依頼は止めない）。まとめて「取り消す」で元に戻せる
    @discardableResult
    func applyPending(_ model: AppModel) -> Bool {
        var any = false
        for p in proposals where held[p.id] == nil {
            let preview: ChatGPTTransfer.Preview
            do { preview = try ChatGPTTransfer.preview(p.payload.data, in: model.repo) }
            catch { held[p.id] = (error as? RepositoryError)?.description ?? error.localizedDescription; continue }
            let restore = undoPoint(model.repo, changes: preview.changes)
            var count = 0
            let ok = model.perform(Self.toastText(preview.changes), undo: restore) {
                try model.repo.store.transaction {
                    count = try ChatGPTTransfer.apply(preview, to: model.repo)
                    self.recordResult(p.id, applied: true, repo: model.repo)
                }
            }
            if ok {
                any = true
                log(preview.changes.filter { !$0.skipped })
                proposals.removeAll { $0.id == p.id }
                _ = count
            } else {
                held[p.id] = model.errorMessage ?? "反映できませんでした"
                model.errorMessage = nil
            }
        }
        return any
    }

    /// 「ChatGPTが予定を2件変更しました」など（純正アプリの知らせと同じ、短い文）
    static func toastText(_ changes: [ChatGPTTransfer.Change]) -> String {
        let live = changes.filter { !$0.skipped }
        guard let first = live.first else { return "ChatGPTからの変更はありません" }
        let title = first.value("title", afterChange: first.action != .delete)?.stringValue ?? first.kind.label
        if live.count == 1 { return "ChatGPTが「\(title)」を\(actionLabel(first.action))しました" }
        return "ChatGPTが\(live.count)件を変更しました"
    }

    static func actionLabel(_ a: ChatGPTTransfer.Action) -> String {
        switch a {
        case .add: return "追加"
        case .edit: return "変更"
        case .delete: return "削除"
        case .copy: return "コピー"
        }
    }

    /// 反映する前の状態を覚え、元に戻す手順を返す
    private func undoPoint(_ repo: Repository, changes: [ChatGPTTransfer.Change]) -> () throws -> Void {
        let store = repo.store
        var records: [(EntityName, String, JSONValue?)] = []
        var tasks = Set<String>()
        for c in changes where !c.skipped {
            switch c.kind {
            case .event: records.append((.event, c.id, store.get(.event, id: c.id)))
            case .task: records.append((.task, c.id, store.get(.task, id: c.id))); tasks.insert(c.id)
            case .checkpoint: break
            }
        }
        let subtasks = store.all(.subtask).filter { tasks.contains($0["taskId"]?.stringValue ?? "") }
        let checkpoints = repo.settings().raw[ChatGPTTransfer.checkpointsKey]
        let hasCheckpoints = changes.contains { $0.kind == .checkpoint }
        return {
            try store.transaction {
                for (e, id, old) in records {
                    if let old { store.put(e, id: id, json: old) } else { store.delete(e, id: id) }
                }
                if !tasks.isEmpty {
                    for s in store.all(.subtask) where tasks.contains(s["taskId"]?.stringValue ?? "") {
                        if let sid = s["id"]?.stringValue { store.delete(.subtask, id: sid) }
                    }
                    for s in subtasks { if let sid = s["id"]?.stringValue { store.put(.subtask, id: sid, json: s) } }
                }
                if hasCheckpoints {
                    repo.updateSettings { st in st.raw = st.raw.merging(.object([ChatGPTTransfer.checkpointsKey: checkpoints ?? .array([])])) }
                }
            }
        }
    }

    private func log(_ changes: [ChatGPTTransfer.Change]) {
        let now = Date()
        let rows = changes.map { c in
            Activity(at: now, kind: c.kind.rawValue, action: c.action.rawValue,
                     title: c.value("title", afterChange: c.action != .delete)?.stringValue ?? c.value("title", afterChange: false)?.stringValue ?? "（無題）")
        }
        activity = Array((rows + activity).prefix(50))
        if let d = try? JSONEncoder().encode(activity) { UserDefaults.standard.set(d, forKey: "chatgpt.activity") }
    }

    func clearActivity() {
        activity = []
        UserDefaults.standard.removeObject(forKey: "chatgpt.activity")
    }

    private static func loadActivity() -> [Activity] {
        guard let d = UserDefaults.standard.data(forKey: "chatgpt.activity") else { return [] }
        return (try? JSONDecoder().decode([Activity].self, from: d)) ?? []
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
            var fields = ChatGPTTransfer.occurrenceFields(occurrence.event)
            fields["id"] = summary["id"]
            fields["revision"] = summary["revision"]
            fields["title"] = .string(occurrence.title)
            fields["occurrenceId"] = .string(occurrence.id)
            fields["notes"] = .string(occurrence.event.notes)
            if let original = occurrence.originalStart {
                fields["occurrenceStart"] = .number(Double(original))
                fields["seriesStart"] = summary["start"]
                fields["seriesEnd"] = summary["end"]
            }
            fields["start"] = .number(Double(occurrence.start))
            fields["end"] = .number(Double(occurrence.end))
            return .object(fields)
        }
        var wire = snapshot.objectValue ?? [:]
        wire.removeValue(forKey: "event")
        wire["occurrences"] = .array(occurrences)
        let checkpoints = model.repo.settings().raw[ChatGPTTransfer.checkpointsKey]?.arrayValue ?? []
        wire["checkpointOccurrences"] = .array((-30...90).flatMap { delta in
            ChatGPTTransfer.checkpoints(checkpoints, on: model.time.addDays(today, delta), time: model.time, forSync: true)
        })
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
