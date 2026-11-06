export const accountStyle = `
:root {
  color-scheme: light dark;
  font: 100%/1.55 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
  --canvas: #f6f6f5;
  --surface: #fff;
  --ink: #222326;
  --muted: #555b62;
  --line: #d8dadd;
  --accent: #405f7a;
  --soft: #eaf0f4;
  --primary: #222326;
  --on-primary: #fff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --canvas: #171819;
    --surface: #232527;
    --ink: #f0f0f1;
    --muted: #b8bec4;
    --line: #45494d;
    --accent: #aac5da;
    --soft: #2b3944;
    --primary: #f0f0f1;
    --on-primary: #171819;
  }
}
*, *::before, *::after { box-sizing: border-box; }
body { margin: 0; background: var(--canvas); color: var(--ink); }
main { max-width: 43rem; margin: 0 auto; padding: clamp(24px, 6vw, 56px) clamp(16px, 5vw, 40px); }
.brand { font-size: .875rem; font-weight: 700; letter-spacing: .06em; color: var(--accent); margin-bottom: 24px; }
h1, h2, p { margin: 0 0 12px; }
h1 { font-size: clamp(1.85rem, 5.5vw, 2.7rem); line-height: 1.15; letter-spacing: -.04em; }
h2 { font-size: 1.125rem; line-height: 1.35; }
p, a, code, dd, td, th, summary { overflow-wrap: anywhere; }
a { color: var(--accent); text-underline-offset: .2em; }
footer { color: var(--muted); font-size: .875rem; border-top: 1px solid var(--line); padding-top: 16px; margin-top: 40px; }
.account-id, .muted { color: var(--muted); font-size: .9rem; }
.lead { color: var(--muted); margin-bottom: 24px; }
.panel, fieldset { background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: clamp(14px, 4vw, 22px); margin: 16px 0; min-inline-size: 0; }
.panel > :last-child, fieldset > :last-child { margin-bottom: 0; }
legend { font-weight: 700; padding-inline: 6px; }
.notice { background: var(--soft); border-radius: 10px; padding: 12px 16px; margin: 16px 0; }
.actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 22px; align-items: center; }
button, .button { font: inherit; min-height: 44px; cursor: pointer; border: 0; border-radius: 9px; padding: 0; background: transparent; color: inherit; }
.button { display: inline-flex; align-items: center; justify-content: center; padding: 9px 15px; text-decoration: none; font-weight: 650; }
.primary { background: var(--primary); color: var(--on-primary); }
.text-button { color: var(--accent); border: 1px solid var(--line); }
img { display: block; max-width: 100%; height: auto; }
:where(button, a, input, summary):focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
.choice { display: flex; align-items: center; gap: 10px; min-height: 44px; }
.choice + .choice { border-top: 1px solid var(--line); }
.choice input { width: 19px; height: 19px; flex: none; margin: 0; accent-color: var(--accent); }
.trip-options { margin-top: 12px; }
.scope-options:has(input[name="onlyCreated"]:checked) .trip-options { display: none; }
.search { display: flex; flex-wrap: wrap; align-items: end; gap: 8px; margin: 16px 0; }
.search label { flex: 1 1 12rem; }
input[type="search"] { width: 100%; min-height: 44px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); color: var(--ink); font: inherit; padding: 8px; }
details { margin: 14px 0; }
summary { color: var(--accent); cursor: pointer; padding-block: 10px; }
dl, dd { margin: 0; }
dt { font-weight: 600; }
dd + dt { margin-top: 10px; }
.metrics { display: flex; flex-wrap: wrap; gap: 12px 28px; margin: 16px 0; }
.metrics dt { color: var(--muted); font-size: .875rem; }
.metrics dd { font-size: 1.125rem; font-weight: 650; }
.stack { list-style: none; padding: 0; margin: 0; }
.status { color: var(--accent); font-size: .875rem; font-weight: 650; }
.review-table table { border-collapse: collapse; table-layout: fixed; width: 100%; font-size: .9rem; }
.review-table th, .review-table td { border-bottom: 1px solid var(--line); text-align: start; vertical-align: top; padding: 8px 6px; }
.review-table tbody tr:last-child > * { border-bottom: 0; }
.review-table thead { color: var(--muted); }
.review-table td:last-child { font-weight: 600; }
@media (forced-colors: active) { .button { border: 1px solid ButtonText; } }
`;
