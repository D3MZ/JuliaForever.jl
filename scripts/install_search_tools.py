import io
import os
from pathlib import Path
import shutil
import sys
import tarfile
from urllib.request import urlopen
import zipfile

destination, runner_os, runner_arch = sys.argv[1:]
arch = {"X64": "x86_64", "ARM64": "aarch64"}[runner_arch]
target = {"Linux": "unknown-linux-musl", "macOS": "apple-darwin", "Windows": "pc-windows-msvc"}[runner_os]
extension = "zip" if runner_os == "Windows" else "tar.gz"
destination = Path(destination)
destination.mkdir(parents=True, exist_ok=True)

for name, repo, version, prefix in [("fd", "sharkdp/fd", "10.2.0", "fd-v"), ("rg", "BurntSushi/ripgrep", "15.2.0", "ripgrep-")]:
    tag = ("v" if name == "fd" else "") + version
    asset = f"{prefix}{version}-{arch}-{target}.{extension}"
    url = f"https://github.com/{repo}/releases/download/{tag}/{asset}"
    print(f"Downloading {url}", flush=True)
    data = io.BytesIO(urlopen(url).read())
    binary = name + (".exe" if runner_os == "Windows" else "")
    if extension == "zip":
        with zipfile.ZipFile(data) as archive:
            member = next(path for path in archive.namelist() if path.endswith("/" + binary))
            with archive.open(member) as source, (destination / binary).open("wb") as output:
                shutil.copyfileobj(source, output)
    else:
        with tarfile.open(fileobj=data, mode="r:gz") as archive:
            member = next(item for item in archive.getmembers() if item.name.endswith("/" + binary))
            with archive.extractfile(member) as source, (destination / binary).open("wb") as output:
                shutil.copyfileobj(source, output)
    os.chmod(destination / binary, 0o755)
