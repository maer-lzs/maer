def laender_urteil(gemessen: dict, referenz: dict, toleranz: float) -> list:
    # R7: early exit for empty input
    if not gemessen and not referenz:
        return []

    # R1: union of all country codes
    lands = set(gemessen.keys()) | set(referenz.keys())

    result = []
    for land in sorted(lands):  # R2: sort ascending by country code
        measured_val = gemessen.get(land, 0)
        ref_val = referenz.get(land)  # may be None

        # R5: compute relative deviation if reference exists and > 0
        if ref_val is None or ref_val == 0:
            deviation = None
        else:
            deviation = round(abs(measured_val - ref_val) / ref_val, 3)

        # R3: determine verdict according to the hierarchy
        if ref_val is None or ref_val == 0:          # Stage 1
            urteil = "ohne_referenz"
        elif measured_val == 0:                     # Stage 2
            urteil = "fehlt"
        else:
            if deviation is not None and deviation <= toleranz:   # Stage 3
                urteil = "passt"
            else:
                if measured_val < ref_val:          # Stage 4
                    urteil = "unter_erwartung"
                elif measured_val > ref_val:       # Stage 5
                    urteil = "ueber_erwartung"
                else:
                    raise ValueError(f"No verdict for land {land}")  # R4

        result.append({
            "land": land,
            "gemessen": measured_val,
            "referenz": ref_val,
            "urteil": urteil,
            "abweichung": deviation
        })

    return result


# R1: lands = set(gemessen.keys()) | set(referenz.keys())
# R2: for land in sorted(lands):
# R3: verdict determination logic with stages 1-5
# R4: raise ValueError if no verdict (unreachable)
# R5: deviation calculation and rounding
# R6: No modifications to gemessen or referenz
# R7: early return when both dicts empty
# R8: only standard library used
