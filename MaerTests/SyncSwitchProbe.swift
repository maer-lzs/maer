// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
@testable import Maer

/// Der Schalter, unter dem die Traeger ueberhaupt reden, als ZUSICHERUNG
/// statt als Hoffnung.
///
/// Vier Zeugen begannen mit `guard AppStorageKeys.syncAcrossDevicesEnabled
/// else { return }`. Das ist kein Ueberspringen: steht die Vorgabe auf aus,
/// meldet der Fall BESTANDEN und hat nichts gemessen, und ein gruener Lauf
/// ohne Messung ist der teuerste Ausgang.
///
/// Die Vorgabe ist prozessweit, und zwei Nachbarsuiten setzen genau sie auf
/// aus. Sie legen sie zurueck, aber einmal ohne `defer`: reisst der Fall
/// dazwischen, bleibt der Schalter unten, und jeder spaetere Zeuge mit dem
/// Wachposten oben besteht ab da, ohne zu messen. Keine dieser Suiten ist
/// `.serialized`, also steht die Reihenfolge nirgends fest.
///
/// Deshalb wird der Schalter hier GESETZT und danach genau so
/// wiederhergestellt, wie er war, statt gelesen zu werden.
@MainActor
enum SyncSwitchProbe {
    /// Legt den Schalter um und gibt zurueck, wie er zurueckgelegt wird.
    ///
    /// Die Rueckgabe statt eines Blocks um den ganzen Fall ist Absicht: sie
    /// kostet die Zeugen zwei Zeilen statt einer Einrueckung, und ein
    /// `defer` daneben liest sich wie jede andere Aufraeumzeile im Fall.
    static func armOn() -> @MainActor () -> Void {
        let key = AppStorageKeys.podcastICloudSync
        let was = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        return {
            if let was { UserDefaults.standard.set(was, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
#endif
