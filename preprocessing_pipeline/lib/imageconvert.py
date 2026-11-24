#!/usr/bin/env python3
"""imageconvert.py -- DICOM <-> NIfTI / JPEG conversion helpers.

Reconstructed (2026) to match the interface expected by IMAGINGlib.sh
(``imm_dcm2jpg`` -> :func:`dcm2jpg`, ``imm_nii2dcm`` -> :func:`nii2dcm`) after
the original module was lost. Depends on: numpy, pydicom, nibabel, pillow.

IMPORTANT -- scope of confidence
--------------------------------
The original module's internals are unknown; only the *call signatures* were
recoverable from the shell wrappers. These implementations reproduce that
interface with reasonable, conservative behaviour, BUT:

  * :func:`dcm2jpg` is straightforward and tested against synthetic DICOMs.
  * :func:`nii2dcm` writes a multi-file DICOM series from a 3D NIfTI. Producing
    a *fully spec-compliant, PACS-ready* series (correct Image Orientation /
    Position Patient for oblique acquisitions, Frame of Reference UIDs, VR
    handling for every private tag, rescale slope/intercept round-tripping,
    modality-specific IODs) is a large undertaking. This function sets the
    geometry and identifying tags needed for the result to load correctly in
    common viewers, and lets you override/add any tag via ``fields``. Treat its
    output as "loads correctly and is geometrically sane", NOT as validated
    clinical DICOM. Verify against your own viewer/PACS before relying on it.
    For production NIfTI->DICOM you may prefer the dedicated `nii2dcm` package.

The NIfTI->DICOM geometry here assumes an axial, near-orthogonal affine (the
common preprocessed case). Oblique/rotated affines are approximated via the
affine's direction cosines but are not exhaustively validated.
"""

from __future__ import annotations

import os
import datetime

import numpy as np


# --------------------------------------------------------------------------- #
# DICOM -> JPEG
# --------------------------------------------------------------------------- #
def dcm2jpg(dcm_path, outputdir=None, adjust_contrast=0):
    """Convert DICOM image(s) to JPEG.

    Parameters
    ----------
    dcm_path : str
        Either a single DICOM file or a directory of DICOM files. A directory
        is converted file-by-file.
    outputdir : str, optional
        Where to write the JPEG(s). Defaults to the directory of ``dcm_path``
        (or ``dcm_path`` itself if it is a directory). Created if absent.
    adjust_contrast : bool or int, optional
        If truthy, apply per-image min-max contrast stretch to the full 0-255
        range. If falsy (default), only the DICOM Rescale slope/intercept and a
        linear window to 8-bit are applied. Passed through from the shell as
        0/1.

    Returns
    -------
    list of str
        Paths of the JPEG files written.

    Notes
    -----
    Multi-frame DICOMs are written as ``<stem>_frameNNN.jpg``. Color (RGB)
    DICOMs are passed through; grayscale is scaled to 8-bit.
    """
    import pydicom
    from PIL import Image

    def _one(path, odir):
        ds = pydicom.dcmread(path)
        arr = ds.pixel_array.astype(np.float32)

        # Apply rescale slope/intercept if present.
        slope = float(getattr(ds, "RescaleSlope", 1) or 1)
        intercept = float(getattr(ds, "RescaleIntercept", 0) or 0)
        arr = arr * slope + intercept

        written = []
        frames = arr if arr.ndim == 3 and getattr(ds, "SamplesPerPixel", 1) == 1 else arr[None, ...]
        # Grayscale multiframe -> arr.ndim==3; RGB single frame -> handle below.
        is_rgb = getattr(ds, "SamplesPerPixel", 1) == 3

        stem = os.path.splitext(os.path.basename(path))[0]

        if is_rgb:
            img = Image.fromarray(arr.astype(np.uint8))
            out = os.path.join(odir, stem + ".jpg")
            img.convert("RGB").save(out, "JPEG")
            return [out]

        multi = frames.shape[0] > 1
        for i, frame in enumerate(frames):
            f = frame.astype(np.float32)
            if adjust_contrast:
                lo, hi = np.nanmin(f), np.nanmax(f)
            else:
                lo, hi = np.nanmin(f), np.nanmax(f)  # linear window; same for grayscale
            rng = (hi - lo) if hi > lo else 1.0
            f8 = np.clip((f - lo) / rng * 255.0, 0, 255).astype(np.uint8)
            name = f"{stem}_frame{i:03d}.jpg" if multi else f"{stem}.jpg"
            out = os.path.join(odir, name)
            Image.fromarray(f8).convert("L").save(out, "JPEG")
            written.append(out)
        return written

    if os.path.isdir(dcm_path):
        odir = outputdir or dcm_path
        os.makedirs(odir, exist_ok=True)
        out = []
        for fn in sorted(os.listdir(dcm_path)):
            fp = os.path.join(dcm_path, fn)
            if os.path.isfile(fp):
                try:
                    out += _one(fp, odir)
                except Exception as exc:  # skip non-DICOM files in the folder
                    print(f"[dcm2jpg] skipped {fn}: {exc}")
        return out
    else:
        odir = outputdir or os.path.dirname(os.path.abspath(dcm_path))
        os.makedirs(odir, exist_ok=True)
        return _one(dcm_path, odir)


