#!/usr/bin/env python3
"""immpy.py -- Python 3 implementations of the operations previously embedded as
Python 2 heredocs inside IMAGINGlib.sh.

Each former heredoc becomes a function here and a ``python3 -m immpy <op> ...``
CLI entry point, so the shell library no longer needs the (now unavailable)
``python`` binary, inline indentation-sensitive heredocs, or deprecated nibabel
APIs.

Modernization notes
--------------------
  * nibabel: ``get_data()`` -> ``np.asanyarray(img.dataobj)`` (get_data was removed
    in nibabel 5); ``get_header()`` -> ``img.header``; ``get_affine()`` -> ``img.affine``.
  * Python 3: ``print`` statements -> ``print()``; ``xrange`` -> ``range``; the
    ``imm_flip_as`` try/except had broken indentation (an IndentationError even in
    Py2) which is corrected here.
  * ``flip_as`` originally built slice expressions with ``exec`` over 48 string
    combinations. That behaviour is preserved exactly (same 48-combination search,
    same squared-difference metric, same "two metrics very close" warning), but
    implemented with real numpy indexing instead of ``exec`` on strings.
"""

from __future__ import annotations

import sys
import numpy as np
import nibabel as nib


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _load(path):
    img = nib.load(path)
    return img, np.asanyarray(img.dataobj)


def _strip_out_name(path, suffix):
    """Reproduce the original '.'-based stem logic: drop the last extension, and
    if that was '.gz' drop one more, then append suffix + '.nii.gz'."""
    stem = path[: path.rfind(".")] if "." in path else path
    if path[path.rfind("."):] == ".gz":
        stem = stem[: stem.rfind(".")]
    return stem + suffix + ".nii.gz"


# --------------------------------------------------------------------------- #
# flip  (axis-flip a 3D or 4D image, optionally borrowing a reference geometry)
# --------------------------------------------------------------------------- #
def flip(file_path_toflip, axis, filename_flipped="", reference=""):
    img, arr = _load(file_path_toflip)
    header, affine = img.header, img.affine
    reference = reference or None

    if not filename_flipped:
        filename_flipped = _strip_out_name(file_path_toflip, "_flipped" + axis)

    ax = {"X": 0, "Y": 1, "Z": 2}[axis]
    flipped = np.flip(arr, axis=ax)

    if reference is not None:
        ref = nib.load(reference)
        header, affine = ref.header, ref.affine

    nib.Nifti1Image(flipped, affine=affine, header=header).to_filename(filename_flipped)
    return filename_flipped


# --------------------------------------------------------------------------- #
# header_as  (write image data with another image's header/affine)
# --------------------------------------------------------------------------- #
def header_as(file_path, reference, filename_out):
    _, arr = _load(file_path)
    ref = nib.load(reference)
    nib.Nifti1Image(arr, affine=ref.affine, header=ref.header).to_filename(filename_out)
    return filename_out


# --------------------------------------------------------------------------- #
# flip_as  (find the axis flip/permutation of `toflip` closest to `fixed`)
# --------------------------------------------------------------------------- #
def _combinations():
    combos = []
    for perm in ([0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]):
        for fx in (False, True):
            for fy in (False, True):
                for fz in (False, True):
                    combos.append((fx, fy, fz, tuple(perm)))
    return combos


