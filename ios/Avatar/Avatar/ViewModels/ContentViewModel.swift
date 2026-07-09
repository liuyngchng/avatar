//
//  ContentViewModel.swift
//  Avatar
//
//  Root navigation state management.
//  Ported from Android: MainActivity.kt navigation logic
//

import Foundation

class ContentViewModel: ObservableObject {
    @Published var modelsReady: Bool = false
    @Published var hasConfig: Bool = false
    @Published var showSettings: Bool = false

    private let configRepo = ConfigRepository()

    func checkInitialState() {
        modelsReady = ModelManager.checkAllReady()
        hasConfig = configRepo.hasConfig
    }

    func onModelsReady() {
        modelsReady = true
        hasConfig = configRepo.hasConfig
    }

    func onConfigSaved() {
        hasConfig = true
        showSettings = false
    }

    func refreshState() {
        modelsReady = ModelManager.checkAllReady()
        hasConfig = configRepo.hasConfig
    }
}
