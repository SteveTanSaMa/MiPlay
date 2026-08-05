# Applying Liquid Glass to Custom Views

Learn how to apply Liquid Glass effects to your custom views and create engaging interfaces.

## Overview

Standard SwiftUI, UIKit, and AppKit controls automatically adopt the Liquid Glass appearance when built with the latest Xcode and SDK. However, if you build custom views or design unique layouts, you can apply Liquid Glass effects directly using the appropriate APIs.

Apply Liquid Glass to custom views in three main ways:

1. **Use the `glassEffect(_:in:)` modifier** (SwiftUI) — Apply the effect to individual views.
2. **Use `GlassEffectContainer`** (SwiftUI) — Combine multiple glass shapes into a single morphable shape.
3. **Use visual effect views** (UIKit/AppKit) — Apply blur and material effects through the respective framework APIs.

## Apply and Configure Liquid Glass Effects

The `glassEffect(_:in:)` modifier renders a shape anchored behind a view with the Liquid Glass material and applies the foreground effects over the view.

### Basic Usage

Apply the default Liquid Glass effect to any view:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Hello, Liquid Glass!")
            .font(.largeTitle)
            .foregroundStyle(.white)
            .padding()
            .glassEffect()
    }
}
```

When you use this modifier, the system creates a default rounded rectangle shape behind your view and applies the Liquid Glass material with the `.regular` variant.

### Customizing the Glass Variant

You can customize the glass appearance using the `Glass` structure:

```swift
import SwiftUI

struct CustomGlassView: View {
    var body: some View {
        VStack(spacing: 20) {
            // Regular glass effect
            Text("Regular")
                .padding()
                .glassEffect(.regular)
            
            // Tinted glass effect
            Text("Tinted")
                .padding()
                .glassEffect(Glass.tint(.blue))
            
            // Interactive glass effect
            Text("Interactive")
                .padding()
                .glassEffect(Glass.interactive(true))
        }
    }
}
```

### Custom Shape for the Glass Effect

You can provide a custom shape that defines the bounds of the glass effect:

```swift
import SwiftUI

struct CustomShapeGlassView: View {
    var body: some View {
        Text("Custom Shape")
            .font(.headline)
            .foregroundStyle(.white)
            .padding()
            .glassEffect(in: Circle())
    }
}
```

The system uses the provided shape to both mask the glass material and determine the hit-testing region.

### Full Configuration Example

Combine custom shape, tint, and interactivity:

```swift
import SwiftUI

struct FullConfigExample: View {
    var body: some View {
        VStack(spacing: 16) {
            // Rounded rectangle with blue tint
            Text("Profile")
                .font(.title2)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .glassEffect(
                    Glass.tint(.blue).interactive(true),
                    in: RoundedRectangle(cornerRadius: 16)
                )
            
            // Circular glass effect
            Image(systemName: "star.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
                .padding(24)
                .glassEffect(in: Circle())
            
            // Large pill shape
            Text("Subscribe")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .glassEffect(
                    Glass.tint(.purple),
                    in: Capsule()
                )
        }
    }
}
```

## Combine Multiple Views with Liquid Glass Containers

`GlassEffectContainer` is a container view that combines multiple Liquid Glass shapes into a single shape that can morph individual shapes into one another. This is useful when you have several glass elements that need to animate smoothly between states.

### Basic Container

```swift
import SwiftUI

struct GlassContainerExample: View {
    var body: some View {
        GlassEffectContainer {
            Text("Item 1")
                .padding()
                .glassEffect()
            
            Text("Item 2")
                .padding()
                .glassEffect()
            
            Text("Item 3")
                .padding()
                .glassEffect()
        }
    }
}
```

### Animated Container with State Changes

```swift
import SwiftUI

struct AnimatedGlassContainer: View {
    @State private var selectedIndex: Int = 0
    
    let items = ["Explore", "Library", "Playlists", "Search"]
    
    var body: some View {
        GlassEffectContainer {
            ForEach(items.indices, id: \.self) { index in
                Text(items[index])
                    .font(.subheadline)
                    .foregroundStyle(selectedIndex == index ? .white : .secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .glassEffect(
                        Glass.tint(selectedIndex == index ? .accentColor : .gray)
                            .interactive(true),
                        in: Capsule()
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            selectedIndex = index
                        }
                    }
            }
        }
    }
}
```

### Container with Morphing Geometry

The `GlassEffectContainer` automatically handles morphing between shapes when the underlying geometries change. This allows smooth transitions when items are added, removed, or repositioned:

```swift
import SwiftUI

struct MorphingGlassExample: View {
    @State private var expanded = false
    
