import Foundation
import OSLog 

// Errors that can occur when fetching jobs
enum JobServiceError: Error {
    case noToken
    case noUsername
    case invalidURL
    case networkError(Error)
    case httpError(Int)
    case decodingError(Error)
    case jobNotFound
    case streamEnded
    case streamTimeout
    case unknown
}

// Structure to decode log entries from streaming response
struct JobLogEntry: Decodable {
    let timestamp: String
    let data: String
}

// Delegate protocol for streaming logs
protocol JobLogStreamDelegate: AnyObject {
    func didReceiveLogLine(_ line: String, timestamp: Date?)
    func didEncounterError(_ error: Error)
    func didCompleteStream()
}

// JobService class for handling API communication
class JobService {
    static let shared = JobService()
    
    private init() {}
    
    // Fetch jobs using Swift concurrency
    func fetchJobs() async throws -> [HFJob] {
        guard let token = AppSettings.shared.token, !token.isEmpty else {
            throw JobServiceError.noToken
        }
        
        guard let username = AppSettings.shared.username, !username.isEmpty else {
            throw JobServiceError.noUsername
        }
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)") else {
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
            
            let jobs = try JSONDecoder().decode([HFJob].self, from: data)
            return jobs
        } catch let error as JobServiceError {
            throw error
        } catch let error as URLError {
            throw JobServiceError.networkError(error)
        } catch {
            throw JobServiceError.decodingError(error)
        }
    }
    
    // Fetch a specific job by ID
    func fetchJobById(jobId: String) async throws -> HFJob {
        guard let token = AppSettings.shared.token, !token.isEmpty else {
            throw JobServiceError.noToken
        }
        
        guard let username = AppSettings.shared.username, !username.isEmpty else {
            throw JobServiceError.noUsername
        }
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)") else {
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
            
            if httpResponse.statusCode == 404 {
                throw JobServiceError.jobNotFound
            }
            
            guard httpResponse.statusCode == 200 else {
                throw JobServiceError.httpError(httpResponse.statusCode)
            }
            
            let job = try JSONDecoder().decode(HFJob.self, from: data)
            return job
        } catch let error as JobServiceError {
            throw error
        } catch let error as URLError {
            throw JobServiceError.networkError(error)
        } catch {
            throw JobServiceError.decodingError(error)
        }
    }
    // Streaming logs implementation
    private var logStreamTask: URLSessionDataTask?
    private var logStreamTimeout: TimeInterval = 10
    private var isStreamingActive = false
    func streamJobLogs(jobId: String, includeTimestamps: Bool, delegate: JobLogStreamDelegate) -> String {
        // If already streaming this job, don't start another stream
        if isStreamingActive {
            return "Already streaming logs for job \(jobId)..."
        }
        
        isStreamingActive = true
        
        guard let token = AppSettings.shared.token, !token.isEmpty else {
            delegate.didEncounterError(JobServiceError.noToken)
            isStreamingActive = false
            return "No token available."
        }
        
        guard let username = AppSettings.shared.username, !username.isEmpty else {
            delegate.didEncounterError(JobServiceError.noUsername)
            isStreamingActive = false
            return "No username available."
        }
        
        // First verify the job exists
        Task {
            do {
                let _ = try await fetchJobById(jobId: jobId)
                startLogStream(username: username, jobId: jobId, includeTimestamps: includeTimestamps, delegate: delegate)
            } catch {
                delegate.didEncounterError(error)
                isStreamingActive = false
            }
        }
        
        return "Connecting to log stream..."
    }
    private func startLogStream(username: String, jobId: String, includeTimestamps: Bool, delegate: JobLogStreamDelegate) {
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/logs-stream") else {
            delegate.didEncounterError(JobServiceError.invalidURL)
            isStreamingActive = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(AppSettings.shared.token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("hfjobs-swift", forHTTPHeaderField: "X-Library-Name")
        request.timeoutInterval = logStreamTimeout
        
        let session = URLSession.shared
        
        var buffer = Data()
        var loggingFinished = false
        var jobFinished = false
        
        // Cancel any existing stream task before creating a new one
        logStreamTask?.cancel()
        
        logStreamTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { 
                self?.isStreamingActive = false
                return 
            }
            
            if let error = error {
                if let urlError = error as? URLError, urlError.code == .timedOut {
                    // Timeout error, retry with longer timeout
                    self.logStreamTimeout = min(self.logStreamTimeout * 2, 60)
                    
                    // Check job status before retrying
                    Task {
                        do {
                            let job = try await self.fetchJobById(jobId: jobId)
                            let status = job.status.stage
                            let currentLoggingFinished = loggingFinished
                            
                            if status != "RUNNING" && status != "UPDATING" {
                                // Using local variable to avoid Swift 6 warning
                                // instead of mutating the captured variable
                                let isJobFinished = true
                                
                                if isJobFinished {
                                    delegate.didCompleteStream()
                                    self.isStreamingActive = false
                                }
                            } else if !currentLoggingFinished {
                                // Retry streaming if job is still running and we haven't received logs yet
                                self.startLogStream(username: username, jobId: jobId, includeTimestamps: includeTimestamps, delegate: delegate)
                            }
                        } catch {
                            delegate.didEncounterError(error)
                            self.isStreamingActive = false
                        }
                    }
                    return
                } else {
                    delegate.didEncounterError(JobServiceError.networkError(error))
                    self.isStreamingActive = false
                    return
                }
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                delegate.didEncounterError(JobServiceError.unknown)
                self.isStreamingActive = false
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                delegate.didEncounterError(JobServiceError.httpError(httpResponse.statusCode))
                self.isStreamingActive = false
                return
            }
            
            if let data = data {
                buffer.append(data)
                
                // Process buffer line by line
                while let newlineIndex = buffer.firstIndex(of: 10) { // ASCII for '\n'
                    let lineData = buffer.prefix(upTo: newlineIndex)
                    buffer = buffer.suffix(from: newlineIndex + 1)
                    
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        if line.hasPrefix("data: {") {
                            let jsonStart = line.index(line.startIndex, offsetBy: "data: ".count)
                            let jsonString = String(line[jsonStart...])
                            
                            if let data = jsonString.data(using: .utf8) {
                                do {
                                    let logEntry = try JSONDecoder().decode(JobLogEntry.self, from: data)
                                    
                                    // Skip "Job started" messages as per Python reference
                                    if !logEntry.data.hasPrefix("===== Job started") {
                                        let timestamp: Date? = includeTimestamps ? {
                                            let dateFormatter = ISO8601DateFormatter()
                                            return dateFormatter.date(from: logEntry.timestamp)
                                        }() : nil
                                        
                                        delegate.didReceiveLogLine(logEntry.data, timestamp: timestamp)
                                        loggingFinished = true
                                    }
                                } catch {
                                    os_log("Failed to decode log entry: %@", error.localizedDescription)
                                }
                            }
                        }
                    }
                }
            } else {
                // Empty response
                let currentLoggingFinished = loggingFinished
                let currentJobFinished = jobFinished
                
                if currentLoggingFinished || currentJobFinished {
                    delegate.didCompleteStream()
                    self.isStreamingActive = false
                } else {
                    // Check job status
                    Task {
                        do {
                            let job = try await self.fetchJobById(jobId: jobId)
                            let status = job.status.stage
                            
                            if status != "RUNNING" && status != "UPDATING" {
                                // Using local variable instead of mutating captured variable
                                let isJobFinished = true
                                
                                if isJobFinished {
                                    delegate.didCompleteStream()
                                    self.isStreamingActive = false
                                }
                            } else {
                                // Wait and retry - similar to Python reference
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    self.startLogStream(username: username, jobId: jobId, includeTimestamps: includeTimestamps, delegate: delegate)
                                }
                            }
                        } catch {
                            delegate.didEncounterError(error)
                            self.isStreamingActive = false
                        }
                    }
                }
            }
        }
        
        logStreamTask?.resume()
    }
    func cancelLogStream() {
        logStreamTask?.cancel()
        logStreamTask = nil
        isStreamingActive = false
    }
    
    // TODO: Implement job cancellation on the server side?
    // Cancel a running job
    func cancelJob(jobId: String) async throws {
        guard let token = AppSettings.shared.token, !token.isEmpty else {
            throw JobServiceError.noToken
        }
        
        guard let username = AppSettings.shared.username, !username.isEmpty else {
            throw JobServiceError.noUsername
        }
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/cancel") else {
            throw JobServiceError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("hfjobs-swift", forHTTPHeaderField: "X-Library-Name")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JobServiceError.unknown
            }
            
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 202 else {
                throw JobServiceError.httpError(httpResponse.statusCode)
            }
        } catch let error as JobServiceError {
            throw error
        } catch {
            throw JobServiceError.networkError(error)
        }
    }
    
    // Helper method to convert fetch errors to user-friendly messages
    func errorMessage(for error: Error) -> String {
        switch error {
        case JobServiceError.noToken:
            return "No API token found. Please add your Hugging Face token."
        case JobServiceError.noUsername:
            return "No username found. Please add your Hugging Face username."
        case JobServiceError.invalidURL:
            return "Invalid API URL. Please check your network connection."
        case JobServiceError.jobNotFound:
            return "Job not found. It may have been deleted."
        case JobServiceError.streamEnded:
            return "Log stream ended unexpectedly."
        case JobServiceError.streamTimeout:
            return "Log stream timed out. Retrying..."
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
        case JobServiceError.decodingError:
            return "Error processing the response. Please try again."
        default:
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}