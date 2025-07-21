import SwiftUI
import Combine

// Components for displaying job events
struct JobEventsViewComponents {
    // Loading view for events
    struct EventsLoadingView: View {
        var body: some View {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading events...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(Color(.textBackgroundColor).opacity(0.2))
            .cornerRadius(8)
        }
    }
    
    // Error view for events
    struct EventsErrorView: View {
        let message: String
        let retryAction: () -> Void
        
        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundColor(.orange)
                
                Text("Failed to load events")
                    .font(.headline)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Retry") {
                    retryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 8)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(Color(.textBackgroundColor).opacity(0.2))
            .cornerRadius(8)
        }
    }
    
    // Event row component
    struct EventRow: View {
        let event: JobEvent
        
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                // Header with event type and timestamp
                HStack {
                    // Type icon and name
                    HStack(spacing: 4) {
                        eventTypeIcon
                            .foregroundColor(eventTypeColor)
                        
                        Text(eventTypeLabel)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(eventTypeColor)
                    }
                    
                    Spacer()
                    
                    // Display timestamp
                    let timestamp = event.timestamp
                    Text(formatEventTime(timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Content varies based on event type
                eventContent
                    .padding(.top, 1)
            }
            .padding(8)
            .background(eventBackgroundColor)
            .cornerRadius(6)
        }
        
        // Format event timestamp
        private func formatEventTime(_ timestamp: String) -> String {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            
            guard let date = dateFormatter.date(from: timestamp) else {
                return timestamp
            }
            
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "HH:mm:ss"
            return outputFormatter.string(from: date)
        }
        
        // Event type icon
        private var eventTypeIcon: Image {
            switch event.type {
            case .status:
                return Image(systemName: "circle.fill")
            case .log:
                return Image(systemName: "terminal")
            case .metric:
                return Image(systemName: "chart.bar")
            case .error:
                return Image(systemName: "exclamationmark.triangle")
            case .info:
                return Image(systemName: "info.circle")
            case .unknown:
                return Image(systemName: "questionmark.circle")
            }
        }
        
        // Event type label
        private var eventTypeLabel: String {
            switch event.type {
            case .status: return "Status"
            case .log: return "Log"
            case .metric: return "Metric"
            case .error: return "Error"
            case .info: return "Info"
            case .unknown: return "Event"
            }
        }
        
        // Event type color
        private var eventTypeColor: Color {
            switch event.type {
            case .status:
                let status = event.status ?? ""
                if !status.isEmpty {
                    switch status {
                    case "RUNNING": return .green
                    case "COMPLETED": return .blue
                    case "ERROR": return .red
                    case "PENDING", "QUEUED": return .orange
                    default: return .gray
                    }
                }
                return .blue
            case .log: return .gray
            case .metric: return .purple
            case .error: return .red
            case .info: return .blue
            case .unknown: return .gray
            }
        }
        
        // Event background color
        private var eventBackgroundColor: Color {
            switch event.type {
            case .status: return eventTypeColor.opacity(0.1)
            case .log: return Color(.textBackgroundColor)
            case .metric: return eventTypeColor.opacity(0.1)
            case .error: return eventTypeColor.opacity(0.1)
            case .info: return eventTypeColor.opacity(0.1)
            case .unknown: return Color(.textBackgroundColor)
            }
        }
        
        // Content varies based on event type
        @ViewBuilder
        private var eventContent: some View {
            switch event.type {
            case .status:
                let status = event.status ?? ""
                if !status.isEmpty {
                    Text("Job status changed to: \(status)")
                        .font(.caption)
                    
                    let message = event.message ?? ""
                    if !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Status update received")
                        .font(.caption)
                }
                
            case .log:
                if let logData = event.logData {
                    Text(logData)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(nil)
                } else {
                    let message = event.message ?? ""
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(nil)
                    }
                }
                
            case .metric:
                Text("Metric update received")
                    .font(.caption)
                
            case .error:
                let message = event.message ?? ""
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("Error occurred")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
            case .info:
                let message = event.message ?? ""
                if !message.isEmpty {
                    Text(message)
                        .font(.caption)
                } else {
                    Text("Info event received")
                        .font(.caption)
                }
                
            case .unknown:
                Text("Unknown event received")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // Events summary view
    struct EventsSummaryView: View {
        let events: [JobEvent]
        let maxDisplayCount: Int
        
        init(events: [JobEvent], maxDisplayCount: Int = 5) {
            self.events = events
            self.maxDisplayCount = maxDisplayCount
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if events.isEmpty {
                    Text("No events received yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    // Display most recent events (limited by maxDisplayCount)
                    let recentEvents = Array(events.suffix(maxDisplayCount).reversed())
                    
                    ForEach(recentEvents.indices, id: \.self) { index in
                        EventRow(event: recentEvents[index])
                    }
                    
                    // Show count of additional events if there are more than maxDisplayCount
                    if events.count > maxDisplayCount {
                        Text("\(events.count - maxDisplayCount) more events not shown")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
    
    // Full events view for the events tab
    struct EventsFullView: View {
        let events: [JobEvent]
        
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if events.isEmpty {
                    Text("No events received yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    // Group events by day for better organization
                    let groupedEvents = groupEventsByDay(events)
                    
                    ForEach(groupedEvents.keys.sorted().reversed(), id: \.self) { date in
                        if let dateEvents = groupedEvents[date] {
                            // Date header
                            Text(formatDateHeader(date))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            
                            // Events for this date
                            ForEach(dateEvents.indices, id: \.self) { index in
                                EventRow(event: dateEvents[index])
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                }
            }
        }
        
        // Group events by day
        private func groupEventsByDay(_ events: [JobEvent]) -> [Date: [JobEvent]] {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            
            var grouped: [Date: [JobEvent]] = [:]
            
            for event in events {
                let timestamp = event.timestamp
                if let date = dateFormatter.date(from: timestamp) {
                    // Convert to day-only precision
                    let calendar = Calendar.current
                    let components = calendar.dateComponents([.year, .month, .day], from: date)
                    if let dayDate = calendar.date(from: components) {
                        if grouped[dayDate] == nil {
                            grouped[dayDate] = []
                        }
                        grouped[dayDate]?.append(event)
                    }
                }
            }
            
            // Sort events within each day by timestamp (newest first)
            for (day, dayEvents) in grouped {
                grouped[day] = dayEvents.sorted { (event1, event2) -> Bool in
                    let timestamp1 = event1.timestamp
                    let timestamp2 = event2.timestamp
                    guard let date1 = dateFormatter.date(from: timestamp1),
                          let date2 = dateFormatter.date(from: timestamp2) else {
                        return false
                    }
                    return date1 > date2
                }
            }
            
            return grouped
        }
        
        // Format date header
        private func formatDateHeader(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

typealias EventsLoadingView = JobEventsViewComponents.EventsLoadingView
typealias EventsErrorView = JobEventsViewComponents.EventsErrorView
typealias EventRow = JobEventsViewComponents.EventRow
typealias EventsSummaryView = JobEventsViewComponents.EventsSummaryView
typealias EventsFullView = JobEventsViewComponents.EventsFullView