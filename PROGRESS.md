# Progress — Synterra

> Ce fichier sert de point de resynchronisation rapide entre les sessions de travail avec Claude. Mis à jour en fin de session.

## État actuel

**Réseau (base) : fonctionnel et validé en test réel (2 instances Godot, via le menu principal en conditions de prod)**
- Topologie host-serveur via `ENetMultiplayerPeer`, port 7000, protection par mot de passe
- Pattern authoritative (client → serveur → broadcast), validation côté serveur
- Liste de joueurs gérée côté serveur uniquement (autoritative)
- Signaux ENet connectés : `connected_to_server`, `connection_failed`, `peer_connected`, `peer_disconnected`, `server_disconnected`
- Identification de l'expéditeur RPC via `multiplayer.get_remote_sender_id()`

**Synchronisation de position : implémentée**
- `scenes/player.tscn` : `CharacterBody3D` (racine "Player") + `CollisionShape3D` + `MeshInstance3D` (capsules) + `MultiplayerSynchronizer` configuré sur `Player:position` et `Player:rotation` (Point d'apparition + Toujours cochés)
- `levels/game.tscn` : `Game` > `PlayersSpawner` (`MultiplayerSpawner`, Spawn Path → `Players`) + `Players` (Node3D vide, frère du spawner, Auto Spawn List contient `player.tscn`)
- `network_manager.gd` (autoload) : fonction `add_player(player_id, peer_player_info)` unifiée, appelée depuis `on_scene_loaded_on_server()` (id=1, côté serveur) et depuis `update_player_info()` côté serveur (après validation mot de passe) ; stocke `players[player_id]` et instancie `player.tscn` sous `get_tree().current_scene.get_node("Players")`, nom du nœud `"Player-" + str(player_id)`

**Autorité réseau du joueur : implémentée ✅**

`set_multiplayer_authority()` n'est **pas** répliqué par le `MultiplayerSynchronizer` (métadonnée locale à chaque instance du nœud, gérée par le moteur réseau). Solution : `scenes/player.gd`, dans `_enter_tree()` (s'exécute sur **toute** machine où le nœud entre dans l'arbre, y compris via réplication du spawner), extraction de l'ID depuis le nom du nœud (`"Player-2"` → `2`).

Note mineure non bloquante encore ouverte : `network_manager.gd::add_player()` ne rappelle plus `set_multiplayer_authority()` lui-même (nettoyé), seul `player.gd::_enter_tree()` s'en charge — à vérifier/documenter comme acquis.

**Mouvement joueur : implémenté et testé en réseau réel ✅**

```gdscript
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	var direction_input := Input.get_vector("ui_up", "ui_down", "ui_left", "ui_right") * speed
	if not is_on_floor():
		self.velocity.y += get_gravity().y * delta
	self.velocity.x = direction_input.x
	self.velocity.z = direction_input.y

	move_and_slide()
```

Points clés retenus :
- X/Z (mouvement horizontal) : **assignation directe** depuis l'input à chaque frame (reflète l'état courant, pas une accumulation)
- Y (gravité) : **accumulation** (`+=`) multipliée par `delta` (accélération indépendante du framerate), seulement si `not is_on_floor()`
- Pas de multiplication par `delta` sur X/Z : `move_and_slide()` intègre déjà `velocity` (exprimée en unités/seconde) avec le temps en interne — contrairement à un déplacement `Node2D` classique (`position += direction * speed * delta`)
- Positionnement du `MeshInstance3D`/`CollisionShape3D` : décalés pour que l'origine du `CharacterBody3D` corresponde aux "pieds" du personnage, pas à son centre

**Scène de test créée : `tests/test.tscn` — réutilisable pour les futures features (combat, particules...)**

Structure : sol (`StaticBody3D` + collision générée via Mesh → Create Trimesh Static Body) + `Players` (Node3D vide, même convention que `game.tscn`) + `WorldEnvironment` + `Camera3D` + `DirectionalLight3D`. Script `tests/test.gd` :

```gdscript
extends Node3D

func _ready() -> void:
	SceneManager.set_skip_scene_loading(true)
	NetworkManager.create_server("TyR", "password")
```

Passe par le **vrai chemin réseau de prod** (`create_server()`), donc teste aussi l'intégration réseau, pas juste la logique de mouvement isolée.

**Architecture réseau/navigation — refactorisée cette session (changement important) ✅**

Problème de départ : `create_server()` et `update_players()` faisaient chacun un `change_scene_to_file()` en dur, dupliqué et rigide (couplait `network_manager.gd`, censé rester une boîte noire réseau, à la connaissance des scènes du jeu).

