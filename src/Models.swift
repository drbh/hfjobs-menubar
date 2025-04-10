import Foundation

// Helper struct to get app version information
struct AppVersion {
    static var current: String {
        let dictionary = Bundle.main.infoDictionary!
        let version = dictionary["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = dictionary["CFBundleVersion"] as? String ?? "Unknown"
        return "v\(version) (\(build))"
    }
}

// Job data model
struct HFJob: Codable, Equatable, Identifiable {
    struct Owner: Codable, Equatable {
        let id: String
        let name: String
    }
    
    struct Metadata: Codable, Equatable {
        let jobId: String
        let owner: Owner
        let createdAt: String
    }
        
    struct Spec: Codable, Equatable {
        let spaceId: String?     
        let command: [String]
        let flavor: String
        let dockerImage: String?
    }
    
    struct Status: Codable, Equatable {
        var stage: String
        let message: String?
    }
    
    let metadata: Metadata
    let spec: Spec
    var status: Status
    
    var id: String { metadata.jobId }
    
    // Helper computed properties
    var displayName: String {
        if let spaceId = spec.spaceId, !spaceId.isEmpty {
            return spaceId
        } else if let dockerImage = spec.dockerImage, !dockerImage.isEmpty {
            // Extract meaningful part from docker image name if possible
            let components = dockerImage.split(separator: "/")
            if let lastComponent = components.last {
                return String(lastComponent)
            }
            return dockerImage
        } else {
            // Use the first part of the command as an identifier
            let command = spec.command.first ?? ""
            if !command.isEmpty {
                return "Command: \(command)"
            }
            // Fallback to job ID if nothing else is available
            return "Job \(id.prefix(8))"
        }
    }
    
    var statusEmoji: String {
        switch status.stage {
        case "RUNNING": return "🟢"
        case "COMPLETED": return "✅"
        case "ERROR": return "❌"
        case "PENDING": return "⏳"
        case "QUEUED": return "🟡"
        default: return "❓"
        }
    }
    
    var statusColor: String {
        switch status.stage {
        case "RUNNING": return "#00FF00"
        case "COMPLETED": return "#00AA00"
        case "ERROR": return "#FF0000"
        case "PENDING": return "#AAAAAA"
        case "QUEUED": return "#FFFF00"
        default: return "#666666"
        }
    }
    
    var formattedCreationDate: String {
        // Parse the ISO 8601 formatted date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        guard let date = dateFormatter.date(from: metadata.createdAt) else {
            return "Unknown time"
        }
        
        // Format as relative time (e.g., "2h ago")
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .abbreviated
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
    
    // Get the date object from creation time for filtering
    var creationDate: Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        return dateFormatter.date(from: metadata.createdAt)
    }
    
    var formattedCommand: String {
        let commandString = spec.command.joined(separator: " ")
        return commandString.count > 30 ? "\(commandString.prefix(30))..." : commandString
    }
    
    var spaceURL: URL? {
        guard let spaceId = spec.spaceId else { return nil }
        return URL(string: "https://huggingface.co/spaces/\(spaceId)")
    }
}

// App settings
struct AppSettings {
    static var shared = AppSettings()
    
    let tokenKey = "HuggingFaceAPIToken"
    let usernameKey = "HuggingFaceUsername"
    let pollingEnabledKey = "PollingEnabled"
    let pollingIntervalKey = "PollingInterval"
    let jobHistoryKey = "JobHistory"
    let showTextInMenuKey = "ShowTextInMenu"
    let notificationsEnabledKey = "NotificationsEnabled"
    
    private let defaults = UserDefaults.standard
    
    var token: String? {
        get { defaults.string(forKey: tokenKey) }
        set { defaults.set(newValue, forKey: tokenKey) }
    }
    
    var username: String? {
        get { defaults.string(forKey: usernameKey) }
        set { defaults.set(newValue, forKey: usernameKey) }
    }
    
    var pollingEnabled: Bool {
        get { defaults.bool(forKey: pollingEnabledKey) }
        set { defaults.set(newValue, forKey: pollingEnabledKey) }
    }
    
    var pollingInterval: Int {
        get { 
            let interval = defaults.integer(forKey: pollingIntervalKey)
            return interval > 0 ? interval : 60 // Default to 60 seconds
        }
        set { defaults.set(newValue, forKey: pollingIntervalKey) }
    }
    
    var showTextInMenu: Bool {
        get {
            // If key doesn't exist yet, default to true
            if defaults.object(forKey: showTextInMenuKey) == nil {
                return true
            }
            return defaults.bool(forKey: showTextInMenuKey)
        }
        set { defaults.set(newValue, forKey: showTextInMenuKey) }
    }
    
    var notificationsEnabled: Bool {
        get {
            // If key doesn't exist yet, default to true
            if defaults.object(forKey: notificationsEnabledKey) == nil {
                return true
            }
            return defaults.bool(forKey: notificationsEnabledKey)
        }
        set { defaults.set(newValue, forKey: notificationsEnabledKey) }
    }
    
    // Job history as a persistent cache of completed jobs
    var jobHistory: [String: HFJob] {
        get {
            guard let data = defaults.data(forKey: jobHistoryKey),
                  let history = try? JSONDecoder().decode([String: HFJob].self, from: data) else {
                return [:]
            }
            return history
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: jobHistoryKey)
            }
        }
    }
    
    // Add a job to history
    mutating func addJobToHistory(_ job: HFJob) {
        var history = jobHistory
        history[job.id] = job
        jobHistory = history
    }
    
    // Clear job history
    mutating func clearJobHistory() {
        jobHistory = [:]
    }
}