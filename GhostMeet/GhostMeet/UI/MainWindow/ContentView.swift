//
//  ContentView.swift
//  GhostMeet
//

import AppKit
import SwiftUI

/// Content of the overlay panel: the live transcript, the controls the user has
/// to be able to reach mid-call (listen, settings, opacity), and an honest note
/// about what the invisibility promise covers.
///
/// Everything this view can go wrong about — a denied microphone, a capture that
/// would not start — is shown here and only here. A system notification would be
/// drawn over the shared screen and give the app away (ADR-0004).
struct ContentView: View {

    @ObservedObject var controller: OverlayWindowController

    /// The session: where the turns come from and what the listen button drives.
    let session: SessionController

    /// How far the recognition model has got. Read here — and not only in
    /// settings — because it decides whether the listen button works at all, and
    /// a disabled button with no visible reason reads as a broken app.
    let recognition: SpeechModelStatus

    /// The global chords and their bindings. Shown here so that the one thing a
    /// user needs after pressing the panic key — the chord that brings the window
    /// back — is written down in the window itself.
    let hotkeys: HotkeyCenter

    /// Opens the settings window. In accessory mode there is no menu bar, so
    /// this button is the only way in.
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            recognitionNotice
            failureNotice
            themNotice
            suggestions
            Divider().opacity(0.4)
            transcript
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: controller.cornerRadius, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ChannelIndicatorsView(indicators: indicators)

            Spacer(minLength: 12)

            listenButton
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The state of both channels and of the model, recomputed from the session
    /// on every redraw. Nothing about it is stored: an indicator that can go
    /// stale is worse than no indicator.
    private var indicators: SessionIndicators {
        SessionIndicators.make(
            isListening: session.isListening,
            failure: session.failure,
            recognition: recognition.phase,
            themStatus: session.themStatus,
            isGenerating: session.isGenerating,
            suggestionFailure: session.lastSuggestionFailure
        )
    }

    private var isModelReady: Bool { recognition.phase.isReady }

    /// Whether pressing the button would do anything.
    ///
    /// Stopping is always allowed — only starting waits for the model.
    private var canPressListen: Bool {
        if session.isStarting { return false }
        return session.isListening || session.canStartListening
    }

    private var listenButton: some View {
        Button { session.toggle() } label: {
            Label(listenTitle, systemImage: session.isListening ? "stop.fill" : "mic.fill")
                .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .disabled(!canPressListen)
        .help(listenHelp)
    }

    private var listenTitle: String {
        if session.isStarting { return "Доступ…" }
        if session.isListening { return "Стоп" }
        // The word on a disabled button has to say why it is disabled — the
        // reason below the header explains it, but the button is what the eye
        // goes to first.
        return isModelReady ? "Слушать" : "Подготовка…"
    }

    private var listenHelp: String {
        if let reason = recognition.phase.listeningBlockedReason, !session.isListening {
            return reason
        }
        return "Начать и остановить прослушивание микрофона — канал You. Кнопка ничего не отправляет в звонок."
    }

    private var settingsButton: some View {
        Button { openSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
        }
        .controlSize(.small)
        .help("Настройки: профиль, ключ провайдера, пороги нарезки реплик.")
    }

    // MARK: - Recognition readiness

    /// Where the recognition model has got to, stated in the overlay itself.
    ///
    /// Until this was here the window said nothing while the model loaded, the
    /// button was pressable, and the user started talking into a session that
    /// could not transcribe: the opening turn came back empty or half — measured
    /// once at 75 characters out of 144. In an interview that is the first
    /// question, gone.
    ///
    /// It disappears in exactly one case — model ready *and* the session already
    /// listening — because from then on the green dot and the «Стоп» button say
    /// the same thing, and the overlay has to stay small mid-call.
    ///
    /// This is the only place readiness is ever reported. GhostMeet posts no
    /// system notifications at all, not even the cheerful "ready now" kind: a
    /// banner is drawn on top of everything the user is sharing and hands the
    /// app over (ADR-0004). Good news is no exception to that rule.
    @ViewBuilder
    private var recognitionNotice: some View {
        if let reason = recognition.phase.listeningBlockedReason {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(reason)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: recognitionIcon)
                }
                .font(.system(size: 11))

                if case .downloading(let fraction) = recognition.phase {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else if case .loading = recognition.phase {
                    // Loading reports no progress, so an indeterminate bar is
                    // the honest shape: it says "working", not "almost there".
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(recognitionBackground)
        } else if !session.isListening {
            Label("Модель готова — можно слушать", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var recognitionIcon: String {
        if case .failed = recognition.phase { return "exclamationmark.triangle.fill" }
        return "arrow.down.circle"
    }

    private var recognitionBackground: Color {
        if case .failed = recognition.phase { return Color.orange.opacity(0.15) }
        return Color.yellow.opacity(0.12)
    }

    // MARK: - Failure notice

    /// The one place capture failures are ever reported.
    @ViewBuilder
    private var failureNotice: some View {
        if let failure = session.failure {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(failure.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 11))

                if failure.isPermissionDenied {
                    Button("Открыть настройки приватности") { openMicrophonePrivacySettings() }
                        .controlSize(.small)
                        .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.15))
        }
    }

    /// Sends the user to the microphone switch itself, rather than describing
    /// where it is and hoping.
    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - The Them channel

    /// What the `Them` channel is doing, whenever that is not simply "слушаю".
    ///
    /// This is the one failure of the app the user cannot hear: the microphone
    /// works, the transcript fills with their own turns, and the other side is
    /// silent for a reason nobody stated. Until now the reason went to the
    /// unified log and nowhere else.
    ///
    /// Inside the window and nowhere else, like every other report here: a
    /// notification banner would be drawn over the shared screen (ADR-0004).
    @ViewBuilder
    private var themNotice: some View {
        let them = indicators.them
        if them.state.deservesAnExplanation {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(them.detail)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: them.state == .failed
                        ? "exclamationmark.triangle.fill"
                        : "speaker.slash")
                }
                .font(.system(size: 11))

                if isThemBlockedByScreenRecording {
                    Button("Открыть настройки записи экрана") { openScreenRecordingPrivacySettings() }
                        .controlSize(.small)
                        .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                them.state == .failed ? Color.orange.opacity(0.15) : Color.yellow.opacity(0.12)
            )
        }
    }

