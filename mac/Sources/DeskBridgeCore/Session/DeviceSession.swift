import AppKit
import CoreGraphics
import Foundation
import os

/// One connection to one device: starts the server, connects, and runs the Mac / Android control state
/// machine (`local` ⇄ `remote`). All state lives on `queue`; the event tap only reads the swallowing flag.
public final class DeviceSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case starting
        case local
        case remote
        case ended(SessionEndReason)
    }

    /// Set before `start()`. Called on the session queue.
    public var onStateChange: (@Sendable (State) -> Void)?

    private static let connectTimeout: TimeInterval = 8
    private static let connectRetryDelay = 0.25
    private static let silenceTimeout: TimeInterval = 6
    private static let heartbeatInterval = 2.0
    private static let log = Logger(subsystem: "com.deskbridge.app", category: "session")

    private let adb: ADBBridge
    private let serial: String
    private let jar: URL
    private let settings: Settings
    private let queue = DispatchQueue(label: "deskbridge.session", qos: .userInteractive)
    private let cursor: RemoteCursor
    private let clipboard = MacClipboard()

    private var state: State = .starting {
        didSet {
            guard state != oldValue else { return }
            let description = String(describing: state)
            Self.log.info("state: \(description, privacy: .public)")
            onStateChange?(state)
        }
    }

    private var server: LaunchedServer?
    private var connection: Connection?
    private var capturer: InputCapturer?
    private var heartbeat: DispatchSourceTimer?
    private var parser = ServerPacketParser()
    private var coalescer = MoveCoalescer()
    private var detector = EdgeDetector(edge: .right, displays: [])
    private var screenObserver: NSObjectProtocol?
    private var connectDeadline = Date()
    private var lastReceived = Date()
    /// Display the cursor left from; control returns to the same display.
    private var entryDisplay = CGRect.zero

    public init(adb: ADBBridge, serial: String, jar: URL, settings: Settings) {
        self.adb = adb
        self.serial = serial
        self.jar = jar
        self.settings = settings
        cursor = RemoteCursor(queue: queue)
    }

    public func start() {
        queue.async { self.launch() }
    }

    public func stop() {
        queue.async { self.end(.stopped) }
    }

    /// Call when the edge setting changed so the new edge applies at once.
    public func settingsChanged() {
        queue.async { self.refreshDetector() }
    }

    /// For app termination: finishes teardown (cursor, forward, server) before returning.
    public func stopAndWait() {
        queue.sync { self.end(.stopped) }
    }

    // MARK: - Startup

    private func launch() {
        do {
            server = try adb.launchServer(serial: serial, jar: jar)
            connectDeadline = Date().addingTimeInterval(Self.connectTimeout)
            connect()
        } catch {
            end(.adbFailed("\(error)"))
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
            queue.asyncAfter(deadline: .now() + Self.connectRetryDelay) { self.connect() }
            return
        }
        let detail = server?.lastError ?? ""
        Self.log.error("connection closed: \(detail, privacy: .public)")
        end(.connectionLost(serverLog: detail))
    }

    private func startRunning() {
        guard state == .starting else { return }
        refreshDetector()
        lastReceived = Date()
        cursor.prepare()

        cursor.setKeyboardHandlers(
            text: { [weak self] text in
                guard let self else { return }
                queue.async { self.sendText(text) }
            },
            command: { [weak self] code, flags in
                guard let self else { return }
                queue.async { self.sendKeyPress(code: code, flags: flags) }
            }
        )
        let capturer = InputCapturer(
            isRemote: cursor.swallowingProbe(),
            deliversKeyToMac: cursor.keyRouter(),
            onEvent: { [weak self] event in
                guard let self else { return }
                queue.async { self.handle(event) }
            }
        )
        do {
            try capturer.start()
        } catch {
            end(.captureDenied)
            return
        }
        self.capturer = capturer

        // Displays plugged, unplugged or rearranged: rebuild the edges right away.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.refreshDetector() }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        heartbeat = timer

        state = .local
    }

    /// Edges are fixed while Android has control (the way back must match the way in); the change is
    /// applied when control returns.
    private func refreshDetector() {
        guard state != .remote else { return }
        detector = EdgeDetector(edge: settings.values.edge, displays: Displays.current(), primary: Displays.primary())
    }

    private func tick() {
        guard !isEnded else { return }
        if Date().timeIntervalSince(lastReceived) > Self.silenceTimeout {
            end(.deviceSilent)
            return
        }
        connection?.send(ProtocolEncoder.ping())
    }

    // MARK: - Incoming packets

    private func received(_ data: Data) {
        lastReceived = Date()
        do {
            for packet in try parser.feed(data) {
                switch packet {
                case .helloOK: startRunning()
                case let .exit(along): returnToMac(along: along, notifyServer: false)
                case let .clipboard(text): receivedClipboard(text)
                case .pong: break
                }
            }
        } catch {
            end(.protocolError("\(error)"))
        }
    }

    /// The phone's new clip arrives just before it hands control back (or after our LEAVE).
    private func receivedClipboard(_ text: String) {
        if settings.values.shareClipboard {
            clipboard.apply(text)
        }
    }

    // MARK: - Captured input

    private func handle(_ event: CapturedEvent) {
        switch (state, event) {
        case let (.local, .move(dx, dy, location)):
            if let crossing = detector.crossing(at: location, deltaX: dx, deltaY: dy) {
                enterRemote(crossing, from: location)
            }
        case (.remote, _):
            if case let .move(dx, dy, _) = event, cursor.shouldIgnoreMove(dx: dx, dy: dy) {
                return
            }
            perform(RemoteInput.action(for: event, prefs: settings.values))
        default:
            break
        }
    }

    private func perform(_ action: RemoteAction) {
        switch action {
        case let .move(dx, dy):
            if let delta = coalescer.add(dx: dx, dy: dy) {
                transmit(delta)
            }
        case let .send(data):
            flushMoves()
            send(data)
        case .releaseToMac:
            returnToMac(along: nil, notifyServer: true)
        case .ignore:
            break
        }
    }

    private func enterRemote(_ crossing: EdgeDetector.Crossing, from location: CGPoint) {
        entryDisplay = crossing.display
        coalescer = MoveCoalescer()
        if settings.values.shareClipboard {
            send(ProtocolEncoder.clipboard(clipboard.textToSend() ?? "")) // also tells the phone to share this visit
        }
        send(ProtocolEncoder.enter(edge: detector.edge.androidEntryEdge, along: crossing.along))
        state = .remote
        cursor.engage(from: location, on: crossing.display, edge: detector.edge)
    }

    private func returnToMac(along: Float?, notifyServer: Bool) {
        guard state == .remote else { return }
        if notifyServer {
            send(ProtocolEncoder.leave())
        }
        cursor.release(returnTo: along.map { detector.returnPoint(along: $0, in: entryDisplay) })
        state = .local
        refreshDetector()
    }

    // MARK: - Text from a Mac input method

    /// Text a Mac input method composed (Vietnamese Telex, ...), typed on the phone; split to fit a packet.
    private func sendText(_ text: String) {
        guard state == .remote else { return }
        flushMoves()
        var chunk = ""
        for character in text {
            if chunk.utf8.count + character.utf8.count > ProtocolEncoder.maxTextBytes {
                send(ProtocolEncoder.text(chunk))
                chunk = ""
            }
            chunk.append(character)
        }
        send(ProtocolEncoder.text(chunk))
    }

    /// A key the input method handed back unhandled (Return, Backspace, an arrow, ...): a plain key press.
    private func sendKeyPress(code: UInt16, flags: UInt64) {
        guard state == .remote else { return }
        for down in [true, false] {
            perform(RemoteInput.action(for: .key(code: code, down: down, flags: flags), prefs: settings.values))
        }
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

    private func end(_ reason: SessionEndReason) {
        guard !isEnded else { return }
        returnToMac(along: nil, notifyServer: false)
        heartbeat?.cancel()
        heartbeat = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        capturer?.stop()
        capturer = nil
        connection?.cancel()
        connection = nil
        server?.terminate()
        server = nil
        state = .ended(reason)
    }
}
