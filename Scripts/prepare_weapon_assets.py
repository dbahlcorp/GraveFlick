"""Split the expanded weapon kit into clean, transparent runtime sprites."""

from pathlib import Path

from PIL import Image

from prepare_animation_atlases import remove_edge_fragments


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ArtSource" / "WeaponKit" / "expanded-weapons-alpha.png"
DESTINATION = ROOT / "Resources" / "Art" / "Weapons"
NAMES = (
    "weapon_anvil", "weapon_grenade", "weapon_propane", "weapon_wrecking_ball",
    "weapon_sniper", "weapon_grease_fire", "weapon_transformer", "weapon_delivery_truck",
)


def main() -> None:
    image = Image.open(SOURCE).convert("RGBA")
    cell_width = image.width // 4
    cell_height = image.height // 2
    DESTINATION.mkdir(parents=True, exist_ok=True)

    for index, name in enumerate(NAMES):
        row, column = divmod(index, 4)
        left = column * cell_width
        top = row * cell_height
        right = image.width if column == 3 else (column + 1) * cell_width
        bottom = image.height if row == 1 else (row + 1) * cell_height
        cell = remove_edge_fragments(image.crop((left, top, right, bottom)))
        alpha_box = cell.getchannel("A").getbbox()
        if alpha_box is None:
            raise RuntimeError(f"{name} contains no visible pixels")

        cropped = cell.crop(alpha_box)
        pad = max(8, round(max(cropped.size) * 0.035))
        output = Image.new("RGBA", (cropped.width + pad * 2, cropped.height + pad * 2))
        output.alpha_composite(cropped, (pad, pad))
        output.save(DESTINATION / f"{name}.png", optimize=True)
        print(f"Wrote {name}.png: {output.size}")


if __name__ == "__main__":
    main()
