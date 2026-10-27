# GroundKeeper app icon

The icon uses the Folded Ledger concept: a brass top page and charcoal lower
ledger on a warm ivory tile, without a wordmark. The app uses the same artwork
in light and dark appearances.

The master is `apps/macos/GroundKeeper/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`.
The asset catalog includes every standard macOS size from 16 to 1024 pixels.
Debug and Release both select `AppIcon`.

## Generation

Created with the built-in imagegen tool from the selected Folded Ledger concept.
The export normalizes the canvas to 1024 pixels, clips the tile to a clean rounded
outline, and downsamples the master for the remaining sizes.

Prompt set:

### 1

```text
Use case: precise-object-edit.
Asset type: production macOS app icon, a single square high-resolution icon.
Input image 1 is the edit target: the "02 / Folded Ledger" GroundKeeper presentation board.
Primary request: Extract and preserve ONLY the large two-color folded-ledger symbol near the upper middle of the board. Preserve its exact distinctive geometry: the sloping brass quadrilateral top page, the charcoal left upright plane flowing into the rounded charcoal horizontal G-shaped lower page, the ivory negative-space channel separating the planes. Use the LARGE symbol's colors, NOT either small supporting version. Charcoal approximately #22262B, muted brass approximately #806021, warm ivory background approximately #F3F1EC. Match the reference's warm neutral palette.
Remove ALL text, ALL typography, the heading, the wordmark, and both smaller supporting marks. The finished image has one symbol only.
Center the isolated symbol, preserving its proportions, on a solid warm ivory macOS squircle tile. Icon composition on a square 1024x1024 canvas: tile extends approximately from (100,100) to (924,924), with smooth continuous rounded corners of approximately 180px radius. Transparent canvas outside the ivory tile. The symbol is approximately 585px wide and 470px tall, visually centered within the tile, with generous consistent padding. No border. No shadow. No gradients or texture; flatten all three fills to clean solid colors while preserving antialiased crisp contours. No perspective added to the tile. The icon is front-facing. Keep the folded symbol's existing shape and page angles identical to the reference, do not invent or redesign it.
Constraints: exactly one ivory tile and one two-color charcoal-and-brass ledger mark. No letters other than the abstract G already formed by the mark, no words, labels, numbers, font, badge, ornamental shapes, metallic lighting or watermark. Truly transparent exterior corners.
```

### 2

```text
Use case: precise-object-edit. Input image is the edit target, the finished GroundKeeper folded-ledger app icon.
Make exactly one correction: clean the transparency boundary and exterior of the ivory rounded square tile. There are unwanted stray white flecks and rough pixels around the tile in the current image. Remove every stray fleck, speck, fringe, rough edge and detached pixel. Everything outside the exact clean smooth ivory rounded square must be fully transparent alpha zero. The tile boundary must be a perfectly smooth geometric rounded rectangle with clean antialiasing and no halo. Keep the warm ivory tile interior, all colors, the centered brass top fold and charcoal G-ledger symbol, and the symbol's size and proportions unchanged. Do not add any text, font, border, shadow, new elements, texture or light effects. Deliver one pristine production macOS app icon on a transparent square canvas.
```

