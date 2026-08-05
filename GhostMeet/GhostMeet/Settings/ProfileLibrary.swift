//
//  ProfileLibrary.swift
//  GhostMeet
//

import Foundation

/// Every profile the user keeps, and which one is in force right now.
///
/// The user has more than one resume — «Тимлид» and «Синьор фулстек» are two
/// different people on paper — and the profile is what makes a suggestion sound
/// like them. Suggesting a team lead's answers at a full-stack interview is
/// exactly the failure the profile exists to prevent, so the choice belongs to
/// the user and has to be one click before the call.
///
/// **The library changes nothing above it.** Prompts still receive a single
/// `UserProfile`: `selected`. That is the whole point of keeping the selection
/// here rather than teaching the prompt layer about a list.
///
/// Two invariants hold at all times, including after decoding a file somebody
/// hand-edited:
///
/// 1. **The library is never empty.** Removing the last profile leaves a fresh
///    blank one, because a session with no profile at all has nowhere to put the
///    fields the settings screen is showing.
/// 2. **The selection always points at a profile that exists.** A dangling id
///    falls back to the first entry instead of leaving the app with no profile
///    to send.
nonisolated struct ProfileLibrary: Codable, Equatable, Sendable {

    private(set) var profiles: [UserProfile]
    private(set) var selectedID: UserProfile.ID

    /// What a machine that has never seen this app starts with: one blank
    /// profile, selected.
    static var initial: ProfileLibrary {
        ProfileLibrary(profiles: [UserProfile()])
    }

    /// Builds a library, repairing both invariants as it goes.
    init(profiles: [UserProfile], selectedID: UserProfile.ID? = nil) {
        let unique = Self.deduplicated(profiles)
        let kept = unique.isEmpty ? [UserProfile()] : unique
        self.profiles = kept
        self.selectedID = kept.contains { $0.id == selectedID }
            ? (selectedID ?? kept[0].id)
            : kept[0].id
    }

    /// Wraps the single profile of an older build — the migration path, spelled
    /// out here so that `SettingsStore` does not have to know the shape.
    init(migrating profile: UserProfile) {
        self.init(profiles: [profile], selectedID: profile.id)
    }

    /// The one profile that reaches a prompt.
    var selected: UserProfile {
        profiles.first { $0.id == selectedID } ?? profiles[0]
    }

    // MARK: - Editing

    mutating func select(_ id: UserProfile.ID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Adds a profile and selects it — adding one is always a prelude to
    /// filling it in.
    @discardableResult
    mutating func add(_ profile: UserProfile = UserProfile()) -> UserProfile.ID {
        profiles.append(profile)
        selectedID = profile.id
        return profile.id
    }

    /// Writes a profile back over the entry with the same id. A profile the
    /// library has never seen is ignored rather than appended: an edit to a
    /// deleted profile must not resurrect it.
    mutating func update(_ profile: UserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }

    /// Puts `profile` in the place of the selected one, adopting its identity.
    ///
    /// This is what `SettingsStore.profile`'s setter runs, which is why it
    /// takes the incoming id rather than keeping the old one: assigning a whole
    /// profile means "this is now the selected profile", and an imported one
    /// carries the id of the entry it was built for anyway.
    mutating func replaceSelected(with profile: UserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }) else {
            add(profile)
            return
        }
        profiles[index] = profile
        selectedID = profile.id
    }

    mutating func rename(_ id: UserProfile.ID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }

    /// Removes a profile, keeping both invariants: the library keeps at least
    /// one entry, and the selection lands on the neighbour rather than nowhere.
    mutating func remove(_ id: UserProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        if profiles.isEmpty { profiles = [UserProfile()] }
        guard id == selectedID else { return }
        selectedID = profiles[min(index, profiles.count - 1)].id
    }

    // MARK: - Persistence

    /// Decoded defensively: a preferences file written by a future build, or by
    /// a hand that got the id wrong, still yields a usable library rather than
    /// an app with no profile.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            profiles: try container.decodeIfPresent([UserProfile].self, forKey: .profiles) ?? [],
            selectedID: try container.decodeIfPresent(UserProfile.ID.self, forKey: .selectedID)
        )
    }

    /// Two entries with the same id would make "the selected one" ambiguous;
    /// the later duplicate gets a new identity instead of being dropped, since
    /// its contents are the user's.
    private static func deduplicated(_ profiles: [UserProfile]) -> [UserProfile] {
        var seen: Set<UserProfile.ID> = []
        return profiles.map { profile in
            guard seen.insert(profile.id).inserted else {
                let copy = UserProfile(
                    name: profile.name,
                    role: profile.role,
                    experience: profile.experience,
                    stack: profile.stack
                )
                seen.insert(copy.id)
                return copy
            }
            return profile
        }
    }
}
