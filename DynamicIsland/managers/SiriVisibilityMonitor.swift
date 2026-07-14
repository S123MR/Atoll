/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Cocoa
import Combine
import Defaults

@MainActor
final class SiriVisibilityMonitor: ObservableObject {
    static let shared = SiriVisibilityMonitor()

    @Published private(set) var isSiriVisible = false

    private var isScreenLocked = false
    private var isDisplayOn = true
    private var isPluggedIn = false
    private var isInLowPowerMode = false
    private var cancellables = Set<AnyCancellable>()
    private var autohideSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]

    private var monitoringTimer: Timer?
    private var disappearanceConfirmations = 0
    private let disappearanceThreshold = 2
    private var batteryObserverID: Int?

    // Polling intervals calculated dynamically
    private var currentIdleInterval: TimeInterval {
        calculateIntervals().idle
    }

    private var currentActiveInterval: TimeInterval {
        calculateIntervals().active
    }

    private init() {
        setupStateObservers()
    }

    private func setupStateObservers() {
        // Observe lock state
        LockScreenManager.shared.$isLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] locked in
                self?.isScreenLocked = locked
                self?.updateMonitoringState()
            }
            .store(in: &cancellables)

        // Observe display sleep/wake
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayOn = false
            self?.updateMonitoringState()
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayOn = true
            self?.updateMonitoringState()
        }

        // Observe low power mode
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.isInLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.updateMonitoringState()
        }
        self.isInLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        self.isPluggedIn = BatteryActivityManager.shared.initializeBatteryInfo().isPluggedIn

        // Observe plug-in state via BatteryActivityManager
        batteryObserverID = BatteryActivityManager.shared.addObserver { [weak self] event in
            if case .powerSourceChanged(let pluggedIn) = event {
                Task { @MainActor in
                    self?.isPluggedIn = pluggedIn
                    self?.updateMonitoringState()
                }
            }
        }

        // Observe user preference changes to responsiveness mode
        Defaults.publisher(.siriResponsivenessMode)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMonitoringState()
            }
            .store(in: &cancellables)
    }

    private func calculateIntervals() -> (idle: TimeInterval, active: TimeInterval) {
        let mode = Defaults[.siriResponsivenessMode]

        let effectiveMode: SiriResponsivenessMode
        if mode == .automatic {
            if isInLowPowerMode {
                effectiveMode = .powerSaver
            } else if isPluggedIn {
                effectiveMode = .highPerformance
            } else {
                effectiveMode = .balanced
            }
        } else {
            effectiveMode = mode
        }

        let intervals: (idle: TimeInterval, active: TimeInterval)
        switch effectiveMode {
        case .highPerformance:
            intervals = (idle: 0.10, active: 0.03) // ~10Hz idle, ~33Hz active
        case .balanced, .automatic:
            intervals = (idle: 0.15, active: 0.05) // ~6.6Hz idle, ~20Hz active
        case .powerSaver:
            intervals = (idle: 1.00, active: 0.12) // ~1Hz idle, ~8Hz active
        }

        return intervals
    }

    private func updateMonitoringState() {
        guard #available(macOS 27, *) else { return }
        let shouldMonitor = isScreenLocked && isDisplayOn

        if shouldMonitor {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        let desiredInterval = isSiriVisible ? currentActiveInterval : currentIdleInterval

        if let currentTimer = monitoringTimer, currentTimer.isValid {
            if currentTimer.timeInterval == desiredInterval {
                return
            }
        }

        monitoringTimer?.invalidate()
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: desiredInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performCheck()
            }
        }
    }

    private func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil

        if isSiriVisible {
            setSiriVisible(false)
        }
        disappearanceConfirmations = 0
    }

    private func performCheck() {
        guard isScreenLocked && isDisplayOn else {
            stopMonitoring()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let isSiriActive = SiriVisibilityMonitor.detectSiriWindowOffMain()
            await MainActor.run { [weak self] in
                self?.applyDetectionResult(isSiriActive)
            }
        }
    }

    private static nonisolated func detectSiriWindowOffMain() -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            let owner  = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer  = info[kCGWindowLayer as String] as? Int ?? 0
            let bounds = info[kCGWindowBounds as String] as? [String: Int] ?? [:]
            let height = bounds["Height"] ?? 0
            let alpha  = info[kCGWindowAlpha as String] as? Float ?? 1.0

            let isSiri = (owner == SiriWindowConstants.siriOwnerName
                          || owner == SiriWindowConstants.appleIntelligenceOwnerName)
                         && layer == SiriWindowConstants.windowLayer
            let isVisible = alpha > SiriWindowConstants.minimumAlpha
                            && height > SiriWindowConstants.minimumHeight
            return isSiri && isVisible
        }
    }

    private func applyDetectionResult(_ isSiriActive: Bool) {
        if isSiriActive {
            disappearanceConfirmations = 0
            if !isSiriVisible {
                setSiriVisible(true)
                startMonitoring()
            }
        } else if isSiriVisible {
            disappearanceConfirmations += 1
            if disappearanceConfirmations >= disappearanceThreshold {
                setSiriVisible(false)
                disappearanceConfirmations = 0
                startMonitoring()
            }
        }
    }

    private func setSiriVisible(_ visible: Bool) {
        guard isSiriVisible != visible else { return }
        isSiriVisible = visible
    }

    // MARK: - Siri Window Detection Constants
    // These values are macOS 27-specific internals observed via CGWindowListCopyWindowInfo.
    // They ARE expected to change on future macOS major releases — audit on every OS bump.
    private enum SiriWindowConstants {
        /// CGWindowLayer assigned to the Siri / Apple Intelligence overlay on macOS 27.
        static let windowLayer: Int = 23

        /// Minimum window height in points used to distinguish the full Siri overlay
        /// from incidental utility windows owned by the same process.
        static let minimumHeight: Int = 400

        /// Alpha threshold below which the overlay is considered invisible.
        static let minimumAlpha: Float = 0.1

        /// CGWindowOwnerName for the classic Siri process.
        static let siriOwnerName = "Siri"

        /// CGWindowOwnerName for the Apple Intelligence / Campo process on macOS 27.
        static let appleIntelligenceOwnerName = "CampoRemoteService"
    }

    func refreshVisibilityState(for window: NSWindow?) {
        guard let window else { return }

        let targetAlpha: CGFloat
        if #available(macOS 27, *) {
            targetAlpha = (isSiriVisible && LockScreenManager.shared.isLocked) ? 0.0 : 1.0
        } else {
            targetAlpha = 1.0
        }

        window.contentView?.layer?.removeAllAnimations()

        if window.alphaValue != targetAlpha {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = targetAlpha
            }
        }
    }

    func autohide(_ window: NSWindow?) {
        guard #available(macOS 27, *) else { return }
        guard let window else { return }

        let key = ObjectIdentifier(window)
        autohideSubscriptions[key]?.cancel()
        autohideSubscriptions[key] = nil

        let subscription = Publishers.CombineLatest($isSiriVisible, LockScreenManager.shared.$isLocked)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main)
            .sink { [weak self, weak window] isVisible, isLocked in
                guard let self, let window else { return }
                guard isLocked else {
                    self.refreshVisibilityState(for: window)
                    return
                }

                let targetAlpha: CGFloat = isVisible ? 0.0 : 1.0
                window.contentView?.layer?.removeAllAnimations()

                if window.alphaValue != targetAlpha {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        window.animator().alphaValue = targetAlpha
                    }
                }
            }

        autohideSubscriptions[key] = subscription
        refreshVisibilityState(for: window)
    }

    deinit {
        if let id = batteryObserverID {
            BatteryActivityManager.shared.removeObserver(byId: id)
        }
    }
}
