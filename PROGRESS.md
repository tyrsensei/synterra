# Progress — Synterra

> Ce fichier sert de point de resynchronisation rapide entre les sessions de travail avec Claude. Mis à jour en fin de session.

## État actuel

**Réseau (base) : fonctionnel et validé en test réel (2 instances Godot en ligne de commande)**
- Topologie host-serveur via `ENetMultiplayerPeer`, port 7000, protection par mot de passe
- Pattern authoritative (client → serveur → broadcast), validation côté serveur
- Liste de joueurs gérée côté serveur uniquement (autoritative)
- Signaux ENet connectés : `connected_to_server`, `connection_failed`, `peer_connected`, `peer_disconnected`, `server_disconnected`
- Identification de l'expéditeur RPC via `multiplayer.get_remote_sender_id()`

**Synchronisation de position : implémentée**
- `scenes/player.tscn` : `CharacterBody3D` (racine "Player") + `CollisionShape3D` + `MeshInstance3D` (capsules) + `MultiplayerSynchronizer` configuré sur `Player:position` et `Player:rotation` (Point d'apparition + Toujours cochés)
- `levels/game.tscn` : `Game` > `PlayersSpawner` (`MultiplayerSpawner`, Spawn Path → `Players`) + `Players` (Node3D vide, frère du spawner, Auto Spawn List contient `player.tscn`)
- `network_manager.gd` (autoload) : fonction `add_player(player_id, peer_player_info)` unifiée, appelée depuis `create_server()` (id=1, après succès) et depuis `update_player_info()` côté serveur (après validation mot de passe) ; stocke `players[player_id]` et instancie `player.tscn` sous `get_tree().current_scene.get_node("Players")`, nom du nœud `"Player-" + str(player_id)`

**Piège identifié — corrigé ✅**

`change_scene_to_file()` est différé (idle time) → nécessitait `await get_tree().scene_changed`. Vérifié dans `network_manager.gd` :
- côté serveur, dans `create_server()`, avant `add_player()`
- côté client, dans `update_players()`, qui change de scène sans appeler `add_player()` lui-même — c'est bien le `MultiplayerSpawner` qui réplique automatiquement

**Autorité réseau du joueur : implémentée ✅**

Piège découvert cette session : `set_multiplayer_authority()` n'est **pas** une donnée répliquée par le `MultiplayerSynchronizer` (c'est une métadonnée locale à chaque instance du nœud sur chaque machine, gérée par le moteur réseau). Donc appeler `set_multiplayer_authority()` uniquement côté serveur dans `add_player()` ne suffit pas : les clients qui reçoivent le nœud via le `MultiplayerSpawner` ne repassent jamais par cette fonction, et se retrouvent avec l'autorité par défaut.

Solution retenue : `scenes/player.gd`, dans `_enter_tree()` (s'exécute sur **toute** machine où le nœud entre dans l'arbre, y compris via réplication du spawner) :

```gdscript
extends CharacterBody3D
class_name Player

func _enter_tree() -> void:
	var multiplayer_id := int(self.name.split("-")[1])
	set_multiplayer_authority(multiplayer_id)
```

L'ID est extrait du nom du nœud (`"Player-2"` → `2`), convention posée par `add_player()` dans `network_manager.gd`.

Note mineure : `add_player()` appelle aussi `player.set_multiplayer_authority(player_id)` avant le `add_child()` — redondant avec le `_enter_tree()` de `player.gd` (qui gère déjà tous les cas, y compris côté clients), mais pas bloquant. À nettoyer ou assumer comme "belt and suspenders" plus tard.

**Mouvement joueur : en cours 🔄**

`scenes/player.gd`, squelette posé dans `_physics_process()` :

```gdscript
func _physics_process(delta: float) -> void:
    if not is_multiplayer_authority():
        return

	# 1. Récupérer l'input (direction souhaitée)
	var direction_input := Input.get_vector("ui_up", "ui_down", "ui_left", "ui_right")
	# 2. Appliquer la gravité si besoin (CharacterBody3D)
	# 3. Définir self.velocity en fonction de l'input

    move_and_slide()
```

**Bug connu à corriger à la prochaine session :** l'ordre des paramètres de `Input.get_vector()` est `(negative_x, positive_x, negative_y, positive_y)`. Actuellement `("ui_up", "ui_down", "ui_left", "ui_right")` mappe up/down sur l'axe X — inversion à corriger avant de brancher la vélocité.

## Prochaines étapes

1. Corriger l'ordre des paramètres de `Input.get_vector()` (voir bug connu ci-dessus)
2. Ajouter la gravité (`CharacterBody3D` : accumulation sur l'axe Y, cf. `get_gravity()` ou constante projet)
3. Mapper la direction d'input (2D, X/Y écran) vers les axes 3D du monde (X/Z), assigner `self.velocity`
4. Nettoyer la redondance `set_multiplayer_authority()` entre `network_manager.gd::add_player()` et `player.gd::_enter_tree()`
5. Tester en réel à deux instances (mouvement + autorité correcte par joueur)

## Décisions d'architecture (rappel)

- Pattern authoritative pour le réseau (validation serveur), sauf mouvement joueur (autorité client assumée pour l'instant, cf. ci-dessus)
- Éditeur de niveaux intégré : abandonné (trop de complexité pour un projet solo)
- Renderer Compatibility (OpenGL 3.3 / ES 3.0) pour accessibilité max + export WebGL
