import AppKit
import DeskBridgeCore
import Observation
import os

@MainActor @Observable
final class AppModel {
    private static let wirelessLog = Logger(subsystem: "com.deskbridge.app", category: "wireless")
    private static let mirrorLog = Logger(subsystem: "com.deskbridge.app", category: "mirror")
    enum Phase: Equatable { case paused, searching, connected, controlling }
    enum WirelessOperation: Equatable {
        case idle, readingAddress, preparing, connecting, checkingDevice, startingSession, disconnecting
    }

    enum MirrorPhase: Equatable {
        case idle, opening, open, focusFailed, closing, notInstalled, failed, disconnected
    }

    private struct MirrorRun {
        let id = UUID()
        let sessionID: UUID
        let process: any MirrorProcess
        var window: (pid: pid_t, executable: URL)?
        var suspensionRequested = false
    }

    struct DetectedPhone: Equatable {
        let serial: String
        let identity: String
    }

    var phase = Phase.searching
    var status = StatusText.searching {
        didSet {
            if oldValue != status {
                connectionErrorDetails = nil
            }
        }
    }

    private(set) var connectionErrorDetails: String?
    var setup = SetupState()
    private(set) var selectedPhoneHasBothTransports = false
    private var selectedPhoneHasWifiTransport = false
    private(set) var selectedPhoneTransports: [AdbDevice] = []
    private(set) var automaticSwitchMessage: String?
    private(set) var detectedDifferentPhone: DetectedPhone?
    private(set) var activePhone: AdbDevice?
    private(set) var pendingPhone: AdbDevice?
    var wirelessIP = ""
    var wirelessPort = "5555"
    private(set) var wirelessOperation = WirelessOperation.idle
    private(set) var isRestartingADB = false
    private(set) var autoWifiInProgress = false
    private(set) var autoWifiStatus: String?
    var wirelessErrorMessage: String?
    private(set) var wirelessErrorDetails: String?
    private(set) var installingADB = false
    private(set) var adbInstallError: String?
    private(set) var checkingUpdates = false
    private(set) var updateMessage: String?
    private(set) var updateURL: URL?
    private(set) var mirrorPhase = MirrorPhase.idle

    var installedVersion: String {
        dependencies.installedVersion()
    }

    var isOperatingWireless: Bool {
        wirelessOperation != .idle || isRestartingADB || autoWifiInProgress
    }

    var canOpenMirror: Bool {
        isEnabled && activePhone != nil && !isOperatingWireless && !installingADB && !isShuttingDown
    }

    var canRestartADB: Bool {
        !isOperatingWireless && wirelessErrorMessage != nil &&
            wirelessErrorDetails?.localizedCaseInsensitiveContains("no route to host") == true
    }

    var selectedPhone: AdbDevice? {
        guard let serial = prefs.preferredSerial else { return nil }
        if rememberedPhone?.serial == serial {
            return rememberedPhone
        }
        return AdbDevice(serial: serial, state: "offline")
    }

