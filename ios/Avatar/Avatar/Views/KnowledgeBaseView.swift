//
//  KnowledgeBaseView.swift
//  Avatar
//
//  Knowledge base import and management view.
//  Allows importing a JSON knowledge base file from PC (via Files app),
//  viewing status, and clearing the KB.
//

import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBaseView: View {
    @StateObject private var kbManager = KnowledgeBaseManager()
    @State private var showFilePicker = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var importSuccess = false

    var body: some View {
        List {
            // MARK: - Status
            Section(header: Text("知识库状态")) {
                HStack {
                    Text("状态")
                    Spacer()
                    if kbManager.isLoaded {
                        Label("已加载", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.subheadline)
                    } else {
                        Label("未加载", systemImage: "xmark.circle.fill")
                            .foregroundColor(.orange)
                            .font(.subheadline)
                    }
                }

                if kbManager.isLoaded {
                    HStack {
                        Text("知识条目数")
                        Spacer()
                        Text("\(kbManager.chunkCount) 条")
                            .foregroundColor(.secondary)
                    }

                    if let kb = kbManager.knowledgeBase, let company = kb.companyName {
                        HStack {
                            Text("公司")
                            Spacer()
                            Text(company)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // MARK: - Import
            Section(header: Text("导入知识库"),
                    footer: Text("请在 PC 端将文档向量化后，导出为 JSON 格式文件，再通过此页面导入。\nJSON 格式：{\"version\":1, \"companyName\":\"公司名称\", \"chunks\":[{\"id\":\"1\", \"text\":\"知识内容...\", \"keywords\":[\"关键词1\"]}]}")) {
                Button(action: { showFilePicker = true }) {
                    Label("从文件导入", systemImage: "square.and.arrow.down")
                }

                if importSuccess {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("导入成功！已加载 \(kbManager.chunkCount) 条知识")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                }
            }

            // MARK: - Preview
            if kbManager.isLoaded, let kb = kbManager.knowledgeBase {
                Section(header: Text("知识库预览（前10条）")) {
                    ForEach(kb.chunks.prefix(10)) { chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chunk.text)
                                .font(.subheadline)
                                .lineLimit(3)
                            if let keywords = chunk.keywords, !keywords.isEmpty {
                                Text(keywords.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if kb.chunks.count > 10 {
                        Text("... 还有 \(kb.chunks.count - 10) 条")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // MARK: - Clear
            if kbManager.isLoaded {
                Section {
                    Button(action: {
                        kbManager.clear()
                        importSuccess = false
                    }) {
                        Label("清除知识库", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }

            // MARK: - Search Test
            if kbManager.isLoaded {
                Section(header: Text("检索测试")) {
                    SearchTestRow(kbManager: kbManager)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("知识库管理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFilePicker) {
            KnowledgeBaseFilePicker(
                onPick: { url, cleanup in
                    do {
                        try kbManager.importFromURL(url)
                        importSuccess = true
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                        importSuccess = false
                    }
                    cleanup()
                    showFilePicker = false
                },
                onError: { msg in
                    errorMessage = msg
                    showError = true
                }
            )
        }
        .alert(isPresented: $showError) {
            Alert(
                title: Text("导入失败"),
                message: Text(errorMessage ?? "未知错误"),
                dismissButton: .default(Text("好"))
            )
        }
        .onAppear {
            kbManager.loadIfExists()
        }
    }
}

// MARK: - Search Test Row

private struct SearchTestRow: View {
    let kbManager: KnowledgeBaseManager
    @State private var query: String = ""
    @State private var keywordResults: [KnowledgeBaseSearchResult] = []
    @State private var hybridResults: [KnowledgeBaseSearchResult] = []
    @State private var showResults = false
    @State private var isSearching = false
    @State private var searchMode: String = ""

    private let configRepo = ConfigRepository()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("输入测试查询...", text: $query)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("搜索") {
                    runSearch()
                }
                .font(.subheadline)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }

            if isSearching {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("搜索中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if showResults {
                if !hybridResults.isEmpty {
                    Text("混合检索结果（关键词 + Embedding）")
                        .font(.caption)
                        .foregroundColor(.blue)
                    ForEach(Array(hybridResults.enumerated()), id: \.offset) { (_, result) in
                        resultRow(result)
                    }
                } else if !keywordResults.isEmpty {
                    Text("关键词检索结果")
                        .font(.caption)
                        .foregroundColor(.orange)
                    ForEach(Array(keywordResults.enumerated()), id: \.offset) { (_, result) in
                        resultRow(result)
                    }
                } else {
                    Text("未找到相关结果")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("检索模式: \(searchMode)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func resultRow(_ result: KnowledgeBaseSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.chunk.text)
                .font(.caption)
                .lineLimit(2)
            Text("相关度: \(String(format: "%.2f", result.score))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        showResults = false

        // Always run keyword search first (instant)
        keywordResults = kbManager.search(query: q, topK: 5)

        Task {
            // Try hybrid search with embedding API
            let config = configRepo.getConfig()
            let hybrid = await kbManager.searchHybrid(query: q, topK: 5, config: config)
            await MainActor.run {
                hybridResults = hybrid
                searchMode = (config != nil && !hybrid.isEmpty)
                    ? "混合检索 (关键词粗排 + Embedding精排)"
                    : "关键词检索 (未配置 API 或 Embedding 不可用)"
                showResults = true
                isSearching = false
            }
        }
    }
}

// MARK: - File Picker

private struct KnowledgeBaseFilePicker: UIViewControllerRepresentable {
    let onPick: (URL, @escaping () -> Void) -> Void
    let onError: ((String) -> Void)?

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let jsonType = UTType.json
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [jsonType], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiView: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onError: onError)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL, @escaping () -> Void) -> Void
        let onError: ((String) -> Void)?

        init(onPick: @escaping (URL, @escaping () -> Void) -> Void, onError: ((String) -> Void)?) {
            self.onPick = onPick
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onError?("无法读取所选文件。")
                return
            }

            let secured = url.startAccessingSecurityScopedResource()
            if !secured {
                onError?("无法访问所选文件。请在文件 App 中将该文件复制到'我的 iPhone'，再重新导入。")
                return
            }

            onPick(url) {
                url.stopAccessingSecurityScopedResource()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - Preview

struct KnowledgeBaseView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            KnowledgeBaseView()
        }
    }
}
