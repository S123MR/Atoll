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

@MainActor
final class SiriVisibilityMonitor: ObservableObject {
    static let shared = SiriVisibilityMonitor()

    @Published private(set) var isSiriVisible = false
    
    private var isScreenLocked = false
    private var isDisplayOn = true
    private var cancellables = Set<AnyCancellable>()
    
    private var monitoringTimer: Timer?
    private var disappearanceConfirmations = 0
    private let disappearanceThreshold = 2 

    private init() {
        setupStateObservers()
    }

    private func setupStateObservers() {
        LockScreenManager.shared.$isLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] locked in
                self?.isScreenLocked = locked
                self?.updateMonitoringState()
            }
            .store(in: &cancellables)

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayOn = false
            self?.updateMonitoringState()
        }
        wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isDisplayOn = true
            self?.updateMonitoringState()
        }
    }

    private func updateMonitoringState() {
        let shouldMonitor = isScreenLocked && isDisplayOn
        
        if shouldMonitor {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        // High-performance intervals:
        // Idle is set to 0.12 seconds (~8Hz) for instant, lag-free appearance detection.
        // Active is set to 0.05 seconds (20Hz) for highly responsive tracking during dismissal.
        let desiredInterval: TimeInterval = isSiriVisible ? 0.05 : 0.12
        
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
        print("🟢 [SiriVisibilityMonitor] Started polling at \(desiredInterval)s interval")
    }

    private func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        
        if isSiriVisible {
            setSiriVisible(false)
        }
        disappearanceConfirmations = 0
        print("🔴 [SiriVisibilityMonitor] Stopped polling")
    }

    private func performCheck() {
        // Double check preconditions
        guard isScreenLocked && isDisplayOn else {
            stopMonitoring()
            return
        }
        
        let isSiriActive = detectSiriWindow()
        
        if isSiriActive {
            disappearanceConfirmations = 0
            if !isSiriVisible {
                setSiriVisible(true)
                // Instantly speed up polling rate to track dismissal
                startMonitoring()
            }
        } else {
            if isSiriVisible {
                disappearanceConfirmations += 1
                if disappearanceConfirmations >= disappearanceThreshold {
                    setSiriVisible(false)
                    disappearanceConfirmations = 0
                    // Drop back to slow polling rate
                    startMonitoring()
                }
            }
        }
    }

    private func detectSiriWindow() -> Bool {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        
        return windowList.contains { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let bounds = window[kCGWindowBounds as String] as? [String: Int] ?? [:]
            let height = bounds["Height"] ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Float ?? 1.0
            
            // Siri is owner "Siri" or Apple Intelligence "CampoRemoteService". Layer 23 is the Siri layer.
            let isSiri = (owner == "Siri" || owner == "CampoRemoteService") && layer == 23
            let isVisible = alpha > 0.1 && height > 400
            
            return isSiri && isVisible
        }
    }

    private func setSiriVisible(_ visible: Bool) {
        guard isSiriVisible != visible else { return }
        isSiriVisible = visible
        print("👁️ [SiriVisibilityMonitor] isSiriVisible = \(visible)")
    }

    func autohide(_ window: NSWindow?, cancellables: inout Set<AnyCancellable>) {
        guard let window else { return }

        Publishers.CombineLatest($isSiriVisible, LockScreenManager.shared.$isLocked)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main)
            .sink { isVisible, isLocked in
                guard isLocked else { return }
                
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
            .store(in: &cancellables)
    }
}
