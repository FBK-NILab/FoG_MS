#!/usr/bin/env python3
"""csvpack.py -- minimal CSV <-> NumPy array I/O.

Reconstructed (2026) to match the interface expected by IMAGINGlib.sh's
``imm_reshapeConn`` after the original helper was lost. Two functions are
provided: :func:`csv2array` and :func:`array2csv`.

Assumptions (per project decision):
  * CSV files are HEADERLESS and purely numeric (no index column, no labels).
  * The default on-disk separator is whitespace, but any single-character
    delimiter can be passed. ``csv2array`` sniffs comma vs whitespace so it
    reads both the original space-separated connectomes and comma CSVs.

The original module's exact internals are unknown; this reimplementation is
defined by its call site (a connectome loaded, sliced as ``arr[1::2, 1::2]``
etc., recombined and written back out space-separated). If you relied on any
behaviour beyond "load a numeric matrix / write a numeric matrix", verify it
against a known file.
"""

from __future__ import annotations

import numpy as np


def csv2array(path, separator=None, dtype=float):
    """Load a headerless numeric CSV into a 2D NumPy array.

    Parameters
    ----------
    path : str
        Path to the CSV/TSV/whitespace-delimited text file.
    separator : str, optional
        Field delimiter. If ``None`` (default) the delimiter is auto-detected:
        a comma if the first non-empty line contains one, otherwise any run of
        whitespace. Pass an explicit value (e.g. ``","`` or ``" "``) to force it.
    dtype : data-type, optional
        Element dtype of the returned array (default ``float``).

    Returns
    -------
    numpy.ndarray
        A 2D array. A single-row or single-column file is still returned as 2D
        (shape ``(1, N)`` / ``(N, 1)``) so that ``arr[a::b, c::d]`` slicing in
        the callers behaves predictably.

    Notes
    -----
    Auto-detection only inspects the first non-empty line. If your files mix
    delimiters, pass ``separator`` explicitly.
    """
    if separator is None:
        sep_for_np = None  # numpy: any whitespace
        with open(path, "r") as fh:
            for line in fh:
                if line.strip():
                    if "," in line:
                        sep_for_np = ","
                    break
    else:
        sep_for_np = separator

    arr = np.genfromtxt(path, delimiter=sep_for_np, dtype=dtype)
    return np.atleast_2d(arr)


def array2csv(array, output, separator=" ", fmt="%.10g"):
    """Write a NumPy array to a headerless text file.

    Parameters
    ----------
    array : array_like
        The array (or nested sequence) to write. Coerced to at least 2D.
    output : str
        Destination path.
    separator : str, optional
        Field delimiter to write between columns (default a single space, to
        match the original space-separated connectome output).
    fmt : str, optional
        printf-style format for each value (default ``"%.10g"``, which keeps
        integers compact and preserves float precision without trailing zeros).

    Returns
    -------
    str
        The ``output`` path that was written.
    """
    arr = np.atleast_2d(np.asarray(array))
    np.savetxt(output, arr, delimiter=separator, fmt=fmt)
    return output


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="CSV <-> NumPy round-trip / inspect.")
    ap.add_argument("csv", help="input headerless numeric CSV")
    ap.add_argument("-s", "--separator", default=None, help="input delimiter (auto if omitted)")
    args = ap.parse_args()
    a = csv2array(args.csv, separator=args.separator)
    print(f"shape={a.shape} dtype={a.dtype}")
