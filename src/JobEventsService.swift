import Foundation
import OSLog

// Define the job event structure
struct JobEvent: Equatable {
  enum EventType: String, Codable {
    case status = "status"
    case log = "log"
    case metric = "metric"
    case error = "error"
    case info = "info"
    case unknown

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      let rawValue = try container.decode(String.self)
      self = EventType(rawValue: rawValue) ?? .unknown
    }
  }

  let type: EventType
  let timestamp: String
  let message: String?
  let status: String?
  let logData: String?
  let metricData: [String: Any]?

  static func == (lhs: JobEvent, rhs: JobEvent) -> Bool {
    return lhs.type == rhs.type && lhs.timestamp == rhs.timestamp && lhs.message == rhs.message
      && lhs.status == rhs.status && lhs.logData == rhs.logData
    // Note: metricData comparison omitted as [String: Any] doesn't conform to Equatable
  }
}

// Define the job events structure
struct HFJobEvents: Equatable {
  let events: [JobEvent]
}

// Define the delegate protocol
protocol JobEventsStreamDelegate: AnyObject {
  func didReceiveEvent(_ event: JobEvent)
  func didReceiveEvents(_ events: [JobEvent])
  func didEncounterError(_ error: Error)
  func didCompleteStream()
}

// Events Stream Service
class JobEventsStreamService: NSObject, URLSessionDataDelegate {
  static let shared = JobEventsStreamService()

  private var urlSession: URLSession?
  private var eventStreamTask: URLSessionDataTask?
  private var buffer = Data()
  private var isStreamingActive = false
  private var eventsStarted = false
  private var currentJobId = ""
  private var currentDelegate: JobEventsStreamDelegate?

  private override init() {
    super.init()
  }

  // Streaming events implementation
  func streamJobEvents(jobId: String, delegate: JobEventsStreamDelegate) -> String {
    // If already streaming this job, don't start another stream
    if isStreamingActive && currentJobId == jobId {
      print("🚫 Already streaming events for job \(jobId)...")
      return "Already streaming events for job \(jobId)..."
    }

    // Clean up any existing stream before starting a new one
    if isStreamingActive {
      cancelEventStream()
    }

    isStreamingActive = true
    currentDelegate = delegate
    currentJobId = jobId

    guard let token = AppSettings.shared.token, !token.isEmpty else {
      print("❌ No token available")
      delegate.didEncounterError(JobServiceError.noToken)
      isStreamingActive = false
      return "No token available."
    }

    guard let username = AppSettings.shared.username, !username.isEmpty else {
      print("❌ No username available")
      delegate.didEncounterError(JobServiceError.noUsername)
      isStreamingActive = false
      return "No username available."
    }

    print("📊 Starting events stream for job \(jobId)...")

    // First verify the job exists
    Task {
      do {
        print("🔍 Verifying job exists...")
        let _ = try await JobService.shared.fetchJobById(jobId: jobId)
        self.startEventStream(username: username, jobId: jobId)
      } catch {
        if let jobError = error as? JobServiceError, case .jobNotFound = jobError {
          print("ℹ️ Job not found - likely completed or deleted")
          delegate.didCompleteStream()
        } else {
          print("❌ Error verifying job: \(error)")
          delegate.didEncounterError(error)
        }
        self.isStreamingActive = false
      }
    }

    return "Connecting to event stream..."
  }

  private func startEventStream(username: String, jobId: String) {
    print("📡 Creating events stream request...")

    guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/events") else {
      print("❌ Invalid URL")
      currentDelegate?.didEncounterError(JobServiceError.invalidURL)
      isStreamingActive = false
      return
    }

