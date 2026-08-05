# macOS AppKit Liquid Glass & Visual Effects API Reference

## NSGlassEffectView (macOS 26+)

A view that embeds its content view in a dynamic glass effect.

```swift
class NSGlassEffectView
```

This is the native AppKit view for Liquid Glass effects on macOS. It provides the full Liquid Glass material appearance optimized for desktop interfaces.

### Properties

- **style: GlassStyle** — The style of glass this view uses. Determines the overall visual appearance including blur intensity and material behavior.
- **glassColor: GlassColor** — The color used to tint the background and glass effect. Allows customization of the glass tint to match your app's aesthetic.

### Example

```swift
import AppKit

let glassView = NSGlassEffectView(frame: view.bounds)
glassView.style = .regular
glassView.glassColor = .default
glassView.autoresizingMask = [.width, .height]
parentView.addSubview(glassView, positioned: .below, relativeTo: nil)
```

### GlassStyle

Styles available for `NSGlassEffectView`:

- `.regular` — Standard Liquid Glass appearance with balanced translucency.
- `.prominent` — More pronounced glass effect with stronger blur.
- `.subtle` — A lighter glass effect with minimal blur.

### GlassColor

- `.default` — System default glass color.
- You can create custom colors using the designated initializer (if available).

## NSVisualEffectView (macOS 10.10+)

A view that adds translucency and vibrancy effects to views.

### Overview

Use visual effect views primarily as background views. Effects include:
- Translucency and blurring of background content.
- Vibrancy — subtle blending of foreground and background colors, making foreground content appear more vibrant against the blurred background.

### Key Properties

- **material: Material** — The material shown by the visual effect view. Determines the visual style and transparency level.
- **blendingMode: BlendingMode** — Whether the effect blends with content behind or within the window.
- **isEmphasized: Bool** — Whether to emphasize the look of the material. When true, the material appears more prominent.
- **state: State** — Whether the view currently has a visual effect applied. Controls the active state of the effect.
- **maskImage: NSImage?** — An image whose alpha channel masks the effect. Non-transparent areas of the mask image show the effect; transparent areas hide it.

### State Values

```swift
NSVisualEffectView.State.followsWindowActiveState  // Effect updates based on window activation
NSVisualEffectView.State.active                     // Effect is always active
NSVisualEffectView.State.inactive                   // Effect is always inactive
```

### Materials

- `.titlebar` — Material for a window's titlebar area.
- `.selection` — Material for selection indication, such as selected rows in a table.
- `.menu` — Material for menus and menu items.
- `.popover` — Material for popover windows.
- `.sidebar` — Material for window sidebars.
- `.headerView` — Material for in-line header or footer views.
- `.sheet` — Material for sheet windows attached to a parent window.
- `.windowBackground` — Material for opaque window backgrounds.
- `.hudWindow` — Material for HUD (Heads-Up Display) windows.
- `.fullScreenUI` — Material for full-screen modal interface overlays.
- `.toolTip` — Material for tool tip windows.
- `.contentBackground` — Material for opaque content backgrounds.
- `.underWindowBackground` — Material under a window's background area.
- `.underPageBackground` — Material behind pages of a document (e.g., in a paginated layout).

### Blending Modes

- `.behindWindow` — Blends with content behind the window. The effect shows content from other windows and the desktop.
- `.withinWindow` — Blends with content within the window only. The effect shows content below the visual effect view within the same window.

### Example Usage

```swift
import AppKit

class ViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        
        // Create a sidebar with visual effect
        let sidebar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        
        // Add content label
        let label = NSTextField(labelWithString: "Sidebar Content")
        label.frame = NSRect(x: 20, y: 140, width: 160, height: 20)
        sidebar.addSubview(label)
        
        view.addSubview(sidebar)
    }
}
```

### Subclassing Notes

- Always call `super` in `viewDidMoveToWindow()` and `viewWillMove(toWindow:)` to ensure proper behavior.
- Do **not** override `draw(_:)` or `updateLayer()`. The visual effect view manages its own layer and drawing; overriding these methods can break the visual effect rendering.

```swift
class CustomVisualEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()  // Required
        // Custom setup after moving to a window
    }
    
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)  // Required
        // Custom setup before moving to a new window
    }
    
    // Do NOT override draw(_:) or updateLayer()
}
```

## Comparison: NSGlassEffectView vs NSVisualEffectView

| Feature | NSGlassEffectView (macOS 26+) | NSVisualEffectView (macOS 10.10+) |
|---------|-------------------------------|------------------------------------|
| Liquid Glass support | Full | Partial (uses materials) |
| Minimum OS | macOS 26 | macOS 10.10 |
| Glass customization | GlassStyle, GlassColor | Material, blendingMode |
| Performance | Optimized for Liquid Glass | General-purpose blur |
| Animations | Built-in morphing support | Manual animation needed |
