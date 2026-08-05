# macOS 26 设计规范

> 基于 15 份 Figma 设计稿 CSS 代码的系统性分析  
> 覆盖：弹窗系统 · 保存对话框 · 表单设置 · 文件列表 · 菜单系统 · 窗口布局 · 工具窗口 · 通知中心

---

## 目录

1. [窗口层级结构](#1-窗口层级结构)
2. [导航结构](#2-导航结构)
3. [Sidebar 规范](#3-sidebar-规范)
4. [Typography 规范](#4-typography-规范)
5. [Section 规范](#5-section-规范)
6. [Toolbar 规范](#6-toolbar-规范)
7. [交互原则](#7-交互原则)
8. [组件规范](#8-组件规范)
9. [完整设计稿全景](#9-完整设计稿全景)

---

## 1. 窗口层级结构

### 1.1 Z 轴层级体系

```
L0: Desktop Wallpaper (1512×982px)
L1: Menu Bar (1512×34px, top: 0)
L2: Gradient Mask (72px) + Glass Overlay (rgba(255,255,255,0.08~0.15))
L3: Application Window (900×600px / 900×920px)
L4: Overlay (rgba(0,0,0,0.2) — 仅 Window Modal)
L5: Alert / Dialog (260×154px / 260×218px / 390×322px / 800×448px)
L6: Floating Menus (多尺寸)
L7: Dock (882×62px, bottom: 5px)
```

### 1.2 六种窗口类型

| 窗口类型 | 典型尺寸 | 圆角 | 红绿灯 | 阴影 |
|---------|---------|------|--------|------|
| **文档窗口** | `900×600px` / `900×920px` | `16-26px` | `14×14px` | `0px 16px 48px rgba(0,0,0,0.35)` |
| **工具窗口** | `300×300px` | `15px` | `10×10px` | `0px 5px 20px rgba(0,0,0,0.3)` |
| **对话框** | `390×322px` / `800×448px` | `10-26px` | 无 | 双层阴影 |
| **弹窗** | `260×154px` / `260×218px` | `10px` | 无 | `drop-shadow` 双层 |
| **通知横幅** | `382×72px` | `16px` | 无 | Liquid Glass |
| **菜单** | 多尺寸 (201-268px 宽) | `13px` | 无 | 柔和 |

### 1.3 五种窗口布局模式

| 布局模式 | 标题栏 | 工具栏 | 顶部总高 | 内容区高度 | 适合场景 |
|---------|-------|--------|---------|----------|---------|
| **纯标题栏（文档）** | ✅ 全宽 `24px` | ❌ 无 | 24px | 568px | 内容优先（阅读器、预览） |
| **纯标题栏（工具）** | ✅ 居中 `24px` | ❌ 无 + Tab 栏 `30px` | 54px | 243px | 工具面板、检查器 |
| **Monobar** | ✅ 内嵌 Leading Pane | ✅ `32px`（超小） | 32px | 560px | 轻量浏览 |
| **Titlebar 独立** | ✅ 全宽 `32px` | ✅ `36px`（中） | 68px | 524px | 文档编辑 |
| **标准模式** | ❌ 无独立 | ✅ `52px`（大） | 52px | 548px | 内容密集型 |

---

## 2. 导航结构

### 2.1 Menu Bar（菜单栏）

| 属性 | 值 |
|------|-----|
| **尺寸** | `1512 × 34px`（全宽） |
| **布局** | `flex-direction: row; justify-content: space-between; align-items: center` |
| **内边距** | `padding: 5px 10px` |
| **Leading Group** | Apple Logo + App Name + 多个 Menu Item |
| **Trailing Group** | 系统状态项（时间、Wi-Fi、电池等） |

#### 菜单项选中态

```
background: rgba(0, 0, 0, 0.08);
background-blend-mode: plus-darker;
backdrop-filter: blur(30px);
border-radius: 100px;
```

- 选中态背景：`59 × 25px` 椭圆形，向外扩展 `-4px` 水平、`-1px` 垂直

#### 菜单栏玻璃层

| 版本 | 透明度 |
|------|--------|
| 大部分设计稿 | `rgba(255,255,255,0.15)` |
| Windows/Toolbar+Titlebar | `rgba(255,255,255,0.08)` |

### 2.2 Dock（程序坞）

| 属性 | 值 |
|------|-----|
| **尺寸** | `882 × 62px` |
| **定位** | 底部居中，`bottom: 5px` |
| **布局** | `flex-direction: row; gap: 9px; padding: 10px 8px 11px` |
| **图标** | 均为 `36 × 36px` |
| **圆角** | `border-radius: 15px` |
| **背景** | `rgba(246,246,246,0.36)` + 边框 `1px solid rgba(26,26,26,0.46)` |
| **模糊** | `backdrop-filter: blur(67.957px)` |
| **阴影** | `0px 0px 6px rgba(0,0,0,0.15)` |

---

## 3. Sidebar 规范

### 3.1 五种变体

| 变体 | 宽度 | 背景圆角 | 内边距 | 布局模式 | 出现位置 |
|------|------|---------|--------|---------|---------|
| **标准含 Titlebar** | `240px` | `8px` | `padding: 0px 8px 8px` | 独立 Titlebar + Sidebar | Dialog/Save, Windows/Monobar |
| **标准无 Titlebar** | `240px` | `18px` | `padding: 8px` | 独立 Sidebar | Form, List, Windows/Toolbar |
| **紧凑型** | `136px` | `18px` | `padding: 8px 0px 8px 8px` | 独立 Sidebar | Dialog/Save - Large |
| **撑满型** | `240px` | `18px` | `padding: 0px` | 窗口内撑满 | Windows/Toolbar |
| **Monobar 型** | `240px` | `8px` | `padding: 0px 8px 8px` | Titlebar 内嵌于 Leading Pane | Windows/Monobar |

### 3.2 背景材质

```
BG - Medium UI:

Fill + Shadow:
  background: linear-gradient(0deg, rgba(245,245,245,0.67), rgba(245,245,245,0.67)), #262626;
  background-blend-mode: normal, color-dodge;
  box-shadow: 0px 8px 40px rgba(0,0,0,0.12);

Glass Effect:
  background: rgba(0,0,0,0.2);
  background-blend-mode: screen;
```

### 3.3 列表项规范

| 属性 | 值 |
|------|-----|
| **高度** | `24px` |
| **内边距** | `padding: 4px 10px 4px 6px` |
| **圆角** | `border-radius: 8px` |
| **默认态** | 无背景 |
| **选中态** | `rgba(0,0,0,0.11)` + `mix-blend-mode: multiply`，图标变 `#007AFF` |
| **图标** | `20 × 16px` 文件夹 SF Symbol |
| **标签** | Medium 510, `11px`, `line-height: 16px` (145%) |

### 3.4 Section Header

| 属性 | 值 |
|------|-----|
| **高度** | `34px` |
| **内边距** | `padding: 15px 12px 5px 18px` |
| **字体** | Bold 700, `11px`, `line-height: 14px` |
| **颜色** | `rgba(0,0,0,0.5)` + `mix-blend-mode: plus-darker` |

---

## 4. Typography 规范

### 4.1 完整字体体系

| 样式名称 | 字重 | 字号 | 行高 | 行高比 | 应用场景 |
|---------|------|------|------|--------|---------|
| **Apple Logo** | Regular 400 | `16.3px` | `20px` | 123% | 菜单栏 Apple 标志 |
| **Title Large** | Bold 700 | `15px` | `16px` | 107% | 标题栏/工具栏窗口标题 |
| **Headline/Regular** | Bold 700 | `13px` | `16px` | 123% | 弹窗标题、App 名称、通知标题 |
| **Body/Emphasized** | Semi-bold 590 | `13px` | `16px` | 123% | 菜单栏标签 |
| **Button Label** | Medium 510 | `13px` | `16px` | 123% | 按钮文字 |
| **Menu/Label** | Medium 510 | `13px` | `16px` | 123% | 菜单项标签 |
| **Menu/Symbol** | Medium 510 | `13px` | `16px` | 123% | 菜单项图标（`ss15`） |
| **Menu/Chevron** | Bold 700 | `13px` | `16px` | 123% | 子菜单箭头（`ss15`） |
| **Dialog Label** | Medium 510 | `13px` | `14px` | 108% | 对话框标签（`-0.02em`） |
| **Form Row Title** | Medium 510 | `13px` | `16px` | 123% | 表单行标签 |
| **List Row Label** | Medium 510 | `13px` | `16px` | 123% | 列表行文字 |
| **Body/Regular** | Regular 400 | `13px` | `16px` | 123% | 通知描述（`-0.008em`） |
| **Subheadline/Regular** | Regular 400 | `11px` | `14px` | 127% | 弹窗描述、列标题、时间戳 |
| **Subheadline/Emphasized** | Semi-bold 590 | `11px` | `14px` | 127% | 列表底部说明 |
| **Column Header** | Medium/Bold 510/700 | `11px` | `14px` | 127% | 列表列标题 |
| **Folder Label** | Medium 510 | `11px` | `16px` | 145% | Sidebar 列表项 |
| **Section Header** | Bold 700 | `11px` | `14px` | 127% | Sidebar / 菜单分组标题 |
| **Menu/Header** | Bold 700 | `10px` | `12px` | 120% | 菜单分组标题 |
| **Footnote/Emphasized** | Semi-bold 590 | `10px` | `13px` | 130% | 表单 Chevron |
| **List Chevron** | Bold 700 | `9px` | `9px` | 100% | 列表展开箭头 |
| **List Sort Arrow** | Medium 510 | `9px` | `13px` | 144% | 排序箭头 |

**字体系列：** 全局统一 `SF Pro`，仅搜索栏使用 `SF Pro Rounded`

### 4.2 文字颜色体系

| 颜色值 | 语义名称 | 用途 |
|--------|---------|------|
| `rgba(0,0,0,0.85)` | Text/Primary | 主文字颜色 |
| `rgba(0,0,0,0.5)` | Text/Secondary | 次要文字（标签、副标题） |
| `#727272` | Text/Tertiary | 搜索栏占位文字、菜单分组标题 |
| `#BFBFBF` | Text/Disabled | 禁用态文字、快捷键文字、时间戳 |
| `#1A1A1A` | Text/Dark | 深色文字/图标（菜单标签、工具栏图标） |
| `#4D4D4D` | Text/Utility Tab | 工具窗口 Tab 文字 |
| `#FFFFFF` | White | 选中态文字、Primary 按钮文字 |

---

## 5. Section 规范

### 5.1 Window Controls（红绿灯按钮）

| 类型 | 文档窗口 | 工具窗口 |
|------|---------|---------|
| **Close** | `#FF736A` | `#FF736A` |
| **Minimize** | `#FEBC2E` | `#FEBC2E` |
| **Zoom** | `#19C332` | `#19C332` |
| **尺寸** | `14 × 14px` | `10 × 10px` |
| **边框** | `0.5px solid rgba(0,0,0,0.1)` | `0.5px solid rgba(0,0,0,0.1)` |
| **圆角** | `border-radius: 100px`（正圆） | `border-radius: 100px` |
| **间距** | `gap: 9px`，`padding: 1px` | `gap: 7px`，`padding: 3px` |

### 5.2 Titlebar

| 属性 | 全宽型（文档） | 内嵌型（Leading Pane） | 工具窗口型 |
|------|--------------|---------------------|-----------|
| **高度** | `24px` | `32px` | `24px` |
| **内边距** | `padding: 8px 8px 0px` | `padding: 8px 8px 0px 12px` | 居中标题 |
| **标题位置** | 左对齐（红绿灯后） | 左对齐（红绿灯后） | 居中 |
| **标题字体** | Bold 700, `15px` | Bold 700, `15px` | Bold 700, `13px` |
| **标题颜色** | `rgba(0,0,0,0.85)` + `plus-darker` | 同上 | 同上 |

### 5.3 Alert Section

| 属性 | Side-by-side（并排） | Stacked（堆叠） |
|------|-------------------|---------------|
| **弹窗尺寸** | `260 × 154px` | `260 × 218px` |
| **按钮布局** | `flex-direction: row; gap: 8px` | `flex-direction: column; gap: 6px` |
| **按钮高度** | `32px` | `28px` |
| **按钮类型** | Primary + Secondary | Primary + Destructive + Secondary |
| **共有属性** | `padding: 20px 16px 16px; gap: 16px` | — |
| **材质** | Liquid Glass - Medium | Liquid Glass - Medium |

### 5.4 Dialog Section

| 属性 | Small 版 | Large 版 |
|------|---------|---------|
| **尺寸** | `390 × 322px` | `800 × 448px` |
| **内边距** | `padding: 20px; gap: 20px` | 无全局内边距 |
| **内部结构** | 单列（Left + Right） | 三列（Left + Center + Right）+ 表格 + 底部栏 |
| **Sidebar** | 无 | 紧凑型 `136px` |
| **表格** | 无 | 3 列表格（Name/Date/Size） |
| **搜索** | 无 | `168 × 24px` 圆形搜索栏 |
| **底部按钮** | 3 个按钮行 | 4 个按钮行 + 底部边框 |

### 5.5 List Section

| 属性 | 值 |
|------|-----|
| **表格宽度** | `658px`（4 列）/ `664px`（3 列） |
| **行高度** | `20px` |
| **Header Row 高度** | `28px`（List）/ `33px`（Dialog） |
| **交替行背景** | `rgba(0,0,0,0.03)` |
| **选中态** | `#2962D9`，文字变 `#FFFFFF` |
| **圆角连接** | 首列 `8px 0 0 8px` / 末列 `0 8px 8px 0` |
| **缩进增量** | `15px`/级（Level 1-4） |

### 5.6 Menu Section

| 菜单类型 | 总宽 | 项目可用宽度 |
|---------|------|------------|
| **上下文菜单** | `201px` | `177px` |
| **菜单栏菜单** | `268px` | `244px` |
| **子菜单** | `119px` | `95px` |
| **级联菜单** | `226px` | `202px` |

#### 菜单项结构

```
[Symbol - 12px] [Label - flex:1] [Shortcuts - 25~51px] [Chevron - 12px]
```

#### 菜单项状态

| 状态 | 背景 | 文字色 |
|------|------|--------|
| **默认** | 无 | `#1A1A1A` |
| **禁用** | 无 | `#BFBFBF` |
| **高亮（菜单栏菜单）** | `#0088FF` 渐变混合 | `#FFFFFF` |
| **高亮（上下文菜单）** | `#E6E6E6` + `plus-darker` | `#1A1A1A` |

#### 分隔线

| 属性 | 值 |
|------|-----|
| **区域高度** | `11px` |
| **线条高度** | `1px` |
| **颜色** | `#E6E6E6` + `mix-blend-mode: plus-darker` |
| **水平范围** | `left: -1.33px; right: -1.33px`（超出容器） |

### 5.7 Notification Section

| 属性 | 值 |
|------|-----|
| **尺寸** | `382 × 72px` |
| **位置** | 右上角（`right: 16px; top: 49px`） |
| **圆角** | `border-radius: 16px` |
| **内边距** | `padding: 12px 9px 12px 13px` |
| **内部间距** | `gap: 13px` |
| **材质** | Liquid Glass - Medium |
| **垂直堆叠间距** | `gap: 16px` |

#### 内部结构

```
[App Icon 32×32px] [Title + Description 280×48px] [Timestamp 22×14px]
```

| 元素 | 字重 | 字号 | 行高 | 字间距 | 颜色 |
|------|------|------|------|--------|------|
| **Title** | Bold 700 | `13px` | `16px` | `-0.02em` | `rgba(0,0,0,0.85)` |
| **Description** | Regular 400 | `13px` | `16px` | `-0.008em` | `rgba(0,0,0,0.85)` |
| **Timestamp** | Regular 400 | `11px` | `14px` | — | `#BFBFBF` + `plus-darker` |

### 5.8 Utility Window Tab 栏

| 属性 | 值 |
|------|-----|
| **高度** | `30px` |
| **布局** | `flex-direction: row; justify-content: center; align-items: center` |
| **Tab 项尺寸** | `44 × 29px` |
| **圆角** | `border-radius: 6px` |
| **选中态** | `rgba(0,0,0,0.03)` + `mix-blend-mode: plus-darker` |
| **Tab 符号** | Medium 510, `13px`, `line-height: 22px` (169%), `color: #4D4D4D`, `ss16` |
| **标题栏** | 居中标题，Bold 700 `13px` + `ss15` 图标 `15px` |

---

## 6. Toolbar 规范

### 6.1 四尺寸变体

| 版本 | 高度 | 内边距 | Segmented Control | Button Group | Button | Search | 出现位置 |
|------|------|--------|-------------------|-------------|--------|--------|---------|
| **超小** | `32px` | `padding: 8px 8px 0px` | `79×24px`, `p:2px` | `160×24px`, `p:2px` | `36×24px` | `130×24px` | Dialog/Save, Windows/Monobar |
| **小** | `32px` | `padding: 8px 8px 0px` | `79×24px`, `p:2px` | `160×24px`, `p:2px` | `36×24px` | `130×24px` | Dialog/Save 变体 |
| **中** | `36px` | `padding: 0px 8px` | `67×36px`, `p:4px` | `146×36px`, `p:4px` | `37×36px` | `130×36px` | Windows/Toolbar+Titlebar |
| **大** | `52px` | `padding: 8px` | `67×36px`, `p:4px` | `146×36px`, `p:4px` | `37×36px` | `130×36px` | Form, List, Windows/Toolbar |

### 6.2 Toolbar 背景材质（Liquid Glass）

```
background: linear-gradient(0deg, #F7F7F7, #F7F7F7),
            linear-gradient(0deg, rgba(255,255,255,0.5), rgba(255,255,255,0.5)),
            #333333;
background-blend-mode: plus-darker, normal, color-dodge;
box-shadow: 0px 8px 40px rgba(0,0,0,0.12);
border-radius: 296px;
```

### 6.3 Toolbar 组件分解

```
[Segmented Control] [Title] [Flexible Space] [Button Group] [Button] [Search]
```

| 组件 | 小（32px） | 大（52px） |
|------|-----------|-----------|
| Segmented 内边距 | `padding: 2px` | `padding: 4px` |
| Button Group 内边距 | `padding: 2px; gap: 4px` | `padding: 4px; gap: 4px` |
| 按钮尺寸 | `36 × 20px` | `28 × 28px`（min） |
| 符号尺寸 | `24×24px`, `10px/12px` | `18-23×22px`, `13px/22px` |
| Search 高度 | `24px` | `36px` |

---

## 7. 交互原则

### 7.1 毛玻璃效果

| 元素 | 模糊值 | 关键属性 |
|------|--------|---------|
| Dock | `blur(67.957px)` | `rgba(246,246,246,0.36)` + 边框 |
| Alert / Sidebar / Notification | 无 blur | `screen` 混合 + `color-dodge` 混合 |
| Menu | 无 blur | `rgba(0,0,0,0.004)` 极淡玻璃层 |
| Menu Bar 选中态 | `blur(30px)` | `rgba(0,0,0,0.08)` |

### 7.2 阴影体系

| 层级 | 阴影值 |
|------|--------|
| **窗口级** | `0px 0px 0px 1px rgba(0,0,0,0.23)` + `0px 16px 48px rgba(0,0,0,0.35)` |
| **工具窗口** | `0px 5px 20px rgba(0,0,0,0.3)` |
| **对话框** | `0px 0px 0px 1px rgba(0,0,0,0.23)` + `0px 16px 48px rgba(0,0,0,0.35)` |
| **弹窗（外层）** | `drop-shadow(0px 0px 1px rgba(0,0,0,0.2))` + `drop-shadow(0px 17px 45px rgba(0,0,0,0.5))` |
| **弹窗（内层）** | `box-shadow: 0px 8px 40px rgba(0,0,0,0.12)` |
| **Dock** | `0px 0px 6px rgba(0,0,0,0.15)` |
| **菜单** | `0px 0px 2px rgba(0,0,0,0.1)` + `0px 0px 25px rgba(0,0,0,0.16)` |
| **Liquid Glass 组件** | `box-shadow: 0px 8px 40px rgba(0,0,0,0.12)` |

### 7.3 混合模式

| 模式 | 应用位置 |
|------|---------|
| `plus-lighter` | Menu Bar 玻璃层、Primary 按钮文字、Dialog Default 按钮文字 |
| `plus-darker` | Dock 分隔线、Sidebar 标签、菜单标签、Search、TextField 边框、表单标签、Secondary 按钮、Toolbar 图标、Section/Column Header 等 |
| `color-dodge` | Alert / Sidebar / Notification 背景 Fill |
| `screen` | Alert / Sidebar / Notification / Liquid Glass 玻璃效果 |
| `multiply` | TextField Border 背景、Sidebar 选中项背景、Window Modal 末列选中 |
| `normal` | 主要文字、部分菜单文字 |

### 7.4 按钮体系

| 场景 | 类型 | 尺寸 | 圆角 | 背景 | 文字色 |
|------|------|------|------|------|--------|
| **弹窗** | Primary | `110 × 32px` | `100px` | `#0088FF` | `#FFFFFF` |
| **弹窗** | Secondary | `110 × 32px` | `100px` | `#E6E6E6` + `plus-darker` | `rgba(0,0,0,0.85)` |
| **弹窗** | Destructive | `228 × 28px` | `100px` | `rgba(255,56,60,0.23)` | `#FF383C` |
| **对话框** | Default | `63-74 × 24px` | `6px` | `#0D6FFF` | `#FFFFFF` |
| **对话框** | Cancel | `74 × 24px` | `6px` | `rgba(0,0,0,0.05)` | `#1A1A1A` |
| **对话框** | Destructive | `72 × 24px` | `6px` | `rgba(255,56,60,0.25)` | `#FF383C` |
| **表单** | Push Button | `67 × 24px` | `6px` | `rgba(0,0,0,0.05)` | `#1A1A1A` |
| **工具栏** | Icon Button | `36×20px` / `28×28px` | `100px` | Liquid Glass | `#1A1A1A` / `#BFBFBF` |

### 7.5 TextField 规范

| 状态 | 属性 | 值 |
|------|------|-----|
| **默认** | 边框 | `box-shadow: 0px 0px 0px 1px rgba(0,0,0,0.08)` + `plus-darker` |
| | 背景 | `#FFFFFF` |
| **聚焦** | Focus Ring Thick | `box-shadow: 0px 0px 0px 3.5px rgba(0,122,255,0.25)` |
| | Focus Ring Thin | `box-shadow: 0px 0px 0px 1px rgba(0,122,255,0.15)` |
| **光标** | 颜色 | `#0088FF`，宽度 `2px` |
| **通用** | 尺寸 | `229 × 24px` / `120 × 24px` |
| | 圆角 | `border-radius: 6px` |
| | 内边距 | `padding: 0px 4px 0px 8px` |

### 7.6 表单控件

| 控件 | 选中态 | 未选中态 | 尺寸 |
|------|--------|---------|------|
| **Checkbox** | `#0D6FFF` + 白色勾 `9.31×8.93px` | `rgba(0,0,0,0.05)` | `16 × 16px` |
| **Radio Button** | `#0D6FFF` + 白色圆点 `4.8×4.8px` | `rgba(0,0,0,0.05)` | `16 × 16px` |
| **Switch** | 轨道 `#0D6FFF`，滑块 `#FFFFFF` | — | `36 × 16px` |
| **Stepper** | TextField + 上下按钮 `20×24px` | — | `64 × 24px` |

### 7.7 表单行规范

| 属性 | 值 |
|------|-----|
| **高度** | `42px`（`min-height: 42px`） |
| **内边距** | `padding: 2px 0px` |
| **布局** | `flex-direction: row; align-items: center; gap: 16px` |
| **分割线** | `border-bottom: 1px solid rgba(0,0,0,0.05)` |
| **左侧标题** | Medium 510, `13px`, `color: rgba(0,0,0,0.85)` |
| **Form Group 背景** | `rgba(0,0,0,0.03)`，圆角 `12px` |

### 7.8 Modal 分层体系

| 类型 | 遮罩 | 窗口 | Dock | 示例 |
|------|------|------|------|------|
| **Desktop Modal** | 无 | 无 | ✅ 可见 | Alert/Side-by-side |
| **Window Modal** | `rgba(0,0,0,0.2)` 窗口遮罩 | ✅ | ✅ 可见 | Alert - Window Modal |
| **Dialog Modal** | Dialog 自身阴影 | ✅ | ❌ 隐藏 | Dialog/Save |

### 7.9 圆角体系

| 元素 | 圆角值 |
|------|--------|
| **窗口背景** | `border-radius: 26px` 或 `16px` |
| **工具窗口** | `border-radius: 15px` |
| **Sidebar 背景** | `border-radius: 18px` 或 `8px` |
| **通知横幅** | `border-radius: 16px` |
| **菜单背景** | `border-radius: 13px` |
| **Dock** | `border-radius: 15px` |
| **Alert/Dialog 容器** | `border-radius: 10px` |
| **胶囊按钮** | `border-radius: 100px` |
| **直角按钮** | `border-radius: 6px` |
| **TextField** | `border-radius: 6px` |
| **Checkbox** | `border-radius: 5.5px` |
| **App Icon** | `border-radius: 5px` |
| **Liquid Glass** | `border-radius: 296px`（超大圆角） |
| **滚动条 Thumb** | `border-radius: 1000px` |

---

## 8. 组件规范

### 8.1 Segmented Control

| 属性 | 值 |
|------|-----|
| **尺寸** | `79 × 24px`（小）/ `67 × 36px`（大） |
| **内边距** | `padding: 2px`（小）/ `padding: 4px`（大） |
| **材质** | Liquid Glass |
| **按钮尺寸** | `36 × 20px`（小）/ `28 × 28px`（大） |
| **激活态颜色** | `#1A1A1A` |
| **非激活态颜色** | `#BFBFBF` |
| **分隔线** | `1px`，`#D9D9D9` + `plus-darker` |

### 8.2 Search Bar

| 属性 | 工具栏版 | 对话框版 |
|------|---------|---------|
| **尺寸** | `130 × 24px` 或 `130 × 36px` | `168 × 24px` |
| **圆角** | `border-radius: 100px` | `border-radius: 1000px` |
| **材质** | Liquid Glass | 纯白 `#FFFFFF` |
| **内边距** | `padding: 0px 6px` 或 `0px 10px` | `padding: 0px 4px 0px 8px` |
| **字体** | SF Pro, Medium 510 | SF Pro Rounded, Medium 500 |

### 8.3 Pop-Up Button

| 属性 | 值 |
|------|-----|
| **尺寸** | `229 × 24px`（全宽）或 `197 × 24px` |
| **圆角** | `border-radius: 6px` |
| **背景** | `rgba(0,0,0,0.05)` |
| **内边距** | `padding: 0px 0px 0px 12px` |
| **右侧箭头** | Bold 700, `11px` |

### 8.4 App Icon

| 属性 | 值 |
|------|-----|
| **尺寸** | `26 × 26px`（大）/ `20 × 20px`（小）/ `32 × 32px`（通知） |
| **圆角** | `border-radius: 5px` |
| **内发光** | 多层 `inset` 阴影 |
| **基色** | `#0088FF`（蓝）/ `#34C759`（绿）/ `#919191`（灰） |
| **符号** | Regular 400, `#FFFFFF` |

---

## 9. 完整设计稿全景