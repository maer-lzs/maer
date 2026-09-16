// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// Ob die Quellen dieser Kopie ueberhaupt danebenliegen, und was daraus
/// folgt.
///
/// Die Quelltext-Zaeune lesen das Repo ueber `#filePath`. Laeuft die Suite
/// dort, wo das Repo nicht liegt, ist das eine ehrliche Enthaltung. Bisher
/// stand dafuer ein Wachposten am Anfang des Falls, und der meldete
/// BESTANDEN: *„sources unreadable, no verdict"*, und daneben ein gruenes
/// Haekchen. Ein Zaun, der seine Quellen nicht findet, sagt damit „in
/// Ordnung" genau dann, wenn er nichts weiss.
///
/// **Die zwei Faelle werden hier getrennt, und nur so wird es ehrlich:**
///
/// - **Die Quellen fehlen** ist eine Enthaltung. Das entscheidet eine
///   Bedingung VOR dem Lauf, der Fall erscheint als uebersprungen und nicht
///   als bestanden.
/// - **Die Quellen sind da und der Zaun hat trotzdem nichts gelesen** ist
///   ein BEFUND. Dann hat er seine einzige Aufgabe verfehlt, und das gehoert
///   rot.
///
/// Dieselbe Trennung wie auf der Dienst-Seite bei der Ignorier-Datei: fehlt
/// sie im Abbild, ist das in Ordnung; fehlt sie in einer Arbeitskopie, ist
/// es ein Befund. Die Frage „welcher der beiden Faelle ist es" wird gestellt,
/// statt beide gleich zu behandeln.
nonisolated enum SourceTree {
    /// Die Wurzel des Repos, aus der Lage DIESER Datei abgeleitet.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Ob der Quellordner dieser Kopie beiliegt.
    static var hasSources: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path)
    }

    /// Ob die Projektdatei dieser Kopie beiliegt. Eigene Frage, weil ein
    /// Lauf ohne Projektdatei die Quellen trotzdem haben kann.
    static var hasProjectFile: Bool {
        FileManager.default.fileExists(atPath:
            root.appendingPathComponent("Maer.xcodeproj/project.pbxproj").path)
    }

    /// Ob der Testordner dieser Kopie beiliegt. Der Zaun ueber den Zaeunen
    /// liest ihn, und er darf aus demselben Grund nicht still bestehen.
    static var hasTests: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("MaerTests").path)
    }
}

extension Trait where Self == ConditionTrait {
    /// Der Fall liest den Quellbaum. Liegt er nicht bei, wird der Fall
    /// UEBERSPRUNGEN und nicht bestanden.
    static var needsTheSources: Self {
        .enabled(if: SourceTree.hasSources, "die Quellen liegen dieser Kopie nicht bei")
    }

    /// Der Fall liest die Projektdatei. Dasselbe eine Ebene daneben.
    static var needsTheProjectFile: Self {
        .enabled(if: SourceTree.hasProjectFile, "die Projektdatei liegt dieser Kopie nicht bei")
    }

    /// Der Fall liest den Testordner.
    static var needsTheTests: Self {
        .enabled(if: SourceTree.hasTests, "der Testordner liegt dieser Kopie nicht bei")
    }
}
#endif
