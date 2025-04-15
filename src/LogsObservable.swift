import Foundation
import Combine
import SwiftUI
import OSLog

// Observable object to track logs updates
class LogsObservable: ObservableObject {
    @Published var currentLogs: HFJobLogs?
    @Published var logsHistory: [Date: HFJobLogs] = [:]
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // Maximum number of historical log entries to keep
    private let maxHistoryPoints = 1000
    
    init() {
        self.isLoading = true
    }
    
    func update(logs: HFJobLogs) {
        DispatchQueue.main.async {
            self.currentLogs = logs
            
            // Add to history with current timestamp
            let now = Date()
            self.logsHistory[now] = logs
            
            // Trim history if needed
            if self.logsHistory.count > self.maxHistoryPoints {
                // Remove oldest entries
                let sortedKeys = self.logsHistory.keys.sorted()
                let keysToRemove = sortedKeys.prefix(self.logsHistory.count - self.maxHistoryPoints)
                for key in keysToRemove {
                    self.logsHistory.removeValue(forKey: key)
                }
            }
            
            self.isLoading = false
            self.errorMessage = nil
            
            print("📋 Updated logs: \(logs.logEntries.count) entries")
        }
    }
    
    func setError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isLoading = false
            print("❌ Logs error: \(message)")
        }
    }
    
    func reset() {
        DispatchQueue.main.async {
            self.currentLogs = nil
            self.logsHistory.removeAll()
            self.isLoading = true
            self.errorMessage = nil
            print("🔄 Reset logs observable")
        }
    }
}

// MARK: - Job Logs Stream Handler
class JobLogsStreamHandler: JobLogsStreamDelegate {
    var logsObservable: LogsObservable
    var logBuffer: [LogEntry] = []
    var hasReceivedLogs = false
    
    init(logsObservable: LogsObservable) {
        self.logsObservable = logsObservable
        print("🔄 Initialized logs stream handler")
    }
    
    // Convert individual log line to proper structure and update the observable
    func didReceiveLogLine(_ line: String, timestamp: Date?) {
        if !hasReceivedLogs {
            hasReceivedLogs = true
            print("✅ Received first log line")
        }
        
        // Convert Date to timestamp string if available
        let timestampString: String
        if let timestamp = timestamp {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            timestampString = formatter.string(from: timestamp)
        } else {
            timestampString = ""
        }
        
        print("📄 Log line: \(line.prefix(50))...")
        
        // Add to log buffer
        logBuffer.append(LogEntry(timestamp: timestampString, message: line))
        
        // Update the observable with the new entries
        let jobLogs = HFJobLogs(logEntries: logBuffer)
        logsObservable.update(logs: jobLogs)
    }
    
    func didEncounterError(_ error: Error) {
        let errorMessage = JobService.shared.errorMessage(for: error)
        print("❌ Logs stream error: \(errorMessage)")
        logsObservable.setError(errorMessage)
    }
    
    func didCompleteStream() {
        print("🏁 Logs stream completed")
        if !hasReceivedLogs {
            logsObservable.setError("No logs received. The job may not have started or doesn't support logs.")
        }
    }
    
    // Helper function to update logs with a message
    func updateLogsWithMessage(_ message: String) {
        print("ℹ️ Updated logs with message: \(message)")
        logBuffer = [LogEntry(timestamp: "", message: message)]
        let jobLogs = HFJobLogs(logEntries: logBuffer)
        logsObservable.update(logs: jobLogs)
    }
}