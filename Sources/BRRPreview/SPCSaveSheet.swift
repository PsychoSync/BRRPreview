import BRRCore
import SwiftUI

/// Shows the song's extended tags before an SPC is saved. Fields left unchanged keep their original bytes.
struct SPCSaveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    let initialTags: SPCExtendedTags
    let onSave: (SPCExtendedTags) -> Void

    private static let textFields: [(id: UInt8, label: String)] = [
        (0x01, "Song name"),
        (0x02, "Game"),
        (0x03, "Artist"),
        (0x04, "Dumper"),
        (0x07, "Comments"),
        (0x10, "Official soundtrack title"),
        (0x13, "Publisher"),
    ]
    private static let dateID: UInt8 = 0x05

    @State private var texts: [UInt8: String]
    @State private var dateText: String
    private let originalDate: String

    init(fileName: String, initialTags: SPCExtendedTags, onSave: @escaping (SPCExtendedTags) -> Void) {
        self.fileName = fileName
        self.initialTags = initialTags
        self.onSave = onSave
        let date = initialTags.integer(Self.dateID).map { String($0) } ?? ""
        originalDate = date
        _dateText = State(initialValue: date)
        _texts = State(initialValue: Dictionary(uniqueKeysWithValues: Self.textFields.map {
            ($0.id, initialTags.text($0.id) ?? "")
        }))
    }

    private var hasExistingTags: Bool {
        !initialTags.items.isEmpty || !initialTags.remainder.isEmpty
    }

    /// Blank, unchanged, or eight digits such as 20240101.
    private var dateIsValid: Bool {
        dateText.isEmpty || dateText == originalDate
            || (dateText.count == 8 && dateText.allSatisfy { ("0"..."9").contains($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save \(fileName)")
                .font(.headline)

            Text(hasExistingTags
                 ? "Extended tags from the file. Change any field, or leave them alone to keep the original values."
                 : "This file has no extended tags. Anything you fill in is written as a new xid6 block.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !initialTags.remainder.isEmpty {
                Text("Part of the extended block could not be read. It will be kept as it was.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Form {
                ForEach(Self.textFields, id: \.id) { field in
                    TextField(field.label, text: binding(for: field.id))
                }
                TextField("Date dumped (yyyymmdd)", text: $dateText)
                if !dateIsValid {
                    Text("Use eight digits, such as 20240101, or leave the field blank.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save…") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!dateIsValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func binding(for id: UInt8) -> Binding<String> {
        Binding(
            get: { texts[id] ?? "" },
            set: { texts[id] = $0 }
        )
    }

    /// Applies only the fields the user changed, so untouched items keep their original bytes.
    private func save() {
        var tags = initialTags
        for field in Self.textFields {
            let value = texts[field.id] ?? ""
            if value != (initialTags.text(field.id) ?? "") {
                tags.setText(field.id, value)
            }
        }
        if dateText != originalDate {
            tags.setInteger(Self.dateID, Int(dateText))
        }
        onSave(tags)
        dismiss()
    }
}
