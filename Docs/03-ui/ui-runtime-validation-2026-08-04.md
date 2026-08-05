# MiPlay UI Runtime Validation (2026-08-04)

> Task 2: runtime verification for P1-08 and P2-04
>
> Scope: `MiPlay/UI/` and UI validation evidence only. No Domain, Infrastructure,
> Persistence, or Wine logic was changed during this validation.

## 1. Result Summary

| Item | Result | Boundary |
|---|---|---|
| Main-window AX roles and labels | Pass after the measured fix | Three game entries, Settings, Locate Game, and background-independent controls are exposed by the runtime AX tree. |
| Full Keyboard Access | Pass for the reachable main and Settings flows | Tab, Shift-Tab, Space, Return, Escape, and `Cmd-,` were exercised. |
| Settings layout and reopen | Pass | The runtime splitter reports `240pt`; sidebar remains visible after close and reopen. |
| VoiceOver semantic surface | Partial pass | VoiceOver was enabled and the same runtime AX nodes were present. The app-scoped automation API cannot send global VoiceOver navigation keys or provide an audio transcript. |
| Launch progress, failure, cancel, retry, and rollback | Not reachable in this fixture | All three games are unlocated; no real launch task was started. Static semantics are not counted as runtime evidence. |
| Liquid Glass hover/focus/selected separation | Pass for observed states | Pointer traversal and keyboard focus showed stable hit frames and visible focus; no adjacent glass fusion was observed. |
| Increase Contrast and Reduce Motion | Pass for observed main-window states | Each preference was enabled, the app was restarted, and the AX tree plus screenshot were checked. Preferences were restored afterward. |

**P1-08 conclusion:** the measured AX and keyboard defects are fixed, but the
full P1 acceptance remains conditional until a fixture with a real installed
game can exercise progress, failure, cancellation, retry, and rollback announcements.

**P2-04 conclusion:** pass for the tested main-window geometry, focus, hover
separation, Settings layout, Increase Contrast, and Reduce Motion conditions.

## 2. Environment and Build

- Host: Apple Silicon macOS 27.0, Xcode 27.0, target deployment macOS 26.0.
- Build command:

  ```sh
  xcodebuild -project MiPlay.xcodeproj -scheme MiPlay -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath /tmp/MiPlayDerivedData build
  ```

- Build result: `BUILD SUCCEEDED`.
- Executed product: `/tmp/MiPlayDerivedData/Build/Products/Debug/MiPlay.app`.
- Runtime fixture: clean library with three placeholder games; all three report
  `未定位` and the main action reports `定位游戏`.
- Full Keyboard Access was `AppleKeyboardUIMode=2` during the keyboard run.
- The final system preference check was:

  ```text
  AppleKeyboardUIMode=2
  AppleReduceMotion=<unset>
  AppleIncreaseContrast=<unset>
  com.apple.universalaccess increaseContrast=0
  VoiceOver=off
  ```

## 3. Measured Fix

### 3.1 Baseline failure

Before the UI-only fix, the running AX tree represented each game entry as
`unknown`, even though the source used SwiftUI `Button`. Full Keyboard Access
skipped the game entries, and `Return` did not activate a focused game or the
Settings entry. `Space` did activate the focused game entry.

### 3.2 Change made

In [GameSelectionRailView.swift](../../MiPlay/UI/MainWindow/GameSelectionRailView.swift):

- Added `.accessibilityAddTraits(.isButton)` to the game buttons so the custom
  icon label is still exposed as a button in the runtime tree.
- Added `.onKeyPress(.return)` to game buttons and the Settings button, calling
  their existing actions.
- Added no new state, accessibility data tree, business rule, or ViewModel.

This is the only runtime-proven UI correction in this task. The stable hit
frames, glass layering, status-dot rendering, labels, values, and hints were
left unchanged because they did not produce a measured runtime failure.

## 4. Runtime AX Evidence

With the fixed build running, the main window returned:

```text
Window: "MiPlay", App: MiPlay.
0 standard window MiPlay
  2 button Description: 切换到原神, Value: 未选中，未定位
  3 button Description: 切换到崩坏：星穹铁道, Value: 未选中，未定位
  4 button Description: 切换到绝区零, Value: 当前选中，未定位
  5 button Description: 设置, Value: 设置窗口未打开
  6 button Description: 定位游戏, Value: 可执行
```

The decorative background was absent from the AX tree. The game status dot
was not exposed as a second control; its fact was included in the game button
value. This matches the UI contract and avoids duplicate VoiceOver stops.

The Settings window returned:

```text
Window: "MiPlay Settings"
  split group SidebarNavigationSplitView
    list Sidebar
      row (selected) 通用
      row (selectable) 原神
      row (selectable) 星穹铁道
      row (selectable) 绝区零
      row (selectable) Wine 环境
      row (selectable) 关于
    splitter (disabled, settable, float) 240
```

The Settings detail pane exposed headings, the language picker, the update
toggle, game-library status text, and the log button. Selecting a per-game row
exposed Basic Info, Install Status, Metadata, and Game Configuration for that
game. The clean fixture correctly reported `未定位`; it did not display a
nonexistent installed, running, or successful state.

