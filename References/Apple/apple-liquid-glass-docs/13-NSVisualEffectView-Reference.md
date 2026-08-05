# NSVisualEffectView Complete Reference (macOS 10.10+)

While Liquid Glass is the new standard (NSGlassEffectView, macOS 26+), NSVisualEffectView remains available for backward compatibility.

## Class
```swift
@MainActor class NSVisualEffectView
```

## Overview
A view that adds translucency and vibrancy effects to your interface. Use primarily as background views.

Effects:
- **Translucency** and blurring of background content
- **Vibrancy** - subtle blending of foreground and background colors

## Materials (NSVisualEffectView.Material)
| Material | Description |
|----------|-------------|
| `.titlebar` | Window's titlebar |
| `.selection` | Selection indication |
| `.menu` | Menus |
| `.popover` | Popover backgrounds |
| `.sidebar` | Window sidebar backgrounds |
| `.headerView` | In-line header/footer views |
| `.sheet` | Sheet window backgrounds |
| `.windowBackground` | Opaque window backgrounds |
| `.hudWindow` | HUD window backgrounds |
| `.fullScreenUI` | Full-screen modal interface |
| `.toolTip` | Tool tip backgrounds |
| `.contentBackground` | Opaque content backgrounds |
| `.underWindowBackground` | Under window background |
| `.underPageBackground` | Behind document pages |

## Blending Modes
| Mode | Description |
|------|-------------|
| `.behindWindow` | Blends with content behind the window (desktop, other windows) |
| `.withinWindow` | Blends with content within the same window only |

## Key Properties
- `material` - The material shown by the visual effect view
- `blendingMode` - Behind-window or within-window blending
- `isEmphasized` - Whether to emphasize the look of the material
- `state` - Whether a view has a visual effect applied (.followsWindowActiveState, .active, .inactive)
- `maskImage` - An image whose alpha channel masks the visual effect

## Vibrancy
For custom views, enable vibrancy by overriding allowsVibrancy to return true.
Use built-in colors (labelColor, secondaryLabelColor, etc.) for best results.
AppKit views and controls add vibrancy automatically where appropriate.

## Subclassing Notes
- Always call super in viewDidMoveToWindow() and viewWillMove(toWindow:)
- Do NOT override draw(_:) or updateLayer()