Itérations et pièges rencontrés, dans l'ordre :
1. **Rejeté** : passer la scène cible en paramètre de `create_server()` — recouple le réseau à la navigation.
2. **Rejeté** : écouter le signal global `scene_changed` du `SceneTree` pour déclencher `add_player()` côté serveur — se déclencherait sur *n'importe quel* changement de scène du jeu (menu, futurs niveaux), nécessiterait un garde-fou fragile.
3. **Piège découvert** : un `await` (ex. `await get_tree().scene_changed`) écrit dans le script d'une scène qui est elle-même en train d'être remplacée par ce changement de scène peut devenir une coroutine orpheline — le nœud porteur du `await` est libéré (`queue_free()`, différé en fin de frame) avant/pendant l'attente, donc le code après l'`await` ne s'exécute jamais de façon garantie. Piège rencontré une première fois dans `SceneManager`, puis une seconde fois dans `main_menu.gd` (symptôme : `join_server()` jamais appelé, aucun log côté client). **Leçon générale : toute séquence "changer de scène → attendre → agir" doit vivre entièrement dans un nœud qui survit au changement de scène (autoload), jamais dans le script de la scène qui va être remplacée.**
4. **Piège découvert (timing réseau)** : le `MultiplayerSpawner` réplique automatiquement les nœuds déjà spawnés (et les nouveaux) vers un pair dès que la connexion réseau est établie — pas seulement après confirmation applicative. Si le client se connecte (`join_server()`) *avant* d'avoir chargé `game.tscn`, la réplication échoue silencieusement côté client (`Node not found: "Game/PlayersSpawner"`, `on_spawn_receive: Parameter "spawner" is null`) car le nœud spawner n'existe pas encore dans sa scène. **Leçon générale : côté client, charger la scène cible doit précéder l'établissement de la connexion réseau, pas le suivre.**

**Architecture finale retenue :**
- `network_manager.gd` : logique réseau pure. Émet `server_ready` uniquement depuis `create_server()` (plus depuis `update_players()`, retiré pour éviter un double-déclenchement). Expose `on_scene_loaded_on_server()` (spawn du joueur serveur, id=1) — fonction "confiante", sans garde-fou interne : c'est à l'appelant de savoir quand l'appeler.
- `scene_manager.gd` (nouvel autoload) : orchestrateur de navigation, seul responsable des transitions de scène.
  - Côté serveur : écoute `NetworkManager.server_ready` → `_on_server_ready()` → `change_scene()` (si `not skip_scene_loading`) → si `multiplayer.is_server()`, appelle `NetworkManager.on_scene_loaded_on_server()`.
  - Côté client : fonction dédiée `join_server(nickname, password)` → `await change_scene()` → **puis seulement** `NetworkManager.join_server(...)`. Appelée directement depuis `main_menu.gd` (pas de dépendance à un signal réseau, puisque le réseau n'est pas encore établi à ce stade).
- `main_menu.gd` : appelle `NetworkManager.create_server(...)` (host) ou `SceneManager.join_server(...)` (join) — ne pilote plus lui-même aucun `await`/changement de scène.

## Prochaines étapes

1. **Gestion d'erreur de connexion (identifiée, non implémentée)** : prévoir un signal (ex. `connection_rejected`) émis par `NetworkManager` en cas de mot de passe incorrect ou de `connection_failed`, pour permettre un retour au menu principal. Actuellement, un client dont la connexion échoue reste bloqué sur `game.tscn` sans réseau.
2. **Nettoyage mineur** : vérifier qu'il n'y a plus de risque de double `change_scene()` entre `SceneManager.join_server()` et `SceneManager._on_server_ready()` côté client (a priori réglé par le retrait de `server_ready.emit()` dans `update_players()`, à documenter/confirmer explicitement).
3. **Validation croisée test/prod** : la scène de test (`tests/test.tscn`) ne couvre que le rôle serveur pour l'instant (`skip_scene_loading = true` + `create_server()` direct) — pas de pendant "client" pour tester ce rôle en isolation. Pas bloquant, le vrai chemin de prod (menu) sert de test client actuellement.
4. Étoffer `tests/test.tscn` au fil des prochaines features (combat, particules) plutôt que de créer une nouvelle scène de test à chaque fois.

## Idées notées pour plus tard (hors scope immédiat)

- Mode "construction" in-game (remplaçant potentiel de l'éditeur de niveaux abandonné) : à explorer dans une session dédiée à l'architecture combat/exploration.
- Exploration et combat prévus dans la **même scène/niveau**, avec état partagé (ex. un feu allumé en exploration doit être utilisable en combat) — pas de `change_scene_to_file()` entre les deux modes, plutôt une machine à états sur place. Question ouverte : à trancher dans une session dédiée à l'architecture du système de combat.

## Décisions d'architecture (rappel)

- Pattern authoritative pour le réseau (validation serveur), sauf mouvement joueur (autorité client assumée pour l'instant, validation serveur en TODO)
- Séparation stricte réseau (`network_manager.gd`) / navigation (`scene_manager.gd`) : le réseau ne connaît aucune scène, la navigation ne connaît aucun détail réseau interne
- Éditeur de niveaux intégré : abandonné (trop de complexité pour un projet solo) — mode "construction" in-game envisagé comme alternative future
- Renderer Compatibility (OpenGL 3.3 / ES 3.0) pour accessibilité max + export WebGL
