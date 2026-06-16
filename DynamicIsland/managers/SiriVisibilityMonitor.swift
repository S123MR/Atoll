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
import ApplicationServices  // AXObserver, AXUIElement

// MARK: - C callback (file scope; cannot be a member or capture state)

private let siriAXCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let monitor = Unmanaged<SiriVisibilityMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let name = notification as String
    
    // Callbacks fire on the main thread (we added the source to CFRunLoopGetMain),
    // but Task {@MainActor} makes the intent explicit and satisfies strict concurrency.
    Task { @MainActor in
        monitor.handleAXNotification(element, name: name)
    }
}

// MARK: - Monitor

@MainActor
final class SiriVisibilityMonitor: ObservableObject {

    static let shared = SiriVisibilityMonitor()

    @Published private(set) var isSiriVisible = false

    // AX state
    private var axObserver: AXObserver?
    private var siriAppElement: AXUIElement?
    private var trackedWindowElement: AXUIElement?   // the specific Siri window we're watching

    // Screen / display state (same as before)
    private var isScreenLocked = false
    private var isDisplayOn = true
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupStateObservers()
    }

    // MARK: - State observers (lock + display, unchanged)

    private func setupStateObservers() {
        LockScreenManager.shared.$isLocked
            .receive(on: RunLoop.main)
            .sink { [weak self] locked in
                self?.isScreenLocked = locked
                self?.updateMonitoringState()
            }
            .store(in: &cancellables)

        let wsCenter = NSWorkspace.shared.notificationCenter

        wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isDisplayOn = false
            self?.updateMonitoringState()
        }
        wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isDisplayOn = true
            self?.updateMonitoringState()
        }

        // If Siri launches after we start (rare but possible), attach then.
        wsCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: RunLoop.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier == "com.apple.Siri" }
            .sink { [weak self] app in
                guard self?.isScreenLocked == true, self?.isDisplayOn == true else { return }
                self?.attachAXObserver(to: app.processIdentifier)
            }
            .store(in: &cancellables)

        // If Siri's process restarts, tear down the stale observer and re-attach.
        wsCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: RunLoop.main)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier == "com.apple.Siri" }
            .sink { [weak self] _ in
                self?.teardownAXObserver()
                self?.isSiriVisible = false
            }
            .store(in: &cancellables)
    }

    // MARK: - Monitoring lifecycle

    private func updateMonitoringState() {
        if isScreenLocked && isDisplayOn {
            startMonitoring()
        } else {
            stopMonitoring()
            if isSiriVisible { isSiriVisible = false }
        }
    }

    private func startMonitoring() {
        guard axObserver == nil else { return }   // already attached

        guard AXIsProcessTrusted() else {
            print("⚠️ [SiriVisibilityMonitor] Accessibility permission not granted.")
            return
        }

        let bundleID = "com.apple.Siri"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            attachAXObserver(to: app.processIdentifier)
        } else {
            // Siri isn't running yet; the didLaunchApplication observer will handle it.
            print("ℹ️ [SiriVisibilityMonitor] Siri not running; will attach on launch.")
        }
    }

    func stopMonitoring() {
        teardownAXObserver()
    }

    // MARK: - AXObserver setup / teardown

    private func attachAXObserver(to pid: pid_t) {
        teardownAXObserver()

        var obs: AXObserver?
        let result = AXObserverCreate(pid, siriAXCallback, &obs)

        guard result == .success, let obs else {
            print("⚠️ [SiriVisibilityMonitor] AXObserverCreate failed (err \(result.rawValue)). Is Accessibility granted?")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Window creation — fires when any Siri window appears.
        AXObserverAddNotification(obs, appElement, kAXWindowCreatedNotification as CFString, selfPtr)

        // Hidden/deactivated — belt-and-suspenders for when the window is hidden
        // rather than destroyed (e.g. Siri collapses without fully tearing down the element).
        AXObserverAddNotification(obs, appElement, kAXApplicationHiddenNotification as CFString, selfPtr)

        // Wire the observer into the main RunLoop. No background thread needed —
        // the main RunLoop is already running and this is an @MainActor class.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        axObserver = obs
        siriAppElement = appElement
        print("✅ [SiriVisibilityMonitor] AXObserver attached (Siri PID \(pid))")
        
        // Initial check: if Siri is already visible when we attach
        checkInitialVisibility(pid)
    }
    
    private func checkInitialVisibility(_ pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        var windows: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)
        
        if result == .success, let windowList = windows as? [AXUIElement], !windowList.isEmpty {
            // Assume the first window is the Siri overlay
            if let firstWindow = windowList.first {
                subscribeToWindowDestruction(firstWindow)
                setSiriVisible(true)
            }
        }
    }

    private func teardownAXObserver() {
        guard let obs = axObserver, let appEl = siriAppElement else { return }

        AXObserverRemoveNotification(obs, appEl, kAXWindowCreatedNotification as CFString)
        AXObserverRemoveNotification(obs, appEl, kAXApplicationHiddenNotification as CFString)

        if let winEl = trackedWindowElement {
            AXObserverRemoveNotification(obs, winEl, kAXUIElementDestroyedNotification as CFString)
            trackedWindowElement = nil
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = nil
        siriAppElement = nil
        print("🔴 [SiriVisibilityMonitor] AXObserver detached")
    }

    // MARK: - Called back from the C callback

    fileprivate func handleAXNotification(_ element: AXUIElement, name: String) {
        switch name {
        case kAXWindowCreatedNotification as String:
            // `element` IS the new window (not the app element).
            // Subscribe to its destruction so we know precisely when it's gone.
            subscribeToWindowDestruction(element)
            setSiriVisible(true)

        case kAXUIElementDestroyedNotification as String:
            // The specific window we were tracking was destroyed.
            trackedWindowElement = nil
            setSiriVisible(false)

        case kAXApplicationHiddenNotification as String:
            // Siri hidden at the app level (belt-and-suspenders).
            setSiriVisible(false)

        default:
            break
        }
    }

    private func subscribeToWindowDestruction(_ windowElement: AXUIElement) {
        guard let obs = axObserver else { return }

        // Unsubscribe from any previous window first.
        if let prev = trackedWindowElement {
            AXObserverRemoveNotification(obs, prev, kAXUIElementDestroyedNotification as CFString)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, windowElement, kAXUIElementDestroyedNotification as CFString, selfPtr)
        trackedWindowElement = windowElement
    }

    private func setSiriVisible(_ visible: Bool) {
        guard isSiriVisible != visible else { return }
        isSiriVisible = visible
        print("👁️ [SiriVisibilityMonitor] isSiriVisible = \(visible)")
    }

    // MARK: - autohide (unchanged — all 5 manager files keep their existing call)

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
