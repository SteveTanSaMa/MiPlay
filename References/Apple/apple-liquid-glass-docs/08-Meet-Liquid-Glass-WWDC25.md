# Meet Liquid Glass - WWDC25 Session 219

## Overview
Liquid Glass is a significant new step and evolution of the look and feel of Apple software. It introduces a flexible, dynamic layer to apps and system experiences across Apple's ecosystem of products.

It builds on learnings from Aqua (Mac OS X), iOS 7 realtime blurs, iPhone X fluidity, Dynamic Island, and visionOS. Liquid Glass is a new digital meta-material that dynamically bends and shapes light, behaving organically like a lightweight liquid.

## Core Properties

### Lensing
The primary way Liquid Glass visually defines itself. Lensing occurs naturally in the physical world - the warping and bending of light through transparent objects communicates presence, motion, and form. Liquid Glass dynamically bends, shapes, and concentrates light in real time, providing definition against background content while feeling lightweight and transparent.

### Responsive Motion
The material responds to interaction by instantly flexing and energizing with light. It has an inherent gel-like flexibility, moving in tandem with user interaction. Elements can lift up into Liquid Glass temporarily during interaction.

### Morphing
As users navigate between states, Liquid Glass dynamically morphs between controls, maintaining the concept of a singular floating plane. This makes transitions feel fluid and seamless.

## Adaptive Behavior
- **Context-aware**: Each layer continuously adapts based on what's behind it
- **Shadow dynamics**: Shadows become more prominent over text for legibility
- **Light/dark switching**: Can independently switch between light and dark
- **Size adaptation**: When glass morphs to larger sizes, it simulates thicker, more substantial material with richer shadows and more pronounced lensing

## Platform Integration
- Consistent design language across iPhone, iPad, and Mac
- On iPad/Mac, glass layers form a distinct functional layer for controls and navigation
- Glass controls nest perfectly into rounded corners of windows
- Floating sidebars enable new levels of immersion
- Sidebar and tab bar form a cohesive navigation language

## Scroll Edge Effects
Work in concert with Liquid Glass to maintain separation between UI and content layers:
- **Soft style**: Gentle dissolves content underneath
- **Hard style**: Uniform effect across pinned accessory views for extra separation

## Glass Variants

### Regular (most versatile)
- Full visual and adaptive effects
- Provides legibility regardless of context
- Works in any size, over any content
- Anything can be placed on top of it

### Clear
- Permanently more transparent
- No adaptive behaviors
- Needs a dimming layer for legibility
- Only use when: (1) over media-rich content, (2) content won't be negatively affected by dimming, (3) content above is bold and bright

## Legibility
- Small elements (navbars, tabbars) constantly adapt and flip light/dark
- Big elements (menus, sidebars) don't flip but adapt based on context
- Symbols/glyphs flip light/dark to maximize contrast
- Tinting uses a new technique that generates a range of tones mapped to content brightness

## Accessibility
- Reduced Transparency: Makes glass frostier
- Increased Contrast: Makes elements predominantly black/white with borders
- Reduced Motion: Decreases effect intensity, disables elastic properties
