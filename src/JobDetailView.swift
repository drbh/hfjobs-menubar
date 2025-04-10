import Cocoa
import SwiftUI
import OSLog
import Combine
// MARK: - Job Detail Window Controller
class JobDetailWindowController: NSWindowController {
    var job: HFJob
    var onClose: (() -> Void)?
    private var logStreamDelegate: JobLogStreamHandler?
    
    init(job: HFJob, onClose: (() -> Void)? = nil) {
        self.job = job
        self.onClose = onClose
        
        // Create a window with appropriate size and style
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Job: \(job.displayName)"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        
        // Create the job detail view and its view model
        let jobObservable = JobObservable(job: job)
        let logObservable = LogObservable(initialLogs: "Loading logs...")
        
        // Create the log stream handler with the observable
        logStreamDelegate = JobLogStreamHandler(logObservable: logObservable)
        
        // Create the job detail view
        let jobDetailView = JobDetailView(
            jobObservable: jobObservable,
            logObservable: logObservable,
            windowController: self
        )
        
        window.contentView = NSHostingView(rootView: jobDetailView)
        
        // Start log stream
        startLogStream()
        
        // Fetch complete logs if not running
        if job.status.stage != "RUNNING" && job.status.stage != "UPDATING" {
            fetchCompleteLogs()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateJob(_ updatedJob: HFJob) {
        let oldStatus = self.job.status.stage
        self.job = updatedJob
        let newStatus = updatedJob.status.stage
        
        // Update window title
        window?.title = "Job: \(job.displayName)"
        
        // Update content using the JobObservable
        if let hostingView = window?.contentView as? NSHostingView<JobDetailView> {
            hostingView.rootView.jobObservable.update(job: updatedJob)
        }
        
        // Handle log streaming based on job status changes
        if oldStatus != newStatus {
            if newStatus == "RUNNING" || newStatus == "UPDATING" {
                // Job has started or resumed running
                startLogStream()
            } else if (oldStatus == "RUNNING" || oldStatus == "UPDATING") && 
                      (newStatus != "RUNNING" && newStatus != "UPDATING") {
                // Job has just completed - fetch full logs one more time
                JobService.shared.cancelLogStream()
                fetchCompleteLogs()
            }
        } else if newStatus == "RUNNING" || newStatus == "UPDATING" {
            // Status unchanged but still running - ensure log stream is active
            if logStreamDelegate?.onLogUpdate == nil {
                startLogStream()
            }
        }
    }
    
    private func startLogStream() {
        // Stop any existing stream
        JobService.shared.cancelLogStream()
        
        guard let logStreamDelegate = logStreamDelegate else { return }
        
        // Add connecting message to buffer and update UI
        logStreamDelegate.logBuffer = ["Connecting to log stream for running job..."]
        logStreamDelegate.updateFormattedLogs()
        
        _ = JobService.shared.streamJobLogs(
            jobId: job.id,
            includeTimestamps: true, 
            delegate: logStreamDelegate
        )
    }
    
    private func fetchCompleteLogs() {
        // First update UI to show loading message
        logStreamDelegate?.updateLogsWithMessage("Fetching logs for job \(job.id)...")
        
        Task {
            _ = JobService.shared.streamJobLogs(
                jobId: job.id,
                includeTimestamps: true,
                delegate: logStreamDelegate!
            )
        }
    }
    
    deinit {
        JobService.shared.cancelLogStream()
        onClose?()
    }
}
// MARK: - Observable Objects for SwiftUI
// Observable object to track job updates
class JobObservable: ObservableObject {
    @Published var job: HFJob
    
    init(job: HFJob) {
        self.job = job
    }
    
    func update(job: HFJob) {
        DispatchQueue.main.async {
            self.job = job
        }
    }
}
// Observable object to track log updates
class LogObservable: ObservableObject {
    @Published var logs: String
    
    init(initialLogs: String = "Loading logs...") {
        self.logs = initialLogs
    }
    
    func updateLogs(_ newLogs: String) {
        DispatchQueue.main.async {
            self.logs = newLogs
        }
    }
}
// MARK: - Job Log Stream Handler
class JobLogStreamHandler: JobLogStreamDelegate {
    var logBuffer: [String] = []
    var onLogUpdate: ((String) -> Void)?
    private var hasReceivedLogs = false
    private var logObservable: LogObservable
    private var seenLogLines = Set<String>() // Track unique log lines
    
    init(logObservable: LogObservable) {
        self.logObservable = logObservable
        
        // Set up the onLogUpdate handler to update the observable
        self.onLogUpdate = { [weak logObservable] logs in
            logObservable?.updateLogs(logs)
        }
    }
    
    func updateLogsWithMessage(_ message: String) {
        logBuffer = [message]
        updateFormattedLogs()
    }
    
    func didReceiveLogLine(_ line: String, timestamp: Date?) {
        if !hasReceivedLogs {
            // First log received - clear any connecting messages
            if logBuffer.count == 1 && (logBuffer.first?.contains("Connecting") == true || 
                                        logBuffer.first?.contains("Loading") == true) {
                logBuffer.removeAll()
            }
            hasReceivedLogs = true
        }
        
        // Format logs with timestamps if available
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        let formattedLine: String
        if let timestamp = timestamp {
            formattedLine = "[\(dateFormatter.string(from: timestamp))] \(line)"
        } else {
            formattedLine = line
        }
        
        // Check if we've already seen this exact log line to avoid duplicates
        let uniqueKey = formattedLine
        if !seenLogLines.contains(uniqueKey) {
            // Add to our seen set and buffer
            seenLogLines.insert(uniqueKey)
            logBuffer.append(formattedLine)
            
            // Limit buffer size to prevent excessive memory usage
            if logBuffer.count > 1000 {
                // Remove oldest entries
                logBuffer.removeFirst(logBuffer.count - 1000)
                // Also remove from seen set if removed from buffer
                // for oldLine in removed {
                //     seenLogLines.remove(oldLine)
                // }
            }
            
            updateFormattedLogs()
        }
    }
    
    func didEncounterError(_ error: Error) {
        let errorMessage = JobService.shared.errorMessage(for: error)
        
        // Only clear buffer if it just contains the connecting message
        if !hasReceivedLogs && logBuffer.count == 1 && 
           (logBuffer.first?.contains("Connecting") == true || logBuffer.first?.contains("Loading") == true) {
            logBuffer.removeAll()
        }
        
        // Create a unique error message with timestamp
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let uniqueErrorMsg = "⚠️ [\(timestamp)] Error: \(errorMessage)"
        
        if !seenLogLines.contains(uniqueErrorMsg) {
            seenLogLines.insert(uniqueErrorMsg)
            logBuffer.append(uniqueErrorMsg)
            updateFormattedLogs()
        }
    }
    
    func didCompleteStream() {
        // Only add the end marker if we actually received logs or have content
        if hasReceivedLogs || !logBuffer.isEmpty {
            let endMarker = "\n--- End of logs ---"
            if !seenLogLines.contains(endMarker) {
                seenLogLines.insert(endMarker)
                logBuffer.append(endMarker)
                updateFormattedLogs()
            }
        }
    }
    
    func updateFormattedLogs() {
        let formattedLogs = logBuffer.joined(separator: "\n")
        
        // Update UI via the published property
        DispatchQueue.main.async {
            self.logObservable.updateLogs(formattedLogs)
            
            // Also call the legacy callback if set
            self.onLogUpdate?(formattedLogs)
        }
    }
}
// MARK: - SwiftUI Job Detail View
struct JobDetailView: View {
    @ObservedObject var jobObservable: JobObservable
    @ObservedObject var logObservable: LogObservable
    @State private var isLogsExpanded: Bool = true
    @State private var isDetailsExpanded: Bool = true
    @State private var showTimestamps: Bool = true
    
    weak var windowController: JobDetailWindowController?
    
    var job: HFJob { jobObservable.job }
    var jobLogs: String { logObservable.logs }
    
    init(jobObservable: JobObservable, logObservable: LogObservable, windowController: JobDetailWindowController?) {
        self.jobObservable = jobObservable
        self.logObservable = logObservable
        self.windowController = windowController
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with status
            HStack {
                Text(job.statusEmoji)
                    .font(.system(size: 24))
                Text(job.displayName)
                    .font(.title)
                    .lineLimit(1)
                Spacer()
                Text(job.status.stage)
                    .font(.headline)
                    .padding(6)
                    .background(Color(hex: job.statusColor))
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Details section
                    DisclosureGroup(
                        isExpanded: $isDetailsExpanded,
                        content: {
                            VStack(alignment: .leading, spacing: 8) {
                                detailRow(label: "Job ID", value: job.metadata.jobId)
                                detailRow(label: "Owner", value: job.metadata.owner.name)
                                detailRow(label: "Created", value: job.metadata.createdAt)
                                if let spaceId = job.spec.spaceId {
                                    detailRow(label: "Space", value: spaceId)
                                }
                                detailRow(label: "Flavor", value: job.spec.flavor)
                                if let dockerImage = job.spec.dockerImage {
                                    detailRow(label: "Docker Image", value: dockerImage)
                                }
                                detailRow(label: "Command", value: job.spec.command.joined(separator: " "))
                                if let message = job.status.message {
                                    detailRow(label: "Status Message", value: message)
                                }
                            }
                            .padding(.vertical)
                        },
                        label: {
                            HStack {
                                Text("Job Details")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                    )
                    .padding(.horizontal)
                    
                    Divider()
                    
                    // Logs section
                    DisclosureGroup(
                        isExpanded: $isLogsExpanded,
                        content: {
                            VStack(alignment: .leading, spacing: 8) {
                                // Log control toolbar
                                HStack {
                                    Toggle("Show Timestamps", isOn: $showTimestamps)
                                        .toggleStyle(.switch)
                                    
                                    Spacer()
                                    
                                    Button(action: { 
                                        copyLogs()
                                    }) {
                                        Label("Copy Logs", systemImage: "doc.on.doc")
                                    }
                                }
                                .padding(.bottom, 4)
                                
                                // Log content
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        Text(processedLogs)
                                            .font(.system(.body, design: .monospaced))
                                            .lineLimit(nil)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding()
                                            .id("logsEnd")
                                            .onChange(of: jobLogs) { oldValue, newValue in
                                                // Auto-scroll to the bottom when logs update
                                                proxy.scrollTo("logsEnd", anchor: .bottom)
                                            }
                                    }
                                    .frame(minHeight: 300)
                                }
                                .background(Color(.textBackgroundColor))
                                .cornerRadius(4)
                            }
                            .padding(.vertical, 8)
                        },
                        label: {
                            HStack {
                                Text("Job Logs")
                                    .font(.headline)
                                Spacer()
                                if job.status.stage == "RUNNING" || job.status.stage == "UPDATING" {
                                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                }
                            }
                        }
                    )
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            
            Divider()
            
            // Action buttons
            HStack {
                // TODO: revisit when cancel job action is available
                // if job.status.stage == "RUNNING" || job.status.stage == "UPDATING" {
                //     Button("Cancel Job") {
                //         confirmCancelJob()
                //     }
                //     .keyboardShortcut(.cancelAction)
                // }
                
                if let spaceId = job.spec.spaceId {
                    Button("Open Space") {
                        if let url = URL(string: "https://huggingface.co/spaces/\(spaceId)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                
                Spacer()
                
                // Copy Job ID button
                Button("Copy Job ID") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(job.id, forType: .string)
                }
                
                // Refresh button
                Button("Refresh") {
                    refreshJobDetails()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            .padding()
        }
    }
    
    // Process logs to handle timestamp display preference
    private var processedLogs: String {
        if showTimestamps {
            return jobLogs
        } else {
            // Remove timestamp patterns like [2023-01-01 12:34:56]
            return jobLogs.replacingOccurrences(
                of: "\\[\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}(.\\d{3})?\\] ",
                with: "",
                options: .regularExpression
            )
        }
    }
    
    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .lineLimit(nil)
                .textSelection(.enabled)
        }
    }
    
    private func refreshJobDetails() {
        Task {
            do {
                let updatedJob = try await JobService.shared.fetchJobById(jobId: job.id)
                await MainActor.run {
                    windowController?.updateJob(updatedJob)
                }
            } catch {
                print("Error refreshing job: \(error)")
            }
        }
    }
    
    private func confirmCancelJob() {
        let alert = NSAlert()
        alert.messageText = "Cancel Job"
        alert.informativeText = "Are you sure you want to cancel this job? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Job")
        alert.addButton(withTitle: "Keep Running")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // User confirmed cancel
            cancelJob()
        }
    }
    
    private func cancelJob() {
        Task {
            do {
                try await JobService.shared.cancelJob(jobId: job.id)
                
                NotificationService.shared.showNotification(
                    title: "Job Cancellation Requested",
                    body: "Job \(job.id) has been requested to cancel. It may take a moment to take effect."
                )
                
                // Refresh after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    refreshJobDetails()
                }
            } catch {
                NotificationService.shared.showNotification(
                    title: "Job Cancellation Failed",
                    body: "Could not cancel job: \(JobService.shared.errorMessage(for: error))"
                )
            }
        }
    }
    
    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(processedLogs, forType: .string)
    }
}
// MARK: - Helper Extensions
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}