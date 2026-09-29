"""Bakes the 银幕 family: Kodak Vision3 negatives printed on Kodak 2383 / 2393, simulated by spektrafilm.

A finished photo is display light. Each lattice point is expanded back to scene light the same way as
Tools/ImportHalideLUTs.swift (inverse extended Reinhard on the max channel, display white to 12,
18% gray kept at 18%), exposed on the negative, printed, and projected. spektrafilm runs in its LUT
mode, so grain, halation, couplers' spatial diffusion and auto exposure are all off; the app adds its
own finish on top.

    uv venv -p 3.13 /tmp/sf/venv && git clone --depth 1 https://github.com/andreavolpato/spektrafilm /tmp/sf/spektrafilm
    uv pip install --python /tmp/sf/venv numpy scipy colour-science scikit-image matplotlib opt-einsum numba \
        OpenImageIO pyfftw rawpy exiv2 lensfunpy Pillow
    uv pip install --python /tmp/sf/venv --no-deps -e /tmp/sf/spektrafilm   # skips the GUI's PySide6 and napari
    /tmp/sf/venv/bin/python Tools/BakeScreenLUTs.py probe     # gray ramp per look
    /tmp/sf/venv/bin/python Tools/BakeScreenLUTs.py bake      # Resources/ScreenLUTs/*.png
    /tmp/sf/venv/bin/python Tools/BakeScreenLUTs.py chart OUT # test chart through each baked LUT

Writes 512×512 PNGs: 8×8 tiles, blue 0 top-left, red across, green down.
"""

import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from spektrafilm.runtime.params_builder import digest_params, init_params
from spektrafilm.runtime.pipeline import SimulationPipeline

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "AngieFilter/Resources/ScreenLUTs"
LATTICE = 64
TILE = 512
SCENE_WHITE = 12.0


@dataclass
class Stock:
    id: str
    film: str
    paper: str
    # Kodak CC points on top of the filters that print gray neutral. More yellow prints bluer, more magenta
    # prints greener.
    y: float = 0.0
    m: float = 0.0
    # False skips the neutral solve and keeps only the database print filters plus `y` and `m`.
    neutral: bool = True
    # Veiling glare added to scene light before the negative, as a fraction of it. Lifts the print's
    # shadows out of 2383's toe; without it -3 EV prints at 0.035.
    flare: float = 0.012


STOCKS = [
    Stock("screen-250d", "kodak_vision3_250d", "kodak_2383"),
    Stock("screen-50d", "kodak_vision3_50d", "kodak_2383", flare=0.008),
    Stock("screen-200t", "kodak_vision3_200t", "kodak_2383", y=-5, m=-1.5),
    Stock("screen-golden", "kodak_vision3_250d", "kodak_2383", y=-10, m=-3, flare=0.014),
    Stock("screen-500t", "kodak_vision3_500t", "kodak_2383", y=3, m=1, flare=0.018),
    Stock("screen-500t-blue", "kodak_vision3_500t", "kodak_2383", y=10, neutral=False, flare=0.018),
    Stock("screen-premier", "kodak_vision3_250d", "kodak_2393", flare=0.005),
]


def srgb_decode(v):
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def srgb_encode(v):
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * v ** (1 / 2.4) - 0.055)


def expanded_reinhard(m):
    """Solves m = s(1 + s/W²)/(1 + s) for s, so display 1 maps to W."""
    w2 = SCENE_WHITE * SCENE_WHITE
    b = 1 - m
    return (-b + np.sqrt(b * b + 4 * m / w2)) * w2 / 2


GRAY_SCALE = 0.18 / expanded_reinhard(0.18)


LUMA = np.array([0.2126, 0.7152, 0.0722])


def scene_light(linear):
    """Expands on how close to white a pixel is, half luminance and half the lowest channel, not on the
    max channel: a saturated red or yellow at display 1 is a bright color, not a highlight six stops
    over, and would burn out on the negative."""
    norm = ((linear @ LUMA + linear.min(axis=-1)) / 2)[..., None]
    safe = np.maximum(norm, 1e-8)
    return np.where(norm > 0, linear * (expanded_reinhard(np.minimum(safe, 1)) * GRAY_SCALE / safe), 0)


