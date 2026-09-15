# FairEdit

A non-destructive photo editor: local adjustments, curves, masking (linear/radial/luminance/color-range/brush/AI), blur, and heal — plus AI-assisted subject selection and object removal.

The repo has two parts:

| Path | What it is |
|---|---|
| [`fairedit/`](fairedit) | The Flutter app (Android/iOS/desktop) — editor UI, GPU shader pipeline, local edit state. |
| [`backend/`](backend) | FastAPI inference service (SAM 2, Grounding DINO, LaMa) that powers AI Select and AI Remove. Optional — the editor works without it, just without the AI mask types. |

## Quick start

```bash
# App
cd fairedit
flutter pub get
flutter run

# Backend (optional, for AI Select / AI Remove)
cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
pip install -r requirements.txt
python scripts/fetch_vendor.py
python scripts/download_weights.py
cp .env.example .env
uvicorn app.main:app --reload --port 8000
```

Point the app at a running backend with:

```bash
flutter run --dart-define=FAIREDIT_AI_BASE_URL=http://10.0.2.2:8000
```

See [`backend/README.md`](backend/README.md) for the API contract, Docker setup, and configuration reference.
