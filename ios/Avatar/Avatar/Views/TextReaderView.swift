//
//  TextReaderView.swift
//  Avatar
//
//  Text input view for avatar reading.
//  Ported from Android: TextReaderScreen.kt
//

import SwiftUI

@available(iOS 14.0, *)
struct TextReaderView: View {
    var onRead: (String) -> Void
    var onBack: () -> Void

    @State private var text: String = ""
    @State private var charCount: Int = 0
    private let maxChars = 5000

    var body: some View {
        Form {
            Section(header: Text("输入文本"),
                    footer: Text("\(charCount) / \(maxChars)")) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("粘贴或输入要朗读的文本...")
                            .foregroundColor(Color(.placeholderText))
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .onChange(of: text) { newValue in
                            if newValue.count > maxChars {
                                text = String(newValue.prefix(maxChars))
                            }
                            charCount = text.count
                        }
                }
            }

            Section {
                Button(action: {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onRead(trimmed)
                        onBack()
                    }
                }) {
                    HStack {
                        Spacer()
                        Label("朗读", systemImage: "play.fill")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("文本朗读")
        .navigationBarTitleDisplayMode(.inline)
    }
}
