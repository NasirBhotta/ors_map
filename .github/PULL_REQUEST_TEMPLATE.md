## Summary
<!-- Briefly explain the motivation and summary of changes. -->

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Performance / stress optimization
- [ ] CI / Tooling improvement

## Impact & Compatibility
- **Public API Impact**: Does this PR add, remove, or modify exported symbols in `navigation.dart` or `mapbox_nav_core.dart`?
- **Mapbox Visual Parity**: Does this change affect route line rendering, 3D GLB model appearance, or camera tracking?
- **Battery & Lifecycle**: Does this change preserve background timer suspension and fix freshness evaluation?

## Checklist
- [ ] I have read the [CONTRIBUTING.md](../CONTRIBUTING.md) guide.
- [ ] My code adheres to the project's formatting guidelines (`dart format`).
- [ ] `flutter analyze` passes with zero issues on `packages/mapbox_nav_core`.
- [ ] All unit and stress tests pass (`flutter test test`).
- [ ] New or modified code is covered with automated tests.
- [ ] Documentation and dartdocs have been updated where appropriate.
- [ ] **NO secrets, API keys, or access tokens are committed.**
