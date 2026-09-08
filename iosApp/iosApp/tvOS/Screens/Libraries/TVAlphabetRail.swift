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
                    if (selected ?? "All") == letter {
                        Label(letter, systemImage: "checkmark")
                    } else { Text(letter) }
                }
            }
        } label: {
            Text(selected.map { "A–Z · \($0)" } ?? "A–Z")
        }
        .menuStyle(.button)
        .buttonStyle(TVBrowseControlPillStyle(active: selected != nil))
        .accessibilityLabel("Jump to title, \(selected ?? "All")")
    }
}
#endif
