//
//  RobotMainScreen.swift
//  Avatar
//
//  Main screen: robot face with tap/long-press gestures + status overlay.
//  Ported from Android: MainActivity.kt RobotFace screen
//

import SwiftUI

struct RobotMainScreen: View {
    @ObservedObject var viewModel: RobotViewModel
    var onNavigateToSettings: () -> Void

    @State private var showSettings = false

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                // Face circle geometry: centerY = h * 0.46, radius = w * 0.38
                let faceBottom = geo.size.height * 0.46 + geo.size.width * 0.38
                let bottomPadding: CGFloat = 40
                let faceMargin: CGFloat = 16
                let textMaxHeight = max(0, geo.size.height - faceBottom - bottomPadding - faceMargin)

                ZStack {
                    // Face view fills the screen
                    RobotFaceView(
                        robotState: $viewModel.robotState,
                        blinkTrigger: $viewModel.robotState.blinkTrigger,
                        isPaused: showSettings
                    )
                    .edgesIgnoringSafeArea(.all)
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                viewModel.onTap()
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                showSettings = true
                            }
                    )

                    // Status overlay (non-intrusive)
                    VStack {
                        // Top: mode indicator + wake word + settings buttons
                        HStack {
                            if let error = viewModel.errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemBackground).opacity(0.8))
                                    .clipShape(Capsule())
                                    .onTapGesture { viewModel.clearError() }
                            }

                            Spacer()

                            // Wake word toggle (ear icon)
                            Button(action: {
                                viewModel.toggleWakeWord(!viewModel.wakeWordEnabled)
                            }) {
                                Image(systemName: viewModel.wakeWordEnabled
                                      ? "ear.fill"
                                      : "ear")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(viewModel.wakeWordEnabled
                                                     ? .blue
                                                     : .white.opacity(0.6))
                                    .padding(10)
                            }

                            Button(action: { showSettings = true }) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.6))
                                    .padding(10)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        Spacer()

                        // Bottom: status text (matches Android RobotFaceScreen)
                        let statusText: String = {
                            switch viewModel.robotState.mode {
                            case .listening:
                                return "聆听中..."
                            case .thinking:
                                return "思考中..."
                            case .speaking:
                                return viewModel.robotState.responseText ?? ""
                            case .idle, .watching:
                                return viewModel.robotState.mode == .watching
                                    ? "点击我开始说话" : "点击屏幕与我互动"
                            }
                        }()

                        if !statusText.isEmpty {
                            let isHint = viewModel.robotState.mode == .idle
                                       || viewModel.robotState.mode == .watching

                            if isHint {
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.4))
                                    .padding(.bottom, 60)
                            } else {
                                Text(statusText)
                                    .font(.body)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .frame(maxHeight: textMaxHeight)
                                    .padding(.bottom, bottomPadding)
                                    .padding(.horizontal, 20)
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) {
                SettingsHubScreen(
                    configVM: ConfigViewModel(),
                    onDismiss: {
                        showSettings = false
                    },
                    onReadText: { text in
                        viewModel.speakText(text)
                    }
                )
            }
            .onAppear {
                viewModel.startRobot()
            }
            .onChange(of: showSettings) { newValue in
                viewModel.isPaused = newValue
            }
        }
        .navigationViewStyle(.stack)
    }
}
