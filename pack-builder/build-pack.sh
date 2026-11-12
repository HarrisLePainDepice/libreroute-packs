#!/usr/bin/env bash
# =============================================================================
# LibreRoute — construction d'un pack de données hors ligne
#
# Produit, pour une zone OpenStreetMap donnée, dans /srv/libreroute/packs :
#   <pack>-<build>.tiles.pmtiles      carte vectorielle (schéma OpenMapTiles, Planetiler)
#   <pack>-<build>.routing.tar        graphe routier Valhalla 3.9 (même version que l'appli)
#   <pack>-<build>.glyphs.zip         polices de la carte (Noto Sans, licence OFL)
#   <pack>-<build>.voice-<id>.zip     voix françaises Piper (féminine et masculine)
#   <pack>.manifest.json              tailles, empreintes SHA-256, emprise (nom fixe)
#
# Les fichiers lourds portent le numéro de construction : une reconstruction ne
# remplace jamais un fichier qu'un téléphone est en train de télécharger. La
# construction précédente est conservée, les plus anciennes sont supprimées.
#
# Ce dossier peut être publié tel quel par Nginx (nginx-libreroute-packs.conf)
# ou envoyé sur GitHub Releases (publish-github.py), au choix.
#
# Usage (sur le VPS, en root ou membre du groupe docker) :
#   ./build-pack.sh <nom-du-pack> <url-de-l-extrait-osm.pbf>
# Exemple :
#   ./build-pack.sh bretagne https://download.geofabrik.de/europe/france/bretagne-latest.osm.pbf
#
# Variables facultatives :
#   LIBREROUTE_ROOT   dossier racine (défaut : /srv/libreroute)
#   PLANETILER_HEAP   mémoire Java pour Planetiler (défaut : 6g)
#   BUILD_THREADS     cœurs utilisés (défaut : 4, pour ménager tes autres services)
#   PLANETILER_IMAGE  image Docker Planetiler
#   VALHALLA_IMAGE    image Docker Valhalla (doit rester en 3.9.x, comme l'appli)
#
# Destinations réseau (toutes publiques et open source) : l'URL de l'extrait OSM,
# ghcr.io (images Docker), les sources téléchargées par Planetiler --download
# (polygones d'eau OSM, Natural Earth, lacs), github.com/protomaps/basemaps-assets
# (polices) et github.com/k2-fsa/sherpa-onnx (voix).
# =============================================================================
set -Eeuo pipefail

PACK="${1:-}"
PBF_URL="${2:-}"

ROOT="${LIBREROUTE_ROOT:-/srv/libreroute}"
PLANETILER_HEAP="${PLANETILER_HEAP:-6g}"
BUILD_THREADS="${BUILD_THREADS:-4}"
PLANETILER_IMAGE="${PLANETILER_IMAGE:-ghcr.io/onthegomap/planetiler:latest}"
VALHALLA_IMAGE="${VALHALLA_IMAGE:-ghcr.io/valhalla/valhalla:3.9.0}"
FONTS_REPO="https://github.com/protomaps/basemaps-assets.git"
VOICE_BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
GITHUB_ASSET_LIMIT=$((2 * 1024 * 1024 * 1024 - 1))

# identifiant sherpa-onnx | identifiant LibreRoute | genre | libellé affiché
VOICES=(
  "vits-piper-fr_FR-siwis-medium|fr_FR-siwis-medium|female|Siwis (voix féminine)"
  "vits-piper-fr_FR-tom-medium|fr_FR-tom-medium|male|Tom (voix masculine)"
)

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\nERREUR : %s\n' "$*" >&2; exit 1; }
trap 'die "échec à la ligne $LINENO (commande : $BASH_COMMAND)"' ERR

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

[[ -n "$PACK" && -n "$PBF_URL" ]] || usage
[[ "$PACK" =~ ^[a-z0-9][a-z0-9-]{1,39}$ ]] \
  || die "nom de pack invalide « $PACK » : lettres minuscules, chiffres et tirets uniquement."
