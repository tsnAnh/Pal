import argparse
import sys
from collections import Counter

from PIL import Image

SCALE = 3


def parse_point(text):
    try:
        x, y = text.split(",")
        return int(x), int(y)
    except ValueError:
        raise argparse.ArgumentTypeError(f"point must be x,y integers: {text!r}")


def hex_of(pixel):
    return "#{:02x}{:02x}{:02x}".format(*pixel[:3])


def mean_color(image, x, y, radius):
    xs = range(max(0, x - radius), min(image.width, x + radius + 1))
    ys = range(max(0, y - radius), min(image.height, y + radius + 1))
    pixels = [image.getpixel((px, py))[:3] for px in xs for py in ys]
    if not pixels:
        raise SystemExit(f"point {x},{y} is outside {image.width}x{image.height}")
    count = len(pixels)
    return tuple(round(sum(channel) / count) for channel in zip(*pixels))


def sample(image, points, radius):
    for x, y in points:
        color = mean_color(image, x, y, radius)
        print(f"{x},{y}\t{hex_of(color)}\trgb({color[0]},{color[1]},{color[2]})\t@pt({x / SCALE:.1f},{y / SCALE:.1f})")


def emit_run(first, last, color):
    length = last - first + 1
    print(f"{first}-{last}\tlen={length}px/{length / SCALE:.1f}pt\t{hex_of(color)}")


def runs(image, axis, fixed, start, end, tolerance):
    if axis == "row":
        coords = [(position, fixed) for position in range(start, end)]
    else:
        coords = [(fixed, position) for position in range(start, end)]
    current = None
    begin = start
    for index, (x, y) in enumerate(coords):
        color = image.getpixel((x, y))[:3]
        if current is None:
            current, begin = color, start + index
            continue
        if max(abs(a - b) for a, b in zip(color, current)) > tolerance:
            emit_run(begin, start + index - 1, current)
            current, begin = color, start + index
    if current is not None:
        emit_run(begin, end - 1, current)


def pixels_of(image, box):
    region = image.crop(box).convert("RGB")
    raw = region.tobytes()
    return [tuple(raw[index:index + 3]) for index in range(0, len(raw), 3)]


def dominant(image, box, top):
    counts = Counter(pixels_of(image, box))
    for color, count in counts.most_common(top):
        print(f"{hex_of(color)}\t{count}px")


def ink(image, box, top):
    pixels = pixels_of(image, box)
    background = Counter(pixels).most_common(1)[0][0]
    farthest = sorted(pixels, key=lambda pixel: -sum(abs(a - b) for a, b in zip(pixel, background)))[:top]
    mean = tuple(round(sum(channel) / len(farthest)) for channel in zip(*farthest))
    print(f"background {hex_of(background)}\tink {hex_of(mean)}\t(mean of {top} farthest pixels)")


def bbox(image, box, threshold):
    x0, y0, x1, _ = box
    pixels = pixels_of(image, box)
    width = x1 - x0
    background = Counter(pixels).most_common(1)[0][0]
    hits = [
        (x0 + index % width, y0 + index // width)
        for index, pixel in enumerate(pixels)
        if max(abs(a - b) for a, b in zip(pixel, background)) > threshold
    ]
    if not hits:
        print("no ink")
        return
    left, right = min(x for x, _ in hits), max(x for x, _ in hits)
    top, bottom = min(y for _, y in hits), max(y for _, y in hits)
    print(
        f"x {left}-{right} ({(right - left + 1) / SCALE:.1f}pt wide)\ty {top}-{bottom} ({(bottom - top + 1) / SCALE:.1f}pt tall)\t"
        f"origin pt ({left / SCALE:.1f},{top / SCALE:.1f})"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Sample measured colors and edge positions from a 3x reference frame (pixel coordinates)."
    )
    parser.add_argument("frame")
    parser.add_argument("points", nargs="*", type=parse_point, help="x,y pixel coordinates to sample")
    parser.add_argument("--radius", type=int, default=1, help="averaging radius in pixels (default 1)")
    parser.add_argument("--row", type=int, metavar="Y", help="print color runs along row Y")
    parser.add_argument("--col", type=int, metavar="X", help="print color runs along column X")
    parser.add_argument("--from", dest="start", type=int, default=0)
    parser.add_argument("--to", dest="end", type=int, default=None)
    parser.add_argument("--tolerance", type=int, default=6, help="max channel delta inside one run")
    parser.add_argument("--dominant", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"), help="most common colors in a box")
    parser.add_argument("--ink", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"), help="text ink color against the box background")
    parser.add_argument("--bbox", nargs=4, type=int, metavar=("X0", "Y0", "X1", "Y1"), help="bounding box of ink differing from the box background")
    parser.add_argument("--threshold", type=int, default=40, help="channel delta that counts as ink for --bbox")
    parser.add_argument("--top", type=int, default=5)
    args = parser.parse_args()

    image = Image.open(args.frame).convert("RGB")
    if args.points:
        sample(image, args.points, args.radius)
    if args.row is not None:
        runs(image, "row", args.row, args.start, args.end or image.width, args.tolerance)
    if args.col is not None:
        runs(image, "col", args.col, args.start, args.end or image.height, args.tolerance)
    if args.dominant:
        dominant(image, tuple(args.dominant), args.top)
    if args.ink:
        ink(image, tuple(args.ink), args.top if args.top != 5 else 12)
    if args.bbox:
        bbox(image, tuple(args.bbox), args.threshold)
    if not (args.points or args.row is not None or args.col is not None or args.dominant or args.ink or args.bbox):
        parser.error("give points, --row, --col, --dominant, --ink or --bbox")


if __name__ == "__main__":
    sys.exit(main())
