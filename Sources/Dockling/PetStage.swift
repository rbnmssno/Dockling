import AppKit
import QuartzCore

/// The transparent strip above the Dock where the character lives. Its empty parts let clicks through
/// to whatever is underneath; only the character and the cards catch the mouse.
final class PetPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // He belongs to one desktop, like any window: a swipe to a full-screen app carries him away with
        // the desktop and the swipe back brings him in, with nothing to hide or show. Ordering him in
        // on another desktop moves him there.
        collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

protocol PetStageDelegate: AnyObject {
    /// The mouse went down on him; whatever moves him has to stop here.
    func stagePressed()
    func stageClicked()
    func stageHovered()
    func stageDragBegan()
    /// He moved under the cursor while being carried.
    func stageCarried()
    func stageDropped()
    func stageMenu() -> NSMenu
    func stageReceivedFiles(_ urls: [URL])
    func stageFileHover(_ inside: Bool)
}

/// Draws the character with Core Animation. Frames, walking and falling are animations handed to the
/// system compositor, so the app does no work per frame.
final class PetStage: NSView {
    weak var delegate: PetStageDelegate?
    let sprite = CALayer()
    private(set) var skin: Skin?
    private var pixelScale = CGSize(width: 2, height: 2)
    /// Height of the standing line inside this view.
    private(set) var floorY: CGFloat = 0
    private var hoverArea: NSTrackingArea?
    private var press: (start: NSPoint, origin: CGPoint, dragging: Bool)?
    private let walkEnd = OneShot()
    private let glideEnd = OneShot()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        sprite.magnificationFilter = .nearest
        sprite.minificationFilter = .nearest
        sprite.contentsGravity = .resize
        sprite.actions = ["position": NSNull(), "bounds": NSNull(), "contentsRect": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(sprite)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Look

    func setSkin(_ skin: Skin?) {
        self.skin = skin
        sprite.contents = skin?.image
        sprite.isHidden = skin == nil
        applySize()
    }

    func setScale(x: CGFloat, y: CGFloat) {
        pixelScale = CGSize(width: 2 * x, height: 2 * y)
        applySize()
    }

    private func applySize() {
        guard let skin else { return }
        let keep = sprite.position
        sprite.bounds = CGRect(x: 0, y: 0, width: skin.frameSize.width * pixelScale.width,
                               height: skin.frameSize.height * pixelScale.height)
        sprite.position = CGPoint(x: keep.x, y: standY)
        updateHoverArea()
    }

    var spriteSize: CGSize { sprite.bounds.size }
    /// Where the layer's bottom edge sits when the soles touch the standing line.
    var standY: CGFloat { floorY - CGFloat(skin?.footPadding ?? 0) * pixelScale.height }
    /// Top of the head, in view coordinates, for placing cards and the chat.
    var headTop: CGFloat { sprite.presentation()?.frame.maxY ?? sprite.frame.maxY }
    var centerX: CGFloat { sprite.presentation()?.position.x ?? sprite.position.x }
    /// Where he ends up once the current walk or fall is over.
    var restingCenterX: CGFloat { sprite.position.x }
    var restingHeadTop: CGFloat { sprite.frame.maxY }

    func setFloor(_ y: CGFloat) {
        floorY = y
        if sprite.animation(forKey: "fall") == nil { sprite.position.y = standY }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sprite.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - Frames

    /// Plays one row of the sheet. Loops repeat until something else plays; one-offs hold their last frame.
    func show(_ anim: SkinAnimation, loop: Bool) {
        guard let skin else { return }
        sprite.removeAnimation(forKey: "frames")
        sprite.contentsRect = skin.contentsRect(row: anim.row, column: max(1, anim.frames) - 1)
        // Already standing in this row since he arrived: it keeps running, no restart from frame one.
        if loop, anim.row == arrivingRow, sprite.animation(forKey: "arrive") != nil { return }
        sprite.removeAnimation(forKey: "arrive")
        arrivingRow = nil
        guard let a = frames(anim, loop: loop) else { return }
        sprite.add(a, forKey: "frames")
    }

    private var arrivingRow: Int?

    private func frames(_ anim: SkinAnimation, loop: Bool) -> CAKeyframeAnimation? {
        guard let skin, anim.frames > 1 else { return nil }
        let rects = (0..<anim.frames).map { NSValue(rect: skin.contentsRect(row: anim.row, column: $0)) }
        let a = CAKeyframeAnimation(keyPath: "contentsRect")
        a.values = rects
        // Discrete mode wants one more key time than values: each frame holds for an equal slice.
        a.keyTimes = (0...rects.count).map { NSNumber(value: Double($0) / Double(rects.count)) }
        a.calculationMode = .discrete
        a.duration = anim.duration
        a.repeatCount = loop ? .infinity : 1
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        return a
    }

    // MARK: - Badge

    private let badge = CATextLayer()

    /// A small number over the head; it rides on the character's layer, so it moves with him for free.
    func setBadge(_ count: Int) {
        guard count > 0 else { badge.removeFromSuperlayer(); return }
        badge.string = "\(count)"
        badge.font = PixelFont.ns(12)
        badge.fontSize = 12
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
        badge.cornerRadius = 9
        badge.contentsScale = window?.backingScaleFactor ?? 2
        badge.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        badge.frame = CGRect(x: sprite.bounds.width * 0.66, y: sprite.bounds.height - 16, width: 20, height: 18)
        if badge.superlayer == nil { sprite.addSublayer(badge) }
    }

    // MARK: - Moving

    func place(x: CGFloat) {
        stopMoving()
        sprite.position = CGPoint(x: x, y: standY)
        updateHoverArea()
    }

    /// Walks to `x` at `speed` points per second and calls back on arrival. `arrive` is the row he
    /// stands in once there: the compositor switches to it at the exact moment he stops, so he never
    /// runs on the spot while the app catches up.
    func walk(to x: CGFloat, speed: CGFloat, arrive: SkinAnimation?, completion: @escaping () -> Void) {
        let from = centerX
        stopMoving()
        let duration = TimeInterval(abs(x - from) / max(speed, 1))
        sprite.position = CGPoint(x: x, y: standY)
        let now = sprite.convertTime(CACurrentMediaTime(), from: nil)
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = from
        a.toValue = x
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        sprite.add(a, forKey: "walk")
        arrivingRow = arrive?.row
        if let arrive {
            if let rest = frames(arrive, loop: true) {
                rest.beginTime = now + duration
                sprite.add(rest, forKey: "arrive")
            } else if let skin {
                // A one-frame row: hold that frame from the moment he arrives.
                let still = CABasicAnimation(keyPath: "contentsRect")
                still.fromValue = NSValue(rect: skin.contentsRect(row: arrive.row, column: 0))
                still.toValue = still.fromValue
                still.beginTime = now + duration
                still.duration = .greatestFiniteMagnitude
                sprite.add(still, forKey: "arrive")
            }
        }
        startHoverWatch()
        walkEnd.schedule(after: duration) { [weak self] in
            self?.stopHoverWatch()
            self?.updateHoverArea()
            completion()
        }
    }

    // While he runs, the cursor is checked a few times a second (he can run into a cursor that stands
    // still, which sends no mouse events). Nothing runs when he stands.
    private var hoverWatch: Timer?

    private func startHoverWatch() {
        stopHoverWatch()
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.mouseIsOver else { return }
            self.delegate?.stageHovered()
        }
        t.tolerance = 0.04
        RunLoop.main.add(t, forMode: .common)
        hoverWatch = t
    }

    private func stopHoverWatch() {
        hoverWatch?.invalidate()
        hoverWatch = nil
    }

    /// The cursor is over the character right now.
    var mouseIsOver: Bool {
        guard let window, window.isVisible, skin != nil else { return false }
        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return onSprite(p)
    }

    /// Drops from where it is to the standing line, accelerating like a falling object. Returns how long
    /// the fall takes.
    @discardableResult
    func fall(completion: @escaping () -> Void) -> TimeInterval {
        let current = sprite.position
        let height = max(0, current.y - standY)
        stopMoving()
        let duration = TimeInterval(sqrt(2 * height / 2600))
        sprite.position = CGPoint(x: current.x, y: standY)
        guard duration > 0.02 else { updateHoverArea(); completion(); return 0 }
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = current.y
        a.toValue = standY
        a.duration = duration
        // Position grows with the square of time, as under gravity.
        a.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1.0 / 3)
        sprite.add(a, forKey: "fall")
        walkEnd.schedule(after: duration) { [weak self] in
            self?.updateHoverArea()
            completion()
        }
        return duration
    }

