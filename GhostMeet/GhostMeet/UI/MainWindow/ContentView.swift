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

    /// Opens the settings window. In accessory mode there is no menu bar, so
    /// this button is the only way in.
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            failureNotice
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
            // TODO(10 — Хоткеи, паника и индикаторы): per-channel state here
            // (слушает / думает / ошибка) instead of one dot for the session.
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text("GhostMeet")
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 12)

            listenButton
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if session.failure != nil { return .orange }
        return session.isListening ? .green : .secondary
    }

    private var listenButton: some View {
        Button { session.toggle() } label: {
            Label(listenTitle, systemImage: session.isListening ? "stop.fill" : "mic.fill")
                .font(.system(size: 11, weight: .medium))
        }
        .controlSize(.small)
        .disabled(session.isStarting)
        .help("Начать и остановить прослушивание микрофона — канал You. Кнопка ничего не отправляет в звонок.")
    }

    private var listenTitle: String {
        if session.isStarting { return "Доступ…" }
        return session.isListening ? "Стоп" : "Слушать"
    }

    private var settingsButton: some View {
        Button { openSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
        }
        .controlSize(.small)
        .help("Настройки: профиль, ключ провайдера, пороги нарезки реплик.")
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
    ContentView(
        controller: OverlayWindowController(session: session, openSettings: {}),
        session: session,
        openSettings: {}
    )
    .frame(width: 420, height: 520)
}
