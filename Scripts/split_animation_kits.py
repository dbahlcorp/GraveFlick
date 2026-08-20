from pathlib import Path

from PIL import Image

from prepare_animation_atlases import remove_edge_fragments


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ArtSource" / "AnimationKits"
OVERRIDES = SOURCE / "Overrides"
DESTINATION = ROOT / "Resources" / "Art" / "Animated"
PARTS = (
    ("head", 0, 0),
    ("torso", 1, 0),
    ("frontArm", 2, 0),
    ("backArm", 0, 1),
    ("frontLeg", 1, 1),
    ("backLeg", 2, 1),
)


def split_sheet(kind: str) -> None:
    image = Image.open(SOURCE / f"{kind}-alpha.png").convert("RGBA")
    cell_width = image.width // 3
    cell_height = image.height // 2

    for part, column, row in PARTS:
        left = column * cell_width
        top = row * cell_height
        right = image.width if column == 2 else (column + 1) * cell_width
        bottom = image.height if row == 1 else (row + 1) * cell_height
        source_cell = remove_edge_fragments(image.crop((left, top, right, bottom)))
        alpha_box = source_cell.getchannel("A").getbbox()
        if alpha_box is None:
            raise RuntimeError(f"{kind}/{part} contains no visible pixels")

        cropped = source_cell.crop(alpha_box)
        override_path = OVERRIDES / f"{kind}_{part}.png"
        if override_path.exists():
            override = remove_edge_fragments(Image.open(override_path).convert("RGBA"))
            override_box = override.getchannel("A").getbbox()
            if override_box is None:
                raise RuntimeError(f"{kind}/{part} override contains no visible pixels")
            cropped = override.crop(override_box).resize(cropped.size, Image.Resampling.LANCZOS)

        pad = max(8, round(max(cropped.size) * 0.035))
        output = Image.new("RGBA", (cropped.width + pad * 2, cropped.height + pad * 2))
        output.alpha_composite(cropped, (pad, pad))
        output.save(DESTINATION / f"{kind}_{part}.png", optimize=True)


def main() -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for kind in (
        "walker", "runner", "brute", "crawler", "armored", "volatile",
        "waitress", "riot", "groundskeeper", "butcher", "colossus",
    ):
        split_sheet(kind)


if __name__ == "__main__":
    main()
