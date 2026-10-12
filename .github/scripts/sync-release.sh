#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
[[ "$GITHUB_REPOSITORY" == "mirror1sparkled/mihomo" ]] || {
  echo "Unexpected mirror repository" >&2
  exit 1
}

SOURCE_REPO=MetaCubeX/mihomo
MIRROR_DIR="$(mktemp -d)"
trap 'rm -rf "$MIRROR_DIR"' EXIT
export MIRROR_DIR

gh api "repos/$SOURCE_REPO/releases/latest" > "$MIRROR_DIR/source.json"

# Follow Tribbie's scripts/mirror-dependencies.sh whitelist.
python3 - <<'PY'
import json, os, pathlib, re
root = pathlib.Path(os.environ["MIRROR_DIR"])
release = json.loads((root / "source.json").read_text())
tag = release["tag_name"]
if release["draft"] or release["prerelease"] or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    raise SystemExit("Upstream latest is not a stable version")
names = ["version.txt"]
for platform, arch, suffix in [
    ("windows", "amd64-v3", "zip"), ("windows", "arm64", "zip"),
    ("linux", "amd64-v3", "gz"), ("linux", "arm64", "gz"),
    ("darwin", "amd64-v3", "gz"), ("darwin", "arm64", "gz"),
]:
    names.append(f"mihomo-{platform}-{arch}-{tag}.{suffix}")
assets = {asset["name"]: asset for asset in release["assets"]}
for name in names:
    if name not in assets or assets[name]["size"] <= 0:
        raise SystemExit(f"Missing upstream asset: {name}")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", assets[name].get("digest") or ""):
        raise SystemExit(f"Missing SHA-256 digest: {name}")
(root / "tag").write_text(tag)
(root / "names").write_text("\n".join(names) + "\n")
PY

TAG="$(cat "$MIRROR_DIR/tag")"
mkdir "$MIRROR_DIR/assets"
while IFS= read -r name; do
  gh release download "$TAG" --repo "$SOURCE_REPO" \
    --dir "$MIRROR_DIR/assets" --pattern "$name"
done < "$MIRROR_DIR/names"

python3 - <<'PY'
import hashlib, json, os, pathlib
root = pathlib.Path(os.environ["MIRROR_DIR"])
assets = {asset["name"]: asset for asset in json.loads((root / "source.json").read_text())["assets"]}
for name in (root / "names").read_text().splitlines():
    data = (root / "assets" / name).read_bytes()
    expected = assets[name]
    if len(data) != expected["size"] or "sha256:" + hashlib.sha256(data).hexdigest() != expected["digest"]:
        raise SystemExit(f"Upstream checksum mismatch: {name}")
if (root / "assets/version.txt").read_text().strip() != (root / "tag").read_text():
    raise SystemExit("version.txt does not match the release tag")
PY

# A new release remains a draft until all seven assets are verified.
if ! gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --target main --draft \
    --title "$TAG (Tribbie mirror)" \
    --notes "Build dependency mirror for Tribbie. Source: $SOURCE_REPO@$TAG"
fi

gh release upload "$TAG" "$MIRROR_DIR/assets"/* \
  --repo "$GITHUB_REPOSITORY" --clobber
gh api "repos/$GITHUB_REPOSITORY/releases/tags/$TAG" > "$MIRROR_DIR/target.json"

python3 - <<'PY'
import json, os, pathlib
root = pathlib.Path(os.environ["MIRROR_DIR"])
source = {asset["name"]: asset for asset in json.loads((root / "source.json").read_text())["assets"]}
target = json.loads((root / "target.json").read_text())
actual = {asset["name"]: asset for asset in target["assets"]}
names = (root / "names").read_text().splitlines()
if target["tag_name"] != (root / "tag").read_text() or set(actual) != set(names):
    raise SystemExit("Mirror release does not match the asset whitelist")
for name in names:
    if actual[name]["size"] != source[name]["size"] or actual[name].get("digest") != source[name]["digest"]:
        raise SystemExit(f"Mirror checksum mismatch: {name}")
PY

gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease=false --latest
echo "Mirrored $SOURCE_REPO@$TAG with seven verified assets."
