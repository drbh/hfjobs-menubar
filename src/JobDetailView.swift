import Cocoa
import SwiftUI
import OSLog
import Combine

// Observable class for job data
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

// Window controller for job details
class JobDetailWindowController: NSWindowController {
    private var jobObservable: JobObservable
    private var logObservable: LogsObservable
    private var metricsObservable: MetricsObservable
    private var onClose: (() -> Void)?
    private var metricsRefreshTimer: Timer?
    
    init(job: HFJob, onClose: (() -> Void)? = nil) {
        self.jobObservable = JobObservable(job: job)
        self.logObservable = LogsObservable()
        self.metricsObservable = MetricsObservable()
        self.onClose = onClose
        
        // Create the window with appropriate size
        // Define initial and minimum window size
        let initialWidth: CGFloat = 800
        let initialHeight: CGFloat = 1200
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        // Center the window on screen and enforce minimum size
        window.center()
        window.minSize = NSSize(width: initialWidth, height: initialHeight)
        
        // Use a unique autosave name based on job ID
        window.setFrameAutosaveName("JobDetailWindow-\(job.id)")
        
        // Initialize with the window
        super.init(window: window)
        
        // Create the SwiftUI view
        let contentView = JobDetailView(
            jobObservable: jobObservable,
            logObservable: logObservable,
            metricsObservable: metricsObservable,
            windowController: self  // Set the controller immediately
        )
        
        // Set the content view with proper sizing behavior
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false // Important for auto-layout
        window.contentView = hostingView
        
        // Apply auto-layout constraints to fill the window
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        
        // Set window title
        window.title = "Job: \(job.displayName)"
        
        // Set delegate
        window.delegate = self

        // Attempt to focus the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Fetch initial data
        print("🔄 Fetching initial job data")
        fetchJobData()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // Update job data
    func updateJob(_ job: HFJob) {
        print("🔄 Updating job data")
        
        // Check if there's a state change
        let oldState = jobObservable.job.status.stage
        let newState = job.status.stage
        let stateChanged = oldState != newState
        
        // Update the observable job
        jobObservable.update(job: job)
        
        // Update window title
        window?.title = "Job: \(job.displayName)"
        
        // Handle state transitions
        if stateChanged {
            print("📊 Job state changed from \(oldState) to \(newState)")
            
            // If job completed or failed, show notification
            if newState == "COMPLETED" || newState == "ERROR" {
                NotificationService.shared.showNotification(
                    title: "Job Status Changed",
                    body: "Job '\(job.displayName)' changed from \(oldState) to \(newState)"
                )
                
                // Stop streaming metrics but keep logs available
                MetricsService.shared.cancelMetricsStream()
            } else if newState == "RUNNING" && (oldState == "PENDING" || oldState == "QUEUED") {
                // If job just started running, refresh both logs and metrics
                fetchJobLogs()
                fetchJobMetrics()
            }
        } else {
            // Only update metrics and logs for running jobs
            if newState == "RUNNING" {
                // Only start metrics if not already streaming
                if metricsObservable.currentMetrics == nil {
                    fetchJobMetrics()
                }
                
                // Only start logs if not already streaming
                if logObservable.currentLogs == nil {
                    fetchJobLogs()
                }
            }
        }
    }

    private func shouldRefreshData(oldJob: HFJob, newJob: HFJob) -> Bool {
        // Always refresh if status changed
        if oldJob.status.stage != newJob.status.stage {
            return true
        }
        
        // For running jobs, refresh every minute
        if newJob.status.stage == "RUNNING" {
            guard let oldDate = oldJob.creationDate, let newDate = newJob.creationDate else {
                return true
            }
            
            // Check if it's been more than 60 seconds since last refresh
            return newDate.timeIntervalSince(oldDate) > 60
        }
        
        return false
    }
    
    // Implement NSWindowDelegate to handle window resizing
    func windowDidResize(_ notification: Notification) {
        window?.contentView?.needsLayout = true
        window?.contentView?.layout()
    }

    // Cancel the job
    func cancelJob(_ job: HFJob) {
        // Confirm cancellation
        let alert = NSAlert()
        alert.messageText = "Cancel Job"
        alert.informativeText = "Are you sure you want to cancel this job? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Job")
        alert.addButton(withTitle: "Keep Running")
        
        guard let window = self.window else { return }
        
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                // User confirmed cancel
                Task {
                    do {
                        try await JobService.shared.cancelJob(jobId: job.id)
                        
                        await MainActor.run {
                            // Show success message
                            self.showNotification(
                                title: "Cancellation Requested",
                                message: "The job cancellation has been requested. It may take a moment to complete."
                            )
                            
                            // Update job status after a delay to reflect cancellation
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                Task {
                                    do {
                                        let updatedJob = try await JobService.shared.fetchJobById(jobId: job.id)
                                        self.updateJob(updatedJob)
                                    } catch {
                                        print("Error updating job after cancellation: \(error)")
                                    }
                                }
                            }
                        }
                    } catch {
                        // Show error message
                        await MainActor.run {
                            self.showNotification(
                                title: "Cancellation Failed",
                                message: "Failed to cancel the job: \(JobService.shared.errorMessage(for: error))"
                            )
                        }
                    }
                }
            }
        }
    }
    
    private func showNotification(title: String, message: String) {
        guard let window = self.window else { return }
        
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        
        alert.beginSheetModal(for: window) { _ in }
    }
    
    private func fetchJobData() {
        print("🔄 Fetching job data")
        
        
        fetchJobLogs()
        
        if jobObservable.job.status.stage != "COMPLETED" && jobObservable.job.status.stage != "ERROR" {
            fetchJobMetrics()
        }
    }
    
    private func fetchJobLogs() {
        print("🔄 Fetching job logs")
        
        logObservable.reset()
        
        // Get the job ID
        let jobId = jobObservable.job.id
        
        // Start streaming logs
        _ = LogsStreamService.shared.streamJobLogs(
            jobId: jobId,
            includeTimestamps: true,
            delegate: JobLogsStreamHandler(logsObservable: logObservable)
        )
    }
    
    private func fetchJobMetrics() {
        metricsObservable.reset()

        let jobId = jobObservable.job.id

        // Start streaming metrics
        _ = MetricsService.shared.streamJobMetrics(
            jobId: jobId,
            delegate: JobMetricsStreamHandler(metricsObservable: metricsObservable)
        )
    }
}

