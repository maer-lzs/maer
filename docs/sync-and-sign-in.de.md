# Mär: Abgleich und Anmeldung

Zurück zur [README](../README.de.md) · [English](sync-and-sign-in.md)

## Die Sync-Kernregel

Das ist das Herz der App. Eine Sprung-Aktion der Person (Schieber, Kapitelsprung, Sprungknöpfe oder Sperrbildschirm) gilt als gewollt und wird sofort abgeglichen, auch rückwärts. Ein Warndialog erscheint nur, wenn der Fortschritt **ohne Aktion der Person** um mehr als 120 Sekunden fällt, etwa durch einen fehlerhaften Client-Reset. Bricht die Person ab, springt die Wiedergabe auf die zuletzt gespeicherte Position zurück. Der Sperrbildschirm hat keine Handballen-Erkennung, also wird eine Serie von mehr als fünf Sprüngen in vier Sekunden dort nicht weiter ausgeführt: die App fragt einmal, ob die ganze Serie gewollt war.

Beim Gerätewechsel fragt die App vor jedem Wiedergabestart den Server und wartet bis zu 1,5 Sekunden auf seine Antwort; ein Server, der nicht rechtzeitig antwortet, hält den Player nicht fest, und der Start geht von der Position auf dem Gerät weiter. Der Eintrag mit dem neueren Zeitstempel gewinnt: hat ein anderes Gerät zuletzt geschrieben, wird seine Position übernommen, auch wenn sie **weiter vorne** liegt (z. B. nach gewolltem Zurückspulen dort). Bei älteren Servern ohne Zeitstempel wird nur eine weiter fortgeschrittene Server-Position übernommen. Echtes gleichzeitiges Hören auf zwei Geräten ist nicht abgedeckt; dann gewinnt, wer zuletzt schreibt.

Jede Fortschritts-Meldung sendet die aktuelle Zeit und den Gehört-Status zusammen, dazu Dauer und Fortschritt, wann immer die Dauer bekannt ist, statt einer Teil-Aktualisierung; eine Teil-Aktualisierung lässt den Server raten, was er mit den Feldern tun soll, die er nicht bekam, und das hat früher echten Fortschritt gekostet, als nur der Gehört-Status umgeschaltet wurde. Ohne bekannte Dauer (ein Mehrdatei-Buch, für das der Server keine nannte) lässt die App Dauer und Fortschritt weg, weil ein Fortschritt von 0 den des Servers überschreiben würde.

## Anmelde-Optionen

Die App meldet sich entweder mit deinem Audiobookshelf-**Benutzernamen und Passwort** an (die Vorgabe: sie tauscht sie über `/login` gegen einen Token und speichert nur den Token im Schlüsselbund) oder direkt mit einem **API-Token**. Die Anmeldung mit Passwort bittet den Server um seine Token in der Antwort und läuft in einer eigenen Sitzung, so bleibt kein Cookie der Anmeldung in der App.

Bietet der Server eine **Einmalanmeldung** an (OpenID Connect, in Audiobookshelf eingerichtet), zeigt das Anmeldeformular unter „Verbinden“ einen Knopf dafür. Er öffnet die Seite deines Anbieters im Anmeldefenster des Systems und kehrt mit dem Token des Servers zu Mär zurück; der Server muss die Rückkehradresse `audiobookshelf://oauth` zulassen, was Audiobookshelf von sich aus tut.

Hinweis für Server mit der neuen JWT-Anmeldung (v2.26.0+): die Passwort-Anmeldung bekommt dort einen kurzlebigen Zugangs-Token, also kann die Sitzung ablaufen. Die App behält den Token, zeigt den Zustand an der Audiobookshelf-Quelle und prüft selbst erneut; erst wenn der Server ihn weiter ablehnt, bietet die App eine neue Anmeldung an, vorausgefüllt, und löscht von sich aus nichts. Auf solchen Servern ist ein API-Schlüssel die dauerhaftere Wahl.

So findest du deinen Token:

- **Ältere Server-Versionen:** Weboberfläche → Einstellungen → Benutzer → dein Konto wählen → der Token wird angezeigt.
- **Neuere Server-Versionen:** Weboberfläche → Einstellungen → API-Schlüssel → einen neuen Schlüssel anlegen.

Wenn du nicht weißt, welche Variante dein Server nutzt, probiere beide. Einer dieser Wege existiert.
