"""Add consistent transparent safety padding to the authored volatile-burst frames."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ArtSource" / "VFX" / "VolatileBurstFrames"
DESTINATION = ROOT / "Resources" / "Art" / "VFX" / "Frames"
CANVAS_SIZE = 1254
ART_SIZE = round(CANVAS_SIZE * 0.84)


def main() -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for frame_number in range(1, 5):
        name = f"vfx_volatile_burst_{frame_number}.png"
        image = Image.open(SOURCE / name).convert("RGBA")
        alpha_box = image.getchannel("A").getbbox()
        if alpha_box is None:
            raise RuntimeError(f"{name} contains no visible pixels")
        image = image.crop(alpha_box)
        image.thumbnail((ART_SIZE, ART_SIZE), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (CANVAS_SIZE, CANVAS_SIZE))
        canvas.alpha_composite(image, ((CANVAS_SIZE - image.width) // 2, (CANVAS_SIZE - image.height) // 2))
        canvas.save(DESTINATION / name, optimize=True)
        print(f"Wrote {name}: {canvas.size}")


if __name__ == "__main__":
    main()
