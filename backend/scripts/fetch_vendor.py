#!/usr/bin/env python
"""Bring in upstream inference code without vendoring whole repositories.

Two strategies, chosen per project by what upstream actually supports:

  SAM 2           pip-installable from git. Installed as a dependency, so
                  nothing is copied into this repository at all.
  Grounding DINO  pip-installable from git. Only its model *config* file
                  is copied, because `load_model` needs a path to one.
  LaMa            has no package. The inference subset of `saicinpainting/`
                  is extracted here under an explicit allowlist.

The allowlist is the point. Running this does not produce a copy of three
research repositories in your tree: it produces the ~20 modules that a
forward pass actually imports, and prints exactly what it skipped.

    python scripts/fetch_vendor.py              # everything
    python scripts/fetch_vendor.py --only lama  # just one
    python scripts/fetch_vendor.py --dry-run    # show the plan
"""

from __future__ import annotations

import argparse
import logging
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent
VENDOR_DIR = BACKEND_ROOT / "vendor"

log = logging.getLogger("fetch_vendor")


@dataclass(slots=True)
class Recipe:
    name: str
    repo: str
    ref: str

    #: Install the package with pip instead of copying its source. The
    #: right answer whenever upstream publishes an installable package —
    #: it is reuse without a fork.
    pip_install: bool = False

    #: Source paths (relative to the repo root) to copy into vendor/.
    #: A directory is copied recursively, subject to `exclude_names`.
    include: list[str] = field(default_factory=list)

    #: Directory and file names never copied, at any depth. This is what
    #: keeps training loops, notebooks and benchmarks out.
    exclude_names: set[str] = field(default_factory=set)

    notes: str = ""


#: Names that are never inference code in any of these projects.
#:
#: Deliberately does NOT contain "training". That name is ambiguous —
#: LaMa keeps its *model definitions* under `saicinpainting/training/`,
#: so a blanket exclusion silently guts the package the engine imports.
#: Ambiguous names belong to the recipe that understands them, in
#: `Recipe.exclude_names`.
GLOBAL_EXCLUDES: set[str] = {
    # Research and demo surface
    "notebooks",
    "demo",
    "demos",
    "examples",
    "docs",
    "assets",
    "figures",
    "images",
    "tools",
    # Training and evaluation harnesses (unambiguous names only)
    "benchmark",
    "benchmarks",
    "evaluation_scripts",
    "experiments",
    "configs_train",
    "datasets_gen",
    "bin",
    # Build and VCS noise
    ".git",
    ".github",
    "__pycache__",
    ".pytest_cache",
    "build",
    "dist",
    "tests",
    "test",
}

RECIPES: dict[str, Recipe] = {
    "sam2": Recipe(
        name="sam2",
        repo="https://github.com/facebookresearch/sam2.git",
        ref="main",
        pip_install=True,
        notes=(
            "Installed as a package. Inference entry points used by "
            "app/engines/sam2_engine.py: build_sam.build_sam2, "
            "sam2_image_predictor.SAM2ImagePredictor, "
            "automatic_mask_generator.SAM2AutomaticMaskGenerator."
        ),
    ),
    "groundingdino": Recipe(
        name="groundingdino",
        repo="https://github.com/IDEA-Research/GroundingDINO.git",
        ref="main",
        pip_install=True,
        # load_model() takes a filesystem path to the model config, so
        # that one file has to exist locally even though the package
        # itself is pip-installed.
        include=["groundingdino/config/GroundingDINO_SwinT_OGC.py"],
        notes=(
            "Installed as a package; only the model config file is copied. "
            "Inference entry points used by app/engines/grounding_engine.py: "
            "util.inference.load_model, util.inference.predict, "
            "datasets.transforms."
        ),
    ),
    "lama": Recipe(
        name="lama",
        repo="https://github.com/advimman/lama.git",
        ref="main",
        pip_install=False,
        # The import closure of load_checkpoint() plus the generator
        # modules it instantiates. `training/` is included because that is
        # where LaMa puts its *model definitions* - the trainer module is
        # what builds the network, even at inference time.
        include=[
            "saicinpainting/__init__.py",
            "saicinpainting/utils.py",
            "saicinpainting/training",
            # The whole evaluation package, not a hand-picked subset. The
            # trainer imports `evaluation.evaluator` at module scope, and
            # picking files one at a time just moves the next
            # ModuleNotFoundError further down the import chain. The
            # package is small; the exclusions below carve out what is
            # genuinely training-only.
            "saicinpainting/evaluation",
            # LaMa's ade20k segmentation network, at the repository root.
            # Pulled in transitively: trainers/base.py imports
            # `make_evaluator` at module scope, the evaluator imports the
            # perceptual metrics, and those import this. None of it runs
            # during an inpaint — but the import has to resolve for
            # load_checkpoint() to be importable at all.
            "models",
        ],
        # Deliberately a short exclusion list.
        #
        # LaMa's import graph is entangled: the trainer imports the
        # evaluator, which imports the evaluation metrics, which live in
        # a package called `losses`. Three separate attempts to carve
        # this up by directory name each moved the failure one import
        # further down the chain. The honest boundary for this
        # repository is "the saicinpainting package minus what is
        # unambiguously training-only", and the cost of the few extra
        # modules is a handful of files that are never called at
        # inference — much cheaper than an allowlist that breaks every
        # time upstream moves an import.
        exclude_names={
            "visualizers",
            "trainers_legacy",
            "scripts",
        },
        # `training/data` looks like pure training code and is not — the
        # trainer imports it at module scope, so excluding it breaks
        # `from saicinpainting.training.trainers import load_checkpoint`
        # outright. The import closure is derived by running the import,
        # not by reading directory names.
        notes=(
            "No upstream package exists, so the inference subset is "
            "extracted here. Used by app/engines/lama_engine.py: "
            "training.trainers.load_checkpoint."
        ),
    ),
}


