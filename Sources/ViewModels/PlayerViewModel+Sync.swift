import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

/// Sync-Politik: periodischer Sync, Reentrancy-Guard, Konflikt-Erkennung,
/// Geräte-Abgleich, Offline-Queue-Anbindung und Gehört-Status.
extension PlayerViewModel {

    // MARK: - Sync (die eigentliche Existenzberechtigung der App)

    func startSyncTimer() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await self.syncProgress(force: false)
            }
        }
    }

    /// Schreibt den Fortschritt an den Server. Reentrancy-sicher: Es ist nie
    /// mehr als ein Write gleichzeitig unterwegs — parallele Writes könnten
    /// sich im Netz überholen und der ältere Stand würde gewinnen.
    /// - Parameter force: erzwingt einen Sync auch ohne die 5-Sekunden-Schwelle
    ///   (z. B. bei Pause oder wenn die App in den Hintergrund geht).
    func syncProgress(force: Bool) async {
        if syncInFlight {
            // Timer-Ticks verwerfen (der nächste kommt eh); bewusste Syncs
            // (Pause/Seek) nach Abschluss einmal mit frischem Stand nachziehen.
            if force { syncFollowUpRequested = true }
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }

        var runForce = force
        repeat {
            syncFollowUpRequested = false
            await performSync(force: runForce)
            runForce = true
        } while syncFollowUpRequested
    }

    private func performSync(force: Bool) async {
        guard let item else { return }
        guard force || abs(currentTime - lastSyncedTime) >= 5 else { return }

        // Kernregel: Ein Rückschritt, den der Nutzer NICHT selbst ausgelöst hat,
        // wird nie stillschweigend geschrieben.
        if !suppressConflictForNextSync,
           SyncRules.isSuspiciousDrop(
               currentTime: currentTime,
               lastSyncedTime: lastSyncedTime,
               threshold: suspiciousDropThreshold
           ) {
            if pendingServerConflict == nil {
                pendingServerConflict = ServerConflict(serverTime: lastSyncedTime, localTime: currentTime)
                showSourceHint(.conflict)
            }
            return
        }

        let isFinishedNow = duration > 0 && currentTime >= duration - 1
        do {
            try await apiClient.updateProgress(
                itemId: item.id,
                currentTime: currentTime,
                duration: duration,
                isFinished: isFinishedNow
            )
            lastSyncedTime = currentTime
            suppressConflictForNextSync = false
            SyncQueue.shared.remove(itemId: item.id)
            // Server hat den Stand — lokale Crash-Sicherung ist damit erledigt.
            if let key = localPositionKey {
                UserDefaults.standard.removeObject(forKey: key)
            }
            // Nur Übergänge melden (kein 30s-Spam): offline/queued/failed → gesichert.
            if syncStatus != .synced {
                showSourceHint(.saved)
            }
            syncStatus = .synced
        } catch {
            if NetworkStatus.isOfflineError(error) {
                // Erwartbar, kein echter Fehler: kein Netz gerade, z. B. auf
                // Reisen. Den aktuellen Stand in die Offline-Queue legen,
                // damit er auch einen App-Kill übersteht, statt verloren zu
                // gehen — beim nächsten Start bzw. bei Wiederverbindung wird
                // sie automatisch geleert (siehe SyncQueue).
                SyncQueue.shared.enqueue(
                    itemId: item.id,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinishedNow
                )
                errorMessage = nil
                if syncStatus != .queued { showSourceHint(.queued) }
                syncStatus = .queued
            } else {
                // Ein echter Fehler (z. B. abgelaufener Token, Serverproblem) —
                // sichtbar machen, aber den Stand trotzdem queuen: sonst wäre
                // er verloren, wenn die App vor dem nächsten Versuch beendet
                // wird. Der Flush reconciled ohnehin gegen den Server.
                SyncQueue.shared.enqueue(
                    itemId: item.id,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinishedNow
                )
                errorMessage = String(localized: "Sync failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                syncStatus = .failed
            }
        }
    }

    /// Verbindung ging verloren, während gerade abgespielt wird: den sichtbaren
    /// Sync-Status sofort auf "offline" setzen, statt bis zum nächsten
    /// Sync-Tick (alle 30s) zu warten. Es wird bewusst NICHTS in die Queue
    /// gelegt — das geschieht weiterhin nur, wenn ein echter
    /// syncProgress-Versuch fehlschlägt.
    func markConnectionLostWhilePlaying() {
        guard isPlaying, syncStatus == .synced else { return }
        syncStatus = .offline
        showSourceHint(.offline)
    }

    /// Nach einem Flush der Offline-Queue aufrufen: Wurde der eigene Eintrag
    /// erfolgreich nachgereicht, den sichtbaren Status von .queued auf .synced
    /// nachziehen — sonst bliebe der "wird nachgereicht"-Hinweis bis zum
    /// nächsten Sync-Tick stehen, obwohl längst synchronisiert.
    func updateSyncStatusFromQueue() async {
        guard let item, syncStatus != .synced else { return }
        if !SyncQueue.shared.hasPendingUpdate(itemId: item.id) {
            if syncStatus == .queued || syncStatus == .failed { showSourceHint(.saved) }
            syncStatus = .synced
            // Server-Zeitstempel des EIGENEN nachgereichten Writes übernehmen,
            // ohne die Position zu adoptieren — sonst hält der nächste Abgleich
            // unseren (älteren) Flush-Stand für ein fremdes Gerät und springt
            // zurück.
            if let fresh = try? await apiClient.fetchItemDetail(itemId: item.id),
               let ms = fresh.userMediaProgress?.lastUpdate {
                lastKnownServerUpdate = max(lastKnownServerUpdate, ms)
            }
        }
    }

    /// Nutzer hat im Dialog bestätigt: den niedrigeren Stand wirklich schreiben.
    func confirmLowerProgress() async {
        suppressConflictForNextSync = true
        pendingServerConflict = nil
        await syncProgress(force: true)
    }

    /// Nutzer hat abgebrochen: zurück zum zuletzt gespeicherten Serverstand
    /// springen, damit der Konflikt aufgelöst ist und nicht erneut aufpoppt.
    func cancelAndRestoreServerPosition() {
        pendingServerConflict = nil
        Task { await seek(to: lastSyncedTime, userInitiated: false) }
    }

    func dismissLowerProgressConflict() {
        pendingServerConflict = nil
    }

    /// Nutzer hat im Dialog bestätigt: die Sprung-Serie war wirklich gewollt,
    /// aktuellen (weiter vorne liegenden) Stand sofort synchronisieren.
    func confirmLockscreenJump() async {
        suspiciousLockscreenJump = nil
        suppressConflictForNextSync = true
        await syncProgress(force: true)
    }

    /// Nutzer hat abgebrochen: zurück zum Stand vor Beginn der Sprung-Serie
    /// springen — vermutlich Taschen-Kontakt, nicht gewollt.
    func cancelLockscreenJump() {
        guard let jump = suspiciousLockscreenJump else { return }
        suspiciousLockscreenJump = nil
        Task { await seek(to: jump.beforeTime, userInitiated: false) }
    }

    func dismissLockscreenJump() {
        suspiciousLockscreenJump = nil
    }


    /// Setzt das Buch serverseitig auf "abgeschlossen" bzw. hebt das wieder auf.
    func toggleFinished() async {
        guard let item else { return }
        // Denselben In-Flight-Guard respektieren wie syncProgress — sonst kann
        // dieser Write einen laufenden Positions-Write im Netz überholen.
        while syncInFlight {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        syncInFlight = true
        defer { syncInFlight = false }

        let target = !isFinished
        // Gehört markieren setzt den Fortschritt explizit ans Buchende;
        // Rückgängig behält den aktuellen Stand und kippt nur das Flag.
        let writeTime = target ? duration : currentTime
        do {
            try await apiClient.updateProgress(
                itemId: item.id,
                currentTime: writeTime,
                duration: duration,
                isFinished: target
            )
            SyncQueue.shared.remove(itemId: item.id)
        } catch {
            // Nutzer-Statusentscheidung nicht verlieren: queuen, lokal
            // trotzdem übernehmen — der Flush reicht sie nach.
            SyncQueue.shared.enqueue(
                itemId: item.id,
                currentTime: writeTime,
                duration: duration,
                isFinished: target
            )
            if NetworkStatus.isOfflineError(error) {
                if syncStatus != .queued { showSourceHint(.queued) }
                syncStatus = .queued
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                syncStatus = .failed
            }
        }
        isFinished = target
        if target {
            // Lokalen Zustand angleichen: ans Buchende springen und Sync-Stand
            // nachziehen — sonst schriebe der periodische Sync gleich wieder
            // den alten Stand mit isFinished=false.
            await seek(to: duration, userInitiated: false)
            lastSyncedTime = duration
        } else {
            lastSyncedTime = currentTime
        }
    }


    /// Wird aufgerufen, wenn die App wieder in den Vordergrund kommt. Deckt den
    /// Fall ab, dass zwischenzeitlich auf einem anderen Gerät weitergehört
    /// wurde, während diese App-Instanz nur im Hintergrund lag (nicht beendet).
    /// Übernimmt den Serverstand NUR, wenn er weiter ist als die lokale
    /// Position — nie umgekehrt, das würde eigenen Fortschritt verwerfen.
    func reconcileWithServer() async {
        guard let item else { return }
        do {
            let fresh = try await apiClient.fetchItemDetail(itemId: item.id)
            let serverTime = fresh.userMediaProgress?.currentTime ?? 0
            let serverUpdate = fresh.userMediaProgress?.lastUpdate ?? 0
            // Neuerer Server-Eintrag als der zuletzt gesehene + abweichende
            // Position → anderes Gerät hat geschrieben. Übernehmen — auch
            // RÜCKWÄRTS (bewusstes Zurückspulen dort ist gewollt). Nach
            // eigenem Write ist serverTime ≈ currentTime → kein Sprung.
            // Fallback ohne lastUpdate (alte Server): nur vorwärts wie bisher.
            let isNewer = serverUpdate > lastKnownServerUpdate
            let adopt = SyncRules.shouldAdoptServerState(
                serverTime: serverTime,
                serverUpdateMs: serverUpdate,
                lastKnownServerUpdateMs: lastKnownServerUpdate,
                currentTime: currentTime
            )
            if adopt {
                await seek(to: serverTime, userInitiated: false)
                lastSyncedTime = serverTime
                showSourceHint(.serverAdopted)
            }
            // Auch das Abschluss-Flag vom neueren Eintrag übernehmen — z. B.
            // auf einem anderen Gerät als (un)gehört markiert.
            if isNewer, let serverFinished = fresh.userMediaProgress?.isFinished,
               serverFinished != isFinished {
                isFinished = serverFinished
            }
            lastKnownServerUpdate = max(lastKnownServerUpdate, serverUpdate)
            syncStatus = .synced
        } catch {
            // Kein Netz o.ä.: einfach mit dem lokalen Stand weitermachen,
            // kein Abbruch der Wiedergabe wegen eines Abgleich-Fehlers.
        }
    }
}
