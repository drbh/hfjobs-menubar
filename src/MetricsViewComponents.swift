import SwiftUI
import Charts

// MARK: - Metrics View Components

// Progress bar with label
struct LabeledProgressBar: View {
    let value: Double
    let label: String
    let description: String
    let color: Color
    
    init(value: Double, label: String, description: String, color: Color = .blue) {
        self.value = min(max(value, 0), 100) // Ensure value is between 0-100
        self.label = label
        self.description = description
        self.color = color
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    Rectangle()
                        .frame(width: geometry.size.width, height: 8)
                        .opacity(0.2)
                        .foregroundColor(color)
                        .cornerRadius(4)
                    
                    // Progress
                    Rectangle()
                        .frame(width: min(CGFloat(self.value) * geometry.size.width / 100, geometry.size.width), height: 8)
                        .foregroundColor(color)
                        .cornerRadius(4)
                }
            }
            .frame(height: 8)
        }
    }
}

// Card view for displaying metrics
struct MetricsCard: View {
    let title: String
    let metrics: [MetricItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 2)
            
            ForEach(metrics) { metric in
                HStack {
                    Text(metric.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(metric.value)
                        .font(.body)
                        .foregroundColor(.primary)
                }
                
                if metrics.last?.id != metric.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(Color(.textBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }
}

// Metric item for use in MetricsCard
struct MetricItem: Identifiable {
    let id = UUID()
    let name: String
    let value: String
}

// GPU card for displaying GPU metrics
struct GPUCard: View {
    let gpuName: String
    let metrics: GPUMetrics
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(gpuName)
                .font(.headline)
                .padding(.bottom, 2)
            
            if let gpuUtil = metrics.gpuUtilization {
                LabeledProgressBar(
                    value: gpuUtil,
                    label: "GPU Utilization",
                    description: String(format: "%.1f%%", gpuUtil),
                    color: .green
                )
            } else {
                Text("GPU utilization data not available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let memUtil = metrics.memoryUtilization {
                LabeledProgressBar(
                    value: memUtil,
                    label: "GPU Memory Utilization",
                    description: String(format: "%.1f%%", memUtil),
                    color: .blue
                )
            }
            
            // GPU details grid
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 12) {
                if metrics.memoryUsedBytes != nil && metrics.memoryTotalBytes != nil {
                    GroupBox {
                        VStack(alignment: .leading) {
                            Text("Memory")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(metrics.memoryUsedFormatted) / \(metrics.memoryTotalFormatted)")
                                .font(.body)
                        }
                    }
                    .groupBoxStyle(PlainGroupBoxStyle())
                }
                
                if metrics.temperature != nil {
                    GroupBox {
                        VStack(alignment: .leading) {
                            Text("Temperature")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(metrics.temperatureFormatted)
                                .font(.body)
                                .foregroundColor(temperatureColor(metrics.temperature ?? 0))
                        }
                    }
                    .groupBoxStyle(PlainGroupBoxStyle())
                }
                
            }
        }
        .padding()
        .background(Color(.textBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }
    
    // Helper method to color-code temperature
    private func temperatureColor(_ temp: Double) -> Color {
        if temp > 80 {
            return .red
        } else if temp > 70 {
            return .orange
        } else {
            return .primary
        }
    }
}

// Simple GroupBox style without background
struct PlainGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading) {
            configuration.label
                .font(.headline)
                .padding(.bottom, 2)
            configuration.content
        }
        .padding(8)
        .background(Color(.textBackgroundColor).opacity(0.2))
        .cornerRadius(4)
    }
}

/// Line chart view for displaying metric trends
@available(macOS 13.0, iOS 16.0, *)
struct MetricsLineChart: View {
    let data: [ChartDataPoint]
    @State private var selectedMetric: MetricType = .gpu

    enum MetricType: String, CaseIterable, Identifiable {
        case cpu = "CPU Usage"
        case memory = "Memory Usage"
        case gpu = "GPU Utilization"
        var id: String { rawValue }
    }

    private func value(for point: ChartDataPoint) -> Double {
        switch selectedMetric {
        case .cpu: return point.cpuUsage
        case .memory: return point.memoryUsage
        case .gpu: return point.gpuUtilization
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $selectedMetric) {
                ForEach(MetricType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Chart(data) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value(selectedMetric.rawValue, value(for: point))
                )
                .interpolationMethod(.catmullRom)
            }
        }
    }
}

