def antwort_urteil(befund: dict) -> dict:
    # R1: Zugriff auf die vier Schlüssel über befund["..."]
    fehler = befund["fehler"]
    http_status = befund["http_status"]
    zeilen = befund["zeilen"]
    erwartet_mindestens = befund["erwartet_mindestens"]

    # R3, Stufe 1: Fehlertext vorhanden?
    if isinstance(fehler, str) and len(fehler) >= 1:
        return {
            "ergebnis": "nicht_gemessen",
            "grund": f"Nicht gemessen wegen Fehler: {fehler}."
        }

    # R3, Stufe 2: HTTP-Status ist nicht 200?
    if http_status != 200:
        return {
            "ergebnis": "nicht_gemessen",
            "grund": f"Nicht gemessen wegen HTTP-Status {http_status}."
        }

    # R3, Stufe 3: Zeilenwert brauchbar? (int >=0 und kein bool)
    if not (isinstance(zeilen, int) and not isinstance(zeilen, bool) and zeilen >= 0):
        return {
            "ergebnis": "nicht_gemessen",
            "grund": f"Nicht gemessen wegen unbrauchbarer Zeilenzahl {zeilen}."
        }

    # R3, Stufe 4: Keine Zeilen zurückgegeben?
    if zeilen == 0:
        return {
            "ergebnis": "leer_gemessen",
            "grund": "Leer gemessen: keine Zeilen zurückgegeben."
        }

    # R3, Stufe 5: Zu wenige Zeilen für ein Messergebnis?
    if zeilen < erwartet_mindestens:
        return {
            "ergebnis": "leer_gemessen",
            "grund": f"Leer gemessen: nur {zeilen} Zeilen, benötigt mindestens {erwartet_mindestens}."
        }

    # R3, Stufe 6: Ausreichend Zeilen für ein Messergebnis?
    if zeilen >= erwartet_mindestens:
        return {
            "ergebnis": "gemessen",
            "grund": f"Gemessen: {zeilen} Zeilen zurückgegeben."
        }

    # R4: Falls kein Befund durch alle Stufen, raise ValueError
    raise ValueError("Unvollständiger Befund: keine passende Stufe gefunden.")


# ------------------------------------------------------------------
# Kommentarblock zur Selbstprüfung:
#
# R1: Zugriff auf die vier Schlüssel über befund["..."] (Zeilen 5-8)
# R2: Befund nicht verändert – keine Zuweisungen an befund[...] (keine)
# R3: Stufen 1–6 in exakt dieser Reihenfolge, jede positive Bedingung
#     (Zeilen 10–38)
# R4: Raise ValueError wenn kein Befund durch alle sechs Stufen fällt
#     (Zeile 40)
# R5: Bool-Check für zeilen in Stufe 3 (Zeile 20)
# R6: Stufe 4 kommt vor Stufe 5, damit 0 Zeilen immer leer_gemessen ist
#     (Zeilen 24–28)
# R7: Keine Importe außer optionalen Typing‑Importen – hier keine nötig
