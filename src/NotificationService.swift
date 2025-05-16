import Cocoa
import UserNotifications

// Service to handle notifications
class NotificationService {
    static let shared = NotificationService()
    private var notificationsAuthorized = false
    
    private init() {
        checkPermissions()
    }
    
    // Check notification permissions
    func checkPermissions() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized:
                    self.notificationsAuthorized = true
                case .denied:
                    self.notificationsAuthorized = false
                    print("Notification permissions denied")
                case .notDetermined:
                    self.requestPermissions()
                case .provisional, .ephemeral:
                    self.notificationsAuthorized = true
                    print("Notification permissions provisionally granted")
                @unknown default:
                    self.requestPermissions()
                }
            }
        }
    }
    
    // Request notification permissions
    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    self.notificationsAuthorized = true
                    print("Notification permissions granted")
                } else {
                    self.notificationsAuthorized = false
                    if let error = error {
                        print("Error requesting notification permissions: \(error)")
                    } else {
                        print("Notification permissions were not granted")
                    }
                }
            }
        }
    }
    
    // Show a basic notification
    func showNotification(title: String, body: String) {
        // Check if notifications are enabled in app settings
        if !AppSettings.shared.notificationsEnabled {
            print("Notifications disabled in app settings, skipping notification: \(title)")
            return
        }
        
        // Check if notifications are authorized by the system
        if !notificationsAuthorized {
            checkPermissions()
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        // Add app identifier to avoid conflicts with other apps
        let identifier = "com.hfjobs.menubar.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error showing notification: \(error)")
                
                // If we get an authorization error, update our state and try re-requesting permissions
                if error.localizedDescription.contains("denied") || 
                   error.localizedDescription.contains("not authorized") {
                    DispatchQueue.main.async {
                        self.notificationsAuthorized = false
                        self.requestPermissions()
                    }
                }
            }
        }
    }
    
    // Show a job status change notification
    func notifyJobStatusChange(oldJob: HFJob, newJob: HFJob) {
        let jobName = newJob.displayName
        
        showNotification(
            title: "Job Status Changed",
            body: "Job '\(jobName)' changed from \(oldJob.status.stage) to \(newJob.status.stage)"
        )
        
        // Special notification for completion
        if newJob.status.stage == "COMPLETED" {
            showNotification(
                title: "✅ Job Completed",
                body: "Job '\(jobName)' has completed successfully"
            )
        }
        
        // Special notification for errors
        if newJob.status.stage == "ERROR" {
            let errorMessage = newJob.status.message ?? "Unknown error"
            showNotification(
                title: "❌ Job Failed",
                body: "Job '\(jobName)' failed: \(errorMessage)"
            )
        }
    }
    
    // Notify about a new job
    func notifyNewJob(_ job: HFJob) {
        let jobName = job.displayName
        
        if job.status.stage == "RUNNING" {
            showNotification(
                title: "🟢 New Job Started",
                body: "Job '\(jobName)' has started running"
            )
        } else {
            showNotification(
                title: "New Job Added",
                body: "Job '\(jobName)' added with status: \(job.status.stage)"
            )
        }
    }
    
    // Notify about a job that's no longer in the list
    func notifyJobRemoved(_ job: HFJob) {
        let jobName = job.displayName
        
        if job.status.stage == "RUNNING" {
            showNotification(
                title: "✅ Job Likely Completed",
                body: "Running job '\(jobName)' is no longer in the list (likely completed)"
            )
        } else {
            showNotification(
                title: "Job Removed",
                body: "Job '\(jobName)' is no longer in the job list"
            )
        }
    }
}