# Landmarks: Building an app with Liquid Glass

Landmarks is a SwiftUI app demonstrating Liquid Glass, running on iPad, iPhone, and Mac.

## Key Concepts Demonstrated

1. **Background Extension Effect** - Stretching content behind sidebar/inspector
2. **Horizontal Scroll Extension** - Extending scroll views under sidebar/inspector
3. **System Toolbar Glass** - Leveraging system-provided glass effect in toolbars
4. **Custom Glass Effects** - Applying Liquid Glass to custom elements and animations
5. **Icon Composer** - Building a new app icon with layered design

## Background Extension Effect

Apply `backgroundExtensionEffect()` to an image to blur and extend it under sidebar/inspector:

```swift
Image(landmark.backgroundImageName)
    .backgroundExtensionEffect()
```

The system takes a section of the image matching the sidebar width, flips it horizontally, applies a blur, and places it under the sidebar.

## Toolbar Organization

Use `ToolbarSpacer(.fixed)` to group toolbar items logically:

```swift
.toolbar {
    ToolbarSpacer(.flexible)
    ToolbarItem { ShareLink(item: landmark, preview: landmark.sharePreview) }
    ToolbarSpacer(.fixed)
    ToolbarItemGroup {
        LandmarkFavoriteButton(landmark: landmark)
        LandmarkCollectionsMenu(landmark: landmark)
    }
    ToolbarSpacer(.fixed)
    ToolbarItem { Button("Info", systemImage: "info") { ... } }
}
```

## Custom Badges with Liquid Glass

Apply glass effect to badges and use GlassEffectContainer for morphing animations:

```swift
GlassEffectContainer(spacing: Constants.badgeGlassSpacing) {
    VStack {
        if isExpanded {
            ForEach(modelData.earnedBadges) {
                BadgeLabel(badge: $0)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .glassEffectID($0.id, in: namespace)
            }
        }
        Button { withAnimation { isExpanded.toggle() } }
            label: { ToggleBadgesLabel(isExpanded: isExpanded) }
            .buttonStyle(.glass)
            .glassEffectID("togglebutton", in: namespace)
    }
}
```

## Horizontal Scroll Extension

Configure scroll view to touch leading and trailing edges for automatic sidebar/inspector extension.
