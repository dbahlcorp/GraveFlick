"""Prepare standalone and weapon-specific VFX art for SpriteKit."""

import argparse
import filecmp
from pathlib import Path
import tempfile

from PIL import Image

from prepare_animation_atlases import remove_edge_fragments


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ArtSource" / "VFX"
OUTPUT = ROOT / "Resources" / "Art" / "VFX"

ASSETS = {
    "vfx_pavement_impact_source.png": ("vfx_pavement_impact.png", 768),
    "vfx_zombie_splatter_alpha.png": ("vfx_zombie_splatter.png", 640),
    "vfx_explosion_source.png": ("vfx_explosion.png", 768),
    "vfx_freezer_burst_source.png": ("vfx_freezer_burst.png", 768),
}

DEDICATED_SHEETS = {
    "vfx_grenade_explosion_sheet.png": "vfx_grenade_explosion",
    "vfx_propane_explosion_sheet.png": "vfx_propane_explosion",
    "vfx_airstrike_explosion_sheet.png": "vfx_airstrike_explosion",
    "vfx_grease_fire_explosion_sheet.png": "vfx_grease_fire_explosion",
}


def fitted_canvas(image: Image.Image, size: int, art_size: int) -> Image.Image:
    alpha_box = image.getchannel("A").getbbox()
    if alpha_box is None:
        raise RuntimeError("VFX source contains no visible pixels")
    cropped = image.crop(alpha_box)
    cropped.thumbnail((art_size, art_size), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(cropped, ((size - cropped.width) // 2, (size - cropped.height) // 2))
    return canvas


def prepare_standalone(destination: Path) -> list[Path]:
    written: list[Path] = []
    for source_name, (output_name, target_size) in ASSETS.items():
        image = Image.open(SOURCE / source_name).convert("RGBA")
        output = fitted_canvas(image, target_size, int(target_size * 0.84))
        output_path = destination / output_name
        output.save(output_path, optimize=True)
        written.append(output_path)
        print(f"Wrote {output_name}: {output.size}")
    return written


def prepare_dedicated_explosions(destination: Path) -> list[Path]:
    frame_destination = destination / "Frames"
    frame_destination.mkdir(parents=True, exist_ok=True)
    sheet_source = SOURCE / "DedicatedExplosionSheets"
    written: list[Path] = []

    for sheet_name, effect_name in DEDICATED_SHEETS.items():
        sheet = Image.open(sheet_source / sheet_name).convert("RGBA")
        cell_width = sheet.width // 2
        cell_height = sheet.height // 2
        frames: list[Image.Image] = []
        for index in range(4):
            row, column = divmod(index, 2)
            # A small inset keeps antialiased flecks from the neighboring cell out of the crop.
            inset = max(8, round(min(cell_width, cell_height) * 0.025))
            cell = sheet.crop((
                column * cell_width + inset,
                row * cell_height + inset,
                (column + 1) * cell_width - inset,
                (row + 1) * cell_height - inset,
            ))
            frame = fitted_canvas(remove_edge_fragments(cell), 512, 480)
            frames.append(frame)
            frame_path = frame_destination / f"{effect_name}_{index + 1}.png"
            frame.save(frame_path, optimize=True)
            written.append(frame_path)
            print(f"Wrote {frame_path.name}: {frame.size}")

        # Keep the conventional base texture available even though gameplay animates the frames.
        base = fitted_canvas(frames[1], 768, 704)
        base_path = destination / f"{effect_name}.png"
        base.save(base_path, optimize=True)
        written.append(base_path)
        print(f"Wrote {base_path.name}: {base.size}")
    return written


def prepare(destination: Path) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    return prepare_standalone(destination) + prepare_dedicated_explosions(destination)


def verify() -> None:
    with tempfile.TemporaryDirectory(prefix="graveflick-vfx-") as temporary:
        generated = Path(temporary)
        outputs = prepare(generated)
        failures = []
        for generated_path in outputs:
            relative = generated_path.relative_to(generated)
            committed = OUTPUT / relative
            if not committed.exists() or not filecmp.cmp(generated_path, committed, shallow=False):
                failures.append(str(relative))
        if failures:
            raise SystemExit("Generated VFX assets are stale or missing:\n" + "\n".join(failures))
    print("VFX asset verification passed.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        verify()
    else:
        prepare(OUTPUT)


if __name__ == "__main__":
    main()
