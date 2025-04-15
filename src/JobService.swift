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