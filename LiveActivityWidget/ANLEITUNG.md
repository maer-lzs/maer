# Live-Activity-Widget

Das Widget-Extension-Target (`MaerWidgetsExtension`) ist **bereits im
Xcode-Projekt enthalten** — beim Klonen ist nichts weiter einzurichten.
`MaerLiveActivity.swift` gehört nur zum Widget-Target,
`Sources/Models/PlaybackActivityAttributes.swift` gehört App UND Widget
(gemeinsamer Vertrag).

Einziger Handgriff nach einem Fork: dem Widget-Target unter Signing eine
eigene Bundle-ID als Kind der App-ID geben (z. B. `de.deinname.maer.widgets`).

Die Live Activity erscheint NUR während eines laufenden Schlaf-Timers
(Mond + Countdown) — die normale Wiedergabe zeigt Apples eigenes
„Now Playing" auf dem Sperrbildschirm, das nicht gedoppelt wird.
