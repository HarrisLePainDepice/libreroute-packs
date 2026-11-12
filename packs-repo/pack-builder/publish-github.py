#!/usr/bin/env python3
"""
LibreRoute — publication d'un pack sur GitHub Releases (option « sans bande passante VPS »).

GitHub ne limite ni la taille totale d'une release ni la bande passante de
téléchargement ; chaque fichier doit faire moins de 2 Gio. Le VPS ne sert alors
plus qu'au trafic temps réel.

Organisation sur GitHub (dépôt public dédié, par exemple « libreroute-packs ») :
  - une release par construction, étiquette « <pack>-<build> » : fichiers lourds ;
  - une release fixe, étiquette « manifests » : un <pack>.manifest.json par pack,
    remplacé à chaque publication. Il indique où trouver les fichiers lourds
    (champ files_base_url).

L'application se compile alors avec :
  build-apk.bat https://github.com/<compte>/<dépôt>/releases/download/manifests/ <pack>

Usage (sur le VPS, après build-pack.sh) :
  export GITHUB_TOKEN=...   # jeton « fine-grained », droit Contents: Read and write sur ce dépôt uniquement
  ./publish-github.py <pack> <compte>/<dépôt>

Seules destinations réseau : api.github.com et uploads.github.com.
Le jeton n'est jamais écrit sur disque ni affiché.
"""
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.parse

API = "api.github.com"
UPLOADS = "uploads.github.com"
ASSET_LIMIT = 2 * 1024 ** 3 - 1
MANIFESTS_TAG = "manifests"


def die(msg):
    print(f"ERREUR : {msg}", file=sys.stderr)
    sys.exit(1)


def request(host, method, path, token, body=None, headers=None, expected=(200,)):
    """Requête HTTPS vers GitHub ; renvoie (statut, JSON décodé ou None)."""
    h = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "libreroute-publisher",
    }
    if headers:
        h.update(headers)
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    for attempt in range(4):
        conn = http.client.HTTPSConnection(host, timeout=600)
        try:
            if hasattr(body, "seek"):
                body.seek(0)
            conn.request(method, path, body=body, headers=h)
            resp = conn.getresponse()
            data = resp.read()
            if resp.status in expected:
                return resp.status, (json.loads(data) if data else None)
            if resp.status in (500, 502, 503, 504) and attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            detail = data[:300].decode(errors="replace")
            die(f"GitHub a répondu {resp.status} pour {method} {path.split('?')[0]} : {detail}")
        except (OSError, http.client.HTTPException) as e:
            if attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            die(f"connexion à GitHub impossible : {e}")
        finally:
            conn.close()
    die("échec après plusieurs tentatives")


def get_release(repo, tag, token):
    status, rel = request(API, "GET", f"/repos/{repo}/releases/tags/{urllib.parse.quote(tag)}", token,
                          expected=(200, 404))
    return rel if status == 200 else None


def create_release(repo, tag, name, body, token):
    _, rel = request(API, "POST", f"/repos/{repo}/releases", token, body={
        "tag_name": tag,
        "name": name,
        "body": body,
        "draft": False,
        "prerelease": False,
        "make_latest": "false",
    }, expected=(201,))
    return rel


def list_assets(repo, release_id, token):
    assets, page = [], 1
    while True:
        _, batch = request(API, "GET", f"/repos/{repo}/releases/{release_id}/assets?per_page=100&page={page}", token)
        assets += batch
        if len(batch) < 100:
            return assets
        page += 1


def delete_asset(repo, asset_id, token):
    request(API, "DELETE", f"/repos/{repo}/releases/assets/{asset_id}", token, expected=(204,))


