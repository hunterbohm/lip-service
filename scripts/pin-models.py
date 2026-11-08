#!/usr/bin/env python3
"""Regenerates the table of pinned model files: the speech models and live talk's on-Mac voice.

Downloads every file the app reads from the Hugging Face repositories at the commits named in PINS, checks each
against the hash the Hub publishes for that commit, hashes it with SHA-256, and writes:

  DictationCore/Sources/DictationCore/PinnedModels.swift   what the app checks before Core ML reads a file
  scripts/models.lock                                      what scripts/fetch-models.sh downloads and checks

To move to a newer model, change a commit below, run this script, and review the diff. A speech model's files are
listed the way FluidAudio lists them: the Core ML bundles the app loads, and the .json and .txt files at the repository
root. A voice is one pack folder inside its repository: the Core ML bundles it loads and the files named for it, which
are the ones FluidAudio reads and the voices the settings offer.
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request

# The Phonon voices the settings offer, from the pack's voices/ folder. Keep in step with OnMacVoice.offered.
PHONON_VOICES = ["en_us_Preston", "en_us_Easton", "en_us_Miles", "en_us_Harper", "en_us_Zoey", "en_gb_Hugh", "en_gb_Freya"]

# kind is "model" for a speech model and "voice" for a voice pack. folder is the repository's folder in FluidAudio's
# cache; subdirectory is the pack's folder inside the repository, and a pack's files are listed relative to it. files
# names what is kept outside the bundles; without it, the .json and .txt files at the root are.
PINS = [
    dict(kind="model", repo="FluidInference/parakeet-tdt-0.6b-v2-coreml", commit="ee09c569f73759e6d44c9bd16766f477b2b36d39",
         folder="parakeet-tdt-0.6b-v2", name="parakeetTDT",
         bundles=["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]),
    dict(kind="model", repo="FluidInference/parakeet-ctc-110m-coreml", commit="accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
         folder="parakeet-ctc-110m-coreml", name="parakeetCTC",
         bundles=["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"]),
    # PocketTTS small with Gradium's Phonon 31M English voices (Apache-2.0, the pack's LICENSE). FluidAudio's
    # PocketTtsSmallManager reads the MLState package, the fp32 Mimi decoder, the two descriptors, three constants and
    # one voice's conditioning rows; the reference models, the .mlpackage sources and the other constants are not read.
    dict(kind="voice", repo="FluidInference/pocket-tts-coreml", commit="c2e998e269e4d4b51f74061faddb8450cd8f9a9a",
         folder="pocket-tts", subdirectory="phonon/phonon-31m-en", name="phonon",
         bundles=["pocket_state.mlmodelc", "mimi_decoder.mlmodelc"],
         files=["LICENSE", "arch.json", "pocket_state.json", "constants_bin/bos_emb.bin",
                "constants_bin/text_embed_table.bin", "constants_bin/tokenizer.model"]
               + [f"voices/{voice}.safetensors" for voice in PHONON_VOICES]),
]

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
swift_out = os.path.join(root, "DictationCore/Sources/DictationCore/PinnedModels.swift")
lock_out = os.path.join(root, "scripts/models.lock")


def get(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def listing(repo, commit, subdirectory):
    """The files under subdirectory, by their path relative to it."""
    url = f"https://huggingface.co/api/models/{repo}/tree/{commit}" + (f"/{subdirectory}" if subdirectory else "")
    files = json.loads(get(url + "?recursive=true"))
    prefix = subdirectory + "/" if subdirectory else ""
    return {item["path"][len(prefix):]: item for item in files if item["type"] == "file" and item["path"].startswith(prefix)}


def wanted(path, pin):
    if path.split("/")[0] in pin["bundles"]:
        return True
    if "files" in pin:
        return path in pin["files"]
    return "/" not in path and path.endswith((".json", ".txt"))


def fetch(repo, commit, item, destination):
    path = item["path"]
    sha256, git_blob = hashlib.sha256(), hashlib.sha1(b"blob %d\0" % item["size"])
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    request = urllib.request.Request(f"https://huggingface.co/{repo}/resolve/{commit}/{path}")
    size = 0
    with urllib.request.urlopen(request, timeout=120) as response, open(destination, "wb") as out:
        while chunk := response.read(1 << 20):
            out.write(chunk)
            sha256.update(chunk)
            git_blob.update(chunk)
            size += len(chunk)
    # The Hub publishes the SHA-256 of an LFS file and the git object id of any other.
    published = item.get("lfs", {}).get("oid")
    if size != item["size"] or (sha256.hexdigest() != published if published else git_blob.hexdigest() != item["oid"]):
        sys.exit(f"{repo}@{commit[:12]}: {path} does not match the hash the Hub publishes for it")
    return size, sha256.hexdigest()


def main():
    scratch = tempfile.mkdtemp(prefix="pin-models.")
    try:
        models = []
        for pin in PINS:
            repo, commit, folder, subdirectory = pin["repo"], pin["commit"], pin["folder"], pin.get("subdirectory", "")
            tree = listing(repo, commit, subdirectory)
            paths = sorted(p for p in tree if wanted(p, pin))
            missing = [b for b in pin["bundles"] if not any(p.startswith(b + "/") for p in paths)]
            missing += [f for f in pin.get("files", []) if f not in tree]
            if missing:
                sys.exit(f"{repo}@{commit[:12]} has no {', '.join(missing)}")
            files = []
            for path in paths:
                size, digest = fetch(repo, commit, tree[path], os.path.join(scratch, folder, subdirectory, path))
                files.append((path, size, digest))
                print(f"{folder}/{subdirectory + '/' if subdirectory else ''}{path} {size}", file=sys.stderr)
            models.append(dict(pin, subdirectory=subdirectory, files=files))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    with open(swift_out, "w") as out:
        out.write("// Generated by scripts/pin-models.py. Do not edit.\n\n")
        out.write("public enum PinnedModels {\n")
        for m in models:
            out.write(f"    public static let {m['name']} = PinnedModel(\n")
            out.write(f'        repo: "{m["repo"]}",\n        commit: "{m["commit"]}",\n        folder: "{m["folder"]}",\n')
            if m["subdirectory"]:
                out.write(f'        subdirectory: "{m["subdirectory"]}",\n')
            out.write("        files: [\n")
            for path, size, digest in m["files"]:
                out.write(f'            ModelFile("{path}", size: {size}, sha256: "{digest}"),\n')
            out.write("        ])\n\n")
        for kind, label in [("model", "speech"), ("voice", "voices")]:
            names = ", ".join(m["name"] for m in models if m["kind"] == kind)
            out.write(f"    public static let {label} = [{names}]\n")
        out.write("    public static let all = speech + voices\n}\n")
    with open(lock_out, "w") as out:
        out.write("# Generated by scripts/pin-models.py. Do not edit.\n")
        out.write("# model REPOSITORY COMMIT FOLDER\n# voice REPOSITORY COMMIT FOLDER SUBDIRECTORY\n# SIZE SHA-256 PATH\n")
        for m in models:
            extra = f" {m['subdirectory']}" if m["subdirectory"] else ""
            out.write(f"{m['kind']} {m['repo']} {m['commit']} {m['folder']}{extra}\n")
            for path, size, digest in m["files"]:
                out.write(f"{size} {digest} {path}\n")


main()