# Display white after expansion, the brightest thing a photo holds.
WHITE = np.full((1, 3), SCENE_WHITE)
GRAY = np.full((1, 3), 0.18)
# Where printed mid gray lands, in sRGB code values.
GRAY_TARGET = 0.46


class Print:
    """One negative and print setup. Output is scaled per channel so display white prints as white:
    2383 alone tops out near 0.88 and slightly warm, which reads as a dull highlight on a phone."""

    def __init__(self, stock: Stock, exposure: float, y: float, m: float):
        self.exposure, self.y, self.m = exposure, y, m
        self.flare = stock.flare
        p = init_params(film_profile=stock.film, print_profile=stock.paper)
        p.debug.lut_mode = True
        p.io.input_color_space = "sRGB"
        p.io.output_color_space = "sRGB"
        p.io.input_cctf_decoding = False
        p.io.output_cctf_encoding = False
        p.enlarger.y_filter_shift = y
        p.enlarger.m_filter_shift = m
        self.pipeline = SimulationPipeline(digest_params(p))
        # lut_mode resets print exposure while digesting.
        self.pipeline.soft_update(print_exposure=exposure)
        self.white = self.raw(WHITE)[0]

    def raw(self, scene):
        shape = scene.shape
        flat = (scene + self.flare).reshape(1, -1, 3).astype(np.float32)
        return np.asarray(self.pipeline.process(flat), dtype=np.float64).reshape(shape)

    def __call__(self, scene):
        return self.raw(scene) / self.white

    def gray(self):
        return srgb_encode(self(GRAY))[0]


def level(p: Print):
    return np.array([p.gray() @ LUMA - GRAY_TARGET])


def cast(p: Print):
    """Gray level, then blue and red against green."""
    v = p.gray()
    return np.array([v @ LUMA - GRAY_TARGET, v[2] - v[1], v[0] - v[1]])


def newton(make, x, residual, steps):
    for _ in range(8):
        p = make(x)
        r = residual(p)
        if np.abs(r).max() < 0.002:
            break
        jacobian = np.column_stack([
            (residual(make(x + np.eye(len(x))[i] * h)) - r) / h for i, h in enumerate(steps)
        ])
        x = x - np.linalg.solve(jacobian, r)
    return x


def solve(stock: Stock) -> Print:
    """Print exposure sets the gray level; the yellow and magenta CC print it neutral before the look's
    own shift goes on top. Camera EV does nothing here: spektrafilm compensates it in the print."""
    exposure, y, m = 1.0, 0.0, 0.0
    if stock.neutral:
        exposure, y, m = newton(lambda x: Print(stock, *x), np.array([1.0, 0.0, 0.0]), cast, [0.05, 2.0, 2.0])
    y, m = y + stock.y, m + stock.m
    (exposure,) = newton(lambda x: Print(stock, x[0], y, m), np.array([exposure]), level, [0.05])
    return Print(stock, exposure, y, m)


def probe():
    stops = np.arange(-8, 7)
    ramp = np.repeat((0.18 * 2.0 ** stops)[:, None], 3, axis=1)
    for stock in STOCKS:
        t = time.time()
        p = solve(stock)
        out = srgb_encode(p(ramp))
        print(f"{stock.id}  print {p.exposure:.2f} y {p.y:+.1f} m {p.m:+.1f}  ({time.time() - t:.1f}s)")
        for s, v in zip(stops, out):
            print(f"  {s:+d} EV  {v[0]:.3f} {v[1]:.3f} {v[2]:.3f}")


def lattice_input():
    """(blue, green, red) grid of sRGB code values, red fastest."""
    axis = np.arange(LATTICE) / (LATTICE - 1)
    b, g, r = np.meshgrid(axis, axis, axis, indexing="ij")
    return np.stack((r, g, b), axis=-1)


