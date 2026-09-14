"""Rebuilds the file icons' data (WhiskrKit/Sources/WhiskrKit/FileIcons) from VS Code's Seti file icon theme.

Run from native/App:  python3 -I Scripts/update-file-icons.py

It downloads, from VS Code's repository at the commit pinned below, the Seti theme's mapping
(`vs-seti-icon-theme.json`), its font (`seti.woff`, kept byte for byte) and the licence texts, and writes:

- `seti.woff`: the glyphs.
- `seti.json`: the mapping, minified. Each icon is named once ("swift", "c") with its character; file names,
  extensions and language ids name an icon. Seti's colours and its light variants are left out: Whiskr draws
  the glyphs in the theme's text colour, as colour in the chrome means state. Every light variant has the same
  glyph as its dark one (checked here), so nothing is lost.
- `ThirdParty/manifest.json` and the licence texts.

Uses only the standard library. The output is checked in; the app reads nothing from the network.
"""

import hashlib
import json
import pathlib
import re
import sys
import urllib.request

VSCODE_COMMIT = "08e8bbfca63e53b57005f10e97b0fa19f2cf81f1"
RAW = f"https://raw.githubusercontent.com/microsoft/vscode/{VSCODE_COMMIT}/"
SETI = "extensions/theme-seti/"
OUT = pathlib.Path(__file__).resolve().parent.parent / "WhiskrKit/Sources/WhiskrKit/FileIcons"


def fetch(path):
    with urllib.request.urlopen(RAW + path, timeout=60) as response:
        return response.read()


def icon_name(definition_id):
    """`_c_1_light` → `c`: Seti's definitions differ by colour only past the first part."""
    return re.sub(r"_\d+$", "", re.sub(r"_light$", "", definition_id)).lstrip("_")


def main():
    theme = json.loads(fetch(SETI + "icons/vs-seti-icon-theme.json"))
    font = fetch(SETI + "icons/seti.woff")
    notices = fetch(SETI + "ThirdPartyNotices.txt").decode()
    seti_upstream = json.loads(fetch(SETI + "cgmanifest.json"))["registrations"][0]["component"]["git"]
    vscode_licence = fetch("LICENSE.txt")

    definitions = theme["iconDefinitions"]
    icons = {}
    for definition_id, definition in definitions.items():
        name, character = icon_name(definition_id), definition["fontCharacter"].lstrip("\\").lower()
        if icons.setdefault(name, character) != character:
            sys.exit(f"{definition_id}: {name} has two glyphs")

    def section(source):
        mapping = {}
        for key, definition_id in source.items():
            if key != key.lower() or "/" in key:
                sys.exit(f"{key}: keys are expected lower case, without folders")
            mapping[key] = icon_name(definition_id)
        return dict(sorted(mapping.items()))

    data = {
        "file": icon_name(theme["file"]),
        "icons": dict(sorted(icons.items())),
        "fileNames": section(theme["fileNames"]),
        "fileExtensions": section(theme["fileExtensions"]),
        "languageIds": section(theme["languageIds"]),
    }
    light = theme.get("light", {})
    for key in ("fileNames", "fileExtensions", "languageIds"):
        if section(light.get(key, {})) != {k: v for k, v in data[key].items() if k in light.get(key, {})}:
            sys.exit(f"light {key} differs in shape from dark")

    # Seti UI's licence, as VS Code's notices quote it: from "Copyright" to the end of the MIT text.
    start = notices.index("Copyright (c) 2014 Jesse Weed")
    seti_licence = notices[start:].strip() + "\n"

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "ThirdParty").mkdir(exist_ok=True)
    (OUT / "seti.woff").write_bytes(font)
    (OUT / "seti.json").write_text(json.dumps(data, separators=(",", ":"), ensure_ascii=False) + "\n")
    (OUT / "ThirdParty/LICENSE-seti-ui.txt").write_text(seti_licence)
    (OUT / "ThirdParty/LICENSE-vscode.txt").write_bytes(vscode_licence)
    manifest = [
        {
            "name": "VS Code Seti file icon theme (vs-seti-icon-theme.json, seti.woff)",
            "source": f"https://github.com/microsoft/vscode/tree/{VSCODE_COMMIT}/extensions/theme-seti",
            "commit": VSCODE_COMMIT,
            "license": "MIT",
            "licenseFile": "LICENSE-vscode.txt",
            "files": ["seti.json", "seti.woff"],
            "sha256": {"seti.woff": hashlib.sha256(font).hexdigest()},
        },
        {
            "name": "Seti UI (the icons and their font, from which VS Code's theme is generated)",
            "source": seti_upstream["repositoryUrl"],
            "commit": seti_upstream["commitHash"],
            "license": "MIT",
            "licenseFile": "LICENSE-seti-ui.txt",
            "files": ["seti.woff"],
        },
    ]
    (OUT / "ThirdParty/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{len(icons)} icons, {len(data['fileNames'])} file names, {len(data['fileExtensions'])} extensions, "
          f"{len(data['languageIds'])} languages → {OUT}")


if __name__ == "__main__":
    main()
