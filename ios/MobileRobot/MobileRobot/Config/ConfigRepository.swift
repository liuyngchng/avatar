//
//  ConfigRepository.swift
//  SiriApp
//
//  Config storage backed by Keychain (hardware-encrypted).
//  Ported from Android: ConfigRepository.kt (EncryptedSharedPreferences)
//

import Foundation

class ConfigRepository {
    private let serviceName = "dev.richard.voicechat.llmConfig"
    private let accountName = "config"

    func getConfig() -> LlmConfig? {
        guard let data = KeychainHelper.read(service: serviceName, account: accountName),
              let config = try? JSONDecoder().decode(LlmConfig.self, from: data) else {
            return nil
        }
        return config
    }

    func saveConfig(_ config: LlmConfig) {
        if let data = try? JSONEncoder().encode(config) {
            _ = KeychainHelper.save(data: data, service: serviceName, account: accountName)
        }
    }

    func clearConfig() {
        KeychainHelper.delete(service: serviceName, account: accountName)
    }

    var hasConfig: Bool {
        getConfig() != nil
    }
}