def flip_as(file_path_toflip, file_path_fixed, filename_flipped=""):
    img_t, arr_t = _load(file_path_toflip)
    img_f, arr_f = _load(file_path_fixed)
    head_fixed, affine_fixed = img_f.header, img_f.affine

    if not filename_flipped:
        filename_flipped = _strip_out_name(file_path_toflip, "_flipped")

    arr_t = np.nan_to_num(arr_t)
    arr_f = np.nan_to_num(arr_f)
    fixed_flat = arr_f.flatten()

    combos = _combinations()
    norm = np.zeros(len(combos))

    def apply_combo(a, comb):
        fx, fy, fz, perm = comb
        out = a
        if fx:
            out = out[::-1, :, :]
        if fy:
            out = out[:, ::-1, :]
        if fz:
            out = out[:, :, ::-1]
        return out.transpose(*perm)

    for idx, comb in enumerate(combos):
        flipped = apply_combo(arr_t, comb)
        diff = flipped.flatten() - fixed_flat
        norm[idx] = np.dot(diff, diff)
        print(norm[idx])

    norm_min = norm.min()
    idxx = int(np.where(norm == norm_min)[0][0])
    best = apply_combo(arr_t, combos[idxx])
    nib.Nifti1Image(best, affine=affine_fixed, header=head_fixed).to_filename(filename_flipped)
    print("Flipped file saved as: " + filename_flipped)

    # Ambiguity check: is the runner-up score within 2x of the best?
    # BUGFIX: the original tested `norm_min_new > 0.5*norm_min`, which is always true
    # when the best match is exact (norm_min == 0), spuriously writing a "second best"
    # file. Only warn on a genuine near-tie (best > 0 and runner-up within 2x).
    norm_new = norm.copy()
    norm_new[idxx] = np.finfo(norm_new.dtype).max
    norm_min_new = norm_new.min()
    if norm_min > 0 and norm_min_new < 2.0 * norm_min:
        print("Warning: found two similarity-metric values very close.")
        idxx2 = int(np.where(norm_new == norm_min_new)[0][0])
        second = apply_combo(arr_t, combos[idxx2])
        fname2 = _strip_out_name(filename_flipped, "_2nd")
        nib.Nifti1Image(second, affine=affine_fixed, header=head_fixed).to_filename(fname2)
        print("Flipped second file saved as: " + fname2)
    return filename_flipped


# --------------------------------------------------------------------------- #
# min/max Euclidean distance (mm) between two binary masks
# --------------------------------------------------------------------------- #
def _mask_distance(input1, input2, reducer):
    import scipy.spatial as scip

    img1, a1 = _load(input1)
    _, a2 = _load(input2)
    p1 = np.array(np.where(a1 == 1)).T
    p2 = np.array(np.where(a2 == 1)).T
    zooms = np.array(img1.header.get_zooms()[:3])
    d = scip.distance.cdist(p1 * zooms, p2 * zooms)
    return reducer(d)


def min_dist(input1, input2):
    print(_mask_distance(input1, input2, np.min))


def max_dist(input1, input2):
    print(_mask_distance(input1, input2, np.max))


# --------------------------------------------------------------------------- #
# 4D (>=3 volume) image -> packed RGB NIfTI
# --------------------------------------------------------------------------- #
def to_rgb(input_path, output_path):
    img, data = _load(input_path)
    data = np.nan_to_num(data)
    rgb_dtype = np.dtype([("R", "u1"), ("G", "u1"), ("B", "u1")])
    shape3d = data.shape[:3]
    out = np.zeros(shape3d, dtype=rgb_dtype)
    # Vectorized (the original triple xrange loop, without the loop).
    out["R"] = data[:, :, :, 0].astype("u1")
    out["G"] = data[:, :, :, 1].astype("u1")
    out["B"] = data[:, :, :, 2].astype("u1")
    # NB: do NOT reuse the source (float) header here -- nibabel derives the NIfTI
    # datatype from the array's structured RGB dtype, and passing a float header
    # raises "Cannot cast to or from non-numeric types". Geometry is preserved via
    # the affine. (The original heredoc reused the float header and would fail the
    # same way on modern nibabel.)
    nib.Nifti1Image(out, affine=img.affine).to_filename(output_path)
    return output_path


