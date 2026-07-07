import Foundation
import AppKit
import Combine
import CoreGraphics
import PixlPutCore

/// True when the macOS lock screen / login window is currently presented.
/// We must NOT auto-capture in this state: AX returns only the login
/// window at full-display dimensions, and saving that would overwrite
/// the user's good arrangement with system chrome that, on restore,
/// matches nothing the user actually opened.
private func isScreenLockedNow() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return false
    }
    return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

/// Wires the entire app together: AX client, snapshot engine + store,
/// restorer, debouncers, idle/wake watchers. Owned by the AppDelegate;
/// teardown happens on app terminate.
@MainActor
public final class AppLifecycle {

    public let paths: Paths
    public let permissions: PermissionsBootstrap
    public let axClient: AXClient
    public let snapshotStore: SnapshotStore
    public let snapshotEngine: SnapshotEngine
    public let restorer: Restorer
    public let deepIdentityFetcher: DeepIdentityFetcher
    public let displayEnumerator: DisplayEnumerator
    public let spaceResolver: SpaceResolver
    public let eventLog: EventLog

    public let statusModel: MenuBarStatusModel
    public let licenseValidator: LicenseValidator
    public let thumbnailStore: ThumbnailStore

    private let restorerBackend: AXRestorerBackend
    private let idleDebouncer: Debouncer
    private let wakeDebouncer: Debouncer
    private let idleWatcher: IdleTriggerWatcher
    private let wakeWatcher: WakeTriggerWatcher
    private var spaceChangeObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    /// Holds the currently-scheduled "capture the windows on the Space the
    /// user just settled on" task. Each Space switch cancels any previous
    /// pending capture (so a rapid Spaces flip-through doesn't fire a
    /// capture for every intermediate Space — only for the one the user
    /// actually dwells on).
    private var pendingSpaceCaptureTask: Task<Void, Never>?

    /// True when the bundled Ed25519 public key is still the placeholder —
    /// i.e., licensing isn't actually configured for this build. In that
    /// case `LicenseVerifier.verify` always fails, derived state would be
    /// `hardExpired(.revoked)` or `noLicense`, and gating on
    /// `state.allowsAutoFeatures` would block every feature in a dev
    /// build. Detect that and bypass the gates until a real key is pasted.
    /// Production builds (with a real public key) get the strict gates.
    private var isLicensingUnconfigured: Bool {
        LicenseVerifier.publicKeyB64 == "PLACEHOLDER_REPLACE_WITH_GENERATED_KEY"
    }

    /// Auto-features (capture on idle, restore on wake, Space-switch capture,
    /// restore-on-startup) gated on license state. Once licensing is wired,
    /// expired/revoked/trial-expired states quietly stop auto-doing things;
    /// the user can still manually capture / restore while in `graceOverdue`.
    private var allowsAutoFeatures: Bool {
        if isLicensingUnconfigured { return true }
        return licenseValidator.state.allowsAutoFeatures
    }

    /// Manual features (Capture Now, Restore Now) — slightly more permissive
    /// than auto features: also enabled in `graceOverdue` so a user with a
    /// network outage can still operate the app.
    private var allowsManualFeatures: Bool {
        if isLicensingUnconfigured { return true }
        return licenseValidator.state.allowsManualFeatures
    }