    /// Freezes the character where it is now on screen.
    var isDiving: Bool { sprite.animation(forKey: "dive") != nil }

    /// The Dock left this screen: he goes down below its edge after it, then `completion` runs.
    func dive(completion: @escaping () -> Void) {
        stopMoving()
        let from = sprite.position.y
        let below = -sprite.bounds.height - 4
        sprite.position.y = below
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = from
        a.toValue = below
        a.duration = 0.24
        a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        sprite.add(a, forKey: "dive")
        Log.debug("dive from \(Int(from))")
        // Its own timer: a walk or a snap to the Dock meanwhile must not lose the way to the new Dock.
        glideEnd.schedule(after: a.duration) { completion() }
    }

    /// The Dock came to this screen: he comes up from below its edge onto the Dock at `x`.
    func surface(at x: CGFloat) {
        stopMoving()
        sprite.position = CGPoint(x: x, y: standY)
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = -sprite.bounds.height - 4
        a.toValue = standY
        a.duration = 0.34
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
        sprite.add(a, forKey: "surface")
        Log.debug("surface at \(Int(x))")
        glideEnd.schedule(after: a.duration) { [weak self] in self?.updateHoverArea() }
    }

    func stopMoving() {
        let moving = walkEnd.isPending
        if let p = sprite.presentation()?.position { sprite.position = p }
        sprite.removeAnimation(forKey: "walk")
        sprite.removeAnimation(forKey: "fall")
        sprite.removeAnimation(forKey: "dive")
        sprite.removeAnimation(forKey: "surface")
        if moving {
            // Stopped before arriving: the stand-in row must not start later on its own.
            sprite.removeAnimation(forKey: "arrive")
            arrivingRow = nil
        }
        walkEnd.cancel()
        stopHoverWatch()
        if moving { updateHoverArea() }
    }