def bake_one(stock: Stock):
    p = solve(stock)
    code = lattice_input()
    out = srgb_encode(p(scene_light(srgb_decode(code))))
    pixels = np.zeros((TILE, TILE, 3), dtype=np.uint8)
    values = np.round(out * 255).astype(np.uint8)
    for blue in range(LATTICE):
        ox, oy = (blue % 8) * LATTICE, (blue // 8) * LATTICE
        pixels[oy:oy + LATTICE, ox:ox + LATTICE] = values[blue]
    Image.fromarray(pixels, "RGB").save(OUT / f"{stock.id}.png")
    print(f"{stock.id}  print {p.exposure:.2f} y {p.y:+.1f} m {p.m:+.1f}")


def bake():
    OUT.mkdir(parents=True, exist_ok=True)
    wanted = {f"{s.id}.png" for s in STOCKS}
    for stock in STOCKS:
        bake_one(stock)
    for file in OUT.glob("*.png"):
        if file.name not in wanted:
            file.unlink()


# MARK: - Chart

def load_lut(path: Path):
    tiles = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255
    cube = np.zeros((LATTICE, LATTICE, LATTICE, 3))
    for blue in range(LATTICE):
        ox, oy = (blue % 8) * LATTICE, (blue // 8) * LATTICE
        cube[blue] = tiles[oy:oy + LATTICE, ox:ox + LATTICE]
    return cube


def apply_lut(cube, image):
    q = np.clip(image, 0, 1) * (LATTICE - 1)
    i = np.minimum(q.astype(int), LATTICE - 2)
    t = q - i
    out = np.zeros_like(image)
    for db in (0, 1):
        for dg in (0, 1):
            for dr in (0, 1):
                w = ((t[..., 0] if dr else 1 - t[..., 0])
                     * (t[..., 1] if dg else 1 - t[..., 1])
                     * (t[..., 2] if db else 1 - t[..., 2]))
                out += w[..., None] * cube[i[..., 2] + db, i[..., 1] + dg, i[..., 0] + dr]
    return out


def chart():
    """ColorChecker, a skin row, a hue sweep, and a gray ramp, all sRGB code values."""
    import colour
    checker = colour.CCS_COLOURCHECKERS["ColorChecker24 - After November 2014"]
    xyz = colour.xyY_to_XYZ(np.array(list(checker.data.values())))
    patches = srgb_encode(colour.XYZ_to_RGB(xyz, "sRGB", illuminant=checker.illuminant))
    cell = 48
    rows = [patches[:6], patches[6:12], patches[12:18], patches[18:]]
    skin = np.array([[0.96, 0.80, 0.69], [0.90, 0.72, 0.60], [0.80, 0.60, 0.48],
                     [0.66, 0.46, 0.35], [0.50, 0.34, 0.25], [0.33, 0.22, 0.16]])
    rows.append(skin)
    width = cell * 6
    block = np.concatenate([np.repeat(np.repeat(r[None], cell, 0), cell, 1) for r in rows], 0)
    hue = np.linspace(0, 1, width, endpoint=False)
    import colorsys
    sweep = np.array([[colorsys.hsv_to_rgb(h, s, v) for h in hue]
                      for s, v in [(1, 1), (0.6, 1), (1, 0.6), (0.4, 0.5)]])
    sweep = np.repeat(sweep, cell // 2, 0)
    ramp = np.repeat(np.linspace(0, 1, width)[None, :, None], cell, 0).repeat(3, 2)
    return np.concatenate((block, sweep, ramp), 0)


def render_chart(out_path: Path, compare: list[Path]):
    base = chart()
    columns = [base]
    names = ["原图"]
    for stock in STOCKS:
        columns.append(apply_lut(load_lut(OUT / f"{stock.id}.png"), base))
        names.append(stock.id)
    for path in compare:
        columns.append(apply_lut(load_lut(path), base))
        names.append(path.stem)
    gap = np.ones((base.shape[0], 6, 3))
    sheet = np.concatenate([c for col in columns for c in (col, gap)][:-1], 1)
    Image.fromarray(np.round(np.clip(sheet, 0, 1) * 255).astype(np.uint8), "RGB").save(out_path)
    print("columns:", " | ".join(names))


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "bake"
    if command == "probe":
        probe()
    elif command == "bake":
        bake()
    elif command == "chart":
        render_chart(Path(sys.argv[2]), [Path(p) for p in sys.argv[3:]])
    else:
        sys.exit(f"unknown command {command}")
