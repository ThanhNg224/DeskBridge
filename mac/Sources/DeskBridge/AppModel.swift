import AppKit
import DeskBridgeCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case paused, searching, connected, controlling }
    enum WirelessOperation: Equatable {
        case idle, readingAddress, preparing, connecting, checkingDevice, startingSession, disconnecting
    }

    var phase = Phase.searching
    var status = StatusText.searching
    var setup = SetupState()
    private(set) var activePhone: AdbDevice?
    private(set) var pendingPhone: AdbDevice?
    var wirelessIP = ""
    var wirelessPort = "5555"
    private(set) var wirelessOperation = WirelessOperation.idle
    var wirelessErrorMessage: String?
    private(set) var installingADB = false
    private(set) var adbInstallError: String?
    private(set) var checkingUpdates = false
    private(set) var updateMessage: String?
    private(set) var updateURL: URL?

    var isOperatingWireless: Bool {
        wirelessOperation != .idle
    }

    var selectedPhone: AdbDevice? {
        guard let serial = prefs.preferredSerial else { return nil }
        return setup.phones.first { $0.serial == serial }
            ?? AdbDevice(
                serial: serial,
                state: "offline",
                model: rememberedPhone?.serial == serial ? rememberedPhone?.model : nil
            )
    }

    var canConnectWireless: Bool {
        !isOperatingWireless && (try? wirelessInput()) != nil
    }

    var canRetryConnection: Bool {
        isEnabled && !isOperatingWireless && activePhone == nil && pendingPhone == nil && selectedPhone != nil
    }

    var wirelessInputError: String? {
        guard !wirelessIP.isEmpty || wirelessPort != "5555" else { return nil }
        do { _ = try wirelessInput(); return nil }
        catch { return wirelessMessage(for: error) }
    }

    var prefs: Settings.Values {
        didSet {
            settings.values = prefs
            session?.settingsChanged()
            if !updatingPreference, oldValue.preferredSerial != prefs.preferredSerial {
                selectionChanged()
            }
        }
    }

    var isEnabled: Bool {
        get { prefs.enabled }
        set {
            guard prefs.enabled != newValue else { return }
            prefs.enabled = newValue
            selectionGeneration &+= 1
            cancelWireless(restoreSelection: true)
            reconnectSuppressed = !newValue
            resetRetry()
            stopSession()
            phase = newValue ? .searching : .paused
            status = newValue ? StatusText.searching : StatusText.paused
            wakeDiscovery()
        }
    }

    var showDockIcon: Bool {
        get { prefs.showDockIcon }
        set { prefs.showDockIcon = newValue; applyDockIcon() }
    }

    var launchAtLogin: Bool {
        didSet { loginItemChanged() }
    }

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private let integratesWithSystem: Bool
    @ObservationIgnored private let pollsAutomatically: Bool
    @ObservationIgnored private var session: (any AppSession)?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var sessionPhone: AdbDevice?
    @ObservationIgnored private var stoppingSession = false
    @ObservationIgnored private var selectionGeneration: UInt = 0
    @ObservationIgnored private var discoveryGeneration: UInt = 0
    @ObservationIgnored private var backoff = Backoff()
    @ObservationIgnored private var retryNotBefore = Date.distantPast
    @ObservationIgnored private var reconnectSuppressed = false
    @ObservationIgnored private var rememberedPhone: AdbDevice?
    @ObservationIgnored private var updatingPreference = false
    @ObservationIgnored private var syncingLoginItem = false
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DeviceWatcher?
    @ObservationIgnored private var wirelessTask: Task<Void, Never>?
    @ObservationIgnored private var wirelessDeadline: Task<Void, Never>?
    @ObservationIgnored private var wirelessContext: ADBOperation?
    @ObservationIgnored private var wirelessID: UUID?
    @ObservationIgnored private var wirelessOrigin: String?
    @ObservationIgnored private var wirelessTarget: String?
    @ObservationIgnored private var currentWirelessRequest: WirelessRequest?
    @ObservationIgnored private var failedWirelessRequest: WirelessRequest?
    @ObservationIgnored private var isShuttingDown = false

    init(settings: Settings = Settings(), dependencies: AppDependencies = AppDependencies(),
         integratesWithSystem: Bool = true, pollsAutomatically: Bool = true)
    {
        self.settings = settings
        self.dependencies = dependencies
        self.integratesWithSystem = integratesWithSystem
        self.pollsAutomatically = pollsAutomatically
        prefs = settings.values
        launchAtLogin = integratesWithSystem ? LoginItem.isEnabled : false
        if !prefs.enabled {
            phase = .paused; status = StatusText.paused
        }
        if integratesWithSystem {
            applyDockIcon()
            Permissions.requestAccessibility()
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shutdown()
                    self?.session?.stopAndWait()
                }
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.session == nil {
                        self?.wakeDiscovery()
                    }
                }
            }
        }
        if pollsAutomatically {
            wakeDiscovery()
        }
    }

    func shutdown() {
        isShuttingDown = true
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        wirelessTask?.cancel()
        wirelessContext?.cancel()
        wirelessDeadline?.cancel()
        watcher?.stop()
        session?.stop()
    }

    func installADB(from url: URL) {
        guard !installingADB else { return }
        installingADB = true
        adbInstallError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
                installingADB = false
            }
            do {
                try await dependencies.installADB(url)
                wakeDiscovery()
            } catch ManagedADB.InstallError.incompatibleServer {
                adbInstallError =
                    String(
                        localized: "The existing Android tools are incompatible. Close the other tools and try again."
                    )
            } catch {
                adbInstallError =
                    String(localized: "Could not verify the Android tools ZIP. Download it from Google and try again.")
            }
        }
    }

    func checkForUpdates() {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        updateMessage = nil
        updateURL = nil
        Task {
            defer { checkingUpdates = false }
            do {
                updateURL = try await dependencies.checkRelease(dependencies.installedVersion())
                updateMessage = updateURL == nil
                    ? String(localized: "DeskBridge is up to date.")
                    : String(localized: "A new version is available.")
            } catch ReleaseChecker.Error.rateLimited {
                updateMessage = String(localized: "GitHub limited or refused the request. Try again later.")
            } catch {
                updateMessage = String(localized: "Could not check for updates. Check your connection and try again.")
            }
        }
    }

    // MARK: - Selection

    func selectDevice(serial: String?) {
        guard let serial else { return }
        if prefs.preferredSerial == serial {
            selectionChanged()
        } else {
            prefs.preferredSerial = serial
        }
    }

    private func setPreference(_ serial: String?) {
        updatingPreference = true
        prefs.preferredSerial = serial
        updatingPreference = false
    }

    private func selectionChanged() {
        selectionGeneration &+= 1
        cancelWireless(restoreSelection: false)
        reconnectSuppressed = false
        wirelessErrorMessage = nil
        failedWirelessRequest = nil
        resetRetry()
        stopSession()
        phase = isEnabled ? .searching : .paused
        status = isEnabled ? StatusText.searching : StatusText.paused
        wakeDiscovery()
    }

    private func stopSession() {
        activePhone = nil
        pendingPhone = nil
        if session != nil {
            stoppingSession = true
            session?.stop()
        }
    }

    private func resetRetry() {
        backoff.reset(); retryNotBefore = .distantPast
    }

    private func recordFailure() {
        backoff.recordFailure()
        retryNotBefore = dependencies.now().addingTimeInterval(backoff.delay)
    }

    func retryConnection() {
        guard !isOperatingWireless else { return }
        if let request = failedWirelessRequest {
            beginWireless(request)
        } else {
            reconnectSuppressed = false; resetRetry(); wakeDiscovery()
        }
    }

    private func applyDockIcon() {
        guard integratesWithSystem else { return }
        NSApplication.shared.setActivationPolicy(prefs.showDockIcon ? .regular : .accessory)
    }

    private func loginItemChanged() {
        guard integratesWithSystem, !syncingLoginItem else { return }
        do { try LoginItem.set(launchAtLogin) }
        catch {
            status = error.localizedDescription
            syncingLoginItem = true
            launchAtLogin = LoginItem.isEnabled
            syncingLoginItem = false
        }
    }

    // MARK: - Discovery

    private func wakeDiscovery() {
        guard !isShuttingDown else { return }
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        let generation = discoveryGeneration
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                await refreshOnce(generation: generation)
                guard pollsAutomatically, !Task.isCancelled, generation == discoveryGeneration else { return }
                do { try await dependencies.sleep(pollSeconds) } catch { return }
            } while !Task.isCancelled
        }
    }

    /// Runs one pass without advancing a polling clock in model tests.
    func refreshNow() async {
        wakeDiscovery()
        if !pollsAutomatically {
            await discoveryTask?.value
        }
    }

    private var pollSeconds: TimeInterval {
        if session == nil, isEnabled, !reconnectSuppressed, retryNotBefore > dependencies.now() {
            return max(0.1, retryNotBefore.timeIntervalSince(dependencies.now()))
        }
        return watcher?.isAlive == true ? (session == nil ? 30 : 60) : (session == nil ? 2 : 10)
    }

    private func startWatcherIfNeeded() {
        guard integratesWithSystem, watcher == nil, let path = ADBBridge.locate() else { return }
        let watcher = DeviceWatcher(adbPath: path)
        self.watcher = watcher
        watcher.start { [weak self] in Task { @MainActor in self?.wakeDiscovery() } }
    }

    private func refreshOnce(generation: UInt) async {
        startWatcherIfNeeded()
        setup.accessibility = dependencies.accessibility()
        let context = ADBOperation(timeout: 30)
        do {
            let adb = try dependencies.adb().withOperation(context)
            setup.adbFound = true
            var devices = try await withTaskCancellationHandler {
                try await dependencies.devices(adb)
            } onCancel: { context.cancel() }
            guard !Task.isCancelled, generation == discoveryGeneration else { return }
            var pick = updateDevices(devices)
            if let phone = sessionPhone,
               phone.serial != prefs.preferredSerial || !devices.contains(where: {
                   $0.serial == phone.serial && $0.isReady
               })
            {
                stopSession()
                phase = isEnabled ? .searching : .paused
                status = isEnabled ? StatusText
                    .waiting(selectedPhone?.connectionLabel ?? phone.connectionLabel) : StatusText.paused
            }
            guard session == nil else { return }
            guard isEnabled else { phase = .paused; status = StatusText.paused; return }
            guard !isOperatingWireless || wirelessOperation == .startingSession else { return }
            guard !reconnectSuppressed else {
                phase = .searching
                if wirelessErrorMessage ==
                    nil
                {
                    status = StatusText.disconnected(selectedPhone?.connectionLabel ?? "")
                }
                return
            }
            guard setup.accessibility else { status = StatusText.needsAccessibility; return }
            guard let jar = dependencies.jar() else { status = StatusText.jarMissing; return }
            guard dependencies.now() >= retryNotBefore else { return }
            if case .notReady = pick, let phone = selectedPhone,
               let endpoint = ADBBridge.wirelessEndpoint(serial: phone.serial)
            {
                phase = .searching
                status = StatusText.reconnecting(phone.connectionLabel)
                _ = try await withTaskCancellationHandler {
                    try await dependencies.wireless(adb, .connect(endpoint.ip, endpoint.port)) { _ in }
                } onCancel: { context.cancel() }
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                devices = try await dependencies.devices(adb)
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                pick = updateDevices(devices)
            }
            switch pick {
            case let .ready(device):
                guard isEnabled, session == nil, device.serial == prefs.preferredSerial else { return }
                try startSession(adb: dependencies.adb(), phone: device, jar: jar)
            case let .choose(phones): status = StatusText.choosePhone(count: phones.count)
            case .none: status = StatusText.noDevice
            case let .notReady(phone):
                status = phone.state == "unauthorized" ? StatusText.notAuthorized(phone.state) : StatusText
                    .waiting(phone.connectionLabel)
            }
        } catch {
            guard !Task.isCancelled, generation == discoveryGeneration else { return }
            phase = .searching
            if isEnabled, !reconnectSuppressed {
                recordFailure()
            }
            if case ADBError.adbNotFound = error {
                setup.adbFound = false
            }
            if case ManagedADB.InstallError.incompatibleServer = error {
                status =
                    String(
                        localized: "The existing Android tools are incompatible. Close the other tools and try again."
                    )
                return
            }
            if wirelessOperation == .startingSession {
                failWireless(error); return
            }
            status = selectedPhone.map { StatusText.waiting($0.connectionLabel) } ?? wirelessMessage(for: error)
        }
    }

    @discardableResult
    private func updateDevices(_ devices: [AdbDevice]) -> DevicePick {
        if prefs.preferredSerial == nil, !reconnectSuppressed, !isOperatingWireless,
           case let .ready(phone) = DevicePicker.pick(from: devices)
        {
            setPreference(phone.serial)
        }
        var currentDevices = devices
        var phones = devices.filter(\.isReady)
        if let serial = prefs.preferredSerial {
            let discovered = devices.first { $0.serial == serial }
            let selected = AdbDevice(
                serial: serial, state: discovered?.state ?? "offline",
                model: discovered?.model ?? (rememberedPhone?.serial == serial ? rememberedPhone?.model : nil)
            )
            rememberedPhone = selected
            if let index = currentDevices
                .firstIndex(where: { $0.serial == serial })
            {
                currentDevices[index] = selected
            } else {
                currentDevices.append(selected)
            }
            if let index = phones.firstIndex(where: { $0.serial == serial }) {
                phones[index] = selected
            } else {
                phones.append(selected)
            }
        }
        let pick = DevicePicker.pick(from: currentDevices, preferredSerial: prefs.preferredSerial)
        setup.phones = phones
        switch pick {
        case let .ready(phone): setup.device = .ready(phone.displayName)
        case let .choose(phones): setup.device = .choose(phones.count)
        case let .notReady(phone):
            setup.device = phone
                .state == "unauthorized" ? .notAuthorized(phone.state) :
                .waiting(selectedPhone?.connectionLabel ?? phone.connectionLabel)
        case .none: setup.device = .none
        }
        return pick
    }

    // MARK: - Session

    private func startSession(adb: ADBBridge, phone: AdbDevice, jar: URL) {
        let id = UUID(), generation = selectionGeneration
        let operation = wirelessContext ?? ADBOperation(timeout: 30)
        let next = dependencies.session(adb, phone, jar, settings, operation)
        session = next; sessionID = id; sessionPhone = phone
        stoppingSession = false
        pendingPhone = phone
        phase = .searching
        status = StatusText.connecting(phone.connectionLabel)
        next.onStateChange = { [weak self] state in
            Task { @MainActor in self?.apply(state, phone: phone, id: id, generation: generation) }
        }
        next.start()
    }

    private func apply(_ state: DeviceSession.State, phone: AdbDevice, id: UUID, generation: UInt) {
        guard sessionID == id else { return }
        if case let .ended(reason) = state {
            let wasStopping = stoppingSession
            session = nil; sessionID = nil; sessionPhone = nil
            activePhone = nil; pendingPhone = nil; stoppingSession = false
            phase = isEnabled ? .searching : .paused
            if !wasStopping, reason != .stopped {
                if reason == .captureDenied {
                    setup.accessibility = false
                }
                if wirelessOperation == .startingSession {
                    failWireless(AppConnectionError.sessionStartFailed); return
                }
                recordFailure()
                status = isEnabled ? StatusText.ended(reason) : StatusText.paused
            }
            wakeDiscovery()
            return
        }
        guard !stoppingSession, generation == selectionGeneration, isEnabled,
              phone.serial == prefs.preferredSerial else { return }
        switch state {
        case .starting: break
        case .local, .remote:
            activePhone = phone
            pendingPhone = nil
            resetRetry()
            phase = state == .local ? .connected : .controlling
            status = state == .local ? StatusText.connected(phone.connectionLabel) : StatusText
                .controlling(phone.connectionLabel)
            if wirelessOperation == .startingSession {
                finishWireless()
            }
        case .ended: break
        }
    }

    // MARK: - Wireless

    func switchToWireless(serial: String) {
        guard !isOperatingWireless, selectedPhone?.serial == serial,
              selectedPhone?.isReady == true, selectedPhone?.isWireless == false else { return }
        beginWireless(.switchFromUSB(serial))
    }

    func connectWireless() {
        guard !isOperatingWireless else { return }
        do {
            let input = try wirelessInput()
            beginWireless(.connect(input.ip, input.port))
        } catch { wirelessErrorMessage = wirelessMessage(for: error) }
    }

    func disconnectWireless(serial: String) {
        guard !isOperatingWireless, selectedPhone?.serial == serial, selectedPhone?.isWireless == true else { return }
        beginWireless(.disconnect(serial))
    }

    private func beginWireless(_ request: WirelessRequest) {
        selectionGeneration &+= 1
        cancelWireless(restoreSelection: false)
        resetRetry()
        stopSession()
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        let id = UUID(), context = ADBOperation(timeout: 30)
        wirelessID = id; wirelessContext = context; wirelessOrigin = prefs.preferredSerial
        currentWirelessRequest = request
        failedWirelessRequest = nil
        wirelessErrorMessage = nil
        reconnectSuppressed = true
        switch request {
        case .switchFromUSB: wirelessOperation = .readingAddress
        case .connect: wirelessOperation = .connecting
        case .disconnect: wirelessOperation = .disconnecting
        }
        phase = isEnabled ? .searching : .paused
        status = isEnabled ? StatusText.preparingConnection : StatusText.paused
        wirelessDeadline = Task { [weak self] in
            do { try await self?.dependencies.sleep(30) } catch { return }
            guard let self, wirelessID == id else { return }
            failWireless(ADBError.operationTimedOut)
        }
        wirelessTask = Task { [weak self] in
            guard let self else { return }
            do {
                let adb = try dependencies.adb().withOperation(context)
                let target = try await withTaskCancellationHandler {
                    try await dependencies.wireless(adb, request) { [weak self] stage in
                        Task { @MainActor in
                            guard let model = self, model.wirelessID == id,
                                  model.wirelessOperation != .startingSession else { return }
                            switch stage {
                            case .readingAddress: model.wirelessOperation = .readingAddress
                            case .preparing: model.wirelessOperation = .preparing
                            case .connecting: model.wirelessOperation = .connecting
                            case .checkingDevice: model.wirelessOperation = .checkingDevice
                            }
                        }
                    }
                } onCancel: { context.cancel() }
                guard !Task.isCancelled, wirelessID == id else { return }
                if case .disconnect = request {
                    finishWireless(clearInput: false)
                    reconnectSuppressed = true
                    status = StatusText.disconnected(selectedPhone?.connectionLabel ?? target)
                    wakeDiscovery()
                    return
                }
                wirelessTarget = target
                setPreference(target)
                if case .switchFromUSB = request {
                    rememberedPhone = AdbDevice(serial: target, state: "device", model: rememberedPhone?.model)
                }
                reconnectSuppressed = false
                wirelessOperation = .startingSession
                if !isEnabled {
                    finishWireless(); wakeDiscovery(); return
                }
                wakeDiscovery()
            } catch {
                guard !Task.isCancelled, wirelessID == id else { return }
                failWireless(error)
            }
        }
    }

    func cancelWireless() {
        guard isOperatingWireless else { return }
        selectionGeneration &+= 1
        cancelWireless(restoreSelection: true)
        reconnectSuppressed = true
        stopSession()
        phase = isEnabled ? .searching : .paused
        status = isEnabled ? StatusText.connectionCancelled : StatusText.paused
        wakeDiscovery()
    }

    private func cancelWireless(restoreSelection: Bool) {
        if restoreSelection, wirelessTarget != nil {
            setPreference(wirelessOrigin)
        }
        wirelessID = nil
        wirelessTask?.cancel(); wirelessTask = nil
        wirelessContext?.cancel(); wirelessContext = nil
        wirelessDeadline?.cancel(); wirelessDeadline = nil
        wirelessOperation = .idle
        wirelessOrigin = nil; wirelessTarget = nil; currentWirelessRequest = nil
    }

    private func finishWireless(clearInput: Bool = true) {
        if clearInput {
            wirelessIP = ""; wirelessPort = "5555"
        }
        wirelessID = nil; wirelessContext = nil
        wirelessDeadline?.cancel(); wirelessDeadline = nil
        wirelessTask = nil
        wirelessOperation = .idle
        wirelessOrigin = nil; wirelessTarget = nil; currentWirelessRequest = nil
        failedWirelessRequest = nil
    }

    private func failWireless(_ error: Error) {
        let request = currentWirelessRequest, message = wirelessMessage(for: error)
        cancelWireless(restoreSelection: true)
        failedWirelessRequest = request
        wirelessErrorMessage = message
        reconnectSuppressed = true
        stopSession()
        phase = isEnabled ? .searching : .paused
        status = isEnabled ? message : StatusText.paused
        wakeDiscovery()
    }

    private func wirelessInput() throws -> (ip: String, port: Int) {
        guard let port = Int(wirelessPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ADBError.invalidWirelessPort
        }
        let target = try ADBBridge.wirelessTarget(ip: wirelessIP, port: port)
        return (ADBBridge.wirelessEndpoint(serial: target)!.ip, port)
    }

    private func wirelessMessage(for error: Error) -> String {
        if error is AppConnectionError {
            return String(localized: "The control session could not start. Check the phone, then retry.")
        }
        switch error as? ADBError {
        case .invalidWirelessIP: return String(localized: "Enter a valid IPv4 address, such as 192.168.1.75.")
        case .invalidWirelessPort: return String(localized: "Enter a port between 1 and 65535.")
        case .noWifiIPFound: return String(
                localized: "No Wi-Fi address found. Connect the phone to Wi-Fi, then try again."
            )
        case .adbNotFound: return String(localized: "Android tools (adb) are missing. Install them to connect.")
        case .operationTimedOut, .commandTimedOut:
            return String(localized: "The connection timed out. Check the phone and Wi-Fi, then retry.")
        case .wirelessConnectionFailed, .wirelessDeviceNotReady:
            return String(localized: "The Wi-Fi device is not reachable. Check its address and network, then retry.")
        default: return String(localized: "The Wi-Fi action failed. Check the phone and your network, then try again.")
        }
    }
}

extension AdbDevice {
    var connectionLabel: String {
        "\(displayName) · \(isWireless ? "Wi-Fi" : "USB")"
    }
}
