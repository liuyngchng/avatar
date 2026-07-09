//
//  SettingsScreen.swift
//  SiriApp
//
//  LLM API configuration form.
//  iOS 14 native style: Form + Section
//
//  SettingsScreen   – standalone NavigationView wrapper (first-launch flow).
//  SettingsContent  – the Form itself; can be pushed inside another NavView.
//

import SwiftUI

// MARK: - Standalone wrapper (first-launch / forced config)

struct SettingsScreen: View {
    @ObservedObject var viewModel: ConfigViewModel
    var onBack: () -> Void

    var body: some View {
        NavigationView {
            SettingsContent(viewModel: viewModel, onBack: onBack)
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Content (usable standalone or pushed)

struct SettingsContent: View {
    @ObservedObject var viewModel: ConfigViewModel
    var onBack: (() -> Void)?

    @State private var apiUrl: String = ""
    @State private var model: String = ""
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false
    @State private var showHttpWarning: Bool = false
    @State private var pendingSave: Bool = false

    var body: some View {
        Form {
            // MARK: - API 配置
            Section(header: Text("API 配置"),
                    footer: Text("兼容 OpenAI chat/completions 接口")) {
                HStack {
                    Text("地址")
                        .frame(width: 40, alignment: .leading)
                    TextField("https://api.deepseek.com/v1", text: $apiUrl)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: apiUrl) { _ in
                            viewModel.resetTestResult()
                            showHttpWarning = apiUrl.hasPrefix("http://")
                        }
                }

                if showHttpWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("HTTP 明文传输存在安全风险，API 密钥可能被窃取，强烈建议使用 HTTPS")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                HStack {
                    Text("模型")
                        .frame(width: 40, alignment: .leading)
                    TextField("deepseek-v4-flash", text: $model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: model) { _ in viewModel.resetTestResult() }
                }

                HStack {
                    Text("密钥")
                        .frame(width: 40, alignment: .leading)
                    if showKey {
                        TextField("sk-...", text: $apiKey)
                    } else {
                        SecureField("sk-...", text: $apiKey)
                    }
                    Button(action: { showKey.toggle() }) {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: apiKey) { _ in viewModel.resetTestResult() }
            }

            // MARK: - 快捷预设
            if !LlmPreset.all.isEmpty {
                Section(header: Text("快捷预设")) {
                    ForEach(LlmPreset.all) { preset in
                        Button(action: {
                            apiUrl = preset.apiUrl
                            model = preset.model
                            showHttpWarning = apiUrl.hasPrefix("http://")
                            viewModel.resetTestResult()
                        }) {
                            HStack {
                                Text(preset.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(preset.model)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            // MARK: - 连接测试结果
            if case .idle = viewModel.testResult {
                EmptyView()
            } else {
                Section {
                    switch viewModel.testResult {
                    case .testing:
                        HStack {
                            ProgressView()
                            Text("正在测试连接...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    case .success(let msg):
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(msg)
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                    case .failure(let msg):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("连接失败")
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                            }
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    default:
                        EmptyView()
                    }
                }
            }

            // MARK: - 操作
            Section {
                Button(action: {
                    viewModel.testConnection(apiUrl, model, apiKey)
                }) {
                    Label("测试连接", systemImage: "network")
                }
                .disabled(apiUrl.isEmpty || model.isEmpty || apiKey.isEmpty)

                Button(action: {
                    viewModel.clearConfig()
                    apiUrl = ""
                    model = ""
                    apiKey = ""
                }) {
                    Label("清空配置", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .background(
            // Dismiss keyboard on tap-outside without blocking child button taps
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
        )
        .navigationTitle("大模型配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { backButton }
            ToolbarItem(placement: .navigationBarTrailing) { saveButton }
        }
        .onAppear {
            if let config = viewModel.config {
                apiUrl = config.apiUrl
                model = config.model
                apiKey = config.apiKey
                showHttpWarning = config.apiUrl.hasPrefix("http://")
            }
        }
        .alert(isPresented: $pendingSave) {
            Alert(
                title: Text("安全警告"),
                message: Text("你使用的是 HTTP 明文连接，API 密钥将以明文方式传输，存在被窃取的风险。\n\n建议使用 HTTPS 连接。\n\n是否仍然保存？"),
                primaryButton: .destructive(Text("仍然保存"), action: {
                    viewModel.saveConfig(apiUrl, model, apiKey)
                }),
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - Toolbar items (ViewBuilder properties for iOS 14 compat)

    @ViewBuilder
    private var backButton: some View {
        if let onBack = onBack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("返回")
                }
            }
        }
    }

    private var saveButton: some View {
        Button("保存") {
            if apiUrl.hasPrefix("http://") {
                showHttpWarning = true
                pendingSave = true
            } else {
                viewModel.saveConfig(apiUrl, model, apiKey)
            }
        }
        .disabled(apiUrl.isEmpty || model.isEmpty || apiKey.isEmpty)
    }
}
