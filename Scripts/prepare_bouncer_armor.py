"""Downsample authored Bouncer armor masters into SpriteKit-ready alpha PNGs."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ArtSource" / "BouncerKit" / "Armor"
DESTINATION = ROOT / "Resources" / "Art" / "Animated"
NAMES = ("bouncer_armor_shoulders", "bouncer_armor_torso", "bouncer_armor_belt")


def main() -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name in NAMES:
        image = Image.open(SOURCE / f"{name}.png").convert("RGBA")
        alpha_box = image.getchannel("A").getbbox()
        if alpha_box is None:
            raise RuntimeError(f"{name} contains no visible pixels")
        image = image.crop(alpha_box)
        canvas = Image.new("RGBA", (image.width + 36, image.height + 36))
        canvas.alpha_composite(image, (18, 18))
        canvas.thumbnail((700, 700), Image.Resampling.LANCZOS)
        canvas.save(DESTINATION / f"{name}.png", optimize=True)
        print(f"Wrote {name}.png: {canvas.size}")


if __name__ == "__main__":
    main()
