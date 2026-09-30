# Kontrast raporu (WCAG 2.x, hedef ≥ 4.5:1)

Kaynak: `src/styles/tokens.css` — `node scripts/redesign/contrast.mjs --theme <light|dark> --markdown` ile üretildi.

Tek düzeltme: light `--text-faint` spec `#8A93A3` (2.96:1) → `#6B727E` (4.64:1). Ayrıntı: PLAN.md.

## Light

| Metin token | Zemin token | Metin | Zemin | Oran | ≥4.5 |
|---|---|---|---|---|---|
| `--text` | `--bg-app` | #1A1D23 | #F4F5F7 | 15.48:1 | ✅ |
| `--text` | `--bg-chrome` | #1A1D23 | #FFFFFF | 16.88:1 | ✅ |
| `--text` | `--bg-panel` | #1A1D23 | #F9FAFB | 16.15:1 | ✅ |
| `--text` | `--bg-input` | #1A1D23 | #FFFFFF | 16.88:1 | ✅ |
| `--text` | `--bg-control` | #1A1D23 | #FFFFFF | 16.88:1 | ✅ |
| `--text` | `--bg-selected` | #1A1D23 | #EAF0FD | 14.78:1 | ✅ |
| `--text` | `--bg-terminal` | #1A1D23 | #FFFFFF | 16.88:1 | ✅ |
| `--text-strong` | `--bg-rail-active` | #0B0D11 | #E8ECF4 | 16.42:1 | ✅ |
| `--text-strong` | `--bg-segment-active` | #0B0D11 | #FFFFFF | 19.45:1 | ✅ |
| `--text-strong` | `--bg-chrome` | #0B0D11 | #FFFFFF | 19.45:1 | ✅ |
| `--text-strong` | `--bg-terminal` | #0B0D11 | #FFFFFF | 19.45:1 | ✅ |
| `--text-secondary` | `--bg-panel` | #3D4452 | #F9FAFB | 9.36:1 | ✅ |
| `--text-secondary` | `--bg-selected` | #3D4452 | #EAF0FD | 8.56:1 | ✅ |
| `--text-tertiary` | `--bg-segment` | #4A5261 | #EEF0F3 | 6.89:1 | ✅ |
| `--text-tertiary` | `--bg-input` | #4A5261 | #FFFFFF | 7.86:1 | ✅ |
| `--text-tertiary` | `--bg-chrome` | #4A5261 | #FFFFFF | 7.86:1 | ✅ |
| `--text-tertiary` | `--bg-control` | #4A5261 | #FFFFFF | 7.86:1 | ✅ |
| `--text-muted` | `--bg-app` | #5E6675 | #F4F5F7 | 5.30:1 | ✅ |
| `--text-muted` | `--bg-chrome` | #5E6675 | #FFFFFF | 5.78:1 | ✅ |
| `--text-muted` | `--bg-panel` | #5E6675 | #F9FAFB | 5.53:1 | ✅ |
| `--text-muted` | `--bg-input` | #5E6675 | #FFFFFF | 5.78:1 | ✅ |
| `--text-muted` | `--bg-terminal` | #5E6675 | #FFFFFF | 5.78:1 | ✅ |
| `--text-muted` | `--bg-selected` | #5E6675 | #EAF0FD | 5.06:1 | ✅ |
| `--text-muted` | `--bg-table-head` | #5E6675 | #F4F5F7 | 5.30:1 | ✅ |
| `--text-muted` | `--success-card-bg` | #5E6675 | #EEF8F3 | 5.33:1 | ✅ |
| `--text-muted` | `--bg-control` | #5E6675 | #FFFFFF | 5.78:1 | ✅ |
| `--text-faint` | `--bg-chrome` | #6B727E | #FFFFFF | 4.85:1 | ✅ |
| `--text-faint` | `--bg-panel` | #6B727E | #F9FAFB | 4.64:1 | ✅ |
| `--text-terminal` | `--bg-terminal` | #2A2F38 | #FFFFFF | 13.44:1 | ✅ |
| `--accent` | `--bg-terminal` | #2F5BD3 | #FFFFFF | 5.90:1 | ✅ |
| `--accent` | `--bg-app` | #2F5BD3 | #F4F5F7 | 5.41:1 | ✅ |
| `--accent` | `--bg-panel` | #2F5BD3 | #F9FAFB | 5.65:1 | ✅ |
| `--primary-fg` | `--primary-bg` | #FFFFFF | #1A1D23 | 16.88:1 | ✅ |
| `--success-text` | `--success-bg` | #127A56 | #E3F5EE | 4.71:1 | ✅ |
| `--success-text` | `--bg-terminal` | #127A56 | #FFFFFF | 5.32:1 | ✅ |
| `--success-text` | `--bg-panel` | #127A56 | #F9FAFB | 5.10:1 | ✅ |
| `--success-text` | `--bg-selected-head` | #127A56 | #F1F5FE | 4.88:1 | ✅ |
| `--success-text` | `--bg-chrome` | #127A56 | #FFFFFF | 5.32:1 | ✅ |
| `--success-card-text` | `--success-card-bg` | #0E5E43 | #EEF8F3 | 7.17:1 | ✅ |
| `--warning-label` | `--warning-bg` | #9A6400 | #FFF6E6 | 4.66:1 | ✅ |
| `--warning-label` | `--warning-card-bg` | #9A6400 | #FFF8EA | 4.73:1 | ✅ |
| `--warning-label` | `--bg-panel` | #9A6400 | #F9FAFB | 4.79:1 | ✅ |
| `--warning-label` | `--bg-chrome` | #9A6400 | #FFFFFF | 5.00:1 | ✅ |
| `--warning-btn-fg` | `--warning-btn-bg` | #1A1206 | #E9A23B | 8.56:1 | ✅ |
| `--warning-text` | `--warning-card-bg` | #6E4A05 | #FFF8EA | 7.51:1 | ✅ |
| `--warning-text` | `--warning-code-bg` | #6E4A05 | #FBEFD6 | 6.96:1 | ✅ |
| `--warning-text` | `--warning-bg` | #6E4A05 | #FFF6E6 | 7.40:1 | ✅ |
| `--warning-text` | `--bg-chrome` | #6E4A05 | #FFFFFF | 7.94:1 | ✅ |
| `--danger-text` | `--danger-pill-bg` | #B42318 | #FDECEA | 5.75:1 | ✅ |
| `--danger-text` | `--danger-btn-bg` | #B42318 | #FEF3F2 | 6.05:1 | ✅ |
| `--danger-text` | `--bg-terminal` | #B42318 | #FFFFFF | 6.57:1 | ✅ |
| `--danger-kbd` | `--danger-btn-bg` | #C4453B | #FEF3F2 | 4.53:1 | ✅ |

