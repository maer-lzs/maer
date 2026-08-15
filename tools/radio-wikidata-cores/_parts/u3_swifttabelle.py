def swift_tabelle(kerne: dict) -> str:
    # R5
    if not kerne:
        return ""

    result_lines = []

    for country in sorted(kerne):  # R1
        stations = kerne[country]
        # R3e
        if not stations:
            raise ValueError(f"Empty station list for country {country}")
        block_lines = []
        block_lines.append(' ' * 8 + f'"{country}": [')
        for name, qid in stations:  # R2 & R3a-d
            if name.strip() == "":
                raise ValueError(f"Empty station name in country {country}")
            if qid == "":
                raise ValueError(f"Empty QID for station {name} in country {country}")
            if not (qid[0] == "Q" and len(qid) > 1 and qid[1:].isdigit()):
                raise ValueError(f"Invalid QID '{qid}' for station {name} in country {country}")
            escaped_name = name.replace("\\", "\\\\")  # R2 step1
            escaped_name = escaped_name.replace('"', '\\"')  # R2 step2
            escaped_name = escaped_name.replace("\n", "\\n")  # R2 step3
            escaped_name = escaped_name.replace("\t", "\\t")  # R2 step4
            line = ' ' * 12 + f'"{escaped_name}",  // {qid}'
            block_lines.append(line)
        block_lines.append(' ' * 8 + "],")
        result_lines.extend(block_lines)

    return "\n".join(result_lines)  # no trailing newline

# R1: sorted(kerne) at line 8
# R2: escape steps start at line 22
# R3a: name.strip() check at line 16
# R3b: qid empty check at line 18
# R3c/d: qid format check at line 20
# R3e: stations list empty check at line 11
# R4: QID not modified (used unchanged at line 26)
# R5: return "" if kerne empty at line 3
# R6: no modification of kerne or its lists – see lines 1-31
# R7: no imports used
