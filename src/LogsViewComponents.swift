import SwiftUI

// MARK: - Logs View Components

// Logs summary view for job details
struct LogsSummaryView: View {
    let logs: HFJobLogs
    @Binding var showTimestamps: Bool
    @State private var refreshTimestamp = Date()
    @State private var filterText = ""
    @State private var autoScroll = true
    
    // Filter logs based on search text
    private var filteredLogs: [LogEntry] {
        guard !filterText.isEmpty else {
            return logs.logEntries
        }
        
        return logs.logEntries.filter { entry in
            entry.message.localizedCaseInsensitiveContains(filterText) ||
            (showTimestamps && entry.timestamp.localizedCaseInsensitiveContains(filterText))
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with refresh timestamp and filter
            HStack {
                Text("Last Updated: \(timeAgoString(from: refreshTimestamp))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(filteredLogs.count) of \(logs.logEntries.count) log entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .font(.caption)
            }
            .padding(.bottom, 4)
            
            // Search and filter bar
            LogFilterBar(
                filterText: $filterText,
                showTimestamps: $showTimestamps,
                onClear: {
                    // Clear all filters
                    filterText = ""
                }
            )
            
            // Log content with fixed height
            ScrollViewReader { proxy in
                ScrollView {
                    // Use LazyVStack for better performance with many log entries
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if filteredLogs.isEmpty {
                            // Show empty state
                            VStack(spacing: 8) {
                                if filterText.isEmpty {
                                    Text("No logs available")
                                        .font(.callout)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("No logs matching '\(filterText)'")
                                        .font(.callout)
                                        .foregroundColor(.secondary)
                                    
                                    Button("Clear Filter") {
                                        filterText = ""
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(Color.blue.opacity(0.8))
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .padding()
                        } else {
                            // Show logs
                            ForEach(filteredLogs.indices, id: \.self) { index in
                                LogEntryRow(
                                    entry: filteredLogs[index],
                                    showTimestamp: showTimestamps
                                )
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(8)

                    // Add invisible view at the end for scrolling target
                    Color.clear
                        .frame(height: 1)
                        .id("logsEnd")

                }
                .frame(maxHeight: 300)
                .padding(.vertical, 8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
                .onChange(of: logs.logEntries.count) { _, _ in
                    refreshTimestamp = Date()
                    if autoScroll && !filteredLogs.isEmpty {
                        withAnimation {
                            proxy.scrollTo("logsEnd", anchor: .bottom)
                        }
                    }
                }
                // Observe filter changes
                .onChange(of: filterText) { _, _ in
                    if autoScroll && !filteredLogs.isEmpty {
                        withAnimation {
                            proxy.scrollTo("logsEnd", anchor: .bottom)
                        }
                    }
                }
                // Observe autoScroll toggle changes
                .onChange(of: autoScroll) { _, newValue in
                    if newValue && !filteredLogs.isEmpty {
                        withAnimation {
                            proxy.scrollTo("logsEnd", anchor: .bottom)
                        }
                    }
                }
                // Initial scroll when view appears
                .onAppear {
                    // Use DispatchQueue to ensure view is fully rendered
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if !filteredLogs.isEmpty {
                            withAnimation {
                                proxy.scrollTo("logsEnd", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .onAppear {
            refreshTimestamp = Date()
        }
    }
    
    private func timeAgoString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// Loading state view for logs
struct LogsLoadingView: View {
    @State private var loadingDots = ""
    @State private var timer: Timer?
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()
            
            Text("Loading logs\(loadingDots)")
                .font(.headline)
            
            Text("This may take a moment if the job just started")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Text("Logs are collected as they become available")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear {
            // Animate loading dots
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                if loadingDots.count >= 3 {
                    loadingDots = ""
                } else {
                    loadingDots += "."
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

// Error state view for logs
struct LogsErrorView: View {
    let message: String
    let onRetry: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
                .padding()
            
            Text("Logs Error")
                .font(.headline)
            
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 300)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Possible reasons:")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                
                Text("• Job just started - logs take time to initialize")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Container initialization in progress")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Job doesn't support logs collection")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            
            Button(action: {
                onRetry()
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// Individual log entry row
struct LogEntryRow: View {
    let entry: LogEntry
    let showTimestamp: Bool
    
    // Analyze log message to determine the appropriate styling
    private var logStyle: (color: Color, icon: String?) {
        let message = entry.message.lowercased()
        
        if message.contains("error") || message.contains("exception") || message.contains("fail") {
            return (.red, "exclamationmark.triangle.fill")
        } else if message.contains("warn") {
            return (.orange, "exclamationmark.circle.fill")
        } else if message.contains("info") || message.contains("notice") {
            return (.blue, "info.circle.fill")
        } else if message.contains("debug") {
            return (.gray, "magnifyingglass")
        } else if message.contains("success") || message.contains("completed") {
            return (.green, "checkmark.circle.fill")
        } else {
            return (.primary, nil)
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showTimestamp && !entry.timestamp.isEmpty {
                Text("[\(entry.timestamp)]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            if let icon = logStyle.icon {
                Image(systemName: icon)
                    .foregroundColor(logStyle.color)
                    .font(.system(size: 12))
                    .frame(width: 12, alignment: .center)
            }
            
            Text(entry.message)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(logStyle.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 0)
    }
}

// Log Filter Bar
struct LogFilterBar: View {
    @Binding var filterText: String
    @Binding var showTimestamps: Bool
    let onClear: () -> Void
    
    var body: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Filter logs...", text: $filterText)
                    .textFieldStyle(PlainTextFieldStyle())
                
                if !filterText.isEmpty {
                    Button(action: {
                        filterText = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(6)
            .background(Color(.textBackgroundColor))
            .cornerRadius(8)
            
            Toggle("Timestamps", isOn: $showTimestamps)
                .toggleStyle(.switch)
                .labelsHidden()
            
            Button(action: onClear) {
                Text("Clear")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(4)
        }
        .padding(.bottom, 8)
    }
}