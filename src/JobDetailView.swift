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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), // More appropriate default size
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        // Center the window on screen
        window.center()
        
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
        
        jobObservable.update(job: job)
        
        // Update window title
        window?.title = "Job: \(job.displayName)"

        // only fetch metrics if not COMPLETED
        if job.status.stage != "COMPLETED" && job.status.stage != "ERROR" {
            // Fetch job logs
            fetchJobLogs()
            
            // Fetch job metrics
            fetchJobMetrics()
        }
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
        .frame(minWidth: 600, minHeight: 1000)
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
            VStack(alignment: .leading, spacing: 16) {
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
        VStack(alignment: .leading, spacing: 16) {
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
                    VStack(alignment: .leading, spacing: 2) {
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


    // Modify the jobHeaderBar to include job details
    private var jobHeaderBar: some View {
        VStack(spacing: 8) {
            HStack {
                // Job name and status
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
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
                    
                    HStack(spacing: 6) {
                        // Text(job.statusEmoji)
                        Text(job.status.stage)
                            .font(.subheadline)
                            .foregroundColor(Color(hex: job.statusColor))
                        
                        if let message = job.status.message, !message.isEmpty {
                            Text("- \(message)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                
                Spacer()
                
                // Actions
                HStack(spacing: 12) {
                    Text(job.formattedCreationDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Show staus badge in all states
                    if job.status.stage == "RUNNING" || job.status.stage == "UPDATING" {
                        Image(systemName: "circle.fill")
                            .foregroundColor(Color(hex: job.statusColor))
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "circle")
                            .foregroundColor(Color(hex: job.statusColor))
                            .frame(width: 12, height: 12)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                // Job details grid
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    // Job ID
                    VStack(alignment: .leading) {
                        Text("Job ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(job.id)
                            .font(.caption)
                            .monospaced()
                    }
                    
                    // Owner
                    VStack(alignment: .leading) {
                        Text("Owner")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(job.metadata.owner.name)
                            .font(.caption)
                    }
                    
                    // Hardware Flavor
                    VStack(alignment: .leading) {
                        Text("Hardware")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(job.spec.flavor)
                            .font(.caption)
                    }
                    
                    // Creation Date
                    VStack(alignment: .leading) {
                        Text("Created")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let date = job.creationDate {
                            Text(date, style: .date)
                                .font(.caption)
                        } else {
                            Text(job.metadata.createdAt)
                                .font(.caption)
                        }
                    }
                    
                    // Docker Image
                    if let dockerImage = job.spec.dockerImage, !dockerImage.isEmpty {
                        VStack(alignment: .leading) {
                            Text("Docker Image")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(dockerImage)
                                .font(.caption)
                                .monospaced()
                                .lineLimit(1)
                        }
                        .gridCellColumns(2)
                    }
                    
                    // Command
                    VStack(alignment: .leading) {
                        Text("Command")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(job.spec.command.joined(separator: " "))
                            .font(.caption)
                            .monospaced()
                            .lineLimit(2)
                    }
                    .gridCellColumns(2)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
        .padding()
        .background(Color(.windowBackgroundColor).opacity(0.5))
    }

        
    // MARK: - Metrics Section
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Text("Metrics")
                    .font(.headline)
                
                Spacer()
                
                if job.status.stage == "RUNNING" {
                    Text("Updating as events stream in")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            
            // Metrics content
            if job.status.stage == "COMPLETED" {
                Text("Metrics are only available for running jobs")
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let metrics = metricsObservable.currentMetrics {
                MetricsGridView(metrics: metrics)
            } else if metricsObservable.isLoading {
                MetricsLoadingView()
            } else if let error = metricsObservable.errorMessage {
                MetricsErrorView(message: error)
            } else {
                MetricsUnavailableView()
            }
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