    public init() throws {
        self.paths = Paths()
        try paths.bootstrap()

        self.permissions = PermissionsBootstrap()
        self.axClient = AXClient()
        self.snapshotStore = SnapshotStore(directory: paths.snapshots)
        self.displayEnumerator = DisplayEnumerator()
        self.spaceResolver = SpaceResolver()
        self.deepIdentityFetcher = DeepIdentityFetcher()
        self.eventLog = EventLog()
        self.snapshotEngine = SnapshotEngine(
            axClient: axClient,
            store: snapshotStore,
            displayEnumerator: displayEnumerator,
            spaceResolver: spaceResolver,
            deepIdentityFetcher: deepIdentityFetcher
        )

        let backend = AXRestorerBackend(
            axClient: axClient,
            displayEnumerator: displayEnumerator,
            deepIdentityFetcher: deepIdentityFetcher
        )
        self.restorerBackend = backend
        self.restorer = Restorer(backend: backend, tolerancePoints: 1.0)

        self.statusModel = MenuBarStatusModel()
        self.licenseValidator = LicenseValidator()
        self.thumbnailStore = ThumbnailStore(directory: paths.snapshots)

        let statusModel = self.statusModel
        // Capture validator + public key for the closure-based gates
        // below. These run inside Debouncer closures which can't capture
        // `self` yet (init isn't complete), so we close over the concrete
        // references we need.
        let validatorRef = self.licenseValidator
        let isPlaceholderKey = (LicenseVerifier.publicKeyB64 == "PLACEHOLDER_REPLACE_WITH_GENERATED_KEY")
        let licenseGate: @MainActor @Sendable () -> Bool = {
            if isPlaceholderKey { return true }
            return validatorRef.state.allowsAutoFeatures
        }
        let engine = self.snapshotEngine
        let restorerLocal = self.restorer
        let store = self.snapshotStore
        let enumerator = self.displayEnumerator
        let spaceResolverRef = self.spaceResolver
        let logger = LoggerRegistry.app

        // 1.0s window — short enough that auto-capture fires BEFORE the
        // display dims (screen-saver fade-in is ~2-3s). The original 5s
        // value caused the capture to fire after AX had already collapsed,
        // producing snapshots with 1 AX entry and 100+ junk CG entries
        // that overwrote the previous good snapshot.
        self.idleDebouncer = Debouncer(window: 1.0) {
            Task { @MainActor in
                // Hard gate: do not auto-capture when the screen is
                // locked. In that state AX returns only the system
                // login window at full-display dimensions, and saving
                // that snapshot poisons every subsequent restore.
                if isScreenLockedNow() {
                    DiagnosticLog.write("capture",
                        "SKIP: screen is locked — declining auto-capture trigger")
                    logger.log(.info, "Skipped auto-capture: screen is locked")
                    return
                }
                guard licenseGate() else {
                    DiagnosticLog.write("capture",
                        "SKIP auto-capture: license state blocks auto features")
                    return
                }
                do {
                    let snap = try await engine.capture(
                        trigger: .screensaverStart,
                        useDeepIdentity: statusModel.deepIdentityEnabled
                    )
                    statusModel.lastCapture = Date()
                    statusModel.lastCaptureWindowCount = snap.windows.count
                    logger.log(.info, "Captured \(snap.windows.count) windows (idle trigger)")
                } catch {
                    logger.log(.error, "Capture failed: \(error)")
                }
            }
        }

        self.wakeDebouncer = Debouncer(window: 5.0) {
            Task { @MainActor in
                // Same gate as auto-capture: if the lock screen is still
                // up, AX is enumerating loginwindow with bogus frames and
                // moves return AX errors. The per-entry try/catch survives
                // it, but it's a waste of cycles and clutters the log.
                if isScreenLockedNow() {
                    DiagnosticLog.write("restore",
                        "SKIP wake-restore: screen is locked, will rely on Space-switch restore after unlock")
                    return
                }
                guard licenseGate() else {
                    DiagnosticLog.write("restore",
                        "SKIP wake-restore: license state blocks auto features")
                    return
                }
                do {
                    // Find a snapshot matching the active display configuration.
                    let configID = enumerator.configurationID()
                    guard let snapshot = try store.loadLatest(forConfigurationID: configID) else {
                        logger.log(.info, "Wake trigger fired but no snapshot exists for active config \(configID)")
                        return
                    }
                    let activeIDs = Set(enumerator.enumerate().map(\.fingerprint.id))
                    // Scope to the active Space. Without this, the restore
                    // tries to PAIR every entry across all 6 Spaces against
                    // the live AX enumeration (which only sees the active
                    // Space's windows), causing identity-name collisions
                    // — e.g. a snapshot entry for "Brave/<URL>" on Space 0
                    // can pair with the same URL's live window currently
                    // on Space 5, and apply Space-0's frame. Lazy Space-
                    // switch restores cover the other Spaces as the user
                    // visits them.
                    let activeSpace = spaceResolverRef.activeSpaceIndex()
                    let report = try await restorerLocal.apply(
                        snapshot,
                        activeDisplayFingerprintIDs: activeIDs,
                        currentDisplayBoundsByID: Dictionary(
                            enumerator.enumerate().map { ($0.fingerprint.id, $0.bounds) },
                            uniquingKeysWith: { first, _ in first }),
                        onlySpaceIndex: activeSpace
                    )
                    statusModel.lastRestore = Date()
                    statusModel.lastRestoreMoved = report.moved
                    statusModel.lastRestoreDisplaced = report.displacedNoMatchingDisplay
                    logger.log(.info,
                        "Restored: moved=\(report.moved) skipped=\(report.skippedAlreadyAtFrame) missing=\(report.skippedMissingWindow) displaced=\(report.displacedNoMatchingDisplay)"
                    )
                } catch {
                    logger.log(.error, "Restore failed: \(error)")
                }
            }
        }

        self.idleWatcher = IdleTriggerWatcher(debouncer: idleDebouncer, eventLog: eventLog)
        self.wakeWatcher = WakeTriggerWatcher(debouncer: wakeDebouncer, eventLog: eventLog)
    }

