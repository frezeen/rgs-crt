# Docs map (two places, by design)

- **This folder = the USER manual** (ships to the public mirror): effects
  language, setup, profiles, updates — never engine internals.
- **`src/engine/docs/` = the ENGINE dev docs** (never exported): mechanism
  contracts, incident knowledge, ADRs (see `adr/adr-002-display-reconciler.md`).

Why two: the mirror export set ships only the user surface (gift
discipline), so engine internals must not travel with it. This is an
export boundary, not duplication.
