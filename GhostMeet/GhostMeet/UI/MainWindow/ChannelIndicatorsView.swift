//
//  ChannelIndicatorsView.swift
//  GhostMeet
//

import SwiftUI

/// The row of dots in the header: `You`, `Them` and the model, each with its own
/// state.
///
/// One dot per channel and never a single shared one: the two channels fail
/// independently and for different reasons — a granted microphone next to a
/// `Them` channel with no source application is the normal state of a
/// half-configured call, and a single dot would have to pick one of them to lie
/// about.
struct ChannelIndicatorsView: View {

    let indicators: SessionIndicators

    var body: some View {
        HStack(spacing: 9) {
            ForEach(indicators.all) { indicator in
                HStack(spacing: 4) {
                    Circle()
                        .fill(Self.color(for: indicator.state))
                        .frame(width: 7, height: 7)
                        .overlay {
                            // A ring instead of an animation: the overlay sits on
                            // top of a call the user is being watched on, and a
                            // pulsing dot draws the eye of anyone looking at
                            // their face.
                            if indicator.state == .thinking {
                                Circle()
                                    .stroke(Self.color(for: indicator.state).opacity(0.45), lineWidth: 2)
                                    .frame(width: 12, height: 12)
                            }
                        }

                    Text(indicator.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(indicator.state == .idle ? .secondary : .primary)
                }
                .help("\(indicator.name) — \(indicator.detail)")
                .accessibilityLabel("\(indicator.name): \(indicator.detail)")
            }
        }
    }

    static func color(for state: IndicatorState) -> Color {
        switch state {
        case .idle: .secondary
        case .waiting: .yellow
        case .listening: .green
        case .thinking: .blue
        case .failed: .orange
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        ChannelIndicatorsView(
            indicators: SessionIndicators.make(
                isListening: false,
                failure: nil,
                recognition: .downloading(fraction: 0.4),
                themStatus: .idle,
                isGenerating: false,
                suggestionFailure: nil
            )
        )
        ChannelIndicatorsView(
            indicators: SessionIndicators.make(
                isListening: true,
                failure: nil,
                recognition: .ready,
                themStatus: .capturing(application: "Google Chrome"),
                isGenerating: true,
                suggestionFailure: nil
            )
        )
        ChannelIndicatorsView(
            indicators: SessionIndicators.make(
                isListening: true,
                failure: .microphoneDenied,
                recognition: .ready,
                themStatus: .failed(reason: ThemCaptureBackend.screenRecordingHelp),
                isGenerating: false,
                suggestionFailure: nil
            )
        )
    }
    .padding()
}
