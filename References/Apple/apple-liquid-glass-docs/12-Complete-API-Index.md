# Complete Liquid Glass API Index

## SwiftUI APIs
| API | Description | Availability |
|-----|-------------|-------------|
| `glassEffect(_:in:)` | Apply Liquid Glass to a view | All platforms 26+ |
| `Glass` | Configuration structure for Liquid Glass | All platforms 26+ |
| `.regular` | Standard glass variant | All platforms 26+ |
| `.tint(Color?)` | Add tint color | All platforms 26+ |
| `.interactive(Bool)` | Make interactive | All platforms 26+ |
| `GlassEffectContainer` | Combine multiple glass shapes | All platforms 26+ |
| `GlassEffectTransition` | Transition animations | All platforms 26+ |
| `.materialize` | Fade in/out glass | All platforms 26+ |
| `.matchedGeometry` | Match geometry transition | All platforms 26+ |
| `glassEffectID(_:in:)` | ID for morph animations | All platforms 26+ |
| `glassEffectUnion(id:namespace:)` | Unify multiple effects | All platforms 26+ |
| `GlassButtonStyle` / `.glass` | Glass button style | All platforms 26+ |
| `GlassProminentButtonStyle` / `.glassProminent` | Prominent glass button | All platforms 26+ |
| `backgroundExtensionEffect()` | Extend content under sidebar | All platforms 26+ |
| `Material` (`.ultraThin`, `.thin`, `.regular`, `.thick`, `.ultraThick`, `.bar`) | Blur materials | iOS 15+/macOS 12+ |

## AppKit (macOS) APIs
| API | Description | Availability |
|-----|-------------|-------------|
| `NSGlassEffectView` | Native Liquid Glass view | macOS 26+ |
| `.glassColor` | Tint color for glass | macOS 26+ |
| `.style` | Glass style | macOS 26+ |
| `NSVisualEffectView` | Legacy blur/vibrancy view | macOS 10.10+ |
| `.material` (`.titlebar`, `.sidebar`, `.popover`, `.menu`, `.sheet`, `.windowBackground`, etc.) | Material type | macOS 10.10+ |
| `.blendingMode` (`.behindWindow`, `.withinWindow`) | Blending mode | macOS 10.10+ |
| NSButton.BezelStyle.glass | AppKit glass button | macOS 26+ |

## UIKit (iOS/Mac Catalyst) APIs
| API | Description | Availability |
|-----|-------------|-------------|
| `UIGlassEffect` | UIKit glass effect | iOS 26+ |
| `UIGlassContainerEffect` | Combined glass rendering | iOS 26+ |
| `UIVisualEffectView` | Legacy visual effects | iOS 8+ |
| `UIBlurEffect` | Legacy blur effect | iOS 8+ |
| `UIVibrancyEffect` | Legacy vibrancy effect | iOS 8+ |
| `UIButton.Configuration.glass()` | UIKit glass button | iOS 26+ |
| `UIButton.Configuration.prominentGlass()` | Prominent glass button | iOS 26+ |
| `UIButton.Configuration.clearGlass()` | Clear glass button | iOS 26+ |
| `UIButton.Configuration.prominentClearGlass()` | Prominent clear button | iOS 26+ |

## WWDC Sessions
| Session | Title | Year |
|---------|-------|------|
| 219 | Meet Liquid Glass | WWDC 2025 |
| 220 | Say hello to the new look of app icons | WWDC 2025 |
| 284 | (Liquid Glass related) | WWDC 2025 |
| 306 | Optimize SwiftUI performance with Instruments | WWDC 2025 |
| 310 | (Liquid Glass related) | WWDC 2025 |
| 323 | (Liquid Glass related) | WWDC 2025 |
| 356 | (Liquid Glass related) | WWDC 2025 |
| 361 | Create icons with Icon Composer | WWDC 2025 |
| - | Build an AppKit app with the new design | WWDC 2025 |
| - | Build a SwiftUI app with the new design | WWDC 2025 |
| - | Build a UIKit app with the new design | WWDC 2025 |
| - | Modernize your AppKit app | WWDC 2026 |

## Design Resources
- Apple Design Resources: https://developer.apple.com/design/resources/
- Human Interface Guidelines: https://developer.apple.com/design/human-interface-guidelines/
- HIG > Materials
- HIG > App Icons
