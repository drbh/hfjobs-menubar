import Foundation
import Combine
import SwiftUI

// Observable object to track metrics updates
class MetricsObservable: ObservableObject {
    @Published var currentMetrics: HFJobMetrics?
    @Published var metricsHistory: [Date: HFJobMetrics] = [:]
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // Maximum number of historical metrics to keep
    private let maxHistoryPoints = 60 // Keep about 5 minutes of data with ~5s intervals
    
    init() {
        self.isLoading = true
    }
    
    func update(metrics: HFJobMetrics) {
        DispatchQueue.main.async {
            self.currentMetrics = metrics
            
            // Add to history with current timestamp
            let now = Date()
            self.metricsHistory[now] = metrics
            
            // Trim history if needed
            if self.metricsHistory.count > self.maxHistoryPoints {
                // Remove oldest entries
                let sortedKeys = self.metricsHistory.keys.sorted()
                let keysToRemove = sortedKeys.prefix(self.metricsHistory.count - self.maxHistoryPoints)
                for key in keysToRemove {
                    self.metricsHistory.removeValue(forKey: key)
                }
            }
            
            self.isLoading = false
            self.errorMessage = nil
        }
    }
    
    func setError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isLoading = false
        }
    }
    
    func reset() {
        DispatchQueue.main.async {
            self.currentMetrics = nil
            self.metricsHistory.removeAll()
            self.isLoading = true
            self.errorMessage = nil
        }
    }
    
    // Get data for charts in time series format
    func getTimeSeriesData() -> [ChartDataPoint] {
        let sortedData = metricsHistory.sorted { $0.key < $1.key }
        return sortedData.map { (date, metrics) in
            ChartDataPoint(
                timestamp: date,
                cpuUsage: metrics.cpuUsagePct,
                memoryUsage: metrics.memoryUsagePercent,
                gpuUtilization: metrics.gpus.first?.value.gpuUtilization ?? 0
            )
        }
    }
}

// Data point structure for charts
struct ChartDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cpuUsage: Double
    let memoryUsage: Double
    let gpuUtilization: Double
}

// MARK: - Job Metrics Stream Handler
class JobMetricsStreamHandler: JobMetricsStreamDelegate {
    private var metricsObservable: MetricsObservable
    private var hasReceivedMetrics = false
    private let decoder = JSONDecoder()
    
    init(metricsObservable: MetricsObservable) {
        self.metricsObservable = metricsObservable
    }
    
    func didReceiveMetrics(_ metrics: HFJobMetrics) {
        if !hasReceivedMetrics {
            hasReceivedMetrics = true
        }
        
        metricsObservable.update(metrics: metrics)
    }

    func didReceiveMetricsData(_ jsonString: String) {
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("❌ Could not convert metrics JSON string to data")
            return
        }
        
        do {
            let metrics = try decoder.decode(HFJobMetrics.self, from: jsonData)
            if !hasReceivedMetrics {
                hasReceivedMetrics = true
            }
            metricsObservable.update(metrics: metrics)
        } catch {
            print("❌ Failed to decode metrics JSON: \(error)")
            print("📝 JSON data: \(jsonString)")
        }
    }
    
    func didEncounterError(_ error: Error) {
        let errorMessage = JobService.shared.errorMessage(for: error)
        metricsObservable.setError(errorMessage)
    }
    
    func didCompleteStream() {
        if !hasReceivedMetrics {
            metricsObservable.setError("No metrics received. The job may not have started or doesn't support metrics.")
        }
    }
}