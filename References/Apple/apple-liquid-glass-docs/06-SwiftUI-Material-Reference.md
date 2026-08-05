# SwiftUI Material Reference

## Material

A material is a visual style that adds translucency and vibrancy to a view. Materials in SwiftUI provide the foundation for the Liquid Glass design language, allowing you to create backgrounds that blend with the content behind them.

```swift
struct Material
```

### Material Types

SwiftUI provides six built-in material types, ranging from most translucent to least translucent:

| Material | Translucency | Use Case |
|----------|-------------|----------|
| `.ultraThinMaterial` | Highest | Subtle backgrounds, overlay hints, temporary UI |
| `.thinMaterial` | High | Floating panels, secondary content, tooltips |
| `.regularMaterial` | Medium | Standard backgrounds, card views, section headers |
| `.thickMaterial` | Low | Primary content areas, navigation bars, sidebars |
| `.ultraThickMaterial` | Lowest | Heavy backgrounds that need to remain readable |
| `.barMaterial` | Medium (optimized) | Tab bars, toolbar backgrounds, navigation bars |

### Usage

Apply a material as a view background using the `.fill()` modifier or as a background modifier:

```swift
import SwiftUI

struct MaterialExamples: View {
    var body: some View {
        ZStack {
            // Background content
            LinearGradient(
                colors: [.blue, .purple, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Ultra Thin Material
                Text("Ultra Thin Material")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                
                // Thin Material
                Text("Thin Material")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
                
                // Regular Material
                Text("Regular Material")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                
                // Thick Material
                Text("Thick Material")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thickMaterial)
                
                // Ultra Thick Material
                Text("Ultra Thick Material")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.ultraThickMaterial)
            }
            .padding()
        }
    }
}
```

### Material with Shapes

Apply materials to shape fills:

```swift
RoundedRectangle(cornerRadius: 16)
    .fill(.regularMaterial)
    .frame(width: 200, height: 100)

Circle()
    .fill(.thinMaterial)
    .frame(width: 80, height: 80)
```

### Material as Overlay

Use materials as overlays to create frosted-glass effects:

```swift
Image("background")
    .resizable()
    .aspectRatio(contentMode: .fill)
    .overlay {
        VStack {
            Text("Overlay Content")
                .font(.title)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
```

### Material in List and Form Backgrounds

```swift
List {
    Section("Section One") {
        Text("Item 1")
        Text("Item 2")
    }
    Section("Section Two") {
        Text("Item 3")
    }
}
.listRowBackground(.thinMaterial)
```

### Material with glassEffect

Materials serve as the foundation for the Liquid Glass `glassEffect` modifier. When you apply `.glassEffect()`, the system uses material rendering internally:

```swift
Text("Liquid Glass")
    .font(.title)
    .padding()
    .glassEffect()
```

### Material with Background Styles

The `.background(_:in:fillStyle:)` modifier accepts materials:

```swift
Text("Styled Background")
    .font(.headline)
    .foregroundStyle(.primary)
    .padding()
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
```

### Accessibility and Materials

When using materials, consider accessibility:

- Materials automatically support **Dynamic Type** and **Increased Contrast** settings.
- In **accessibility mode**, materials may become more opaque to improve readability.
- Test your interface with **Reduce Transparency** enabled to ensure content remains legible.
- Use `.foregroundStyle(.primary)` or `.foregroundStyle(.secondary)` for text on materials to ensure proper contrast.

```swift
Text("Accessible Label")
    .font(.body)
    .foregroundStyle(.primary)  // Adapts to material contrast
    .padding()
    .background(.ultraThickMaterial)  // More opaque for readability
```

### Platform-Specific Material Behavior

| Platform | Material Support | Notes |
|----------|-----------------|-------|
| iOS 15+ | Full | All six material types available |
| iPadOS 15+ | Full | Same as iOS |
| macOS 11+ | Full | All material types work in AppKit interop |
| watchOS 8+ | Limited | Materials available but more subtle |
| tvOS 15+ | Limited | Materials adapted for focus-based UI |
| visionOS 1+ | Full | Materials integrate with spatial rendering |

### Materials vs. GlassEffect

While `Material` provides the foundation for translucent backgrounds, the `glassEffect` modifier adds the complete Liquid Glass visual treatment including:

- Enhanced blur and color processing
- Dynamic foreground effects
- Interactive state handling
- Shape-based rendering optimization
- Transition support (materialize, matched geometry)

Use `Material` directly when you need lightweight translucency without the full Liquid Glass treatment. Use `glassEffect` when you want the complete Liquid Glass experience.

### Deprecated Material Syntax

Older SwiftUI versions used different syntax for materials:

```swift
// Deprecated (but still works)
Rectangle()
    .fill(Color(.systemUltraThinMaterial))

// Current
Rectangle()
    .fill(.ultraThinMaterial)
```

The modern syntax uses the material as a first-class value, which provides better type safety and integration with the SwiftUI rendering system.
