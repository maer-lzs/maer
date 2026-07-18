# Widget-Extension

Das Widget-Extension-Target (`MaerWidgetsExtension`) ist **bereits im
Xcode-Projekt enthalten** — beim Klonen ist nichts weiter einzurichten.
Die Swift-Dateien in diesem Ordner gehören nur zum Widget-Target,
`Sources/Models/WidgetShared.swift` gehört App UND Widget
(gemeinsamer Vertrag: Snapshot + Cover im App-Group-Container).

Einziger Handgriff nach einem Fork: dem Widget-Target unter Signing eine
eigene Bundle-ID als Kind der App-ID geben (z. B. `de.deinname.maer.widgets`).
