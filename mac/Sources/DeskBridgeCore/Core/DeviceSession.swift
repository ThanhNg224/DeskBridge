import CoreGraphics
import Foundation
import os

public final class DeviceSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case local
        case remote
        case ended(reason: String)
    }

    /// Set before `start()`. Called on the session queue.
    public var onStateChange: (@Sendable (State) -> Void)?

    private static let connectTimeout: TimeInterval = 8
    private static let silenceTimeout: TimeInterval = 6
    private static let scrollSign: Float = 1 // base direction; users can invert it in Settings
    private static let log = Logger(subsystem: "com.deskbridge.app", category: "session")

    private let adb: ADBBridge
    private let serial: String
    private let jar: URL
    private let settings: Settings
    private let queue = DispatchQueue(label: "deskbridge.session", qos: .userInteractive)
    private let remoteFlag = OSAllocatedUnfairLock(initialState: false)

    private var state: State = .starting {
        didSet {
            if state != oldValue {
                let description = String(describing: state)
                Self.log.info("state: \(description, privacy: .public)")
                onStateChange?(state)
            }
        }
    }

    private var server: LaunchedServer?
    private var connection: Connection?
    private var capturer: InputCapturer?
    private var heartbeat: DispatchSourceTimer?
    private var parser = ServerPacketParser()
    private var coalescer = MoveCoalescer()
    private var detector = EdgeDetector(edge: .right, displays: [])
    private var connectDeadline = Date()
    private var lastReceived = Date()
    /// Our own cursor warp comes back through the event tap as a big mouse move; it must not reach Android.
    private var ignoreMovesUntil = Date.distantPast
    private let shield = CursorShield()
    private var cursorHidden = false
    private var loggedMoves = 0
    /// Display the cursor left from; control returns to the same display.
    private var entryDisplay = CGRect.zero

    public init(adb: ADBBridge, serial: String, jar: URL, settings: Settings) {
        self.adb = adb
        self.serial = serial
        self.jar = jar
        self.settings = settings
    }

    public func start() {
        queue.async { self.launch() }
    }

    public func stop() {
        queue.async { self.end("Stopped") }
    }

    /// For app termination: finishes teardown (cursor, forward, server) before returning.
    public func stopAndWait() {
        queue.sync { self.end("Stopped") }
    }

    // MARK: - Startup

    private func launch() {
        do {
            server = try adb.launchServer(serial: serial, jar: jar)
            connectDeadline = Date().addingTimeInterval(Self.connectTimeout)
            connect()
        } catch {
            end("\(error)")
        }
    }

    private func connect() {
        guard let server, !isEnded else { return }
        parser = ServerPacketParser()
        let connection = Connection(port: UInt16(server.port), queue: queue)
        self.connection = connection
        let token = server.token
        connection.onReady = { [weak connection] in
            connection?.send(ProtocolEncoder.hello(token: token))
        }
        connection.onData = { [weak self] data in self?.received(data) }
        connection.onClosed = { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection else { return }
            connectionClosed()
        }
        connection.start()
    }

    private func connectionClosed() {
        guard !isEnded else { return }
        if state == .starting, let server, server.isRunning, Date() < connectDeadline {
            // The server is probably still starting (or adb accepted before it listened): retry.
            queue.asyncAfter(deadline: .now() + 0.25) { self.connect() }
            return
        }
        let detail = server?.lastError ?? ""
        Self.log.error("connection closed: \(detail, privacy: .public)")
        end(detail.isEmpty ? "Connection to the device was lost" : detail)
    }

    // MARK: - Incoming packets

    private func received(_ data: Data) {
        lastReceived = Date()
        do {
            for packet in try parser.feed(data) {
                switch packet {
                case .helloOK: startRunning()
                case let .exit(along):
                    Self.log.info("server exit along=\(along)")
                    returnToMac(along: along, notifyServer: false)
                case .pong: break
                }
            }
        } catch {
            end("Protocol error: \(error)")
        }
    }

    private func startRunning() {
        guard state == .starting else { return }
        detector = EdgeDetector(
            edge: settings.values.edge, displays: EdgeDetector.currentDisplays(), primary: EdgeDetector.primaryDisplay()
        )
        lastReceived = Date()
        CursorVisibility.allowHidingInBackground()
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0 // no input freeze after warps

        let capturer = InputCapturer(
            isRemote: { [remoteFlag] in remoteFlag.withLock { $0 } },
            onEvent: { [weak self] event in
                guard let self else { return }
                queue.async { self.handle(event) }
            }
        )
        do {
            try capturer.start()
        } catch {
            end("\(error)")
            return
        }
        self.capturer = capturer

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        heartbeat = timer

        state = .local
    }

    private func tick() {
        guard !isEnded else { return }
        if Date().timeIntervalSince(lastReceived) > Self.silenceTimeout {
            end("The device stopped responding")
            return
        }
        connection?.send(ProtocolEncoder.ping())
        if state == .local {
            detector = EdgeDetector(
                edge: settings.values.edge, displays: EdgeDetector.currentDisplays(),
                primary: EdgeDetector.primaryDisplay()
            )
        }
    }

    // MARK: - Captured input

    private func handle(_ event: CapturedEvent) {
        switch (state, event) {
        case let (.local, .move(dx, dy, location)):
            if let crossing = detector.crossing(at: location, deltaX: dx, deltaY: dy) {
                enterRemote(crossing, from: location)
            }

        case let (.remote, .move(dx, dy, _)):
            guard Date() >= ignoreMovesUntil else {
                Self.log.info("ignored warp move dx=\(Int(dx)) dy=\(Int(dy))")
                return
            }
            if loggedMoves < 6 {
                loggedMoves += 1
                Self.log.info("first moves after enter: dx=\(Int(dx)) dy=\(Int(dy))")
            }
            let speed = settings.values.pointerSpeed
            if let delta = coalescer.add(dx: Float(dx * speed), dy: Float(dy * speed)) {
                transmit(delta)
            }

        case let (.remote, .button(button, down)):
            flushMoves()
            switch button {
            case .left: send(ProtocolEncoder.button(1, down: down))
            case .right where settings.values.rightClickIsBack:
                send(ProtocolEncoder.key(code: KeyMapper.backKeyCode, down: down, meta: 0))
            case .right: send(ProtocolEncoder.button(2, down: down))
            case .other: send(ProtocolEncoder.button(4, down: down))
            }

        case let (.remote, .scroll(h, v)):
            flushMoves()
            let prefs = settings.values
            let factor = Float(prefs.scrollSpeed) * (prefs.invertScroll ? -1 : 1) * Self.scrollSign
            send(ProtocolEncoder.scroll(h: Float(h) * factor, v: Float(v) * factor))

        case let (.remote, .key(code, down, flags)):
            if down, KeyMapper.isReleaseChord(keyCode: code, flags: flags) {
                returnToMac(along: nil, notifyServer: true)
                return
            }
            guard let android = KeyMapper.androidKeyCode(forMacKeyCode: code) else { return }
            flushMoves()
            send(ProtocolEncoder.key(
                code: android,
                down: down,
                meta: KeyMapper.androidMeta(forFlags: flags, commandIsControl: settings.values.commandIsControl)
            ))

        default:
            break
        }
    }

    private func enterRemote(_ crossing: EdgeDetector.Crossing, from location: CGPoint) {
        entryDisplay = crossing.display
        loggedMoves = 0
        coalescer = MoveCoalescer()
        send(ProtocolEncoder.enter(edge: detector.edge.androidEntryEdge, along: crossing.along))
        remoteFlag.withLock { $0 = true }
        // Park the frozen cursor well inside the screen: at the very edge the Dock (bottom) or another
        // system UI owns the cursor image and ignores our hide request, leaving a sliver visible.
        let target = parkingPoint(for: location)
        CGWarpMouseCursorPosition(target)
        ignoreMovesUntil = Date().addingTimeInterval(0.15)
        let associate = CGAssociateMouseAndMouseCursorPosition(0) // freeze the Mac cursor; deltas keep flowing
        // Cover that display first so this app owns the cursor image, then hide it (best effort).
        shield.show(covering: displayBounds(containing: target)) { [weak self] in
            self?.queue.async {
                guard let self, self.state == .remote, !self.cursorHidden else { return }
                let hide = CGDisplayHideCursor(CGMainDisplayID())
                self.cursorHidden = hide == .success
                Self.log.info("remote: hide=\(hide.rawValue)")
            }
        }
        let edge = String(describing: detector.edge)
        let width = Int(detector.bounds.width)
        let height = Int(detector.bounds.height)
        Self.log.info("""
        remote: edge=\(edge, privacy: .public) from=(\(Int(location.x)),\(Int(location.y))) \
        park=(\(Int(target.x)),\(Int(target.y))) bounds=\(width)x\(height) \
        associate=\(associate.rawValue)
        """)
        // Ground truth a moment later: where the cursor really is and which app's window is under it
        // (e.g. the Dock owns the cursor image while the pointer is over it).
        queue.asyncAfter(deadline: .now() + 0.2) { [log = Self.log] in
            let now = CGEvent(source: nil)?.location ?? .zero
            let owner = Self.windowOwner(at: now)
            log.info("remote+200ms: cursor=(\(Int(now.x)),\(Int(now.y))) windowUnderCursor=\(owner, privacy: .public)")
        }
        state = .remote
    }

    /// Front-most on-screen window containing `point`, if any.
    private static func topWindow(at point: CGPoint) -> (owner: String, layer: Int)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  CGRect(x: x, y: y, width: w, height: h).contains(point)
            else { continue }
            return (
                window[kCGWindowOwnerName as String] as? String ?? "?",
                window[kCGWindowLayer as String] as? Int ?? 0
            )
        }
        return nil
    }

    private static func windowOwner(at point: CGPoint) -> String {
        topWindow(at: point).map { "\($0.owner)(layer \($0.layer))" } ?? "none"
    }

    /// Bounds of the display containing `point`, falling back to the union of all displays.
    private func displayBounds(containing point: CGPoint) -> CGRect {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else {
            return detector.bounds
        }
        return CGDisplayBounds(display)
    }

    /// Where to leave the frozen cursor while Android has control. It has to be somewhere no other app's
    /// window sits: that app owns the cursor image there and ignores our hide request (the Dock at the
    /// bottom edge, floating panels, ...). Tries points further inside the screen, then sideways.
    private func parkingPoint(for location: CGPoint) -> CGPoint {
        let display = displayBounds(containing: location).insetBy(dx: 24, dy: 24)
        let inward = switch detector.edge {
        case .bottom: CGVector(dx: 0, dy: -1)
        case .top: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: 1, dy: 0)
        case .right: CGVector(dx: -1, dy: 0)
        }
        let along = CGVector(dx: abs(inward.dy), dy: abs(inward.dx))
        for distance in [120.0, 240, 400] as [CGFloat] {
            for offset in [0, -250, 250, -500, 500] as [CGFloat] {
                let point = CGPoint(
                    x: location.x + inward.dx * distance + along.dx * offset,
                    y: location.y + inward.dy * distance + along.dy * offset
                )
                guard display.contains(point) else { continue }
                if let window = Self.topWindow(at: point), window.layer >= 0, window.owner != "DeskBridge" {
                    continue
                }
                return point
            }
        }
        return CGPoint(x: location.x + inward.dx * 120, y: location.y + inward.dy * 120)
    }

    private func returnToMac(along: Float?, notifyServer: Bool) {
        guard state == .remote else { return }
        remoteFlag.withLock { $0 = false }
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
        shield.hide()
        if notifyServer {
            send(ProtocolEncoder.leave())
        }
        if let along {
            CGWarpMouseCursorPosition(detector.returnPoint(along: along, in: entryDisplay))
        }
        state = .local
    }

    // MARK: - Sending

    private func send(_ data: Data) {
        connection?.send(data)
    }

    private func transmit(_ delta: MoveCoalescer.Delta) {
        connection?.send(ProtocolEncoder.moveRel(dx: delta.dx, dy: delta.dy)) { [weak self] in
            // Runs on the connection queue, which is the session queue.
            guard let self, let next = coalescer.sendCompleted() else { return }
            transmit(next)
        }
    }

    private func flushMoves() {
        if let delta = coalescer.flush() {
            transmit(delta)
        }
    }

    // MARK: - Teardown

    private var isEnded: Bool {
        if case .ended = state {
            return true
        }
        return false
    }

    private func end(_ reason: String) {
        guard !isEnded else { return }
        returnToMac(along: nil, notifyServer: false)
        heartbeat?.cancel()
        heartbeat = nil
        capturer?.stop()
        capturer = nil
        connection?.cancel()
        connection = nil
        server?.terminate()
        server = nil
        state = .ended(reason: reason)
    }
}