    public func start() {
        // Make sure the diagnostic log file exists immediately so the user
        // can `tail -f` it before the first capture has happened.
        DiagnosticLog.bootstrap()
        DiagnosticLog.write("startup", "PixlPut starting; build at \(Bundle.main.bundleURL.path)")

        // Bootstrap the snapshot store now (not lazily on first save) —
        // this runs any pending format migrations (e.g. legacy .json →
        // .plist) before the first read/write attempt.
        do {
            try snapshotStore.bootstrap()
        } catch {
            DiagnosticLog.write("startup", "snapshotStore.bootstrap failed: \(error)")
        }

        // CRITICAL: sync the real permission state into the status model
        // synchronously, before any menu / window observes it. The 3s
        // polling timer in AppDelegate only catches subsequent CHANGES;
        // without this initial sync, the menu briefly reads `false` for
        // both `hasAccessibilityPermission` and `isSpaceAware` even when
        // both are actually true at launch.
        refreshPermissionState()
        LoggerRegistry.app.log(.info,
            "AppLifecycle starting; AX permission = \(statusModel.hasAccessibilityPermission), Spaces aware = \(statusModel.isSpaceAware)")
        idleWatcher.start()
        wakeWatcher.start()

        // Keep the restorer backend in sync with the deepIdentityEnabled toggle.
        statusModel.$deepIdentityEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.restorerBackend.useDeepIdentity = enabled
            }
            .store(in: &cancellables)

