# mapbox_nav_core Repository

Welcome to the development repository for **`mapbox_nav_core`**, a modular Flutter package providing a decoupled, vendor-neutral turn-by-turn navigation engine and Mapbox presentation layer.

[![CI](https://github.com/NasirBhotta/ors_map/actions/workflows/ci.yml/badge.svg)](https://github.com/NasirBhotta/ors_map/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/badge/pub.dev-mapbox__nav__core-blue.svg)](https://pub.dev/packages/mapbox_nav_core)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](packages/mapbox_nav_core/LICENSE)

---

## Monorepo Layout

```text
.
├── packages/
│   └── mapbox_nav_core/       # The core Flutter package (engine & Mapbox adapters)
│       ├── lib/
│       ├── test/
│       ├── example/           # Standalone example application
│       ├── README.md          # Primary package documentation
│       └── CHANGELOG.md
├── lib/                       # Host development fixture and integration app
├── test/                      # Host integration regression test suite
├── tool/                      # Local CI and release validation scripts
└── .github/                   # GitHub Actions CI workflow & issue templates
```

---

## Package Overview

For package documentation, API references, architecture guides, and getting-started tutorials, see the [Package README](packages/mapbox_nav_core/README.md).

### Quick Summary:
- **`package:mapbox_nav_core/navigation.dart`**: Pure core navigation contracts, immutable models (`GeoPoint`, `LocationFix`, `NavigationRoute`, `NavigationState`), $O(1)$ windowed route matching, binary-search progress tracking, corridor deviation rerouting, and GPS freshness monitoring.
- **`package:mapbox_nav_core/mapbox_nav_core.dart`**: Mapbox presentation adapters, `NavigationMapView` composite widget, 3D GLB vehicle model rendering, zoom-scaled route line styling, and camera tracking.

---

## Contributing & Development

Please refer to:
* **[CONTRIBUTING.md](CONTRIBUTING.md)**: Setup instructions, code formatting, running tests, and PR guidelines.
* **[SECURITY.md](SECURITY.md)**: Security reporting instructions and credential policies.

### Running Pre-flight Validation Locally
Before pushing changes or submitting a PR, run:

```powershell
# Windows
.\tool\release_check.ps1

# macOS / Linux
./tool/release_check.sh
```

---

## License

This repository and the `mapbox_nav_core` package are licensed under the [MIT License](packages/mapbox_nav_core/LICENSE).