    var isMoving: Bool { walkEnd.isPending }

    // MARK: - Mouse

    private func onSprite(_ point: NSPoint) -> Bool {
        (sprite.presentation()?.frame ?? sprite.frame).insetBy(dx: 2, dy: 2).contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit !== self { return hit }
        // Only the character itself catches the mouse in this view.
        let local = convert(point, from: superview)
        return onSprite(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard onSprite(p) else { return }
        // The brain stops the walk or fall itself, so it knows he is standing (or held) now.
        delegate?.stagePressed()
        stopMoving()
        press = (p, sprite.position, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var press else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !press.dragging {
            guard hypot(p.x - press.start.x, p.y - press.start.y) > 4 else { return }
            press.dragging = true
            self.press = press
            delegate?.stageDragBegan()
        }
        let x = (press.origin.x + p.x - press.start.x).clamped(bounds.minX + spriteSize.width / 2, bounds.maxX - spriteSize.width / 2)
        let y = (press.origin.y + p.y - press.start.y).clamped(standY, bounds.maxY - spriteSize.height)
        sprite.position = CGPoint(x: x, y: y)
        delegate?.stageCarried()
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        if press.dragging {
            delegate?.stageDropped()
        } else {
            delegate?.stageClicked()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard onSprite(p), let menu = delegate?.stageMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func updateHoverArea() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        guard skin != nil else { return }
        let area = NSTrackingArea(rect: sprite.frame, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        delegate?.stageHovered()
    }

    // MARK: - Files dropped on him

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let inside = onSprite(convert(sender.draggingLocation, from: nil))
        delegate?.stageFileHover(inside)
        return inside ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        delegate?.stageFileHover(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard onSprite(convert(sender.draggingLocation, from: nil)) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        delegate?.stageReceivedFiles(urls)
        return true
    }
}
