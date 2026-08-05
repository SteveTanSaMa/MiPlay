# iOS/UIKit Liquid Glass API Reference (also applies to Mac Catalyst)

## UIGlassEffect (iOS 26+)
A visual effect that renders a glass material.
```swift
@MainActor class UIGlassEffect
```
Use with UIVisualEffectView to add Liquid Glass to UIKit views.

## UIGlassContainerEffect (iOS 26+)
Renders multiple glass elements into a combined effect.
```swift
@MainActor class UIGlassContainerEffect
```
When using UIGlassContainerEffect with a UIVisualEffectView, add individual glass elements by nesting UIVisualEffectViews configured with UIGlassEffect. The container renders all glass elements in one combined view.

## UIButton Configuration (Liquid Glass styles)
UIKit buttons support Liquid Glass styles:
```swift
UIButton.Configuration.glass()              // Standard glass button
UIButton.Configuration.prominentGlass()      // Prominent glass button
UIButton.Configuration.clearGlass()          // Clear glass button
UIButton.Configuration.prominentClearGlass() // Prominent clear glass button
```

## UIVisualEffectView (iOS 8+, legacy blur/vibrancy)
Base class for visual effects. Use with UIBlurEffect or UIVibrancyEffect for traditional blur effects.

```swift
@MainActor class UIVisualEffectView
```

Key properties:
- `contentView` - Add subviews here, not directly to the effect view
- `effect` - The visual effect (UIVisualEffect)

Important: Avoid alpha values less than 1 on UIVisualEffectView. For snapshot, capture the entire UIWindow/UIScreen.

## UIBlurEffect
```swift
@MainActor class UIBlurEffect
init(style: UIBlurEffect.Style)
```

## UIVibrancyEffect
```swift
@MainActor class UIVibrancyEffect
init(forBlurEffect: UIBlurEffect, style: UIVibrancyEffectStyle)
```

## SwiftUI View Modifiers for Liquid Glass
```swift
func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
func backgroundExtensionEffect() -> some View
```

## SwiftUI Button Styles
```swift
Button("Action") { }.buttonStyle(.glass)          // GlassButtonStyle
Button("Action") { }.buttonStyle(.glassProminent) // GlassProminentButtonStyle
```

## GlassButtonStyle
A button style that applies glass border artwork based on context.

## GlassProminentButtonStyle
A button style that applies prominent glass border artwork based on context.
