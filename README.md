# SimLease

Partage des simulateurs iOS et émulateurs Android entre plusieurs sessions Claude Code en parallèle, sans qu'ils s'accumulent.

- **`bin/sim-lease`** : chaque session « loue » un appareil au lieu d'en démarrer un nouveau. Le script réutilise un appareil allumé et libre, n'en démarre un que sous un plafond, et éteint ceux qui ne servent plus.
- **`app/SimBar.swift`** : app de barre des menus qui montre les appareils démarrés, quelle session les utilise (avec un bouton pour y aller), permet de les éteindre, et lance le nettoyage toutes les 5 min.

## Installation

```bash
ln -sf "$PWD/bin/sim-lease" ~/.claude/bin/sim-lease
./build.sh          # compile et installe ~/Applications/SimBar.app
open ~/Applications/SimBar.app
```

Ajouter aussi le bloc `<simulators>` dans `~/.claude/CLAUDE.md` (voir `CLAUDE.snippet.md`), et ce hook `SessionEnd` dans `~/.claude/settings.json` :

```json
{ "hooks": [{ "type": "command", "command": "$HOME/.claude/bin/sim-lease release-session", "timeout": 30 }] }
```

## Fonctionnement

| Situation | Ce qui se passe |
|---|---|
| Une session appelle `sim-lease acquire ios` | Elle récupère son appareil si elle en a déjà un, sinon un appareil allumé et libre, sinon un nouveau (si on est sous le plafond) |
| La session est active | Son appareil lui reste réservé (activité = date de modification du transcript de la session) |
| La session ne fait rien depuis 20 min, ou appelle `release` | L'appareil reste allumé 10 min pour qu'une autre session le reprenne, puis il est éteint |
| Appareil démarré hors sim-lease | Il est éteint après 30 min s'il n'est pas utilisé |
| Tous les appareils sont occupés | `acquire` renvoie le code 3 ; on réessaie avec `--wait 300` |

Les appareils physiques ne sont jamais touchés.

## Réglages

Dans `~/.claude/sim-lease.conf` :

```bash
SIM_LEASE_MAX_IOS=3
SIM_LEASE_MAX_ANDROID=2
SIM_LEASE_STALE_MIN=20
SIM_LEASE_GRACE_MIN=10
SIM_LEASE_ADOPT_UNMANAGED=1        # 0 = ne jamais éteindre les appareils lancés à la main
SIM_LEASE_UNMANAGED_GRACE_MIN=30
```

## Commandes

```
sim-lease acquire ios|android [--name NAME] [--wait SECS]
sim-lease release [ID]
sim-lease status | json
sim-lease kill ID
sim-lease shutdown-idle
sim-lease reap
```

Debug de l'app : `build/SimBar.app/Contents/MacOS/SimBar --snapshot out.png` dessine le panneau avec les vraies données (certains boutons y apparaissent comme des carrés jaunes, c'est une limite d'`ImageRenderer`).