    var phoneOptions: [PhoneOption] {
        PhoneOption.make(from: setup.phones, selectedSerial: prefs.preferredSerial,
                         selectedIdentity: prefs.preferredPhysicalID)
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
            if oldValue.autoPrepareWifi != prefs.autoPrepareWifi {
                if !prefs.autoPrepareWifi {
                    cancelAutoWifi()
                }
                autoWifiAttemptSerial = nil
                autoWifiAttempts = 0
                autoWifiRetryAfter = .distantPast
                if prefs.autoPrepareWifi {
                    prefs.autoWifiSuppressedPhysicalID = nil
                    settings.values = prefs
                }
                autoWifiStatus = nil
                wakeDiscovery()
            }
            if !updatingPreference, oldValue.preferredSerial != prefs.preferredSerial {
                prefs.preferredPhysicalID = nil
                selectionChanged()
            }
        }
    }

    var isEnabled: Bool {
        get { prefs.enabled }
        set {
            guard prefs.enabled != newValue else { return }
            prefs.enabled = newValue
            connectionErrorDetails = nil
            selectionGeneration &+= 1
            cancelAutoWifi()
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
    @ObservationIgnored private var sessionADBPath: String?
    @ObservationIgnored private var stoppingSession = false
    @ObservationIgnored private var selectionGeneration: UInt = 0
    @ObservationIgnored private var discoveryGeneration: UInt = 0
    @ObservationIgnored private var backoff = Backoff()
    @ObservationIgnored private var retryNotBefore = Date.distantPast
    @ObservationIgnored private var reconnectSuppressed = false
    @ObservationIgnored private var autoWifiTask: Task<Void, Never>?
    @ObservationIgnored private var autoWifiContext: ADBOperation?
    @ObservationIgnored private var autoWifiAttemptSerial: String?
    @ObservationIgnored private var autoWifiAttempts = 0
    @ObservationIgnored private var autoWifiRetryAfter = Date.distantPast
    @ObservationIgnored private var autoWifiFailureShown = false
    private var rememberedPhone: AdbDevice?
    @ObservationIgnored private var pendingAutomaticSwitch: String?
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
    @ObservationIgnored private var mirror: MirrorRun?
    @ObservationIgnored private var mirrorOpening: Task<Void, Never>?
    @ObservationIgnored private var mirrorDraining: Task<Void, Never>?

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
        closeMirror(resumeSession: false)
        cancelAutoWifi()
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        wirelessTask?.cancel()
        wirelessContext?.cancel()
        wirelessDeadline?.cancel()
        watcher?.stop()
        session?.stop()
    }

    func prepareToQuit() -> Task<Void, Never>? {
        isShuttingDown = true
        guard mirror != nil else { return nil }
        session?.stop()
        return closeMirror(resumeSession: false)
    }

    func installADB(from url: URL) {
        guard !installingADB else { return }
        installingADB = true
        let mirrorClosed = closeMirror()
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
                await mirrorClosed?.value
                guard !isShuttingDown else { return }
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
                updateURL = try await dependencies.checkRelease(installedVersion)
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

    func choosePhone(_ id: PhoneOption.ID) -> DetectedPhone? {
        guard let option = phoneOptions.first(where: { $0.id == id }), !option.isSelected else { return nil }
        if let detected = detectedDifferentPhone, detected.serial == option.phone.serial {
            return detected
        }
        selectDevice(serial: option.phone.serial, physicalID: option.phone.physicalID)
        return nil
    }

    func selectDevice(serial: String?, physicalID: String? = nil) {
        guard let serial else { return }
        if prefs.preferredSerial != serial {
            selectedPhoneTransports = []
            selectedPhoneHasBothTransports = false
            var next = prefs
            next.preferredSerial = serial
            next.preferredPhysicalID = physicalID
            updatingPreference = true
            prefs = next
            updatingPreference = false
        }
        selectionChanged()
    }

    func selectTransport(serial: String) {
        guard !isOperatingWireless, isEnabled, let identity = prefs.preferredPhysicalID,
              serial != prefs.preferredSerial,
              selectedPhoneTransports.count == 2,
              selectedPhoneTransports.allSatisfy({ $0.physicalID == identity }),
              selectedPhoneTransports.contains(where: { $0.serial == prefs.preferredSerial }),
              selectedPhoneTransports.contains(where: { $0.serial == serial && $0.isReady }) else { return }
        setPreference(serial)
        selectionChanged()
    }

    private func setPreference(_ serial: String?) {
        updatingPreference = true
        prefs.preferredSerial = serial
        updatingPreference = false
    }

    private func selectionChanged() {
        connectionErrorDetails = nil
        cancelAutoWifi()
        autoWifiStatus = nil
        automaticSwitchMessage = nil
        pendingAutomaticSwitch = nil
        detectedDifferentPhone = nil
        selectionGeneration &+= 1
        cancelWireless(restoreSelection: false)
        reconnectSuppressed = false
        wirelessErrorMessage = nil
        wirelessErrorDetails = nil
        failedWirelessRequest = nil
        resetRetry()
        stopSession()
        phase = isEnabled ? .searching : .paused
        status = isEnabled ? StatusText.searching : StatusText.paused
        wakeDiscovery()
    }

    func useDetectedPhone(_ phone: DetectedPhone) {
        guard detectedDifferentPhone == phone, prefs.preferredSerial == phone.serial else { return }
        selectionGeneration &+= 1
        prefs.preferredPhysicalID = phone.identity
        detectedDifferentPhone = nil
        reconnectSuppressed = false
        resetRetry()
        stopSession()
        wakeDiscovery()
    }

    @discardableResult
    private func stopSession(mirrorResult: MirrorPhase = .idle) -> Task<Void, Never>? {
        activePhone = nil
        pendingPhone = nil
        if session != nil {
            stoppingSession = true
            session?.stop()
        }
        return closeMirror(result: mirrorResult, resumeSession: false)
    }

    // MARK: - Phone mirror

    func openMirror() {
        if let mirror, let window = mirror.window, mirrorDraining == nil, mirrorOpening == nil {
            let id = mirror.id
            mirrorOpening = Task { [weak self] in
                guard let self else { return }
                let shown = await dependencies.showMirrorWindow(window.pid, window.executable, false)
                guard self.mirror?.id == id, mirrorDraining == nil else { return }
                mirrorPhase = shown == true ? .open : .focusFailed
                mirrorOpening = nil
            }
            return
        }
        guard canOpenMirror, mirror == nil, let phone = activePhone, let sessionID, let session,
              let adbPath = sessionADBPath else { return }
        let run = MirrorRun(sessionID: sessionID, process: dependencies.makeMirror())
        mirror = run
        mirrorPhase = .opening
        Self.mirrorLog.info("Mirror requested on \(phone.isWireless ? "Wi-Fi" : "USB", privacy: .public)")
        mirrorOpening = Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try await dependencies.prepareMirror(adbPath, phone.serial)
                guard canLaunchMirror(run) else { return }
                mirror?.suspensionRequested = true
                let suspended = await withCheckedContinuation { continuation in
                    session.suspendEdgeHandoff { continuation.resume(returning: $0) }
                }
                guard canLaunchMirror(run) else { return }
                guard suspended else { closeMirror(result: .disconnected, resumeSession: false); return }
                Self.mirrorLog.info("Mirror handoff suspended")
                let pid = try await run.process.start(configuration) { [weak self] exit in
                    Task { @MainActor in self?.mirrorExited(run.id, exit) }
                }
                guard canLaunchMirror(run) else { return }
                mirror?.window = (pid, configuration.executableURL)
                Self.mirrorLog.info("Mirror process spawned")
                let shown = await dependencies.showMirrorWindow(pid, configuration.executableURL, true)
                guard canLaunchMirror(run) else { return }
                guard let shown else { closeMirror(result: .failed); return }
                mirrorPhase = shown ? .open : .focusFailed
                Self.mirrorLog.info("Mirror presentation finished, focused: \(shown)")
                mirrorOpening = nil
            } catch {
                guard canLaunchMirror(run) else { return }
                if case ScrcpyError.notInstalled = error {
                    closeMirror(result: .notInstalled)
                } else {
                    closeMirror(result: .failed)
                }
            }
        }
    }

    private func canLaunchMirror(_ run: MirrorRun) -> Bool {
        !Task.isCancelled && mirror?.id == run.id && mirrorDraining == nil && sessionID == run.sessionID &&
            !stoppingSession && !isShuttingDown
    }

    private func mirrorExited(_ id: UUID, _ exit: ScrcpyExit) {
        guard mirror?.id == id, mirrorDraining == nil else { return }
        let result: MirrorPhase = if !exit.wasSignalled, exit.status == 2 {
            .disconnected
        } else if !exit.wasSignalled, exit.status == 0 {
            .idle
        } else {
            .failed
        }
        closeMirror(result: result)
    }

    @discardableResult
    func closeMirror(result: MirrorPhase = .idle, resumeSession: Bool = true) -> Task<Void, Never>? {
        if let mirrorDraining {
            return mirrorDraining
        }
        guard let run = mirror else { return nil }
        mirrorOpening?.cancel()
        mirrorOpening = nil
        mirrorPhase = .closing
        let task = Task { [weak self] in
            await run.process.stop()
            guard let self, mirror?.id == run.id else { return }
            if run.suspensionRequested, resumeSession, isEnabled, !stoppingSession,
               !isShuttingDown, sessionID == run.sessionID
            {
                session?.resumeEdgeHandoff()
            }
            mirror = nil
            mirrorDraining = nil
            mirrorPhase = result
            Self.mirrorLog.info("Mirror closed")
            wakeDiscovery()
        }
        mirrorDraining = task
        return task
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
        guard !isShuttingDown, !isRestartingADB else { return }
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
        var hasDiscoveredPhones = false
        do {
            let adb = try dependencies.adb().withOperation(context)
            setup.adbFound = true
            var devices = try await withTaskCancellationHandler {
                try await dependencies.devices(adb)
            } onCancel: { context.cancel() }
            guard !Task.isCancelled, generation == discoveryGeneration else { return }
            if let phone = sessionPhone, !stoppingSession,
               !devices.contains(where: { $0.serial == phone.serial && $0.isReady })
            {
                stopSession(mirrorResult: .disconnected)
            }
            devices = try await withTaskCancellationHandler {
                try await dependencies.describeDevices(adb, devices)
            } onCancel: { context.cancel() }
            guard !Task.isCancelled, generation == discoveryGeneration else { return }
            var pick = updateDevices(devices)
            hasDiscoveredPhones = true
            if let phone = sessionPhone, !stoppingSession,
               phone.serial != prefs.preferredSerial || selectedPhone?.isReady != true
            {
                stopSession()
                phase = isEnabled ? .searching : .paused
                status = isEnabled ? StatusText
                    .waiting(selectedPhone?.connectionLabel ?? phone.connectionLabel) : StatusText.paused
            }
            if startAutoWifiIfNeeded() {
                return
            }
            guard session == nil, mirror == nil, !autoWifiInProgress else { return }
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
                hasDiscoveredPhones = false
                devices = try await withTaskCancellationHandler {
                    let raw = try await dependencies.devices(adb)
                    return try await dependencies.describeDevices(adb, raw)
                } onCancel: { context.cancel() }
                guard !Task.isCancelled, generation == discoveryGeneration else { return }
                pick = updateDevices(devices)
                hasDiscoveredPhones = true
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
            if !hasDiscoveredPhones {
                setup.phones = []
                detectedDifferentPhone = nil
            }
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
            if case ADBError.adbNotFound = error {
                status = wirelessMessage(for: error)
                connectionErrorDetails = nil
            } else {
                status = StatusText.adbFailure
                connectionErrorDetails = StatusText.diagnostic(String(describing: error))
            }
        }
    }

    @discardableResult
    private func updateDevices(_ devices: [AdbDevice]) -> DevicePick {
        if prefs.preferredSerial == nil, !reconnectSuppressed, !isOperatingWireless,
           case let .ready(phone) = DevicePicker.pick(from: devices)
        {
            setPreference(phone.serial)
        }
        if let serial = prefs.preferredSerial,
           let selected = devices.first(where: { $0.serial == serial && $0.isReady }),
           prefs.preferredPhysicalID == nil, let identity = selected.physicalID
        {
            prefs.preferredPhysicalID = identity
        }
        if let serial = prefs.preferredSerial, let expected = prefs.preferredPhysicalID,
           let detected = devices.first(where: { $0.serial == serial && $0.isReady }),
           let identity = detected.physicalID, identity != expected
        {
            detectedDifferentPhone = DetectedPhone(serial: serial, identity: identity)
        } else {
            detectedDifferentPhone = nil
        }
        let checkedDevices = devices.map { device in
            guard device.serial == prefs.preferredSerial, let identity = prefs.preferredPhysicalID,
                  device.isReady, device.physicalID != identity else { return device }
            return AdbDevice(serial: device.serial, state: "offline", model: device.model)
        }
        if let serial = prefs.preferredSerial, session == nil, isEnabled, !reconnectSuppressed,
           !isOperatingWireless, !checkedDevices.contains(where: { $0.serial == serial && $0.isReady }),
           let alternate = DevicePicker.alternate(for: serial, identity: prefs.preferredPhysicalID, in: devices)
        {
            selectionGeneration &+= 1
            pendingAutomaticSwitch = alternate.serial
            detectedDifferentPhone = nil
            setPreference(alternate.serial)
        }
        var currentDevices = checkedDevices
        if let identity = prefs.preferredPhysicalID {
            let matches = checkedDevices.filter { $0.isReady && $0.physicalID == identity }
            selectedPhoneHasWifiTransport = matches.contains(where: \.isWireless)
            selectedPhoneHasBothTransports = matches.count == 2 && matches.filter(\.isWireless).count == 1 &&
                matches.contains { $0.serial == prefs.preferredSerial }
            if selectedPhoneHasBothTransports {
                autoWifiAttempts = 0
            }
            selectedPhoneTransports = selectedPhoneHasBothTransports
                ? matches.sorted { !$0.isWireless && $1.isWireless } : []
        } else {
            selectedPhoneHasBothTransports = false
            selectedPhoneHasWifiTransport = false
            selectedPhoneTransports = []
        }
        if let serial = prefs.preferredSerial {
            let discovered = checkedDevices.first { $0.serial == serial }
            let remembered = rememberedPhone?.serial == serial ? rememberedPhone : nil
            let selected = AdbDevice(
                serial: serial, state: discovered?.state ?? "offline",
                model: discovered?.model ?? remembered?.model,
                physicalID: discovered?.physicalID,
                friendlyName: discovered?.isReady == true ? discovered?.friendlyName : remembered?.friendlyName
            )
            rememberedPhone = selected
            if let index = currentDevices
                .firstIndex(where: { $0.serial == serial })
            {
                currentDevices[index] = selected
            } else {
                currentDevices.append(selected)
            }
        }
        let pick = DevicePicker.pick(from: currentDevices, preferredSerial: prefs.preferredSerial)
        let available = devices.filter { device in
            device.serial != prefs.preferredSerial || prefs.preferredPhysicalID == nil || device.physicalID != nil
        }
        setup.phones = DevicePicker.phones(from: available, preferredSerial: prefs.preferredSerial)
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
        sessionADBPath = adb.adbPath
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
            sessionADBPath = nil
            closeMirror(result: .disconnected, resumeSession: false)
            activePhone = nil; pendingPhone = nil; stoppingSession = false
            phase = isEnabled ? .searching : .paused
            if !wasStopping, reason != .stopped {
                if reason == .captureDenied {
                    setup.accessibility = dependencies.accessibility()
                    setup.captureFailed = true
                }
                if wirelessOperation == .startingSession {
                    failWireless(AppConnectionError.sessionEnded(reason)); return
                }
                recordFailure()
                status = isEnabled ? StatusText.ended(reason, accessibilityGranted: setup.accessibility) : StatusText
                    .paused
                connectionErrorDetails = StatusText.details(for: reason)
            }
            wakeDiscovery()
            return
        }
        guard !stoppingSession, generation == selectionGeneration, isEnabled,
              phone.serial == prefs.preferredSerial else { return }
        switch state {
        case .starting: break
        case .local, .remote:
            setup.captureFailed = false
            connectionErrorDetails = nil
            activePhone = phone
            pendingPhone = nil
            if state == .local, pendingAutomaticSwitch == phone.serial {
                automaticSwitchMessage = phone.isWireless
                    ? String(localized: "Automatically switched to Wi-Fi")
                    : String(localized: "Automatically switched to USB")
                pendingAutomaticSwitch = nil
            }
            resetRetry()
            phase = state == .local ? .connected : .controlling
            status = state == .local ? StatusText.connected(phone.connectionLabel) : StatusText
                .controlling(phone.connectionLabel)
            if wirelessOperation == .startingSession {
                finishWireless()
            }
            if state == .local, prefs.autoPrepareWifi, !selectedPhoneHasWifiTransport,
               autoWifiAttempts < 3, dependencies.now() >= autoWifiRetryAfter
            {
                wakeDiscovery()
            }
        case .ended: break
        }
    }

    // MARK: - Wireless

    private func cancelAutoWifi() {
        autoWifiContext?.cancel()
        autoWifiTask?.cancel()
        autoWifiStatus = nil
        if autoWifiRetryAfter == .distantFuture {
            autoWifiAttempts = 0
            autoWifiRetryAfter = .distantPast
        }
        clearAutoWifiFailure()
    }

    private func clearAutoWifiFailure() {
        guard autoWifiFailureShown else { return }
        autoWifiFailureShown = false
        wirelessErrorMessage = nil
        wirelessErrorDetails = nil
    }

    func retryAutoWifi() {
        guard prefs.autoPrepareWifi, !autoWifiInProgress else { return }
        autoWifiAttempts = 0
        autoWifiRetryAfter = .distantPast
        autoWifiStatus = nil
        wakeDiscovery()
    }

    private func startAutoWifiIfNeeded() -> Bool {
        guard prefs.autoPrepareWifi, isEnabled, !reconnectSuppressed, mirror == nil,
              !autoWifiInProgress, !isOperatingWireless, phase != .controlling,
              !selectedPhoneHasWifiTransport, let phone = selectedPhone,
              phone.isReady, !phone.isWireless, let identity = prefs.preferredPhysicalID,
              prefs.autoWifiSuppressedPhysicalID != "*",
              prefs.autoWifiSuppressedPhysicalID != identity else { return false }
        if autoWifiAttemptSerial != phone.serial {
            autoWifiAttemptSerial = phone.serial
            autoWifiAttempts = 0
            autoWifiRetryAfter = .distantPast
        }
        guard autoWifiAttempts < 3, dependencies.now() >= autoWifiRetryAfter else { return false }
        autoWifiAttempts += 1
        autoWifiInProgress = true
        clearAutoWifiFailure()
        autoWifiStatus = String(localized: "Preparing Wi-Fi in the background…")
        let context = ADBOperation(timeout: 30)
        autoWifiContext = context
        Self.wirelessLog.info("Automatic Wi-Fi preparation started")
        autoWifiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let adb = try dependencies.adb().withOperation(context)
                let needsRestart = try await withTaskCancellationHandler {
                    try await dependencies.wifiNeedsRestart(adb, phone.serial)
                } onCancel: { context.cancel() }
                try context.checkCancellation()
                if needsRestart {
                    if phase == .controlling {
                        autoWifiAttempts -= 1
                        autoWifiStatus = String(localized: "Wi-Fi will be prepared after control returns to the Mac.")
                        autoWifiInProgress = false
                        autoWifiContext = nil
                        autoWifiTask = nil
                        return
                    }
                    let oldSession = session
                    stopSession()
                    await Task.detached { oldSession?.stopAndWait() }.value
                    try context.checkCancellation()
                }
                _ = try await withTaskCancellationHandler {
                    try await dependencies.prepareWifi(adb, phone.serial, needsRestart)
                } onCancel: { context.cancel() }
                try context.checkCancellation()
                autoWifiStatus = nil
                clearAutoWifiFailure()
                // Wait for discovery to verify the paired transport before allowing another attempt.
                autoWifiAttempts = 3
                Self.wirelessLog.info("Automatic Wi-Fi preparation completed")
            } catch {
                if !Task.isCancelled {
                    autoWifiStatus = String(localized: "Wi-Fi could not be prepared. Check the phone and network.")
                    wirelessErrorMessage = wirelessMessage(for: error)
                    autoWifiFailureShown = true
                    switch error as? ADBError {
                    case let .commandFailed(output), let .wirelessConnectionFailed(output):
                        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        wirelessErrorDetails = detail.isEmpty ? nil : String(detail.prefix(2048))
                    default: wirelessErrorDetails = nil
                    }
                    if wirelessErrorDetails?.localizedCaseInsensitiveContains("no route to host") == true {
                        autoWifiRetryAfter = .distantFuture
                    } else {
                        autoWifiRetryAfter = dependencies.now().addingTimeInterval(autoWifiAttempts == 1 ? 30 : 120)
                    }
                    Self.wirelessLog
                        .error("Automatic Wi-Fi preparation failed: \(String(describing: error), privacy: .private)")
                }
            }
            autoWifiInProgress = false
            autoWifiContext = nil
            autoWifiTask = nil
            wakeDiscovery()
        }
        return true
    }

    func restartADB() {
        guard canRestartADB else { return }
        let retryAutomaticWiFi = autoWifiFailureShown
        isRestartingADB = true
        discoveryGeneration &+= 1
        let oldDiscovery = discoveryTask
        oldDiscovery?.cancel()
        let oldWatcher = watcher
        watcher = nil
        let oldSession = session
        let mirrorClosed = stopSession()
        Self.wirelessLog.info("User requested ADB server restart")
        Task {
            do {
                await mirrorClosed?.value
                guard !isShuttingDown else { return }
                await oldDiscovery?.value
                await Task.detached {
                    oldWatcher?.stopAndWait()
                    oldSession?.stopAndWait()
                }.value
                let adb = try dependencies.adb()
                try await dependencies.restartADB(adb)
                Self.wirelessLog.info("ADB server restart completed")
                if !isShuttingDown {
                    if retryAutomaticWiFi {
                        autoWifiAttempts = 0
                        autoWifiRetryAfter = .distantPast
                        autoWifiStatus = nil
                        clearAutoWifiFailure()
                    }
                    wirelessErrorMessage = nil
                    wirelessErrorDetails = nil
                    failedWirelessRequest = nil
                    reconnectSuppressed = false
                    resetRetry()
                }
            } catch {
                Self.wirelessLog.error("ADB server restart failed: \(String(describing: error), privacy: .private)")
                if !isShuttingDown {
                    wirelessErrorMessage = String(localized: "Could not restart ADB. Check the details, then retry.")
                    wirelessErrorDetails = String(describing: error)
                }
            }
            isRestartingADB = false
            wakeDiscovery()
        }
    }

    func switchToWireless(serial: String) {
        guard !isOperatingWireless, selectedPhone?.serial == serial,
              selectedPhone?.isReady == true, selectedPhone?.isWireless == false else { return }
        prefs.autoWifiSuppressedPhysicalID = nil
        beginWireless(.switchFromUSB(serial))
    }

    func connectWireless() {
        guard !isOperatingWireless else { return }
        do {
            let input = try wirelessInput()
            prefs.autoWifiSuppressedPhysicalID = nil
            beginWireless(.connect(input.ip, input.port))
        } catch { wirelessErrorMessage = wirelessMessage(for: error) }
    }

    func disconnectWireless(serial: String) {
        guard !isOperatingWireless, selectedPhone?.serial == serial, selectedPhone?.isWireless == true else { return }
        prefs.autoWifiSuppressedPhysicalID = prefs.preferredPhysicalID ?? "*"
        beginWireless(.disconnect(serial))
    }

    private func beginWireless(_ request: WirelessRequest) {
        automaticSwitchMessage = nil
        pendingAutomaticSwitch = nil
        selectionGeneration &+= 1
        cancelWireless(restoreSelection: false)
        resetRetry()
        let mirrorClosed = stopSession()
        discoveryGeneration &+= 1
        discoveryTask?.cancel()
        let id = UUID(), context = ADBOperation(timeout: 30)
        wirelessID = id; wirelessContext = context; wirelessOrigin = prefs.preferredSerial
        currentWirelessRequest = request
        failedWirelessRequest = nil
        wirelessErrorMessage = nil
        wirelessErrorDetails = nil
        let action = switch request {
        case .switchFromUSB: "switchFromUSB"
        case .connect: "connect"
        case .disconnect: "disconnect"
        }
        Self.wirelessLog
            .info("Wireless operation started: \(action, privacy: .public); id=\(id.uuidString, privacy: .public)")
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
                await mirrorClosed?.value
                guard !Task.isCancelled, wirelessID == id, !isShuttingDown else { return }
                let adb = try dependencies.adb().withOperation(context)
                let target = try await withTaskCancellationHandler {
                    try await dependencies.wireless(adb, request) { [weak self] stage in
                        Task { @MainActor in
                            guard let model = self, model.wirelessID == id,
                                  model.wirelessOperation != .startingSession else { return }
                            Self.wirelessLog
                                .info(
                                    "Wireless stage: \(String(describing: stage), privacy: .public); id=\(id.uuidString, privacy: .public)"
                                )
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
                Self.wirelessLog.info("ADB wireless preparation succeeded; id=\(id.uuidString, privacy: .public)")
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
                    rememberedPhone = AdbDevice(
                        serial: target, state: "offline", model: rememberedPhone?.model,
                        friendlyName: rememberedPhone?.friendlyName
                    )
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
        let id = wirelessID?.uuidString ?? "unknown"
        Self.wirelessLog
            .info("Wireless operation completed; id=\(id, privacy: .public)")
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
        let detail: String? = switch error {
        case let ADBError.commandFailed(output), let ADBError.wirelessConnectionFailed(output):
            StatusText.diagnostic(output)
        case let AppConnectionError.sessionEnded(reason):
            StatusText.details(for: reason)
        default: nil
        }
        let id = wirelessID?.uuidString ?? "unknown"
        let stage = String(describing: wirelessOperation)
        if detail?.localizedCaseInsensitiveContains("no route to host") == true {
            Self.wirelessLog.error("ADB reported No route to host; id=\(id, privacy: .public)")
        }
        Self.wirelessLog
            .error(
                "Wireless operation failed; id=\(id, privacy: .public); stage=\(stage, privacy: .public); error=\(String(describing: error), privacy: .private)"
            )
        cancelWireless(restoreSelection: true)
        failedWirelessRequest = request
        wirelessErrorMessage = message
        wirelessErrorDetails = detail
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
        if case let AppConnectionError.sessionEnded(reason) = error {
            return StatusText.ended(reason, accessibilityGranted: setup.accessibility)
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
        case let .wirelessConnectionFailed(output) where output.localizedCaseInsensitiveContains("no route to host"),
             let .commandFailed(output) where output.localizedCaseInsensitiveContains("no route to host"):
            return String(
                localized: "ADB cannot reach the phone. Check the network and the Local Network permission of the app that started the ADB server."
            )
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
