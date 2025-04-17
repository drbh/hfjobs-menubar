import Foundation
import Combine

// MARK: - Metrics Data Models

/// Structure to represent job metrics data
struct HFJobMetrics: Codable, Equatable {
    let cpuUsagePct: Double
    let cpuMillicores: Int
    let memoryUsedBytes: Int
    let memoryTotalBytes: Int
    let rxBps: Int
    let txBps: Int
    let gpus: [String: GPUMetrics]
    let replica: String
    
    // Computed properties for formatting
    var memoryUsedFormatted: String {
        return formatBytes(memoryUsedBytes)
    }
    
    var memoryTotalFormatted: String {
        return formatBytes(memoryTotalBytes)
    }
    
    var memoryUsagePercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100.0
    }
    
    var networkRxFormatted: String {
        return formatBitsPerSecond(rxBps * 8) // Convert bytes to bits
    }
    
    var networkTxFormatted: String {
        return formatBitsPerSecond(txBps * 8) // Convert bytes to bits
    }
    
    // Coding keys for JSON decoding
    enum CodingKeys: String, CodingKey {
        case cpuUsagePct = "cpu_usage_pct"
        case cpuMillicores = "cpu_millicores"
        case memoryUsedBytes = "memory_used_bytes"
        case memoryTotalBytes = "memory_total_bytes"
        case rxBps = "rx_bps"
        case txBps = "tx_bps"
        case gpus
        case replica
    }
    
    // Helper formatting functions
    private func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var convertedValue = Double(bytes)
        var unitIndex = 0
        
        while convertedValue >= 1024 && unitIndex < units.count - 1 {
            convertedValue /= 1024
            unitIndex += 1
        }
        
        return String(format: "%.2f %@", convertedValue, units[unitIndex])
    }
    
    private func formatBitsPerSecond(_ bps: Int) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var convertedValue = Double(bps)
        var unitIndex = 0
        
        while convertedValue >= 1000 && unitIndex < units.count - 1 {
            convertedValue /= 1000
            unitIndex += 1
        }
        
        return String(format: "%.2f %@", convertedValue, units[unitIndex])
    }
}

/// Structure to represent GPU metrics
struct GPUMetrics: Codable, Equatable {
    let gpuUtilization: Double?
    let memoryUtilization: Double?
    let memoryUsedBytes: Int?
    let memoryTotalBytes: Int?
    let temperature: Double?
    
    // Computed properties for formatting
    var memoryUsedFormatted: String {
        guard let bytes = memoryUsedBytes else { return "N/A" }
        return formatBytes(bytes)
    }
    
    var memoryTotalFormatted: String {
        guard let bytes = memoryTotalBytes else { return "N/A" }
        return formatBytes(bytes)
    }
    
    var temperatureFormatted: String {
        guard let temp = temperature else { return "N/A" }
        return String(format: "%.1f°C", temp)
    }
    
    // Coding keys for JSON decoding
    enum CodingKeys: String, CodingKey {
        case gpuUtilization = "gpu_utilization"
        case memoryUtilization = "memory_utilization"
        case memoryUsedBytes = "memory_used_bytes"
        case memoryTotalBytes = "memory_total_bytes"
        case temperature
    }
    
    // Helper formatting function
    private func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var convertedValue = Double(bytes)
        var unitIndex = 0
        
        while convertedValue >= 1024 && unitIndex < units.count - 1 {
            convertedValue /= 1024
            unitIndex += 1
        }
        
        return String(format: "%.2f %@", convertedValue, units[unitIndex])
    }
}

// Delegate protocol for metrics stream
protocol JobMetricsStreamDelegate: AnyObject {
    func didReceiveMetrics(_ metrics: HFJobMetrics)
    func didReceiveMetricsData(_ jsonString: String)
    func didEncounterError(_ error: Error)
    func didCompleteStream()
}



// MARK: - Metrics Service Class
class MetricsService: NSObject, URLSessionDataDelegate {
    static let shared = MetricsService()
    
    private override init() {
        super.init()
    }
    
    private var urlSession: URLSession?
    private var isStreamingActive = false
    private var metricsStreamTask: URLSessionDataTask?
    private var buffer = Data()
    private var currentDelegate: JobMetricsStreamDelegate?
    private var metricsStarted = false
    private var currentJobId = ""
    
