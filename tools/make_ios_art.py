# -*- coding: utf-8 -*-
"""Builds the asset catalog and the menu logo from the pictures made with Google Flow (Nano Banana) in art_raw/:   python tools/make_ios_art.py

  art_raw/app_icon.png   -> EightBall/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png   (full bleed, no alpha)
  art_raw/logo_wide.jpg  -> Assets.xcassets/LaunchLogo.imageset + EightBall/Resources/Data/art/logo_wide.jpg (main menu)
  art_raw/launch_art.jpg -> EightBall/Resources/Data/art/launch_art.jpg
  colours: AccentColor (gold), LaunchBackground (midnight)
"""
import json
import os
import shutil

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "art_raw")
RES = os.path.join(ROOT, "EightBall", "Resources")
CAT = os.path.join(RES, "Assets.xcassets")


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def colorset(name, r, g, b):
    write_json(os.path.join(CAT, name + ".colorset", "Contents.json"), {
        "colors": [{"color": {"color-space": "srgb", "components": {"red": "%.3f" % r, "green": "%.3f" % g, "blue": "%.3f" % b, "alpha": "1.000"}}, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1}})


def main():
    os.makedirs(CAT, exist_ok=True)
    write_json(os.path.join(CAT, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
    icon_dir = os.path.join(CAT, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    Image.open(os.path.join(RAW, "app_icon.png")).convert("RGB").resize((1024, 1024), Image.LANCZOS).save(os.path.join(icon_dir, "AppIcon-1024.png"))
    write_json(os.path.join(icon_dir, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}})
    colorset("AccentColor", 0.851, 0.663, 0.227)               # gold  #D9A93A
    colorset("LaunchBackground", 0.039, 0.086, 0.133)          # midnight  #0A1622
    logo_dir = os.path.join(CAT, "LaunchLogo.imageset")
    os.makedirs(logo_dir, exist_ok=True)
    logo = Image.open(os.path.join(RAW, "logo_wide.jpg")).convert("RGB")
    logo.resize((1200, int(1200 * logo.height / logo.width)), Image.LANCZOS).save(os.path.join(logo_dir, "LaunchLogo.png"))
    write_json(os.path.join(logo_dir, "Contents.json"), {"images": [{"filename": "LaunchLogo.png", "idiom": "universal", "scale": "3x"}], "info": {"author": "xcode", "version": 1}})
    art = os.path.join(RES, "Data", "art")
    os.makedirs(art, exist_ok=True)
    for name in ("logo_wide.jpg", "launch_art.jpg"):
        shutil.copy2(os.path.join(RAW, name), os.path.join(art, name))
    print("asset catalog written")


if __name__ == "__main__":
    main()
