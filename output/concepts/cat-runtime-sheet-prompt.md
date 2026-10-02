# 앱용 고양이 스프라이트

생성 방식: built-in image_gen, 도트 시안 배경 투명화 편집.
원본 도트 시안은 보존. 결과는 Resources/CatSpriteSheet.png.
런타임 렌더러는 작은 메뉴 아이콘에서 픽셀을 선명하게 보이게 밝은 실루엣 픽셀과 alpha를 읽고 단색 픽셀 마스크로 표시한다.

## 생성 프롬프트

+Edit target: the provided pixel-art 4-by-4 running-cat sheet.
Task: remove ONLY the dark charcoal background and replace it with genuine transparent alpha. Keep the exact sixteen cats, their existing pixel outlines, exact positions, sizes, colors, dark square eyes, poses, body-weight stages, margins, and four-row/four-column layout unchanged. This is an app runtime sprite sheet, not a new design. Preserve the 3:2 landscape canvas. Hard crisp pixel edges. White cat silhouette pixels must remain opaque and all surrounding charcoal pixels must become transparent. The dark square eyes must also be transparent cutouts rather than filled charcoal so each cat reads correctly when tinted for either light or dark macOS menu bars. No opaque black rectangle, no checkerboard painted into the image, no shadow, no added text, no rearrangement, no extra characters. Top row plump to bottom row thin, four run poses in each row. Do not simplify or redesign any cat.
