import Cocoa
import Foundation
import UserNotifications

// Main application delegate
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // UI Components
    private var statusItem: NSStatusItem!
    private var jobsMenuItem: NSMenuItem!
    private var jobsSubmenu: NSMenu!
    private var pollingMenuItem: NSMenuItem!
    
    // Timers
    private var timer: Timer?
    private var pollingTimer: Timer?
    
    // State
    private var cachedJobs: [HFJob] = []
    private var isPollingSwitchedOn = false
    
    // Initialize app
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up notification center delegate
        UNUserNotificationCenter.current().delegate = self
        
        // Setup the app with token and username
        setupApp()
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    // Handle notifications when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Always show notifications, even when the app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    // Handle notification responses
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // You could add logic here to handle when a user clicks on a notification
        completionHandler()
    }
    
    // Main app setup
    private func setupApp() {
        // Check if token exists, if not prompt for it
        if !checkAndPromptForToken() {
            return // Don't proceed with app setup until token is provided
        }
        
        // Check if username exists, if not prompt for it
        if !checkAndPromptForUsername() {
            return // Don't proceed with app setup until username is provided
        }
        
        // Create the status item in the menu bar
        setupMenuBar()
        
        // Initial jobs loading
        Task {
            await loadJobs()
        }
        
        // Set up polling if enabled
        isPollingSwitchedOn = AppSettings.shared.pollingEnabled
        if isPollingSwitchedOn {
            startPolling()
        }
        
        // Set up a timer to refresh jobs periodically (every 60 seconds)
        timer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(refreshJobs), userInfo: nil, repeats: true)
    }
    
    // Setup the menu bar
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let showTextInMenu = AppSettings.shared.showTextInMenu
        if let button = statusItem.button {
            if let iconImage = NSImage(named: "MenuBarIcon") {
                iconImage.isTemplate = true
                button.image = iconImage
                button.image?.size = NSSize(width: 24, height: 24)
                if showTextInMenu {
                    button.title = "hfjobs"
                }
            }
        }

        createMenu()
        updateMenuBarIcon()
    }
    
    // Update the menu bar icon with running job count
    private func updateMenuBarIcon() {
        let runningJobs = cachedJobs.filter { $0.status.stage == "RUNNING" }
        let runningCount = runningJobs.count
        
        if let button = statusItem.button {
            if runningCount > 0 {
                // Show the running job count
                button.title = runningCount > 99 ? "99+" : "\(runningCount)"
            } else {
                // Show "hfjobs" or empty based on settings
                button.title = AppSettings.shared.showTextInMenu ? "hfjobs" : ""
            }
        }
    }
    
    // Create the main menu
    private func createMenu() {
        let menu = NSMenu()
        
        // Jobs submenu
        jobsSubmenu = NSMenu()
        jobsMenuItem = NSMenuItem(title: "Hugging Face Jobs", action: nil, keyEquivalent: "")
        jobsMenuItem.submenu = jobsSubmenu
        menu.addItem(jobsMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Polling toggle
        isPollingSwitchedOn = AppSettings.shared.pollingEnabled
        pollingMenuItem = NSMenuItem(title: "Auto-Refresh: \(isPollingSwitchedOn ? "On" : "Off")", action: #selector(togglePolling), keyEquivalent: "p")
        menu.addItem(pollingMenuItem)
        
        // Polling interval submenu
        let pollingIntervalMenuItem = NSMenuItem(title: "Polling Interval", action: nil, keyEquivalent: "")
        let pollingIntervalSubmenu = NSMenu()
        
        let intervals = [5, 15, 30, 60, 120, 300]
        let currentInterval = AppSettings.shared.pollingInterval
        
        for interval in intervals {
            let item = NSMenuItem(title: "\(interval) seconds", action: #selector(setPollingInterval(_:)), keyEquivalent: "")
            item.tag = interval
            item.state = currentInterval == interval ? .on : .off
            pollingIntervalSubmenu.addItem(item)
        }
        
        pollingIntervalMenuItem.submenu = pollingIntervalSubmenu
        menu.addItem(pollingIntervalMenuItem)
        
        // Jobs view submenu
        let jobViewMenuItem = NSMenuItem(title: "View Jobs", action: nil, keyEquivalent: "")
        let jobViewSubmenu = NSMenu()
        
        let viewOptions = ["All", "In Last 5 Minutes", "In Last Day", "In Last Week", "In Last Month", "Running", "Completed", "Failed"]
        
        for option in viewOptions {
            let item = NSMenuItem(title: option, action: #selector(switchJobView(_:)), keyEquivalent: "")
            item.state = option == "All" ? .on : .off
            jobViewSubmenu.addItem(item)
        }
        
        jobViewMenuItem.submenu = jobViewSubmenu
        menu.addItem(jobViewMenuItem)
        
        // Web links
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: "Hugging Face", link: "https://huggingface.co/")
        addMenuItem(to: menu, title: "HF Spaces", link: "https://huggingface.co/spaces")
        
        // Add refresh option
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Refresh Jobs", action: #selector(refreshJobs), keyEquivalent: "r"))
        
        // Settings
        menu.addItem(NSMenuItem(title: "Update Token", action: #selector(promptForToken), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Update Username", action: #selector(promptForUsername), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "Clear Job History", action: #selector(clearJobHistory), keyEquivalent: ""))
        
        // Show/Hide Text in Menu Bar
        let showTextMenuItem = NSMenuItem(
            title: "Show Text in Menu Bar: \(AppSettings.shared.showTextInMenu ? "On" : "Off")", 
            action: #selector(toggleShowTextInMenu), 
            keyEquivalent: "m"
        )
        menu.addItem(showTextMenuItem)
        
        // Notifications toggle
        let notificationsMenuItem = NSMenuItem(
            title: "Notifications: \(AppSettings.shared.notificationsEnabled ? "On" : "Off")", 
            action: #selector(toggleNotifications), 
            keyEquivalent: "n"
        )
        menu.addItem(notificationsMenuItem)
        
        // Add version display (non-clickable)
        menu.addItem(NSMenuItem.separator())
        let versionItem = NSMenuItem(title: "Version: \(AppVersion.current)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        
        // Add quit option
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        // Set the menu
        statusItem.menu = menu
    }
    
    // MARK: - Job Loading and Polling
    
    // Load jobs using async/await
    @MainActor
    private func loadJobs() async {
        // Clear and add loading indicator
        jobsSubmenu.removeAllItems()
        jobsSubmenu.addItem(NSMenuItem(title: "Loading jobs...", action: nil, keyEquivalent: ""))
        
        do {
            let jobs = try await JobService.shared.fetchJobs()
            
            // Update cached jobs
            cachedJobs = jobs
            
            // Update the UI
            updateJobsUI(jobs: jobs)
        } catch {
            jobsSubmenu.removeAllItems()
            jobsSubmenu.addItem(NSMenuItem(title: "Error: \(JobService.shared.errorMessage(for: error))", action: nil, keyEquivalent: ""))
            
            // If unauthorized, prompt for a new token
            if case JobServiceError.httpError(401) = error {
                let alert = NSAlert()
                alert.messageText = "Authentication Error"
                alert.informativeText = "Your Hugging Face API token is invalid or expired. Please update it."
                alert.alertStyle = .critical
                alert.runModal()
                promptForToken()
            }
        }
    }
    
    // Poll job status with async/await
    @objc private func pollJobStatus() {
        print("Polling for job status changes...")
        
        Task {
            do {
                let jobs = try await JobService.shared.fetchJobs()
                
                await MainActor.run {
                    // Get the current view filter
                    let currentFilter = getCurrentFilter()
                    
                    // Detect status changes for notifications
                    detectStatusChanges(oldJobs: cachedJobs, newJobs: jobs)
                    
                    // Update the cached jobs after checking for changes
                    cachedJobs = jobs
                    
                    // Apply the current filter to the updated jobs
                    applyJobFilter(filter: currentFilter)
                }
            } catch {
                print("Error during polling: \(error.localizedDescription)")
            }
        }
    }
    
    // Get the currently selected filter
    private func getCurrentFilter() -> String {
        if let jobViewMenuItem = statusItem.menu?.items.first(where: { $0.title == "View Jobs" }),
           let submenu = jobViewMenuItem.submenu {
            for item in submenu.items {
                if item.state == .on {
                    return item.title
                }
            }
        }
        return "All" // Default to "All" if no filter is selected
    }
    
    // Apply the current job filter
    private func applyJobFilter(filter: String) {
        if filter == "All" {
            updateJobsUI(jobs: cachedJobs)
            return
        }
        
        var filteredJobs: [HFJob] = []
        let currentDate = Date()
        
        // Time-based filters
        if filter == "In Last 5 Minutes" {
            filteredJobs = cachedJobs.filter { job in
                guard let date = job.creationDate else {
                    return false
                }
                return currentDate.timeIntervalSince(date) <= 300 // 5 minutes = 300 seconds
            }
        } else if filter == "In Last Day" {
            filteredJobs = cachedJobs.filter { job in
                guard let date = job.creationDate else {
                    return false
                }
                return currentDate.timeIntervalSince(date) <= 86400 // 1 day = 86400 seconds
            }
        } else if filter == "In Last Week" {
            filteredJobs = cachedJobs.filter { job in
                guard let date = job.creationDate else {
                    return false
                }
                return currentDate.timeIntervalSince(date) <= 604800 // 1 week = 604800 seconds
            }
        } else if filter == "In Last Month" {
            filteredJobs = cachedJobs.filter { job in
                guard let date = job.creationDate else {
                    return false
                }
                return currentDate.timeIntervalSince(date) <= 2592000 // 1 month = 2592000 seconds
            }
        } else if filter == "Just Completed (<1 hour)" {
            filteredJobs = cachedJobs.filter { job in
                guard let date = job.creationDate else {
                    return false
                }
                return currentDate.timeIntervalSince(date) <= 3600 // 1 hour = 3600 seconds
            }
        }
        // Status-based filters
        else {
            let statusMap = [
                "Running": "RUNNING",
                "Completed": "COMPLETED",
                "Failed": "ERROR"
            ]
            
            guard let status = statusMap[filter] else {
                return
            }
            
            filteredJobs = cachedJobs.filter { $0.status.stage == status }
        }
        
        updateJobsUI(jobs: filteredJobs, showFilterMessage: true, filterStatus: filter)
    }
    
    @objc func refreshJobs() {
        Task {
            await loadJobs()
            
            // Also apply any active filter after refreshing
            DispatchQueue.main.async {
                let currentFilter = self.getCurrentFilter()
                if currentFilter != "All" {
                    self.applyJobFilter(filter: currentFilter)
                }
            }
        }
    }
    
    // MARK: - UI Updates
    
    // Store active job detail windows
    private var activeJobWindows: [String: JobDetailWindowController] = [:]
    
    // Switch job view based on selection
    @objc func switchJobView(_ sender: NSMenuItem) {
        // Update menu item states
        if let submenu = sender.menu {
            for item in submenu.items {
                item.state = (item == sender) ? .on : .off
            }
        }
        
        // Apply filter based on the selected view option
        let viewOption = sender.title

        
        Task {
            await MainActor.run {
                // Default case - show all jobs
                if viewOption == "All" {
                    updateJobsUI(jobs: cachedJobs)
                    return
                }
                
                var filteredJobs: [HFJob] = []
                let currentDate = Date()
                
                // Time-based filters
                if viewOption == "In Last 5 Minutes" {
                    filteredJobs = cachedJobs.filter { job in
                        guard let date = job.creationDate else {
                            return false
                        }
                        return currentDate.timeIntervalSince(date) <= 300 // 5 minutes = 300 seconds
                    }
                } else if viewOption == "In Last Day" {
                    filteredJobs = cachedJobs.filter { job in
                        guard let date = job.creationDate else {
                            return false
                        }
                        return currentDate.timeIntervalSince(date) <= 86400 // 1 day = 86400 seconds
                    }
                } 
                else if viewOption == "In Last Week" {
                    filteredJobs = cachedJobs.filter { job in
                        guard let date = job.creationDate else {
                            return false
                        }
                        return currentDate.timeIntervalSince(date) <= 604800 // 1 week = 604800 seconds
                    }
                } else if viewOption == "In Last Month" {
                    filteredJobs = cachedJobs.filter { job in
                        guard let date = job.creationDate else {
                            return false
                        }
                        return currentDate.timeIntervalSince(date) <= 2592000 // 1 month = 2592000 seconds
                    }
                }
                // Status-based filters
                else {
                    let statusMap = [
                        "Running": "RUNNING",
                        "Completed": "COMPLETED",
                        "Failed": "ERROR"
                    ]
                    
                    guard let status = statusMap[viewOption] else {
                        return
                    }
                    
                    filteredJobs = cachedJobs.filter { $0.status.stage == status }
                }
                
                updateJobsUI(jobs: filteredJobs, showFilterMessage: true, filterStatus: viewOption)
            }
        }
    }
    
    // Update the jobs UI with the current list of jobs
    private func updateJobsUI(jobs: [HFJob], showFilterMessage: Bool = false, filterStatus: String = "All") {
        // Clear the submenu
        jobsSubmenu.removeAllItems()
        
        // Show filter message if needed
        if showFilterMessage && filterStatus != "All" {
            let filterItem = NSMenuItem(title: "Showing \(filterStatus) Jobs", action: nil, keyEquivalent: "")
            filterItem.isEnabled = false
            jobsSubmenu.addItem(filterItem)
            jobsSubmenu.addItem(NSMenuItem.separator())
        }
        
        if jobs.isEmpty {
            jobsSubmenu.addItem(NSMenuItem(title: "No jobs found", action: nil, keyEquivalent: ""))
            updateMenuBarIcon() // Update menu bar even if no jobs
            return
        }
        
        // Group jobs by state
        let runningJobs = jobs.filter { $0.status.stage == "RUNNING" }
        let completedJobs = jobs.filter { $0.status.stage == "COMPLETED" }
        let errorJobs = jobs.filter { $0.status.stage == "ERROR" }
        let otherJobs = jobs.filter { !["RUNNING", "COMPLETED", "ERROR"].contains($0.status.stage) }
        
        // Add sections for each state
        addJobsSection(title: "Running Jobs", jobs: runningJobs, to: jobsSubmenu)
        if !runningJobs.isEmpty && (!completedJobs.isEmpty || !errorJobs.isEmpty || !otherJobs.isEmpty) {
            jobsSubmenu.addItem(NSMenuItem.separator())
        }
        
        addJobsSection(title: "Completed Jobs", jobs: completedJobs, to: jobsSubmenu)
        if !completedJobs.isEmpty && (!errorJobs.isEmpty || !otherJobs.isEmpty) {
            jobsSubmenu.addItem(NSMenuItem.separator())
        }
        
        addJobsSection(title: "Failed Jobs", jobs: errorJobs, to: jobsSubmenu)
        if !errorJobs.isEmpty && !otherJobs.isEmpty {
            jobsSubmenu.addItem(NSMenuItem.separator())
        }
        
        addJobsSection(title: "Other Jobs", jobs: otherJobs, to: jobsSubmenu)
        
        // Update any open job detail windows with fresh data
        for job in jobs {
            if let windowController = activeJobWindows[job.id] {
                // TODO: handle state changes without clearing logs
                
                // windowController.updateJob(job)

                // // and the state has changed
                // if windowController.job.status.stage != job.status.stage {
                //     windowController.updateJob(job)
                // }
            }
        }
        
        // Update menu bar icon with running job count
        updateMenuBarIcon()

        // Update any open job detail windows with fresh data
        for job in jobs {
            if let windowController = activeJobWindows[job.id] {
                windowController.updateJob(job)
            }
        }

    }
    
    // Add a section of jobs to the menu
    private func addJobsSection(title: String, jobs: [HFJob], to menu: NSMenu) {
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
    
    // Add a job item to the menu
    private func addJobMenuItem(_ job: HFJob, to menu: NSMenu) {
        // Get a truncated version of the display name
        let shortNameDisplay = job.displayName.count > 20 ? "\(job.displayName.prefix(20))..." : job.displayName
        
        // Create the main menu item with the job name and status
        let itemTitle = "\(job.statusEmoji) [\(shortNameDisplay)] `\(job.formattedCommand)` (\(job.formattedCreationDate))"
        let item = NSMenuItem(title: itemTitle, action: #selector(openJobDetails(_:)), keyEquivalent: "")
        item.representedObject = job
        
        // Create submenu for job details and actions
        let jobSubmenu = NSMenu()
        
        // Add "Open Details" as the first item in the submenu
        let openDetailsItem = NSMenuItem(title: "Open Detailed View", action: #selector(openJobDetails(_:)), keyEquivalent: "o")
        openDetailsItem.representedObject = job
        jobSubmenu.addItem(openDetailsItem)
        
        jobSubmenu.addItem(NSMenuItem.separator())
        
        // Add detailed info items
        jobSubmenu.addItem(makeInfoMenuItem("Job ID: \(job.metadata.jobId)"))
        if let spaceId = job.spec.spaceId {
            jobSubmenu.addItem(makeInfoMenuItem("Space: \(spaceId)"))
        } else {
            jobSubmenu.addItem(makeInfoMenuItem("Space: N/A"))
        }
        jobSubmenu.addItem(makeInfoMenuItem("Docker Image: \(job.spec.dockerImage ?? "N/A")"))
        jobSubmenu.addItem(makeInfoMenuItem("Status: \(job.status.stage)"))
        jobSubmenu.addItem(makeInfoMenuItem("Created: \(job.metadata.createdAt)"))
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
        
        // TODO: revisit when cancel job action is available
        // // Cancel job action (only for running jobs)
        // if job.status.stage == "RUNNING" {
        //     let cancelJobItem = NSMenuItem(title: "Cancel Job", action: #selector(cancelJob(_:)), keyEquivalent: "")
        //     cancelJobItem.representedObject = job.metadata.jobId
        //     jobSubmenu.addItem(cancelJobItem)
        // }
        
        // Open in browser action (if spaceId is available)
        if let spaceId = job.spec.spaceId {
            let spaceUrl = "https://huggingface.co/spaces/\(spaceId)"
            let openInBrowserItem = NSMenuItem(title: "Open Space in Browser", action: #selector(openLink(_:)), keyEquivalent: "")
            openInBrowserItem.representedObject = spaceUrl
            jobSubmenu.addItem(openInBrowserItem)
        }
        
        item.submenu = jobSubmenu
        menu.addItem(item)
    }
    
    // Open job details window
    @objc func openJobDetails(_ sender: NSMenuItem) {
        guard let job = sender.representedObject as? HFJob else { return }
        
        // Check if window is already open
        if let existingWindow = activeJobWindows[job.id] {
            existingWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Create a new window controller for the job
        let windowController = JobDetailWindowController(job: job) { [weak self] in
            // Remove window from active windows when closed
            self?.activeJobWindows.removeValue(forKey: job.id)
        }
        
        // Store the window controller
        activeJobWindows[job.id] = windowController
        
        // Show the window
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
    
    // Helper to create an info menu item
    private func makeInfoMenuItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
    
    // Helper to add a menu item that opens a link
    private func addMenuItem(to menu: NSMenu, title: String, link: String) {
        let item = NSMenuItem(title: title, action: #selector(openLink(_:)), keyEquivalent: "")
        item.representedObject = link
        menu.addItem(item)
    }
    
    // MARK: - Status Change Detection
    
    // Detect changes in job status and show notifications
    private func detectStatusChanges(oldJobs: [HFJob], newJobs: [HFJob]) {
        print("Checking for status changes between \(oldJobs.count) old jobs and \(newJobs.count) new jobs")
        
        // Create dictionaries for quick lookup
        let oldJobsDict = Dictionary(uniqueKeysWithValues: oldJobs.map { ($0.id, $0) })
        let newJobsDict = Dictionary(uniqueKeysWithValues: newJobs.map { ($0.id, $0) })
        
        // Check for status changes in existing jobs
        for (jobId, oldJob) in oldJobsDict {
            if let newJob = newJobsDict[jobId] {
                // Job still exists - check if status changed
                if oldJob.status.stage != newJob.status.stage {
                    print("Status change detected: \(jobId) changed from \(oldJob.status.stage) to \(newJob.status.stage)")
                    NotificationService.shared.notifyJobStatusChange(oldJob: oldJob, newJob: newJob)
                    
                    // For completed jobs, add to history
                    if newJob.status.stage == "COMPLETED" {
                        var settings = AppSettings.shared
                        settings.addJobToHistory(newJob)
                    }
                }
            } else {
                // Job disappeared from the list
                print("Job disappeared: \(jobId) (previous status: \(oldJob.status.stage))")
                NotificationService.shared.notifyJobRemoved(oldJob)
                
                // If job was running, mark it as completed in history
                if oldJob.status.stage == "RUNNING" {
                    // Create a "completed" version of the job
                    var updatedJob = oldJob
                    var updatedStatus = oldJob.status
                    updatedStatus.stage = "COMPLETED"
                    updatedJob.status = updatedStatus
                    
                    var settings = AppSettings.shared
                    settings.addJobToHistory(updatedJob)
                }
            }
        }
        
        // Check for new jobs
        for (jobId, newJob) in newJobsDict {
            if oldJobsDict[jobId] == nil {
                print("New job detected: \(jobId) with status \(newJob.status.stage)")
                NotificationService.shared.notifyNewJob(newJob)
            }
        }
    }
    
    // MARK: - Actions
    
    // Copy text to clipboard
    @objc func copyText(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
    
    // Cancel a running job
    @objc func cancelJob(_ sender: NSMenuItem) {
        guard let jobId = sender.representedObject as? String else { return }
        
        // Confirm before canceling
        let alert = NSAlert()
        alert.messageText = "Cancel Job"
        alert.informativeText = "Are you sure you want to cancel this job? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Job")
        alert.addButton(withTitle: "Keep Running")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // User confirmed, cancel the job
            Task {
                do {
                    try await JobService.shared.cancelJob(jobId: jobId)
                    
                    // Show notification
                    NotificationService.shared.showNotification(
                        title: "Job Cancellation Requested",
                        body: "Job \(jobId) has been requested to cancel. It may take a moment to take effect."
                    )
                    
                    // Refresh jobs after a short delay to see updated status
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.refreshJobs()
                    }
                } catch {
                    // Show error
                    NotificationService.shared.showNotification(
                        title: "Job Cancellation Failed",
                        body: "Could not cancel job: \(JobService.shared.errorMessage(for: error))"
                    )
                }
            }
        }
    }
    
    // Open a link in the browser
    @objc func openLink(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
    
    // Clear job history
    @objc func clearJobHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Job History"
        alert.informativeText = "Are you sure you want to clear your job history? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            var settings = AppSettings.shared
            settings.clearJobHistory()
            
            NotificationService.shared.showNotification(
                title: "Job History Cleared",
                body: "Your job history has been cleared."
            )
        }
    }
    
    // MARK: - Polling Controls
    
    // Toggle real-time job polling
    @objc func togglePolling() {
        isPollingSwitchedOn.toggle()
        AppSettings.shared.pollingEnabled = isPollingSwitchedOn
        pollingMenuItem.title = "Auto-Refresh: \(isPollingSwitchedOn ? "On" : "Off")"
        
        if isPollingSwitchedOn {
            startPolling()
            NotificationService.shared.showNotification(
                title: "HF Jobs Polling",
                body: "Real-time status monitoring is now active"
            )
        } else {
            stopPolling()
            NotificationService.shared.showNotification(
                title: "HF Jobs Polling",
                body: "Real-time status monitoring is now disabled"
            )
        }
    }
    
    // Set the polling interval
    @objc func setPollingInterval(_ sender: NSMenuItem) {
        let interval = sender.tag
        AppSettings.shared.pollingInterval = interval
        
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
    
    // Start the polling timer
    func startPolling() {
        stopPolling() // Ensure we don't have multiple timers running
        
        let interval = TimeInterval(AppSettings.shared.pollingInterval)
        
        pollingTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(pollJobStatus), userInfo: nil, repeats: true)
        
        // Initial poll
        pollJobStatus()
    }
    
    // Stop the polling timer
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    // MARK: - Menu Settings
    
    // Toggle showing text in menu bar
    @objc func toggleShowTextInMenu() {
        // Toggle the setting
        AppSettings.shared.showTextInMenu = !AppSettings.shared.showTextInMenu
        
        // Update the menu bar with running job count
        updateMenuBarIcon()
        
        // Rebuild the menu to update the menu item text
        // createMenu()
        setupApp()
    }
    
    // Toggle notifications
    @objc func toggleNotifications() {
        // Toggle the setting
        AppSettings.shared.notificationsEnabled = !AppSettings.shared.notificationsEnabled
        
        // Rebuild the menu to update the menu item text
        createMenu()
        
        // Show feedback about the change
        if AppSettings.shared.notificationsEnabled {
            NotificationService.shared.showNotification(
                title: "Notifications Enabled",
                body: "You will now receive notifications for job status changes"
            )
        } else {
            print("Notifications disabled by user")
        }
    }
    
    // MARK: - Token and Username Management
    
    // Check if token exists, if not prompt for it
    func checkAndPromptForToken() -> Bool {
        if AppSettings.shared.token == nil {
            promptForToken()
            return false
        }
        return true
    }
    
    // Check if username exists, if not prompt for it
    func checkAndPromptForUsername() -> Bool {
        if AppSettings.shared.username == nil {
            promptForUsername()
            return false
        }
        return true
    }
    
    // Prompt for HF token
    @objc func promptForToken() {
        let alert = NSAlert()
        alert.messageText = "Hugging Face API Token"
        alert.informativeText = "Please enter your Hugging Face API token"
        alert.alertStyle = .informational
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "hf_..."
        
        // Pre-fill with existing token if available
        if let existingToken = AppSettings.shared.token {
            textField.stringValue = existingToken
        }
        
        alert.accessoryView = textField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let token = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                AppSettings.shared.token = token
                
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
    
    // Prompt for HF username
    @objc func promptForUsername() {
        let alert = NSAlert()
        alert.messageText = "Hugging Face Username"
        alert.informativeText = "Please enter your Hugging Face username"
        alert.alertStyle = .informational
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "username"
        
        // Pre-fill with existing username if available
        if let existingUsername = AppSettings.shared.username {
            textField.stringValue = existingUsername
        }
        
        alert.accessoryView = textField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let username = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                AppSettings.shared.username = username
                
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
    
    // Clean up on app termination
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