[[ "$PBF_URL" =~ ^https://[^[:space:]]+\.osm\.pbf$ ]] \
  || die "l'URL doit commencer par https:// et se terminer par .osm.pbf"
[[ "$BUILD_THREADS" =~ ^[1-9][0-9]?$ ]] || die "BUILD_THREADS doit être un nombre entre 1 et 99"
[[ "$PLANETILER_HEAP" =~ ^[1-9][0-9]*[mg]$ ]] || die "PLANETILER_HEAP doit ressembler à 6g ou 4096m"

for cmd in docker curl git python3 zip tar bzip2 sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "commande manquante : $cmd (apt install $cmd)"
done
docker info >/dev/null 2>&1 || die "Docker ne répond pas (est-il démarré ? l'utilisateur est-il dans le groupe docker ?)"

BUILD="$(date -u +%Y%m%d%H%M)"
PREFIX="$PACK-$BUILD"
WORK="$ROOT/work/$PACK"
CACHE="$ROOT/work/_cache"
PACKS="$ROOT/packs"
STAGE="$PACKS/.staging-$PREFIX"

# Un seul build à la fois pour un même pack.
mkdir -p "$ROOT/work"
exec 9>"$ROOT/work/.lock-$PACK"
command -v flock >/dev/null 2>&1 && { flock -n 9 || die "une construction du pack « $PACK » est déjà en cours"; }

mkdir -p "$WORK" "$CACHE/sources" "$CACHE/voices" "$PACKS"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cleanup_stage() { rm -rf "$STAGE"; }
trap cleanup_stage EXIT

START=$(date +%s)

# -----------------------------------------------------------------------------
log "1/6 Téléchargement de l'extrait OpenStreetMap"
# -----------------------------------------------------------------------------
# Toujours un fichier neuf : on ne mélange jamais un ancien extrait avec un nouveau.
rm -f "$WORK/input.osm.pbf" "$WORK/input.osm.pbf.part"
curl -fL --retry 5 --retry-delay 10 --retry-all-errors -o "$WORK/input.osm.pbf.part" "$PBF_URL"
mv "$WORK/input.osm.pbf.part" "$WORK/input.osm.pbf"
ls -lh "$WORK/input.osm.pbf"

# -----------------------------------------------------------------------------
log "2/6 Génération de la carte vectorielle (Planetiler) — plusieurs minutes"
# -----------------------------------------------------------------------------
rm -f "$WORK/tiles.pmtiles"
docker run --rm \
  -e JAVA_TOOL_OPTIONS="-Xmx${PLANETILER_HEAP}" \
  -v "$WORK:/data" \
  -v "$CACHE/sources:/sources" \
  "$PLANETILER_IMAGE" \
  --osm_path=/data/input.osm.pbf \
  --output=/data/tiles.pmtiles \
  --download \
  --download_dir=/sources \
  --tmpdir=/data/tmp \
  --threads="$BUILD_THREADS" \
  --force
rm -rf "$WORK/tmp"
[[ -s "$WORK/tiles.pmtiles" ]] || die "Planetiler n'a pas produit tiles.pmtiles"

# -----------------------------------------------------------------------------
log "3/6 Construction du graphe routier (Valhalla) — plusieurs minutes"
# -----------------------------------------------------------------------------
rm -rf "$WORK/valhalla"
mkdir -p "$WORK/valhalla"
docker run --rm \
  --user 0:0 \
  -v "$WORK:/data" \
  --entrypoint /bin/bash \
  "$VALHALLA_IMAGE" -c "
    set -e
    valhalla_build_config \
      --mjolnir-tile-dir /data/valhalla/tiles \
      --mjolnir-tile-extract /data/valhalla/tiles.tar \
      --mjolnir-admin /data/valhalla/admin.sqlite \
      --mjolnir-concurrency ${BUILD_THREADS} \
      > /data/valhalla/valhalla.json
    valhalla_build_admins  -c /data/valhalla/valhalla.json /data/input.osm.pbf
    valhalla_build_tiles   -c /data/valhalla/valhalla.json /data/input.osm.pbf
    valhalla_build_extract -c /data/valhalla/valhalla.json -v
  "
[[ -s "$WORK/valhalla/tiles.tar" ]] || die "Valhalla n'a pas produit tiles.tar"

# -----------------------------------------------------------------------------
log "4/6 Polices de la carte (Noto Sans, licence SIL OFL)"
# -----------------------------------------------------------------------------
if [[ ! -d "$CACHE/basemaps-assets/.git" ]]; then
  rm -rf "$CACHE/basemaps-assets"
  git clone --depth 1 --filter=blob:none --sparse "$FONTS_REPO" "$CACHE/basemaps-assets"
fi
git -C "$CACHE/basemaps-assets" sparse-checkout set \
  "fonts/Noto Sans Regular" "fonts/Noto Sans Medium" "fonts/OFL.txt"
[[ -d "$CACHE/basemaps-assets/fonts/Noto Sans Regular" ]] || die "polices introuvables dans basemaps-assets"
rm -rf "$WORK/glyphs"
mkdir -p "$WORK/glyphs"
cp -r "$CACHE/basemaps-assets/fonts/Noto Sans Regular" "$WORK/glyphs/"
cp -r "$CACHE/basemaps-assets/fonts/Noto Sans Medium" "$WORK/glyphs/"
cp "$CACHE/basemaps-assets/fonts/OFL.txt" "$WORK/glyphs/"
(cd "$WORK/glyphs" && zip -q -r -X "$STAGE/$PREFIX.glyphs.zip" .)

# -----------------------------------------------------------------------------
log "5/6 Voix françaises (Piper, converties pour sherpa-onnx)"
# -----------------------------------------------------------------------------
for entry in "${VOICES[@]}"; do
  IFS='|' read -r SRC_ID VOICE_ID _ _ <<< "$entry"
  ARCHIVE="$CACHE/voices/$SRC_ID.tar.bz2"
  if [[ ! -s "$ARCHIVE" ]]; then
    curl -fL --retry 5 --retry-delay 10 --retry-all-errors -o "$ARCHIVE.part" "$VOICE_BASE_URL/$SRC_ID.tar.bz2"
    mv "$ARCHIVE.part" "$ARCHIVE"
  fi
  rm -rf "$WORK/voice-$VOICE_ID"
  mkdir -p "$WORK/voice-$VOICE_ID"
  tar -xjf "$ARCHIVE" -C "$WORK/voice-$VOICE_ID" --strip-components=1
  ls "$WORK/voice-$VOICE_ID"/*.onnx >/dev/null 2>&1 || die "modèle .onnx absent de $SRC_ID"
  [[ -f "$WORK/voice-$VOICE_ID/tokens.txt" ]] || die "tokens.txt absent de $SRC_ID"
  # espeak-ng-data n'est plus utilisé par sherpa-onnx 2.x : l'appli embarque son propre
  # phonétiseur. On l'exclut pour alléger le téléchargement.
  (cd "$WORK/voice-$VOICE_ID" && zip -q -r -X "$STAGE/$PREFIX.voice-$VOICE_ID.zip" . -x 'espeak-ng-data/*')
done

cp "$WORK/tiles.pmtiles" "$STAGE/$PREFIX.tiles.pmtiles"
cp "$WORK/valhalla/tiles.tar" "$STAGE/$PREFIX.routing.tar"

# -----------------------------------------------------------------------------
log "6/6 Manifeste et publication"
# -----------------------------------------------------------------------------
VOICES_SPEC="$(printf '%s\n' "${VOICES[@]}")" \
PACK="$PACK" BUILD="$BUILD" PREFIX="$PREFIX" PBF_URL="$PBF_URL" STAGE="$STAGE" \
VALHALLA_IMAGE="$VALHALLA_IMAGE" ASSET_LIMIT="$GITHUB_ASSET_LIMIT" \
python3 - <<'PY'
import datetime, hashlib, json, os, struct, sys

stage, prefix = os.environ["STAGE"], os.environ["PREFIX"]
limit = int(os.environ["ASSET_LIMIT"])

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

# En-tête PMTiles v3 (127 octets, petit-boutiste) : emprise et centre.
with open(os.path.join(stage, f"{prefix}.tiles.pmtiles"), "rb") as f:
    header = f.read(127)
if len(header) != 127 or header[:7] != b"PMTiles" or header[7] != 3:
    sys.exit("le fichier de carte n'est pas un PMTiles v3")
min_lon, min_lat, max_lon, max_lat = (v / 1e7 for v in struct.unpack_from("<iiii", header, 102))
center_zoom = header[118]
center_lon, center_lat = (v / 1e7 for v in struct.unpack_from("<ii", header, 119))
if not (-180 <= min_lon < max_lon <= 180 and -90 <= min_lat < max_lat <= 90):
    sys.exit("emprise du PMTiles incohérente")

files = []
def add(name, role, **extra):
    path = os.path.join(stage, name)
    size = os.path.getsize(path)
    if size > limit:
        print(f"AVERTISSEMENT : {name} dépasse 2 Gio, il ne pourra pas être publié sur GitHub Releases",
              file=sys.stderr)
    entry = {"name": name, "role": role, "size": size, "sha256": sha256(path)}
    entry.update(extra)
    files.append(entry)

add(f"{prefix}.tiles.pmtiles", "map")
add(f"{prefix}.routing.tar", "routing", engine=os.environ["VALHALLA_IMAGE"])
add(f"{prefix}.glyphs.zip", "glyphs")
for line in os.environ["VOICES_SPEC"].splitlines():
    _src, voice_id, gender, label = line.split("|")
    add(f"{prefix}.voice-{voice_id}.zip", "voice", voice_id=voice_id, gender=gender, label=label, lang="fr")

manifest = {
    "format": 1,
    "pack": os.environ["PACK"],
    "build": os.environ["BUILD"],
    "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "osm_source": os.environ["PBF_URL"],
    "bounds": [round(min_lon, 6), round(min_lat, 6), round(max_lon, 6), round(max_lat, 6)],
    "center": [round(center_lon, 6), round(center_lat, 6), center_zoom],
    "files": files,
}
with open(os.path.join(stage, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
print(json.dumps(manifest, ensure_ascii=False, indent=2))
PY

# Publication : d'abord les fichiers lourds (nouveaux noms), puis le manifeste, de
# façon atomique. Un téléphone voit soit l'ancien manifeste complet, soit le nouveau.
for f in "$STAGE"/"$PREFIX".*; do
  mv "$f" "$PACKS/"
done
mv "$STAGE/manifest.json" "$PACKS/.$PACK.manifest.json.tmp"
mv "$PACKS/.$PACK.manifest.json.tmp" "$PACKS/$PACK.manifest.json"
chmod a+r "$PACKS/$PACK.manifest.json" "$PACKS/$PREFIX".*

# Ménage : on garde cette construction et la précédente (téléchargements en cours).
mapfile -t BUILDS < <(
  find "$PACKS" -maxdepth 1 -type f -name "$PACK-[0-9]*.tiles.pmtiles" -printf '%f\n' \
    | sed -E "s/^$PACK-([0-9]{12})\.tiles\.pmtiles$/\1/" | grep -E '^[0-9]{12}$' | sort -r
)
for old in "${BUILDS[@]:2}"; do
  log "Suppression de l'ancienne construction $old"
  rm -f "$PACKS/$PACK-$old".*
done

END=$(date +%s)
log "Pack « $PACK » (construction $BUILD) prêt en $(( (END - START) / 60 )) min"
ls -lh "$PACKS/$PACK.manifest.json" "$PACKS/$PREFIX".*
