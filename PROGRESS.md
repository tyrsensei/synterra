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

	var direction_input := Input.get_vector("ui_left", "ui_right", "ui_down", "ui_up") * speed
	if not is_on_floor():
		self.velocity.y += get_gravity().y * delta
	self.velocity.x = direction_input.x
	self.velocity.z = -direction_input.y

	move_and_slide()
```

Points clés retenus :
- X/Z (mouvement horizontal) : **assignation directe** depuis l'input à chaque frame (reflète l'état courant, pas une accumulation)
- Y (gravité) : **accumulation** (`+=`) multipliée par `delta` (accélération indépendante du framerate), seulement si `not is_on_floor()`
- Pas de multiplication par `delta` sur X/Z : `move_and_slide()` intègre déjà `velocity` (exprimée en unités/seconde) avec le temps en interne — contrairement à un déplacement `Node2D` classique (`position += direction * speed * delta`)
- Positionnement du `MeshInstance3D`/`CollisionShape3D` : décalés pour que l'origine du `CharacterBody3D` corresponde aux "pieds" du personnage, pas à son centre
- **Bug de mapping corrigé cette session** : `Input.get_vector(neg_x, pos_x, neg_y, pos_y)` — le 1er couple pilote `.x`, le 2e pilote `.y`. L'appel initial (`"ui_up", "ui_down", "ui_left", "ui_right"`) inversait x/y. Par ailleurs, en Godot 3D l'avant d'un nœud est **-Z** (convention fixe, valable pour tout `Node3D`), d'où le `-` sur `direction_input.y` : appuyer "haut" doit donner un `velocity.z` négatif pour avancer vers -Z.

**Caméra 3ᵉ personne : implémentée et testée en réseau réel ✅**

Référence visée : *Trails in the Sky 1st Chapter (remake)* — caméra en retrait, légère plongée, fixe pour l'instant (pas encore de rotation pilotée par le joueur, prévue plus tard).

Structure : `SpringArm3D` (enfant du `CharacterBody3D` "Player", orienté/positionné pour l'angle de vue voulu) → `Camera3D` (enfant du `SpringArm3D`).

- **`SpringArm3D`** choisi plutôt qu'un offset fixe (`Camera3D` en enfant direct avec `Vector3` constant) : fait un shapecast depuis son origine vers `spring_length` à chaque frame, raccourcit dynamiquement sa longueur effective en cas d'obstacle détecté → la caméra vient se coller devant le décor au lieu de le traverser. Un offset fixe n'aurait eu aucune de ces garanties.
- **Activation caméra multijoueur** : `make_current()` (pas la propriété `current`) appelé conditionnellement à `is_multiplayer_authority()`. Raison : `make_current()` désactive proprement toutes les autres `Camera3D` du même viewport (déterministe), alors que positionner plusieurs `current = true` sur des caméras spawnées dynamiquement (un `player.tscn` par joueur via `MultiplayerSpawner`) peut dépendre de l'ordre d'instanciation (non garanti en réseau).
- **Placement dans le cycle de vie** : code caméra placé dans `_ready()` (pas `_enter_tree()`, contrairement à `set_multiplayer_authority()`). Raison vérifiée dans la doc Godot : `_enter_tree()` s'exécute **parent → enfants** (donc `SpringArm3D`/`Camera3D` pas garantis prêts si appelé depuis `player.gd::_enter_tree()`), alors que `_ready()` s'exécute **enfants → parent** (donc toute la sous-arborescence est garantie initialisée quand `player.gd::_ready()` tourne). `is_multiplayer_authority()` reste fiable dans `_ready()` puisque `set_multiplayer_authority()` a déjà été posé en amont dans `_enter_tree()`.
- **Référence au nœud** : `@onready var camera: Camera3D = $SpringArm3D/Camera3D` — résolu juste avant `_ready()`, donc disponible sans re-fetch dans le corps de la fonction.
- **Collision layers/masks** configurées pour que le `SpringArm3D` ignore les autres joueurs (sinon un joueur passant devant la caméra masque toute la scène) :
  - Décor/sol : layer 1
  - Joueurs (`CharacterBody3D`) : layer 2, mask incluant 1 et 2 (collision avec le sol + les autres joueurs entre eux)
  - `SpringArm3D` : `collision_mask` sur layer 1 uniquement → ne scanne que le décor, ignore les joueurs quelle que soit leur layer
  - Le sol n'a pas eu besoin d'un mask particulier : c'est le `CharacterBody3D` du joueur qui pilote la détection sol via son propre mask pour `move_and_slide()`

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

**Caméra joueur 3ᵉ personne : implémentée ✅**

Structure (`scenes/player.tscn`) : `SpringArm3D` (enfant du `CharacterBody3D` "Player") + `Camera3D` (enfant du `SpringArm3D`). Angle façon *Trails in the Sky 1st Chapter* (léger recul + plongée) obtenu par rotation du `SpringArm3D`, `spring_length = 5.0`.

```gdscript
@onready var camera_3d: Camera3D = $SpringArm3D/Camera3D

