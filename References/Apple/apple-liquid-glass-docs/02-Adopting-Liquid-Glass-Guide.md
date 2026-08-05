# Adopting Liquid Glass

Learn how to adopt Liquid Glass in your app and embrace the design principles of Apple platforms.

## Overview

If you have an existing app, adopting Liquid Glass doesn't mean reinventing your app from the ground up. Start by building your app in the latest version of Xcode to see the changes. Then, follow the best practices in this guide to help your app look right at home on Apple platforms.

The Liquid Glass material is automatically applied to standard system components. By following the guidance in this document, you can ensure your app benefits from the full visual and behavioral refresh that Liquid Glass brings.

## Visual Refresh

Liquid Glass introduces a comprehensive visual refresh across all Apple platforms. This refresh touches every part of the system interface:

- **Materials** — Windows, sidebars, menus, sheets, and popovers automatically adopt the Liquid Glass material, providing a consistent translucent appearance.
- **Controls** — Buttons, sliders, toggles, pickers, and other controls receive updated styling that complements the Liquid Glass aesthetic.
- **App Icons** — App icons adopt a new layered design language with bold, simple shapes.

The system applies these updates automatically when you build your app with the latest Xcode and target the appropriate SDK version. No code changes are required to get the basic visual refresh.

### Custom Views

For custom views, you can apply Liquid Glass effects using the following APIs:

- **SwiftUI**: Use the `glassEffect(_:in:)` modifier or `GlassEffectContainer` for complex layouts.
- **UIKit**: Use `UIVisualEffectView` with the appropriate `UIBlurEffect.Style`.
- **AppKit**: Use `NSGlassEffectView` (macOS 26+) or `NSVisualEffectView` with the appropriate material.

## App Icons

Reimagine your app icon with simple, bold layers. The Liquid Glass design language emphasizes clarity and recognizability through minimal, well-defined shapes.

### Best Practices

- **Use simple shapes** — Bold, uncomplicated silhouettes read well at all sizes.
- **Limit the number of layers** — Two to three layers of depth is ideal.
- **Avoid text** — Text in app icons is difficult to read at small sizes and doesn't localize.
- **Provide all necessary sizes** — Ensure your icon assets include all required resolutions.

### Creating App Icons

Use the App Icon asset catalog in Xcode to supply your icons. The system renders them with the appropriate corner radius and visual treatment automatically.

```swift
// No code changes needed — supply assets in the asset catalog
// The system applies the Liquid Glass styling to the icon
```

## Controls

Standard controls adopt the Liquid Glass appearance automatically. The following sections describe how to use controls effectively across frameworks.

### SwiftUI Controls

SwiftUI controls automatically inherit the Liquid Glass appearance when built with the latest SDK.

```swift
// Standard SwiftUI controls with Liquid Glass appearance
Button("Submit") {
    // Action
}
.buttonStyle(.borderedProminent)

Slider(value: $value, in: 0...100)

Toggle("Enable Feature", isOn: $isEnabled)

Picker("Size", selection: $size) {
    Text("Small").tag(Size.small)
    Text("Medium").tag(Size.medium)
    Text("Large").tag(Size.large)
}
.pickerStyle(.menu)
```

For a glass-specific button style, use the `.glass` button style:

```swift
Button("Glass Action") {
    // Action
}
.buttonStyle(.glass)
```

### UIKit Controls

UIKit controls automatically adopt the updated appearance. The system provides `UIVisualEffectView` for custom visual effects.

```swift
import UIKit

let blurEffect = UIBlurEffect(style: .systemMaterial)
let visualEffectView = UIVisualEffectView(effect: blurEffect)
visualEffectView.frame = view.bounds
visualEffectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
view.addSubview(visualEffectView)
```

Available blur effect styles:

```swift
UIBlurEffect.Style.systemMaterial
UIBlurEffect.Style.systemUltraThinMaterial
UIBlurEffect.Style.systemThinMaterial
UIBlurEffect.Style.systemThickMaterial
UIBlurEffect.Style.systemChromeMaterial
UIBlurEffect.Style.systemUltraThickMaterial
```

### AppKit Controls

AppKit controls update automatically. For custom effects, use `NSVisualEffectView` or the new `NSGlassEffectView` on macOS 26+.

