//
//  AvatarApp.swift
//  Avatar
//
//  @main entry point for the SwiftUI app.
//  Ported from Android: MainActivity.kt / RobotApplication.kt
//

import SwiftUI

@main
struct AvatarApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
