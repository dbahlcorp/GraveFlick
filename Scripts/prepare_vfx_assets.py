"""Crop and downsample authored VFX sources into SpriteKit-ready alpha PNGs."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ArtSource" / "VFX"
OUTPUT = ROOT / "Resources" / "Art" / "VFX"
OUTPUT.mkdir(parents=True, exist_ok=True)

ASSETS = {
    "vfx_pavement_impact_source.png": ("vfx_pavement_impact.png", 768),
    "vfx_zombie_splatter_alpha.png": ("vfx_zombie_splatter.png", 640),
    "vfx_explosion_source.png": ("vfx_explosion.png", 768),
    "vfx_freezer_burst_source.png": ("vfx_freezer_burst.png", 768),
}


for source_name, (output_name, target_size) in ASSETS.items():
    image = Image.open(SOURCE / source_name).convert("RGBA")
    alpha_box = image.getchannel("A").getbbox()
    if alpha_box is None:
        raise RuntimeError(f"{source_name} has no visible pixels")
    image = image.crop(alpha_box)
    art_size = int(target_size * 0.84)
    image.thumbnail((art_size, art_size), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (target_size, target_size), (0, 0, 0, 0))
    canvas.alpha_composite(image, ((target_size - image.width) // 2, (target_size - image.height) // 2))
    canvas.save(OUTPUT / output_name, optimize=True)
    print(f"Wrote {output_name}: {canvas.size}")
