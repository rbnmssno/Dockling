import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What goes with the next question.
struct ChatAttachment {
    enum Kind { case file, text, screenshot }
    var kind: Kind
    var label: String
    /// Text content (a text file, a selection, the clipboard).
    var text: String?
    /// PNG data for a screenshot.
    var image: Data?
    var thumbnail: NSImage?
    var quick: [(String, String)]
}

struct ChatMessage: Identifiable {
    enum Role { case me, bot, note }
    let id = UUID()
    var role: Role
    var text: String
    var thinking = false
    var actions: [CardAction] = []
}

final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var busy = false
    @Published var listening = false
    @Published var attachment: ChatAttachment?
    @Published var limits = PlanLimits()
    /// Claude Code is being asked for the limits right now.
    @Published var checkingLimits = false
    @Published var status = ChatModel.online
    @Published var avatar: NSImage?
    /// How sharply the screen behind the glass shows through (0..1), from the transparency setting.
    @Published var clarity: Double = 0

    /// The status line under the title while Claude Code is found.
    static let online = tr("на связи", "online")
    static let noClaude = tr("нет claude code", "no claude code")

    enum ButtonMode { case mic, send, stop, listen }
    var buttonMode: ButtonMode {
        if busy { return .stop }
        if listening { return .listen }
        return input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .mic : .send
    }
}

// MARK: - The window

/// A panel that takes typing without making the app the active one, like Spotlight.
final class ChatPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 348, height: 352),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The window shadow would follow the window's square bounds, not the glass's rounded shape.
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// MARK: - The view

struct ChatView: View {
    @ObservedObject var model: ChatModel
    let send: () -> Void
    let stop: () -> Void
    let startListening: () -> Void
    let stopListening: () -> Void
    let quick: (String) -> Void
    let dropAttachment: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private var dark: Bool { scheme == .dark }
    // Bubbles and the field keep their colour but grow denser as the glass clears, so the screen behind
    // does not run through the text. Dark theme: a smoke under the light tint (one colour that equals
    // the two layered); light theme: more white.
    private func backing(dark o: Double, light l: Double, lightClear: Double) -> Color {
        if dark {
            let smoke = 0.62 * model.clarity
            let a = 1 - (1 - o) * (1 - smoke)
            return Color(white: o / a).opacity(a)
        }
        return Color.white.opacity(l + (lightClear - l) * model.clarity)
    }
    private var field: Color { backing(dark: 0.13, light: 0.45, lightClear: 0.72) }
    private var botBubble: Color { backing(dark: 0.18, light: 0.66, lightClear: 0.86) }
    private var meBubble: Color { dark ? Color(white: 0.96).opacity(0.94) : Color(white: 0.08).opacity(0.9) }
    private var meText: Color { dark ? .black : .white }
    private var dim: Color { Color.primary.opacity(0.62) }