def run_git_clone(repo: str, ref: str, destination: Path) -> None:
    """Shallow single-branch clone — the history is irrelevant and these
    repositories carry large assets in theirs."""
    log.info("cloning %s @ %s", repo, ref)
    subprocess.run(
        [
            "git",
            "clone",
            "--depth",
            "1",
            "--branch",
            ref,
            "--single-branch",
            repo,
            str(destination),
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def pip_install_from_git(repo: str, ref: str) -> None:
    target = f"git+{repo}@{ref}"
    log.info("pip install %s", target)
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--no-cache-dir", target],
        check=True,
    )


def copy_subset(
    source_root: Path,
    recipe: Recipe,
    destination_root: Path,
    *,
    dry_run: bool,
) -> tuple[int, int]:
    """Copies only `recipe.include`, minus every excluded name.

    Returns (copied, skipped) file counts so the run can report what it
    left behind — the number that shows the allowlist is doing its job.
    """
    excludes = GLOBAL_EXCLUDES | recipe.exclude_names
    copied = skipped = 0

    def is_excluded(relative_to_entry: Path) -> bool:
        """Exclusions apply strictly *below* an included path.

        Evaluated against the path relative to the entry being copied, so
        asking for `saicinpainting/training` cannot be vetoed by the name
        "training" while `training/losses` still is. Matching against the
        full path instead is what let an explicit include silently expand
        to nothing.
        """
        return any(part in excludes for part in relative_to_entry.parts)

    for entry in recipe.include:
        source = source_root / entry
        if not source.exists():
            log.warning("  missing upstream path, skipping: %s", entry)
            continue

        destination = destination_root / entry

        if source.is_file():
            if dry_run:
                log.info("  + %s", entry)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            copied += 1
            continue

        for file in sorted(source.rglob("*")):
            if not file.is_file():
                continue
            relative = file.relative_to(source_root)
            if is_excluded(file.relative_to(source)) or file.suffix in {
                ".ipynb",
                ".pth",
                ".ckpt",
            }:
                skipped += 1
                continue
            if dry_run:
                log.debug("  + %s", relative)
            else:
                target = destination_root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(file, target)
            copied += 1

    return copied, skipped


def ensure_namespace_packages(root: Path) -> None:
    """Adds any missing `__init__.py` so a partially-copied tree still
    imports. Extracting a subset of a package can leave an intermediate
    directory without its initialiser."""
    for directory in root.rglob("*"):
        if not directory.is_dir() or "__pycache__" in directory.parts:
            continue
        if any(child.suffix == ".py" for child in directory.iterdir()):
            init = directory / "__init__.py"
            if not init.exists():
                init.touch()


def process(recipe: Recipe, *, dry_run: bool) -> None:
    log.info("--- %s ---", recipe.name)
    log.info("%s", recipe.notes)

    if recipe.pip_install:
        if dry_run:
            log.info("  would pip install git+%s@%s", recipe.repo, recipe.ref)
        else:
            pip_install_from_git(recipe.repo, recipe.ref)
        if not recipe.include:
            return

    with tempfile.TemporaryDirectory(prefix=f"fairedit-{recipe.name}-") as tmp:
        clone_dir = Path(tmp) / "repo"
        if dry_run and recipe.pip_install and not recipe.include:
            return
        run_git_clone(recipe.repo, recipe.ref, clone_dir)
        copied, skipped = copy_subset(
            clone_dir, recipe, VENDOR_DIR, dry_run=dry_run
        )
        log.info(
            "  extracted %d inference file(s); left %d file(s) upstream",
            copied,
            skipped,
        )
        # An allowlist that quietly matches nothing is worse than one that
        # errors: the service then fails later, at model-load time, with a
        # message that points nowhere near the real cause.
        if copied < len(recipe.include):
            raise RuntimeError(
                f"{recipe.name}: {len(recipe.include)} paths requested but only "
                f"{copied} file(s) copied — an include is being vetoed by an "
                f"exclude rule, or upstream moved it"
            )

    if not dry_run:
        ensure_namespace_packages(VENDOR_DIR)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only",
        choices=sorted(RECIPES),
        action="append",
        help="Process only these projects (repeatable).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the plan without installing or copying anything.",
    )
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(message)s",
    )

    VENDOR_DIR.mkdir(parents=True, exist_ok=True)
    selected = args.only or list(RECIPES)

    for name in selected:
        try:
            process(RECIPES[name], dry_run=args.dry_run)
        except subprocess.CalledProcessError as exc:
            log.error("%s failed: %s", name, exc.stderr or exc)
            return 1

    log.info("")
    log.info("Done. Next: python scripts/download_weights.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