    // Streaming metrics implementation
    func streamJobMetrics(jobId: String, delegate: JobMetricsStreamDelegate) -> String {
        // If already streaming this job, don't start another stream
        if isStreamingActive {
            print("🚫 Already streaming metrics for job \(jobId)...")
            return "Already streaming metrics for job \(jobId)..."
        }
        
        isStreamingActive = true
        currentDelegate = delegate
        currentJobId = jobId
        
        guard let token = AppSettings.shared.token, !token.isEmpty else {
            print("❌ No token available")
            delegate.didEncounterError(JobServiceError.noToken)
            isStreamingActive = false
            return "No token available."
        }
        
        guard let username = AppSettings.shared.username, !username.isEmpty else {
            print("❌ No username available")
            delegate.didEncounterError(JobServiceError.noUsername)
            isStreamingActive = false
            return "No username available."
        }
        
        print("🔥 Starting metrics stream for job \(jobId)...")
        
        // First verify the job exists
        Task {
            do {
                print("🔍 Verifying job exists...")
                let _ = try await JobService.shared.fetchJobById(jobId: jobId)
                self.startMetricsStream(username: username, jobId: jobId)
            } catch {
                print("❌ Error verifying job: \(error)")
                delegate.didEncounterError(error)
                self.isStreamingActive = false
            }
        }
        
        return "Connecting to metrics stream..."
    }
    
    private func startMetricsStream(username: String, jobId: String) {
        print("📡 Creating metrics stream request...")
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/metrics-stream") else {
            print("❌ Invalid URL")
            currentDelegate?.didEncounterError(JobServiceError.invalidURL)
            isStreamingActive = false
            return
        }
        
