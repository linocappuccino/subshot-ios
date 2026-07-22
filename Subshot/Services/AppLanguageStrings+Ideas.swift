import Foundation

/// 2026-07-22 — translation keys for the Ideas + Postproduction/Video
/// workflow views (IdeaGridView, IdeaEditSheet, IdeaFeedbackSheet,
/// IdeaMediaSourceButton, PostproductionListView, VideoPanelView,
/// VideoPlayerSheet, NotificationsSheet, NotionImportSheet). See
/// AppLanguage.swift's own doc comment for why this lives in its own file
/// instead of a shared dictionary literal.
///
/// Wording matches lib/i18n.tsx wherever an equivalent web concept already
/// exists (e.g. postproductionStatus.*, reused verbatim including key
/// names since that group is explicitly shared across platforms; ideaCard./
/// ideaGrid./ideaTile./videoTile./videoReviewModal./notificationBell./
/// notionImportModal.* wording ported under this file's own iOS key names).
/// Deliberately NOT translated, left as marker text: IdeaSlashOption's
/// .label/.icon/.markerLine in IdeaSlashTextEditor.swift — those strings
/// are parsed verbatim by exact-match regexes server-side
/// (app/main.py's `_IDEA_SCENE_MARKER` etc.), translating them would break
/// parsing without a matching backend change, same reasoning as web's own
/// RichTextEditor.tsx slash-menu marker labels (see lib/i18n.tsx's own
/// comment above richTextEditor.* for the same footnote there).
extension AppLanguage {
    static let ideasStrings: [String: [String: String]] = [
        "de": [
            // IdeaGridView.swift
            "ideaGrid.heading": "💡 Ideen",
            "ideaGrid.emptyState": "Noch keine Ideen — leg die erste Idee für dieses Projekt an, bevor es ins Scripting geht.",
            "ideaGrid.groupIdea": "Idee",
            "ideaGrid.groupFeedback1": "1. Feedback",
            "ideaGrid.groupFeedback2": "2. Feedback",
            "ideaGrid.groupApproved": "✓ Abgenommen",
            "ideaGrid.newIdeaTitle": "Neue Idee",
            "ideaTile.approvedOn": "Angenommen am {date}",

            // IdeaEditSheet.swift
            "ideaEditSheet.imagesSectionTitle": "Bilder ({count}/10)",
            "ideaEditSheet.addImageButton": "Bild hinzufügen",
            "ideaEditSheet.uploadingImage": "Lädt hoch…",
            "ideaEditSheet.generatePopupTitle": "AI Bild generieren",
            "ideaEditSheet.titleSectionLabel": "Titel",
            "ideaEditSheet.descriptionSectionLabel": "Beschreibung",
            "ideaEditSheet.slashHint": "Tippe „/“ für Szene/Zwischenschritt (oder für Titel/Dialog innerhalb einer Szene). Zweimal Enter schliesst den Block ab.",
            "ideaEditSheet.feedbackSectionLabel": "Feedback",
            "ideaEditSheet.noFeedbackYet": "Noch kein Feedback",
            "ideaEditSheet.feedbackCountLabel": "{count} Feedback{suffix}",
            "ideaEditSheet.approvedBadge": "Angenommen",
            "ideaEditSheet.approvedOnLabel": "Angenommen am",
            "ideaEditSheet.approving": "Wird angenommen…",
            "ideaEditSheet.approveButton": "Abgenommen",
            "ideaEditSheet.deleteIdeaButton": "Idee löschen",
            "ideaEditSheet.navTitleFallback": "Idee",
            "ideaEditSheet.doneButton": "Fertig",
            "ideaEditSheet.insertDialogTitle": "Einfügen",
            "ideaEditSheet.cancelButton": "Abbrechen",
            "ideaEditSheet.noCreditsTitle": "Keine Credits mehr",
            "ideaEditSheet.later": "Später",
            "ideaEditSheet.buyCredits": "Credits kaufen",
            "ideaEditSheet.noCreditsMessage": "Du hast keine AI Credits mehr übrig, um ein Bild zu generieren. Lade Credits über die Web-Seite nach.",
            "ideaEditSheet.imagePromptSectionLabel": "Bildprompt",
            "ideaEditSheet.imagePromptPlaceholder": "Beschreibe das Bild...",
            "ideaEditSheet.imagePromptHint": "Leer lassen, um die Beschreibung der Idee selbst zu verwenden.",
            "ideaEditSheet.formatLabel": "Format",
            "ideaEditSheet.styleLabel": "Stil",
            "ideaEditSheet.styleRealistic": "Realistisch",
            "ideaEditSheet.styleSketch": "Sketch",
            "ideaEditSheet.generatingLabel": "Erstellt…",
            "ideaEditSheet.generateImageButton": "Bild generieren",

            // IdeaFeedbackSheet.swift
            "ideaFeedbackSheet.emptyState": "Noch kein Feedback",
            "ideaFeedbackSheet.feedbackWord": "Feedback",
            "ideaFeedbackSheet.openCount": "{count} offen",
            "ideaFeedbackSheet.navTitle": "Feedback zu „{title}“",
            "ideaFeedbackSheet.doneButton": "Fertig",

            // IdeaMediaSourceButton.swift
            "ideaMediaSourceButton.dialogTitle": "Bild oder Video hinzufügen",
            "ideaMediaSourceButton.takePhoto": "Foto aufnehmen",
            "ideaMediaSourceButton.chooseFromLibrary": "Aus Mediathek wählen",
            "ideaMediaSourceButton.cancel": "Abbrechen",

            // Shared postproduction status labels — reused verbatim from
            // web's lib/i18n.tsx (VideoTile.tsx, projects/[id]/page.tsx).
            "postproductionStatus.wartend": "Wartend",
            "postproductionStatus.inBearbeitung": "In Bearbeitung",
            "postproductionStatus.wartetAufFeedback": "Wartet auf Feedback",
            "postproductionStatus.abgeschlossen": "Abgeschlossen",
            "postproductionStatus.abgelehnt": "Abgelehnt",

            // PostproductionListView.swift
            "postproductionListView.navTitle": "Postproduction",
            "postproductionListView.doneButton": "Fertig",
            "postproductionListView.emptyTitle": "Noch keine Abschnitte",
            "postproductionListView.emptyDescription": "Auf der Szenenübersicht: Abschnitt gedrückt halten → „Ab in die Postproduction“, sobald alle Szenen im Kasten sind — oder unten rechts direkt ein unabhängiges Video hochladen.",
            "postproductionListView.titleAlertTitle": "Titel",
            "postproductionListView.cancelButton": "Abbrechen",
            "postproductionListView.saveButton": "Speichern",
            "postproductionListView.errorAlertTitle": "Fehler",
            "postproductionListView.videoLoadFailed": "Video konnte nicht geladen werden.",
            "postproductionListView.noUploadUrl": "Keine Upload-URL erhalten.",
            "postproductionListView.statusLabel": "Status",
            "postproductionListView.deadlineLabel": "Deadline",
            "postproductionListView.dateLabel": "Datum",
            "postproductionListView.deadlineWithValue": "Deadline: {date}",
            "postproductionListView.noVideoYet": "Noch kein Video",
            "postproductionListView.uploadVideo": "Video hochladen",
            "postproductionListView.processing": "In Verarbeitung…",

            // VideoPanelView.swift (superseded by PostproductionListView's
            // grid, see that file's own top-of-file doc comment — kept
            // translated anyway since the source file itself still ships).
            "videoPanelView.video": "Video",
            "videoPanelView.anotherVideo": "weiteres Video",
            "videoPanelView.noVideosYet": "Noch keine Videos.",
            "videoPanelView.videoLoadFailed": "Video konnte nicht geladen werden.",
            "videoPanelView.noUploadUrl": "Keine Upload-URL erhalten.",
            "videoPanelView.versionCommentsLabel": "Version {number} · {count} Kommentare",
            "videoPanelView.noVideoUploaded": "Noch kein Video hochgeladen",
            "videoPanelView.play": "Abspielen",
            "videoPanelView.upload": "Hochladen",
            "videoPanelView.newVersion": "Neue Version",
            "videoPanelView.deleteVideo": "Video löschen",

            // VideoPlayerSheet.swift
            "videoPlayerSheet.noComments": "Noch keine Kommentare.",
            "videoPlayerSheet.yourName": "Dein Name",
            "videoPlayerSheet.commentPlaceholder": "Kommentar…",

            // NotificationsSheet.swift
            "notificationsSheet.empty": "Keine neuen Benachrichtigungen",
            "notificationsSheet.title": "Benachrichtigungen",
            "notificationsSheet.doneButton": "Fertig",
            "notificationsSheet.markAllRead": "Alle gelesen",

            // NotionImportSheet.swift
            "notionImportSheet.title": "Notion-Import",
            "notionImportSheet.doneButton": "Fertig",
            "notionImportSheet.cancelButton": "Abbrechen",
            "notionImportSheet.importButton": "Importieren",
            "notionImportSheet.importedTitleTemplate": "{count} {noun} importiert",
            "notionImportSheet.sceneSingular": "Szene",
            "notionImportSheet.scenePlural": "Szenen",
            "notionImportSheet.importedDescription": "Von Notion übernommen.",
            "notionImportSheet.connectIntro": "Verbinde deinen Notion-Workspace einmalig — danach kannst du aus jedem Projekt heraus importieren.",
            "notionImportSheet.howToTitle": "So geht's",
            "notionImportSheet.step1": "notion.so/my-integrations → \"+ New integration\" → benennen, Submit",
            "notionImportSheet.step2": "Das \"Internal Integration Secret\" kopieren",
            "notionImportSheet.step3": "In der Notion-Datenbank: „...“-Menü → Connections → Integration hinzufügen",
            "notionImportSheet.integrationSecretLabel": "Integration Secret",
            "notionImportSheet.secretPlaceholder": "secret_… oder ntn_…",
            "notionImportSheet.connectButton": "Verbinden",
            "notionImportSheet.noDatabasesFound": "Keine Datenbank gefunden — hast du sie in Notion über \"Connections\" mit der Integration geteilt?",
            "notionImportSheet.chooseDatabaseLabel": "Datenbank auswählen",
        ],
        "en": [
            // IdeaGridView.swift
            "ideaGrid.heading": "💡 Ideas",
            "ideaGrid.emptyState": "No ideas yet — create the first idea for this project before moving into scripting.",
            "ideaGrid.groupIdea": "Idea",
            "ideaGrid.groupFeedback1": "1st feedback",
            "ideaGrid.groupFeedback2": "2nd feedback",
            "ideaGrid.groupApproved": "✓ Approved",
            "ideaGrid.newIdeaTitle": "New idea",
            "ideaTile.approvedOn": "Approved on {date}",

            // IdeaEditSheet.swift
            "ideaEditSheet.imagesSectionTitle": "Images ({count}/10)",
            "ideaEditSheet.addImageButton": "Add image",
            "ideaEditSheet.uploadingImage": "Uploading…",
            "ideaEditSheet.generatePopupTitle": "Generate AI image",
            "ideaEditSheet.titleSectionLabel": "Title",
            "ideaEditSheet.descriptionSectionLabel": "Description",
            "ideaEditSheet.slashHint": "Type “/” for a scene/intermediate step (or for title/dialogue inside a scene). Press Enter twice to close the block.",
            "ideaEditSheet.feedbackSectionLabel": "Feedback",
            "ideaEditSheet.noFeedbackYet": "No feedback yet",
            "ideaEditSheet.feedbackCountLabel": "{count} Feedback{suffix}",
            "ideaEditSheet.approvedBadge": "Approved",
            "ideaEditSheet.approvedOnLabel": "Approved on",
            "ideaEditSheet.approving": "Approving…",
            "ideaEditSheet.approveButton": "Approve",
            "ideaEditSheet.deleteIdeaButton": "Delete idea",
            "ideaEditSheet.navTitleFallback": "Idea",
            "ideaEditSheet.doneButton": "Done",
            "ideaEditSheet.insertDialogTitle": "Insert",
            "ideaEditSheet.cancelButton": "Cancel",
            "ideaEditSheet.noCreditsTitle": "No credits left",
            "ideaEditSheet.later": "Later",
            "ideaEditSheet.buyCredits": "Buy credits",
            "ideaEditSheet.noCreditsMessage": "You have no AI credits left to generate an image. Top up credits via the website.",
            "ideaEditSheet.imagePromptSectionLabel": "Image prompt",
            "ideaEditSheet.imagePromptPlaceholder": "Describe the image...",
            "ideaEditSheet.imagePromptHint": "Leave empty to use the idea's own description.",
            "ideaEditSheet.formatLabel": "Format",
            "ideaEditSheet.styleLabel": "Style",
            "ideaEditSheet.styleRealistic": "Realistic",
            "ideaEditSheet.styleSketch": "Sketch",
            "ideaEditSheet.generatingLabel": "Generating…",
            "ideaEditSheet.generateImageButton": "Generate image",

            // IdeaFeedbackSheet.swift
            "ideaFeedbackSheet.emptyState": "No feedback yet",
            "ideaFeedbackSheet.feedbackWord": "Feedback",
            "ideaFeedbackSheet.openCount": "{count} open",
            "ideaFeedbackSheet.navTitle": "Feedback on “{title}”",
            "ideaFeedbackSheet.doneButton": "Done",

            // IdeaMediaSourceButton.swift
            "ideaMediaSourceButton.dialogTitle": "Add photo or video",
            "ideaMediaSourceButton.takePhoto": "Take photo",
            "ideaMediaSourceButton.chooseFromLibrary": "Choose from library",
            "ideaMediaSourceButton.cancel": "Cancel",

            // Shared postproduction status labels — reused verbatim from
            // web's lib/i18n.tsx (VideoTile.tsx, projects/[id]/page.tsx).
            "postproductionStatus.wartend": "Waiting",
            "postproductionStatus.inBearbeitung": "In progress",
            "postproductionStatus.wartetAufFeedback": "Awaiting feedback",
            "postproductionStatus.abgeschlossen": "Completed",
            "postproductionStatus.abgelehnt": "Rejected",

            // PostproductionListView.swift
            "postproductionListView.navTitle": "Postproduction",
            "postproductionListView.doneButton": "Done",
            "postproductionListView.emptyTitle": "No sections yet",
            "postproductionListView.emptyDescription": "On the scene overview: press and hold a section → “Send to postproduction” once every scene is in the can — or upload an independent video directly using the button in the bottom right.",
            "postproductionListView.titleAlertTitle": "Title",
            "postproductionListView.cancelButton": "Cancel",
            "postproductionListView.saveButton": "Save",
            "postproductionListView.errorAlertTitle": "Error",
            "postproductionListView.videoLoadFailed": "Could not load video.",
            "postproductionListView.noUploadUrl": "Did not receive an upload URL.",
            "postproductionListView.statusLabel": "Status",
            "postproductionListView.deadlineLabel": "Deadline",
            "postproductionListView.dateLabel": "Date",
            "postproductionListView.deadlineWithValue": "Deadline: {date}",
            "postproductionListView.noVideoYet": "No video yet",
            "postproductionListView.uploadVideo": "Upload video",
            "postproductionListView.processing": "Processing…",

            // VideoPanelView.swift (superseded by PostproductionListView's
            // grid, see that file's own top-of-file doc comment — kept
            // translated anyway since the source file itself still ships).
            "videoPanelView.video": "Video",
            "videoPanelView.anotherVideo": "another video",
            "videoPanelView.noVideosYet": "No videos yet.",
            "videoPanelView.videoLoadFailed": "Could not load video.",
            "videoPanelView.noUploadUrl": "Did not receive an upload URL.",
            "videoPanelView.versionCommentsLabel": "Version {number} · {count} comments",
            "videoPanelView.noVideoUploaded": "No video uploaded yet",
            "videoPanelView.play": "Play",
            "videoPanelView.upload": "Upload",
            "videoPanelView.newVersion": "New version",
            "videoPanelView.deleteVideo": "Delete video",

            // VideoPlayerSheet.swift
            "videoPlayerSheet.noComments": "No comments yet.",
            "videoPlayerSheet.yourName": "Your name",
            "videoPlayerSheet.commentPlaceholder": "Comment…",

            // NotificationsSheet.swift
            "notificationsSheet.empty": "No new notifications",
            "notificationsSheet.title": "Notifications",
            "notificationsSheet.doneButton": "Done",
            "notificationsSheet.markAllRead": "Mark all read",

            // NotionImportSheet.swift
            "notionImportSheet.title": "Notion import",
            "notionImportSheet.doneButton": "Done",
            "notionImportSheet.cancelButton": "Cancel",
            "notionImportSheet.importButton": "Import",
            "notionImportSheet.importedTitleTemplate": "{count} {noun} imported",
            "notionImportSheet.sceneSingular": "scene",
            "notionImportSheet.scenePlural": "scenes",
            "notionImportSheet.importedDescription": "Imported from Notion.",
            "notionImportSheet.connectIntro": "Connect your Notion workspace once — after that you can import from any project.",
            "notionImportSheet.howToTitle": "How it works",
            "notionImportSheet.step1": "notion.so/my-integrations → \"+ New integration\" → name it, Submit",
            "notionImportSheet.step2": "Copy the \"Internal Integration Secret\"",
            "notionImportSheet.step3": "In the Notion database: “…” menu → Connections → add the integration",
            "notionImportSheet.integrationSecretLabel": "Integration secret",
            "notionImportSheet.secretPlaceholder": "secret_… or ntn_…",
            "notionImportSheet.connectButton": "Connect",
            "notionImportSheet.noDatabasesFound": "No database found — have you shared it with the integration in Notion via \"Connections\"?",
            "notionImportSheet.chooseDatabaseLabel": "Choose a database",
        ],
    ]
}
