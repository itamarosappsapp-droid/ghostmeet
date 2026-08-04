//
//  ContentView.swift
//  GhostMeet
//

import SwiftUI

/// Content of the overlay panel: the suggestion feed, the only window control the
/// user should have to touch mid-call (opacity), and an honest note about what the
/// invisibility promise covers.
struct ContentView: View {

    @ObservedObject var controller: OverlayWindowController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            feed
            Divider().opacity(0.4)
            sharingScopeNote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: controller.cornerRadius, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // TODO(10 — Хоткеи, паника и индикаторы): real per-channel state here
            // (слушает / думает / ошибка), instead of this static dot.
            Circle()
                .fill(.secondary)
                .frame(width: 7, height: 7)

            Text("GhostMeet")
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 12)

            opacityControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var opacityControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Slider(value: $controller.opacity, in: controller.opacityRange)
                .controlSize(.mini)
                .frame(width: 90)

            Text("\(Int((controller.opacity * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .help("Прозрачность окна. Размер меняется перетаскиванием краёв, положение — перетаскиванием окна; и то и другое запоминается между запусками.")
    }

    // MARK: - Feed

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // TODO(07 — Автоподсказка, 08 — Жизненный цикл подсказки): лента подсказок
                // со скроллом — автоскролл к новой, последняя визуально выделена.
                // TODO(03 — Распознавание): сюда же встанет TranscriptView(turns:)
                // из UI/MainWindow/TranscriptView.swift, когда появится источник
                // реплик (SessionEngine).
                Text("Подсказки появятся здесь")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    /// The scope of the invisibility guarantee, spelled out in the interface and not
    /// only in `docs/adr/0004-invisibility-scope.md`, as that ADR requires.
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help("Окно исключено из захвата экрана, поэтому не попадает в шаринг отдельного окна или вкладки браузера. Шаринг всего экрана сознательно не поддерживается — выбирайте окно или вкладку.")
    }
}

#Preview {
    ContentView(controller: OverlayWindowController())
        .frame(width: 420, height: 520)
}