    var body: some View {
        VStack {
            GlassEffectContainer {
                if expanded {
                    VStack(spacing: 8) {
                        Text("Title")
                            .font(.headline)
                        Text("Description text that appears when expanded")
                            .font(.caption)
                    }
                    .padding()
                    .glassEffect(in: RoundedRectangle(cornerRadius: 20))
                } else {
                    Text("Tap to expand")
                        .padding()
                        .glassEffect(in: Capsule())
                }
            }
            
            Button("Toggle") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            }
        }
        .padding()
    }
}
```

## Morph Liquid Glass Effects During Transitions

`GlassEffectTransition` describes changes to apply when a glass effect is added or removed from the view hierarchy. Use transitions to create smooth entrances and exits for glass-effect views.

### Materialize Transition

The `.materialize` transition fades in content and animates in/out the glass material:

```swift
import SwiftUI

struct MaterializeExample: View {
    @State private var showContent = false
    
    var body: some View {
        VStack {
            Button("Toggle") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showContent.toggle()
                }
            }
            
            if showContent {
                Text("Appearing Content")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
                    .glassEffect()
                    .transition(.glassMaterialize)
            }
        }
    }
}
```

### Matched Geometry Transition

The `.matchedGeometry` transition allows geometries to be derived from nearby shapes, enabling seamless transitions between different views:

```swift
import SwiftUI

struct MatchedGeometryExample: View {
    @Namespace private var animation
    @State private var selectedItem: Item? = nil
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
                ForEach(items) { item in
                    ItemCell(item: item)
                        .matchedTransitionSource(id: item.id, in: animation)
                        .glassEffect()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35)) {
                                selectedItem = item
                            }
                        }
                }
            }
        }
        .overlay {
            if let item = selectedItem {
                ItemDetailView(item: item)
                    .glassEffect()
                    .transition(.glassMatchedGeometry(from: item.id, in: animation))
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35)) {
                            selectedItem = nil
                        }
                    }
            }
        }
    }
}
```

### Custom Transitions

You can combine transitions with other SwiftUI transition types:

```swift
// Combined transition
AnyTransition
    .glassMaterialize
    .combined(with: .scale(scale: 0.9))
```

## Optimize Performance

Liquid Glass effects use GPU-accelerated rendering and are designed to be performant. However, there are best practices to follow to ensure smooth performance:

### Best Practices

1. **Limit the number of glass-effect views on screen simultaneously.**
   While Liquid Glass is efficient, rendering many glass surfaces at once can impact performance. Group related items inside a `GlassEffectContainer` rather than using individual `glassEffect` modifiers on each element.

2. **Use appropriate shapes.**
   Simple shapes like `RoundedRectangle` and `Capsule` are more performant than complex custom paths. Use `GlassEffectContainer` to merge nearby shapes into a single rendering pass.

3. **Avoid excessive animation of glass properties.**
   While morphing and transitions are optimized, animating the position and size of many glass views simultaneously can create layout passes. Use `GlassEffectContainer` to batch geometry changes.

4. **Test on target devices.**
   Performance characteristics vary across devices. Always test the glass effects on the oldest devices you support.

5. **Use Instruments for profiling.**
   Use the GPU and rendering instruments in Xcode to identify performance bottlenecks:

   - Open Instruments from Xcode (Product > Profile or Cmd+I).
   - Select the GPU Trace template.
   - Look for tile and renderer utilization.
   - Identify views that cause off-screen rendering passes.

6. **Prefer `.glassEffect()` over manual visual effect views when possible.**
   The native modifier is highly optimized. Only drop down to `UIVisualEffectView` or `NSVisualEffectView` when you need specific behaviors not covered by the SwiftUI API.

### Performance Comparison

| Approach | Performance | Use Case |
|----------|-------------|----------|
| `glassEffect()` | Best | Most custom views |
| `GlassEffectContainer` | Best for multiple items | Lists, grids, tab-like interfaces |
| `UIVisualEffectView` | Good | UIKit interop |
| `NSGlassEffectView` | Good | AppKit (macOS 26+) |
| `NSVisualEffectView` | Good | AppKit (older macOS) |

### Debugging Tips

- Use the `_debugBody` view modifier or the SwiftUI inspector in Xcode to inspect the view hierarchy.
- Check for warning symbols in the Xcode canvas that indicate off-screen rendering.
- On macOS, use the Quartz Debug tool to visualize screen updates and compositing.
- On iOS, use the Color Blended Layers and Color Offscreen-Rendered instruments in the simulator's Debug menu.
