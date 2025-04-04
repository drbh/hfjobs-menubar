import Cocoa
import Foundation
import UserNotifications

// Job data model
struct HFJob: Decodable, Equatable, Identifiable {
    struct Owner: Decodable, Equatable {
        let id: String
        let name: String
    }
    
    struct Metadata: Decodable, Equatable {
        let jobId: String
        let owner: Owner
        let createdAt: String
    }
        
    struct Spec: Decodable, Equatable {
        let spaceId: String?     
        let command: [String]
        let flavor: String
        let dockerImage: String?
    }
    
    struct Status: Decodable, Equatable {
        let stage: String
        let message: String?
    }
    
    let metadata: Metadata
    let spec: Spec
    let status: Status
    
    var id: String { metadata.jobId }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var jobsMenuItem: NSMenuItem!
    var jobsSubmenu: NSMenu!
    var timer: Timer?
    var pollingTimer: Timer?
    var isPollingSwitchedOn = false
    var pollingMenuItem: NSMenuItem!
    var cachedJobs: [HFJob] = []
    
    let tokenKey = "HuggingFaceAPIToken"
    let usernameKey = "HuggingFaceUsername"
    let pollingEnabledKey = "PollingEnabled"
    let pollingIntervalKey = "PollingInterval"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        requestNotificationPermissions()
        
        // Check if token exists, if not prompt for it
        if !checkAndPromptForToken() {
            return // Don't proceed with app setup until token is provided
        }
        
