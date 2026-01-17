//
//  VideoDebugLogger.swift
//  SoftBurn
//
//  Debug logging infrastructure for video playback.
//  Enable via UserDefaults key "debugVideoPlayback".
//

import Foundation

/// Centralized debug logger for video playback diagnostics
enum VideoDebugLogger {

    /// Check if debug logging is enabled
    static var isEnabled: Bool {
        #if DEBUG
            return UserDefaults.standard.bool(forKey: "debugVideoPlayback")
        #else
            return false
        #endif
    }

    /// Log a debug message with file/line info
    /// - Parameters:
    ///   - message: The message to log
    ///   - file: Source file (auto-captured)
    ///   - line: Source line (auto-captured)
    static func log(_ message: String, file: String = #file, line: Int = #line) {
        guard isEnabled else { return }

        let filename = (file as NSString).lastPathComponent
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("[\(timestamp)] [Video] \(filename):\(line) - \(message)")
    }

    /// Log a status change for a player
    static func logStatusChange(
        slot: String,
        oldStatus: String,
        newStatus: String,
        bufferState: String
    ) {
        log("\(slot): status \(oldStatus) -> \(newStatus), buffer: \(bufferState)")
    }

    /// Log an error with context
    static func logError(_ error: Error, context: String, file: String = #file, line: Int = #line) {
        log("ERROR in \(context): \(error.localizedDescription)", file: file, line: line)
    }

    /// Log video loading start
    static func logLoadStart(source: String, identifier: String) {
        log("Loading video from \(source): \(identifier)")
    }

    /// Log video loading completion
    static func logLoadComplete(
        identifier: String, duration: Double, size: CGSize, rotation: Int
    ) {
        log(
            "Loaded: duration=\(String(format: "%.1f", duration))s, size=\(Int(size.width))x\(Int(size.height)), rotation=\(rotation)°"
        )
    }

    /// Log texture sampling for Metal path
    static func logTextureSample(slot: String, hasNewFrame: Bool, itemTime: Double) {
        // Only log occasionally to avoid flooding
        #if DEBUG
            if Int(itemTime * 10) % 50 == 0 {  // Log every ~5 seconds
                log("\(slot) texture: newFrame=\(hasNewFrame), time=\(String(format: "%.2f", itemTime))s")
            }
        #endif
    }

    // MARK: - Private

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Enable/Disable Helpers

extension VideoDebugLogger {

    /// Enable debug logging
    static func enable() {
        #if DEBUG
            UserDefaults.standard.set(true, forKey: "debugVideoPlayback")
            print("[Video] Debug logging ENABLED")
        #endif
    }

    /// Disable debug logging
    static func disable() {
        #if DEBUG
            UserDefaults.standard.set(false, forKey: "debugVideoPlayback")
            print("[Video] Debug logging DISABLED")
        #endif
    }
}