```swift
import AppKit

let visualEffectView = NSVisualEffectView(frame: view.bounds)
visualEffectView.material = .sidebar
visualEffectView.blendingMode = .behindWindow
visualEffectView.state = .active
view.addSubview(visualEffectView, positioned: .below, relativeTo: nil)
```

For Liquid Glass on macOS 26+:

```swift
import AppKit

let glassView = NSGlassEffectView(frame: view.bounds)
glassView.style = .regular
glassView.glassColor = .default
view.addSubview(glassView, positioned: .below, relativeTo: nil)
```

## Navigation

Navigation elements like tab bars, sidebars, and split views automatically adopt Liquid Glass.

### Tab Bars (SwiftUI)

```swift
TabView {
    ContentView()
        .tabItem {
            Label("Home", systemImage: "house")
        }
    
    SettingsView()
        .tabItem {
            Label("Settings", systemImage: "gear")
        }
}
```

The tab bar background automatically uses the Liquid Glass material.

### Tab Bars (UIKit)

```swift
import UIKit

let tabBarController = UITabBarController()
tabBarController.viewControllers = [homeVC, settingsVC]

// The tab bar appearance updates automatically
let appearance = UITabBarAppearance()
appearance.configureWithDefaultBackground()
tabBarController.tabBar.standardAppearance = appearance
tabBarController.tabBar.scrollEdgeAppearance = appearance
```

### Sidebars (SwiftUI)

```swift
NavigationSplitView {
    List {
        Label("Inbox", systemImage: "tray")
        Label("Sent", systemImage: "paperplane")
        Label("Drafts", systemImage: "doc")
    }
    .navigationTitle("Mailboxes")
} detail: {
    MessageListView()
}
```

Sidebars automatically render with the Liquid Glass material, providing a translucent background that reveals the content beneath.

### Sidebars (UIKit)

```swift
import UIKit

let splitViewController = UISplitViewController(style: .tripleColumn)
let sidebarViewController = SidebarViewController()
splitViewController.setViewController(sidebarViewController, for: .primary)
splitViewController.setViewController(secondaryVC, for: .supplementary)
splitViewController.setViewController(detailVC, for: .secondary)
```

### NavigationStack (SwiftUI)

```swift
NavigationStack {
    List(items) { item in
        NavigationLink(item.title, value: item)
    }
    .navigationTitle("Items")
    .navigationDestination(for: Item.self) { item in
        ItemDetailView(item: item)
    }
}
```

## Menus and Toolbars

Menus and toolbars receive the Liquid Glass visual treatment automatically.

### Toolbars (SwiftUI)

```swift
NavigationStack {
    ContentView()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Action
                } label: {
                    Image(systemName: "plus")
                }
            }
            
            ToolbarItem(placement: .secondaryAction) {
                Button("Filter") {
                    // Action
                }
            }
        }
}
```

Toolbar items automatically align with the Liquid Glass aesthetic. Use `.toolbarBackground(.visible)` to control the toolbar material visibility.

### Toolbars (UIKit)

```swift
import UIKit

let toolbar = UIToolbar()
toolbar.items = [
    UIBarButtonItem(systemItem: .add),
    UIBarButtonItem(systemItem: .flexibleSpace),
    UIBarButtonItem(systemItem: .search)
]

let appearance = UIToolbarAppearance()
appearance.configureWithDefaultBackground()
toolbar.standardAppearance = appearance
toolbar.scrollEdgeAppearance = appearance
```

### Menus and Commands (SwiftUI)

```swift
struct MyCommands: Commands {
    var body: some Commands {
        CommandMenu("Actions") {
            Button("Process") {
                // Action
            }
            .keyboardShortcut("p")
            
            Divider()
            
            Button("Reset") {
                // Action
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
```

### Menu Bar Extra Background

On macOS, you can control the background appearance of menu bar extras:

```swift
struct MenuBarExtraView: View {
    var body: some View {
        Text("Status")
            .glassEffect()
    }
}
```

### Context Menus

```swift
Text("Tap and hold")
    .contextMenu {
        Button("Copy", systemImage: "doc.on.doc") {
            // Action
        }
        Button("Share", systemImage: "square.and.arrow.up") {
            // Action
        }
    }
```

## Windows and Modals

Windows, sheets, and modal presentations automatically adopt the Liquid Glass material.

### Sheets (SwiftUI)