        // Create a dedicated session with a delegate for better stream handling
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 300 // 5 minutes
        sessionConfig.timeoutIntervalForResource = 3600 // 1 hour
        urlSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: .main)
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(AppSettings.shared.token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("hfjobs-swift", forHTTPHeaderField: "X-Library-Name")
        

        // Cancel any existing task
        metricsStreamTask?.cancel()
        
        // Create and start a new task
        metricsStreamTask = urlSession?.dataTask(with: request)
        metricsStreamTask?.resume()
        
        // For debugging: Check again after 5 seconds if we're receiving data
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if !self.metricsStarted {
                print("⚠️ No metrics received after 5 seconds")
                print("🔍 Checking connection status...")
                if let task = self.metricsStreamTask {
                    print("📊 Task state: \(task.state.rawValue)")
                }
            }
        }
    }
    
    // MARK: - URLSessionDataDelegate Methods
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            
            guard httpResponse.statusCode == 200 else {
                print("❌ HTTP error: \(httpResponse.statusCode)")
                currentDelegate?.didEncounterError(JobServiceError.httpError(httpResponse.statusCode))
                isStreamingActive = false
                completionHandler(.cancel)
                return
            }
            
            // Check content type is SSE
            if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String,
               contentType.contains("text/event-stream") {
                print("✅ Confirmed SSE content type: \(contentType)")
            } else {
                print("⚠️ Unexpected content type: \(httpResponse.allHeaderFields["Content-Type"] ?? "unknown")")
            }
        }
        
        // Accept this response and continue
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        print("📦 Received \(data.count) bytes of data")
        
        // Print raw data as string for debugging
        if let rawString = String(data: data, encoding: .utf8) {
            print("📝 Raw data: \(rawString)")
        }
        
        // Add to buffer and process
        buffer.append(data)
        processBuffer()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("❌ Stream task completed with error: \(error)")
            
            if (error as NSError).domain == NSURLErrorDomain {
                print("🔍 URL error code: \((error as NSError).code)")
            }
            
            // Check job status before deciding what to do
            Task {
                do {
                    let job = try await JobService.shared.fetchJobById(jobId: currentJobId)
                    let status = job.status.stage
                    
                    if status != "RUNNING" && status != "UPDATING" {
                        print("🏁 Job is no longer running (status: \(status))")
                        currentDelegate?.didCompleteStream()
                        isStreamingActive = false
                    } else if !metricsStarted {
                        print("🔄 Job still running but metrics stream failed - retrying in 3 seconds")
                        // Retry after delay if the job is still running
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self = self, let username = AppSettings.shared.username else { return }
                            self.startMetricsStream(username: username, jobId: self.currentJobId)
                        }
                    } else {
                        currentDelegate?.didEncounterError(JobServiceError.networkError(error))
                        isStreamingActive = false
                    }
                } catch {
                    print("❌ Error checking job status: \(error)")
                    currentDelegate?.didEncounterError(error)
                    isStreamingActive = false
                }
            }
        } else {
            print("✅ Stream task completed normally")
            currentDelegate?.didCompleteStream()
            isStreamingActive = false
        }
    }
    
    private func processBuffer() {
        // Look for complete lines in the buffer (terminated by \n)
        while let newlineIndex = buffer.firstIndex(of: 10) { // ASCII for '\n'
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer = buffer.suffix(from: newlineIndex + 1)
            
            // Convert line data to string
            if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                
                // Handle "event: metric" line
                if line == "event: metric" {
                    continue
                }
                
                // Handle data line
                if line.hasPrefix("data: ") {
                    let jsonStart = line.index(line.startIndex, offsetBy: "data: ".count)
                    let jsonString = String(line[jsonStart...])
                    
                    metricsStarted = true
                    
                    // Try to decode the metrics directly for efficiency
                    if let jsonData = jsonString.data(using: .utf8) {
                        do {
                            let decoder = JSONDecoder()
                            let metrics = try decoder.decode(HFJobMetrics.self, from: jsonData)
                            
                            // Notify delegate of parsed metrics on main thread
                            DispatchQueue.main.async { [weak self] in
                                self?.currentDelegate?.didReceiveMetrics(metrics)
                            }
                        } catch {
                            print("❌ Error decoding metrics: \(error)")
                            
                            // If we can't decode directly, pass the raw JSON string
                            DispatchQueue.main.async { [weak self] in
                                self?.currentDelegate?.didReceiveMetricsData(jsonString)
                            }
                        }
                    } else {
                        print("❌ Could not convert metrics JSON string to data")
                        
                        // Fallback to raw string if data conversion fails
                        DispatchQueue.main.async { [weak self] in
                            self?.currentDelegate?.didReceiveMetricsData(jsonString)
                        }
                    }
                } else if line == ": keep-alive" {
                    print("🔄 Received keep-alive")
                } else if !line.isEmpty {
                    print("❓ Unknown line format: \(line)")
                }
            }
        }
    }
    
    func cancelMetricsStream() {
        print("🛑 Cancelling metrics stream")
        metricsStreamTask?.cancel()
        metricsStreamTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isStreamingActive = false
    }
    
    // Fetch metrics for a job
    func fetchMetrics(jobId: String) async throws -> HFJobMetrics {
        guard let token = AppSettings.shared.token, !token.isEmpty else {
            throw JobServiceError.noToken
        }
        
        guard let username = AppSettings.shared.username, !username.isEmpty else {
            throw JobServiceError.noUsername
        }
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/metrics") else {
            throw JobServiceError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("hfjobs-swift", forHTTPHeaderField: "X-Library-Name")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JobServiceError.unknown
            }
            
            guard httpResponse.statusCode == 200 else {
                throw JobServiceError.httpError(httpResponse.statusCode)
            }
            
            let decoder = JSONDecoder()
            let metrics = try decoder.decode(HFJobMetrics.self, from: data)
            return metrics
        } catch let error as JobServiceError {
            throw error
        } catch let error as URLError {
            throw JobServiceError.networkError(error)
        } catch {
            throw error
        }
    }
    
    // Helper method to format error messages
    func errorMessage(for error: Error) -> String {
        switch error {
        case JobServiceError.noToken:
            return "No API token found. Please add your Hugging Face token."
        case JobServiceError.noUsername:
            return "No username found. Please add your Hugging Face username."
        case JobServiceError.invalidURL:
            return "Invalid API URL. Please check your network connection."
        case JobServiceError.httpError(let statusCode):
            switch statusCode {
            case 401: return "Authentication failed. Please check your API token."
            case 404: return "User or job not found. Please check your username and job ID."
            case 429: return "Too many requests. Please try again later."
            case 500...599: return "Server error. Please try again later."
            default: return "HTTP error: \(statusCode)"
            }
        case JobServiceError.networkError:
            return "Network error. Please check your internet connection."
        default:
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}