// Make JobDetailWindowController conform to NSWindowDelegate
extension JobDetailWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Clean up resources
        LogsStreamService.shared.cancelLogStream()
        MetricsService.shared.cancelMetricsStream()
        
        // Call closure when window is closed
        onClose?()
    }
}

// MARK: - Job Detail View
struct JobDetailView: View {
    @ObservedObject var jobObservable: JobObservable
    @ObservedObject var logObservable: LogsObservable
    @ObservedObject var metricsObservable: MetricsObservable
    @State private var isLogsExpanded: Bool = true
    @State private var isDetailsExpanded: Bool = true
    @State private var isMetricsExpanded: Bool = true
    @State private var showTimestamps: Bool = true
    @State private var selectedTab: Int = 0
    @State private var refreshTimer: Publishers.Autoconnect<Timer.TimerPublisher>? = nil
    @State private var jobDetailsExpanded: Bool = false
    
    // Window management
    var job: HFJob { jobObservable.job }
    var windowController: NSWindowController?

    // State + timer to tick every second
    @State private var currentDate = Date()
    private let timer = Timer
        .publish(every: 1, on: .main, in: .common)
        .autoconnect()
    
    // Grid layout for details section
    private let columns = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.flexible(), alignment: .leading)
    ]
    
    var body: some View {
        mainContentView
    }
    
    // Break down the large body into smaller components
    private var mainContentView: some View {

        VStack(alignment: .leading, spacing: 16) {
            // Header bar
            jobHeaderBar
            // Content tabs
            contentTabsView
        }
        .frame(minWidth: 600, minHeight: 800)
    }
    
    private var contentTabsView: some View {
        TabView(selection: $selectedTab) {
            // Main status tab
            statusTabView
                .tabItem {
                    Label("Status", systemImage: "info.circle")
                }
                .tag(0)
            
            // Full logs tab
            logsTabView
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
                .tag(1)
        }
    }
    
    private var statusTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Spacer()

                // Metrics section
                metricsSection
                
                Divider()
                    .padding(.horizontal)
                
                logsSection
                
                Spacer()
            }
            .padding(.vertical)
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Logs section header
            HStack {
                Text("Logs")
                    .font(.headline)
                
                Spacer()
                
                if job.status.stage == "RUNNING" || job.status.stage == "UPDATING" {
                    Text("Live Logs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            
            // Logs content
            logsContentView
            
            Spacer()
        }
        .padding(.vertical)
    }
    
    @ViewBuilder
    private var logsContentView: some View {
        if logObservable.isLoading {
            LogsLoadingView()
        } else if let errorMessage = logObservable.errorMessage {
            LogsErrorView(message: errorMessage) {
                // Retry function
                if let detailController = windowController as? JobDetailWindowController {
                    detailController.updateJob(job)
                }
            }
        } else if let logs = logObservable.currentLogs {
            LogsSummaryView(logs: logs, showTimestamps: $showTimestamps)
        } else {
            LogsLoadingView()
        }
    }
    
    private var logsRefreshIndicator: some View {
        HStack {
            Spacer()
            if refreshTimer != nil {
                Text("Auto-refreshing logs...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button("Refresh Logs") {
                    if let detailController = windowController as? JobDetailWindowController {
                        detailController.updateJob(job)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.blue.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(4)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
    
    private var logsDisclosureLabel: some View {
        HStack {
            Text("Logs")
                .font(.headline)
            
            Spacer()
            
            if job.status.stage == "RUNNING" || job.status.stage == "UPDATING" {
                // Live indicator for running jobs
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Toggle between collapsed/expanded
            Image(systemName: isLogsExpanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
    }
    
    private var logsTabView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top bar with controls
            logsTabTopBar
            
            Divider()
            
            // Full height logs
            logsTabContent
        }
        .padding(.vertical)
    }
    
    private var logsTabTopBar: some View {
        HStack {
            // TODO: revisit timestamp toggle
            // Toggle("Show Timestamps", isOn: $showTimestamps)
            //     .toggleStyle(.switch)
            
            Spacer()
            
            Button("Refresh") {
                if let detailController = windowController as? JobDetailWindowController {
                    detailController.updateJob(job)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.blue.opacity(0.8))
            .foregroundColor(.white)
            .cornerRadius(4)
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var logsTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if logObservable.isLoading {
                LogsLoadingView()
                    .frame(height: 300)
            } else if let errorMessage = logObservable.errorMessage {
                logsErrorContent(errorMessage)
            } else if let logs = logObservable.currentLogs {
                logsEntriesContent(logs)
            } else {
                LogsLoadingView()
                    .frame(height: 300)
            }
        }
    }
    
    private func logsErrorContent(_ errorMessage: String) -> some View {
        VStack(spacing: 8) {
            Text("Logs Error: \(errorMessage)")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("Retry") {
                if let detailController = windowController as? JobDetailWindowController {
                    detailController.updateJob(job)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.blue.opacity(0.8))
            .foregroundColor(.white)
            .cornerRadius(4)
        }
        .padding()
        .frame(height: 300)
    }
    
    private func logsEntriesContent(_ logs: HFJobLogs) -> some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // Use LazyVStack to improve performance with large log lists
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logs.logEntries.indices, id: \.self) { index in
                            LogEntryRow(entry: logs.logEntries[index], showTimestamp: showTimestamps)
                        }
                    }
                    .padding(.horizontal, 8)


                    // Add invisible view at the end for scrolling target
                    Color.clear
                        .frame(height: 1)
                        .id("logsEnd")
                }
                .onAppear {
                    // Scroll to the bottom when view appears
                    proxy.scrollTo("logsEnd", anchor: .bottom)
                }
            }
            .background(Color(.textBackgroundColor))
            .cornerRadius(8)
        }
        .padding(.horizontal)
    }

    private var sinceStartString: String {
        guard let start = job.creationDate else { return "--" }
        
        // For completed or error jobs, show start to end times
        if job.status.stage == "COMPLETED" || job.status.stage == "ERROR" {
            // We don't have an actual end time, so estimate based on the status change
            // In a real implementation, you might want to store the completion time
            let formattedStart = formatDate(start)
            return "Start: \(formattedStart)"
        } else {
            // For running jobs, show runtime in real-time
            let elapsed = currentDate.timeIntervalSince(start)
            return "Runtime: \(formatElapsed(elapsed))"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        
        // Switch format based on duration
        if interval >= 86400 { // > 1 day
            formatter.allowedUnits = [.day, .hour, .minute]
        } else if interval >= 3600 { // > 1 hour
            formatter.allowedUnits = [.hour, .minute, .second]
        } else {
            formatter.allowedUnits = [.minute, .second]
        }
        
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: interval) ?? "0s"
    }

    private var jobHeaderBar: some View {
        VStack(spacing: 4) {
            // Top row: Job name, status and indicators in a compact layout
            HStack(alignment: .center, spacing: 8) {
                // Left side: Job name with space link
                HStack(spacing: 4) {
                    Text(job.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    
                    if let spaceId = job.spec.spaceId, !spaceId.isEmpty {
                        Button {
                            if let spaceURL = job.spaceURL {
                                NSWorkspace.shared.open(spaceURL)
                            }
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Open space in browser")
                        .focusable(false)
                    }
                }
                
                // Error message if present
                if let message = job.status.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    // Status pill
                    HStack(spacing: 4) {
                        Image(systemName: job.status.stage == "RUNNING" || job.status.stage == "UPDATING" 
                            ? "circle.fill" : "circle")
                            .foregroundColor(Color(hex: job.statusColor))
                            .frame(width: 10, height: 10)
                        
                        Text(job.status.stage)
                            .font(.caption.bold())
                            .foregroundColor(Color(hex: job.statusColor))
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(Color(hex: job.statusColor).opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    // Right side: Runtime or timing information with clock icon
                    HStack(spacing: 6) {
                        // Clock icon differs based on job status
                        Image(systemName: job.status.stage == "RUNNING" ? "clock.arrow.circlepath" : "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(sinceStartString)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Main details in a 3-column grid to maximize horizontal space
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], alignment: .leading, spacing: 8) {
                // Row 1: ID, Owner, Hardware
                detailItem(label: "ID", value: job.id.prefix(10) + "...")
                detailItem(label: "Owner", value: job.metadata.owner.name)
                detailItem(label: "Hardware", value: job.spec.flavor)
                
                // Row 2: Created, Docker Image/Command
                if let date = job.creationDate {
                    detailItem(label: "Created", value: date.formatted(date: .abbreviated, time: .shortened))
                } else {
                    detailItem(label: "Created", value: job.metadata.createdAt)
                }
                
                // Command (spans 2 columns)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Command")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(job.spec.command.joined(separator: " "))
                        .font(.caption)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .gridCellColumns(2)
            }
            .padding(.top, 4)
        }
        .padding(8) // Reduced padding
        .background(Color(.windowBackgroundColor).opacity(0.5))
        .onReceive(timer) { now in
            self.currentDate = now
        }
    }

    // Helper function for detail items
    private func detailItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
        }
    }

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            
            // Metrics content
            if job.status.stage == "COMPLETED" || job.status.stage == "ERROR" {
                Text("Metrics are only available for running jobs")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let metrics = metricsObservable.currentMetrics {
                // Charts section
                if #available(macOS 13.0, iOS 16.0, *) {
                    MetricsLineChart(data: metricsObservable.getTimeSeriesData())
                        .frame(height: 200)
                        .padding(.horizontal)
                } 
                
                // Enhanced metrics summary card
                enhancedMetricsCard(metrics: metrics)
                    .padding(.horizontal)
                
                // Network card
                networkMetricsCard(metrics: metrics)
                    .padding(.horizontal)
                    .padding(.top, 4)
                
                // GPU cards if available
                if !metrics.gpus.isEmpty {
                    gpuMetricsCards(metrics: metrics)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
            } else if metricsObservable.isLoading {
                MetricsLoadingView()
            } else if let error = metricsObservable.errorMessage {
                MetricsErrorView(message: error)
            } else {
                MetricsUnavailableView()
            }
        }
    }

    // Enhanced metrics card with percentages and nominal values
    private func enhancedMetricsCard(metrics: HFJobMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resource Usage")
                .font(.headline)
                .padding(.bottom, 2)
            
            // CPU usage with both percentage and cores
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CPU Usage")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    let cpuUsagePct = metrics.cpuUsagePct
                    let cpuCoresUsed = Double(metrics.cpuMillicores) / 1000.0
                    let totalCores: Int = {
                        guard cpuUsagePct > 0 else { return 0 }
                        return Int(ceil(cpuCoresUsed / (cpuUsagePct / 100.0)))
                    }()

                    Text(String(format: "%.1f%% (%.2f cores of %d)", 
                                cpuUsagePct, 
                                cpuCoresUsed, 
                                totalCores))
                        .font(.subheadline)
                        .monospacedDigit()

                }
                
                // Progress bar for CPU
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        Rectangle()
                            .frame(width: geometry.size.width, height: 8)
                            .opacity(0.2)
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                        
                        // Progress
                        Rectangle()
                            .frame(width: min(CGFloat(metrics.cpuUsagePct) * geometry.size.width / 100, geometry.size.width), height: 8)
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)
            }
            
            // Memory usage with both percentage and size
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Memory Usage")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Text(String(format: "%.1f%% (%@ of %@)", 
                            metrics.memoryUsagePercent,
                            metrics.memoryUsedFormatted,
                            metrics.memoryTotalFormatted))
                        .font(.subheadline)
                        .monospacedDigit()
                }
                
                // Progress bar for Memory
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        Rectangle()
                            .frame(width: geometry.size.width, height: 8)
                            .opacity(0.2)
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                        
                        // Progress
                        Rectangle()
                            .frame(width: min(CGFloat(metrics.memoryUsagePercent) * geometry.size.width / 100, geometry.size.width), height: 8)
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)
            }
        }
        .padding()
        .background(Color(.textBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }

    // Network metrics card
    private func networkMetricsCard(metrics: HFJobMetrics) -> some View {
        HStack(spacing: 20) {
            // Download
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.green)
                    Text("Download")
                        .font(.subheadline)
                }
                Text(metrics.networkRxFormatted)
                    .font(.title3)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Upload  
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: "arrow.up.circle")
                        .foregroundColor(.blue)
                    Text("Upload")
                        .font(.subheadline)
                }
                Text(metrics.networkTxFormatted)
                    .font(.title3)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.textBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }

    // GPU metrics cards
    private func gpuMetricsCards(metrics: HFJobMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GPU Resources")
                .font(.headline)
                .padding(.bottom, 2)
            
            ForEach(Array(metrics.gpus.keys.sorted()), id: \.self) { gpuName in
                if let gpu = metrics.gpus[gpuName] {
                    singleGpuCard(name: gpuName, gpu: gpu)
                }
            }
        }
    }

    // Single GPU card
    private func singleGpuCard(name: String, gpu: GPUMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name)
                .font(.headline)
                .padding(.bottom, 2)
            
            // GPU utilization with percentage
            if let utilization = gpu.gpuUtilization {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("GPU Utilization")
                            .font(.subheadline)
                        
                        Spacer()
                        
                        Text(String(format: "%.1f%%", utilization))
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    
                    // Progress bar for GPU
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            Rectangle()
                                .frame(width: geometry.size.width, height: 8)
                                .opacity(0.2)
                                .foregroundColor(.green)
                                .cornerRadius(4)
                            
                            // Progress
                            Rectangle()
                                .frame(width: min(CGFloat(utilization) * geometry.size.width / 100, geometry.size.width), height: 8)
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }
                    }
                    .frame(height: 8)
                }
            }
            
            // GPU memory with percentage and size
            if let memUtil = gpu.memoryUtilization, 
            let memUsed = gpu.memoryUsedBytes, 
            let memTotal = gpu.memoryTotalBytes {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("GPU Memory")
                            .font(.subheadline)
                        
                        Spacer()
                        
                        Text(String(format: "%.1f%% (%@ of %@)", 
                                memUtil,
                                gpu.memoryUsedFormatted,
                                gpu.memoryTotalFormatted))
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    
                    // Progress bar for GPU Memory
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            Rectangle()
                                .frame(width: geometry.size.width, height: 8)
                                .opacity(0.2)
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                            
                            // Progress
                            Rectangle()
                                .frame(width: min(CGFloat(memUtil) * geometry.size.width / 100, geometry.size.width), height: 8)
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }
                    .frame(height: 8)
                }
            }
            
            // GPU temperature if available
            if let temp = gpu.temperature {
                HStack {
                    Text("Temperature")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Text(gpu.temperatureFormatted)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundColor(temperatureColor(temp))
                }
            }
        }
        .padding()
        .background(Color(.textBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }

    // Helper function to determine temperature color
    private func temperatureColor(_ temp: Double) -> Color {
        if temp > 85 {
            return .red
        } else if temp > 75 {
            return .orange
        } else if temp > 65 {
            return .yellow
        } else {
            return .green
        }
    }
}

// MARK: - Color Extensions
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
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Status Section
struct JobStatusSection: View {
    let job: HFJob
    @Binding var expanded: Bool
    
    var body: some View {
        DisclosureGroup(
            isExpanded: $expanded,
            content: {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 24) {
                        // Status info
                        VStack(alignment: .leading) {
                            Text("Status")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Text(job.status.stage)
                                .font(.title2)
                                .foregroundColor(Color(hex: job.statusColor))
                                .fontWeight(.bold)
                        }
                        
                        // Status message if available
                        if let message = job.status.message, !message.isEmpty {
                            VStack(alignment: .leading) {
                                Text("Message")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                Text(message)
                                    .font(.body)
                            }
                        }
                    }
                    .padding(.vertical)
                }
            },
            label: {
                HStack {
                    Text("Status")
                        .font(.headline)
                    
                    Spacer()
                    
                    // Visual status indicator
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: job.statusColor))
                            .frame(width: 12, height: 12)
                        
                        Text(job.status.stage)
                            .fontWeight(.semibold)
                            .foregroundColor(Color(hex: job.statusColor))
                    }
                    
                    // Toggle between collapsed/expanded
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
        )
    }
}