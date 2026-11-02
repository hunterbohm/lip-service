import AppKit
import DictationCore
import SwiftUI

struct DictionaryPage: View {
    let preferences: Preferences
    @State private var draft: TermDraft?
    @State private var snippetDraft: Snippet?
    @State private var saveError: String?

    var body: some View {
        let configuration = preferences.current
        let terms = configuration.vocabulary.terms
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle("Dictionary")
                    Spacer()
                    Button { draft = TermDraft() } label: { Label("Add Word", systemImage: "plus") }
                        .buttonStyle(DarkButtonStyle(kind: .prominent))
                }
                Text("Names and words Lip Service should spell your way, with the ways it mishears them.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, -10)
                    .padding(.bottom, 20)
                VStack(alignment: .leading, spacing: 10) {
                    if !configuration.settings.vocabularyEnabled {
                        Notice(tone: .warning, title: "Vocabulary boost is off", detail: "These words are not used until it is on.") {
                            Button("Turn On") { preferences.change { $0.vocabularyEnabled = true } }
                                .buttonStyle(DarkButtonStyle(kind: .prominent))
                        }
                    }
                    if let issue = configuration.issues.first {
                        Notice(tone: .warning, title: "Line \(issue.line) of the vocabulary file is skipped", detail: issue.message)
                    }
                    if let saveError { Notice(tone: .failure, title: "Could not save the vocabulary file", detail: saveError) }
                }
                .padding(.bottom, configuration.settings.vocabularyEnabled && configuration.issues.isEmpty && saveError == nil ? 0 : 18)
                if terms.isEmpty {
                    Text("No words yet. Add the names you say often.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(terms, id: \.text) { term in
                            TermTile(term: term) { draft = TermDraft(term) } delete: { remove(term) }
                        }
                    }
                    .frame(maxWidth: 760)
                }
                Button("Open Vocabulary File") {
                    preferences.seedVocabularyFile()
                    NSWorkspace.shared.open(preferences.vocabularyURL)
                }
                .buttonStyle(DarkButtonStyle())
                .padding(.top, 24)
                .padding(.bottom, 30)
                SettingLine(title: "Names from the screen", isOn: preferences.binding(\.screenNames),
                            detail: "When you start talking, Lip Service reads the names in the window you're in so it spells them right. Nothing leaves your Mac.")
                    .padding(.bottom, 16)
                SettingLine(title: "Learn from your fixes", isOn: preferences.binding(\.learnFixes),
                            detail: "When you correct one word Lip Service typed, your spelling goes into the dictionary. Nothing leaves your Mac.")
                    .padding(.bottom, 36)
                SnippetSection(snippets: configuration.settings.snippets, edit: { snippetDraft = $0 },
                               delete: { snippet in preferences.change { $0.snippets.removeAll { $0.id == snippet.id } } })
            }
            .page()
        }
        .sheet(item: $draft) { draft in
            TermEditor(draft: draft, save: save)
        }
        .sheet(item: $snippetDraft) { snippet in
            SnippetEditor(draft: snippet, isNew: !configuration.settings.snippets.contains { $0.id == snippet.id }, save: save)
        }
    }

    private func save(_ snippet: Snippet) -> String? {
        var snippets = preferences.current.settings.snippets
        do { try Snippets.save(snippet, in: &snippets) } catch { return error.message }
        preferences.change { $0.snippets = snippets }
        return nil
    }

    /// Each edit starts from the file as it is now, so a change made by hand in the meantime is kept.
    private func save(_ draft: TermDraft) -> String? {
        preferences.reloadVocabularyIfChanged()
        var vocabulary = preferences.current.vocabulary
        do {
            try vocabulary.save(.init(text: draft.text, aliases: Vocabulary.aliases(fromField: draft.aliases)),
                                replacing: draft.original)
        } catch {
            return error.message
        }
        saveError = write(vocabulary)
        return saveError
    }

    private func remove(_ term: Vocabulary.Term) {
        preferences.reloadVocabularyIfChanged()
        var vocabulary = preferences.current.vocabulary
        vocabulary.terms.removeAll { $0.text == term.text }
        saveError = write(vocabulary)
    }

    private func write(_ vocabulary: Vocabulary) -> String? {
        do {
            try preferences.saveVocabulary(vocabulary)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct TermDraft: Identifiable {
    let id = UUID()
    var original: String?
    var text = ""
    var aliases = ""

    init() {}

    init(_ term: Vocabulary.Term) {
        original = term.text
        text = term.text
        aliases = term.aliases.joined(separator: ", ")
    }
}

private struct TermTile: View {
    let term: Vocabulary.Term
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(term.text).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(term.aliases.isEmpty ? "No misheard spellings" : "Also heard as " + term.aliases.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                IconButton(symbol: "pencil", help: "Edit", size: 24, action: edit)
                IconButton(symbol: "trash", help: "Delete", size: 24, action: delete)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(hovering ? Theme.raised : Theme.tile))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

private struct TermEditor: View {
    @State var draft: TermDraft
    let save: (TermDraft) -> String?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "Add Word" : "Edit Word").font(.system(size: 17, weight: .semibold))
            Form {
                TextField("Word", text: $draft.text, prompt: Text("Siobhan"))
                TextField("Misheard as", text: $draft.aliases, prompt: Text("shivon, chevonne"))
            }
            Text("Separate misheard spellings with commas. Each one is replaced with the word.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(DarkButtonStyle())
                Button("Save") {
                    problem = save(draft)
                    if problem == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(DarkButtonStyle(kind: .prominent))
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.canvas)
    }
}

private struct SnippetSection: View {
    let snippets: [Snippet]
    let edit: (Snippet) -> Void
    let delete: (Snippet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Snippets", detail: "Say a cue on its own, and Lip Service inserts its text exactly as you saved it.")
                Spacer()
                Button { edit(Snippet(cue: "", text: "")) } label: { Label("Add Snippet", systemImage: "plus") }
                    .buttonStyle(DarkButtonStyle())
            }
            .frame(maxWidth: 760)
            if snippets.isEmpty {
                Text("No snippets yet. Add text you type often, such as your address or a sign-off.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.tertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(snippets) { snippet in
                        SnippetRow(snippet: snippet, edit: { edit(snippet) }, delete: { delete(snippet) })
                    }
                }
                .frame(maxWidth: 760)
            }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(snippet.cue)
                .font(.system(size: 14.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            Text(snippet.text.trimmingCharacters(in: .newlines))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                IconButton(symbol: "pencil", help: "Edit", size: 24, action: edit)
                IconButton(symbol: "trash", help: "Delete", size: 24, action: delete)
            }
            .opacity(hovering ? 1 : 0)
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(hovering ? Theme.raised : Theme.tile))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

private struct SnippetEditor: View {
    @State var draft: Snippet
    let isNew: Bool
    let save: (Snippet) -> String?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Snippet" : "Edit Snippet").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("When I say").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                TextField("When I say", text: $draft.cue, prompt: Text("my address"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Insert").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                TextEditor(text: $draft.text)
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.tile))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line))
            }
            Text("Say the cue on its own. Punctuation and capitals don't matter. The text goes in exactly as written here, line breaks included.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(DarkButtonStyle())
                Button("Save") {
                    problem = save(draft)
                    if problem == nil { dismiss() }
                }
                .buttonStyle(DarkButtonStyle(kind: .prominent))
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.canvas)
    }
}

/// A checkbox with a line under it that says what it does.
private struct SettingLine: View {
    let title: String
    @Binding var isOn: Bool
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CheckRow(title: title, isOn: $isOn)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 36)
                .frame(maxWidth: 680, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