```swift
struct ContentView: View {
    @State private var showingSheet = false
    
    var body: some View {
        Button("Show Sheet") {
            showingSheet = true
        }
        .sheet(isPresented: $showingSheet) {
            SheetView()
        }
    }
}
```

### Popovers (SwiftUI)

```swift
struct ContentView: View {
    @State private var showingPopover = false
    
    var body: some View {
        Button("Show Popover") {
            showingPopover = true
        }
        .popover(isPresented: $showingPopover) {
            PopoverContent()
                .frame(width: 300, height: 200)
        }
    }
}
```

### Windows (macOS — AppKit)

```swift
import AppKit

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)

// The window background automatically uses Liquid Glass
window.title = "My Window"
window.contentViewController = MyViewController()
window.makeKeyAndOrderFront(nil)
```

### Window Controls and Titlebar

On macOS, you can configure the titlebar appearance:

```swift
window.titlebarAppearsTransparent = true
window.styleMask.insert(.fullSizeContentView)
```

## Organization and Layout

A well-organized layout helps your app feel consistent with system experiences. Use standard layout techniques to ensure your interface aligns with Liquid Glass design principles.

### SwiftUI Layout

```swift
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            HeaderView()
            
            HStack(alignment: .top, spacing: 12) {
                SidebarContent()
                    .frame(width: 200)
                
                MainContent()
                    .frame(maxWidth: .infinity)
            }
            
            FooterView()
        }
        .padding()
    }
}
```

### Grid Layouts

```swift
LazyVGrid(
    columns: [
        GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 16)
    ],
    spacing: 16
) {
    ForEach(items) { item in
        ItemCell(item: item)
    }
}
.padding()
```

### Containers and Groups

```swift
GroupBox {
    VStack(alignment: .leading) {
        Label("Storage", systemImage: "externaldrive")
        
        ProgressView(value: storageUsed, total: storageTotal)
        
        Text("\(storageUsed) GB of \(storageTotal) GB used")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
}
```

### Form Layout

```swift
Form {
    Section("Profile") {
        TextField("Name", text: $name)
        TextField("Email", text: $email)
    }
    
    Section("Preferences") {
        Toggle("Notifications", isOn: $notificationsEnabled)
        Picker("Language", selection: $language) {
            Text("English").tag("en")
            Text("Chinese").tag("zh")
        }
    }
}
```

### Spacing and Alignment

Use consistent spacing throughout your interface. Standard spacing values:

- 4 pt — Tight spacing between related elements
- 8 pt — Default spacing between controls
- 16 pt — Section spacing
- 20 pt — Large section spacing
- 32 pt — Screen-level padding

## Search

A universal search experience helps users find content across your app. SwiftUI provides the `.searchable()` modifier for easy integration.

### SwiftUI Search

```swift
struct ContentView: View {
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            List(filteredItems) { item in
                Text(item.title)
            }
            .searchable(text: $searchText, prompt: "Search items")
        }
    }
    
    var filteredItems: [Item] {
        searchText.isEmpty ? items : items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }
}
```

### Search Suggestions

```swift
NavigationStack {
    List {
        // Content
    }
    .searchable(text: $searchText) {
        Text("Recent").searchCompletion("Recent")
        Text("Favorites").searchCompletion("Favorites")
    }
}
```

### Search with Scope

```swift
NavigationStack {
    List {
        // Content
    }
    .searchable(text: $searchText)
    .searchScopes($scope) {
        Text("All").tag(Scope.all)
        Text("Documents").tag(Scope.documents)
        Text("Images").tag(Scope.images)
    }
}
```

### UIKit Search

```swift
import UIKit

let searchController = UISearchController(searchResultsController: nil)
searchController.searchResultsUpdater = self
searchController.obscuresBackgroundDuringPresentation = false
navigationItem.searchController = searchController
navigationItem.hidesSearchBarWhenScrolling = false
```

### macOS NSSearchField

```swift
import AppKit

let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
searchField.placeholderString = "Search"
searchField.sendsWholeSearchString = true
searchField.target = self
searchField.action = #selector(searchAction(_:))
```

## Platform Considerations

Different platforms have different conventions and capabilities. This section describes platform-specific considerations when adopting Liquid Glass.

### watchOS

On Apple Watch, Liquid Glass is optimized for the smaller display and always-on retina screen.

