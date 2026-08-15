import SwiftUI
import ZwispCore

/// The Dictionary section: the exact-spelling word list plus the add field.
/// Each word row expands (click) into a "sounds like" editor where the user
/// registers the mishearings Whisper actually produced for it ("Zeddo" for
/// "Ziedo") — those feed both the deterministic corrector and the cleanup
/// prompt. The `AddResult` feedback handling matches the word add field.
struct DictionarySectionView: View {
    let model: SettingsModel
    @State private var newWord = ""
    @State private var feedback: DictionaryStore.AddResult?
    /// The one word whose sounds-like editor is open, if any.
    @State private var expandedWord: String?
    @State private var newAlias = ""
    @State private var aliasFeedback: DictionaryStore.AliasAddResult?

    private func submit() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let result = model.addDictionaryWord(word)
        feedback = result
        if result == .added || result == .updated {
            newWord = ""
        }
    }

    private func toggleExpansion(of word: String) {
        expandedWord = expandedWord == word ? nil : word
        newAlias = ""
        aliasFeedback = nil
    }

    private func submitAlias(for word: String) {
        let alias = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return }
        let result = model.addDictionaryAlias(alias, for: word)
        aliasFeedback = result
        if result == .added || result == .updated {
            newAlias = ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceXL) {
            SectionHeader(title: "Dictionary",
                          subtitle: "Names and terms zwisp should spell exactly your way. "
                            + "Click a word to teach it mishearings.")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    if model.dictionaryEntries.isEmpty {
                        Text("No words yet.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 10)
                    }
                    ForEach(Array(model.dictionaryEntries.enumerated()),
                            id: \.element) { index, word in
                        wordRow(word, isLast: index == model.dictionaryEntries.count - 1)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Theme.spaceS) {
                    HStack(spacing: Theme.spaceM) {
                        TextField("e.g. WhisperKit", text: $newWord)
                            .textFieldStyle(.plain)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, Theme.spaceM)
                            .padding(.vertical, 7)
                            .background(Theme.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
                            .onSubmit(submit)
                        Button("Add", action: submit)
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    switch feedback {
                    case .rejected?:
                        Text(model.dictionaryRejectionMessage)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    case .duplicate?:
                        Text("Already in your dictionary.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    default:
                        EmptyView()
                    }
                }
            }
            Card {
                ToggleRow(title: "Learn from your edits",
                          caption: "After zwisp types, fixing a word right there adds it "
                            + "here automatically — a countdown lets you cancel each add.",
                          isOn: Binding(
                            get: { model.editLearningEnabled },
                            set: { model.setEditLearningEnabled($0) }))
            }
        }
        .onChange(of: newWord) { feedback = nil }
        .onChange(of: newAlias) { aliasFeedback = nil }
    }

    // MARK: - Word rows

    private func wordRow(_ word: String, isLast: Bool) -> some View {
        let aliases = model.dictionaryAliases[word] ?? []
        let expanded = expandedWord == word
        return VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: word,
                       caption: expanded || aliases.isEmpty
                           ? nil : "Sounds like " + aliases.joined(separator: ", "),
                       // When expanded, the divider moves below the editor.
                       showsDivider: !isLast && !expanded) {
                HStack(spacing: Theme.spaceM) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Remove") { model.removeDictionaryWord(word) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleExpansion(of: word) }
            if expanded {
                aliasEditor(for: word, aliases: aliases)
                if !isLast {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: Theme.hairlineWidth)
                }
            }
        }
    }

    // MARK: - Sounds-like editor

    private func aliasEditor(for word: String, aliases: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            if aliases.isEmpty {
                Text("No mishearings yet — add what zwisp typed instead of “\(word)”.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(aliases, id: \.self) { alias in
                HStack(spacing: Theme.spaceM) {
                    Text(alias)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Theme.spaceM)
                    Button {
                        model.removeDictionaryAlias(alias, for: word)
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: Theme.spaceM) {
                TextField("Heard as… e.g. Zeddo", text: $newAlias)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.spaceM)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth))
                    .onSubmit { submitAlias(for: word) }
                Button("Add") { submitAlias(for: word) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(newAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            switch aliasFeedback {
            case .rejected?:
                Text(model.dictionaryRejectionMessage)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            case .conflict?:
                Text(model.aliasConflictMessage)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.attention)
            case .duplicate?:
                Text("Already listed for this word.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            default:
                EmptyView()
            }
        }
        .padding(.leading, Theme.spaceM)
        .padding(.bottom, 10)
    }
}
