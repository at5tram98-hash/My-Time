import SwiftUI
import UIKit
import MyTimeCore

/// ChatGPT との連携（その他 → ChatGPT）。
/// つないでいれば：状態・自動で反映・最近の変更・ChatGPT での使い方。
/// つないでいなければ：何ができるかと、つなぎ方を順に。
/// ファイルでのやりとり（TimeTree のコピーなど）は下の「ファイルでやりとり」に分ける
struct ChatGPTTransferView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var setupCode = ""
    @State private var pairing: (code: String, until: Date)?
    @State private var disconnecting = false
    @State private var busy = false
    @State private var syncing = false
    @State private var message: String?
    @State private var copied = false
    @FocusState private var codeFocused: Bool

    static let serverURL = "https://mytime-chatgpt.at5tram98.workers.dev/mcp"

    private var live: ChatGPTLiveConnection { model.chatGPT }

    var body: some View {
        List {
            hero
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            if live.connected { connectedSections } else { setupSections }
            Section {
                NavigationLink { ChatGPTFileExchangeView() } label: {
                    row("ファイルでやりとり", "doc.badge.arrow.up", .gray, sub: "書き出し・読み込み・TimeTree からのコピー")
                }
            } footer: {
                Text("自動の連携を使わずに、JSON ファイルを ChatGPT に渡したり、ChatGPT が作ったファイルを読み込んだりできます。")
            }
            if live.connected {
                Section {
                    Button("連携を解除", role: .destructive) { disconnecting = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("ChatGPT")
        .navigationBarTitleDisplayMode(.inline)
        .animation(reduceMotion ? nil : .snappy, value: live.connected)
        .animation(reduceMotion ? nil : .snappy, value: live.activity)
        .sensoryFeedback(.success, trigger: copied)
        .confirmationDialog("ChatGPT との連携を解除しますか？", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("連携を解除", role: .destructive) { run { try await live.disconnect(); pairing = nil } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("同期サーバーにあるコピーと、届いている依頼を消去します。もう一度つなぐには、新しいセットアップコードが必要です。")
        }
        .alert("ChatGPT", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    // MARK: 見出し

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: "#10A37F"), Color(hex: "#0B7A60")], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: live.activity.count)
            }
            .frame(width: 72, height: 72)
            .shadow(color: Color(hex: "#10A37F").opacity(0.35), radius: 12, y: 6)
            .accessibilityHidden(true)
            Text(live.connected ? "ChatGPT とつながっています" : "ChatGPT で予定を編集")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if live.connected {
                statusLine
            } else {
                Text("ChatGPT に話しかけるだけで、予定・タスク・チェックポイントを追加したり変えたりできます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    /// 「● 接続中・2分前に同期」と「今すぐ同期」
    private var statusLine: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(live.failure == nil ? Color.green : Color.orange).frame(width: 8, height: 8)
                Group {
                    if let failure = live.failure {
                        Text(failure).lineLimit(1)
                    } else if let t = live.lastSent {
                        Text("\(t, format: .relative(presentation: .named))に同期")
                    } else {
                        Text("同期の準備中")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Button {
                syncing = true
                Task { await live.sync(model); syncing = false }
            } label: {
                Group {
                    if syncing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .disabled(syncing)
            .accessibilityLabel("今すぐ同期")
        }
    }

    // MARK: つないでいるとき

    @ViewBuilder
    private var connectedSections: some View {
        Section {
            Toggle(isOn: Binding(get: { live.autoApply }, set: { v in
                live.autoApply = v
                if v { Task { await live.sync(model) } }
            })) {
                row("変更をすぐ反映", "bolt.fill", .orange, sub: live.autoApply ? "ChatGPT が変えた内容を、確認せずにそのまま反映" : "届いた変更を、ひとつずつ確かめてから反映")
            }
            .tint(.green)
        } footer: {
            Text("反映したあとは、iPhone を振るか画面下の「取り消す」で元に戻せます。My Time を開いていない間も、iOS が許す範囲で取り込みます。")
        }

        // 反映を待っている・反映できなかった依頼
        if !live.proposals.isEmpty {
            Section {
                ForEach(live.proposals) { p in
                    NavigationLink { ChatGPTFileExchangeView(initialProposal: p) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: live.held[p.id] == nil ? "clock.fill" : "exclamationmark.triangle.fill")
                                .font(.title3)
                                .foregroundStyle(live.held[p.id] == nil ? Color.blue : Color.orange)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(live.held[p.id] == nil ? "確認を待っている変更" : "反映できなかった変更").font(.body.weight(.medium))
                                Text(live.held[p.id] ?? "\(model.time.dayLabel(p.created)) \(model.hm(p.created))に届きました")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            } header: {
                Text("確認が必要")
            }
        }

        Section {
            if live.activity.isEmpty && live.lastSent == nil && live.failure == nil {
                // はじめての同期が終わるまでは、行の形の仮の表示
                ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            } else if live.activity.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.title2).foregroundStyle(.tertiary)
                    Text("まだ変更はありません").font(.subheadline.weight(.medium))
                    Text("ChatGPT で「@My Time 明日の10時に歯医者を入れて」のように頼んでみてください。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                ForEach(live.activity.prefix(20)) { a in
                    activityRow(a)
                        // 左へなぞると記録から外す（予定・タスクはそのまま）
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { live.removeActivity(a.id) } label: { Label("記録から外す", systemImage: "eye.slash") }
                        }
                }
            }
        } header: {
            HStack {
                Text("最近の変更")
                Spacer()
                if !live.activity.isEmpty {
                    Button("消去") { live.clearActivity() }.font(.caption).textCase(nil)
                }
            }
        }

        Section {
            howTo
            Button { pair() } label: {
                row("ChatGPT の接続コードを発行", "key.fill", .blue, sub: "ChatGPT の認証の画面に入れる、10分間だけ使えるコード")
            }
            .buttonStyle(.plain)
            if let pairing { pairingCard(pairing) }
        } header: {
            Text("ChatGPT で使う")
        }
    }

    private func activityRow(_ a: ChatGPTLiveConnection.Activity) -> some View {
        let (symbol, tint): (String, Color) = {
            switch a.action {
            case "add", "copy": return ("plus.circle.fill", .green)
            case "delete": return ("trash.circle.fill", .red)
            default: return ("pencil.circle.fill", .blue)
            }
        }()
        let kind = ChatGPTTransfer.Kind(rawValue: a.kind)?.label ?? ""
        let action = ChatGPTTransfer.Action(rawValue: a.action).map(ChatGPTLiveConnection.actionLabel) ?? ""
        return HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.body.weight(.medium)).lineLimit(1)
                    .strikethrough(a.action == "delete", color: .secondary)
                Text("\(kind)を\(action)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(a.at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// ChatGPT 側の設定（3つの手順）
    private var howTo: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "ChatGPT の「設定」→「コネクタ」（または「プラグイン」）で、カスタムの MCP サーバーを追加")
            step(2, "名前を「My Time」、URL を下のものに、認証を「OAuth」にする")
            HStack(spacing: 8) {
                Text(Self.serverURL)
                    .font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.tertiarySystemFill)))
                Button {
                    UIPasteboard.general.string = Self.serverURL
                    copied.toggle()
                } label: {
                    Image(systemName: "doc.on.doc").frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("URL をコピー")
            }
            .padding(.leading, 34)
            step(3, "認証の画面で、下の「接続コード」を入れる。あとはチャットで「@My Time」と頼むだけ")
        }
        .padding(.vertical, 6)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color(hex: "#10A37F")))
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 発行した接続コード（大きく、残り時間つき）
    private func pairingCard(_ p: (code: String, until: Date)) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(p.until.timeIntervalSince(ctx.date)))
            VStack(spacing: 10) {
                Text(p.code)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .textSelection(.enabled)
                    .opacity(left == 0 ? 0.35 : 1)
                HStack {
                    Label(left == 0 ? "期限が切れました" : "あと \(left / 60):\(String(format: "%02d", left % 60))", systemImage: "timer")
                        .font(.caption.monospacedDigit()).foregroundStyle(left < 60 ? Color.orange : Color.secondary)
                    Spacer()
                    Button(left == 0 ? "発行し直す" : "コピー") {
                        if left == 0 { pair() } else {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": p.code]], options: [.localOnly: true, .expirationDate: p.until])
                            copied.toggle()
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Color(hex: "#10A37F")).controlSize(.small)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    // MARK: つないでいないとき

    @ViewBuilder
    private var setupSections: some View {
        Section {
            feature("text.bubble.fill", .blue, "話しかけるだけで編集", "「金曜の授業のあとにバイトを入れて」で予定ができます")
            feature("bolt.fill", .orange, "確認なしですぐ反映", "ChatGPT が変えた内容は、そのまま My Time に入ります")
            feature("arrow.uturn.backward.circle.fill", .green, "いつでも元に戻せる", "反映した変更は「取り消す」で戻せます")
        }
        Section {
            SecureField("セットアップコード", text: $setupCode)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($codeFocused)
                .submitLabel(.go)
                .onSubmit(connect)
            Button(action: connect) {
                HStack {
                    Spacer()
                    if busy { ProgressView().tint(.white) } else { Text("つなぐ").font(.headline) }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "#10A37F"))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .disabled(setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || model.storeFailure != nil)
        } header: {
            Text("つなぐ")
        } footer: {
            Text("一度だけ使うセットアップコードを入れます。つなぐと、My Time を開いている間に前30日・先90日の予定などを同期します。")
        }
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).symbolRenderingMode(.hierarchical).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(sub).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 部品

    private func row(_ title: String, _ symbol: String, _ tint: Color, sub: String) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(sub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }

    private func connect() {
        let code = setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        codeFocused = false
        run { try await live.connect(code, model: model); setupCode = "" }
    }

    private func pair() {
        run {
            let code = try await live.pairingCode()
            withAnimation(.snappy) { pairing = (code, Date().addingTimeInterval(600)) }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action() }
            catch { message = (error as? RepositoryError)?.description ?? error.localizedDescription }
        }
    }
}
