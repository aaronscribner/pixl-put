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

    /// Called when an action the user explicitly asked for fails.
    ///
    /// `statusModel.lastError` alone is not enough: it only reaches the user if
    /// they happen to open the menu and click the error row. A Capture Now that
    /// refused to save therefore looked identical to one that succeeded — the
    /// user believed Desktops 4 and 5 were captured for a full day (2026-08-12).
    /// Failures the user is standing right in front of must announce themselves.
    public var onUserActionFailed: ((String) -> Void)?
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
    /// The in-flight Space-switch restore (300/500/1000ms retry loop).
    /// Cancelled when a newer Space switch supersedes it, and by ANY capture:
    /// a capture declares the current layout authoritative, and a pending
    /// restore armed milliseconds earlier would load the pre-capture
    /// snapshot and yank windows back to the layout the user just replaced
    /// (measured 2026-08-06 18:13:37 — capture and stale restore 3ms apart).
    private var pendingSpaceRestoreTask: Task<Void, Never>?

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
                // Respect the user's "Auto-restore on wake" setting. When off,
                // nothing moves automatically — restore is manual-only.
                guard statusModel.restoreOnSpaceSwitch else {
                    DiagnosticLog.write("restore", "SKIP wake-restore: auto-restore on wake disabled by setting")
                    return
                }
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
                    // Storage is keyed per Space, so loading the active Space's
                    // config is what scopes the restore — there are no other
                    // Spaces' entries in this file to mis-pair against. (The
                    // old global snapshot needed an explicit filter here: an
                    // entry for "Brave/<URL>" on Space 0 could pair with the
                    // same URL's live window on Space 5 and apply Space 0's
                    // frame.) Lazy Space-switch restores cover the rest as the
                    // user visits them.
                    let activeSpace = spaceResolverRef.activeSpaceIndex()
                    guard let snapshot = try store.loadLatest(forConfigurationID: configID,
                                                              spaceIndex: activeSpace) else {
                        DiagnosticLog.write("restore", """
                            SKIP wake restore: no config for space=\(activeSpace) of \(configID) \
                            — capture this Space once while you're on it.
                            """)
                        logger.log(.info, "Wake trigger fired but no snapshot exists for config \(configID) space \(activeSpace)")
                        return
                    }
                    let activeIDs = Set(enumerator.enumerate().map(\.fingerprint.id))
                    let report = try await restorerLocal.apply(
                        snapshot,
                        activeDisplayFingerprintIDs: activeIDs,
                        currentDisplayBoundsByID: Dictionary(
                            enumerator.enumerate().map { ($0.fingerprint.id, $0.bounds) },
                            uniquingKeysWith: { first, _ in first }),
                        onlySpaceIndex: activeSpace,
                        movePolicy: .settling   // displays re-attaching — AX clamps silently
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
        // Idle auto-capture is disabled: it fired on screensaver/idle and
        // overwrote the saved layout with whatever was on screen. Capture is
        // manual-only now (Capture now). Watcher intentionally NOT started.
        // idleWatcher.start()
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

        // App launch is deliberately NOT treated as a wake and does NOT
        // arm the Space-switch restore. Launching the app must not move any
        // windows — restore only happens on a real sleep/wake (while the app
        // is running) or when the user explicitly clicks Restore now.

        // A launch within minutes of a reboot is the one launch that IS a
        // wake: every app was just relaunched and its windows landed wherever
        // macOS put them. Arm the Space-switch restore gate so the first
        // visit to each Space restores it, exactly as after sleep. Measured
        // 2026-09-10: without this the first post-boot Space visit logged
        // "already visited since last wake (gate closed)" and nothing moved.
        let uptime = ProcessInfo.processInfo.systemUptime
        let freshBoot = BootDetection.isFreshBoot(uptime: uptime)
        if freshBoot {
            eventLog.recordWake()
            DiagnosticLog.write("startup",
                "fresh boot (uptime \(Int(uptime))s): Space-switch restore gate armed")
        }

        // Seed EventLog with the Space active at launch so it isn't later
        // treated as "unvisited since wake". On a fresh boot the active Space
        // is covered by restore-after-restart below.
        let initialSpace = spaceResolver.activeSpaceIndex()
        eventLog.recordSpaceVisit(spaceIndex: initialSpace)

        if freshBoot && statusModel.restoreAfterRestart {
            DiagnosticLog.write("startup", "fresh boot: restore-after-restart scheduled")
            scheduleRestoreAfterRestart()
        } else if freshBoot {
            DiagnosticLog.write("startup", "fresh boot: restore-after-restart disabled by setting")
        }

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
            // DISABLED: launching the app must not move windows. Restore only
            // on a real wake or explicit Restore now. (Left in place, gated
            // off, so it's easy to re-enable behind a setting later.)
            let restoreOnStartupEnabled = false
            guard restoreOnStartupEnabled else {
                DiagnosticLog.write("startup", "restore-on-startup disabled — launch does not move windows")
                return
            }
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
            let startupSpace = self.spaceResolver.activeSpaceIndex()
            guard let snapshot = try? storeStart.loadLatest(forConfigurationID: configID,
                                                            spaceIndex: startupSpace) else {
                DiagnosticLog.write("startup",
                    "No snapshot to restore on startup for config \(configID) space \(startupSpace)")
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
                    onlySpaceIndex: activeSpace,
                    movePolicy: .settling   // login items still creating windows
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
        // The restore gate for this Space: OPEN on the first visit since the
        // last wake-ish trigger (system wake, screens-wake, display
        // reconfiguration, unlock — anything that may have displaced
        // windows), CLOSED on every later visit (the user owns the layout
        // until the next such trigger re-arms it). Read it BEFORE recording
        // the visit — recordSpaceVisit would close the gate we're checking.
        //
        // An interim revision restored on EVERY visit. Tradeoff that killed
        // it: a window you move and don't recapture snaps back on the next
        // visit to that Space, yanking layouts the user had deliberately
        // rearranged since wake.
        let gateOpen = eventLog.shouldRestoreOnSwitch(toSpaceIndex: spaceIndex)
        let shouldRestore = statusModel.restoreOnSpaceSwitch && gateOpen
        let previouslyVisited = eventLog.lastVisited(spaceIndex: spaceIndex)
        eventLog.recordSpaceVisit(spaceIndex: spaceIndex)
        LoggerRegistry.app.log(.info,
            "Space changed to index=\(spaceIndex); previously visited=\(previouslyVisited?.description ?? "never"); gateOpen=\(gateOpen); will-restore=\(shouldRestore)")

        // License gate. If the state blocks auto features (expired/revoked
        // license, trial expired), skip the Space-switch restore — the only
        // path that still runs is manual Capture/Restore (and only those if
        // `allowsManualFeatures`).
        guard allowsAutoFeatures else {
            DiagnosticLog.write("restore",
                "SKIP Space-switch restore for space=\(spaceIndex): license state blocks auto features")
            return
        }

        // Every skip writes to the diagnostic log. The first wake-gate era
        // skipped silently, which cost a debugging session: "restore didn't
        // work" with an empty log is indistinguishable from "restore never
        // ran".
        guard gateOpen else {
            DiagnosticLog.write("restore",
                "SKIP Space-switch restore for space=\(spaceIndex): already visited since last wake (gate closed)")
            return
        }
        guard shouldRestore else {
            DiagnosticLog.write("restore",
                "SKIP Space-switch restore for space=\(spaceIndex): auto-restore toggle is off")
            return
        }

        let configID = displayEnumerator.configurationID()
        pendingSpaceRestoreTask?.cancel()
        pendingSpaceRestoreTask = Task { @MainActor [weak self] in
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
                // Cancelled = superseded by a newer Space switch or by a
                // capture. Applying anyway would restore a snapshot the
                // user has already replaced.
                if Task.isCancelled {
                    DiagnosticLog.write("restore",
                        "SKIP Space-switch restore for space=\(spaceIndex): superseded (newer switch or capture)")
                    return
                }
                if isScreenLockedNow() {
                    DiagnosticLog.write("restore",
                        "SKIP Space-switch restore for space=\(spaceIndex): screen is locked")
                    return
                }
                do {
                    guard let snapshot = try self.snapshotStore.loadLatest(forConfigurationID: configID,
                                                                          spaceIndex: spaceIndex) else {
                        // Must reach the DIAGNOSTIC log, not just os_log. A Space
                        // that has never been captured is the single most likely
                        // reason a restore "didn't work", and routing it to
                        // os_log alone made Desktops 4 and 5 fail silently on
                        // 2026-08-12 — indistinguishable from a broken restore.
                        DiagnosticLog.write("restore", """
                            SKIP Space-switch restore for space=\(spaceIndex): \
                            no config for this Space yet — capture it once while you're on it.
                            """)
                        LoggerRegistry.app.log(.info,
                            "Space-switch restore skipped: no config for space \(spaceIndex) of \(configID)")
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
        pendingSpaceRestoreTask?.cancel()
        pendingSpaceRestoreTask = nil
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceChangeObserver = nil
        }
    }

    /// Manually capture (user invoked from menu bar).
    public func captureNow() {
        // The Space being asked for is the one on screen at the click, not
        // whichever one the user is on when the enumeration completes.
        let requestedSpace = spaceResolver.activeSpaceIndex()
        Task { @MainActor in
            guard allowsManualFeatures else {
                statusModel.lastError = "License required. Open menu bar → License… to activate or start a trial."
                DiagnosticLog.write("capture", "BLOCKED manual capture: license state = \(licenseValidator.state)")
                return
            }
            // Capture declares the CURRENT layout authoritative. A restore
            // scheduled by the Space switch the user made moments ago must
            // not fire mid-capture (moving windows while frames are being
            // read) or after it (loading the pre-capture snapshot and
            // yanking windows back to the layout just replaced).
            pendingSpaceRestoreTask?.cancel()
            pendingSpaceRestoreTask = nil
            do {
                let snap = try await snapshotEngine.capture(
                    trigger: .manual,
                    useDeepIdentity: statusModel.deepIdentityEnabled,
                    expectedSpaceIndex: requestedSpace
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
                // The user pressed Capture Now and is waiting on an answer. Say
                // it out loud rather than parking it behind a menu click.
                onUserActionFailed?(msg)
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
                // Read the index ONCE, verified. This used to be read twice —
                // here and again for `onlySpaceIndex` below — so a Space switch
                // landing between the two loaded one Space's config and filtered
                // it for another, considering zero entries.
                let activeSpace = await spaceResolver.settledActiveSpaceIndex { reported, observed in
                    DiagnosticLog.write("restore", """
                        SETTLING manual restore: display says space \(reported) but on-screen \
                        windows are on \(observed) — waiting for the Space switch to finish.
                        """)
                }
                guard let snap = try snapshotStore.loadLatest(forConfigurationID: configID,
                                                              spaceIndex: activeSpace) else {
                    statusModel.lastError = "No snapshot for this Space (\(activeSpace + 1)) on the current display configuration. Capture first."
                    // Diagnostic log, not just os_log: "restore did nothing" with
                    // an empty diagnostic log is indistinguishable from a broken
                    // restore, which cost a full debugging session on 2026-08-13.
                    DiagnosticLog.write("restore", """
                        SKIP manual restore: no config for space=\(activeSpace) \
                        of \(configID) — capture this Space once while you're on it.
                        """)
                    LoggerRegistry.app.log(.info, "Manual restore: no config for space \(activeSpace) of \(configID)")
                    return
                }
                // Manual "Restore now" restores ONLY the active Space. It
                // deliberately does NOT recordWake()/re-arm the per-Space lazy
                // restore. Re-arming made every *other* Space restore on its
                // next visit — clobbering whatever layout the user had since
                // arranged there (e.g. Space 0's windows getting yanked back
                // to a stale snapshot the moment you switched to it). Restore
                // now = "fix the Space I'm looking at", nothing more. Automatic
                // multi-Space restore happens only on a real wake.
                let activeIDs = Set(displayEnumerator.enumerate().map(\.fingerprint.id))
                let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: activeIDs, currentDisplayBoundsByID: currentDisplayBoundsByID(), onlySpaceIndex: activeSpace)
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


    /// Restore windows to the **Spaces** they were captured on, then restore
    /// their frames across every Space (ADR-0002).
    ///
    /// Unlike `restoreNow()`, which deliberately touches only the active Space,
    /// this is the full cross-Space restore. Relocation runs first so that the
    /// frame pass finds each window already on its destination Space.
    ///
    /// The relocation mechanism is process-scoped: an app whose windows were
    /// captured on several Spaces cannot be fully reproduced, and those windows
    /// are reported as displaced rather than silently mis-placed.
    /// Why a cross-Space restore is running. Decides which licence gate
    /// applies and how the outcome is worded.
    public enum RestoreSpacesTrigger: String, Sendable {
        case manual
        case afterRestart
    }

    public func restoreSpaces() {
        Task { @MainActor in
            await self.performRestoreSpaces(trigger: .manual)
        }
    }

    /// The full cross-Space restore (ADR-0002). Returns `false` when it was
    /// refused before touching anything; `true` when it ran, whether or not
    /// anything needed moving. The outcome is always written to
    /// `statusModel.lastError` when nothing moved, so a click that "did
    /// nothing" can always explain itself.
    @discardableResult
    func performRestoreSpaces(trigger: RestoreSpacesTrigger) async -> Bool {
        let licensed = trigger == .manual ? allowsManualFeatures : allowsAutoFeatures
        guard licensed else {
            statusModel.lastError = "License required. Open menu bar → License… to activate or start a trial."
            DiagnosticLog.write("restore-spaces", "BLOCKED: license state = \(licenseValidator.state)")
            return false
        }
        guard spaceResolver.canRelocateAcrossSpaces else {
            statusModel.lastError = "This macOS doesn't expose the Space-relocation API. "
                + "Windows can still be restored to their display and frame via Restore now."
            LoggerRegistry.app.log(.info, "Restore Spaces unavailable: CGSProcessAssignToSpace missing")
            return false
        }
        // ADR-0003: this project targets one display configuration. With
        // several managed Space sets a stored Space index doesn't identify
        // which display it came from, and a guess scatters windows onto a
        // Space the user never picked. Refuse, and say why.
        guard spaceResolver.hasSupportedSpaceConfiguration else {
            statusModel.lastError = "Restoring Spaces needs Spaces that span your displays. "
                + "Turn off System Settings → Desktop & Dock → \"Displays have separate Spaces\", "
                + "or use Restore now, which is unaffected."
            DiagnosticLog.write("restore-spaces", "REFUSED: multiple managed Space sets (ADR-0003)")
            LoggerRegistry.app.log(.info, "Restore Spaces refused: unsupported display/Spaces configuration")
            return false
        }

        let configID = displayEnumerator.configurationID()
        // Relocation planning is the one operation that genuinely needs
        // every Space at once — it decides, per window or per app, which
        // Space to send it to. So union each Space's config into one working
        // snapshot. Every other path reads a single Space.
        let knownSpaces = snapshotStore.spaceIndices(forConfigurationID: configID)
        var unioned: [WindowEntry] = []
        var newestCapture: Date?
        var unionDisplays: [DisplaySnapshot] = []
        for index in knownSpaces {
            guard let s = try? snapshotStore.loadLatest(forConfigurationID: configID,
                                                        spaceIndex: index) else { continue }
            unioned.append(contentsOf: s.windows)
            if newestCapture == nil || s.capturedAt > newestCapture! {
                newestCapture = s.capturedAt
                unionDisplays = s.displays
            }
        }
        guard !unioned.isEmpty, let capturedAt = newestCapture else {
            statusModel.lastError = "No Space configs exist for the current display configuration (\(configID)). Capture first."
            DiagnosticLog.write("restore-spaces", "\(trigger.rawValue): no Space configs for \(configID)")
            return false
        }
        let snap = Snapshot(
            displayConfigurationID: configID,
            displays: unionDisplays,
            capturedAt: capturedAt,
            trigger: .manual,
            windows: unioned
        )
        LoggerRegistry.app.log(.info,
            "Restore Spaces (\(trigger.rawValue)): unioned \(unioned.count) window(s) from space configs \(knownSpaces)")
        DiagnosticLog.write("restore-spaces",
            "\(trigger.rawValue): begin — \(unioned.count) captured window(s) across Spaces \(knownSpaces)")

        // Backend. yabai (per-window) when it answers. When yabai is
        // installed but silent — the state every reboot leaves it in unless
        // its launch agent is installed — try to start it, and refuse rather
        // than downgrade if that fails: the per-app backend deliberately
        // leaves every app whose windows span Spaces where it is, which for
        // this user's layout is a restore that does nothing.
        let selection = SpaceRelocationBackendFactory.select()
        var backend = selection.backend
        if !backend.supportsPerWindowMoves, let yabai = YabaiRelocationBackend.locate() {
            DiagnosticLog.write("restore-spaces", "yabai installed but not answering; starting its service")
            if yabai.startService() {
                backend = yabai
                DiagnosticLog.write("restore-spaces", "yabai service started")
            } else {
                statusModel.lastError = "yabai is installed but not running, and PixlPut couldn't start it. "
                    + "Restore Spaces needs it to move windows one at a time. "
                    + "Run scripts/setup-yabai.sh, and approve yabai under Privacy & Security → Accessibility."
                DiagnosticLog.write("restore-spaces", "REFUSED: yabai installed but not answering after --start-service")
                return false
            }
        }
        DiagnosticLog.write("restore-spaces", "backend=\(backend.name)")

        do {
            if let yabai = backend as? YabaiRelocationBackend {
                try await crossSpaceRestore(yabai: yabai, snapshot: snap, trigger: trigger)
            } else {
                try await perAppRestore(backend: backend, snapshot: snap)
            }
            return true
        } catch {
            let msg = Self.describe(error: error, operation: "restore Spaces")
            statusModel.lastError = msg
            LoggerRegistry.app.log(.error, "Restore Spaces failed: \(error)")
            DiagnosticLog.write("restore-spaces", "FAILED: \(error)")
            return false
        }
    }

    /// Per-window restore over every Space at once.
    ///
    /// yabai's window query is the only enumeration that covers Spaces AX
    /// cannot see; AX supplies exact identities for the active Space, and
    /// AppleScript supplies documents-by-title for the rest. Spaces and
    /// frames on non-active Spaces are set through yabai; the active Space's
    /// frames go through the verified AX pass as always.
    private func crossSpaceRestore(
        yabai: YabaiRelocationBackend,
        snapshot snap: Snapshot,
        trigger: RestoreSpacesTrigger
    ) async throws {
        let bundleIDByPID: [pid_t: String] = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
                app.bundleIdentifier.map { (app.processIdentifier, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Active-Space identities from AX: exact, and the same pipeline that
        // wrote the snapshot.
        let axLive = (try? await restorerBackend.enumerateLiveWindows()) ?? []
        let axByWindowID: [CGWindowID: LiveWindow] = Dictionary(
            axLive.compactMap { w in w.windowID.map { ($0, w) } },
            uniquingKeysWith: { first, _ in first }
        )

        // PixPut's own every-Space enumeration is authoritative. It needs no
        // helper process, so the plan can still be built when yabai is
        // absent or stopped, and it is correct on the spanning-display
        // configuration (ADR-0003) that yabai historically mis-read. yabai
        // stays the fallback, and remains the actuator either way: only it
        // can move another process's window between Spaces.
        //
        // Titles come from yabai. On a Space AX cannot see, every identity is
        // built from a title — VS Code's workspace name, and the browser
        // documents joined by title — and CoreGraphics withholds titles
        // without Screen Recording (0 of 13 VS Code windows, measured
        // 2026-09-13). yabai reads them over AX for every window it tracks.
        // One query serves both that and the tracked-window filter below.
        let tracked = yabai.queryWindows()
        let yabaiTitles = NativeWindowQuery.titles(from: tracked)
        let source: String
        let yabaiWindows: [YabaiWindow]
        let untracked: Int
        // CoreGraphics also lists windows no user placed: off-screen 500×500
        // placeholders, popups, an app's hidden panels. Measured 2026-09-13:
        // 13 beside 63 real windows, none tracked by yabai. Left in, each
        // takes an ordinal from a real window of its app.
        let native = NativeWindowQuery.windows(titlesByWindowID: yabaiTitles) ?? []
        let restricted = NativeWindowQuery.restricted(
            native, toTrackedIDs: tracked.map { Set($0.map(\.id)) }
        )
        if NativeWindowQuery.nativeCoversTracked(kept: restricted.kept.count, trackedCount: tracked?.count) {
            yabaiWindows = restricted.kept
            untracked = restricted.dropped
            source = "native"
        } else if let fromYabai = tracked {
            DiagnosticLog.write("restore-spaces", """
                native window query unusable: \(restricted.kept.count) of \(fromYabai.count) \
                yabai-tracked window(s), \(native.count) before filtering — planning from yabai's query
                """)
            yabaiWindows = fromYabai
            untracked = 0
            source = "yabai"
        } else {
            statusModel.lastError = "The window query failed, from both PixPut and yabai. Nothing was moved."
            DiagnosticLog.write("restore-spaces", "window query failed (native and yabai)")
            return
        }

        // Documents by title for other Spaces — browsers' active tab. Gated
        // like every other AppleScript use.
        var documentsByTitle: [String: [String: URL]] = [:]
        if statusModel.deepIdentityEnabled {
            let bundles = Set(yabaiWindows.compactMap { bundleIDByPID[$0.pid] })
                .filter { DeepIdentityFetcher.reportsDocumentsByTitle(bundleID: $0) }
            for bundleID in bundles.sorted() {
                if let docs = await restorerBackend.deepIdentityFetcher.documentsByTitle(bundleID: bundleID) {
                    documentsByTitle[bundleID] = docs
                }
            }
        }

        let currentBounds = currentDisplayBoundsByID()
        let index = CrossSpaceWindowIndex.build(
            yabaiWindows: yabaiWindows,
            bundleIDByPID: bundleIDByPID,
            axLiveByWindowID: axByWindowID,
            documentsByTitle: documentsByTitle,
            displayBoundsByID: currentBounds
        )
        // Windows on other Spaces identified by a browser document joined by
        // title. Zero while browsers are open on other Spaces means that join
        // is broken again.
        let browserDocs = index.filter { w in
            guard let id = w.live.windowID, axByWindowID[id] == nil,
                  DeepIdentityFetcher.reportsDocumentsByTitle(bundleID: w.live.bundleID),
                  case .documentPath = w.live.identity else { return false }
            return true
        }.count
        let spaceByWindowID: [CGWindowID: Int] = Dictionary(
            index.compactMap { w in w.live.windowID.map { ($0, w.spaceIndex) } },
            uniquingKeysWith: { first, _ in first }
        )
        let matches = SpaceAssignmentPlanner.perWindowMatches(snapshot: snap.windows,
                                                              live: index.map(\.live))
        DiagnosticLog.write("restore-spaces", """
            cross-Space index: source=\(source) windows=\(yabaiWindows.count) untracked=\(untracked) \
            titledByYabai=\(yabaiTitles.count) \
            placeable=\(index.count) \
            ax=\(axLive.count) scriptedApps=\(documentsByTitle.count) browserDocs=\(browserDocs) matched=\(matches.count) \
            captured=\(snap.windows.count)
            """)

        // Unmatched live windows, by app, so "why didn't X move" is answerable.
        let matchedIDs = Set(matches.map(\.windowID))
        let unmatched = index.filter { w in w.live.windowID.map { !matchedIDs.contains($0) } ?? true }
        for app in Dictionary(grouping: unmatched, by: { $0.live.bundleID }).sorted(by: { $0.key < $1.key }) {
            let kinds = Set(app.value.map { identityKind($0.live.identity) }).sorted().joined(separator: ",")
            DiagnosticLog.write("restore-spaces",
                "unmatched: \(app.key) \(app.value.count) window(s) [identity: \(kinds)]")
        }

        // 1. Space moves — verified by re-reading each window's Space.
        let moves = matches
            .filter { spaceByWindowID[$0.windowID] != $0.entry.spaceIndex }
            .map { SpaceAssignmentPlanner.WindowMove(windowID: $0.windowID,
                                                     targetSpaceIndex: $0.entry.spaceIndex,
                                                     bundleID: $0.live.bundleID) }
        let assigner = SpaceAssigner(backend: yabai)
        let unlanded = assigner.applyPerWindow(moves)
        let movedCount = moves.count - unlanded.count
        let alreadyThere = matches.count - moves.count
        var scriptingAdditionProblem: String?
        if let first = unlanded.first,
           let diag = yabai.moveDiagnostic(windowID: first.windowID, toSpaceIndex: first.targetSpaceIndex) {
            DiagnosticLog.write("restore-spaces", "yabai --space failed: \(diag)")
            if diag.localizedCaseInsensitiveContains("scripting") || diag.localizedCaseInsensitiveContains("addition") {
                scriptingAdditionProblem = diag
            }
        }
        for move in unlanded {
            DiagnosticLog.write("restore-spaces",
                "\(move.bundleID) window \(move.windowID) -> space \(move.targetSpaceIndex): did not land")
        }
        for m in matches where !unlanded.contains(where: { $0.windowID == m.windowID }) {
            DiagnosticLog.write("restore-spaces",
                "\(m.live.bundleID) window \(m.windowID) -> space \(m.entry.spaceIndex): "
                + (spaceByWindowID[m.windowID] == m.entry.spaceIndex ? "already there" : "moved"))
        }

        // Relocation is asynchronous in the window server; give it a beat
        // before frames are read or set.
        try? await Task.sleep(nanoseconds: 250_000_000)

        // 2. Frames on Spaces AX cannot reach, through yabai. Re-anchor by
        // display origin exactly as Restorer does.
        let savedBounds: [String: CGRectCodable] = Dictionary(
            snap.displays.map { ($0.fingerprint.id, $0.bounds) },
            uniquingKeysWith: { first, _ in first }
        )
        func reanchored(_ entry: WindowEntry) -> CGRectCodable {
            guard let saved = savedBounds[entry.displayFingerprintID],
                  let current = currentBounds[entry.displayFingerprintID] else { return entry.frame }
            let dx = current.x - saved.x, dy = current.y - saved.y
            if dx == 0 && dy == 0 { return entry.frame }
            return CGRectCodable(x: entry.frame.x + dx, y: entry.frame.y + dy,
                                 width: entry.frame.width, height: entry.frame.height)
        }
        let activeSpace = spaceResolver.activeSpaceIndex()
        var framed = 0
        var frameFailed = 0
        for m in matches where m.entry.spaceIndex != activeSpace
            && !unlanded.contains(where: { $0.windowID == m.windowID })
            && !m.entry.isMinimized {
            let target = reanchored(m.entry)
            if Self.framesEqual(m.live.currentFrame, target, tolerance: 1.0) { continue }
            if yabai.setFrame(windowID: m.windowID, frame: target) {
                framed += 1
            } else {
                frameFailed += 1
                DiagnosticLog.write("restore-spaces",
                    "\(m.live.bundleID) window \(m.windowID): frame set failed on space \(m.entry.spaceIndex)")
            }
        }

        // 3. The active Space's frames via the verified AX pass.
        let activeIDs = Set(displayEnumerator.enumerate().map(\.fingerprint.id))
        let report = try await restorer.apply(
            snap,
            activeDisplayFingerprintIDs: activeIDs,
            currentDisplayBoundsByID: currentBounds,
            onlySpaceIndex: activeSpace,
            movePolicy: trigger == .afterRestart ? .settling : .fast
        )

        statusModel.lastRestore = Date()
        statusModel.lastRestoreMoved = report.moved + movedCount + framed
        statusModel.lastRestoreSkipped = report.skippedMissingWindow + report.skippedAlreadyAtFrame
        statusModel.lastRestoreDisplaced = report.displacedNoMatchingDisplay

        var notes: [String] = []
        if movedCount == 0 && framed == 0 && report.moved == 0 {
            notes.append("Nothing moved: \(alreadyThere) window(s) already on their captured Space"
                + (matches.count == 0 ? "; no live window matched a captured entry" : "") + ".")
        }
        if !unlanded.isEmpty {
            notes.append("\(unlanded.count) window(s) couldn't change Space."
                + (scriptingAdditionProblem != nil
                   ? " yabai's scripting addition isn't loaded — run scripts/setup-yabai.sh."
                   : " See the diagnostic log."))
        }
        if frameFailed > 0 { notes.append("\(frameFailed) frame(s) couldn't be set on other Spaces.") }
        if !unmatched.isEmpty {
            let apps = Dictionary(grouping: unmatched, by: { $0.live.bundleID }).keys.sorted()
                .map { $0.components(separatedBy: ".").last ?? $0 }.prefix(5).joined(separator: ", ")
            notes.append("\(unmatched.count) window(s) had no captured match (\(apps)"
                + (unmatched.count > 5 ? ", …" : "") + ")"
                + (statusModel.deepIdentityEnabled ? "." : "; turn on deep identity in Settings to match browser windows on other Spaces."))
        }
        statusModel.lastError = notes.isEmpty ? nil : notes.joined(separator: " ")

        DiagnosticLog.write("restore-spaces", """
            done (\(trigger.rawValue)): backend=\(yabai.name) spaceMoves=\(movedCount) alreadyThere=\(alreadyThere) \
            unlanded=\(unlanded.count) framesViaYabai=\(framed) frameFailed=\(frameFailed) \
            axFramesMoved=\(report.moved) unmatched=\(unmatched.count)
            """)
        LoggerRegistry.app.log(.info,
            "Restore Spaces via \(yabai.name): moved=\(movedCount) framed=\(framed) axMoved=\(report.moved) unmatched=\(unmatched.count)")
    }

    /// Per-app restore — the path for machines without yabai. Process-scoped
    /// moves, so apps whose windows span Spaces are left alone (ADR-0002).
    private func perAppRestore(backend: SpaceRelocationBackend, snapshot snap: Snapshot) async throws {
        let assigner = SpaceAssigner(backend: backend)
        var notes: [String] = []

        let plan = SpaceAssignmentPlanner.plan(for: snap.windows)
        let outcomes = assigner.apply(plan)
        let failed = outcomes.filter { !$0.applied }
        let alreadyInPlaceCount = outcomes.filter { $0.applied && $0.alreadyOnTarget }.count
        let relocatedCount = outcomes.count - failed.count - alreadyInPlaceCount
        let failedCount = failed.count
        let leftAloneCount = plan.unrestorable.count

        for outcome in outcomes where outcome.applied {
            DiagnosticLog.write("restore-spaces",
                "\(outcome.bundleID) -> space \(outcome.targetSpaceIndex): "
                + (outcome.alreadyOnTarget ? "already there, not assigned" : "moved"))
        }
        for outcome in failed {
            DiagnosticLog.write("restore-spaces",
                "\(outcome.bundleID) -> space \(outcome.targetSpaceIndex): \(outcome.failureReason ?? "unknown")")
        }
        // Apps the do-no-harm guard skipped. Logged individually so the skip
        // is auditable — silently omitting them would read as "PixPut
        // ignored my windows".
        for skipped in plan.unrestorable {
            DiagnosticLog.write("restore-spaces",
                "\(skipped.bundleID): LEFT ALONE — \(skipped.windowCount) window(s) across "
                + "\(skipped.spaceCount) Spaces; best target would place "
                + "\(skipped.bestCaseSatisfied) and misplace \(skipped.bestCaseDisplaced)")
        }
        if !plan.unrestorable.isEmpty {
            let apps = plan.unrestorable.map(\.bundleID).joined(separator: ", ")
            notes.append("\(plan.totalLeftAlone) window(s) left where they are: "
                + "\(apps) had windows spread across Spaces, and macOS moves an app's "
                + "windows together — collapsing them onto one Space would misplace more "
                + "than it fixes. Install yabai (scripts/setup-yabai.sh) for per-window moves.")
        }
        if plan.totalDisplaced > 0 {
            let apps = plan.partial.map(\.bundleID).joined(separator: ", ")
            notes.append("\(plan.totalDisplaced) window(s) couldn't be placed: "
                + "\(apps) had windows on more than one Space, and macOS moves an app's "
                + "windows together.")
        }
        if failedCount > 0 {
            notes.append("\(failedCount) app(s) couldn't be relocated — see Settings → Snapshots.")
        }
        if relocatedCount == 0 {
            let summary: String
            if alreadyInPlaceCount > 0 && failedCount == 0 && leftAloneCount == 0 {
                summary = "Nothing to move: all \(alreadyInPlaceCount) app(s) were already on their captured Spaces."
            } else if alreadyInPlaceCount > 0 {
                summary = "No apps moved; \(alreadyInPlaceCount) were already on their captured Spaces."
            } else {
                summary = "No apps moved."
            }
            notes.insert(summary, at: 0)
        }
        DiagnosticLog.write("restore-spaces", """
            done: backend=\(backend.name) relocated=\(relocatedCount) \
            alreadyInPlace=\(alreadyInPlaceCount) failed=\(failedCount) leftAlone=\(leftAloneCount)
            """)

        // Relocation is asynchronous in the window server; give it a beat
        // before AX starts reading frames.
        try? await Task.sleep(nanoseconds: 250_000_000)

        let activeIDs = Set(displayEnumerator.enumerate().map(\.fingerprint.id))
        let report = try await restorer.apply(
            snap,
            activeDisplayFingerprintIDs: activeIDs,
            currentDisplayBoundsByID: currentDisplayBoundsByID(),
            onlySpaceIndex: nil            // every Space, not just the active one
        )
        statusModel.lastRestore = Date()
        statusModel.lastRestoreMoved = report.moved
        statusModel.lastRestoreSkipped = report.skippedMissingWindow + report.skippedAlreadyAtFrame
        statusModel.lastRestoreDisplaced = report.displacedNoMatchingDisplay
        statusModel.lastError = notes.isEmpty ? nil : notes.joined(separator: " ")
        LoggerRegistry.app.log(.info,
            "Restore Spaces via \(backend.name): relocated=\(relocatedCount) "
            + "failed=\(failedCount) frames moved=\(report.moved)")
    }

    private static func framesEqual(_ a: CGRectCodable, _ b: CGRectCodable, tolerance: Double) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func identityKind(_ identity: WindowIdentity) -> String {
        switch identity {
        case .documentPath: return "document"
        case .browserTabSet: return "tabs"
        case .editorWorkspace: return "workspace"
        case .terminalCWD: return "cwd"
        case .titleRegex: return "title"
        case .ordinal: return "ordinal-only"
        }
    }

    // MARK: - Restore after restart

    /// Wait out the login storm, then run the cross-Space restore, and keep
    /// re-running it while late-launching apps keep appearing. Only ever
    /// scheduled when the app was launched within minutes of a reboot.
    private func scheduleRestoreAfterRestart() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Settle: sample the CG window population every 5s; settled after
            // four equal samples (20s of no change). Hard cap 5 minutes.
            var tracker = SettleTracker(requiredStableSamples: 4)
            let start = Date()
            let settleDeadline = start.addingTimeInterval(5 * 60)
            while !tracker.isSettled && Date() < settleDeadline {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if isScreenLockedNow() { continue }
                tracker.record(CGWindowEnumerator.enumerateAllWindows().count)
            }
            // Don't move windows the user can't see; wait for unlock.
            let unlockDeadline = Date().addingTimeInterval(10 * 60)
            while isScreenLockedNow() && Date() < unlockDeadline {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            guard !isScreenLockedNow() else {
                DiagnosticLog.write("restore-spaces", "afterRestart: still locked after 10 minutes, giving up")
                return
            }
            DiagnosticLog.write("restore-spaces", """
                afterRestart: window population \(tracker.isSettled ? "settled" : "did not settle") \
                after \(Int(Date().timeIntervalSince(start)))s at \(tracker.latest ?? -1) window(s)
                """)
            let ran = await self.performRestoreSpaces(trigger: .afterRestart)
            guard ran else { return }

            // Late arrivals: every minute for ten minutes, restore again
            // whenever an app that wasn't running before has appeared.
            func runningBundles() -> Set<String> {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            }
            var seen = runningBundles()
            let retryDeadline = Date().addingTimeInterval(10 * 60)
            while Date() < retryDeadline {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if isScreenLockedNow() { continue }
                let now = runningBundles()
                let newcomers = now.subtracting(seen)
                guard !newcomers.isEmpty else { continue }
                seen = now
                DiagnosticLog.write("restore-spaces",
                    "afterRestart: new app(s) \(newcomers.sorted().joined(separator: ", ")) — restoring again")
                await self.performRestoreSpaces(trigger: .afterRestart)
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
                let pickerSpace = await spaceResolver.settledActiveSpaceIndex { reported, observed in
                    DiagnosticLog.write("restore", """
                        SETTLING slot restore: display says space \(reported) but on-screen \
                        windows are on \(observed) — waiting for the Space switch to finish.
                        """)
                }
                guard let snap = try snapshotStore.load(forConfigurationID: configID,
                                                        spaceIndex: pickerSpace,
                                                        slot: slot) else {
                    statusModel.lastError = "Slot \(slot) is empty for Space \(pickerSpace)."
                    return
                }
                let activeIDs = Set(displayEnumerator.enumerate().map(\.fingerprint.id))
                let report = try await restorer.apply(snap, activeDisplayFingerprintIDs: activeIDs, currentDisplayBoundsByID: currentDisplayBoundsByID(), onlySpaceIndex: pickerSpace)
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
        if case SnapshotEngine.CaptureError.spaceChangedDuringCapture(let reported, let observed) = error {
            // Deliberately actionable: nothing was written, and waiting a beat
            // is the whole fix.
            return "Space was still changing — nothing was saved. "
                + "The system reported Desktop \(reported + 1) but the windows were on Desktop \(observed + 1). "
                + "Wait a second after switching Spaces, then capture again."
        }
        if case SnapshotEngine.CaptureError.spaceLeftBeforeCaptureFinished(let requested, _) = error {
            return "You left Desktop \(requested + 1) before its capture finished, so nothing was saved. "
                + "Go back to Desktop \(requested + 1), capture again, and stay there a few seconds."
        }
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

    /// Toggle the "Auto-restore on wake" user setting. When off, PixlPut never
    /// moves windows automatically — restore is manual-only (Restore now).
    public func toggleAutoRestore() {
        statusModel.restoreOnSpaceSwitch.toggle()
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
    private func resolveLiveWindows(
        limitToBundleIDs: Set<String>? = nil
    ) async throws -> ([LiveWindow], [AXKey: AXWindow]) {
        let axWindows = try await axClient.enumerateWindows(limitToBundleIDs: limitToBundleIDs)
            .filter { !ExcludedApps.contains($0.bundleID) }
        let displays = displayEnumerator.enumerate()
        let resolver = WindowIdentityResolver.defaultV1()

        // Same fetch as capture: title-joined where the app supports it.
        var deepByBundle: [String: [Int: WindowIdentity]] = [:]
        var documentsByTitle: [String: [String: URL]] = [:]
        if useDeepIdentity {
            for bundleID in Set(axWindows.map(\.bundleID)) {
                if DeepIdentityFetcher.reportsDocumentsByTitle(bundleID: bundleID) {
                    if let docs = await deepIdentityFetcher.documentsByTitle(bundleID: bundleID) {
                        documentsByTitle[bundleID] = docs
                    }
                } else if DeepIdentityFetcher.isScripted(bundleID: bundleID),
                          let result = await deepIdentityFetcher.identitiesForApp(bundleID: bundleID) {
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
            let deep = DeepIdentityFetcher.signalInputs(
                bundleID: axw.bundleID,
                indexInApp: axw.indexInApp,
                title: axw.title,
                axDocumentURL: axw.documentURL,
                identitiesByIndex: deepByBundle,
                documentsByTitle: documentsByTitle
            )
            let identity = resolver.resolve(WindowSignal(
                bundleID: axw.bundleID,
                title: axw.title,
                documentURL: deep.documentURL,
                appProviderIdentity: deep.appProviderIdentity,
                creationOrdinal: axw.creationOrdinal
            ))
            // CGWindowID enables per-window Space relocation (ADR-0002) and
            // windowID-first restore matching. Pre-fetched at enumeration.
            let cgWindowID = axw.windowID
            live.append(LiveWindow(
                bundleID: axw.bundleID,
                identity: identity,
                ordinalInApp: axw.creationOrdinal,
                currentFrame: frame,
                currentDisplayFingerprintID: displayFingerprintID,
                windowID: cgWindowID,
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

    // MARK: - AX element cache
    //
    // `move()`/`setFullscreen()` used to call `resolveLiveWindows()` — a
    // full AX enumeration plus per-app AppleScript — PER WINDOW MOVED, so a
    // restore that moved N windows walked the world N+1 times. That, not
    // the moves themselves (2–4 ms each), was the bulk of the minute-long
    // restores. `Restorer.apply` always enumerates through this same
    // backend before it moves anything, so the elements resolved there are
    // fresh; cache them and look up by CG window number (exact), falling
    // back to the composite key for windows without one.
    private let cacheLock = NSLock()
    private var cachedByKey: [AXKey: AXWindow] = [:]
    private var cachedByWindowID: [CGWindowID: AXWindow] = [:]

    private func cachedAXWindow(for window: LiveWindow) -> AXWindow? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let wid = window.windowID, let axw = cachedByWindowID[wid] { return axw }
        return cachedByKey[keyFor(window)]
    }

    /// Synchronous so the NSLock critical section contains no suspension
    /// points (Swift 6 forbids lock()/unlock() across awaits).
    private func updateCache(byKey: [AXKey: AXWindow]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedByKey = byKey
        cachedByWindowID = Dictionary(
            byKey.values.compactMap { axw in axw.windowID.map { ($0, axw) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func enumerateLiveWindows(limitToBundleIDs: Set<String>?) async throws -> [LiveWindow] {
        let (live, byKey) = try await resolveLiveWindows(limitToBundleIDs: limitToBundleIDs)
        updateCache(byKey: byKey)
        return live
    }

    public func move(window: LiveWindow, to frame: CGRectCodable, policy: MovePolicy) async throws -> Bool {
        if let axWindow = cachedAXWindow(for: window) {
            return try await axClient.move(axWindow, to: frame, policy: policy)
        }
        // Cache miss — caller skipped enumeration or the window is gone.
        // One fresh resolve, scoped to the one app that matters.
        let (_, byKey) = try await resolveLiveWindows(limitToBundleIDs: [window.bundleID])
        guard let axWindow = byKey[keyFor(window)] else { return false }
        return try await axClient.move(axWindow, to: frame, policy: policy)
    }

    public func setFullscreen(window: LiveWindow, on displayFingerprintID: String) async throws -> Bool {
        if let axWindow = cachedAXWindow(for: window) {
            return try await axClient.setFullscreen(axWindow, true)
        }
        let (_, byKey) = try await resolveLiveWindows(limitToBundleIDs: [window.bundleID])
        guard let axWindow = byKey[keyFor(window)] else { return false }
        return try await axClient.setFullscreen(axWindow, true)
    }

    private func intersectionArea(_ a: CGRectCodable, _ b: CGRectCodable) -> CGFloat {
        let i = a.cgRect.intersection(b.cgRect)
        if i.isNull || i.isEmpty { return 0 }
        return i.width * i.height
    }
}