        // Re-check AX whenever the app comes back to the foreground —
        // this catches the user returning from System Settings after
        // toggling Accessibility ON or OFF.
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPermissionState() }
            .store(in: &cancellables)

        // Treat app launch as a synthetic wake event. Without this, the
        // lazy Space-switch restore predicate fails (`lastWakeAt == nil`
        // → predicate returns false → no Space-switch restores ever
        // fire). The common scenario: user puts machine to sleep with
        // PixlPut quit, wakes, launches PixlPut, switches to Space N — we
        // need that Space-switch to restore the Space-N layout. Setting
        // lastWakeAt here makes "since the last time PixlPut was alive"
        // count as a wake for predicate purposes.
        eventLog.recordWake(at: Date())

        // Phase A — seed EventLog with the Space active at launch so
        // restore-on-startup's Space handles the active one, and the
        // lazy Space-switch restore covers the others as the user visits.
        let initialSpace = spaceResolver.activeSpaceIndex()
        eventLog.recordSpaceVisit(spaceIndex: initialSpace)

        // Licensing: start the validator. It refreshes local state from
        // Keychain, kicks off a /validate phone-home if a license is
        // stored, and runs a periodic re-validation loop. State changes
        // are exposed via `licenseValidator.statePublisher` — the paywall
        // window subscribes to that, and feature gates check
        // `state.allowsAutoFeatures` / `allowsManualFeatures`. We do NOT
        // gate features yet (paywall UI not wired) — the validator runs
        // observably while the rest of the integration lands.
        licenseValidator.start()
        // First-launch convenience: if no license is stored AND no trial
        // has been started, auto-request a trial. The server returns a
        // signed 14-day window. If offline, this silently fails and the
        // app stays in `noLicense` until the next launch.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if LicenseKeychain.loadSignedLicense() == nil
                && LicenseKeychain.loadTrialExpiresAt() == nil {
                _ = try? await self.licenseValidator.startTrial()
            }
        }

        // Phase A — subscribe to active-Space changes. Each change updates
        // `eventLog.spaceLastVisitedAt[newSpace]`. Phase D will hook in
        // here to dispatch the lazy restore when appropriate.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let newSpace = self.spaceResolver.activeSpaceIndex()
                self.handleSpaceChange(to: newSpace)
            }
        }

        // Restore-on-startup: apply the latest snapshot for the current
        // display configuration once the app and AX are ready. Useful
        // after the user kills + relaunches PixlPut, or after a fresh
        // build replaces the binary — they shouldn't have to manually
        // click "Restore Now" to get back to their saved layout. Skip
        // when the screen is locked (no point moving windows the user
        // can't see).
        let restorerLocalStart = self.restorer
        let storeStart = self.snapshotStore
        let enumeratorStart = self.displayEnumerator
        let statusModelStart = self.statusModel
        Task { @MainActor in
            // Brief delay lets AX settle and any auto-launched apps
            // (login items) finish creating their windows.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if isScreenLockedNow() {
                DiagnosticLog.write("startup",
                    "SKIP restore-on-startup: screen is locked")
                return
            }
            guard self.allowsAutoFeatures else {
                DiagnosticLog.write("startup",
                    "SKIP restore-on-startup: license state blocks auto features")
                return
            }
            let configID = enumeratorStart.configurationID()
            guard let snapshot = try? storeStart.loadLatest(forConfigurationID: configID) else {
                DiagnosticLog.write("startup",
                    "No snapshot to restore on startup for config \(configID)")
                return
            }
            let activeIDs = Set(enumeratorStart.enumerate().map(\.fingerprint.id))
            // Restrict to the active Space — AX can only see the active
            // Space's windows anyway, so trying to PAIR off-Space entries
            // just produces noise. Other Spaces restore lazily via
            // handleSpaceChange when the user visits them.
            let activeSpace = self.spaceResolver.activeSpaceIndex()
            do {
                let report = try await restorerLocalStart.apply(
                    snapshot,
                    activeDisplayFingerprintIDs: activeIDs,
                    currentDisplayBoundsByID: Dictionary(
                        enumeratorStart.enumerate().map { ($0.fingerprint.id, $0.bounds) },
                        uniquingKeysWith: { first, _ in first }),
                    onlySpaceIndex: activeSpace
                )
                statusModelStart.lastRestore = Date()
                statusModelStart.lastRestoreMoved = report.moved
                statusModelStart.lastRestoreSkipped = report.skippedMissingWindow + report.skippedAlreadyAtFrame
                statusModelStart.lastRestoreDisplaced = report.displacedNoMatchingDisplay
                DiagnosticLog.write("startup",
                    "restore-on-startup done: moved=\(report.moved) skipped=\(report.skippedMissingWindow + report.skippedAlreadyAtFrame)")
            } catch {
                DiagnosticLog.write("startup",
                    "restore-on-startup failed: \(error)")
            }
        }
    }

    /// Phase D — when the active Space changes, decide whether to dispatch
    /// a restore for the newly-active Space. The predicate
    /// `EventLog.shouldRestoreOnSwitch` is true when the user hasn't
    /// visited this Space since the last wake event — i.e. this is the
    /// FIRST time they're seeing this Space since the machine resumed,
    /// and the snapshot for it predates any rearrangement they've made.
    ///
    /// A 1.5s dispatch delay lets both the Mission Control transition
    /// animation AND any in-flight display reconfiguration (post-wake
    /// external-monitor handshake) settle before windows move. The
    /// shorter 250ms originally chosen here was fine for cold Space
    /// switches but caused post-wake restores to issue moves while the
    /// external display's virtual coordinate region was still
    /// re-establishing — macOS silently clamped the target frame to the
    /// main display and the window appeared not to move.
    private func handleSpaceChange(to spaceIndex: Int) {
        let shouldRestore = statusModel.restoreOnSpaceSwitch
            && eventLog.shouldRestoreOnSwitch(toSpaceIndex: spaceIndex)
        let previouslyVisited = eventLog.lastVisited(spaceIndex: spaceIndex)
        eventLog.recordSpaceVisit(spaceIndex: spaceIndex)
        LoggerRegistry.app.log(.info,
            "Space changed to index=\(spaceIndex); previously visited=\(previouslyVisited?.description ?? "never"); will-restore=\(shouldRestore)")

        // License gate. If the state blocks auto features (expired/revoked
        // license, trial expired), skip both the Space-switch capture AND
        // the Space-switch restore — the only path that still runs is
        // manual Capture/Restore (and only those if `allowsManualFeatures`).
        guard allowsAutoFeatures else {
            DiagnosticLog.write("capture",
                "SKIP Space-switch capture+restore for space=\(spaceIndex): license state blocks auto features")
            return
        }

        // Always schedule an auto-capture for the newly-active Space.
        // This is the workaround for "macOS AX is single-Space" — every
        // time the user naturally visits a Space, we capture its layout,
        // so the snapshot accumulates per-Space data without the user
        // having to think about it. Debounced via a Task that we cancel
        // and replace on each Space switch — rapid flip-throughs only
        // fire one capture, for the Space the user dwells on.
        scheduleSpaceSwitchCapture(for: spaceIndex)

        guard shouldRestore else { return }

        let configID = displayEnumerator.configurationID()
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Retry-with-back-off instead of a flat 1.5s wait. First
            // attempt fires after just 300ms — most Spaces animations
            // are <250ms and that's the snappiest the user perceives.
            // If many entries SKIP-MISSING (AX hasn't enumerated the
            // new Space's windows yet), retry after 500ms, then 1000ms.
            // Caps total wait at ~1.8s in the worst case while landing
            // the first moves in 300ms when AX is ready immediately.
            let delaysMs: [UInt64] = [300, 500, 1000]
            var attempt = 0
            for delayMs in delaysMs {
                attempt += 1
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                if isScreenLockedNow() {
                    DiagnosticLog.write("restore",
                        "SKIP Space-switch restore for space=\(spaceIndex): screen is locked")
                    return
                }
                do {
                    guard let snapshot = try self.snapshotStore.loadLatest(forConfigurationID: configID) else {
                        LoggerRegistry.app.log(.info,
                            "Space-switch restore skipped: no snapshot for config \(configID)")
                        return
                    }
                    let activeIDs = Set(self.displayEnumerator.enumerate().map(\.fingerprint.id))
                    let report = try await self.restorer.apply(
                        snapshot,
                        activeDisplayFingerprintIDs: activeIDs,
                        currentDisplayBoundsByID: self.currentDisplayBoundsByID(),
                        onlySpaceIndex: spaceIndex
                    )
                    self.statusModel.lastRestore = Date()
                    self.statusModel.lastRestoreMoved = report.moved
                    self.statusModel.lastRestoreSkipped = report.skippedMissingWindow + report.skippedAlreadyAtFrame
                    self.statusModel.lastRestoreDisplaced = report.displacedNoMatchingDisplay
                    DiagnosticLog.write("restore",
                        "Space-switch restore (attempt \(attempt)/\(delaysMs.count)): space=\(spaceIndex) moved=\(report.moved) skippedAlreadyAtFrame=\(report.skippedAlreadyAtFrame) skippedMissingWindow=\(report.skippedMissingWindow)")
                    // Stop retrying as soon as one of these is true:
                    //  - At least one window was actually moved (AX is ready, work happened).
                    //  - Everything was already at the target frame (idempotent — nothing to do).
                    //  - There were zero matching entries for this Space anyway.
                    let satisfied = report.moved > 0
                        || (report.skippedAlreadyAtFrame > 0 && report.skippedMissingWindow == 0)
                        || (report.moved == 0 && report.skippedAlreadyAtFrame == 0 && report.skippedMissingWindow == 0)
                    if satisfied { return }
                    // Otherwise: SKIP-MISSING dominated — AX hadn't
                    // enumerated the new Space yet. Loop will retry.
                } catch {
                    DiagnosticLog.write("restore",
                        "Space-switch restore attempt \(attempt) failed: \(error)")
                }
            }
        }
    }

    /// Cancel any previously-pending Space-switch capture and schedule a
    /// new one for `spaceIndex` after a dwell delay. The delay serves two
    /// purposes: (1) ignore rapid Spaces flip-throughs — only the Space
    /// the user lands on triggers a capture; (2) let any concurrent
    /// Space-switch restore complete first, so we capture the restored
    /// layout, not the transitional one.
    private func scheduleSpaceSwitchCapture(for spaceIndex: Int) {
        pendingSpaceCaptureTask?.cancel()
        let engine = self.snapshotEngine
        let statusModel = self.statusModel
        let thumbnailStore = self.thumbnailStore
        pendingSpaceCaptureTask = Task { @MainActor in
            // 5s dwell — comfortably past the 1.5s restore-on-switch
            // delay so we capture the post-restore layout when a restore
            // is happening, and not too long to feel laggy when it isn't.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            if isScreenLockedNow() {
                DiagnosticLog.write("capture",
                    "SKIP space-switch auto-capture for space=\(spaceIndex): screen is locked")
                return
            }
            do {
                let snap = try await engine.capture(
                    trigger: .spaceSwitch,
                    useDeepIdentity: statusModel.deepIdentityEnabled
                )
                statusModel.lastCapture = Date()
                statusModel.lastCaptureWindowCount = snap.windows.count
                DiagnosticLog.write("capture",
                    "space-switch auto-capture done: space=\(spaceIndex) windows=\(snap.windows.count)")

                // Per-Space thumbnail. Strictly opt-in; gated on both the
                // user's consent toggle AND the live Screen Recording
                // permission state. Failure (e.g. permission revoked at
                // OS level) is logged but never blocks the snapshot save.
                //
                // Rotate thumbnails in lockstep with the snapshot we just
                // saved: snapshot was rotated current→1 inside store.save,
                // so the matching thumbnails follow now. preserveRotated
                // controls whether to keep them as history or drop them.
                if statusModel.enableSpaceScreenshots {
                    thumbnailStore.rotateForward(
                        configID: snap.displayConfigurationID,
                        historyLimit: snapshotStore.historyLimit,
                        preserveRotated: statusModel.enableSnapshotHistoryThumbnails
                    )
                    if let jpeg = await ScreenshotCapturer.captureActiveDisplay() {
                        do {
                            try thumbnailStore.save(
                                jpeg,
                                configID: snap.displayConfigurationID,
                                spaceIndex: spaceIndex
                            )
                            DiagnosticLog.write("screenshot",
                                "thumbnail saved: space=\(spaceIndex) bytes=\(jpeg.count) history=\(statusModel.enableSnapshotHistoryThumbnails)")
                        } catch {
                            DiagnosticLog.write("screenshot",
                                "thumbnail save failed for space=\(spaceIndex): \(error)")
                        }
                    }
                }
            } catch {
                DiagnosticLog.write("capture",
                    "space-switch auto-capture failed for space=\(spaceIndex): \(error)")
            }
        }
    }

    /// Reconcile the status model with the actual permission / system
    /// state. Safe to call from any thread that can hop to MainActor —
    /// AppLifecycle is `@MainActor`-isolated so direct calls are fine.
    public func refreshPermissionState() {
        let granted = permissions.currentState() == .accessibilityGranted
        if statusModel.hasAccessibilityPermission != granted {
            statusModel.hasAccessibilityPermission = granted
        }
        let spaceAware = spaceResolver.isSpaceAware
        if statusModel.isSpaceAware != spaceAware {
            statusModel.isSpaceAware = spaceAware
        }
    }

    public func stop() {
        idleWatcher.stop()
        wakeWatcher.stop()
        licenseValidator.stop()
        pendingSpaceCaptureTask?.cancel()
        pendingSpaceCaptureTask = nil
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceChangeObserver = nil
        }
    }

    /// Manually capture (user invoked from menu bar).
    public func captureNow() {
        Task { @MainActor in
            guard allowsManualFeatures else {
                statusModel.lastError = "License required. Open menu bar → License… to activate or start a trial."
                DiagnosticLog.write("capture", "BLOCKED manual capture: license state = \(licenseValidator.state)")
                return
            }
            do {
                let snap = try await snapshotEngine.capture(
                    trigger: .manual,
                    useDeepIdentity: statusModel.deepIdentityEnabled
                )
                statusModel.lastCapture = Date()
                statusModel.lastCaptureWindowCount = snap.windows.count
                statusModel.lastError = (snap.windows.count == 0)
                    ? "Captured 0 windows — is Accessibility permission really granted? Check System Settings → Privacy & Security → Accessibility."
                    : nil
                LoggerRegistry.app.log(.info, "Manual capture: \(snap.windows.count) windows")
            } catch {
                let msg = Self.describe(error: error, operation: "capture")
                statusModel.lastError = msg
                LoggerRegistry.app.log(.error, "Manual capture failed: \(error)")
            }
        }
    }

    /// Manually restore the most recent snapshot for the current config.
    /// Current display origins keyed by fingerprint id — passed to
    /// `Restorer.apply` so saved window frames get re-anchored to where each
    /// monitor sits now (fixes windows landing off-screen after a monitor is
    /// added/removed/rearranged).
    private func currentDisplayBoundsByID() -> [String: CGRectCodable] {
        Dictionary(
            displayEnumerator.enumerate().map { ($0.fingerprint.id, $0.bounds) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func restoreNow() {
        Task { @MainActor in
            guard allowsManualFeatures else {
                statusModel.lastError = "License required. Open menu bar → License… to activate or start a trial."
                DiagnosticLog.write("restore", "BLOCKED manual restore: license state = \(licenseValidator.state)")
                return
            }
            do {
                let configID = displayEnumerator.configurationID()
                guard let snap = try snapshotStore.loadLatest(forConfigurationID: configID) else {
                    statusModel.lastError = "No snapshot exists for the current display configuration (\(configID)). Capture first."
                    LoggerRegistry.app.log(.info, "Manual restore: no snapshot for config \(configID)")
                    return
                }
                // Re-arm the per-Space lazy restore: a manual "Restore now"
                // means "put my layout back", so every Space the user then
                // switches to should restore (AX can only touch the active
                // Space, so the others must happen on visit). Without this,
                // `shouldRestoreOnSwitch` stays false for already-visited
                // Spaces and only the active Space ever restores.
                eventLog.recordWake()
                let activeIDs = Set(displayEnumerator.enumerate().map(\.fingerprint.id))
                let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: activeIDs, currentDisplayBoundsByID: currentDisplayBoundsByID())
                statusModel.lastRestore = Date()
                statusModel.lastRestoreMoved = report.moved
                statusModel.lastRestoreSkipped = report.skippedMissingWindow + report.skippedAlreadyAtFrame
                statusModel.lastRestoreDisplaced = report.displacedNoMatchingDisplay
                if report.moved == 0 && snap.windows.count > 0 {
                    statusModel.lastError = "Restore moved 0 of \(snap.windows.count) windows. "
                        + "\(report.skippedMissingWindow) windows from the snapshot weren't found, "
                        + "\(report.skippedAlreadyAtFrame) were already at the recorded frame. "
                        + "Open Settings → Snapshots to inspect."
                } else {
                    statusModel.lastError = nil
                }
                LoggerRegistry.app.log(.info,
                    "Manual restore: moved=\(report.moved) skipped=\(report.skippedAlreadyAtFrame) missing=\(report.skippedMissingWindow) displaced=\(report.displacedNoMatchingDisplay)"
                )
            } catch {
                let msg = Self.describe(error: error, operation: "restore")
                statusModel.lastError = msg
                LoggerRegistry.app.log(.error, "Manual restore failed: \(error)")
            }
        }
    }

    // MARK: Master snapshot

    /// Capture the current layout and store it as the "master" — a
    /// separate, never-rotated snapshot the user can restore to on
    /// demand. Replaces any existing master.
    public func saveAsMaster() {
        Task { @MainActor in
            guard allowsManualFeatures else {
                statusModel.lastError = "License required. Open menu bar → License…"
                return
            }
            do {
                // Use the normal capture path so master inherits any
                // cross-Space data already merged into the latest snapshot.
                let snap = try await snapshotEngine.capture(
                    trigger: .manual,
                    useDeepIdentity: statusModel.deepIdentityEnabled
                )
                try snapshotStore.saveMaster(snap)
                statusModel.lastError = nil
                DiagnosticLog.write("master",
                    "saved master: configID=\(snap.displayConfigurationID) windows=\(snap.windows.count)")
                LoggerRegistry.app.log(.info, "Master snapshot saved: \(snap.windows.count) windows")
            } catch {
                let msg = Self.describe(error: error, operation: "saveMaster")
                statusModel.lastError = msg
                LoggerRegistry.app.log(.error, "Save Master failed: \(error)")
            }
        }
    }

    /// Apply the master snapshot to the current OS state. Same machinery
    /// as `restoreNow` but loads `.master.plist` instead of `.plist`.
    public func restoreMaster() {
        Task { @MainActor in
            guard allowsManualFeatures else {
                statusModel.lastError = "License required. Open menu bar → License…"
                return
            }
            do {
                let configID = displayEnumerator.configurationID()
                guard let snap = try snapshotStore.loadMaster(forConfigurationID: configID) else {
                    statusModel.lastError = "No master snapshot saved for this display configuration."
                    return
                }
                let activeIDs = Set(displayEnumerator.enumerate().map(\.fingerprint.id))
                let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: activeIDs, currentDisplayBoundsByID: currentDisplayBoundsByID())
                statusModel.lastRestore = Date()
                statusModel.lastRestoreMoved = report.moved
                statusModel.lastRestoreSkipped = report.skippedMissingWindow + report.skippedAlreadyAtFrame
                statusModel.lastRestoreDisplaced = report.displacedNoMatchingDisplay
                statusModel.lastError = nil
                DiagnosticLog.write("master",
                    "restored master: moved=\(report.moved) skippedMissing=\(report.skippedMissingWindow)")
            } catch {
                let msg = Self.describe(error: error, operation: "restoreMaster")
                statusModel.lastError = msg
                LoggerRegistry.app.log(.error, "Restore Master failed: \(error)")
            }
        }
    }

    /// Apply a specific historical slot (0 = current, 1..N = older).
    /// Used by the Restore Picker UI.
    public func restoreFromSlot(_ slot: Int) {
        Task { @MainActor in
            guard allowsManualFeatures else {
                statusModel.lastError = "License required. Open menu bar → License…"
                return
            }
            do {
                let configID = displayEnumerator.configurationID()
                guard let snap = try snapshotStore.load(forConfigurationID: configID, slot: slot) else {
                    statusModel.lastError = "Snapshot slot \(slot) is empty."
                    return
                }
                let activeIDs = Set(displayEnumerator.enumerate().map(\.fingerprint.id))
                let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: activeIDs, currentDisplayBoundsByID: currentDisplayBoundsByID())
                statusModel.lastRestore = Date()
                statusModel.lastRestoreMoved = report.moved
                statusModel.lastRestoreSkipped = report.skippedMissingWindow + report.skippedAlreadyAtFrame
                statusModel.lastError = nil
                DiagnosticLog.write("restore",
                    "history slot=\(slot) applied: moved=\(report.moved)")
            } catch {
                let msg = Self.describe(error: error, operation: "restoreFromSlot")
                statusModel.lastError = msg
            }
        }
    }

    /// User-facing error string for capture / restore failures.
    private static func describe(error: Error, operation: String) -> String {
        if let axError = error as? AXClient.AXError {
            switch axError {
            case .permissionDenied:
                return "Accessibility permission is missing. Grant it in System Settings → Privacy & Security → Accessibility, then try \(operation) again."
            case .windowGone:
                return "A window disappeared during \(operation)."
            case .attributeUnavailable(let attr):
                return "AX call failed during \(operation): \(attr)."
            case .operationCancelled:
                return "\(operation.capitalized) was cancelled."
            }
        }
        return "\(operation.capitalized) failed: \(error.localizedDescription)"
    }

    public func togglePauseAutoCapture() {
        statusModel.isAutoCapturePaused.toggle()
        idleWatcher.setPaused(statusModel.isAutoCapturePaused)
    }
}