    // Create a dedicated session with a delegate for better stream handling
    let sessionConfig = URLSessionConfiguration.default
    sessionConfig.timeoutIntervalForRequest = 300  // 5 minutes
    sessionConfig.timeoutIntervalForResource = 3600  // 1 hour
    urlSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: .main)

    var request = URLRequest(url: url)
    request.setValue(
      "Bearer \(AppSettings.shared.token ?? "")", forHTTPHeaderField: "Authorization")
    request.setValue("hfjobs-swift", forHTTPHeaderField: "X-Library-Name")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    
    print("🌐 Making events request to: \(url)")

    // Cancel any existing task
    eventStreamTask?.cancel()

    // Create and start a new task
    eventStreamTask = urlSession?.dataTask(with: request)
    eventStreamTask?.resume()

    // For debugging: Check again after 5 seconds if we're receiving data
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self = self else { return }
      if !self.eventsStarted {
        if let task = self.eventStreamTask {
          print("📊 Task state: \(task.state.rawValue)")
        }
      }
    }
  }

  // MARK: - URLSessionDataDelegate Methods

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let httpResponse = response as? HTTPURLResponse {

      guard httpResponse.statusCode == 200 else {
        print("❌ HTTP error: \(httpResponse.statusCode)")
        currentDelegate?.didEncounterError(JobServiceError.httpError(httpResponse.statusCode))
        isStreamingActive = false
        completionHandler(.cancel)
        return
      }

      // Check content type is SSE
      if let contentType = httpResponse.allHeaderFields["Content-Type"] as? String,
        contentType.contains("text/event-stream")
      {
        print("✅ Confirmed SSE content type: \(contentType)")
      } else {
        print(
          "⚠️ Unexpected content type: \(httpResponse.allHeaderFields["Content-Type"] ?? "unknown")")
      }
    }

    // Accept this response and continue
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    print("📦 Received \(data.count) bytes of event data")

    // Print raw data as string for debugging (limited characters)
    if let rawString = String(data: data, encoding: .utf8) {
      let preview = String(rawString.prefix(100))
      print("📝 Event data preview: \(preview)...")
    }

    // Add to buffer and process
    buffer.append(data)
    // processBuffer()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      // Handle cancellation silently (expected when stopping streams)
      if let urlError = error as? URLError, urlError.code == .cancelled {
        print("🛑 Events stream cancelled")
        currentDelegate?.didCompleteStream()
        isStreamingActive = false
        return
      }
      
      print("❌ [Event Service] Stream task completed with error: \(error)")

      if (error as NSError).domain == NSURLErrorDomain {
        print("🔍 URL error code: \((error as NSError).code)")
      }

      // Check job status before deciding what to do
      Task {
        do {
          let job = try await JobService.shared.fetchJobById(jobId: currentJobId)
          let status = job.status.stage

          if status != "RUNNING" && status != "UPDATING" {
            print("🏁 Job is no longer running (status: \(status))")
            currentDelegate?.didCompleteStream()
            isStreamingActive = false
          } else if !eventsStarted {
            print("🔄 Job still running but events stream failed - retrying in 3 seconds")
            // Retry after delay if the job is still running
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
              guard let self = self, let username = AppSettings.shared.username else { return }
              self.startEventStream(username: username, jobId: self.currentJobId)
            }
          } else {
            currentDelegate?.didEncounterError(JobServiceError.networkError(error))
            isStreamingActive = false
          }
        } catch {
          print("❌ Error checking job status: \(error)")
          currentDelegate?.didEncounterError(error)
          isStreamingActive = false
        }
      }
    } else {
      print("✅ Stream task completed normally")
      currentDelegate?.didCompleteStream()
      isStreamingActive = false
    }
  }

  private func processBuffer() {
    // Look for complete events in the buffer (SSE format: event and data fields ending with double newlines)
    var jobEvents: [JobEvent] = []

    // Process buffer for complete SSE events (double newlines)
    while let doubleNewlineIndex = findDoubleNewlineIndex() {
      print("🟣🟣🟣🟣 Found double newline at index \(doubleNewlineIndex)")
      
      let eventData = buffer.prefix(upTo: doubleNewlineIndex)
      buffer = buffer.suffix(from: doubleNewlineIndex + 2)  // +2 to skip both newlines
      print("🟣🟣🟣🟣 Remaining buffer size: \(buffer.count) bytes")
      if let event = parseSSEEvent(from: eventData) {
        eventsStarted = true
        jobEvents.append(event)
      }
      print("🔄 Processed event data: \(eventData)")
      
    }

    // print("🗑️ Remaining buffer after processing: \(buffer.count) bytes")
    

    // If we collected any events, notify delegate with the batch
    if !jobEvents.isEmpty {
      DispatchQueue.main.async { [weak self] in
        self?.currentDelegate?.didReceiveEvents(jobEvents)

        // For compatibility with single event handling
        jobEvents.forEach { event in
          self?.currentDelegate?.didReceiveEvent(event)
        }
      }
    }
  }

  private func findDoubleNewlineIndex() -> Data.Index? {
    // Find double newline sequence in the buffer (\n\n)
    guard buffer.count >= 2 else { return nil }

    // Start from the beginning and look for \n\n sequence
    for i in 0..<(buffer.count - 1) {
      if buffer[i] == 10 && buffer[i + 1] == 10 {
        return buffer.index(buffer.startIndex, offsetBy: i + 1)  // Return index of the second newline
      }
    }
    return nil
  }

  private func parseSSEEvent(from data: Data) -> JobEvent? {
    guard let dataString = String(data: data, encoding: .utf8) else {
      print("❌ Failed to decode SSE event data as string")
      return nil
    }

    // Parse SSE format
    let lines = dataString.split(separator: "\n")
    var eventType = "message"  // Default event type
    var eventData = ""

    for line in lines {
      if line.hasPrefix("event:") {
        eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
      } else if line.hasPrefix("data:") {
        eventData = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }

    // Skip keep-alive messages
    if eventData == "keep-alive" || eventData.isEmpty {
      print("🔄 Received keep-alive or empty event")
      return nil
    }

    // print the text data for debugging
    print("📝 Parsed event data: \(eventData)"
          + "\nEvent type: \(eventType)")

    // // Parse the event data as JSON
    // guard let jsonData = eventData.data(using: .utf8) else {
    //   print("❌ Failed to encode event data as UTF-8")
    //   return nil
    // }

    // do {
    //   // Parse event content based on event type
    //   if eventType == "log" {
    //     return try parseLogEvent(jsonData: jsonData)
    //   } else if eventType == "status" {
    //     return try parseStatusEvent(jsonData: jsonData)
    //   } else if eventType == "metric" {
    //     return try parseMetricEvent(jsonData: jsonData)
    //   } else if eventType == "error" {
    //     return try parseErrorEvent(jsonData: jsonData)
    //   } else {
    //     // Generic event parsing
    //     return try parseGenericEvent(jsonData: jsonData, type: eventType)
    //   }
    // } catch {
    //   print("❌ Error parsing event JSON: \(error)")
    //   return nil
    // }
    return nil
  }

  private func parseLogEvent(jsonData: Data) throws -> JobEvent {
    struct LogEventData: Decodable {
      let timestamp: String
      let data: String
    }

    let decoder = JSONDecoder()
    let logEntry = try decoder.decode(LogEventData.self, from: jsonData)

    return JobEvent(
      type: .log,
      timestamp: logEntry.timestamp,
      message: nil,
      status: nil,
      logData: logEntry.data,
      metricData: nil
    )
  }

  private func parseStatusEvent(jsonData: Data) throws -> JobEvent {
    struct StatusEventData: Decodable {
      let timestamp: String
      let status: String
    }

    let decoder = JSONDecoder()
    let statusEntry = try decoder.decode(StatusEventData.self, from: jsonData)

    return JobEvent(
      type: .status,
      timestamp: statusEntry.timestamp,
      message: nil,
      status: statusEntry.status,
      logData: nil,
      metricData: nil
    )
  }

  private func parseMetricEvent(jsonData: Data) throws -> JobEvent {
    struct MetricEventData: Decodable {
      let timestamp: String
      let metricData: [String: AnyCodable]

      enum CodingKeys: String, CodingKey {
        case timestamp
        case metricData = "metric_data"
      }
    }

    let decoder = JSONDecoder()
    let metricEntry = try decoder.decode(MetricEventData.self, from: jsonData)

    // Convert AnyCodable to Any
    let metricDataAny = metricEntry.metricData.mapValues { $0.value }

    return JobEvent(
      type: .metric,
      timestamp: metricEntry.timestamp,
      message: nil,
      status: nil,
      logData: nil,
      metricData: metricDataAny
    )
  }

  private func parseErrorEvent(jsonData: Data) throws -> JobEvent {
    struct ErrorEventData: Decodable {
      let timestamp: String
      let message: String
    }

    let decoder = JSONDecoder()
    let errorEntry = try decoder.decode(ErrorEventData.self, from: jsonData)

    return JobEvent(
      type: .error,
      timestamp: errorEntry.timestamp,
      message: errorEntry.message,
      status: nil,
      logData: nil,
      metricData: nil
    )
  }

  private func parseGenericEvent(jsonData: Data, type: String) throws -> JobEvent {
    struct GenericEventData: Decodable {
      let timestamp: String
      let message: String?
    }

    let decoder = JSONDecoder()
    let genericEntry = try decoder.decode(GenericEventData.self, from: jsonData)

    return JobEvent(
      type: type == "info" ? .info : .unknown,
      timestamp: genericEntry.timestamp,
      message: genericEntry.message,
      status: nil,
      logData: nil,
      metricData: nil
    )
  }

  func cancelEventStream() {
    print("🛑 Cancelling event stream")
    eventStreamTask?.cancel()
    eventStreamTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    isStreamingActive = false
    eventsStarted = false
  }
  
  // Additional method with jobId parameter for compatibility
  func cancelEventsStream(jobId: String) {
    print("🛑 Cancelling events stream for job \(jobId)")
    cancelEventStream()
  }

  // Fetch all events for a job (non-streaming)
  func fetchEvents(jobId: String) async throws -> HFJobEvents {
    guard let token = AppSettings.shared.token, !token.isEmpty else {
      throw JobServiceError.noToken
    }

    guard let username = AppSettings.shared.username, !username.isEmpty else {
      throw JobServiceError.noUsername
    }

    guard let url = URL(string: "https://huggingface.co/api/jobs/\(username)/\(jobId)/events")
    else {
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

      return try parseEventsResponse(data)
    } catch let error as JobServiceError {
      throw error
    } catch let error as URLError {
      throw JobServiceError.networkError(error)
    } catch {
      throw error
    }
  }

  private func parseEventsResponse(_ data: Data) throws -> HFJobEvents {
    struct EventsResponse: Decodable {
      struct EventData: Decodable {
        let type: String
        let timestamp: String
        let message: String?
        let status: String?
        let logData: String?
        let metricData: [String: AnyCodable]?

        enum CodingKeys: String, CodingKey {
          case type
          case timestamp
          case message
          case status
          case logData = "log_data"
          case metricData = "metric_data"
        }
      }

      let events: [EventData]
    }

    do {
      let decoder = JSONDecoder()
      let response = try decoder.decode(EventsResponse.self, from: data)

      // Convert response to our model
      let jobEvents = response.events.map { eventData -> JobEvent in
        let eventType = JobEvent.EventType(rawValue: eventData.type) ?? .unknown

        // Convert AnyCodable to Any for metric data
        let metricDataAny = eventData.metricData?.mapValues { $0.value }

        return JobEvent(
          type: eventType,
          timestamp: eventData.timestamp,
          message: eventData.message,
          status: eventData.status,
          logData: eventData.logData,
          metricData: metricDataAny
        )
      }

      return HFJobEvents(events: jobEvents)
    } catch {
      throw JobServiceError.decodingError(error)
    }
  }
}