    var body: some View {
        VStack(spacing: 0) {
            header
            limits
            log
            if let a = model.attachment { attachmentRow(a) }
            inputRow
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // The face close up, 1.5 points per sprite pixel: three screen pixels each on a Retina display.
            let side = min(40, max(24, (model.avatar?.size.width ?? 21) * 1.5))
            ZStack {
                PixelRect(step: 3).fill(Color.black)
                if let avatar = model.avatar {
                    Image(nsImage: avatar).interpolation(.none).resizable()
                        .frame(width: side, height: side).clipShape(PixelRect(step: 3))
                }
            }
            .frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 1) {
                Text("GHOST").font(.pixel(16))
                Text(model.status.uppercased()).font(.pixel(11))
                    .foregroundStyle(model.status == ChatModel.online ? Color.green : dim)
            }
            Spacer()
            Button(action: close) {
                PixelIconShape(icon: .close).fill(Color.primary).frame(width: 11, height: 11)
                    .frame(width: 28, height: 28).background(field, in: PixelRect(step: 3))
            }
            .buttonStyle(.plain)
            .help(tr("Закрыть", "Close"))
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                limitRow(tr("Сессия", "Session"), model.limits.session)
                limitRow(tr("Неделя", "Week"), model.limits.week)
            }
            Text(limitNote).font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { dottedLine }
        .overlay(alignment: .bottom) { dottedLine }
        .padding(.horizontal, 14)
    }

    private var dottedLine: some View {
        Rectangle().fill(.clear).frame(height: 2)
            .overlay(Line().stroke(Color.primary.opacity(0.24), style: StrokeStyle(lineWidth: 2, dash: [2, 3])))
    }

    private var limitNote: String {
        guard let reset = model.limits.sessionReset else {
            return model.checkingLimits ? tr("Узнаю лимиты…", "Checking the limits…") : tr("Лимиты появятся после первого ответа.", "Limits appear after the first reply.")
        }
        let mins = Int(reset.timeIntervalSinceNow / 60)
        if mins < 1 { return tr("Лимит сессии уже обновился, цифры уточнятся со следующим ответом.", "The session limit has reset; the numbers update with the next reply.") }
        return tr("Сессия обновится через ", "Session resets in ") + durationText(minutes: mins) + "."
    }

    private func limitRow(_ label: String, _ value: Double?) -> some View {
        let pct = Int((value ?? 0).rounded())
        let on = Int((Double(pct) / 10).rounded())
        let color: Color = pct >= 95 ? Card.red : pct >= 80 ? Card.amber : Color.primary
        return HStack(spacing: 7) {
            Text(label.uppercased()).font(.pixel(11))
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    Rectangle().fill(i < on && value != nil ? color : Color.primary.opacity(0.18)).frame(height: 9)
                }
            }
            Text(value == nil ? "—" : "\(pct)%").font(.pixel(11)).frame(minWidth: 26, alignment: .trailing)
        }
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(model.messages) { m in bubble(m).id(m.id) }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .scrollIndicators(.never)
            .onChange(of: model.messages.last?.text) { _ in
                if let id = model.messages.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: model.messages.count) { _ in
                if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        switch m.role {
        case .note:
            Text(m.text).font(.system(size: 11.5)).foregroundStyle(dim).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .me:
            HStack {
                Spacer(minLength: 40)
                Text(m.text).font(.system(size: 13)).foregroundStyle(meText).textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7).background(meBubble, in: PixelRect(step: 3))
            }
        case .bot:
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    if m.thinking && m.text.isEmpty {
                        ThinkingDots().frame(height: 16)
                    } else {
                        Text(m.text).font(.system(size: 13)).textSelection(.enabled)
                    }
                    if !m.actions.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(m.actions.enumerated()), id: \.offset) { _, a in
                                quickButton(a.title, primary: a.primary) { a.run() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 7).background(botBubble, in: PixelRect(step: 3))
                Spacer(minLength: 40)
            }
        }
    }

    private func quickButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(primary ? meText : Color.primary)
                .background(primary ? meBubble : field, in: PixelRect(step: 3))
        }
        .buttonStyle(.plain)
    }

    private func attachmentRow(_ a: ChatAttachment) -> some View {
        FlowRow(spacing: 6) {
            HStack(spacing: 6) {
                if let thumb = a.thumbnail {
                    Image(nsImage: thumb).resizable().scaledToFill().frame(width: 28, height: 18).clipShape(PixelRect(step: 2))
                }
                Text(a.label).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
                Button(action: dropAttachment) { Text("×").font(.system(size: 13)).foregroundStyle(dim) }.buttonStyle(.plain)
            }
            .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 4)
            .background(botBubble, in: PixelRect(step: 3))
            ForEach(Array(a.quick.enumerated()), id: \.offset) { _, q in
                quickButton(q.0) { quick(q.1) }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
    }

    private var inputRow: some View {
        HStack(spacing: 7) {
            TextField(model.listening ? tr("Слушаю…", "Listening…") : tr("Спроси что-нибудь", "Ask anything"), text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { if model.buttonMode == .send { send() } }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(field, in: PixelRect(step: 3))
            ActionButton(mode: model.buttonMode, background: field, send: send, stop: stop,
                         startListening: startListening, stopListening: stopListening)
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 14)
    }
}

/// One button: microphone while the field is empty (hold to talk), arrow when there is text, square while
/// a reply runs. It looks the same in every state; only the icon changes.
private struct ActionButton: View {
    let mode: ChatModel.ButtonMode
    let background: Color
    let send: () -> Void
    let stop: () -> Void
    let startListening: () -> Void
    let stopListening: () -> Void
    @State private var pressMode: ChatModel.ButtonMode?

    var body: some View {
        let icon: PixelIcon = mode == .send ? .send : mode == .stop ? .stop : .mic
        PixelIconShape(icon: icon).fill(Color.primary).frame(width: 15, height: 15)
            .frame(width: 36, height: 36)
            .background(background, in: PixelRect(step: 3))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressMode == nil else { return }
                        pressMode = mode
                        if mode == .mic { startListening() }
                    }
                    .onEnded { _ in
                        let m = pressMode
                        pressMode = nil
                        switch m {
                        case .mic?, .listen?: stopListening()
                        case .send?: send()
                        case .stop?: stop()
                        case nil: break
                        }
                    }
            )
            .help(mode == .send ? tr("Отправить", "Send") : mode == .stop ? tr("Остановить ответ", "Stop the reply") : tr("Зажми и говори", "Hold to talk"))
    }
}

private struct ThinkingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.33, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Rectangle().fill(Color.primary.opacity(i == phase ? 0.75 : 0.25)).frame(width: 5, height: 5)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Lays its children out left to right and wraps to a new line when they do not fit.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
