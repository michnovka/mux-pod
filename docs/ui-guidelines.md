# MuxPod UI/UX Guidelines

## Color Palette

Material Design 3 with dark theme as default. Light theme also supported.

### Dark Theme

| Usage | Color | Description |
|-------|-------|-------------|
| Background | `#0E0E11` | Main background |
| Canvas | `#101116` | App bar, elevated surfaces |
| Surface | `#1E1F27` | Cards, containers |
| Input | `#0B0F13` | Text input fields |
| Border | `#2A2B36` | Card/container borders |
| Primary | `#00C0D1` | Accent, buttons, active state |
| Text (primary) | `#FFFFFF` | Main text |
| Text (secondary) | `#9CA3AF` | Supporting text |
| Text (muted) | `#6B7280` | Disabled/hint text |
| Error | `#EF4444` | Error state |
| Success | `#22C55E` | Connected, etc. |
| Warning | `#F59E0B` | Warning state |

### Light Theme

| Usage | Color | Description |
|-------|-------|-------------|
| Background | `#F9FAFB` | Main background |
| Canvas | `#F3F4F6` | App bar, elevated surfaces |
| Surface | `#FFFFFF` | Cards, containers |
| Input | `#F9FAFB` | Text input fields |
| Border | `#E5E7EB` | Card/container borders |
| Text (primary) | `#111827` | Main text |
| Text (secondary) | `#4B5563` | Supporting text |
| Text (muted) | `#9CA3AF` | Disabled/hint text |

All colors are defined in `lib/theme/design_colors.dart`. Themes are configured in `lib/theme/app_theme.dart`.

## Design Tokens

### Border Radius

- Cards / containers: `12px`
- Buttons: `12px`
- Text inputs: `12px`
- Dialog: `16px`
- Bottom sheet: `20px` (top corners)
- Dashboard center button: circle
- Segmented buttons: `8px`

### Spacing

- xs: `4px`
- sm: `8px`
- md: `16px`
- lg: `24px`
- xl: `32px`

## Typography

- **UI text**: Space Grotesk (`google_fonts`)
- **Monospace text**: JetBrains Mono (`google_fonts`)
- **Terminal (English)**: HackGenConsole (bundled asset) or UDEVGothicNF (bundled asset)
- **Terminal (Japanese)**: HackGenConsole, UDEVGothicNF (both include Japanese glyphs)

App bar titles: Space Grotesk, 24px, weight 700, letter-spacing -0.5.

## Screen Layout

### Bottom Navigation (5-tab)

| Index | Icon | Label | Screen |
|-------|------|-------|--------|
| 0 | `dns` | Servers | Connection list |
| 1 | `key` | Keys | SSH key management |
| 2 | `terminal` | (center button) | Dashboard — recent sessions |
| 3 | `notifications_outlined` | Notify | Alert monitoring (tmux window flags) |
| 4 | `settings` | Settings | App settings |

Dashboard (index 2) is the default tab and has a large protruding circular button in the center of the navigation bar.

### Dashboard

- Recent sessions sorted by last access
- One-tap reconnect to last window/pane
- Session cards show connection name, host, window count, and last pane info

### Servers

- Expandable server cards with tmux session tree
- Attached/Detached status badges
- "+" FAB to add new connection

### Terminal

Full-screen terminal pushed on top of tab navigation:
- Top: Session > Window > Pane breadcrumb navigation
- Center: xterm-based terminal view with pinch zoom
- Bottom: Special keys bar (ESC, TAB, CTRL, ALT, SHIFT, arrows, etc.)
- Gesture: hold + swipe for arrow keys

### Alerts (Notify)

- Monitors tmux window flags across all connections
- Bell (red), Activity (orange), Silence (gray) indicators
- Tap to jump directly to flagged window

### Keys

- Generate Ed25519 or RSA keys on-device
- Import existing keys
- One-tap copy public key

### Settings

- Terminal font family, size, and minimum font size
- Theme selection (dark/light)
- Keep screen on, haptic feedback toggles
- Connection defaults

## Foldable Device Support

- Landscape / foldable: left panel for session tree, right panel for terminal
- Portrait: standard single-column layout

## Icons

- Material Icons throughout
- Connection status: green dot (connected), gray dot (disconnected), red dot (error)