// Helper for decoding arbitrary JSON values
struct AnyCodable: Codable {
  let value: Any

  init(_ value: Any) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self.value = NSNull()
    } else if let bool = try? container.decode(Bool.self) {
      self.value = bool
    } else if let int = try? container.decode(Int.self) {
      self.value = int
    } else if let double = try? container.decode(Double.self) {
      self.value = double
    } else if let string = try? container.decode(String.self) {
      self.value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      self.value = array.map { $0.value }
    } else if let dictionary = try? container.decode([String: AnyCodable].self) {
      self.value = dictionary.mapValues { $0.value }
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Cannot decode value"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self.value {
    case is NSNull:
      try container.encodeNil()
    case let bool as Bool:
      try container.encode(bool)
    case let int as Int:
      try container.encode(int)
    case let double as Double:
      try container.encode(double)
    case let string as String:
      try container.encode(string)
    case let array as [Any]:
      try container.encode(array.map { AnyCodable($0) })
    case let dictionary as [String: Any]:
      try container.encode(dictionary.mapValues { AnyCodable($0) })
    default:
      let context = EncodingError.Context(
        codingPath: container.codingPath,
        debugDescription: "Cannot encode value"
      )
      throw EncodingError.invalidValue(value, context)
    }
  }
}

// Observable class for job events (for SwiftUI)
class JobEventsObservable: ObservableObject {
  @Published var events: [JobEvent] = []
  @Published var isLoading: Bool = false
  @Published var errorMessage: String? = nil

