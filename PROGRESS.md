# Progress — Synterra

> Ce fichier sert de point de resynchronisation rapide entre les sessions de travail avec Claude. Mis à jour en fin de session.

## État actuel

**Réseau (base) : fonctionnel et validé en test réel (2 instances Godot en ligne de commande)**
- Topologie host-serveur via `ENetMultiplayerPeer`, port 7000, protection par mot de passe
- Pattern authoritative (client → serveur → broadcast), validation côté serveur
- Liste de joueurs gérée côté serveur uniquement (autoritative)
- Signaux ENet connectés : `connected_to_server`, `connection_failed`, `peer_connected`, `peer_disconnected`, `server_disconnected`
- Identification de l'expéditeur RPC via `multiplayer.get_remote_sender_id()`

**Synchronisation de position (en cours)**
- `scenes/player.tscn` : `CharacterBody3D` (racine "Player") + `CollisionShape3D` + `MeshInstance3D` (capsules) + `MultiplayerSynchronizer` configuré sur `Player:position` et `Player:rotation` (Point d'apparition + Toujours cochés)
- `levels/game.tscn` : `Game` > `PlayersSpawner` (`MultiplayerSpawner`, Spawn Path → `Players`) + `Players` (Node3D vide, frère du spawner, Auto Spawn List contient `player.tscn`)
- `network_manager.gd` (autoload) : fonction `add_player(player_id, peer_player_info)` unifiée, appelée depuis `create_server()` (id=1, après succès) et depuis `update_player_info()` côté serveur (après validation mot de passe) ; stocke `players[player_id]` et instancie `player.tscn` sous `get_tree().current_scene.get_node("Players")` (casté en `Node3D`), nom du nœud `"Player-" + str(player_id)`

## Piège identifié — corrigé ✅

`change_scene_to_file()` est différé (idle time) → nécessitait `await get_tree().scene_changed`. Vérifié dans `network_manager.gd` :
- côté serveur, dans `create_server()` (lignes 28-29), avant `add_player()`
- côté client, dans `update_players()` (lignes 89-90), qui change de scène sans appeler `add_player()` lui-même — c'est bien le `MultiplayerSpawner` qui réplique automatiquement

## Prochaines étapes

1. Écrire le script de déplacement sur `player.tscn` avec `set_multiplayer_authority()`
   - Choix : autorité client, **sans** validation serveur pour l'instant (contexte combat tour par tour + hébergement joueurs type LAN → peu de risque de triche compétitive)
   - Validation serveur notée comme amélioration future
2. Tester en réel à deux instances

## Décisions d'architecture (rappel)

- Pattern authoritative pour le réseau (validation serveur), sauf mouvement joueur (autorité client assumée pour l'instant, cf. ci-dessus)
- Éditeur de niveaux intégré : abandonné (trop de complexité pour un projet solo)
- Renderer Compatibility (OpenGL 3.3 / ES 3.0) pour accessibilité max + export WebGL