- **Limited translucency** — Due to the small screen and power constraints, glass effects are more subtle on watchOS.
- **Complications** — Complications can adopt a simplified glass appearance.
- **Navigation** — Use `TabView` with page-style navigation or `NavigationStack` where appropriate.

```swift
// watchOS example with glass effect
Text("Heart Rate: 72 BPM")
    .font(.title3)
    .padding()
    .glassEffect()
```

**Design considerations:**
- Watch content areas are smaller; avoid overcrowding.
- Use system fonts and dynamic type for readability.
- Minimize the number of interactive elements per screen.
- Leverage the Digital Crown for continuous value adjustments.

### tvOS

On Apple TV, Liquid Glass adapts to the focus-based interaction model and the larger viewing distance.

- **Focus effects** — Views gain visual enhancements when focused, including subtle glass elevation.
- **Parallax** — Focused items can include parallax effects for depth.
- **Large text** — Text sizes are larger to accommodate viewing distance.

```swift
// tvOS example with glass effect on focused view
Button("Play Movie") {
    // Action
}
.buttonStyle(.glass)
```

**Design considerations:**
- Design for the 10-foot viewing distance — use larger fonts and UI elements.
- Ensure all interactive elements are focusable.
- Provide clear focus indicators.
- Use the full-screen canvas effectively — avoid cluttered layouts.
- Consider top shelf assets for the TV app's main screen.

### iOS and iPadOS

iOS and iPadOS provide the most comprehensive Liquid Glass implementation.

- **Full material support** — All Liquid Glass variants are available.
- **Rich animations** — Transition effects and material morphing are fully supported.
- **Multitasking** — On iPadOS, consider how glass effects interact with Split View and Slide Over.

```swift
// iOS example with glass effect
ZStack {
    backgroundImage
        .ignoresSafeArea()
    
    VStack {
        Text("Overlay Content")
            .font(.largeTitle)
            .foregroundStyle(.white)
    }
    .padding()
    .glassEffect()
}
```

**Design considerations:**
- Respect the safe area on devices with Dynamic Island or rounded corners.
- Use `ignoresSafeArea()` deliberately to extend content behind bars.
- Consider landscape and portrait layouts.
- On iPad, support keyboard shortcuts and multi-window scenarios.

### macOS

macOS provides native Liquid Glass support through `NSGlassEffectView` on macOS 26+, with fallback to `NSVisualEffectView` on earlier versions.

- **Window-backed** — Each window can independently configure its glass appearance.
- **Menu bar** — The menu bar and menu bar extras can adopt glass effects.
- **Multiple displays** — Glass effects work seamlessly across all displays.

```swift
// macOS example with NSGlassEffectView (macOS 26+)
let glassView = NSGlassEffectView()
glassView.style = .regular
glassView.glassColor = .default
glassView.translatesAutoresizingMaskIntoConstraints = false
contentView.addSubview(glassView)

NSLayoutConstraint.activate([
    glassView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
    glassView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    glassView.topAnchor.constraint(equalTo: contentView.topAnchor),
    glassView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
])
```

**Design considerations:**
- Support window restoration and state preservation.
- Use the appropriate window style mask for your content.
- Consider touch bar integration for MacBook Pro models.
- Respect the system appearance (light and dark mode).

### visionOS

On Apple Vision Pro, Liquid Glass integrates with the spatial computing environment.

- **Spatial materials** — Glass effects blend with the user's physical environment.
- **Depth and volume** — Content can be displayed at varying depths.
- **Ornaments** — Use ornaments for attachments that follow the content.

**Design considerations:**
- Design for comfort — avoid rapid motion and disorienting transitions.
- Use appropriate scaling for spatial content.
- Consider the user's field of view — avoid placing critical content at the edges.

## Testing Your App

After adopting Liquid Glass, test your app thoroughly to ensure a great experience across platforms:

1. **Visual consistency** — Verify your interface looks correct in light and dark mode.
2. **Performance** — Ensure glass effects render smoothly, especially during animations.
3. **Accessibility** — Test with Dynamic Type, increased contrast, and VoiceOver.
4. **Platform testing** — Verify behavior on all supported platforms and device sizes.
5. **Multitasking** — On iPadOS, test in Split View and Slide Over configurations.
6. **Window management** — On macOS, test with multiple windows, tabs, and spaces.
