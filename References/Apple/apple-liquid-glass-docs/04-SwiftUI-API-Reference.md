# SwiftUI Liquid Glass API Reference

## glassEffect(_:in:)

Applies the Liquid Glass effect to a view.

Signature:

```swift
nonisolated func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
```

When you use this effect, the system:
- Renders a shape anchored behind a view with the Liquid Glass material.
- Applies the foreground effects of Liquid Glass over a view.

Example:

```swift
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect()
```

### Parameters

- **glass**: A `Glass` instance that configures the appearance of the Liquid Glass material. Default is `.regular`.
- **shape**: A `Shape` that defines the bounds of the glass effect. Default is a standard rounded rectangle shape.

### Return Value

A view with the Liquid Glass effect applied.

## Glass

A structure that defines the configuration of the Liquid Glass material.

```swift
struct Glass
```

### Variants

- `.regular` — The regular variant of the Liquid Glass material.
- `.tint(Color?)` — Returns a copy with a configured tint color. Passing `nil` removes the tint.
- `.interactive(Bool = true)` — Returns a copy configured to be interactive. Interactive glass responds to user input and hover states.

### Example

```swift
let blueGlass = Glass.tint(.blue)
let interactiveGlass = Glass.interactive(true)
let customGlass = Glass.tint(.purple).interactive(true)
```

## GlassEffectContainer

A view that combines multiple Liquid Glass shapes into a single shape that can morph individual shapes into one another.

```swift
@MainActor @preconcurrency struct GlassEffectContainer<Content> where Content : View
```

### Usage

Wrap multiple glass-effect views inside a `GlassEffectContainer` to optimize rendering and enable smooth morphing between shapes.

```swift
GlassEffectContainer {
    Text("First")
        .padding()
        .glassEffect()
    
    Text("Second")
        .padding()
        .glassEffect()
}
```

## GlassEffectTransition

A structure that describes changes to apply when a glass effect is added or removed.

### Transitions

- `.materialize` — Fades in content and animates in/out the glass material.

```swift
.animation(.easeInOut) {
    if showContent {
        Text("Content")
            .glassEffect()
            .transition(.glassMaterialize)
    }
}
```

- `.matchedGeometry` — Allows geometries to be derived from nearby shapes, enabling seamless transitions between views.

```swift
.transition(.glassMatchedGeometry(from: itemId, in: namespace))
```

## Glass Button Styles

SwiftUI provides a built-in glass button style:

```swift
Button("Action") { }
    .buttonStyle(.glass)
```

The glass button style renders the button with the Liquid Glass material, providing visual depth and the characteristic glass appearance.

## backgroundExtensionEffect()

Adds the background extension effect to mirror content under sidebars and inspectors.

```swift
func backgroundExtensionEffect() -> some View
```

This effect extends the visual content of a view into the background area, creating a seamless visual connection between content areas.

## Material (SwiftUI)

SwiftUI's `Material` types define the standard material appearances. The Liquid Glass design language uses these materials as the foundation for glass effects.

```swift
struct Material
```

Available material types:

- `Material.ultraThin` — The most translucent material variant.
- `Material.thin` — A highly translucent material.
- `Material.regular` — Standard material with balanced translucency.
- `Material.thick` — A minimally translucent material.
- `Material.ultraThick` — The least translucent material variant.
- `Material.bar` — A material optimized for bar backgrounds (tab bars, toolbars).

### Example

```swift
Rectangle()
    .fill(Material.regular)
    .frame(height: 200)
```

## GlassColor

Defines the color used to tint the glass effect background.

```swift
struct GlassColor
```

### Default Colors

- `.default` — The system default glass color.

## DefaultGlassEffectShape

The default shape used when no explicit shape is provided to `glassEffect(_:in:)`.

```swift
struct DefaultGlassEffectShape
```

This is typically a rounded rectangle with system-default corner radius.
