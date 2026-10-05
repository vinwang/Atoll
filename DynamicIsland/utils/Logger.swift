/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import Foundation
import OSLog
import SwiftUI
import Defaults

enum LogCategory: String {
    case lifecycle = "🔄"
    case memory = "💾"
    case performance = "⚡️"
    case ui = "🎨"
    case network = "🌐"
    case error = "❌"
    case warning = "⚠️"
    case success = "✅"
    case debug = "🔍"
    case extensions = "🧩"

    var osCategoryName: String {
        switch self {
        case .lifecycle: return "lifecycle"
        case .memory: return "memory"
        case .performance: return "performance"
        case .ui: return "ui"
        case .network: return "network"
        case .error: return "error"
        case .warning: return "warning"
        case .success: return "success"
        case .debug: return "debug"
        case .extensions: return "extensions"
        }
    }

    var defaultLevel: LogLevel {
        switch self {
        case .error: return .error
        case .warning: return .warning
        case .success, .ui, .network, .lifecycle, .memory, .performance, .extensions: return .info
        case .debug: return .debug
        }
    }
}

struct Logger {
    private static let subsystem = "com.ebullioscopic.Atoll"
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dateFormatterLock = NSLock()
    private static var osLoggerCache: [LogCategory: OSLog] = [:]
    private static let cacheLock = NSLock()

    private static func osLogger(for category: LogCategory) -> OSLog {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = osLoggerCache[category] {
            return cached
        }
        let logger = OSLog(subsystem: subsystem, category: category.osCategoryName)
        osLoggerCache[category] = logger
        return logger
    }

    static func log(
        _ message: String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let configuredLevel = Defaults[.logLevel]
        if configuredLevel == .none || category.defaultLevel.rawValue > configuredLevel.rawValue {
            return
        }

        let fileName = (file as NSString).lastPathComponent
        dateFormatterLock.lock()
        let timestamp = dateFormatter.string(from: Date())
        dateFormatterLock.unlock()
        let entry = "\(category.rawValue) [\(timestamp)] [\(fileName):\(line)] \(function) - \(message)"
        let logger = osLogger(for: category)
        os_log("%{public}@", log: logger, type: .default, entry)

#if DEBUG
        Swift.print(entry)
#endif
    }
    
    static func trackMemory(
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1024.0 / 1024.0
            log(String(format: "Memory used: %.2f MB", usedMB),
                category: .memory,
                file: file,
                function: function,
                line: line)
        }
    }
}

/// Records when the main run loop stops servicing work. This is deliberately
/// small: it helps distinguish an Atoll main-thread stall from a WindowServer
/// or kernel freeze without adding a sampling thread or a new logging system.
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()

    private let lock = NSLock()
    private var lastHeartbeat = DispatchTime.now().uptimeNanoseconds
    private var hasReportedStall = false
    private var started = false
    private var checkTimer: DispatchSourceTimer?

    private init() {}

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        scheduleHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.checkHeartbeat() }
        checkTimer = timer
        timer.resume()
    }

    private func scheduleHeartbeat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastHeartbeat = DispatchTime.now().uptimeNanoseconds
            let recovered = self.hasReportedStall
            self.hasReportedStall = false
            self.lock.unlock()
            if recovered {
                Logger.log("[Diagnostics] Main thread responsive again", category: .performance)
            }
            self.scheduleHeartbeat()
        }
    }

    private func checkHeartbeat() {
        lock.lock()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastHeartbeat
        let shouldReport = elapsed >= 1_000_000_000 && !hasReportedStall
        if shouldReport { hasReportedStall = true }
        lock.unlock()

        guard shouldReport else { return }
        Logger.log(
            String(format: "[Diagnostics] Main thread stalled for %.2fs", Double(elapsed) / 1_000_000_000),
            category: .warning
        )
    }
}

extension View {
    func trackLifecycle(_ identifier: String) -> some View {
        self.modifier(ViewLifecycleTracker(identifier: identifier))
    }
}

struct ViewLifecycleTracker: ViewModifier {
    let identifier: String
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                Logger.log("\(identifier) appeared", category: .lifecycle)
                Logger.trackMemory()
            }
            .onDisappear {
                Logger.log("\(identifier) disappeared", category: .lifecycle)
                Logger.trackMemory()
            }
    }
}

// Global overrides to filter scattered print and NSLog statements throughout the app

public func NSLog(_ format: String, _ args: CVarArg...) {
    let configuredLevel = Defaults[.logLevel]
    if configuredLevel == .none { return }
    
    let message = String(format: format, arguments: args)
    let lowerMessage = message.lowercased()
    
    let isError = message.contains("❌") || lowerMessage.contains("error") || lowerMessage.contains("failed")
    let isWarning = message.contains("⚠️") || lowerMessage.contains("warning")
    
    let simulatedLevel: LogLevel = isError ? .error : (isWarning ? .warning : .debug)
    
    if simulatedLevel.rawValue > configuredLevel.rawValue { return }
    
    Foundation.NSLog("%@", message)
}
