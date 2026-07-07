//
//  AppDelegate.swift
//  SiriApp
//
//  App delegate for audio session configuration and app lifecycle.
//  Ported from Android: SiriApp.kt (Application class)
//

import UIKit
import AVFoundation
import os.log

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        os_log(.info, "AppDelegate: didFinishLaunching")
        configureNavigationBar()
        configureAudioSession()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        os_log(.info, "AppDelegate: willResignActive")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        os_log(.info, "AppDelegate: didBecomeActive")
        // Re-activate the audio session without overwriting the current
        // category/mode — KWS may have been running with .voiceChat.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            os_log(.error, "AppDelegate: failed to reactivate audio session: %{public}@",
                   error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        os_log(.info, "AppDelegate: willTerminate")
        AudioSessionManager.deactivate()
    }

    /// Make the navigation bar opaque so scroll content doesn't bleed through it.
    private func configureNavigationBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .systemBackground
        UINavigationBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
            os_log(.info, "AppDelegate: audio session configured")
        } catch {
            os_log(.error, "AppDelegate: audio session config failed: %{public}@",
                   error.localizedDescription)
        }
    }
}
