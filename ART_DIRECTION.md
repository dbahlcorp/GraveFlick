# GraveFlick Art Direction

## Visual identity

GraveFlick is a weathered midnight roadside horror-comedy. Its world combines a warmly lit 1950s diner with cold cyan moonlight, distressed metal, dirty concrete, burgundy enamel, faded cream paint, and toxic zombie greens. The diner is the visual anchor: every gameplay asset should look as though it belongs in the same illustrated scene.

## Rendering rules

- Use detailed, hand-painted 2D illustration with crisp silhouettes and readable exaggeration at phone scale.
- Favor three-quarter or direct side views for moving gameplay objects. Keep the diner and interface emblems front-facing.
- Use warm amber, red neon, burgundy, aged cream, and oxidized teal for human-made objects.
- Use cyan rim light, sickly green accents, and muted violet shadows for supernatural effects.
- Retain surface wear: chipped enamel, scratches, grease, rust, cracks, and impact dents.
- Avoid photorealism, flat vector art, pixel art, pristine sci-fi materials, and generic emoji-like icons.
- Avoid baked rectangular backgrounds. Gameplay sprites require transparent padding and clean alpha edges.

## Runtime scale and export

- Author source art at least four times its intended SpriteKit display size.
- Preserve the uncropped source under `ArtSource/`; place optimized transparent runtime files under `Resources/Art/`.
- Use lower_snake_case filenames and stable category prefixes.
- Keep important silhouettes inside an 8% safety margin.
- Runtime art uses linear filtering unless an asset explicitly requires hard pixel edges.
- Every asset family must have a coverage check that verifies its texture is present and non-empty.

## Animation language

- Idle loops should have restrained secondary motion and randomized timing so the scene never looks synchronized.
- Actions need anticipation, a sharp readable impact pose, and a brief settle.
- Heavy objects squash less but overshoot farther; light objects wobble and spin more quickly.
- Impacts combine sprite animation, directional debris, a short camera response, and sound/haptics.
- Reduced Motion keeps state changes and readable flashes while removing loops, large camera motion, and excessive particles.
- High Contrast increases edge separation without discarding the authored palette.

## Gameplay readability

- Weapons use warm yellow/orange highlights.
- Traps use hazard yellow; freezer effects add bright cyan.
- Pickups use an orange outer glow plus the actual contained item silhouette.
- Friendly or ready states glow outward; enemy damage flashes inward toward the body.
- Critical diner damage shifts from warm light to broken red neon, smoke, and silhouette loss.

## Asset acceptance checklist

1. The asset matches the diner and articulated zombie rendering style.
2. It remains recognizable at intended runtime size.
3. Alpha corners are transparent and edges have no chroma fringe.
4. Its runtime node, animation/state transitions, accessibility behavior, and cleanup lifetime are implemented.
5. The asset is actually selected by live gameplay, not merely present in the repository.
6. Simulator build/tests and asset coverage checks pass.