## 5. Keyboard and VoiceOver Checks

### 5.1 Full Keyboard Access

| Operation | Expected | Observed |
|---|---|---|
| `Tab` from the main window | Game buttons appear before Settings and Locate Game | Pass; all three game buttons entered the cycle. |
| `Space` on a focused game | Select that game | Pass; selected value changed in the AX tree. |
| `Return` on a focused game | Select that game | Pass after the fix; the focused game changed selection. |
| `Return` on Settings | Open Settings | Pass after the fix. |
| `Shift-Tab` in Settings | Move to the previous sidebar control | Pass; focus returned to the selected sidebar row. |
| `Cmd-,` | Open Settings | Pass. |
| `Escape` from the main window | Do not change selected game | Pass. |
| Settings close and reopen | Keep sidebar and detail visible | Pass; splitter remained `240pt`. |

The game order was stable: Genshin Impact, Honkai: Star Rail, Zenless Zone
Zero, then Settings. The focus ring was visible around the focused game in the
normal, Reduce Motion, and Increase Contrast screenshots.

### 5.2 VoiceOver / AX

VoiceOver was enabled through System Settings for the validation pass. While
it was enabled, MiPlay still exposed the same button labels and values shown in
Section 4, and the Settings rows, headings, picker, toggle, and log button
remained in the AX tree. VoiceOver was disabled after the pass.

The Computer Use API used here is app-scoped: it can inspect AX roles,
descriptions, values, and focus, but cannot send the global VoiceOver modifier
combination or capture an audio transcript. Therefore this record proves the
runtime semantic surface and focus behavior, but does not claim an audio
pronunciation or localization review.

## 6. Liquid Glass and Visual State Checks

The experiment kept the existing `GlassEffectContainer`, fixed `64pt` Button
hit frames, fixed `56pt` glass contents, and glyph-only hover/selection scale.
No material or window structure was changed during this task.

| State | Method | Result |
|---|---|---|
| Selected | AX selected value plus screenshot | Selected game remained distinct; adjacent icons did not merge. |
| Keyboard focus | Full Keyboard Access and pointer traversal | Focus ring was visible outside the glass content and did not move the layout. |
| Hover | Pointer dragged to a game control, then screenshot | Hover feedback stayed within the icon content; neighboring hit regions remained stable. |
| Pressed/action | Space and Return activation | Standard Button actions fired without changing the hit-frame geometry. A held-mouse screenshot was not produced by the automation API. |
| High contrast | System Settings Display > Increase Contrast, app restart | Toggle was `on`; main and Settings controls remained distinguishable and readable. |
| Reduce Motion | `AppleReduceMotion=true`, app restart | Main window retained controls, focus, and AX labels; no required state disappeared. |

The screenshots are retained in [`validation-artifacts/`](validation-artifacts/):

- [`main-normal.jpg`](validation-artifacts/main-normal.jpg)
- [`settings-normal.jpg`](validation-artifacts/settings-normal.jpg)
- [`main-hover-focus.jpg`](validation-artifacts/main-hover-focus.jpg)
- [`main-reduce-motion.jpg`](validation-artifacts/main-reduce-motion.jpg)
- [`main-increase-contrast.jpg`](validation-artifacts/main-increase-contrast.jpg)

## 7. Dynamic State Boundary

The clean runtime fixture cannot locate a real executable without opening a
user file panel, so it cannot safely produce a real launch task. Consequently,
these states were not marked as runtime passes:

- determinate or indeterminate launch progress;
- cancellation while a task is running;
- launch failure with its recovery action;
- permission failure and reauthorization;
- compatibility solution unavailable;
- rollback in progress, rollback verified, or retry after rollback.

The existing UI source contains the corresponding state-driven projection, but
that is static evidence only. A later implementation or user-validation pass
must use a controlled installed-game fixture and record the AX value changes
for each state. No success announcement was fabricated in this task.

## 8. Verification Matrix

| Surface | Normal | Increase Contrast | Reduce Motion | Reopen | Evidence |
|---|---:|---:|---:|---:|---|
| Main game buttons / Settings | Pass | Pass | Pass | Pass | AX dump + main screenshots |
| Focus ring and stable hit area | Pass | Pass | Pass | Pass | `main-hover-focus.jpg` and keyboard run |
| Settings sidebar/detail | Pass | Pass | Not separately repeated | Pass | `settings-normal.jpg`, AX splitter `240` |
| Per-game Settings | Pass | Not separately repeated | Not separately repeated | Pass | Runtime AX for Zenless Zone Zero |
| Progress / failure / recovery | Not reachable | Not reachable | Not reachable | Not reachable | Explicitly pending fixture |

## 9. Follow-up Gate

P1-08 should be closed only after a real installed-game fixture exercises the
dynamic task and recovery states with VoiceOver announcements or an equivalent
recorded AX notification trace. P2-04 is ready for the next review based on the
observed geometry and accessibility-display runs.
