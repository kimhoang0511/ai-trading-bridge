"""
build_ext_zip.py -- Bundle third-party packages + stdlib C extensions.
Usage: python build_ext_zip.py <site-packages-dir> <output-zip> <python-dir> [embed-dir]

embed-dir: path to extracted Python embeddable package (python-3.12.X-embed-win32.zip)
           Contains python312.dll, python312.zip, _socket.pyd, _ssl.pyd, etc.
           Use this for guaranteed stdlib C extensions (preferred over full installer DLLs/).
"""
import sys
import os
import zipfile

def main():
    if len(sys.argv) < 4:
        print("Usage: build_ext_zip.py <site-packages> <output.zip> <python-dir> [embed-dir]")
        sys.exit(1)

    sp         = sys.argv[1]   # e.g. C:\Python312_x86\Lib\site-packages
    out        = sys.argv[2]   # e.g. build\ext_packages.zip
    python_dir = sys.argv[3]   # e.g. C:\Python312_x86
    embed_dir  = sys.argv[4] if len(sys.argv) >= 5 else None

    pkg_dirs = [
        "anthropic", "httpx", "httpcore", "h11", "certifi",
        "anyio", "sniffio", "idna", "jiter",
        "pydantic", "pydantic_core", "annotated_types",
    ]
    pkg_files = ["typing_extensions.py", "distro.py"]

    # Stdlib C extensions needed by httpx / ssl / socket
    stdlib_pyd = [
        "_socket.pyd", "select.pyd",
        "_ssl.pyd",    "_hashlib.pyd",
        "_overlapped.pyd",
        "_asyncio.pyd",
    ]

    skip_exts = {".pyc"}
    skip_dirs = {"__pycache__"}

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:

        # ── Third-party package directories ──────────────────────────────────
        for pkg in pkg_dirs:
            pkgdir = os.path.join(sp, pkg)
            if not os.path.isdir(pkgdir):
                print(f"  [SKIP] {pkg}/ not found")
                continue
            count = 0
            for root, dirs, files in os.walk(pkgdir):
                dirs[:] = [d for d in dirs if d not in skip_dirs]
                for fname in files:
                    if os.path.splitext(fname)[1] in skip_exts:
                        continue
                    fpath = os.path.join(root, fname)
                    z.write(fpath, os.path.relpath(fpath, sp))
                    count += 1
            print(f"  {pkg}/  ({count} files)")

        # ── Single-file packages ──────────────────────────────────────────────
        for fname in pkg_files:
            fpath = os.path.join(sp, fname)
            if os.path.isfile(fpath):
                z.write(fpath, fname)
                print(f"  {fname}")
            else:
                print(f"  [SKIP] {fname} not found")

        # ── Stdlib C extensions: prefer embeddable package, fallback to DLLs\ ─
        if embed_dir and os.path.isdir(embed_dir):
            print(f"  [embed] Using embeddable package: {embed_dir}")
            added = set()
            # Add every .pyd from the embeddable package root (covers all stdlib C ext)
            for fname in os.listdir(embed_dir):
                if fname.lower().endswith(".pyd"):
                    fpath = os.path.join(embed_dir, fname)
                    z.write(fpath, fname)
                    added.add(fname.lower())
                    print(f"  embed pyd: {fname}")
            # OpenSSL DLLs from embeddable package
            for fname in os.listdir(embed_dir):
                if fname.lower().startswith(("libssl", "libcrypto")):
                    fpath = os.path.join(embed_dir, fname)
                    z.write(fpath, fname)
                    print(f"  embed ssl: {fname}")
        else:
            # Fallback: grab specific .pyd files from full installer DLLs\
            print("  [WARN] embed_dir not provided — falling back to PYTHON_DIR\\DLLs\\")
            dlls_dir = os.path.join(python_dir, "DLLs")
            for fname in stdlib_pyd:
                fpath = os.path.join(dlls_dir, fname)
                if os.path.isfile(fpath):
                    z.write(fpath, fname)
                    print(f"  stdlib: {fname}")
                else:
                    print(f"  [SKIP] stdlib {fname} not found in {dlls_dir}")

            # OpenSSL DLLs (needed by _ssl.pyd)
            for search_dir in [python_dir, dlls_dir]:
                if not os.path.isdir(search_dir):
                    continue
                for fname in os.listdir(search_dir):
                    if fname.lower().startswith(("libssl", "libcrypto")):
                        fpath = os.path.join(search_dir, fname)
                        z.write(fpath, fname)
                        print(f"  ssl: {fname}")

    size_mb = os.path.getsize(out) / 1024 / 1024
    print(f"ext_packages.zip OK  ({size_mb:.1f} MB)")

if __name__ == "__main__":
    main()
