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
    private var detector = EdgeDetector(edge: .right, bounds: .zero)
    private var connectDeadline = Date()
    private var lastReceived = Date()

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
                case let .exit(along): returnToMac(along: along, notifyServer: false)
                case .pong: break
                }
            }
        } catch {
            end("Protocol error: \(error)")
        }
    }

    private func startRunning() {
        guard state == .starting else { return }
        detector = EdgeDetector(edge: settings.values.edge, bounds: EdgeDetector.currentBounds())
        lastReceived = Date()

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
            detector = EdgeDetector(edge: settings.values.edge, bounds: EdgeDetector.currentBounds())
        }
    }

    // MARK: - Captured input

    private func handle(_ event: CapturedEvent) {
        switch (state, event) {
        case let (.local, .move(dx, _, location)):
            if let along = detector.crossing(at: location, deltaX: dx) {
                enterRemote(along: along)
            }

        case let (.remote, .move(dx, dy, _)):
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

    private func enterRemote(along: Float) {
        coalescer = MoveCoalescer()
        send(ProtocolEncoder.enter(edge: detector.edge.androidEntryEdge, along: along))
        remoteFlag.withLock { $0 = true }
        CGAssociateMouseAndMouseCursorPosition(0) // freeze the Mac cursor; deltas keep flowing
        CGDisplayHideCursor(CGMainDisplayID()) // best effort for a background app
        state = .remote
    }

    private func returnToMac(along: Float?, notifyServer: Bool) {
        guard state == .remote else { return }
        remoteFlag.withLock { $0 = false }
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        if notifyServer {
            send(ProtocolEncoder.leave())
        }
        if let along {
            CGWarpMouseCursorPosition(detector.returnPoint(along: along))
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
