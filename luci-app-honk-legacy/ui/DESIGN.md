# Honk Quick Setup UI

The Quick Setup view extends the existing Honk dashboard tokens: cool blue
primary actions, warm warning accents, 8px panels, compact 14px body text and
Lucide icons. Panels are used for repeated controls and review output; the
page remains an unframed vertical workflow. Focus rings use the existing
primary token and every disabled state keeps its reserved layout size.

Responsive contracts:

- 375px: one-column controls, full-width actions, no horizontal scrolling.
- 768px: two-column network and preset controls when both fit.
- 1280px: constrained content with a stable review column and readable diff.

Accepted debt: the legacy Config view retains its existing editor styling and
translation coverage while Quick Setup uses the API contract's stable English
identifiers for status codes.
