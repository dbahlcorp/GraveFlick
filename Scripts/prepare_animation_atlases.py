"""Split generated GraveFlick art atlases into transparent runtime frames."""

from __future__ import annotations

import argparse
import filecmp
from pathlib import Path
import tempfile

from PIL import Image


def remove_border_background(image: Image.Image, tolerance: int = 38) -> Image.Image:
    rgba = image.convert("RGBA")
    width, height = rgba.size
    samples = [
        rgba.getpixel((2, 2)),
        rgba.getpixel((width - 3, 2)),
        rgba.getpixel((2, height - 3)),
        rgba.getpixel((width - 3, height - 3)),
    ]
    key = tuple(sum(pixel[channel] for pixel in samples) // len(samples) for channel in range(3))
    pixels = rgba.load()
    for y in range(height):
        for x in range(width):
            red, green, blue, alpha = pixels[x, y]
            distance = max(abs(red - key[0]), abs(green - key[1]), abs(blue - key[2]))
            chroma_magenta = red > 150 and blue > 120 and green < min(red, blue) * 0.72
            if distance <= tolerance or chroma_magenta:
                pixels[x, y] = (red, green, blue, 0)
            elif distance <= tolerance * 2:
                matte = (distance - tolerance) / tolerance
                green_floor = min(red, blue)
                pixels[x, y] = (int(red * matte), int(green + (green_floor - green) * (1 - matte)), int(blue * matte), int(alpha * matte))
    return rgba


def crop_cells(source: Path, destination: Path, rows: int, columns: int, names: list[str], key: bool) -> None:
    image = Image.open(source).convert("RGBA")
    cell_width = image.width // columns
    cell_height = image.height // rows
    destination.mkdir(parents=True, exist_ok=True)
    for index, name in enumerate(names):
        row, column = divmod(index, columns)
        frame = image.crop((column * cell_width, row * cell_height, (column + 1) * cell_width, (row + 1) * cell_height))
        if key and not frame.getbbox():
            raise RuntimeError(f"Empty cell for {name}")
        if key:
            frame = remove_border_background(frame)
        alpha = frame.getchannel("A")
        bbox = alpha.getbbox()
        if bbox is None:
            raise RuntimeError(f"No visible pixels for {name}")
        frame = frame.crop(bbox)
        canvas = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
        frame.thumbnail((464, 464), Image.Resampling.LANCZOS)
        canvas.alpha_composite(frame, ((512 - frame.width) // 2, (512 - frame.height) // 2))
        canvas.save(destination / f"{name}.png", optimize=True)


def crop_selected(source: Path, destination: Path, rows: int, columns: int, selections: list[tuple[int, str]], key: bool) -> None:
    image = Image.open(source).convert("RGBA")
    cell_width = image.width // columns
    cell_height = image.height // rows
    destination.mkdir(parents=True, exist_ok=True)
    for index, name in selections:
        row, column = divmod(index, columns)
        frame = image.crop((column * cell_width, row * cell_height, (column + 1) * cell_width, (row + 1) * cell_height))
        if key:
            frame = remove_border_background(frame)
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise RuntimeError(f"No visible pixels for {name}")
        frame = frame.crop(bbox)
        canvas = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
        frame.thumbnail((464, 464), Image.Resampling.LANCZOS)
        canvas.alpha_composite(frame, ((512 - frame.width) // 2, (512 - frame.height) // 2))
        canvas.save(destination / f"{name}.png", optimize=True)


def crop_boxes(source: Path, destination: Path, selections: list[tuple[tuple[int, int, int, int], str]]) -> None:
    image = Image.open(source).convert("RGBA")
    destination.mkdir(parents=True, exist_ok=True)
    for box, name in selections:
        frame = remove_border_background(image.crop(box))
        bbox = frame.getchannel("A").getbbox()
        if bbox is None:
            raise RuntimeError(f"No visible pixels for {name}")
        frame = frame.crop(bbox)
        canvas = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
        frame.thumbnail((464, 464), Image.Resampling.LANCZOS)
        canvas.alpha_composite(frame, ((512 - frame.width) // 2, (512 - frame.height) // 2))
        canvas.save(destination / f"{name}.png", optimize=True)


def prepare(root: Path, source: Path) -> None:
    crop_cells(source / "ui-icons.png", root / "Resources" / "Art" / "UI" / "Icons", 4, 3, [
        "ui_upgrade_diner", "ui_upgrade_flick", "ui_upgrade_rapid",
        "ui_currency_coin", "ui_achievement", "ui_settings",
        "ui_pause", "ui_lock", "ui_star",
        "ui_music", "ui_sound", "ui_contrast",
    ], True)
    crop_cells(source / "combat-vfx.png", root / "Resources" / "Art" / "VFX" / "Frames", 4, 4, [
        f"vfx_{effect}_{frame}" for effect in ("pavement_impact", "zombie_splatter", "explosion", "freezer_burst") for frame in range(1, 5)
    ], False)
    crop_cells(source / "equipment-actions.png", root / "Resources" / "Art" / "Equipment" / "Frames", 5, 3, [
        f"{item}_{frame}" for item in ("weapon_bowling_ball", "weapon_scatterblast", "weapon_airstrike_beacon", "trap_spike_strip", "trap_flash_freezer") for frame in range(1, 4)
    ], False)
    crop_cells(source / "diner-components.png", root / "Resources" / "Art" / "Diner" / "Frames", 3, 4, [
        f"diner_{item}_{frame}" for item in ("marquee", "door", "vent") for frame in range(1, 5)
    ], True)
    crop_boxes(source / "secondary-ui-icons.png", root / "Resources" / "Art" / "UI" / "Icons", [
        ((15, 10, 365, 290), "ui_play"), ((380, 10, 755, 290), "ui_levels"), ((760, 10, 1125, 290), "ui_survival"),
        ((15, 280, 440, 570), "ui_upgrades"), ((440, 280, 880, 570), "ui_info"),
        ((900, 280, 1370, 570), "ui_back"), ((15, 540, 440, 840), "ui_grave_time"), ((440, 540, 900, 840), "ui_heart"),
        ((920, 560, 1370, 820), "ui_moon"), ((15, 830, 440, 1086), "ui_tutorial_grab"),
        ((430, 830, 910, 1086), "ui_tutorial_flick"), ((900, 845, 1370, 1086), "ui_tutorial_slam"),
    ])
    crop_cells(source / "environment-atmosphere.png", root / "Resources" / "Art" / "Environments" / "Frames", 5, 3, [
        f"environment_atmosphere_{level}_{frame}" for level in range(1, 6) for frame in range(1, 4)
    ], False)


def verify(root: Path) -> None:
    relative_directories = [
        Path("Resources/Art/UI/Icons"), Path("Resources/Art/VFX/Frames"), Path("Resources/Art/Equipment/Frames"),
        Path("Resources/Art/Diner/Frames"), Path("Resources/Art/Environments/Frames"),
    ]
    with tempfile.TemporaryDirectory(prefix="graveflick-assets-") as temporary:
        generated_root = Path(temporary)
        prepare(generated_root, root / "ArtSource" / "AnimationAtlases")
        failures: list[str] = []
        for relative in relative_directories:
            committed = root / relative
            generated = generated_root / relative
            comparison = filecmp.dircmp(committed, generated)
            # left_only (committed files the atlas doesn't produce) is deliberately excluded: these
            # directories also hold hand-supplied art dropped in outside the atlas pipeline (e.g.
            # vfx_volatile_burst_*, bouncer_armor_*), which this check has no way to regenerate and
            # was never meant to gate. Only flag drift in the atlas-managed subset itself — a frame
            # the atlas should produce that's missing (right_only) or stale (diff_files/funny_files).
            failures.extend(str(relative / name) for name in comparison.right_only + comparison.diff_files + comparison.funny_files)
        if failures:
            raise SystemExit("Generated animation assets are stale or missing:\n" + "\n".join(sorted(failures)))
    print("Animation asset verification passed.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--verify", action="store_true", help="Regenerate into a temporary directory and compare with committed frames")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.verify:
        verify(root)
    else:
        prepare(root, root / "ArtSource" / "AnimationAtlases")


if __name__ == "__main__":
    main()
