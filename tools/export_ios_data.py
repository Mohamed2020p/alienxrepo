# -*- coding: utf-8 -*-
"""Packs the assets of the Python game (../pool_game) for the iOS app:

    python tools/export_ios_data.py [path to the pool_game folder]      (default: ../pool_game)

Writes EightBall/Resources/Data/ and EightBall/Resources/Audio/:
  man.bin + man.json   every animation frame of the man (int16 positions, int8 normals) + per-part uv / indices and the clip table
                       (anchors of the cue, head / spine bone matrices).  Layout of man.bin, all little endian:
                           positions  int16  [frame][vertex][xyz]     quant = 1 / man.json["quant"] metres
                           normals    int8   [frame][vertex][xyz]     / 127
                           uvs        float32 [vertex][uv]            (all parts one after the other, part offsets in man.json)
                           indices    uint32  triangle lists          (all parts one after the other)
  models.bin/json, ninja.bin/json   triangle soups from Blender (8 floats per corner: position, normal, uv)
  skins/  variants.json + prints + hair textures        tex/  textures        art/  posters + menu picture        man/  the man's textures
  Audio/*.wav  every sound
"""
import json
import os
import shutil
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)
DATA = os.path.join(ROOT, "EightBall", "Resources", "Data")
AUDIO = os.path.join(ROOT, "EightBall", "Resources", "Audio")


def copy_tree(src, dst, skip=(".npz",)):
    os.makedirs(dst, exist_ok=True)
    for name in sorted(os.listdir(src)):
        p = os.path.join(src, name)
        if os.path.isfile(p) and not name.endswith(skip):
            shutil.copy2(p, os.path.join(dst, name))


def export_man(game):
    z = np.load(os.path.join(game, "data", "man.npz"))
    meta = json.load(open(os.path.join(game, "data", "man.json")))
    pos, nrm = z["pos"], z["nrm"]
    frames, verts = pos.shape[0], pos.shape[1]
    parts, uv_off, idx_off = [], 0, 0
    uv_blobs, idx_blobs = [], []
    for i, p in enumerate(meta["parts"]):
        uv = np.ascontiguousarray(z["p%d_uv" % i], dtype="<f4")
        idx = np.ascontiguousarray(z["p%d_idx" % i], dtype="<u4")
        mat = meta["materials"][p["mat"]] if p["mat"] is not None else None
        parts.append({"name": p["name"], "role": p["role"], "texture": ("man/" + mat["tex"]) if mat and mat.get("tex") else None,
                      "vertexOffset": p["offset"], "vertexCount": p["count"], "uvByteOffset": uv_off, "indexByteOffset": idx_off, "indexCount": int(len(idx))})
        uv_blobs.append(uv.tobytes())
        idx_blobs.append(idx.tobytes())
        uv_off += len(uv_blobs[-1])
        idx_off += len(idx_blobs[-1])
    pos_bytes = np.ascontiguousarray(pos, dtype="<i2").tobytes()
    nrm_bytes = np.ascontiguousarray(nrm, dtype="<i1").tobytes()
    header = {"quant": meta["quant"], "frames": int(frames), "vertices": int(verts), "posByteOffset": 0, "nrmByteOffset": len(pos_bytes),
              "uvByteOffset": len(pos_bytes) + len(nrm_bytes), "indexByteOffset": len(pos_bytes) + len(nrm_bytes) + uv_off, "parts": parts,
              "animations": meta["animations"], "strokeRest": meta["stroke_rest"], "maxPull": meta["max_pull"], "follow": meta["follow"],
              "cueLength": meta["cue_length"], "tableHeight": meta["table_height"], "walkSpeed": meta["walk_speed"]}
    with open(os.path.join(DATA, "man.bin"), "wb") as f:
        f.write(pos_bytes)
        f.write(nrm_bytes)
        for b in uv_blobs:
            f.write(b)
        for b in idx_blobs:
            f.write(b)
    json.dump(header, open(os.path.join(DATA, "man.json"), "w"), separators=(",", ":"))
    os.makedirs(os.path.join(DATA, "man"), exist_ok=True)
    for name in os.listdir(os.path.join(game, "data")):
        if name.startswith("man_tex_"):
            shutil.copy2(os.path.join(game, "data", name), os.path.join(DATA, "man", name))
    print("man: %d frames x %d vertices, %.1f MB" % (frames, verts, os.path.getsize(os.path.join(DATA, "man.bin")) / 1e6))


def main(game):
    game = os.path.abspath(game)
    if os.path.isdir(DATA):
        shutil.rmtree(DATA)
    os.makedirs(DATA)
    os.makedirs(AUDIO, exist_ok=True)
    for name in ("models.bin", "models.json", "ninja.bin", "ninja.json"):
        shutil.copy2(os.path.join(game, "data", name), os.path.join(DATA, name))
    for sub in ("skins", "tex", "art"):
        copy_tree(os.path.join(game, "data", sub), os.path.join(DATA, sub))
    export_man(game)
    for name in sorted(os.listdir(os.path.join(game, "data", "sounds"))):
        shutil.copy2(os.path.join(game, "data", "sounds", name), os.path.join(AUDIO, name))
    import make_ios_art                                     # the logo / launch pictures live in art_raw/, not in the Python game
    make_ios_art.main()
    total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(os.path.join(ROOT, "EightBall", "Resources")) for f in fs)
    print("resources: %.1f MB" % (total / 1e6))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(ROOT), "pool_game"))
