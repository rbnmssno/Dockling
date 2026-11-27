import AppKit
import SwiftUI

struct CardAction {
    let title: String
    var primary = false
    let run: () -> Void
}

struct AgendaLine: Hashable {
    let time: String
    let title: String
    var past = false
    var next = false
}

/// A notification over the character's head: an icon, one or two lines, buttons on the right.
struct Card {
    var icon: PixelIcon
    var color: Color
    var text: String
    var meta: String? = nil
    var mono = false
    var actions: [CardAction] = []
    var agenda: [AgendaLine] = []
    /// Stays until a button is pressed (permission requests, Claude waiting).
    var sticky = false
    var duration: TimeInterval = 5
    /// He waits while it is up.
    var hold = false
    /// He calls for attention while it is up (reminders, meetings).
    var call = false
    /// Which kind it is, so a newer card of the same kind replaces it.
    var tag: String? = nil
    /// Where it comes from ("Claude Code"), named over it when it lands in the chat.
    var source: String? = nil

    static let blue = Color(red: 0.24, green: 0.48, blue: 0.96)
    static let amber = Color(red: 0.85, green: 0.51, blue: 0.04)
    static let green = Color(red: 0.12, green: 0.62, blue: 0.33)
    static let red = Color(red: 0.90, green: 0.28, blue: 0.30)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
}

struct CardView: View {
    let card: Card
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var wraps: Bool {
        // A long command is cut in the middle at the same width.
        let font = card.mono ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium) : NSFont.systemFont(ofSize: 12, weight: .semibold)
        return (card.text as NSString).size(withAttributes: [.font: font]).width > 230
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                PixelIconShape(icon: card.icon)
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .frame(width: 22, height: 22)
                    .background(card.color, in: PixelRect(step: 2))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.text)
                        .font(card.mono ? .system(size: 11.5, weight: .medium, design: .monospaced) : .system(size: 12, weight: .semibold))
                        .lineLimit(card.mono ? 1 : 2)
                        .truncationMode(.middle)
                    if let meta = card.meta {
                        Text(meta).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                // A long line gets a fixed width so it wraps and the card grows to two lines; a short
                // one keeps its own width.
                .frame(width: wraps ? 230 : nil, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                if !card.actions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                            Button {
                                action.run()
                                close()
                            } label: {
                                Text(action.title)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .foregroundStyle(action.primary ? (scheme == .dark ? Color.black : Color.white) : Color.primary)
                                    .background(action.primary ? Color.primary.opacity(0.9) : Color.primary.opacity(0.1), in: PixelRect(step: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !card.agenda.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.agenda, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(line.time).font(.pixel(12)).frame(width: 40, alignment: .leading)
                            Text(line.title).font(.system(size: 11.5, weight: line.next ? .semibold : .regular))
                        }
                        .opacity(line.past ? 0.5 : 1)
                        .strikethrough(line.past)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, card.sticky ? 7 : 9)
        .fixedSize()
    }
}

/// A thin dashed strip along the card's bottom edge that drains while the card is up. It is a layer
/// animation, so it costs nothing while it runs.
final class TimerStrip: NSView {
    private let bar = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bar.lineWidth = 2
        bar.lineDashPattern = [7, 3]
        bar.fillColor = nil
        layer?.addSublayer(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func run(duration: TimeInterval, color: NSColor) {
        bar.frame = bounds
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 1))
        path.addLine(to: CGPoint(x: bounds.width, y: 1))
        bar.path = path
        bar.strokeColor = color.cgColor
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 1
        a.toValue = 0
        a.duration = duration
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        bar.add(a, forKey: "drain")
    }
}

/// Shows one card at a time above the character.
final class CardPresenter {
    private weak var stage: PetStage?
    private var box: GlassBox?
    private let timeout = OneShot()
    private(set) var current: Card?
    private var serial = 0
    var onChange: (() -> Void)?
    var look: () -> (dark: Bool, transparency: Double) = { (false, 85) }

    init(stage: PetStage) {
        self.stage = stage
    }

    func show(_ card: Card) {
        guard let stage else { return }
        dismissView()
        current = card
        Log.debug("card: \(card.text) | \(card.meta ?? "") | \(card.actions.map(\.title))")
        Log.note("card shown: \(card.tag ?? "untagged")")
        serial += 1
        let mine = serial
        // A button closes its own card only, not one that replaced it meanwhile.
        let host = NSHostingView(rootView: CardView(card: card, close: { [weak self] in
            guard let self, self.serial == mine, self.current != nil else { return }
            self.hide()
        }))
        let size = host.fittingSize
        let box = GlassBox(content: host, cornerRadius: 13)
        let style = look()
        box.apply(dark: style.dark, transparency: style.transparency)
        box.frame = CGRect(origin: .zero, size: size)
        host.frame = box.bounds
        if !card.sticky {
            let strip = TimerStrip(frame: CGRect(x: 10, y: 2, width: size.width - 20, height: 2))
            box.addSubview(strip)
            strip.run(duration: card.duration, color: style.dark ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0, alpha: 0.35))
        }
        stage.addSubview(box)
        self.box = box
        position()
        box.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            box.animator().alphaValue = 1
        }
        if !card.sticky {
            timeout.schedule(after: card.duration) { [weak self] in self?.hide() }
        } else {
            timeout.cancel()
        }
        onChange?()
    }

    /// Keeps the card over his head and inside the screen.
    func position() {
        guard let stage, let box else { return }
        let w = box.frame.width, h = box.frame.height
        let x = (stage.centerX - w / 2).clamped(6, stage.bounds.width - w - 6)
        let y = min(stage.headTop + 9, stage.bounds.height - h - 4)
        box.frame = CGRect(x: x, y: y, width: w, height: h)
    }

    /// A question that waits for an answer (a permission request, Claude waiting). Passing cards may
    /// cover it for a moment; it comes back when they go.
    private(set) var standing: Card?

    func setStanding(_ card: Card?) {
        standing = card
        if let card {
            if current == nil || current?.sticky == true || current?.tag == card.tag { show(card) }
        } else if current?.sticky == true {
            hide()
        }
    }

    func hide(tag: String? = nil) {
        if let tag, current?.tag != tag { return }
        guard current != nil else { return }
        dismissView()
        current = nil
        if let standing { show(standing); return }
        onChange?()
    }

    private func dismissView() {
        timeout.cancel()
        box?.removeFromSuperview()
        box = nil
    }

    func restyle() {
        guard let box else { return }
        let style = look()
        box.apply(dark: style.dark, transparency: style.transparency)
    }
}