  func reset() {
    events = []
    isLoading = true
    errorMessage = nil
  }

  func addEvent(_ event: JobEvent) {
    DispatchQueue.main.async {
      self.events.append(event)
      self.isLoading = false
    }
  }

  func addEvents(_ newEvents: [JobEvent]) {
    DispatchQueue.main.async {
      self.events.append(contentsOf: newEvents)
      self.isLoading = false
    }
  }

  func setError(_ message: String) {
    DispatchQueue.main.async {
      self.errorMessage = message
      self.isLoading = false
    }
  }
}

// Example implementation of delegate for JobEventsStreamDelegate
class JobEventsStreamHandler: JobEventsStreamDelegate {
  private weak var eventsObservable: JobEventsObservable?

  init(eventsObservable: JobEventsObservable) {
    self.eventsObservable = eventsObservable
  }

  func didReceiveEvent(_ event: JobEvent) {
    eventsObservable?.addEvent(event)

    // Special handling for status updates
    if event.type == .status, let status = event.status {
      print("Job status updated: \(status)")
      // You could trigger specific actions based on status changes here
    }
  }

  func didReceiveEvents(_ events: [JobEvent]) {
    eventsObservable?.addEvents(events)
  }

  func didEncounterError(_ error: Error) {
    let errorMessage = JobService.shared.errorMessage(for: error)
    eventsObservable?.setError(errorMessage)
  }

  func didCompleteStream() {
    print("Event stream completed")
  }
}
