# DualCam

Filme en **horizontal 16:9 et vertical 9:16 en même temps**, avec un codec et une résolution au choix pour chaque fichier (ProRes 422 HQ / 422 / LT / Proxy, HEVC, H.264).

## Comment ça marche

- La caméra capture en 4K (3840×2160).
- **Horizontal** : l'image complète, encodée en 4K, 1080p ou 720p.
- **Vertical** : recadrage central 9:16 (1215×2160 de capteur) encodé en 1080×1920 ou 720×1280.
- Deux fichiers `.mov` par prise (`_16x9` et `_9x16`), envoyés dans Photos ou laissés dans l'app Fichiers.
- Taper sur l'image fait la mise au point et l'expo ; le cadenas verrouille mise au point, exposition et balance des blancs.
- Requiert iOS 17. ProRes nécessite un iPhone 13 Pro ou plus récent.

## Build sans Mac (GitHub Actions)

1. Crée un dépôt GitHub (public = minutes macOS gratuites ; en privé, les minutes macOS comptent ×10).
2. Pousse tout le contenu de ce dossier, **y compris `.github/`**.
3. Onglet **Actions** › *Build IPA* › dernier run › télécharge l'artefact **DualCam-ipa** (un zip contenant `DualCam.ipa`).
4. Si le build échoue, télécharge l'artefact **build-log** et envoie-le à Claude.

## Installation sur l'iPhone (Windows)

1. Installe **Sideloadly**, ainsi qu'iTunes et iCloud *versions web* (pas Microsoft Store).
2. Branche l'iPhone en USB, glisse `DualCam.ipa` dans Sideloadly, entre ton Apple ID, *Start*.
3. Sur l'iPhone : Réglages › Confidentialité et sécurité › **Mode développeur** (activer, redémarrer).
4. Réglages › Général › **VPN et gestion de l'appareil** › faire confiance à ton Apple ID.

Avec un Apple ID gratuit, l'app expire après **7 jours** : relance Sideloadly pour la re-signer (les vidéos déjà dans Photos ne sont pas touchées).