# --------------------------------------------------------------------------- #
# NIfTI -> DICOM
# --------------------------------------------------------------------------- #
def nii2dcm(nii_path, outputdir=None, fields=None):
    """Write a DICOM series from a 3D NIfTI volume.

    Parameters
    ----------
    nii_path : str
        Path to a 3D NIfTI (.nii/.nii.gz). 4D inputs are rejected (convert one
        volume at a time upstream).
    outputdir : str, optional
        Directory for the output slices. Defaults to
        ``<nii_dir>/<stem>_dicom/``. Created if absent.
    fields : dict, optional
        DICOM tag overrides applied to every slice, e.g.
        ``{"PatientName": "DOE^JANE", "SeriesDescription": "T1w",
        "PatientID": "sub-01"}``. Keys must be valid pydicom keywords. These are
        set AFTER the defaults, so they win.

        NB: the original shell wrapper spelled this argument ``fileds`` in one
        branch (a typo). Callers should use ``fields``; the modernized
        ``imm_nii2dcm`` passes ``fields``.

    Returns
    -------
    list of str
        Paths of the DICOM files written (one per axial slice).

    Confidence / caveats
    --------------------
    See the module docstring. In short: geometry (PixelSpacing, SliceThickness,
    ImagePositionPatient, ImageOrientationPatient) is derived from the NIfTI
    affine assuming a near-axial acquisition, and a shared Series/Study/Frame-of-
    Reference UID set is generated. This loads correctly in common viewers and is
    geometrically consistent, but is NOT validated as clinical-grade DICOM.
    Oblique affines are approximated. Verify before production use.
    """
    import nibabel as nib
    import pydicom
    from pydicom.dataset import Dataset, FileDataset
    from pydicom.uid import generate_uid, ExplicitVRLittleEndian

    img = nib.load(nii_path)
    if img.ndim != 3:
        raise ValueError(f"nii2dcm expects a 3D volume; got shape {img.shape}")

    data = np.asanyarray(img.dataobj)
    affine = img.affine
    zooms = img.header.get_zooms()

    stem = os.path.basename(nii_path)
    for ext in (".nii.gz", ".nii"):
        if stem.endswith(ext):
            stem = stem[: -len(ext)]
            break
    odir = outputdir or os.path.join(os.path.dirname(os.path.abspath(nii_path)), stem + "_dicom")
    os.makedirs(odir, exist_ok=True)

    # Scale float data into int16, recording rescale slope/intercept.
    finite = data[np.isfinite(data)]
    dmin = float(finite.min()) if finite.size else 0.0
    dmax = float(finite.max()) if finite.size else 0.0
    if np.issubdtype(data.dtype, np.integer) and dmin >= -32768 and dmax <= 32767:
        pixel = data.astype(np.int16)
        slope, intercept = 1.0, 0.0
    else:
        rng = (dmax - dmin) if dmax > dmin else 1.0
        slope = rng / 32767.0 if rng > 0 else 1.0
        intercept = dmin
        pixel = np.clip(np.round((data - intercept) / slope), 0, 32767).astype(np.int16)

    # Direction cosines from the affine (columns), normalized.
    R = affine[:3, :3]
    col = R[:, 0] / (np.linalg.norm(R[:, 0]) or 1)
    row = R[:, 1] / (np.linalg.norm(R[:, 1]) or 1)
    # DICOM ImageOrientationPatient = [row_dir(x), col_dir(x)] (6 values).
    iop = [row[0], row[1], row[2], col[0], col[1], col[2]]

    px, py = float(zooms[0]), float(zooms[1])
    slice_thk = float(zooms[2])

    study_uid = generate_uid()
    series_uid = generate_uid()
    frame_uid = generate_uid()
    now = datetime.datetime.now()

    written = []
    nslices = pixel.shape[2]
    for k in range(nslices):
        sl = pixel[:, :, k]

        meta = Dataset()
        meta.MediaStorageSOPClassUID = pydicom.uid.SecondaryCaptureImageStorage
        meta.MediaStorageSOPInstanceUID = generate_uid()
        meta.TransferSyntaxUID = ExplicitVRLittleEndian
        meta.ImplementationClassUID = generate_uid()

        ds = FileDataset(None, {}, file_meta=meta, preamble=b"\0" * 128)
        ds.is_little_endian = True
        ds.is_implicit_VR = False

        # Identity / defaults (overridable via `fields`).
        ds.PatientName = "ANON^ANON"
        ds.PatientID = stem
        ds.Modality = "MR"
        ds.StudyInstanceUID = study_uid
        ds.SeriesInstanceUID = series_uid
        ds.FrameOfReferenceUID = frame_uid
        ds.SOPClassUID = meta.MediaStorageSOPClassUID
        ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
        ds.SeriesNumber = 1
        ds.InstanceNumber = k + 1
        ds.StudyDate = now.strftime("%Y%m%d")
        ds.StudyTime = now.strftime("%H%M%S")
        ds.SeriesDescription = stem

        # Geometry.
        pos = affine.dot(np.array([0, 0, k, 1]))[:3]
        ds.ImagePositionPatient = [float(pos[0]), float(pos[1]), float(pos[2])]
        ds.ImageOrientationPatient = [float(v) for v in iop]
        ds.PixelSpacing = [py, px]  # DICOM order is [row spacing, col spacing]
        ds.SliceThickness = slice_thk
        ds.SpacingBetweenSlices = slice_thk

        # Pixel data (16-bit signed).
        ds.SamplesPerPixel = 1
        ds.PhotometricInterpretation = "MONOCHROME2"
        ds.Rows, ds.Columns = int(sl.shape[0]), int(sl.shape[1])
        ds.BitsAllocated = 16
        ds.BitsStored = 16
        ds.HighBit = 15
        ds.PixelRepresentation = 1
        ds.RescaleSlope = slope
        ds.RescaleIntercept = intercept
        ds.PixelData = np.ascontiguousarray(sl).tobytes()

        # User overrides last so they take precedence.
        if fields:
            for key, val in fields.items():
                setattr(ds, key, val)

        out = os.path.join(odir, f"{stem}_{k + 1:04d}.dcm")
        ds.save_as(out, write_like_original=False)
        written.append(out)

    return written


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="DICOM <-> NIfTI/JPEG conversion.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("dcm2jpg")
    a.add_argument("dcm_path")
    a.add_argument("-o", "--outputdir", default=None)
    a.add_argument("-c", "--adjust-contrast", type=int, default=0)
    b = sub.add_parser("nii2dcm")
    b.add_argument("nii_path")
    b.add_argument("-o", "--outputdir", default=None)
    args = ap.parse_args()
    if args.cmd == "dcm2jpg":
        print("\n".join(dcm2jpg(args.dcm_path, args.outputdir, args.adjust_contrast)))
    else:
        print("\n".join(nii2dcm(args.nii_path, args.outputdir)))
