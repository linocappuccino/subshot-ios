import Foundation

/// 2026-07-22 — translation strings for the "support/utility views" batch
/// (EmojiPickerField, ImageSourceButton, LoginView) plus the couple of
/// genuinely user-facing strings found in ShotListViewModel while auditing
/// the ViewModels/Services layer per this pass's instructions. See
/// AppLanguage.swift's `allTables` doc comment for why this lives in its
/// own file instead of editing the shared dictionary directly.
///
/// Wording for keys with an established web equivalent (see lib/i18n.tsx)
/// is copied verbatim from there rather than re-invented — emojiField.* →
/// emojiPickerField.*, common.cancel → imageSourceButton.cancel,
/// imageDropZone.emptyLabel → imageSourceButton.title, scene.unnamed →
/// shotListViewModel.unnamedScene, ideaGrid.newIdeaTitle →
/// shotListViewModel.newIdeaTitle.
extension AppLanguage {
    static let supportStrings: [String: [String: String]] = [
        "de": [
            // EmojiPickerField.swift — UI chrome only, NOT the emoji
            // name/search dataset itself (that stays the German
            // emojibase-data locale, per this pass's explicit instructions).
            "emojiPickerField.searchPlaceholder": "Suchen…",
            "emojiPickerField.noResults": "Keine Treffer",
            "emojiPickerField.filmProject": "Film & Projekt",
            "emojiPickerField.groupSmileys": "Smileys & Emotionen",
            "emojiPickerField.groupPeople": "Menschen",
            "emojiPickerField.groupNature": "Natur",
            "emojiPickerField.groupFood": "Essen & Trinken",
            "emojiPickerField.groupTravel": "Reisen",
            "emojiPickerField.groupActivity": "Aktivität",
            "emojiPickerField.groupObjects": "Objekte",
            "emojiPickerField.groupSymbols": "Symbole",
            "emojiPickerField.groupFlags": "Flaggen",

            // ImageSourceButton.swift
            "imageSourceButton.title": "Bild hinzufügen",
            "imageSourceButton.takePhoto": "Foto aufnehmen",
            "imageSourceButton.chooseFromLibrary": "Aus Mediathek wählen",
            "imageSourceButton.cancel": "Abbrechen",

            // LoginView.swift — "Subshot" itself stays untranslated (brand
            // wordmark, matches the web app's own font-anton logo not being
            // run through t() either).
            "loginView.tagline": "Shots planen. Am Set abhaken.",
            "loginView.signInButton": "Anmelden",

            // ShotListViewModel.swift — found while auditing the ViewModel
            // layer per this pass's instructions (see its own doc comments
            // at the call sites for why APIError's generic network-error
            // strings were deliberately NOT touched here).
            "shotListViewModel.unnamedScene": "Unbenannte Szene",
            "shotListViewModel.sceneDeletedUndoLabel": "Szene „{name}“ gelöscht",
            "shotListViewModel.newIdeaTitle": "Neue Idee",
        ],
        "en": [
            "emojiPickerField.searchPlaceholder": "Search…",
            "emojiPickerField.noResults": "No results",
            "emojiPickerField.filmProject": "Film & Project",
            "emojiPickerField.groupSmileys": "Smileys & Emotion",
            "emojiPickerField.groupPeople": "People",
            "emojiPickerField.groupNature": "Nature",
            "emojiPickerField.groupFood": "Food & Drink",
            "emojiPickerField.groupTravel": "Travel",
            "emojiPickerField.groupActivity": "Activity",
            "emojiPickerField.groupObjects": "Objects",
            "emojiPickerField.groupSymbols": "Symbols",
            "emojiPickerField.groupFlags": "Flags",

            "imageSourceButton.title": "Add image",
            "imageSourceButton.takePhoto": "Take photo",
            "imageSourceButton.chooseFromLibrary": "Choose from library",
            "imageSourceButton.cancel": "Cancel",

            "loginView.tagline": "Plan shots. Check them off on set.",
            "loginView.signInButton": "Sign in",

            "shotListViewModel.unnamedScene": "Untitled scene",
            "shotListViewModel.sceneDeletedUndoLabel": "Scene \u{201C}{name}\u{201D} deleted",
            "shotListViewModel.newIdeaTitle": "New idea",
        ],
    ]
}
