import SwiftUI

/// Full-screen branded interstitial shown while the automatic pipeline runs.
/// Blocks all editing until the first pass is done, with stage-aware copy.
struct ProcessingView: View {
    @ObservedObject var vm: StudioViewModel

    private var stage: (title: String, quip: String) {
        let message = vm.busyMessage ?? ""
        if message.contains("Importing") {
            return ("Rolling the tape", "Loading your recording and sizing it up.")
        }
        if message.contains("Detecting") {
            return ("Finding your scenes", "Watching the walkthrough frame by frame — every screen gets its moment.")
        }
        if message.contains("Transcribing") {
            return ("Listening closely", "Turning your narration into words. The ums and ahs will be dealt with.")
        }
        if message.contains("Drafting") {
            return ("Writing the copy", "Titles, captions, and headlines — warm, plain, and on-brand.")
        }
        if message.contains("Polishing") {
            return ("Polishing the script", "Trimming the filler, keeping the heart.")
        }
        if message.contains("Synthesizing") {
            return ("Recording the voice-over", "A warm, steady narrator is reading your script right now.")
        }
        return ("Working on it", "Turning your walkthrough into something worth shipping.")
    }

    var body: some View {
        ZStack {
            // Brand backdrop: warm gradient + soft orbs, like the slides.
            LinearGradient(
                colors: [Brand.warm, Brand.cream, Brand.soft],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Brand.coral.opacity(0.10))
                .frame(width: 560, height: 560)
                .blur(radius: 90)
                .offset(x: 320, y: -260)
            Circle()
                .fill(Brand.golden.opacity(0.10))
                .frame(width: 500, height: 500)
                .blur(radius: 90)
                .offset(x: -340, y: 280)

            // The card
            VStack(spacing: 22) {
                VoiceBarsMark()

                VStack(spacing: 8) {
                    Text(stage.title)
                        .font(.custom("Georgia", size: 28))
                        .foregroundStyle(Brand.charcoal)
                        .contentTransition(.opacity)
                    Text(stage.quip)
                        .font(.callout)
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .animation(.easeInOut(duration: 0.3), value: stage.title)

                VStack(spacing: 8) {
                    if let progress = vm.progress {
                        ProgressView(value: progress)
                            .tint(Brand.coral)
                            .frame(width: 260)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Brand.coral)
                    }
                    if !vm.statusMessage.isEmpty {
                        Text(vm.statusMessage)
                            .font(.caption)
                            .foregroundStyle(Brand.faded)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 320)
                    }
                }

                Text("Sit tight — you'll review and edit everything before anything is exported.")
                    .font(.caption)
                    .foregroundStyle(Brand.faded)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white)
                    .shadow(color: Brand.coral.opacity(0.14), radius: 40, y: 18)
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .light)
    }
}

/// The LiveAgain mark with its five voice bars gently pulsing.
private struct VoiceBarsMark: View {
    @State private var animating = false

    /// Resting heights mirror the brand icon's bar proportions.
    private let restingHeights: [CGFloat] = [14, 26, 38, 23, 11]
    private let opacities: [Double] = [0.7, 0.85, 1.0, 0.8, 0.6]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17)
                .fill(Brand.coral)
                .frame(width: 64, height: 64)
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(opacities[index]))
                        .frame(width: 5, height: restingHeights[index])
                        .scaleEffect(y: animating ? 1.0 : 0.55, anchor: .center)
                        .animation(
                            .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                            value: animating
                        )
                }
            }
        }
        .onAppear { animating = true }
    }
}
