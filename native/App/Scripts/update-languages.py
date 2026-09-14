#!/usr/bin/env python3
"""Rebuilds the bundled language data (WhiskrKit/Sources/WhiskrKit/Languages) from its sources.

    python3 -I Scripts/update-languages.py --vscode <clone of microsoft/vscode> --cache <download folder>

The pinned source list is update-languages.json beside this script. VS Code's built-in extensions are read from
the clone, which must be at the pinned commit (only its `extensions/` folder and root licence files are needed).
Grammars VS Code does not ship, and every licence text, are downloaded from GitHub at their pinned commits into
the cache folder (once; later runs reuse it). Nothing is downloaded from any extension marketplace.

What is written:
  index.json            languages and grammars as VS Code contributes them, in VS Code's registration order
  grammars/<scope>.json TextMate grammars, minified JSON (plist grammars converted)
  configurations/<id>.json  language configurations, comments removed, minified
  ThirdParty/manifest.json  where every file came from: repository, commit, licence, files, licence text
  ThirdParty/*.txt      the licence texts, read at the pinned commits
"""

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "WhiskrKit", "Sources", "WhiskrKit", "Languages")
RAW = "https://raw.githubusercontent.com"


def fail(message):
    sys.exit(f"update-languages: {message}")


def minified(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def strip_jsonc(text):
    """JSON with comments and trailing commas, as VS Code writes language configurations, as plain JSON."""
    out = []
    i, n = 0, len(text)
    pending_comma = None
    while i < n:
        c = text[i]
        if c == '"':
            pending_comma = None
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif c == ",":
            pending_comma = len(out)
            out.append(c)
            i += 1
        elif c in "}]":
            if pending_comma is not None:
                out[pending_comma] = ""
            pending_comma = None
            out.append(c)
            i += 1
        elif c in " \t\r\n":
            out.append(c)
            i += 1
        else:
            pending_comma = None
            out.append(c)
            i += 1
    return "".join(out)


def read_jsonc(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.loads(strip_jsonc(f.read()))


def read_grammar(path):
    if path.endswith(".json"):
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    with open(path, "rb") as f:
        return plistlib.load(f)


def fetch(cache, repository, commit, path, required=True):
    """A file of a GitHub repository at a commit, downloaded once into its own folder of the cache (None when it
    does not exist there and is not required)."""
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail(f"{repository}: pin a full commit hash, not {commit!r}")
    folder = os.path.join(cache, repository.replace("/", "--") + "--" + commit)
    target = os.path.join(folder, *path.split("/"))
    if not os.path.isfile(target):
        url = f"{RAW}/{repository}/{commit}/{urllib.parse.quote(path)}"
        os.makedirs(os.path.dirname(target), exist_ok=True)
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404 and not required:
                return None
            fail(f"could not download {url}: {error}")
        except Exception as error:
            fail(f"could not download {url}: {error}")
        with open(target, "wb") as f:
            f.write(data)
    return target


def license_section(text, heading):
    """The section of a Markdown README under `# <heading>`, up to the next heading of the same level."""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if re.fullmatch(r"#+\s*" + re.escape(heading) + r"\s*", line.strip()):
            level = len(line) - len(line.lstrip("#"))
            body = []
            for rest in lines[index + 1:]:
                match = re.match(r"(#+)\s", rest)
                if match and len(match.group(1)) <= level:
                    break
                body.append(rest)
            return "\n".join(body).strip() + "\n"
    fail(f"no '{heading}' section")


class Builder:
    def __init__(self, sources, vscode, cache):
        self.sources = sources
        self.vscode = vscode
        self.cache = cache
        self.languages = set(sources["languages"])
        self.grammar_scopes = set(sources["grammars"])
        # Contributions in VS Code's registration order: built-in extensions by folder name, then the others.
        self.language_entries = []
        self.grammar_entries = []
        # scope -> (source file, provenance); language id -> [configuration files]
        self.grammar_files = {}
        self.configurations = {}
        # (repository, commit) -> set of output paths
        self.groups = {}

    # Provenance

    def claim(self, repository, commit, path):
        self.groups.setdefault((repository, commit), set()).add(path)

    def grammar_provenance(self, grammar, extension, relative):
        override = self.sources["provenance"].get(f"{extension}/{relative}")
        if override:
            return override["repository"], override["commit"]
        version = grammar.get("version")
        if isinstance(version, str):
            match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/commit/([0-9a-f]{40})", version)
            if match:
                return match.group(1), match.group(2)
        # VS Code's own grammar (ignore files, JSDoc injections).
        return None

    # Reading

    def add_extension(self, folder, manifest, provenance):
        contributes = manifest.get("contributes", {})
        for language in contributes.get("languages", []):
            if language.get("id") not in self.languages:
                continue
            entry = {"id": language["id"]}
            for key in ("aliases", "extensions", "filenames", "filenamePatterns", "firstLine"):
                if key in language:
                    entry[key] = language[key]
            if language.get("configuration"):
                path = os.path.normpath(os.path.join(folder, language["configuration"]))
                self.configurations.setdefault(language["id"], []).append((path, provenance))
                entry["configuration"] = f"configurations/{language['id']}.json"
            self.language_entries.append(entry)
        for grammar in contributes.get("grammars", []):
            scope = grammar.get("scopeName")
            if scope not in self.grammar_scopes:
                continue
            entry = {"scopeName": scope, "file": f"grammars/{scope}.json"}
            for key in ("language", "embeddedLanguages", "injectTo", "tokenTypes", "balancedBracketScopes", "unbalancedBracketScopes"):
                if key in grammar and grammar[key]:
                    entry[key] = grammar[key]
            self.grammar_entries.append(entry)
            path = os.path.normpath(os.path.join(folder, grammar["path"]))
            self.grammar_files[scope] = (path, provenance, os.path.relpath(path, folder))

    def read_vscode(self):
        head = subprocess.run(["git", "-C", self.vscode, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        if head != self.sources["vscode"]["commit"]:
            fail(f"the VS Code clone is at {head or 'nothing'}, not the pinned {self.sources['vscode']['commit']}")
        root = os.path.join(self.vscode, "extensions")
        for name in sorted(os.listdir(root)):
            manifest_path = os.path.join(root, name, "package.json")
            if os.path.isfile(manifest_path):
                with open(manifest_path, encoding="utf-8") as f:
                    self.add_extension(os.path.join(root, name), json.load(f), ("vscode", name))

    def read_upstreams(self):
        for extension in self.sources["extensions"]:
            paths = [fetch(self.cache, extension["repository"], extension["commit"],
                           "/".join(p for p in (extension["folder"], file) if p)) for file in extension["files"]]
            folder = os.path.dirname(paths[0])
            with open(paths[0], encoding="utf-8") as f:
                manifest = json.load(f)
            self.add_extension(folder, manifest, ("upstream", extension))

    # Writing

    def write(self, out):
        if os.path.isdir(out) and os.listdir(out):
            # Only ever replace an earlier output of this script.
            if not os.path.isfile(os.path.join(out, "index.json")):
                fail(f"{out} is not empty and holds no index.json; not replacing it")
            shutil.rmtree(out)
        for sub in ("grammars", "configurations", "ThirdParty"):
            os.makedirs(os.path.join(out, sub))
        vscode = self.sources["vscode"]

        missing = self.grammar_scopes - set(self.grammar_files)
        if missing:
            fail(f"grammars listed but contributed by no extension: {sorted(missing)}")
        missing = self.languages - {entry["id"] for entry in self.language_entries}
        if missing:
            fail(f"languages listed but contributed by no extension: {sorted(missing)}")

        for scope, (path, provenance, relative) in sorted(self.grammar_files.items()):
            # A grammar taken from another commit than the extension contributing it (`grammarFiles`): its
            # licence is clearer there.
            replacement = self.sources.get("grammarFiles", {}).get(scope)
            if replacement:
                path = fetch(self.cache, replacement["repository"], replacement["commit"], replacement["path"])
                provenance = ("replacement", replacement)
            grammar = read_grammar(path)
            if grammar.get("scopeName") != scope:
                fail(f"{path} says its scope is {grammar.get('scopeName')!r}, not {scope!r}")
            output = f"grammars/{scope}.json"
            with open(os.path.join(out, output), "w", encoding="utf-8") as f:
                f.write(minified(grammar))
            kind, source = provenance
            if kind == "replacement":
                self.claim(source["repository"], source["commit"], output)
                if "upstream" in source:
                    self.claim(source["upstream"]["repository"], source["upstream"]["commit"], output)
            elif kind == "vscode":
                upstream = self.grammar_provenance(grammar, source, relative)
                if upstream:
                    self.claim(*upstream, output)
                # VS Code converts and adapts what it ships; its own licence covers that work.
                self.claim(vscode["repository"], vscode["commit"], output)
            else:
                self.claim(source["repository"], source["commit"], output)

        # The plain-text language and its configuration are built into VS Code (modesRegistry.ts and
        # languageConfigurationRegistry.ts), not contributed by an extension.
        plain = {"id": "plaintext", "aliases": ["Plain Text", "text"], "extensions": [".txt"], "configuration": "configurations/plaintext.json"}
        plain_configuration = {
            "brackets": [["(", ")"], ["[", "]"], ["{", "}"]],
            "surroundingPairs": [{"open": o, "close": c} for o, c in (("{", "}"), ("[", "]"), ("(", ")"), ("<", ">"), ('"', '"'), ("'", "'"), ("`", "`"))],
            "folding": {"offSide": True},
        }
        with open(os.path.join(out, plain["configuration"]), "w", encoding="utf-8") as f:
            f.write(minified(plain_configuration))
        self.claim(vscode["repository"], vscode["commit"], plain["configuration"])

        for language, files in sorted(self.configurations.items()):
            # VS Code combines several configurations of one language field by field, the later winning.
            merged = {}
            for path, provenance in files:
                merged.update({k: v for k, v in read_jsonc(path).items() if v})
                kind, source = provenance
                repository, commit = (vscode["repository"], vscode["commit"]) if kind == "vscode" else (source["repository"], source["commit"])
                self.claim(repository, commit, f"configurations/{language}.json")
            with open(os.path.join(out, f"configurations/{language}.json"), "w", encoding="utf-8") as f:
                f.write(minified(merged))

        index = {"languages": [plain] + self.language_entries, "grammars": self.grammar_entries, "fences": self.fences(out)}
        with open(os.path.join(out, "index.json"), "w", encoding="utf-8") as f:
            f.write(minified(index))
        self.claim(vscode["repository"], vscode["commit"], "index.json")
        for extension in self.sources["extensions"]:
            self.claim(extension["repository"], extension["commit"], "index.json")

        self.check_includes(out)
        self.write_third_party(out)

    def fences(self, out):
        """Markdown fence info words and the language each colours its block as: the words of the fenced-code
        rules of the Markdown grammar and of the grammars injected into it (those first, as `L:` injections
        are tried first). A block's language is the one the grammar's embeddedLanguages names for the block's
        embedded scope, else the language of the grammar the rule includes. A word two rules share belongs
        to the one tried first ("h" is C, before Objective-C), as in the editor."""
        language_of = {e["scopeName"]: e["language"] for e in self.grammar_entries if e.get("language")}
        languages = {e["id"] for e in self.language_entries}
        markdown = "text.html.markdown"
        scopes = [e["scopeName"] for e in self.grammar_entries if markdown in e.get("injectTo", [])] + [markdown]
        table = {}
        for scope in scopes:
            with open(os.path.join(out, f"grammars/{scope}.json"), encoding="utf-8") as f:
                grammar = json.load(f)
            embedded = {}
            for entry in self.grammar_entries:
                if entry["scopeName"] == scope:
                    embedded.update(entry.get("embeddedLanguages", {}))
            for words, include, content in fence_rules(grammar):
                language = embedded.get(content) if embedded.get(content) in languages else language_of.get(include)
                if language:
                    for word in words:
                        table.setdefault(word.lower(), language)
        for word, language in self.sources["fenceAliases"]["words"].items():
            if word in table:
                fail(f"the fence alias {word!r} is already a fence word of the Markdown grammars")
            table[word] = language
        return table

    def check_includes(self, out):
        """Every grammar another includes is bundled or listed as left out, and every bundled grammar is used:
        it colours a language, is injected, or is included by another."""
        bundled = set(self.grammar_files)
        unresolved = {}
        used = {e["scopeName"] for e in self.grammar_entries if e.get("language") or e.get("injectTo")}
        for scope in sorted(bundled):
            with open(os.path.join(out, f"grammars/{scope}.json"), encoding="utf-8") as f:
                grammar = json.load(f)
            for include in external_includes(grammar):
                target = include.split("#", 1)[0]
                if target not in bundled:
                    unresolved.setdefault(target, set()).add(scope)
                elif target != scope:
                    used.add(target)
        if bundled - used:
            fail(f"grammars nothing uses: {sorted(bundled - used)}")
        listed = set(self.sources["unresolvedIncludes"]["scopes"])
        unexplained = set(unresolved) - listed
        stale = listed - set(unresolved)
        if unexplained or stale:
            for target in sorted(unexplained):
                print(f"  unresolved {target}: included by {', '.join(sorted(unresolved[target]))}", file=sys.stderr)
            for target in sorted(stale):
                print(f"  listed but resolved or unused: {target}", file=sys.stderr)
            fail("update unresolvedIncludes in update-languages.json")

    def write_third_party(self, out):
        licenses = self.sources["licenses"]
        entries = []
        texts = {}
        for (repository, commit), files in sorted(self.groups.items(), key=lambda item: (item[0][0].lower(), item[0][1])):
            license = licenses.get(repository)
            if not license:
                fail(f"no licence recorded for {repository}")
            text, license_commit = self.license_text(repository, commit, license)
            name = repository.replace("/", "-")
            digest = hashlib.sha256(text.encode()).hexdigest()
            # One text per repository unless it changed between the commits used.
            known = texts.setdefault(name, {})
            if digest not in known:
                known[digest] = f"{name}.txt" if not known else f"{name}-{commit[:12]}.txt"
                with open(os.path.join(out, "ThirdParty", known[digest]), "w", encoding="utf-8") as f:
                    f.write(text)
            entry = {
                "name": repository,
                "url": f"https://github.com/{repository}",
                "commit": commit,
                "license": license["spdx"],
                "licenseFile": known[digest],
                "files": sorted(files),
            }
            if license_commit != commit:
                entry["licenseCommit"] = license_commit
            if "note" in license:
                entry["note"] = license["note"]
            entries.append(entry)
        with open(os.path.join(out, "ThirdParty", "manifest.json"), "w", encoding="utf-8") as f:
            f.write(minified(entries))

    def license_text(self, repository, commit, license):
        """A repository's licence text, and the commit it was read at."""
        if "vscodeLicenseDetail" in license:
            # The text VS Code records for the component, in the cgmanifest.json of the extension shipping it.
            with open(os.path.join(self.vscode, "extensions", license["vscodeLicenseDetail"], "cgmanifest.json"), encoding="utf-8") as f:
                registrations = json.load(f)["registrations"]
            detail = next(r["licenseDetail"] for r in registrations if (r["component"].get("git") or {}).get("name") == repository)
            return "\n".join(detail) + "\n", commit
        if repository == self.sources["vscode"]["repository"]:
            with open(os.path.join(self.vscode, license["file"]), encoding="utf-8") as f:
                return f.read(), commit
        # Read at the commit the files come from; a repository that added its licence file later has it read
        # at another commit the bundle uses.
        commits = [commit] + sorted(c for (r, c) in self.groups if r == repository and c != commit)
        found = next(((c, path) for c in commits for path in [fetch(self.cache, repository, c, license["file"], required=False)] if path), None)
        if not found:
            fail(f"{repository} has no {license['file']} at any commit used")
        license_commit, path = found
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if "section" in license:
            text = license_section(text, license["section"])
        if "notice" in license:
            with open(fetch(self.cache, repository, license_commit, license["notice"]), encoding="utf-8") as f:
                text += "\n\n" + f.read()
        return text, license_commit


FENCE_WORDS = re.compile(r"\(\?i:\(([^()]*)\)")
LITERAL_WORD = re.compile(r"(?:[^\\{}()\[\]*+?|^$]|\\.)+")


def fence_rules(grammar):
    """(words, included scope, embedded content scope) for each fenced-code rule reachable from a grammar's
    top-level patterns, in the order the rules are tried. Words that are regular expressions rather than plain
    words are left out."""
    repository = grammar.get("repository", {})
    seen = set()
    found = []

    def first(node, key):
        if isinstance(node, dict):
            value = node.get(key)
            if key == "include" and isinstance(value, str) and value and value[0] not in "#$":
                return value.split("#", 1)[0]
            if key == "contentName" and isinstance(value, str) and value.startswith("meta.embedded.block"):
                return value
            for child in node.get("patterns", []):
                found = first(child, key)
                if found:
                    return found
        return None

    def visit(node):
        if not isinstance(node, dict):
            return
        include = node.get("include")
        if isinstance(include, str) and include.startswith("#"):
            name = include[1:]
            if name not in seen and name in repository:
                seen.add(name)
                visit(repository[name])
            return
        match = FENCE_WORDS.search(node.get("begin", "")) if "`{3,}" in node.get("begin", "") else None
        if match:
            words = [re.sub(r"\\(.)", r"\1", word) for word in match.group(1).split("|") if LITERAL_WORD.fullmatch(word)]
            scope = first(node, "include")
            if words and scope:
                found.append((words, scope, first(node, "contentName")))
            return
        for value in node.get("patterns", []):
            visit(value)

    for value in grammar.get("patterns", []):
        visit(value)
    return found


def external_includes(node):
    """Every `include` of another grammar (`source.x` or `source.x#rule`) in a grammar."""
    if isinstance(node, dict):
        include = node.get("include")
        if isinstance(include, str) and include and include[0] not in "#$":
            yield include
        for value in node.values():
            yield from external_includes(value)
    elif isinstance(node, list):
        for value in node:
            yield from external_includes(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vscode", required=True, help="a clone of microsoft/vscode at the pinned commit")
    parser.add_argument("--cache", required=True, help="a folder for downloaded upstream files")
    parser.add_argument("--out", default=DEFAULT_OUT, help="the resource folder to write (replaced)")
    arguments = parser.parse_args()
    with open(os.path.join(HERE, "update-languages.json"), encoding="utf-8") as f:
        sources = json.load(f)
    builder = Builder(sources, os.path.abspath(arguments.vscode), os.path.abspath(arguments.cache))
    builder.read_vscode()
    builder.read_upstreams()
    builder.write(os.path.abspath(arguments.out))
    print(f"update-languages: wrote {os.path.abspath(arguments.out)}")


if __name__ == "__main__":
    main()