    /// Whether the channel is silent because Screen Recording was never granted.
    ///
    /// Compared against the very constant the capture layer publishes, so this
    /// cannot drift into offering the button for an unrelated failure.
    private var isThemBlockedByScreenRecording: Bool {
        session.themStatus == .failed(reason: ThemCaptureBackend.screenRecordingHelp)
    }

    private func openScreenRecordingPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Suggestions

    /// The main content of the window: what the model is answering right now.
    ///
    /// It takes the space that is left over, because this is what the user reads
    /// mid-call; the transcript below is there to check that both channels are
    /// being heard.
    private var suggestions: some View {
        SuggestionFeedView(suggestions: session.suggestions)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Transcript

    /// The transcript keeps the lower strip of the window: enough to see the
    /// last turns of both channels without competing with the suggestion.
    private var transcript: some View {
        TranscriptView(turns: session.transcript)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 132, alignment: .topLeading)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            opacityControl
            HotkeysSectionView(hotkeys: hotkeys)
            sharingScopeNote
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var opacityControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Slider(value: $controller.opacity, in: controller.opacityRange)
                .controlSize(.mini)
                .frame(maxWidth: 140)

            Text("\(Int((controller.opacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            Spacer(minLength: 0)
        }
        .help("Прозрачность окна. Размер меняется перетаскиванием краёв, положение — перетаскиванием окна; и то и другое запоминается между запусками.")
    }

    /// The scope of the invisibility guarantee, spelled out in the interface and
    /// not only in `docs/adr/0004-invisibility-scope.md`, as that ADR requires.
    private var sharingScopeNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: 9))

            Text("Скрыто при шаринге окна или вкладки. При шаринге всего экрана невидимость не гарантируется.")
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .help("Окно исключено из захвата экрана, поэтому не попадает в шаринг отдельного окна или вкладки браузера. Шаринг всего экрана сознательно не поддерживается — выбирайте окно или вкладку.")
    }
}

#Preview {
    // A session with no sources: the preview shows the empty transcript and the
    // controls, without asking the previewing machine for its microphone.
    let session = SessionController(engine: SessionEngine(), requestMicrophoneAccess: { false })
    // A throwaway settings suite, so previewing never rewrites the user's own
    // model choice or hotkeys. Nothing calls `prepare()`, so no gigabytes move
    // either.
    let settings = SettingsStore(
        defaults: UserDefaults(suiteName: "GhostMeetOverlayPreview") ?? .standard,
        secrets: InMemorySecretStore()
    )
    let recognition = SpeechModelStatus(store: settings)
    // A registry that registers nothing: previewing must not take four chords
    // away from the machine running Xcode.
    let hotkeys = HotkeyCenter(store: settings, registry: InertHotkeyRegistry())
    ContentView(
        controller: OverlayWindowController(
            session: session,
            recognition: recognition,
            hotkeys: hotkeys,
            openSettings: {}
        ),
        session: session,
        recognition: recognition,
        hotkeys: hotkeys,
        openSettings: {}
    )
    .frame(width: 420, height: 520)
}
