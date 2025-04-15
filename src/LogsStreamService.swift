import Foundation
import OSLog

// Define the log entry structure
struct LogEntry: Equatable {
    let timestamp: String
    let message: String
}

// Define the job logs structure
struct HFJobLogs: Equatable {
    let logEntries: [LogEntry]
}

// Define the delegate protocol
protocol JobLogsStreamDelegate: AnyObject {
    func didReceiveLogLine(_ line: String, timestamp: Date?)
    func didEncounterError(_ error: Error)
    func didCompleteStream()
}

// Logs Stream Service
class LogsStreamService: NSObject, URLSessionDataDelegate {
    static let shared = LogsStreamService()
    
    private var urlSession: URLSession?
    private var logStreamTask: URLSessionDataTask?
    private var buffer = Data()
    private var isStreamingActive = false
    private var logsStarted = false
    private var currentJobId = ""
    private var currentDelegate: JobLogsStreamDelegate?
    private var includeTimestamps = false
    
    private override init() {
        super.init()
    }
    
    // Streaming logs implementation
    func streamJobLogs(jobId: String, includeTimestamps: Bool, delegate: JobLogsStreamDelegate) -> String {
        // If already streaming this job, don't start another stream
        if isStreamingActive && currentJobId == jobId {
            print("🚫 Already streaming logs for job \(jobId)...")
            return "Already streaming logs for job \(jobId)..."
        }
        
        // Clean up any existing stream before starting a new one
        if isStreamingActive {
            cancelLogStream()
        }
        
        isStreamingActive = true
        currentDelegate = delegate
        currentJobId = jobId
        self.includeTimestamps = includeTimestamps
        
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
        
        print("📜 Starting logs stream for job \(jobId)...")
        
        // First verify the job exists
        Task {
            do {
                print("🔍 Verifying job exists...")
                let _ = try await JobService.shared.fetchJobById(jobId: jobId)
                self.startLogStream(username: username, jobId: jobId)
            } catch {
                print("❌ Error verifying job: \(error)")
                delegate.didEncounterError(error)
                self.isStreamingActive = false
            }
        }
        
        return "Connecting to log stream..."
    }
    
    private func startLogStream(username: String, jobId: String) {
        print("📡 Creating logs stream request...")
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/logs-stream") else {
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
        logStreamTask?.cancel()
        
        // Create and start a new task
        logStreamTask = urlSession?.dataTask(with: request)
        logStreamTask?.resume()
        
        // For debugging: Check again after 5 seconds if we're receiving data
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if !self.logsStarted {
                if let task = self.logStreamTask {
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
        print("📦 Received \(data.count) bytes of log data")
        
        // Print raw data as string for debugging (limited characters)
        if let rawString = String(data: data, encoding: .utf8) {
            let preview = String(rawString.prefix(100))
            print("📝 Log data preview: \(preview)...")
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
                    } else if !logsStarted {
                        print("🔄 Job still running but logs stream failed - retrying in 3 seconds")
                        // Retry after delay if the job is still running
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self = self, let username = AppSettings.shared.username else { return }
                            self.startLogStream(username: username, jobId: self.currentJobId)
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

                // Handle "event: log" line
                if line == "event: log" {
                    continue
                }
                
                // Handle data line
                if line.hasPrefix("data: ") {
                    let jsonStart = line.index(line.startIndex, offsetBy: "data: ".count)
                    let jsonString = String(line[jsonStart...])
                    
                    // print("🧩 JSON: \(jsonString)")
                    logsStarted = true
                    
                    // Try to decode the log entry
                    if let jsonData = jsonString.data(using: .utf8) {
                        do {
                            let decoder = JSONDecoder()
                            let logEntry = try decoder.decode(JobLogEntry.self, from: jsonData)
                            
                            // Skip "Job started" messages as per original implementation
                            if !logEntry.data.hasPrefix("===== Job started") {
                                let timestamp: Date? = includeTimestamps ? {
                                    let dateFormatter = ISO8601DateFormatter()
                                    return dateFormatter.date(from: logEntry.timestamp)
                                }() : nil
                                
                                // Notify delegate on main thread
                                DispatchQueue.main.async { [weak self] in
                                    self?.currentDelegate?.didReceiveLogLine(logEntry.data, timestamp: timestamp)
                                }
                            }
                        } catch {
                            os_log("❌ Error decoding log entry: %@", error.localizedDescription)
                            print("❌ Error decoding log JSON: \(error), JSON: \(jsonString)")
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
    
    func cancelLogStream() {
        print("🛑 Cancelling log stream")
        logStreamTask?.cancel()
        logStreamTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isStreamingActive = false
        logsStarted = false
    }
    
    // Fetch complete logs for a job (non-streaming)
    func fetchLogs(jobId: String) async throws -> HFJobLogs {
        guard let token = AppSettings.shared.token, !token.isEmpty else {
            throw JobServiceError.noToken
        }
        
        guard let username = AppSettings.shared.username, !username.isEmpty else {
            throw JobServiceError.noUsername
        }
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/logs") else {
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
            
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw JobServiceError.unknown
            }
            
            // Parse log entries
            let logEntries = parseLogEntries(from: responseString)
            return HFJobLogs(logEntries: logEntries)
        } catch let error as JobServiceError {
            throw error
        } catch let error as URLError {
            throw JobServiceError.networkError(error)
        } catch {
            throw error
        }
    }
    
    // Parse log entries from raw logs
    private func parseLogEntries(from rawLogs: String) -> [LogEntry] {
        var logEntries: [LogEntry] = []
        
        let lines = rawLogs.components(separatedBy: .newlines)
        for line in lines {
            if line.isEmpty { continue }
            
            let components = line.components(separatedBy: " ")
            if components.count >= 2 {
                let timestamp = components[0]
                let message = components.dropFirst().joined(separator: " ")
                logEntries.append(LogEntry(timestamp: timestamp, message: message))
            } else {
                // If we can't parse a timestamp, just use the whole line as the message
                logEntries.append(LogEntry(timestamp: "", message: line))
            }
        }
        
        return logEntries
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