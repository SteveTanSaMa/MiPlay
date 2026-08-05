# Creating Your App Icon Using Icon Composer

Icon Composer creates a single multilayer file (.icn) for Liquid Glass app icons across iOS, iPadOS, macOS, watchOS.

## Design Guidelines
- Use SVG format for scalability; convert text to outlines
- Design in layers (back to front in z-plane)
- Remove blurs, shadows, opacity, translucency from source art
- Remove background colors/gradients (apply in Icon Composer)
- Canvas size: 1024x1024px (iPhone/iPad/Mac), 1088x1088px (Apple Watch)

## Layer Organization
- Maximum 4 groups (become the rendered layers)
- System renders layers from bottom to top in sidebar order
- Groups allow common settings across multiple layers
- Layers can be hidden/shown using eye icons

## Liquid Glass Effects in Icon Composer
- **Mode**: Individual (per-layer) or Combined (group as one object)
- **Specular**: On by default; toggling off removes background blur and edge highlights
- **Blur, Translucency, Shadow**: Adjustable settings per group

## Preview Variants
- Platforms: iOS, macOS, watchOS
- Appearances: Default (light), Dark, Mono (clear/tinted)
- Simulate device backgrounds, lighting angles, and grid lines

## App Icon Variants
iOS/iPadOS/macOS: Default, Dark, Clear (Light), Clear (Dark), Tinted (Light), Tinted (Dark)

## Color Settings
- Fill options: None, Solid, Gradient (per layer or group)
- Opacity control for transparency
- Customize per platform/appearance variant

## Workflow
1. Export layers from vector tool (SVG preferred)
2. Drag into Icon Composer sidebar
3. Organize into groups (max 4)
4. Apply Liquid Glass settings
5. Preview all platform/appearance variants
6. Save .icn file
7. Add to Xcode project (replaces AppIcon asset catalog)

## Key Resources
- Apple Design Resources: https://developer.apple.com/design/resources/
- WWDC 2025 Session 220: "Say hello to the new look of app icons"
- WWDC 2025 Session 361: "Create icons with Icon Composer"
- HIG: Human Interface Guidelines > Foundations > App icons