# --------------------------------------------------------------------------- #
# hard crop to the nonzero bounding box (+1 voxel margin where possible)
# --------------------------------------------------------------------------- #
def hardcrop(input_path, output_path):
    """Crop to the nonzero bounding box.

    Behaviour is preserved from the original: the low bound is decremented by one
    voxel (a 1-voxel lower margin) and the high bound incremented by one, then the
    array is sliced ``arr[lo:hi]``.

    NB (flagged quirk, behaviour intentionally unchanged): numpy slicing is
    half-open, so ``hi = max + 1`` with slice ``[lo:hi]`` includes voxels
    ``lo .. max`` -- i.e. a 1-voxel margin is added on the LOW side only; the high
    side sits flush against the object. If you want a symmetric 1-voxel margin,
    change ``hi[d] += 1`` to ``hi[d] += 2``. Left as-is to avoid silently changing
    output image dimensions in existing pipelines.
    """
    img, arr = _load(input_path)
    idx = np.nonzero(arr)
    lo = [int(np.min(idx[d])) for d in range(3)]
    hi = [int(np.max(idx[d])) for d in range(3)]
    for d in range(3):
        if lo[d] != 0:
            lo[d] -= 1
        if hi[d] != arr.shape[d] - 1:
            hi[d] += 1
    cropped = arr[lo[0]:hi[0], lo[1]:hi[1], lo[2]:hi[2]]
    nib.Nifti1Image(cropped, header=img.header, affine=img.affine).to_filename(output_path)
    return output_path


# --------------------------------------------------------------------------- #
# unique intensity values (used by imm_4D2RGB's shell caller)
# --------------------------------------------------------------------------- #
def unique_vals(input_path):
    _, arr = _load(input_path)
    print(np.unique(arr))


# --------------------------------------------------------------------------- #
# points2roi_filled  (convex-hull fill of a set of voxel coordinates)
# --------------------------------------------------------------------------- #
def _flood_fill_hull(image):
    from scipy.spatial import ConvexHull, Delaunay

    points = np.transpose(np.where(image))
    hull = ConvexHull(points)
    deln = Delaunay(points[hull.vertices])
    idx = np.stack(np.indices(image.shape), axis=-1)
    out_idx = np.nonzero(deln.find_simplex(idx) + 1)
    out_img = np.zeros(image.shape)
    out_img[out_idx] = 1
    return out_img, hull


def _read_points(points_file):
    """Read an Nx3 integer coordinate list.

    BUGFIX/flag: the original used pandas.read_csv with default settings, which
    treats the first row as a HEADER -- silently dropping the first coordinate.
    Here we read with no header and coerce to numeric, skipping any leading
    non-numeric (header) row if present, so no point is lost.
    """
    import pandas as pd

    df = pd.read_csv(points_file, header=None)
    arr = df.apply(pd.to_numeric, errors="coerce").to_numpy()
    arr = arr[~np.isnan(arr).any(axis=1)]  # drop a header row if it coerced to NaN
    return arr.astype(int)


def points2roi_filled(points_file, template_file, output_file):
    img = nib.load(template_file)
    template_array = np.asanyarray(img.dataobj)
    points_list = _read_points(points_file)

    roi = np.zeros_like(template_array)
    for p in points_list:
        roi[p[0], p[1], p[2]] = 1

    filled, _ = _flood_fill_hull(roi)
    nib.Nifti1Image(filled, affine=img.affine, header=img.header).to_filename(output_file)
    return output_file


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print("usage: python3 -m immpy <op> [args...]", file=sys.stderr)
        return 2
    op, rest = argv[0], argv[1:]
    table = {
        "flip": lambda: flip(*rest),
        "header_as": lambda: header_as(*rest),
        "flip_as": lambda: flip_as(*rest),
        "min_dist": lambda: min_dist(*rest),
        "max_dist": lambda: max_dist(*rest),
        "to_rgb": lambda: to_rgb(*rest),
        "hardcrop": lambda: hardcrop(*rest),
        "unique": lambda: unique_vals(*rest),
        "points2roi_filled": lambda: points2roi_filled(*rest),
    }
    if op not in table:
        print(f"immpy: unknown op '{op}'", file=sys.stderr)
        return 2
    table[op]()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
