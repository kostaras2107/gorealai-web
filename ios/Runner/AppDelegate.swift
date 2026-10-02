import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // Ζητάμε ρητά εγγραφή στην Apple για push, χωρίς να περιμένουμε το plugin.
    application.registerForRemoteNotifications()
    return result
  }

  // Το αποτέλεσμα της εγγραφής APNs γράφεται στο UserDefaults (το διαβάζει το
  // Dart μέσω shared_preferences, κλειδί "apnsResult") για διάγνωση.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    UserDefaults.standard.set("registered ok (\(deviceToken.count) bytes)", forKey: "flutter.apnsResult")
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    UserDefaults.standard.set("FAILED: \(error.localizedDescription)", forKey: "flutter.apnsResult")
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}