/// AX-backed RestorerBackend bridging the AX client + display enumerator
/// + deep-identity fetcher into the abstract `RestorerBackend` protocol
/// from PixlPutCore.
///
/// The identity computation here MUST match the one in `SnapshotEngine.capture`
/// — otherwise a snapshot written by capture won't match the live windows
/// at restore. They share the same deep-identity fetch + resolver, AND the
/// same `useDeepIdentity` flag from the status model.
public final class AXRestorerBackend: RestorerBackend, @unchecked Sendable {
    let axClient: AXClient
    let displayEnumerator: DisplayEnumerator
    let deepIdentityFetcher: DeepIdentityFetcher
    /// Mirrors `MenuBarStatusModel.deepIdentityEnabled`. AppLifecycle
    /// keeps this in sync via Combine; updates are coalesced on the main
    /// thread. Mutated from `@MainActor` only.
    var useDeepIdentity: Bool

    public init(
        axClient: AXClient,
        displayEnumerator: DisplayEnumerator,
        deepIdentityFetcher: DeepIdentityFetcher = DeepIdentityFetcher(),
        useDeepIdentity: Bool = false
    ) {
        self.axClient = axClient
        self.displayEnumerator = displayEnumerator
        self.deepIdentityFetcher = deepIdentityFetcher
        self.useDeepIdentity = useDeepIdentity
    }

