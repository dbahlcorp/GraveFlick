"""Validate GraveFlick runtime art coverage and transparency invariants."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


RIG_PARTS = ("head", "torso", "frontArm", "backArm", "frontLeg", "backLeg")
ZOMBIE_KINDS = (
    "walker", "runner", "brute", "crawler", "armored", "volatile",
    "waitress", "riot", "groundskeeper", "butcher", "colossus", "bouncer",
)
TRANSPARENT_DIRECTORIES = (
    Path("Resources/Art/Animated"),
    Path("Resources/Art/Equipment"),
    Path("Resources/Art/Weapons"),
    Path("Resources/Art/VFX"),
    Path("Resources/Art/UI/Icons"),
)


def verify(root: Path) -> None:
    failures: list[str] = []
    animated = root / "Resources" / "Art" / "Animated"
    for kind in ZOMBIE_KINDS:
        for part in RIG_PARTS:
            path = animated / f"{kind}_{part}.png"
            if not path.is_file():
                failures.append(f"missing articulated rig part: {path.relative_to(root)}")

    for relative in TRANSPARENT_DIRECTORIES:
        directory = root / relative
        for path in directory.rglob("*.png"):
            with Image.open(path).convert("RGBA") as image:
                if image.getchannel("A").getbbox() is None:
                    failures.append(f"empty alpha channel: {path.relative_to(root)}")
                    continue
                corners = (
                    image.getpixel((0, 0))[3],
                    image.getpixel((image.width - 1, 0))[3],
                    image.getpixel((0, image.height - 1))[3],
                    image.getpixel((image.width - 1, image.height - 1))[3],
                )
                if any(corners):
                    failures.append(f"non-transparent corner: {path.relative_to(root)}")

    if failures:
        raise SystemExit("Art verification failed:\n" + "\n".join(sorted(failures)))
    print("Art verification passed: complete rigs, visible alpha, and transparent corners.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    verify(args.root.resolve())


if __name__ == "__main__":
    main()
