# SimLease

Partage des simulateurs iOS et émulateurs Android entre plusieurs sessions Claude Code en parallèle, sans qu'ils s'accumulent.

- **`bin/sim-lease`** : chaque session « loue » un appareil au lieu d'en démarrer un nouveau. Le script réutilise un appareil allumé et libre, n'en démarre un que sous un plafond, et éteint ceux qui ne servent plus.
- **`app/SimBar.swift`** : app de barre des menus (en anglais, en français si le système est en français) qui montre :
  - les appareils démarrés, avec la RAM et le CPU de chacun ;
  - quelle session les utilise : un clic sur le nom et la description ouvre cette session ;
  - un clic sur l'icône du téléphone affiche le simulateur (Android : la fenêtre de l'émulateur ; iOS : Simulator.app, ou DeviceHub depuis Xcode 27, qui ne permet pas de choisir l'appareil) ;
  - un bouton pour éteindre, et une punaise pour **garder un appareil allumé** : il n'est alors jamais éteint automatiquement.

  Elle lance aussi le nettoyage toutes les 5 min. Si l'icône est cachée dans la barre des menus, relancer l'app ouvre le panneau dans une fenêtre.

## Installation

```bash
./build.sh          # installe ~/.claude/bin/sim-lease (copie) et ~/Applications/SimBar.app
open ~/Applications/SimBar.app
```

Ensuite, dans SimBar, **⚙ → Setup** indique si le script, la règle `<simulators>` de `~/.claude/CLAUDE.md` et le hook `SessionEnd` sont installés et à jour, et les installe en un clic (un point orange sur la roue signale qu'il manque quelque chose). L'app embarque sa propre copie de `bin/sim-lease` et de `CLAUDE.snippet.md`. Le hook est ajouté avec `jq` en gardant le reste de `settings.json` intact, et une sauvegarde est faite dans `settings.json.backup-simbar`.

À la main, le hook correspond à :

```json
{ "hooks": [{ "type": "command", "command": "$HOME/.claude/bin/sim-lease release-session", "timeout": 30 }] }
```

Relancer `./build.sh` après chaque modification de `bin/sim-lease`. C'est une copie et pas un lien symbolique : sinon macOS demande à SimBar l'accès au dossier Documents.

## Fonctionnement

| Situation | Ce qui se passe |
|---|---|
| Une session appelle `sim-lease acquire ios` | Elle récupère son appareil si elle en a déjà un, sinon un appareil allumé et libre, sinon un nouveau (si on est sous le plafond) |
| La session est active | Son appareil lui reste réservé (activité = date de modification du transcript de la session) |
| La session ne fait rien depuis 20 min, ou appelle `release` | L'appareil reste allumé 10 min pour qu'une autre session le reprenne, puis il est éteint |
| Appareil démarré hors sim-lease | Il est éteint après 30 min s'il n'est pas utilisé |
| Appareil épinglé (`sim-lease pin ID`) | Jamais éteint automatiquement, seulement à la main |
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
sim-lease pin|unpin ID
sim-lease shutdown-idle
sim-lease reap
```

Debug de l'app : `SimBar --setup DOSSIER` teste l'installation dans un faux `~/.claude`, et `build/SimBar.app/Contents/MacOS/SimBar --snapshot out.png` dessine le panneau avec les vraies données (certains boutons y apparaissent comme des carrés jaunes, c'est une limite d'`ImageRenderer`).
