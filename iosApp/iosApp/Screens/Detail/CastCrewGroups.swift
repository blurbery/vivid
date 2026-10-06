import Foundation

/// One person in the Cast & Crew rail: a director, writer or cast member.
struct CastCrewPerson: Identifiable, Hashable {
    let id: String
    let personId: String?
    let name: String
    let role: String?
    let photoUrl: String?
    let photoThumbhash: String?
}

/// A labelled run of people in the Cast & Crew rail.
struct CastCrewGroup: Identifiable {
    let id: String
    let label: String
    let people: [CastCrewPerson]
}

/// Groups detail-page credits for the iPhone, iPad and Apple TV Cast & Crew
/// rails: directors first, then writers and creators, then the cast in the
/// order the server sends, which is its billing order. Empty groups are left
/// out.
enum CastCrewGrouping {
    static func groups(
        cast: [CastMember],
        crew: [CrewMember],
        maxCast: Int = 24,
        maxCrewPerGroup: Int = 6
    ) -> [CastCrewGroup] {
        // Between the crew groups, a person credited more than once (a
        // writer-director, or both screenplay and story) only appears in their
        // first group. The cast keeps every billed actor, so someone who
        // directs and acts still shows with their character.
        var seen = Set<String>()
        func crewGroup(_ id: String, label: String, role: (String?) -> String?) -> CastCrewGroup {
            var people: [CastCrewPerson] = []
            for member in crew {
                guard people.count < maxCrewPerGroup, let title = role(member.job),
                      seen.insert(member.personId ?? member.name.lowercased()).inserted else { continue }
                people.append(CastCrewPerson(
                    id: "\(id)-\(people.count)", personId: member.personId, name: member.name,
                    role: title, photoUrl: member.photoUrl, photoThumbhash: member.photoThumbhash
                ))
            }
            return CastCrewGroup(id: id, label: label, people: people)
        }

        let directors = crewGroup("directors", label: "Directors") { job in
            normalised(job) == "director" ? "Director" : nil
        }
        let writers = crewGroup("writers", label: "Writers") { job in
            let job = normalised(job)
            guard writerJobs.contains(job) else { return nil }
            return job == "creator" ? "Creator" : "Writer"
        }
        let castGroup = CastCrewGroup(
            id: "cast",
            label: "Cast",
            people: cast.prefix(maxCast).enumerated().map { index, member in
                CastCrewPerson(
                    id: "cast-\(index)", personId: member.personId, name: member.name,
                    role: member.character, photoUrl: member.photoUrl, photoThumbhash: member.photoThumbhash
                )
            }
        )
        return [directors, writers, castGroup].filter { !$0.people.isEmpty }
    }

    /// Whether the rail has anyone to show, so titles credited with only a
    /// director or writers still get a Cast & Crew section.
    static func hasPeople(cast: [CastMember]?, crew: [CrewMember]?) -> Bool {
        !groups(cast: cast ?? [], crew: crew ?? []).isEmpty
    }

    /// Writing credits as Silo (Writer) and Jellyfin's TMDb data (Screenplay,
    /// Story, Creator and so on) name them.
    private static let writerJobs: Set<String> = [
        "writer", "screenplay", "story", "teleplay", "novel", "creator",
    ]

    private static func normalised(_ job: String?) -> String {
        (job ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