        // Check if username exists, if not prompt for it
        if !checkAndPromptForUsername() {
            return // Don't proceed with app setup until username is provided
        }
        
        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.title = "HF JOBS"
        }
        
        // Create the menu
        let menu = NSMenu()
        
        // Jobs submenu
        jobsSubmenu = NSMenu()
        jobsMenuItem = NSMenuItem(title: "Hugging Face Jobs", action: nil, keyEquivalent: "")
        jobsMenuItem.submenu = jobsSubmenu
        menu.addItem(jobsMenuItem)
        
        // Initial jobs loading
        loadJobs()
        
        menu.addItem(NSMenuItem.separator())
        
        // Polling toggle
        isPollingSwitchedOn = UserDefaults.standard.bool(forKey: pollingEnabledKey)
        pollingMenuItem = NSMenuItem(title: "Auto-Refresh: \(isPollingSwitchedOn ? "On" : "Off")", action: #selector(togglePolling), keyEquivalent: "p")
        menu.addItem(pollingMenuItem)
        
        // Polling interval submenu
        let pollingIntervalMenuItem = NSMenuItem(title: "Polling Interval", action: nil, keyEquivalent: "")
        let pollingIntervalSubmenu = NSMenu()
        
        let intervals = [15, 30, 60, 120, 300]
        let currentInterval = UserDefaults.standard.integer(forKey: pollingIntervalKey)
        
        for interval in intervals {
            let item = NSMenuItem(title: "\(interval) seconds", action: #selector(setPollingInterval(_:)), keyEquivalent: "")
            item.tag = interval
            item.state = currentInterval == interval ? .on : .off
            pollingIntervalSubmenu.addItem(item)
        }
        
        pollingIntervalMenuItem.submenu = pollingIntervalSubmenu
        menu.addItem(pollingIntervalMenuItem)
        
        // Web links
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: "Hugging Face", link: "https://huggingface.co/")
        addMenuItem(to: menu, title: "HF Spaces", link: "https://huggingface.co/spaces")
        
        // Add refresh option
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Refresh Jobs", action: #selector(refreshJobs), keyEquivalent: "r"))
        
        // Add update token option
        menu.addItem(NSMenuItem(title: "Update Token", action: #selector(promptForToken), keyEquivalent: "t"))
        
        // Add update username option
        menu.addItem(NSMenuItem(title: "Update Username", action: #selector(promptForUsername), keyEquivalent: "u"))
        
        // Add quit option
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        // Set the menu
        statusItem.menu = menu
        
        // Set up polling if enabled
        if isPollingSwitchedOn {
            startPolling()
        }
        
        // Set up a timer to refresh jobs periodically (every 60 seconds)
        timer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(refreshJobs), userInfo: nil, repeats: true)
    }
    
    func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Notification permissions granted")
            } else if let error = error {
                print("Error requesting notification permissions: \(error)")
            }
        }
    }
    
    @objc func togglePolling() {
        isPollingSwitchedOn.toggle()
        UserDefaults.standard.set(isPollingSwitchedOn, forKey: pollingEnabledKey)
        pollingMenuItem.title = "Auto-Refresh: \(isPollingSwitchedOn ? "On" : "Off")"
        
        if isPollingSwitchedOn {
            startPolling()
            showNotification(title: "HF Jobs Polling", body: "Real-time status monitoring is now active")
        } else {
            stopPolling()
            showNotification(title: "HF Jobs Polling", body: "Real-time status monitoring is now disabled")
        }
    }
    
    @objc func setPollingInterval(_ sender: NSMenuItem) {
        let interval = sender.tag
        UserDefaults.standard.set(interval, forKey: pollingIntervalKey)
        
        // Update menu item states
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = item.tag == interval ? .on : .off
            }
        }
        
        // Restart polling if it's enabled
        if isPollingSwitchedOn {
            stopPolling()
            startPolling()
        }
    }
    
    func startPolling() {
        stopPolling() // Ensure we don't have multiple timers running
        
        let interval = UserDefaults.standard.integer(forKey: pollingIntervalKey)
        let pollingInterval = TimeInterval(interval > 0 ? interval : 60) // Default to 60 seconds
        
        pollingTimer = Timer.scheduledTimer(timeInterval: pollingInterval, target: self, selector: #selector(pollJobStatus), userInfo: nil, repeats: true)
        
        // Initial poll
        pollJobStatus()
    }
    
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    @objc func pollJobStatus() {
        fetchJobs { [weak self] jobs in
            guard let self = self, let jobs = jobs else { return }
            
            DispatchQueue.main.async {
                // Compare new jobs with cached jobs to detect status changes
                self.detectStatusChanges(oldJobs: self.cachedJobs, newJobs: jobs)
                
                // Update the cached jobs
                self.cachedJobs = jobs
            }
        }
    }
    
    func detectStatusChanges(oldJobs: [HFJob], newJobs: [HFJob]) {
        // Create dictionaries for fast lookup
        let oldJobsDict = Dictionary(uniqueKeysWithValues: oldJobs.map { ($0.id, $0) })
        var statusChanged = false
        
        for newJob in newJobs {
            // Get a meaningful job name
            let jobName = getJobDisplayName(job: newJob)
            
            // Check if job existed before
            if let oldJob = oldJobsDict[newJob.id] {
                // Check if status changed
                if oldJob.status.stage != newJob.status.stage {
                    // Status changed, send notification
                    statusChanged = true
                    let title = "Job Status Changed"
                    let body = "Job '\(jobName)' changed from \(oldJob.status.stage) to \(newJob.status.stage)"
                    showNotification(title: title, body: body)
                }
            } else if newJob.status.stage == "RUNNING" {
                // New running job
                statusChanged = true
                let title = "New Job Started"
                let body = "Job '\(jobName)' has started running"
                showNotification(title: title, body: body)
            }
        }
        
        // Check for completed or failed jobs that weren't in that state before
        for oldJob in oldJobs {
            // Get a meaningful job name
            let jobName = getJobDisplayName(job: oldJob)
            
            if let newJob = newJobs.first(where: { $0.id == oldJob.id }) {
                // Job still exists, check for terminal states
                if newJob.status.stage == "COMPLETED" && oldJob.status.stage != "COMPLETED" {
                    statusChanged = true
                    let title = "Job Completed"
                    let body = "Job '\(jobName)' has completed successfully"
                    showNotification(title: title, body: body)
                } else if newJob.status.stage == "ERROR" && oldJob.status.stage != "ERROR" {
                    statusChanged = true
                    let title = "Job Failed"
                    let body = "Job '\(jobName)' has failed with an error"
                    showNotification(title: title, body: body)
                }
            } else {
                // Job disappeared from the list
                statusChanged = true
                let title = "Job Removed"
                let body = "Job '\(jobName)' is no longer in the job list"
                showNotification(title: title, body: body)
            }
        }
        
        // If any job status changed, update the menu
        if statusChanged {
            DispatchQueue.main.async {
                self.loadJobs()
            }
        }
    }
    
    func getJobDisplayName(job: HFJob) -> String {
        if let spaceId = job.spec.spaceId, !spaceId.isEmpty {
            return spaceId
        } else if let dockerImage = job.spec.dockerImage, !dockerImage.isEmpty {
            // Extract meaningful part from docker image name if possible
            let components = dockerImage.split(separator: "/")
            if let lastComponent = components.last {
                return String(lastComponent)
            }
            return dockerImage
        } else {
            // Use the first part of the command as an identifier
            let command = job.spec.command.first ?? ""
            if !command.isEmpty {
                return "Command: \(command)"
            }
            // Fallback to job ID if nothing else is available
            return "Job \(job.id.prefix(8))"
        }
    }
    
    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing notification: \(error)")
            }
        }
    }
    
    func checkAndPromptForToken() -> Bool {
        if UserDefaults.standard.string(forKey: tokenKey) == nil {
            promptForToken()
            return false
        }
        return true
    }
    
    func checkAndPromptForUsername() -> Bool {
        if UserDefaults.standard.string(forKey: usernameKey) == nil {
            promptForUsername()
            return false
        }
        return true
    }
    
    @objc func promptForToken() {
        let alert = NSAlert()
        alert.messageText = "Hugging Face API Token"
        alert.informativeText = "Please enter your Hugging Face API token"
        alert.alertStyle = .informational
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "hf_..."
        
        // Pre-fill with existing token if available
        if let existingToken = UserDefaults.standard.string(forKey: tokenKey) {
            textField.stringValue = existingToken
        }
        
        alert.accessoryView = textField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let token = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                UserDefaults.standard.set(token, forKey: tokenKey)
                
                // If this is an update (app is already running), refresh jobs
                if statusItem != nil {
                    refreshJobs()
                } else {
                    // Initialize app if this was first setup
                    applicationDidFinishLaunching(Notification(name: Notification.Name("TokenSetup")))
                }
            } else {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Error"
                errorAlert.informativeText = "Token cannot be empty"
                errorAlert.alertStyle = .critical
                errorAlert.runModal()
                promptForToken() // Ask again
            }
        } else if statusItem == nil {
            // If user cancels on first run, quit the app
            NSApplication.shared.terminate(nil)
        }
    }
    
    @objc func promptForUsername() {
        let alert = NSAlert()
        alert.messageText = "Hugging Face Username"
        alert.informativeText = "Please enter your Hugging Face username"
        alert.alertStyle = .informational
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "username"
        
        // Pre-fill with existing username if available
        if let existingUsername = UserDefaults.standard.string(forKey: usernameKey) {
            textField.stringValue = existingUsername
        }
        
        alert.accessoryView = textField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let username = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                UserDefaults.standard.set(username, forKey: usernameKey)
                
                // If this is an update (app is already running), refresh jobs
                if statusItem != nil {
                    refreshJobs()
                } else {
                    // Initialize app if this was first setup
                    applicationDidFinishLaunching(Notification(name: Notification.Name("UsernameSetup")))
                }
            } else {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Error"
                errorAlert.informativeText = "Username cannot be empty"
                errorAlert.alertStyle = .critical
                errorAlert.runModal()
                promptForUsername() // Ask again
            }
        } else if statusItem == nil {
            // If user cancels on first run, quit the app
            NSApplication.shared.terminate(nil)
        }
    }
    
    func addMenuItem(to menu: NSMenu, title: String, link: String) {
        let menuItem = NSMenuItem(title: title, action: #selector(openLink(_:)), keyEquivalent: "")
        menuItem.representedObject = link
        menu.addItem(menuItem)
    }
    
    @objc func openLink(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func refreshJobs() {
        loadJobs()
    }
    
    func loadJobs() {
        // Clear and add loading indicator
        jobsSubmenu.removeAllItems()
        jobsSubmenu.addItem(NSMenuItem(title: "Loading jobs...", action: nil, keyEquivalent: ""))
        
        // Fetch jobs
        fetchJobs { [weak self] jobs in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                // Clear the submenu
                self.jobsSubmenu.removeAllItems()
                
                guard let jobs = jobs else {
                    self.jobsSubmenu.addItem(NSMenuItem(title: "Error fetching jobs", action: nil, keyEquivalent: ""))
                    return
                }
                
                // Update cached jobs for status polling
                self.cachedJobs = jobs
                
                if jobs.isEmpty {
                    self.jobsSubmenu.addItem(NSMenuItem(title: "No jobs found", action: nil, keyEquivalent: ""))
                    return
                }
                
                // Group jobs by state
                let runningJobs = jobs.filter { $0.status.stage == "RUNNING" }
                let completedJobs = jobs.filter { $0.status.stage == "COMPLETED" }
                let errorJobs = jobs.filter { $0.status.stage == "ERROR" }
                let otherJobs = jobs.filter { !["RUNNING", "COMPLETED", "ERROR"].contains($0.status.stage) }
                
                // Add sections for each state
                self.addJobsSection(title: "Running Jobs", jobs: runningJobs, to: self.jobsSubmenu)
                if !runningJobs.isEmpty && (!completedJobs.isEmpty || !errorJobs.isEmpty || !otherJobs.isEmpty) {
                    self.jobsSubmenu.addItem(NSMenuItem.separator())
                }
                
                self.addJobsSection(title: "Completed Jobs", jobs: completedJobs, to: self.jobsSubmenu)
                if !completedJobs.isEmpty && (!errorJobs.isEmpty || !otherJobs.isEmpty) {
                    self.jobsSubmenu.addItem(NSMenuItem.separator())
                }
                
                self.addJobsSection(title: "Failed Jobs", jobs: errorJobs, to: self.jobsSubmenu)
                if !errorJobs.isEmpty && !otherJobs.isEmpty {
                    self.jobsSubmenu.addItem(NSMenuItem.separator())
                }
                
                self.addJobsSection(title: "Other Jobs", jobs: otherJobs, to: self.jobsSubmenu)
            }
        }
    }
    
    func addJobsSection(title: String, jobs: [HFJob], to menu: NSMenu) {
        if jobs.isEmpty {
            return
        }
        
        // Add section header
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        
        // Add jobs
        for job in jobs {
            addJobMenuItem(job, to: menu)
        }
    }
    
    func addJobMenuItem(_ job: HFJob, to menu: NSMenu) {
        // Get emoji for job status
        let statusEmoji: String
        switch job.status.stage {
        case "RUNNING":
            statusEmoji = "🟢"
        case "COMPLETED":
            statusEmoji = "✅"
        case "ERROR":
            statusEmoji = "❌"
        case "PENDING":
            statusEmoji = "⏳"
        case "QUEUED":
            statusEmoji = "🟡"
        default:
            statusEmoji = "❓"
        }
        // Format creation date (2025-04-01T15:03:30.589Z)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let displayDate: String
        if let date = dateFormatter.date(from: job.metadata.createdAt) {
            let relativeFormatter = RelativeDateTimeFormatter()
            relativeFormatter.unitsStyle = .abbreviated
            displayDate = relativeFormatter.localizedString(for: date, relativeTo: Date())
        } else {
            displayDate = "Unknown time"
        }
        // Get a meaningful job name using our helper function
        let shortName = getJobDisplayName(job: job)
        // ensure its only 20 characters max
        let shortNameDisplay = shortName.count > 20 ? "\(shortName.prefix(20))..." : shortName
        // Create command string for display
        let commandDisplay = job.spec.command.joined(separator: " ")
        let shortCommand = commandDisplay.count > 30 ? "\(commandDisplay.prefix(30))..." : commandDisplay
        
        // Create submenu for job details and actions
        let jobSubmenu = NSMenu()
        
        // Add detailed info items
        jobSubmenu.addItem(makeInfoMenuItem("Job ID: \(job.metadata.jobId)"))
        // jobSubmenu.addItem(makeInfoMenuItem("Space: \(job.spec.spaceId)"))
        if let spaceId = job.spec.spaceId {
            jobSubmenu.addItem(makeInfoMenuItem("Space: \(spaceId)"))
        } else {
            jobSubmenu.addItem(makeInfoMenuItem("Space: N/A"))
        }
        jobSubmenu.addItem(makeInfoMenuItem("Docker Image: \(job.spec.dockerImage ?? "N/A")"))
        jobSubmenu.addItem(makeInfoMenuItem("Status: \(job.status.stage)"))
        jobSubmenu.addItem(makeInfoMenuItem("Created: \(dateFormatter.string(from: dateFormatter.date(from: job.metadata.createdAt) ?? Date()))"))
        jobSubmenu.addItem(makeInfoMenuItem("Owner: \(job.metadata.owner.name)"))
        jobSubmenu.addItem(makeInfoMenuItem("Flavor: \(job.spec.flavor)"))
        
        if let message = job.status.message, !message.isEmpty {
            jobSubmenu.addItem(makeInfoMenuItem("Message: \(message)"))
        }
        
        // Add command with full details
        jobSubmenu.addItem(NSMenuItem.separator())
        jobSubmenu.addItem(makeInfoMenuItem("Command:"))
        let commandString = job.spec.command.joined(separator: " ")
        jobSubmenu.addItem(makeInfoMenuItem("  \(commandString)"))
        
        // Add actions
        jobSubmenu.addItem(NSMenuItem.separator())
        
        // Copy Job ID action
        let copyJobIdItem = NSMenuItem(title: "Copy Job ID", action: #selector(copyText(_:)), keyEquivalent: "")
        copyJobIdItem.representedObject = job.metadata.jobId
        jobSubmenu.addItem(copyJobIdItem)
        
        // Open in browser action (if spaceId is available)
        if let spaceId = job.spec.spaceId {
            let spaceUrl = "https://huggingface.co/spaces/\(spaceId)"
            let openInBrowserItem = NSMenuItem(title: "Open Space in Browser", action: #selector(openLink(_:)), keyEquivalent: "")
            openInBrowserItem.representedObject = spaceUrl
            jobSubmenu.addItem(openInBrowserItem)
        }
        
        // Create the main menu item with the job name and status
        let itemTitle = "\(statusEmoji) [\(shortNameDisplay)] `\(shortCommand)` (\(displayDate))"
        let item = NSMenuItem(title: itemTitle, action: nil, keyEquivalent: "")
        item.submenu = jobSubmenu
        menu.addItem(item)
    }
    
    func makeInfoMenuItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
    
    @objc func copyText(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
    
    func fetchJobs(completion: @escaping ([HFJob]?) -> Void) {
        guard let token = UserDefaults.standard.string(forKey: tokenKey), !token.isEmpty else {
            print("No API token found")
            // Prompt for token if not available
            DispatchQueue.main.async {
                self.promptForToken()
            }
            completion(nil)
            return
        }
        
        guard let username = UserDefaults.standard.string(forKey: usernameKey), !username.isEmpty else {
            print("No username found")
            // Prompt for username if not available
            DispatchQueue.main.async {
                self.promptForUsername()
            }
            completion(nil)
            return
        }
        
        guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Error fetching jobs: \(error)")
                completion(nil)
                return
            }
            
            // Check for HTTP status code
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("HTTP Error: \(httpResponse.statusCode)")
                
                // If unauthorized (401), prompt for a new token
                if httpResponse.statusCode == 401 {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Authentication Error"
                        alert.informativeText = "Your Hugging Face API token is invalid or expired. Please update it."
                        alert.alertStyle = .critical
                        alert.runModal()
                        self.promptForToken()
                    }
                }
                
                completion(nil)
                return
            }
            
            guard let data = data else {
                print("No data received")
                completion(nil)
                return
            }
            do {
                let jobs = try JSONDecoder().decode([HFJob].self, from: data)
                completion(jobs)
            } catch {
                print("Error decoding jobs: \(error)")
                completion(nil)
            }
        }
        
        task.resume()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pollingTimer?.invalidate()
    }
}

// Main application entry point
struct HFJobsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}