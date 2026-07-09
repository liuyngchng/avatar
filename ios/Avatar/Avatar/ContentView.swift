//
//  ContentView.swift
//  Avatar
//
//  Root navigation: ModelSetup → Settings → RobotMainScreen.
//  Ported from Android: MainActivity.kt navigation logic
//  Reference: siri/ios/SiriApp/ContentView.swift
//

import SwiftUI

struct ContentView: View {
    @StateObject private var contentVM = ContentViewModel()
    @StateObject private var configVM = ConfigViewModel()
    @StateObject private var robotVM = RobotViewModel()

    var body: some View {
        Group {
            if !contentVM.modelsReady {
                ModelSetupScreen(onReady: {
                    contentVM.onModelsReady()
                })
            } else if !contentVM.hasConfig {
                SettingsScreen(
                    viewModel: configVM,
                    onBack: {
                        contentVM.onConfigSaved()
                    }
                )
            } else if contentVM.showSettings {
                SettingsHubScreen(
                    configVM: configVM,
                    onDismiss: {
                        contentVM.showSettings = false
                        contentVM.refreshState()
                        _ = robotVM.checkConfig()
                    }
                )
            } else {
                RobotMainScreen(
                    viewModel: robotVM,
                    onNavigateToSettings: {
                        contentVM.showSettings = true
                    }
                )
            }
        }
        .onAppear {
            contentVM.checkInitialState()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