def upload(repo, release_id, path, name, token):
    size = os.path.getsize(path)
    if size > ASSET_LIMIT:
        die(f"{name} fait {size / 1024 ** 3:.2f} Gio : GitHub refuse les fichiers de plus de 2 Gio")
    print(f"  envoi de {name} ({size / 1_000_000:.1f} Mo)…", flush=True)
    with open(path, "rb") as f:
        _, asset = request(UPLOADS, "POST",
                           f"/repos/{repo}/releases/{release_id}/assets?name={urllib.parse.quote(name)}",
                           token, body=f,
                           headers={"Content-Type": "application/octet-stream", "Content-Length": str(size)},
                           expected=(201,))
    return asset


def rename_asset(repo, asset_id, name, token):
    request(API, "PATCH", f"/repos/{repo}/releases/assets/{asset_id}", token, body={"name": name})


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    pack, repo = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,39}", pack):
        die("nom de pack invalide")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        die("dépôt invalide : attendu <compte>/<dépôt>")
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        die("variable GITHUB_TOKEN absente")

    root = os.environ.get("LIBREROUTE_ROOT", "/srv/libreroute")
    packs_dir = os.path.join(root, "packs")
    manifest_path = os.path.join(packs_dir, f"{pack}.manifest.json")
    if not os.path.isfile(manifest_path):
        die(f"{manifest_path} introuvable : lance d'abord build-pack.sh {pack} …")
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    build = manifest["build"]
    tag = f"{pack}-{build}"

    print("Vérification des fichiers locaux…", flush=True)
    for entry in manifest["files"]:
        path = os.path.join(packs_dir, entry["name"])
        if not os.path.isfile(path) or os.path.getsize(path) != entry["size"]:
            die(f"{entry['name']} absent ou de taille inattendue")
        if sha256(path) != entry["sha256"]:
            die(f"{entry['name']} ne correspond pas à son empreinte")

    # 1. Fichiers lourds dans la release de cette construction.
    rel = get_release(repo, tag, token) or create_release(
        repo, tag, f"Pack {pack} — construction {build}",
        f"Données OpenStreetMap (© contributeurs OpenStreetMap, ODbL) pour le pack « {pack} ».\n"
        f"Source : {manifest.get('osm_source', '')}", token)
    existing = {a["name"]: a for a in list_assets(repo, rel["id"], token)}
    print(f"Release {tag} :", flush=True)
    for entry in manifest["files"]:
        a = existing.get(entry["name"])
        if a and a["size"] == entry["size"] and a["state"] == "uploaded":
            print(f"  {entry['name']} déjà en ligne")
            continue
        if a:
            delete_asset(repo, a["id"], token)
        upload(repo, rel["id"], os.path.join(packs_dir, entry["name"]), entry["name"], token)

    # 2. Manifeste, avec l'adresse des fichiers lourds, dans la release fixe « manifests ».
    manifest["files_base_url"] = f"https://github.com/{repo}/releases/download/{tag}/"
    published = os.path.join(root, "work", f".{pack}.manifest.github.json")
    os.makedirs(os.path.dirname(published), exist_ok=True)
    with open(published, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    mrel = get_release(repo, MANIFESTS_TAG, token) or create_release(
        repo, MANIFESTS_TAG, "Manifestes des packs LibreRoute",
        "Un manifeste par pack ; il pointe vers la release de la dernière construction.", token)
    # Le nouveau manifeste est envoyé sous un nom provisoire, puis renommé juste après la
    # suppression de l'ancien : l'adresse n'est indisponible qu'une fraction de seconde.
    name = f"{pack}.manifest.json"
    temp_name = f"{pack}.manifest.json.{build}.new"
    print("Release manifests :", flush=True)
    for a in list_assets(repo, mrel["id"], token):
        if a["name"] == temp_name:
            delete_asset(repo, a["id"], token)
    new_asset = upload(repo, mrel["id"], published, temp_name, token)
    for a in list_assets(repo, mrel["id"], token):
        if a["name"] == name:
            delete_asset(repo, a["id"], token)
    rename_asset(repo, new_asset["id"], name, token)

    print()
    print("Publication terminée. Adresse à donner à build-apk.bat :")
    print(f"  https://github.com/{repo}/releases/download/{MANIFESTS_TAG}/")


if __name__ == "__main__":
    main()