func _ready() -> void:
	if is_multiplayer_authority():
		camera_3d.make_current()
```

Points clés retenus :
- `make_current()` préféré à la propriété `current = true` : avec plusieurs `Camera3D` simultanées dans le même viewport (un `player.tscn` par joueur spawné via `MultiplayerSpawner`), `make_current()` garantit un comportement déterministe (désactive proprement toute autre caméra active), contrairement à `current = true` où l'ordre d'instanciation réseau pourrait faire "gagner" la mauvaise caméra.
- Logique caméra volontairement séparée de celle de l'autorité réseau dans le cycle de vie du nœud, malgré les deux étant dans `player.gd` :
  - `set_multiplayer_authority()` reste en `_enter_tree()` (a besoin d'être précoce)
  - `camera_3d.make_current()` est en `_ready()`, pas en `_enter_tree()`
  - Raison : ordre d'exécution Godot **inversé** entre les deux callbacks — `_enter_tree()` descend parent → enfants (les enfants comme `SpringArm3D`/`Camera3D` ne sont pas garantis prêts quand le parent l'exécute), `_ready()` remonte enfants → parent (les enfants ont fini leur propre `_ready()` avant celui du parent, donc accessibles en toute sécurité). Vérifié empiriquement + confirmé par la doc officielle.
  - `@onready var camera_3d` s'évalue juste avant le `_ready()` du nœud porteur — donc soumis à la même garantie d'ordre, résolution fiable de `$SpringArm3D/Camera3D`.

**Collision layers/masks (nouveau système, mis en place pour la caméra) :**
- Layer 1 : décor/sol (défaut, non renommé pour l'instant)
- Layer 2 : joueurs (`CharacterBody3D` : `collision_layer = 2`, `collision_mask = 3` → détecte sol *et* autres joueurs, pour qu'ils se gênent physiquement)
- `SpringArm3D.collision_mask` : layer 1 uniquement → le shapecast de la caméra ignore totalement les autres joueurs (peu importe leur layer), ne réagit qu'au décor. Corrige le clipping/masquage d'écran quand un autre joueur passe devant la caméra.
- Retenu : le sol n'a pas besoin de connaître la layer des joueurs — c'est le `collision_mask` du `CharacterBody3D` lui-même qui pilote la détection sol dans `move_and_slide()`.

**Rotation caméra/perso pilotée par la souris : implémentée ✅ (validée en local, pas encore en réseau réel)**

Choix de gameplay tranché cette session : caméra et perso **couplés** (comme un TPS classique type WoW/ARPG) — tourner la caméra tourne aussi le perso, qui "regarde" toujours dans sa direction de vue. Le strafe gauche/droite est un vrai pas latéral, pas une rotation. C'est le `CharacterBody3D` lui-même qui tourne (pas de nœud pivot caméra séparé), et le `SpringArm3D`/`Camera3D` suivent automatiquement en tant qu'enfants.

Pattern retenu — **capture évènementielle, consommation physique** :
```gdscript
# Dans _input(event) :
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_move += event.relative
```
```gdscript
# Dans _physics_process(delta) :
rotate_y(-mouse_move.x * camera_speed)
mouse_move = Vector2.ZERO
```
- `_input()` **accumule** (`+=`, jamais un remplacement) le `relative` de chaque `InputEventMouseMotion` reçu, filtré via `if event is InputEventMouseMotion` (idiomatique : pas de cast explicite nécessaire, Godot infère le type dans le bloc). Nécessaire car Godot peut appeler `_input()` plusieurs fois par tick physique — un remplacement perdrait les deltas intermédiaires.
- `_physics_process()` **consomme puis reset à zéro** l'accumulateur à chaque tick. Sûr sans mécanisme de verrouillage particulier : Godot est single-threaded sur sa boucle de jeu, `_input()` et `_physics_process()` ne s'exécutent jamais en parallèle.
- `rotate_y()` préféré à une assignation directe sur `rotation.y` : rotation *relative* (cohérente avec un accumulateur de delta, pas une position absolue), et robuste à l'ordre d'application des angles d'Euler si d'autres axes de rotation s'ajoutent plus tard (tangage caméra prévu, voir "Prochaines étapes").
- `camera_speed` déclaré en `@export var` (valeur par défaut `0.005`, réglée empiriquement, ajustable depuis l'inspecteur sans recompiler) et axe X inversé (`-mouse_move.x`) pour un ressenti plus naturel — choix de confort, pas de contrainte technique.
- `Input.mouse_mode = Input.MOUSE_MODE_CAPTURED` posé dans `_ready()`, **conditionné par `is_multiplayer_authority()`** (même bloc que `camera_3d.make_current()`) — piège identifié et évité : posé initialement dans `_enter_tree()`, ce qui aurait capturé la souris à chaque instanciation de `player.tscn`, y compris pour les instances des *autres* joueurs répliquées localement. `_ready()` choisi pour la même raison que pour la caméra (ordre d'exécution enfants → parent, cohérence avec `camera_3d` déjà résolu).

**Conséquence sur le mouvement horizontal — passage d'un repère global à un repère local (piège découvert et corrigé) :**

Le code de mouvement existant (`velocity.x = direction_input.x`, `velocity.z = -direction_input.y`) assignait `velocity` en repère **global** — sans conséquence tant que le perso ne tournait jamais. Avec la rotation ajoutée, ce code cassait : la touche "avant" avançait toujours vers -Z du *monde*, jamais vers -Z du *perso*.

Correction — conversion via les vecteurs de base (`basis`) du `CharacterBody3D`, qui donnent les axes locaux actuels exprimés en coordonnées globales :
```gdscript
var move_direction: Vector3 = (
	direction_input.x * self.transform.basis.x
) + (
	-direction_input.y * self.transform.basis.z
)
self.velocity.x = move_direction.x
self.velocity.z = move_direction.z
```
- `basis.x` = direction "droite" actuelle du perso (utilisé pour le strafe)
- `basis.z` = direction "arrière" actuelle du perso en repère global (convention -Z-local-avant déjà établie), d'où le `-` pour obtenir un vecteur "avant" exploitable
- Un seul `Vector3` (`move_direction`) construit par combinaison scalaire + somme vectorielle, puis décomposé en `.x`/`.z` à l'assignation finale — évite de dupliquer le calcul pour chaque axe séparément
- Piège intermédiaire rencontré en cours de route : confusion entre `basis.y` (axe vertical, haut/bas) et `basis.z` (axe avant/arrière) — à garder en tête, l'intuition du nom d'axe ne suffit pas toujours, se fier à la convention -Z-avant déjà documentée

**Bug corrigé en cours de route (mapping input) :** l'ordre des arguments de `Input.get_vector()` compte : le 1er couple pilote `.x` du vecteur retourné, le 2e pilote `.y`. Appel final retenu :
```gdscript
var direction_input := Input.get_vector("ui_left", "ui_right", "ui_down", "ui_up") * speed
...
self.velocity.x = direction_input.x
self.velocity.z = -direction_input.y  # -Z = avant en Godot 3D, d'où le signe négatif
```
Rappel convention Godot 3D : **-Z local = "avant"** d'un `Node3D` (visible dans l'éditeur via le frustum de la `Camera3D` ou le gizmo d'axes, bleu = Z).

## Prochaines étapes

1. **Non testé en réseau réel (2 instances) avec la rotation caméra/perso** : la rotation souris (voir section dédiée ci-dessous) a été validée en local (un seul poste) mais pas encore confirmée en test réseau croisé — vérifier que chaque client capture bien sa propre souris et tourne sa propre caméra (conditionné par `is_multiplayer_authority()`), sans affecter les instances des autres joueurs répliquées localement.
2. **Tangage caméra (mouvement vertical souris) — non implémenté** : `mouse_move.y` est déjà accumulé mais volontairement inutilisé pour l'instant. Décision prise en session : le mouvement vertical de la souris doit piloter une rotation indépendante du `SpringArm3D` seul (tangage caméra), *sans* affecter la rotation du `CharacterBody3D` qui doit rester à plat. À implémenter dans une session dédiée à l'affinage caméra.
3. **Gestion d'erreur de connexion (identifiée, non implémentée)** : prévoir un signal (ex. `connection_rejected`) émis par `NetworkManager` en cas de mot de passe incorrect ou de `connection_failed`, pour permettre un retour au menu principal. Actuellement, un client dont la connexion échoue reste bloqué sur `game.tscn` sans réseau. Jugé non urgent pour un premier prototype (repoussé une session).
4. **Nettoyage mineur** : vérifier qu'il n'y a plus de risque de double `change_scene()` entre `SceneManager.join_server()` et `SceneManager._on_server_ready()` côté client (a priori réglé par le retrait de `server_ready.emit()` dans `update_players()`, à documenter/confirmer explicitement).
5. **Validation croisée test/prod** : la scène de test (`tests/test.tscn`) ne couvre que le rôle serveur pour l'instant (`skip_scene_loading = true` + `create_server()` direct) — pas de pendant "client" pour tester ce rôle en isolation. Pas bloquant, le vrai chemin de prod (menu) sert de test client actuellement.
6. Étoffer `tests/test.tscn` au fil des prochaines features (combat, particules) plutôt que de créer une nouvelle scène de test à chaque fois.

## Idées notées pour plus tard (hors scope immédiat)

- Mode "construction" in-game (remplaçant potentiel de l'éditeur de niveaux abandonné) : à explorer dans une session dédiée à l'architecture combat/exploration.
- Exploration et combat prévus dans la **même scène/niveau**, avec état partagé (ex. un feu allumé en exploration doit être utilisable en combat) — pas de `change_scene_to_file()` entre les deux modes, plutôt une machine à états sur place. Question ouverte : à trancher dans une session dédiée à l'architecture du système de combat.

## Décisions d'architecture (rappel)

- Pattern authoritative pour le réseau (validation serveur), sauf mouvement joueur (autorité client assumée pour l'instant, validation serveur en TODO)
- Séparation stricte réseau (`network_manager.gd`) / navigation (`scene_manager.gd`) : le réseau ne connaît aucune scène, la navigation ne connaît aucun détail réseau interne
- Éditeur de niveaux intégré : abandonné (trop de complexité pour un projet solo) — mode "construction" in-game envisagé comme alternative future
- Renderer Compatibility (OpenGL 3.3 / ES 3.0) pour accessibilité max + export WebGL
