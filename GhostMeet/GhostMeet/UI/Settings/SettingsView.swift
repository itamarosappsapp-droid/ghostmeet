//
//  SettingsView.swift
//  GhostMeet
//

import SwiftUI

/// Settings screen: profile, provider key, turn-segmentation thresholds.
///
/// Every control writes straight through to the observable `SettingsStore`, so
/// a change takes effect at once — there is no Apply button and no restart.
struct SettingsView: View {

    @Bindable var store: SettingsStore

    /// Holds the key only while the user is typing it. Cleared as soon as it
    /// reaches the keychain so the secret does not linger in view state.
    @State private var providerKeyDraft: String = ""

    var body: some View {
        Form {
            profileSection
            providerKeySection
            segmentationSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section("Профиль") {
            LabeledContent("Роль") {
                TextField("Например: backend-разработчик", text: $store.profile.role)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Опыт") {
                TextField(
                    "Например: 6 лет, финтех и высоконагруженные сервисы",
                    text: $store.profile.experience,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Стек") {
                TextField(
                    "Например: Go, PostgreSQL, Kubernetes",
                    text: $store.profile.stack,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            }
            Text("Профиль относится к вам, а не к звонку: очистка контекста разговора его не стирает.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Provider key

    private var providerKeySection: some View {
        Section("Ключ провайдера") {
            SecureField("API-ключ", text: $providerKeyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveProviderKey)

            HStack {
                Button("Сохранить", action: saveProviderKey)
                    .disabled(providerKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Удалить", role: .destructive) {
                    providerKeyDraft = ""
                    store.removeProviderKey()
                }
                .disabled(!store.hasProviderKey)
                Spacer()
                Text(store.hasProviderKey ? "Ключ сохранён в Keychain" : "Ключ не задан")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = store.lastSecretError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Text("Ключ хранится только в системном Keychain — не в настройках приложения, не в файлах и не в логах.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func saveProviderKey() {
        guard store.setProviderKey(providerKeyDraft) else { return }
        providerKeyDraft = ""
    }

    // MARK: - Turn segmentation

    private var segmentationSection: some View {
        Section("Нарезка реплик") {
            threshold(
                title: "Порог паузы",
                value: $store.turnSegmentation.pauseThreshold,
                range: TurnSegmentationSettings.pauseThresholdRange,
                step: 0.05,
                format: { "\(Int(($0 * 1000).rounded())) мс" },
                hint: "Тишина такой длины закрывает реплику."
            )
            threshold(
                title: "Минимальная длина реплики",
                value: $store.turnSegmentation.minimumTurnDuration,
                range: TurnSegmentationSettings.minimumTurnDurationRange,
                step: 0.05,
                format: { String(format: "%.2f с", $0) },
                hint: "Более короткие отрезки не попадают в распознавание."
            )
            threshold(
                title: "Страховочный флаш",
                value: $store.turnSegmentation.safetyFlushInterval,
                range: TurnSegmentationSettings.safetyFlushIntervalRange,
                step: 1,
                format: { String(format: "%.0f с", $0) },
                hint: "Монолог без пауз всё равно попадёт в транскрипт по этому таймеру."
            )
            threshold(
                title: "Порог RMS-гейта",
                value: Binding(
                    get: { TimeInterval(store.turnSegmentation.rmsGateThreshold) },
                    set: { store.turnSegmentation.rmsGateThreshold = Float($0) }
                ),
                range: Self.rmsGateRange,
                step: 0.001,
                format: { String(format: "%.3f", $0) },
                hint: "Звук тише этого уровня считается тишиной."
            )

            Button("Вернуть значения по умолчанию") {
                store.resetTurnSegmentationToDefaults()
            }
        }
    }

    /// The RMS gate is a `Float` in the model but a `TimeInterval` in the
    /// shared slider helper, so its range is bridged once here.
    private static let rmsGateRange: ClosedRange<TimeInterval> = {
        let bounds = TurnSegmentationSettings.rmsGateThresholdRange
        return TimeInterval(bounds.lowerBound)...TimeInterval(bounds.upperBound)
    }()

    private func threshold(
        title: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<TimeInterval>,
        step: TimeInterval,
        format: @escaping (TimeInterval) -> String,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Text(format(range.lowerBound))
            } maximumValueLabel: {
                Text(format(range.upperBound))
            }
            HStack {
                Text(hint)
                Spacer()
                Text(format(value.wrappedValue))
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView(
        store: SettingsStore(
            defaults: UserDefaults(suiteName: "GhostMeetSettingsPreview") ?? .standard,
            secrets: InMemorySecretStore()
        )
    )
}
