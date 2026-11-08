import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

PREFIX = "parity-"
GUTTER = 48
GUTTER_COLOR = (60, 60, 60)
INDEX_CELL_WIDTH = 760
INDEX_GAP = 24
INDEX_COLUMNS = 3


def reference_for(reference_dir, name):
    for suffix in (".jpg", ".jpeg", ".png"):
        candidate = reference_dir / f"{name}{suffix}"
        if candidate.exists():
            return candidate
    return None


def compose(ours_path, reference_path, destination):
    reference = Image.open(reference_path).convert("RGB")
    ours = Image.open(ours_path).convert("RGB")
    scale = reference.height / ours.height
    ours = ours.resize((round(ours.width * scale), reference.height), Image.LANCZOS)
    sheet = Image.new("RGB", (ours.width + GUTTER + reference.width, reference.height), GUTTER_COLOR)
    sheet.paste(ours, (0, 0))
    sheet.paste(reference, (ours.width + GUTTER, 0))
    sheet.save(destination)
    return sheet


def write_index(composites, destination):
    thumbnails = []
    for name, sheet in composites:
        height = round(sheet.height * INDEX_CELL_WIDTH / sheet.width)
        thumbnails.append((name, sheet.resize((INDEX_CELL_WIDTH, height), Image.LANCZOS)))
    label_height = 28
    rows = [thumbnails[index:index + INDEX_COLUMNS] for index in range(0, len(thumbnails), INDEX_COLUMNS)]
    row_heights = [max(image.height for _, image in row) + label_height for row in rows]
    width = INDEX_COLUMNS * INDEX_CELL_WIDTH + (INDEX_COLUMNS + 1) * INDEX_GAP
    height = sum(row_heights) + (len(rows) + 1) * INDEX_GAP
    index = Image.new("RGB", (width, height), (24, 24, 24))
    draw = ImageDraw.Draw(index)
    top = INDEX_GAP
    for row, row_height in zip(rows, row_heights):
        for column, (name, image) in enumerate(row):
            left = INDEX_GAP + column * (INDEX_CELL_WIDTH + INDEX_GAP)
            draw.text((left, top + 6), f"{name}   ours | reference", fill=(220, 220, 220))
            index.paste(image, (left, top + label_height))
        top += row_height + INDEX_GAP
    index.save(destination)


def main():
    parser = argparse.ArgumentParser(description="Compose ours | reference parity images from parity-<ref-name>.png screenshots.")
    parser.add_argument("--shots", required=True, type=Path, help="directory holding parity-<ref-name>.png from a drive run")
    parser.add_argument("--reference-dir", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    shots = sorted(args.shots.glob(f"{PREFIX}*.png"))
    if not shots:
        print(f"no {PREFIX}*.png screenshots in {args.shots}", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    composites = []
    missing = []
    for shot in shots:
        name = shot.stem[len(PREFIX):]
        reference = reference_for(args.reference_dir, name)
        if reference is None:
            missing.append(name)
            continue
        destination = args.out / f"{name}.png"
        composites.append((name, compose(shot, reference, destination)))
        print(destination)
    if composites:
        write_index(composites, args.out / "index.png")
        print(args.out / "index.png")
    for name in missing:
        print(f"no reference frame for {name} in {args.reference_dir}", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
