//
//  UpdateNoticeView.swift
//  GhostMeet
//

import AppKit
import SwiftUI

/// One quiet line saying a newer GhostMeet exists, and where to read about it.
///
/// **Not a fourth field in the readiness strip.** That strip answers «чем я
/// вооружён» in one line across 420 points and truncates already; a fourth field
/// would push the profile name off it to state something that is usually not
/// worth stating at all. This appears only when there is something to say, and
/// takes no room the rest of the time — the same bargain `routeNotice` strikes
/// one line below.
///
/// **It is shown before the call and not during it.** The caller hides it once
/// listening starts: a new version is news, not a diagnosis, and news hanging
/// over the suggestion feed for an hour is the nagging kind of honesty that gets
/// ignored. Nothing about it is urgent — the build in hand keeps working.
///
/// The link opens the release page in a browser, which brings that browser
/// forward. That is the reason it is a link and not a download button: during a
/// call the answer to «обновиться прямо сейчас» is no, and the click has to be
/// deliberate enough to be worth it.
struct UpdateNoticeView: View {

    let release: PublishedRelease

    /// Puts the line away for this launch — see `UpdateCheck.dismiss()`.
    let dismiss: () -> Void

    /// How a URL is opened. Injected so a preview — and anything that runs
    /// without a browser — does not launch one.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text("Вышла версия \(release.version.description)")
            } icon: {
                Image(systemName: "arrow.down.circle")
            }

            Button("что нового") { open(release.page) }
                .buttonStyle(.link)
                .font(.system(size: 10))

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Скрыть до следующего запуска")
            .accessibilityLabel("Скрыть уведомление о новой версии")
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

#Preview {
    UpdateNoticeView(
        release: PublishedRelease(
            version: AppVersion(major: 0, minor: 2, patch: 0),
            page: URL(string: "https://github.com/slimgo/ghostmeet/releases/tag/v0.2.0")!
        ),
        dismiss: {},
        open: { _ in }
    )
    .frame(width: 420)
}
