# Subshot iOS — Setup-Anleitung

Dieser Ordner enthält nur die Swift-Quelldateien (keine `.xcodeproj`, da die auf
Linux nicht zuverlässig von Hand erzeugt werden kann — Xcode-Projektdateien
sind ein komplexes Binärformat, das normalerweise nur Xcode selbst schreibt).
Du erstellst das eigentliche Xcode-Projekt einmalig selbst und ziehst die
Dateien rein — danach ist alles normale Xcode-Arbeit.

## Einmaliges Setup

1. **Xcode-Projekt anlegen:** File → New → Project → iOS → App.
   - Product Name: `Subshot`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Minimum Deployment: **iOS 17.0** (wegen `@Observable`/neuer Navigation-APIs)

2. **Alle Dateien aus `Subshot/` reinziehen:** Im Finder den Inhalt dieses
   `Subshot/`-Ordners (Models/, Services/, ViewModels/, Views/, `SubshotApp.swift`)
   per Drag & Drop in dein Xcode-Projekt ziehen. Xcode fragt nach dem
   Ziel-Target — `Subshot` ankreuzen. Die von Xcode automatisch erzeugte
   `ContentView.swift`/leere `SubshotApp.swift` kannst du löschen (wird durch
   die mitgelieferte `SubshotApp.swift` ersetzt).

3. **Clerk SDK hinzufügen:** File → Add Package Dependencies... →
   `https://github.com/clerk/clerk-ios` → beide Produkte **ClerkKit** und
   **ClerkKitUI** zum Target hinzufügen.

4. **Bauen & testen:** Cmd+R im Simulator. Login-Screen sollte erscheinen,
   "Anmelden" öffnet Clerks Auth-Sheet (Google + E-Mail, wie schon auf der
   Web-Testseite gesehen).

## Bekannte offene Punkte (bewusst noch nicht gebaut)

- **PDF-Export** (ExportView aus der ursprünglichen Spec) — Backend-Endpunkt
  `GET /projects/:id/export/pdf` existiert noch nicht.
- **Szenen umbenennen/Farbe ändern** über die UI — Backend-Endpunkt existiert
  (`PATCH /scenes/:id`), nur noch keine UI dafür gebaut.
- **Drag & Drop zum Umsortieren** von Shots/Szenen — `sort_order` existiert im
  Datenmodell, aber noch keine Reorder-Geste in `ShotListView`.
- **E-Mail-Versand** für Einladungen und 30-Tage-Löschwarnung — Backend loggt
  aktuell nur, verschickt nichts wirklich (kein E-Mail-Anbieter angebunden).
- **Push-Benachrichtigungen** — nicht Teil dieses MVP.

## API-Basis-URL

`APIClient.swift` zeigt aktuell auf `https://dev.subli.ch/subshot-test` — das
ist die **temporäre** Test-Domain, die nur zur Backend-Validierung diente.
Vor echtem Einsatz auf eine richtige Subshot-Domain umstellen (siehe Projekt-
Spec §1: subshot.app / subshot.ch).

## Nicht getestet von mir

Ich konnte diesen Code nicht selbst kompilieren oder in einem Simulator
starten (kein Xcode/Swift-Toolchain auf diesem Linux-Server) — nur sorgfältig
gegengelesen. Erwarte beim ersten Build ein paar kleine Fehler (Tippfehler,
API-Namen), die in Xcode selbst schnell zu finden und zu fixen sind. Schick
mir Fehlermeldungen, ich korrigiere den Code entsprechend.
