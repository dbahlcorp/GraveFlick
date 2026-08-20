"""Split the expanded weapon kit into clean, transparent runtime sprites."""

import argparse
import filecmp
from pathlib import Path
import tempfile

from PIL import Image, ImageDraw

from prepare_animation_atlases import remove_edge_fragments


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ArtSource" / "WeaponKit" / "expanded-weapons-alpha.png"
OVERRIDES = ROOT / "ArtSource" / "WeaponKit" / "Overrides"
METEOR_SOURCE = OVERRIDES / "weapon_meteor_sheet.png"
DELIVERY_TRUCK_SOURCE = OVERRIDES / "weapon_delivery_truck_sheet.png"
DESTINATION = ROOT / "Resources" / "Art" / "Weapons"
NAMES = (
    "weapon_anvil", "weapon_grenade", "weapon_propane", "weapon_wrecking_ball",
    "weapon_sniper", "weapon_grease_fire", "weapon_transformer", "weapon_delivery_truck",
)
METEOR_NAMES = ("weapon_meteor", "weapon_meteor_1", "weapon_meteor_2", "weapon_meteor_3")
DELIVERY_TRUCK_FRAME_NAMES = tuple(f"weapon_delivery_truck_drive_{index}" for index in range(1, 5))


def render_override(name: str) -> Image.Image:
    image = remove_edge_fragments(Image.open(OVERRIDES / f"{name}.png").convert("RGBA"))
    alpha_box = image.getchannel("A").getbbox()
    if alpha_box is None:
        raise RuntimeError(f"{name} override contains no visible pixels")
    cropped = image.crop(alpha_box)

    # These two weapons are drawn into fixed-size SpriteKit nodes. Matching their authored canvas
    # aspect prevents the runtime size from stretching otherwise-correct source art.
    if name == "weapon_grenade":
        canvas = Image.new("RGBA", (304, 400))  # 44:58 gameplay aspect, rounded to practical pixels.
        cropped.thumbnail((276, 372), Image.Resampling.LANCZOS)
        canvas.alpha_composite(cropped, ((canvas.width - cropped.width) // 2, (canvas.height - cropped.height) // 2))
        return canvas
    if name == "weapon_wrecking_ball":
        canvas = Image.new("RGBA", (512, 512))
        cropped.thumbnail((464, 464), Image.Resampling.LANCZOS)
        canvas.alpha_composite(cropped, ((canvas.width - cropped.width) // 2, (canvas.height - cropped.height) // 2))
        return canvas

    cropped.thumbnail((484, 484), Image.Resampling.LANCZOS)
    pad = max(8, round(max(cropped.size) * 0.035))
    output = Image.new("RGBA", (cropped.width + pad * 2, cropped.height + pad * 2))
    output.alpha_composite(cropped, (pad, pad))
    return output


def prepare_meteor(destination: Path) -> None:
    sheet = Image.open(METEOR_SOURCE).convert("RGBA")
    cell_width = sheet.width // 2
    cell_height = sheet.height // 2
    safety_inset = 20
    for index, name in enumerate(METEOR_NAMES):
        row, column = divmod(index, 2)
        cell = remove_edge_fragments(sheet.crop((
            column * cell_width + safety_inset,
            row * cell_height + safety_inset,
            (sheet.width if column == 1 else (column + 1) * cell_width) - safety_inset,
            (sheet.height if row == 1 else (row + 1) * cell_height) - safety_inset,
        )))
        alpha_box = cell.getchannel("A").getbbox()
        if alpha_box is None:
            raise RuntimeError(f"{name} contains no visible pixels")
        cropped = cell.crop(alpha_box)
        cropped.thumbnail((480, 480), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (512, 512))
        canvas.alpha_composite(cropped, ((512 - cropped.width) // 2, (512 - cropped.height) // 2))
        if index == 0:
            # The generated sheet includes a detached cyan fleck in the icon cell's empty
            # upper-right corner. Remove it without disturbing the meteor or its trailing flame.
            ImageDraw.Draw(canvas).rectangle((430, 0, 511, 130), fill=(0, 0, 0, 0))
        canvas.save(destination / f"{name}.png", optimize=True)
        print(f"Wrote {name}.png: {canvas.size}")


def prepare_delivery_truck(destination: Path) -> None:
    sheet = Image.open(DELIVERY_TRUCK_SOURCE).convert("RGBA")
    cell_width = sheet.width // 2
    cell_height = sheet.height // 2
    frames_destination = destination / "Frames"
    frames_destination.mkdir(parents=True, exist_ok=True)
    frames: list[Image.Image] = []

    for index, name in enumerate(DELIVERY_TRUCK_FRAME_NAMES):
        row, column = divmod(index, 2)
        inset = 18
        cell = remove_edge_fragments(sheet.crop((
            column * cell_width + inset,
            row * cell_height + inset,
            (column + 1) * cell_width - inset,
            (row + 1) * cell_height - inset,
        )))
        # Generated alpha can contain nearly invisible matte noise far from the vehicle. Clear it
        # before measuring bounds so the actual truck, not a 1/255-alpha speck, sets runtime scale.
        cell.putalpha(cell.getchannel("A").point(lambda alpha: alpha if alpha >= 8 else 0))
        alpha_box = cell.getchannel("A").getbbox()
        if alpha_box is None:
            raise RuntimeError(f"{name} contains no visible pixels")
        cropped = cell.crop(alpha_box)
        cropped.thumbnail((612, 332), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (640, 360))
        canvas.alpha_composite(cropped, ((640 - cropped.width) // 2, (360 - cropped.height) // 2))
        frame_path = frames_destination / f"{name}.png"
        canvas.save(frame_path, optimize=True)
        frames.append(canvas)
        print(f"Wrote {frame_path.name}: {canvas.size}")

    # The first driving pose doubles as the HUD/store icon, keeping the advertised vehicle and
    # the in-game vehicle identical while retaining the runtime node's authored 16:9-ish aspect.
    base_path = destination / "weapon_delivery_truck.png"
    frames[0].save(base_path, optimize=True)
    print(f"Wrote {base_path.name}: {frames[0].size}")


def prepare(destination: Path) -> None:
    image = Image.open(SOURCE).convert("RGBA")
    cell_width = image.width // 4
    cell_height = image.height // 2
    destination.mkdir(parents=True, exist_ok=True)

    for index, name in enumerate(NAMES):
        if name == "weapon_delivery_truck":
            continue
        override_path = OVERRIDES / f"{name}.png"
        if override_path.exists():
            output = render_override(name)
        else:
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
        output.save(destination / f"{name}.png", optimize=True)
        print(f"Wrote {name}.png: {output.size}")
    prepare_delivery_truck(destination)
    prepare_meteor(destination)


def verify() -> None:
    with tempfile.TemporaryDirectory(prefix="graveflick-weapons-") as temporary:
        generated = Path(temporary)
        prepare(generated)
        root_names = NAMES + METEOR_NAMES
        failures = [name for name in root_names if not filecmp.cmp(
            generated / f"{name}.png", DESTINATION / f"{name}.png", shallow=False
        )]
        failures.extend(name for name in DELIVERY_TRUCK_FRAME_NAMES if not filecmp.cmp(
            generated / "Frames" / f"{name}.png",
            DESTINATION / "Frames" / f"{name}.png",
            shallow=False,
        ))
        if failures:
            raise SystemExit("Generated weapon assets are stale or missing:\n" + "\n".join(failures))
    print("Weapon asset verification passed.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        verify()
    else:
        prepare(DESTINATION)


if __name__ == "__main__":
    main()
