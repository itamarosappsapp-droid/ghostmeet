//
//  UserProfile.swift
//  GhostMeet
//

import Foundation

/// Standing facts about the user — role, experience, stack — that are not
/// derivable from the conversation and are filled in ahead of a call.
///
/// The profile belongs to the *user*, not to the call: it lives in
/// `SettingsStore` (user-scoped storage), never in session state, which is why
/// clearing the conversation context leaves it untouched.
nonisolated struct UserProfile: Codable, Equatable, Sendable {

    /// Job title the user is interviewing for or working as.
    var role: String

    /// Free-form experience summary — years, domains, notable projects.
    var experience: String

    /// Technologies the user actually works with.
    var stack: String

    /// A profile the user has not filled in yet.
    static let empty = UserProfile()

    init(role: String = "", experience: String = "", stack: String = "") {
        self.role = role
        self.experience = experience
        self.stack = stack
    }

    var isEmpty: Bool {
        role.trimmedOrNil == nil && experience.trimmedOrNil == nil && stack.trimmedOrNil == nil
    }

    /// The block appended to the end of the system prompt (the
    /// `{{resume_context}}` slot in docs/GhostMeet-Prompts.md). Blank fields are
    /// omitted rather than sent as empty labels.
    var promptFragment: String {
        var lines: [String] = []
        if let role = role.trimmedOrNil { lines.append("Роль: \(role)") }
        if let experience = experience.trimmedOrNil { lines.append("Опыт: \(experience)") }
        if let stack = stack.trimmedOrNil { lines.append("Стек: \(stack)") }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    /// The trimmed string, or `nil` when nothing but whitespace is left.
    nonisolated var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