light: 52 pairs, 0 below 4.5:1

## Dark

| Metin token | Zemin token | Metin | Zemin | Oran | ≥4.5 |
|---|---|---|---|---|---|
| `--text` | `--bg-app` | #E6E8EC | #0F1115 | 15.40:1 | ✅ |
| `--text` | `--bg-chrome` | #E6E8EC | #13161B | 14.78:1 | ✅ |
| `--text` | `--bg-panel` | #E6E8EC | #14171C | 14.64:1 | ✅ |
| `--text` | `--bg-input` | #E6E8EC | #171A20 | 14.21:1 | ✅ |
| `--text` | `--bg-control` | #E6E8EC | #1A1E25 | 13.63:1 | ✅ |
| `--text` | `--bg-selected` | #E6E8EC | #1C2436 | 12.63:1 | ✅ |
| `--text` | `--bg-terminal` | #E6E8EC | #0B0D11 | 15.85:1 | ✅ |
| `--text-strong` | `--bg-rail-active` | #FFFFFF | #232936 | 14.56:1 | ✅ |
| `--text-strong` | `--bg-segment-active` | #FFFFFF | #2A303C | 13.24:1 | ✅ |
| `--text-strong` | `--bg-chrome` | #FFFFFF | #13161B | 18.13:1 | ✅ |
| `--text-strong` | `--bg-terminal` | #FFFFFF | #0B0D11 | 19.45:1 | ✅ |
| `--text-secondary` | `--bg-panel` | #C9D1DC | #14171C | 11.66:1 | ✅ |
| `--text-secondary` | `--bg-selected` | #C9D1DC | #1C2436 | 10.06:1 | ✅ |
| `--text-tertiary` | `--bg-segment` | #B4BCC8 | #1B1F27 | 8.62:1 | ✅ |
| `--text-tertiary` | `--bg-input` | #B4BCC8 | #171A20 | 9.10:1 | ✅ |
| `--text-tertiary` | `--bg-chrome` | #B4BCC8 | #13161B | 9.47:1 | ✅ |
| `--text-tertiary` | `--bg-control` | #B4BCC8 | #1A1E25 | 8.73:1 | ✅ |
| `--text-muted` | `--bg-app` | #9AA3B2 | #0F1115 | 7.43:1 | ✅ |
| `--text-muted` | `--bg-chrome` | #9AA3B2 | #13161B | 7.13:1 | ✅ |
| `--text-muted` | `--bg-panel` | #9AA3B2 | #14171C | 7.06:1 | ✅ |
| `--text-muted` | `--bg-input` | #9AA3B2 | #171A20 | 6.85:1 | ✅ |
| `--text-muted` | `--bg-terminal` | #9AA3B2 | #0B0D11 | 7.64:1 | ✅ |
| `--text-muted` | `--bg-selected` | #9AA3B2 | #1C2436 | 6.09:1 | ✅ |
| `--text-muted` | `--bg-table-head` | #9AA3B2 | #161920 | 6.91:1 | ✅ |
| `--text-muted` | `--success-card-bg` | #9AA3B2 | #172420 | 6.30:1 | ✅ |
| `--text-muted` | `--bg-control` | #9AA3B2 | #1A1E25 | 6.57:1 | ✅ |
| `--text-faint` | `--bg-chrome` | #7C8595 | #13161B | 4.87:1 | ✅ |
| `--text-faint` | `--bg-panel` | #7C8595 | #14171C | 4.83:1 | ✅ |
| `--text-terminal` | `--bg-terminal` | #D4D9E1 | #0B0D11 | 13.72:1 | ✅ |
| `--accent` | `--bg-terminal` | #8FB3FF | #0B0D11 | 9.32:1 | ✅ |
| `--accent` | `--bg-app` | #8FB3FF | #0F1115 | 9.05:1 | ✅ |
| `--accent` | `--bg-panel` | #8FB3FF | #14171C | 8.61:1 | ✅ |
| `--primary-fg` | `--primary-bg` | #0F1115 | #E6E8EC | 15.40:1 | ✅ |
| `--success-text` | `--success-bg` | #7BE3BF | #15322A | 8.93:1 | ✅ |
| `--success-text` | `--bg-terminal` | #7BE3BF | #0B0D11 | 12.58:1 | ✅ |
| `--success-text` | `--bg-panel` | #7BE3BF | #14171C | 11.62:1 | ✅ |
| `--success-text` | `--bg-selected-head` | #7BE3BF | #161B26 | 11.14:1 | ✅ |
| `--success-text` | `--bg-chrome` | #7BE3BF | #13161B | 11.73:1 | ✅ |
| `--success-card-text` | `--success-card-bg` | #CFF5E7 | #172420 | 13.64:1 | ✅ |
| `--warning-label` | `--warning-bg` | #F2B34B | #251F13 | 8.82:1 | ✅ |
| `--warning-label` | `--warning-card-bg` | #F2B34B | #211B10 | 9.22:1 | ✅ |
| `--warning-label` | `--bg-panel` | #F2B34B | #14171C | 9.69:1 | ✅ |
| `--warning-label` | `--bg-chrome` | #F2B34B | #13161B | 9.78:1 | ✅ |
| `--warning-btn-fg` | `--warning-btn-bg` | #1A1206 | #F2B34B | 10.00:1 | ✅ |
| `--warning-text` | `--warning-card-bg` | #E9D6AE | #211B10 | 11.96:1 | ✅ |
| `--warning-text` | `--warning-code-bg` | #E9D6AE | #17130B | 12.95:1 | ✅ |
| `--warning-text` | `--warning-bg` | #E9D6AE | #251F13 | 11.44:1 | ✅ |
| `--warning-text` | `--bg-chrome` | #E9D6AE | #13161B | 12.69:1 | ✅ |
| `--danger-text` | `--danger-pill-bg` | #FFA8A0 | #3A1D1D | 8.27:1 | ✅ |
| `--danger-text` | `--danger-btn-bg` | #FFA8A0 | #2A1716 | 9.22:1 | ✅ |
| `--danger-text` | `--bg-terminal` | #FFA8A0 | #0B0D11 | 10.52:1 | ✅ |
| `--danger-kbd` | `--danger-btn-bg` | #D98B84 | #2A1716 | 6.47:1 | ✅ |

dark: 52 pairs, 0 below 4.5:1
