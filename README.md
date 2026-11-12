# Packs de cartes LibreRoute

Ce dépôt **construit et publie automatiquement** les packs de cartes hors ligne de l'application LibreRoute, sur les machines gratuites de GitHub. Aucun serveur personnel n'est nécessaire.

Chaque pack contient, pour une région : la carte vectorielle (PMTiles), le graphe routier (Valhalla 3.9), les polices et deux voix françaises. Les fichiers sont publiés dans les **Releases** de ce dépôt.

## Utilisation

- **Ajouter une région** : ajoute une ligne dans `packs.json` (nom du pack et adresse de l'extrait `.osm.pbf`, par exemple sur [Geofabrik](https://download.geofabrik.de/europe/france.html)).
- **Construire maintenant** : onglet *Actions* → *Construire les packs* → *Run workflow* (laisser vide pour tous les packs de `packs.json`, ou indiquer un seul pack et son extrait).
- **Mise à jour automatique** : le 1er de chaque mois, tous les packs sont reconstruits.

Adresse à donner à l'application (`build-apk.bat`) :

```
https://github.com/<ton-compte>/<ce-dépôt>/releases/download/manifests/
```

## Limites à connaître

- GitHub refuse les fichiers de plus de 2 Gio : un pack doit rester une région, pas un pays entier.
- Une construction ne doit pas dépasser 6 h ; une région française prend en général bien moins.
- GitHub suspend les tâches planifiées d'un dépôt sans activité pendant 60 jours : il suffit alors de relancer à la main.

## Licences

Données © contributeurs OpenStreetMap, licence ODbL. Polices Noto Sans (SIL OFL). Voix Piper (licences sur les fiches des modèles).
