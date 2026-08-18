//
//  RobotMainScreen.swift
//  Avatar
//
//  Main screen: stick figure with tap/long-press gestures + status overlay.
//  Ported from Android: RobotFaceScreen.kt
//

import SwiftUI

struct RobotMainScreen: View {
    @ObservedObject var viewModel: RobotViewModel
    var onNavigateToSettings: () -> Void

    @State private var showSettings = false

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                // Figure geometry: feetY = h * 0.82, head extends to ~h * 0.30
                let figureBottom = geo.size.height * StickGeo.feetYFrac + 20
                let bottomPadding: CGFloat = 40
                let faceMargin: CGFloat = 16
                let textMaxHeight = max(0, geo.size.height - figureBottom - bottomPadding - faceMargin)

                ZStack {
                    // Stick figure view fills the screen
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

                    // Status overlay
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
                                                     ? Color(red: 0.27, green: 0.53, blue: 1.0)
                                                     : .white.opacity(0.55))
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
                            if !viewModel.enginesReady {
                                return "小火正在醒来..."
                            }
                            switch viewModel.robotState.mode {
                            case .listening:
                                return "聆听中..."
                            case .thinking:
                                return "思考中..."
                            case .speaking:
                                return viewModel.robotState.responseText ?? ""
                            default:
                                return ""
                            }
                        }()

                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.body)
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                                .padding(.bottom, 40)
                                .frame(maxHeight: textMaxHeight)
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
                    },
                    ttsNumSpeakers: viewModel.ttsNumSpeakers,
                    selectedSid: $viewModel.selectedSid,
                    onSetSpeaker: { viewModel.setSpeaker($0) },
                    speakerName: { viewModel.speakerName(for: $0) }
                )
            }
            .onAppear {
                viewModel.startRobot()
            }
            .onChange(of: showSettings) { newValue in
                if newValue {
                    viewModel.pauseRobot()
                } else {
                    viewModel.resumeRobot()
                }
            }
        }
        .navigationViewStyle(.stack)
        .background(Color(red: 0.10, green: 0.10, blue: 0.18).edgesIgnoringSafeArea(.all))
    }
}
