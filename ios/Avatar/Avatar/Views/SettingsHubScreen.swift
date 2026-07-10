//
//  SettingsHubScreen.swift
//  SiriApp
//
//  Settings hub: master list with NavigationLinks to sub-pages.
//  Follows the iOS Settings.app pattern.
//

import SwiftUI

struct SettingsHubScreen: View {
    @ObservedObject var configVM: ConfigViewModel
    var onDismiss: () -> Void
    var onReadText: (String) -> Void = { _ in }

    // TTS speaker selection
    var ttsNumSpeakers: Int = 0
    @Binding var selectedSid: Int
    var onSetSpeaker: (Int) -> Void = { _ in }

    @Environment(\.presentationMode) private var presentationMode

    /// Build-time-based version string (executable modification date).
    private var appVersion: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let modDate = attrs[.modificationDate] as? Date
        else { return "unknown" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd.HHmm"
        return fmt.string(from: modDate)
    }

    var body: some View {
        NavigationView {
            List {
                // MARK: - 配置
                Section(header: Text("配置")) {
                    NavigationLink(destination:
                        SettingsContent(viewModel: configVM, onBack: nil)
                    ) {
                        Label {
                            Text("大模型 API")
                        } icon: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.blue)
                        }
                    }
                }

                // MARK: - 模型
                Section(header: Text("模型")) {
                    NavigationLink(destination:
                        ModelSetupContent(onReady: nil)
                    ) {
                        Label {
                            Text("语音模型")
                        } icon: {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                }

                // MARK: - 音色
                if ttsNumSpeakers > 1 {
                    Section(header: Text("音色")) {
                        NavigationLink(destination:
                            SpeakerPickerView(
                                numSpeakers: ttsNumSpeakers,
                                selectedSid: $selectedSid,
                                onSelect: { onSetSpeaker($0) }
                            )
                        ) {
                            Label {
                                HStack {
                                    Text("说话人")
                                    Spacer()
                                    Text("Voice \(selectedSid)")
                                        .foregroundColor(.secondary)
                                }
                            } icon: {
                                Image(systemName: "waveform.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }

                // MARK: - 交互
                Section(header: Text("交互")) {
                    NavigationLink(destination:
                        TextReaderView(
                            onRead: onReadText,
                            onBack: {}
                        )
                    ) {
                        Label {
                            Text("文本朗读")
                        } icon: {
                            Image(systemName: "text.quote")
                                .foregroundColor(.blue)
                        }
                    }
                }

                // MARK: - 关于
                Section(header: Text("关于")) {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                        onDismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Speaker Picker (sub-page)

private struct SpeakerPickerView: View {
    let numSpeakers: Int
    @Binding var selectedSid: Int
    let onSelect: (Int) -> Void

    var body: some View {
        List {
            ForEach(0..<numSpeakers, id: \.self) { sid in
                Button(action: {
                    onSelect(sid)
                }) {
                    HStack {
                        Text("Voice \(sid)")
                            .foregroundColor(.primary)
                        Spacer()
                        if sid == selectedSid {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("选择音色")
        .navigationBarTitleDisplayMode(.inline)
    }
}
