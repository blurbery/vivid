#if os(tvOS)
import SwiftUI

/// The native menu replaces the expanding alphabet rail.
struct TVAlphabetMenu: View {
    let selected: String?
    let onSelect: (String?) -> Void
    private let letters = ["All", "#"] + (65...90).compactMap { UnicodeScalar($0).map(String.init) }

    var body: some View {
        Menu {
            ForEach(letters, id: \.self) { letter in
                Button { onSelect(letter == "All" ? nil : letter) } label: {
                    // "All" stays the menu's own identity; only its label is translated.
                    let title = letter == "All" ? String(localized: "All") : letter
                    if (selected ?? "All") == letter {
                        Label(title, systemImage: "checkmark")
                    } else { Text(title) }
                }
            }
        } label: {
            selected.map { Text("A–Z · \($0)") } ?? Text("A–Z")
        }
        .menuStyle(.button)
        .buttonStyle(TVBrowseControlPillStyle(active: selected != nil))
        .accessibilityLabel(selected.map { Text("Jump to title, \($0)") } ?? Text("Jump to title, All"))
    }
}
#endif
