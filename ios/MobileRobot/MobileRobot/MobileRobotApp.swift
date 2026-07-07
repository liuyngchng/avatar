//
//  MobileRobotApp.swift
//  MobileRobot
//
//  @main entry point for the SwiftUI app.
//  Ported from Android: MainActivity.kt / RobotApplication.kt
//

import SwiftUI

@main
struct MobileRobotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