// Metrics summary view for job details
struct MetricsSummaryView: View {
    let metrics: HFJobMetrics
    @State private var refreshTimestamp = Date()
    @State private var isNetworkExpanded = true
    @State private var isGPUExpanded = true
    @State private var isSystemExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with refresh timestamp
            HStack {
                Text("Last Updated: \(timeAgoString(from: refreshTimestamp))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Replica: \(metrics.replica)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)
            
            // CPU and Memory Progress Bars
            VStack(alignment: .leading, spacing: 12) {
                LabeledProgressBar(
                    value: metrics.cpuUsagePct,
                    label: "CPU Usage",
                    description: String(format: "%.1f%% (%.2f cores)", 
                                      metrics.cpuUsagePct, 
                                      Double(metrics.cpuMillicores) / 1000),
                    color: .orange
                )
                
                LabeledProgressBar(
                    value: metrics.memoryUsagePercent,
                    label: "Memory Usage",
                    description: "\(metrics.memoryUsedFormatted) / \(metrics.memoryTotalFormatted) (\(String(format: "%.1f%%", metrics.memoryUsagePercent)))",
                    color: .blue
                )
            }
            
            // System Metrics Card with DisclosureGroup
            DisclosureGroup(
                isExpanded: $isSystemExpanded,
                content: {
                    MetricsCard(title: "", metrics: [
                        MetricItem(name: "CPU Allocation", value: String(format: "%.2f cores", Double(metrics.cpuMillicores) / 1000)),
                        MetricItem(name: "Total Memory", value: metrics.memoryTotalFormatted),
                        MetricItem(name: "Used Memory", value: metrics.memoryUsedFormatted)
                    ])
                    .padding(.top, 8)
                },
                label: {
                    HStack {
                        Text("System Resources")
                            .font(.headline)
                        Spacer()
                        Image(systemName: isSystemExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isSystemExpanded ? 0 : 180))
                    }
                }
            )
            .padding(.vertical, 4)
            
            // Network Section with DisclosureGroup
            DisclosureGroup(
                isExpanded: $isNetworkExpanded,
                content: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(metrics.networkRxFormatted)
                                .font(.body)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Upload")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(metrics.networkTxFormatted)
                                .font(.body)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                },
                label: {
                    HStack {
                        Text("Network")
                            .font(.headline)
                        Spacer()
                        Image(systemName: isNetworkExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isNetworkExpanded ? 0 : 180))
                    }
                }
            )
            .padding(.vertical, 4)

            // GPU Section with DisclosureGroup
            if !metrics.gpus.isEmpty {
                DisclosureGroup(
                    isExpanded: $isGPUExpanded,
                    content: {
                        VStack(spacing: 12) {
                            ForEach(Array(metrics.gpus.keys.sorted()), id: \.self) { gpuName in
                                if let gpuMetrics = metrics.gpus[gpuName] {
                                    GPUCard(gpuName: gpuName, metrics: gpuMetrics)
                                }
                            }
                        }
                        .padding(.top, 8)
                    },
                    label: {
                        HStack {
                            Text("GPUs")
                                .font(.headline)
                            Spacer()
                            Image(systemName: isGPUExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .rotationEffect(.degrees(isGPUExpanded ? 0 : 180))
                        }
                    }
                )
                .padding(.vertical, 4)
            } else {
                Text("No GPU resources detected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
        }
        .padding()
        .onAppear {
            refreshTimestamp = Date()
            // All sections default to open
            isNetworkExpanded = true
            isGPUExpanded = true
            isSystemExpanded = true
        }
        .onChange(of: metrics) { _, _ in
            refreshTimestamp = Date()
        }
    }
    
    private func timeAgoString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// Loading state view for metrics
struct MetricsLoadingView: View {
    @State private var loadingDots = ""
    @State private var timer: Timer?
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()
            
            Text("Loading metrics\(loadingDots)")
                .font(.headline)
            
            Text("This may take a moment if the job just started")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Text("Metrics are collected as they become available")
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

// Error state view for metrics
struct MetricsErrorView: View {
    let message: String
    var onRetry: (() -> Void)?
    
    init(message: String, onRetry: (() -> Void)? = nil) {
        self.message = message
        self.onRetry = onRetry
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
                .padding()
            
            Text("Metrics Error")
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
                
                Text("• Job just started - metrics take time to initialize")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Container initialization in progress")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Job doesn't support metrics collection")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            
            if let onRetry = onRetry {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// View for when metrics are unavailable
struct MetricsUnavailableView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
                .padding()
            
            Text("Metrics Unavailable")
                .font(.headline)
            
            Text("No metrics are available for this job")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 300)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Possible reasons:")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                
                Text("• Job is not in a running state")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Job is too new and metrics haven't been collected yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Job doesn't support metrics collection")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// Grid view for metrics
struct MetricsGridView: View {
    let metrics: HFJobMetrics
    
    var body: some View {
        MetricsSummaryView(metrics: metrics)
    }
}