    /// Composite key matching Restorer.MatchKey + ordinal — uniquely
    /// addresses any AX window even when bundle+identity collide.
    private struct AXKey: Hashable {
        let bundleID: String
        let identity: WindowIdentity
        let ordinalInApp: Int
    }

    /// Compute identities for all currently-visible windows using the same
    /// pipeline as `SnapshotEngine.capture`. Returns a `LiveWindow` list +
    /// a sidecar map keyed by `(bundleID, identity, ordinalInApp)` so the
    /// move/fullscreen handlers can recover the exact AX element without
    /// re-enumerating and without falling victim to the identity-collision
    /// bug that caused windows to "disappear" on restore.
    private func resolveLiveWindows() async throws -> ([LiveWindow], [AXKey: AXWindow]) {
        let axWindows = try await axClient.enumerateWindows()
        let displays = displayEnumerator.enumerate()
        let resolver = WindowIdentityResolver.defaultV1()

        var deepByBundle: [String: [Int: WindowIdentity]] = [:]
        if useDeepIdentity {
            let scriptedBundleIDs = Set(axWindows.map(\.bundleID))
                .filter { DeepIdentityFetcher.isScripted(bundleID: $0) }
            for bundleID in scriptedBundleIDs {
                if let result = await deepIdentityFetcher.identitiesForApp(bundleID: bundleID) {
                    deepByBundle[bundleID] = result
                }
            }
        }

        var live: [LiveWindow] = []
        var byKey: [AXKey: AXWindow] = [:]
        for axw in axWindows {
            // AX attributes already pre-fetched on the AX queue.
            guard let frame = axw.frame else { continue }
            let displayFingerprintID = displays
                .max(by: {
                    intersectionArea($0.bounds, frame) < intersectionArea($1.bounds, frame)
                })?.fingerprint.id ?? (displays.first?.fingerprint.id ?? "")
            let appProviderIdentity = deepByBundle[axw.bundleID]?[axw.indexInApp]
            let identity = resolver.resolve(WindowSignal(
                bundleID: axw.bundleID,
                title: axw.title,
                documentURL: axw.documentURL,
                appProviderIdentity: appProviderIdentity,
                creationOrdinal: axw.creationOrdinal
            ))
            live.append(LiveWindow(
                bundleID: axw.bundleID,
                identity: identity,
                ordinalInApp: axw.creationOrdinal,
                currentFrame: frame,
                currentDisplayFingerprintID: displayFingerprintID,
                isFullscreen: axw.isFullscreen
            ))
            byKey[AXKey(
                bundleID: axw.bundleID,
                identity: identity,
                ordinalInApp: axw.creationOrdinal
            )] = axw
        }
        return (live, byKey)
    }

    private func keyFor(_ window: LiveWindow) -> AXKey {
        AXKey(
            bundleID: window.bundleID,
            identity: window.identity,
            ordinalInApp: window.ordinalInApp
        )
    }

    public func enumerateLiveWindows() async throws -> [LiveWindow] {
        let (live, _) = try await resolveLiveWindows()
        return live
    }

    public func move(window: LiveWindow, to frame: CGRectCodable) async throws -> Bool {
        let (_, byKey) = try await resolveLiveWindows()
        guard let axWindow = byKey[keyFor(window)] else { return false }
        return try await axClient.move(axWindow, to: frame)
    }

    public func setFullscreen(window: LiveWindow, on displayFingerprintID: String) async throws -> Bool {
        let (_, byKey) = try await resolveLiveWindows()
        guard let axWindow = byKey[keyFor(window)] else { return false }
        return try await axClient.setFullscreen(axWindow, true)
    }

    private func intersectionArea(_ a: CGRectCodable, _ b: CGRectCodable) -> CGFloat {
        let i = a.cgRect.intersection(b.cgRect)
        if i.isNull || i.isEmpty { return 0 }
        return i.width * i.height
    }
}

