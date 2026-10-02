# 고양이 도트 시안 v1

생성 방식: built-in image_gen, 원본 시안의 style-transfer 편집.
원본: cat-weight-run-concept-v1.png (보존).
결과: cat-weight-run-pixel-v1.png.
4행은 통통 → 날씬, 4열은 달리는 자세. 앱에 적용하기 전 검토용 도트 시안.

## 생성 프롬프트

+Use case: style-transfer
Asset type: pixel-art running cat sprite-sheet CONCEPT for a macOS menu-bar quota mascot.
Edit target: the attached original 4-by-4 white cat character sheet. Preserve that concept as a separate source; create a new pixel-art rendition.
Primary request: Convert every cat and its silhouette to genuine crisp, coarse, retro pixel art, not smooth art with a pixel filter. Preserve the original cat identity, its RIGHT-facing side profile, short pointed ears, tiny dark eye, trailing gently raised LEFT tail, the four body-weight stages, and the sequence of four running poses per row.
Layout invariants: exactly FOUR rows and FOUR columns, exactly 16 cats; top row very plump, second moderately plump, third slim athletic, bottom gently slender healthy; same head size and limb lengths throughout. Decrease torso and belly volume down the rows. Preserve generous margins and the regular positions of the 16 sprites. Do not add or remove any cat. Keep the composition landscape 3:2.
Pixel construction: imagine drawing on a 192-by-128-pixel logical canvas (48-by-32 cells), then enlarging exactly 8 times with nearest-neighbor scaling. Every visible pixel is a clearly defined square of the same size on the same uniform pixel grid. Each cat is approximately 36 by 22 logical pixels. All contours use deliberate stepped pixel clusters, angular diagonal stairs, and blocky paws and ears. The eye is one dark square pixel. Zero antialiasing, zero smooth curves, zero rounded vector edges, zero blur, zero gradients, zero painterly texture, zero dithering, zero 3D.
Palette: two colors only, warm white cat pixels and uniform flat dark charcoal background. Preserve an opaque dark background, not transparency or a checkerboard. This should be charming minimal ONE-BIT pixel sprite art, readily legible as a cat at menu-bar size. The cat should feel energetic and cute, never sick or skeletal.
Animation poses: extended airborne stride; front foot contact with gathering rear legs; compact passing pose; rear push-off with reaching forelegs. Maintain coherent identity and size between frames. No rainbow trail, no accessories, no labels, no typography, no UI, no watermark.
