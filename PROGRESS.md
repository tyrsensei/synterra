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

**Tangage caméra (rotation verticale souris) : implémenté ✅ (validé en réseau réel, 2 instances)**

Point ouvert de la session précédente clos en premier : la rotation horizontale (caméra/perso couplés) a été testée en réseau croisé — seule l'instance ayant le focus voit sa caméra bouger, confirmant que `is_multiplayer_authority()` filtre correctement l'input souris entre pairs répliqués.

Architecture retenue pour le tangage, après discussion des alternatives :
- **Nouveau nœud `CameraPivot`** (`Node3D`) inséré entre `CharacterBody3D` et `SpringArm3D` : `CharacterBody3D` (rotation Y) → `CameraPivot` (rotation X dynamique, nouveau) → `SpringArm3D` (offset fixe "Trails in the Sky", inchangé) → `Camera3D`.
- Raison du nœud séparé plutôt que de tourner le `SpringArm3D` directement : celui-ci porte déjà une rotation *fixe* (l'angle artistique de plongée). Faire cohabiter cet offset fixe avec une rotation *dynamique* clampée sur le même nœud aurait faussé les bornes du clamp (`rotation.x` ne serait pas parti de zéro). Le `CameraPivot` isole la valeur "dynamique pure".
- Shapecast du `SpringArm3D` non impacté par le changement de parent : le cast part toujours de son origine locale, quel que soit son parent — seule son orientation/position *globale* change (effet recherché : le tangage doit affecter la détection de collision de la caméra).

```gdscript
@export var camera_pivot_min = -PI/4
@export var camera_pivot_max = PI/4
@onready var camera_pivot: Node3D = $CameraPivot
...
camera_pivot.rotate_x(-mouse_move.y * camera_speed)
if camera_pivot.rotation.x > camera_pivot_max or camera_pivot.rotation.x < camera_pivot_min:
	camera_pivot.rotation.x = clamp(camera_pivot.rotation.x, camera_pivot_min, camera_pivot_max)
```

- Bornes en **radians bruts** dans l'inspecteur (`PI/4` par défaut de part et d'autre) — pas de conversion degrés↔radians, choix assumé pour rester cohérent avec `rotate_x()` qui travaille nativement en radians. Valeurs à affiner à l'usage.
- **Bug rencontré et corrigé pendant la session** : le clamp lisait/écrivait initialement `self.rotation.x` (rotation du `CharacterBody3D`) au lieu de `camera_pivot.rotation.x` — confusion entre le nœud sur lequel `rotate_x()` est appelé (`camera_pivot`) et celui vérifié par la condition de clamp (`self`). Symptôme : le clamp semblait ne rien faire. Leçon : bien vérifier que le clamp lit/écrit sur le **même nœud** que celui qui accumule la rotation.
- Axe inversé (`-mouse_move.y`) pour un ressenti cohérent avec l'inversion déjà faite sur l'axe Y (`-mouse_move.x`) — confort, pas contrainte technique.

**Tangage caméra validé en réseau croisé ✅** — même comportement observé que pour la rotation horizontale : seule l'instance ayant le focus voit sa caméra bouger verticalement, comportement correct des deux côtés.

**Risque de double `change_scene()` — vérifié par relecture de code, écarté ✅**

Retracé les deux chemins (host et join) :
- **Host** : `main_menu.gd` → `NetworkManager.create_server()` → émet `server_ready` → seul écouteur `SceneManager._on_server_ready()` → `change_scene()` appelé **une fois**.
- **Client (join)** : `main_menu.gd` → `SceneManager.join_server()` → `change_scene()` appelé **une fois** directement, puis `NetworkManager.join_server()` (qui n'émet pas `server_ready`) → aucun re-déclenchement possible de `_on_server_ready()` côté client.
- `update_players()` (RPC reçu côté client après validation mot de passe) n'émet plus rien, confirmé — le retrait de `server_ready.emit()` mentionné en session précédente est bien effectif.

**Nuance retenue (pas un bug, une fragilité silencieuse)** : la garantie actuelle repose sur la discipline d'appel (seul `main_menu.gd` orchestre host/join, et n'appelle jamais `create_server()` côté client) plutôt que sur un garde-fou structurel dans le code. Rien n'empêcherait aujourd'hui un futur appel erroné de `create_server()` depuis un contexte client d'émettre `server_ready` par erreur. Non bloquant vu la taille actuelle du projet — à garder en tête si l'architecture se complexifie (plusieurs points d'entrée réseau, reconnexion, etc.).

**Gestion d'erreur de connexion : implémentée et testée en réseau réel ✅**

Deux cas distincts identifiés et traités séparément, convergeant vers un signal commun côté client :

- **Mot de passe incorrect** : détecté côté serveur dans `update_player_info()` (`@rpc("any_peer")`). Le serveur notifie le client fautif via un RPC ciblé (`rpc_id(remote_id, "notify_connection_error", "Password Error")`), **avant** de forcer sa déconnexion (`multiplayer.multiplayer_peer.disconnect_peer(remote_id)`).
  - **Piège de timing découvert et corrigé empiriquement** : sans délai, `disconnect_peer()` coupait la connexion avant que le RPC de notification n'ait eu le temps d'être physiquement envoyé (aucune trace du message côté client dans les logs, malgré un ordre d'appel apparemment correct dans le code). Un `await get_tree().create_timer(0.1).timeout` entre les deux appels laisse le temps à ENet de vider sa file d'envoi. Solution validée par test réel (logs confirmant l'ordre correct), pas seulement déduite de la doc — retenir ce réflexe pour tout futur cas "notifier avant de couper la connexion".
  - RPC dédié `notify_connection_error(reason: String)` (`@rpc("authority", "call_remote")`), reçu côté client, émet le signal `NetworkManager.connection_error`.
- **Serveur injoignable** (`connection_failed`, signal ENet natif) : déjà câblé sur `_on_connected_fail()`, qui émet directement `connection_error.emit("Connection failed")`. Délai avant déclenchement dépendant du timeout ENet interne (assez long, plusieurs secondes) — acceptable pour un prototype LAN, non retravaillé cette session (voir feedback visuel ci-dessous qui compense ce délai).

**Propagation du signal à travers un changement de scène — piège identifié et résolu :**

Le menu (`main_menu.tscn`) est déchargé dès la tentative de connexion (`SceneManager.join_server()` change de scène *avant* d'appeler `NetworkManager.join_server()`), donc un nœud de `main_menu.gd` qui se serait abonné à un signal dans son propre `_ready()` initial ne peut plus le recevoir — il a été détruit entretemps. Solution : `NetworkManager.connection_error` est écouté par **`SceneManager`** (autoload, survit aux changements de scène), qui recharge `main_menu.tscn` puis émet son propre signal `SceneManager.error(reason)` — écouté à ce moment-là par la **nouvelle** instance de `main_menu.gd`, fraîchement instanciée et donc bien vivante pour recevoir le signal. Pattern à retenir : ne jamais faire porter un signal de flux réseau/scène directement par un nœud de scène qui va et vient — le faire relayer par un autoload.

Affichage du message : `main_menu.tscn` a un nœud `Error` (`Label`), vide par défaut (pas de reset manuel nécessaire — chaque `change_scene_to_packed()` instancie une toute nouvelle scène, donc l'état par défaut est naturellement restauré).

**Feedback "connexion en cours" côté client — implémenté ✅**

Un `Label` "Loading" dans `game.tscn` (`levels/game_ui.gd`, `CanvasLayer`), visible dès l'arrivée sur la scène de jeu (dans les deux rôles), caché une fois la connexion confirmée :
- **Côté serveur** : `SceneManager._on_server_ready()` émet `loaded_complete` directement après `on_scene_loaded_on_server()`.
- **Côté client** : nouveau signal dédié `NetworkManager.client_ready`, émis dans `update_players()` (le RPC reçu côté client *après* validation du mot de passe par le serveur — pas dans `_on_connected_ok()`, qui ne signale que la connexion réseau bas niveau, trop tôt puisque le mot de passe n'est pas encore validé à ce stade). `SceneManager` s'y abonne et relaie vers son propre `loaded_complete`, suivant le même principe de découplage que pour `connection_error`.
- **Piège RPC résolu en cours de route** : une fonction annotée `@rpc` s'exécute sur la machine qui **reçoit** l'appel, pas celle qui l'émet — `update_player_info()` (appelée par le client via `rpc_id(1, ...)`) s'exécute côté **serveur**, pas côté client, ce qui explique un premier essai infructueux d'émettre le signal directement dedans.

**Nettoyage des joueurs déconnectés — implémenté et testé en réseau réel ✅**

Nouvelle fonction `remove_player(player_id)`, symétrique à `add_player()`, appelée depuis `_on_peer_disconnected()` (déjà câblée, gère tout type de déconnexion : volontaire, timeout, forcée par le serveur).

**Piège découvert et corrigé** : `players_container.find_child(str("Player-", player_id))` retournait `null` alors que le nœud était bien visible dans l'arbre distant du débogueur. Cause : `find_child()` a par défaut `owned = true`, qui restreint la recherche aux nœuds ayant un **`owner`** valide. Un nœud instancié dynamiquement via `PackedScene.instantiate()` puis `add_child()` (comme le fait `add_player()`) n'a **aucun owner assigné automatiquement** — contrairement aux nœuds placés dans l'éditeur, où Godot assigne l'owner à la scène automatiquement. `owner` reste donc `null`, ignoré silencieusement par `find_child(owned=true)`. Solution : `find_child(str("Player-", player_id), true, false)` (troisième argument `owned` explicitement à `false`). Diagnostiqué par test empirique (vérification du `player_id` reçu, confirmation que le nœud attendu existe bien dans l'arbre distant) plutôt que par lecture seule de la doc, qui ne précisait pas ce cas implicite.

## Session — State machine par joueur (Exploration / Combat / Construction)

**Objectif de session** : poser les fondations du changement d'état par joueur (Exploration / Combat / Construction), sans encore implémenter la logique de déclenchement ni le futur `CombatManager`.

**Décision d'architecture retenue** : l'état est **par joueur**, pas partagé au niveau de l'instance `Game` — un joueur peut rester en exploration pendant qu'un autre est en combat (voir `GAMEPLAY.md` pour le détail du raisonnement gameplay). La variable d'état vit sur `player.gd` (`scenes/player.gd`), l'enum et les RPC de transition vivent dans un autoload dédié (`states.gd`, enregistré sous le nom `States`).

**Pattern RPC retenu (à trois temps)**, cohérent avec l'existant (`update_player_info`) :
1. Client → serveur : `rpc_id(1, "request_state_change", nouvel_état)` (à câbler côté `player.gd`, pas encore fait)
2. Serveur, réception : `request_state_change` (`@rpc("any_peer")`), identifie l'auteur via `multiplayer.get_remote_sender_id()`, pas de validation pour l'instant (le futur `CombatManager` en aura la responsabilité)
3. Serveur → tous : `notify_state_changed` (`@rpc("authority", "call_local")`), résout le nœud `Player` concerné via `get_node_or_null("Players/Player-" + str(player_id))` sur `current_scene`, applique `player.state = new_state`

**Code actuel (`states.gd`, committé)** :
```gdscript
extends Node

enum PlayerState {EXPLORATION, FIGHT, BUILD}

@rpc("any_peer")
func request_state_change(new_state: PlayerState):
	var player_id := multiplayer.get_remote_sender_id()
	rpc("notify_state_changed", player_id, new_state)

@rpc("authority", "call_local")
func notify_state_changed(player_id: int, new_state: PlayerState):
	var player: Player = get_tree().current_scene.get_node_or_null(
		str("Players/Player-", player_id)
	)
	if player:
		player.state = new_state
```
Et dans `player.gd` : `var state: States.PlayerState = States.PlayerState.EXPLORATION`.

**Piège moteur découvert et documenté — conflit `class_name` / nom d'autoload :**

Un `class_name` et un nom d'autoload (déclaré dans Project Settings > Autoload) partagent le **même espace de noms global** dans Godot 4. Donner à un script autoload un `class_name` identique à son nom d'autoload (ex. `class_name States` sur le script enregistré comme autoload `States`) provoque l'erreur `Class "X" hides an autoload singleton`. Sans `class_name` du tout, Godot attribue à la place un identifiant de type **généré automatiquement** (un hash lié au fichier, ex. `b1u716w1xlgk5`), qui peut être résolu différemment selon le contexte d'où il est référencé dans le code — d'où une possible incompatibilité de type (`states.gd.PlayerState` vs `b1u716w1xlgk5.PlayerState`) entre deux scripts qui pensent pourtant référencer le même enum.

Solution standard (contournement documenté, voir issue Godot #28187 et forum officiel) : donner au script un `class_name` **différent** du nom d'autoload (ex. `class_name GameStates` sur le script enregistré comme autoload `States`) — les appels globaux (`States.xxx`) et le typage (`GameStates.PlayerState`) cohabitent alors sans conflit.

**⚠️ État non résolu à la fin de cette session — point bloquant pour la suite :**

Le fichier `states.gd` actuellement committé **n'a pas de `class_name`**. Le typage fonctionne actuellement dans l'éditeur (`States.PlayerState` dans `player.gd` résout correctement), mais ce comportement s'est avéré **instable pendant la session** : la même erreur de type est apparue puis a disparu à plusieurs reprises selon l'état du cache de l'éditeur et l'ordre de résolution des scripts, sans changement de code entre certaines de ces variations. Rien ne garantit que ce comportement reste stable après un export, sur une autre machine, ou même après un simple reload futur du projet.

**À faire en priorité à la prochaine session, avant toute nouvelle feature sur les états** :
1. Ajouter `class_name GameStates` en tête de `states.gd` (autoload restant nommé `States` dans Project Settings) pour obtenir un typage stable et documenté plutôt que de compter sur le hash auto-généré
2. Adapter le typage dans `player.gd` en conséquence (`var state: GameStates.PlayerState = GameStates.PlayerState.EXPLORATION`), en gardant les appels globaux via `States.xxx`
3. Câbler le déclenchement du changement d'état côté `player.gd` (actuellement absent — rien n'appelle encore `request_state_change`)
4. Tester en réseau réel à 2 instances (pas encore fait cette session)

**Piège potentiel à surveiller à l'implémentation du déclencheur** : `get_node_or_null()` dans `notify_state_changed` suppose que `current_scene` est bien `Game` et que le chemin `"Players/Player-" + id` est correct — cohérent avec l'architecture actuelle (`game.tscn` : `Game` > `Players`), mais à re-vérifier si la structure de scène évolue (une scène par map, mentionnée comme prévue à terme dans `GAMEPLAY.md`).

## Session — Ennemi minimal + déclenchement du combat par détection

**Objectif de session** : câbler et valider le déclencheur d'état Exploration → Combat, en passant par un ennemi minimal (plutôt qu'un bouton UI jetable), et poser une première structure d'ordre de tour. Seul le premier volet a été traité cette session — l'ordre de tour reste à faire.

**Décisions d'architecture prises avant implémentation :**
- Ennemi répliqué via le même pattern que le joueur : `EnemiesSpawner` (`MultiplayerSpawner`, spawn path → `Enemies`) + `Enemies` (`Node3D`, sibling de `Players`), ajoutés dans `game.tscn`.
- Autorité serveur sur les ennemis (pas de notion de "propriétaire client" comme pour le joueur).
- Détection de mise en combat via une `Area3D` (`PlayerDetector`) portée par chaque ennemi (`enemy.tscn`), pas une structure de détection centralisée — cohérent avec l'architecture caméra du joueur (`SpringArm3D` embarqué).
- `CharacterBody3D` choisi comme racine de l'ennemi malgré l'absence de mouvement pour l'instant, en anticipation de la patrouille prévue dans `GAMEPLAY.md` — évite une migration de type de nœud plus tard.
- Nouvelle layer physique dédiée **Layer 3 = "Enemies"** (`project.godot`), distincte de Layer 2 = "Players", pour permettre un filtrage propre côté masks plutôt que par nom de nœud.

**Filtrage du déclenchement — deux protections combinées :**
1. Garde `if not multiplayer.is_server(): return` dans le callback `body_entered` : la détection tourne localement sur toute instance ayant l'ennemi chargé (spawné via `MultiplayerSpawner`), mais seule l'instance serveur doit agir dessus.
2. Filtrage physique par `collision_mask` plutôt que par nom de nœud : `PlayerDetector.collision_mask` ciblé sur Layer 2 (Players) uniquement → ne reçoit `body_entered` que pour des corps joueurs, filtrage fait par le moteur physique avant même l'exécution du script. `Enemy.collision_layer = 4` (Layer 3), `Enemy.collision_mask = 7` (collision physique avec décor + joueurs + autres ennemis).
3. Filtrage de type en complément dans le script (`if body is Player`), rendu possible par le `class_name Player` déjà existant — plus robuste qu'un `body.name.begins_with("Player-")`, écarté en discussion.

**Identification du joueur détecté — métadonnée plutôt que parsing répété :**

Le parsing de l'id depuis le nom du nœud (`"Player-2".split("-")[1]`) restait jusqu'ici unique à `player.gd::_enter_tree()`. Décision : en faire la source de vérité unique, et exposer le résultat via `set_meta("player_id", ...)` pour que les autres consommateurs (comme `enemy.gd`) lisent la métadonnée au lieu de reparser la chaîne. Posé côté serveur dans `network_manager.gd::add_player()` (`player.set_meta("player_id", player_id)`, avant `add_child()`), donc disponible dès l'entrée en scène sur toutes les instances via réplication.

Note de clarification actée : `get_meta`/`set_meta` ne permet de résoudre que dans le sens nœud → valeur, pas l'inverse (pas de recherche de nœud par valeur de métadonnée). Le sens id → nœud (`get_node_or_null("Players/Player-" + str(player_id))`, utilisé dans `notify_state_changed`) reste donc inchangé, structurellement différent du besoin résolu par la meta.

**Déclenchement du changement d'état — appel direct plutôt que réutilisation de `request_state_change` :**

Décision actée : puisque la détection tourne déjà exclusivement côté serveur, faire un aller-retour RPC serveur → serveur via `request_state_change` (pensé pour un déclenchement initié par un *client*, utilisant `multiplayer.get_remote_sender_id()`) n'aurait pas de sens. `enemy.gd` appelle donc directement l'émission de l'état :

```gdscript
func _on_player_detector_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	if body is Player:
		States.rpc(
			"notify_state_changed",
			body.get_meta("player_id"),
			States.PlayerState.FIGHT
		)
```

**Piège rencontré et corrigé — appel RPC mal formé :**

Premier essai : `States.notify_state_changed(...)` (accès direct par point). Ne déclenche **pas** la réplication : l'annotation `@rpc` ne prend effet que sur un appel via `rpc()`/`rpc_id()`, jamais sur un appel de méthode classique — un appel direct exécute la fonction localement (silencieusement, sans erreur), donnant l'illusion que ça fonctionne en test solo côté serveur, alors que rien n'est diffusé aux clients.

Deuxième piège, sur la correction elle-même : `rpc("États.notify_state_changed", ...)` (nom de méthode "qualifié" en chaîne) — ne fonctionne pas non plus. `rpc()` est une méthode d'instance (`Node.rpc()`) : le récepteur de l'appel RPC est déterminé par l'objet sur lequel `.rpc()` est invoqué, jamais par un chemin composé dans la chaîne de nom. Appeler `rpc(...)` sans le préfixer par `States.` l'exécute sur `self` (ici `enemy.gd`), qui n'a pas de méthode `notify_state_changed`.

Forme finale correcte : `States.rpc("notify_state_changed", player_id, new_state)` — `.rpc()` appelé explicitement sur l'objet `States` (l'autoload), avec le nom simple de la méthode en argument.

**État non testé à la fin de cette session** : les corrections ont été poussées mais pas encore validées en réseau réel à 2 instances (contact ennemi → état FIGHT répliqué côté client). À faire en priorité à la prochaine session avant de construire par-dessus.

## Session — CombatManager, socle (classe `Combat` + squelette `CombatManager`)

**Objectif de session** : poser le socle de `CombatManager` identifié dans `GAMEPLAY.md` (liste des combats actifs, participants, cycle préparation/en cours) — uniquement la structure, sans logique de déclenchement automatique depuis `enemy.gd`, sans ordre de tour, sans test réseau.

**Décision d'architecture retenue — `Combat` en classe dédiée, pas un dictionnaire :**

Un combat individuel est représenté par une classe (`class_name Combat`, `extends RefCounted`) plutôt qu'un dictionnaire brut stocké dans `CombatManager`. Raisons actées en session :
- Permet de poser des méthodes typées (`add_participant()`, `start()`...) dès maintenant, quitte à les laisser vides au départ, plutôt que de migrer plus tard comme ça a été le cas pour `states.gd`.
- `RefCounted` suffit (pas besoin de `Node`/`Node3D`) : un combat n'a pas besoin d'exister dans l'arbre de scène ni d'être répliqué comme nœud — sa diffusion se fera par RPC, même pattern que `notify_state_changed`.
- Pas de conflit `class_name`/autoload (piège #28187 documenté plus haut) : `Combat` n'est **pas** un autoload, seul `CombatManager` l'est.

**Décision actée — `participants` restreint aux joueurs (`Array[Player]`), pas de type généraliste :**

Un ennemi ne "participe" pas à un combat au même sens qu'un joueur (rejoindre/quitter en phase préparation) — il **déclenche** le combat, il n'y figure pas comme participant. `participants` reste donc typé `Array[Player]`, pas d'`Array` générique en prévision des ennemis.

**Code committé (au-delà du stub discuté en session — Julien a implémenté directement) :**

`resources/combat.gd` :
```gdscript
extends RefCounted
class_name Combat

var participants: Array[Player] = []
var phase: States.CombatState = States.CombatState.PREP

signal combat_end
signal participant_added(player: Player)

func add_participant(player: Player):
	participants.append(player)
	participant_added.emit(player)

func start():
	phase = States.CombatState.ONGOING

func end():
	phase = States.CombatState.END
	combat_end.emit()
```

`states.gd` : nouvel enum `CombatState {PREP, ONGOING, END}` ajouté à côté de `PlayerState` — le cycle préparation/en cours/fin de `Combat.phase` type sur cet enum plutôt que sur un enum local à `Combat`, cohérent avec le fait que `States` porte déjà tous les enums d'état du projet (`PlayerState`).

`combat_manager.gd` (nouvel autoload `CombatManager`) : squelette minimal pour l'instant, pas encore de méthodes.
```gdscript
extends Node

var currents: Array[Combat] = []
```

**Écart par rapport à ce qui a été discuté en session à noter pour la prochaine reprise :**
- `end()` et le signal `combat_end` n'étaient pas dans le squelette proposé en session (qui ne couvrait que `add_participant()`/`start()` en `pass`) — ajoutés directement par Julien, phase `END` incluse dans `CombatState`. À valider/discuter si besoin à la prochaine session (notamment : est-ce qu'un combat `END` reste dans `CombatManager.currents` ou en est retiré ?).
- `phase` typé sur `States.CombatState` (autoload) plutôt que sur un enum local à `Combat` comme initialement esquissé — choix cohérent, pas remis en question, juste à noter comme divergence du brouillon de session.

**Pas fait / prochaine session :**
- `combat_manager.gd` toujours sans méthodes (`currents` déclaré, rien pour créer/trouver un combat, rien pour y ajouter automatiquement un joueur détecté)
- Rien de connecté à `enemy.gd` : la détection de contact (`_on_player_detector_body_entered`) appelle toujours directement `States.rpc("notify_state_changed", ...)`, pas encore la création/récupération d'un objet `Combat` via `CombatManager`
- Question ouverte non tranchée : que devient un `Combat` une fois `end()` appelé — retiré de `currents`, ou conservé avec `phase == END` pour historique ? À trancher à l'implémentation des méthodes de `CombatManager`
- Ordre de tour toujours pas commencé — vient se greffer sur ce socle une fois `CombatManager` fonctionnel
- Rien de testé en réseau réel sur cette brique

## Session — Ennemi minimal (gravité) + rattrapage d'état à la connexion tardive

**Objectif de session** : câbler un ennemi minimal directement dans la scène (placement manuel, pas d'édition), et corriger un bug identifié en testant — un client se connectant après le début d'un combat ne voyait pas l'état FIGHT des joueurs déjà engagés.

**Ennemi minimal placé directement dans `Enemies`** : décision actée d'ajouter l'ennemi à la main dans `game.tscn` pour l'instant plutôt que via un outil — cohérent avec le mode construction non encore implémenté (voir "Idées notées pour plus tard" pour la question de persistance de niveau, mise de côté).

**Bug corrigé — gravité absente sur l'ennemi** : `CharacterBody3D` n'applique aucune physique automatiquement (contrairement à `RigidBody3D`) — la gravité doit être accumulée manuellement en `_physics_process()`, exactement comme côté joueur. `enemy.gd` avait un `_on_player_detector_body_entered()` mais pas encore de `_physics_process()`, d'où l'absence de gravité. Corrigé :
```gdscript
func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += get_gravity().y * delta
	move_and_slide()
```

**Bug identifié et corrigé — état de combat non rattrapé à la connexion tardive :**

`notify_state_changed` (broadcast RPC) diffuse un changement d'état au moment où il se produit, mais ne transmet rien à un client qui se connecte *après* ce changement — aucun mécanisme de rattrapage n'existait. Un joueur A en combat, rejoint par un joueur B après coup, laissait B avec un état obsolète (EXPLORATION) pour A.

**Décision d'architecture — RPC de rattrapage ciblé, pas de synchronizer dédié :**

Piste alternative explorée puis écartée : un second `MultiplayerSynchronizer` à autorité serveur dédié à `state` (parallèle à celui de `position`/`rotation`, qui reste autorité client). Techniquement viable, mais écartée au profit d'une solution RPC pure :
- Le `MultiplayerSynchronizer` ne fait que de la *diffusion* passive (il ne peut pas insérer de logique de validation/décision dans son flux — l'autorité décide, tout le reste observe, sans étape intermédiaire).
- Un second synchronizer par propriété "décidée côté serveur" alourdit la scène (nouveau nœud + config éditeur) à chaque nouvelle propriété du même type, alors qu'une fonction de rattrapage générique en RPC scale par simple ajout de ligne dans une boucle existante.
- Cohérence avec le pattern RPC déjà utilisé partout ailleurs dans le projet (`notify_state_changed`, `update_player_info`...).
- Pour rappel (piste explorée avec Gemini) : une correction *bidirectionnelle* via synchronizer nécessiterait un split en deux propriétés/synchronizers (un par sens de flux, ex. `client_requested_X` autorité client + `validated_X` autorité serveur) — solution viable mais réservée aux propriétés à haute fréquence de changement (ex. position, si l'anti-triche est un jour rouvert), pas justifiée pour une propriété événementielle comme `state`.

**Implémentation retenue (`states.gd`)** :
```gdscript
func _ready() -> void:
	NetworkManager.client_connected.connect(get_states)

func get_states(client_id: int):
	var players = get_tree().current_scene.get_node("Players").get_children()
	for player in players:
		rpc_id(
			client_id,
			"notify_state_changed",
			player.get_meta("player_id"), player.state
		)
```
Réutilise `notify_state_changed` tel quel (juste ciblé via `rpc_id` au lieu du broadcast habituel), aucune nouvelle structure de message.

**Point de déclenchement — nouveau signal `NetworkManager.client_connected`** : émis dans `update_player_info()` (côté serveur), juste après `add_player()` — le moment où le serveur connaît l'id du nouveau client et vient de l'ajouter à `Players`. Écouté directement par `States` dans son propre `_ready()`, sans passer par `SceneManager` (pas de notion de scène/navigation ici, juste "un joueur est prêt réseau") — cohérent avec la séparation stricte réseau/navigation déjà en place, tout en gardant `network_manager.gd` ignorant de l'existence de `States`.

**Risque de timing identifié mais non problématique en pratique** : `get_states()` suppose que le nouveau client a déjà reçu la réplication des nœuds `Player` existants (via `MultiplayerSpawner`) au moment où le RPC de rattrapage arrive — sinon `get_node_or_null()` échouerait silencieusement côté client. Le mot de passe étant déjà validé à ce stade (connexion établie depuis un moment), la réplication a normalement eu le temps de se faire. **Validé en test réel ✅** — aucun souci observé.

**Piste anti-triche évoquée puis explicitement écartée pour l'instant** : la question de valider `position`/`rotation` côté serveur (empêcher un client de tricher sur sa vitesse de déplacement) a été soulevée en session. Décision actée : **pas de validation pour l'instant**, jeu coopératif entre amis, non compétitif — priorité à la simplicité. Le pattern RPC actuel (`request_state_change`/mouvement autorité client) permet d'insérer une validation ultérieure sans changement de protocole si le besoin apparaît un jour (ex. jeu ouvert au public). Piège technique noté au passage : une tentative de correction de position basée sur un setter de propriété synchronisée avec autorité **client** ne fonctionne pas — le synchronizer ne réplique que dans le sens de l'autorité, une correction serveur assignée localement dans ce cas ne serait jamais renvoyée au client.

## Session — Ordre de tour, socle (`Combatant`, `CombatManager.handle_contact`, `Combat.start()`)

**Objectif de session** : poser le premier incrément de l'ordre de tour (report deux fois consécutif), en clarifiant au passage le déclenchement du combat depuis la détection ennemi. Découplage volontaire de l'initiative et du futur système d'équipement (discussion de design approfondie en amont, voir `GAMEPLAY.md` § Système élémentaire / Progression) : initiative posée comme un `int` plat + bruit aléatoire pour tester le tri, sans lien avec une affinité élémentaire pour l'instant.

**Décision d'architecture retenue — classe `Combatant` (héritage), pas de duck typing ni composition :**

`Player` et `Enemy` héritent désormais tous les deux de `Combatant` (`extends CharacterBody3D`, `class_name Combatant`), qui porte les stats de combat partagées :
```gdscript
# scenes/combatant.gd
extends CharacterBody3D
class_name Combatant

var initiative: int = 0
var current_combat: Combat = null

func _ready() -> void:
	initiative = randi_range(0, 10)
```
- Alternatives écartées en discussion : duck typing (`has_method`) — perd la sécurité de typage statique déjà pratiquée ailleurs dans le projet (`class_name Player`, filtrage `body is Player`) ; composition via un nœud/ressource `CombatantStats` séparé — ajoute une indirection non justifiée puisque `Player`/`Enemy` partagent déjà le même parent `CharacterBody3D`.
- Pas de conflit avec le piège `class_name`/autoload (#28187, documenté plus haut) : `Combatant` n'est pas un autoload, seul `StateManager` (ex-`States`, renommé cette session) l'est.
- `Combatant` reste volontairement un simple porteur de stats de combat (`initiative`, `current_combat`) — pas de mutualisation de la physique/gravité, qui diverge déjà entre `Player` (bloqué par `is_multiplayer_authority()`) et `Enemy` (pas de notion d'autorité client).

**Piège rencontré et corrigé — `_ready()` écrasé silencieusement par l'héritage :**

GDScript n'appelle jamais automatiquement la méthode du parent quand une classe fille redéfinit la même fonction. `player.gd` avait déjà son propre `_ready()` (caméra, capture souris) — en héritant de `Combatant`, ce `_ready()` remplaçait entièrement celui de `Combatant`, empêchant `initiative` d'être randomisée côté joueur, sans erreur ni avertissement. Corrigé par un appel explicite `super()` en première ligne des `_ready()` de `player.gd` et `enemy.gd`.

**Renommage `states.gd` → `state_manager.gd` (autoload `States` → `StateManager`) :**

Renommage assumé cette session, cohérent avec le rôle grandissant de cet autoload (transitions d'état + maintenant appelé directement depuis `CombatManager`). Effectué de façon cohérente dans tous les points d'appel (`state_manager.gd` lui-même, `player.gd`, `combat_manager.gd`, `resources/combat.gd`).

**`Combat` — `participants`/`enemies` fusionnés en un seul `turn_order: Array[Combatant]` :**

Décision actée en discussion : plutôt que deux tableaux séparés (`participants: Array[Player]` + un nouveau tableau ennemis), un seul tableau `turn_order: Array[Combatant]`, alimenté par deux méthodes d'ajout **typées séparément** pour garder la sécurité de typage à l'écriture :
```gdscript
# resources/combat.gd
extends RefCounted
class_name Combat

var turn_order: Array[Combatant] = []
var phase: StateManager.CombatState = StateManager.CombatState.PREP

signal combat_end
signal participant_added(player: Player)
signal enemy_added(enemy: Enemy)

func add_participant(player: Player):
	turn_order.append(player)
	participant_added.emit(player)
	player.current_combat = self

func add_enemy(enemy: Enemy):
	turn_order.append(enemy)
	enemy_added.emit(enemy)
	enemy.current_combat = self

func start():
	turn_order.sort_custom(
		func(a: Combatant, b: Combatant):
			return a.initiative > b.initiative
	)
	for combatant in turn_order:
		print_debug("Initiative: ", combatant.name, " -> ", combatant.initiative)
	phase = StateManager.CombatState.ONGOING

func end():
	phase = StateManager.CombatState.END
	combat_end.emit()
```
- `add_participant()`/`add_enemy()` assignent chacun `current_combat = self` sur le `Combatant` ajouté — c'est le point unique où cette référence est posée (pas dans `CombatManager`), donc garanti cohérent quel que soit l'appelant.
- Tri par `Array.sort_custom()` avec fonction de comparaison inline, décroissant (`>`) — plus haute initiative en premier, cohérent avec la référence Dofus/Dota discutée en amont.
- `print_debug()` de vérification laissé en place pour le test manuel de cette session — à retirer ou remplacer par un vrai affichage UI quand le tour par tour aura une interface.

**`CombatManager` — `handle_contact()` implémentée (trouver/créer un combat, déclenchement d'état FIGHT) :**

```gdscript
# combat_manager.gd
extends Node

var currents: Array[Combat] = []

func handle_contact(player: Player, enemy: Enemy):
	# Player can't join 2 combats
	if player.current_combat:
		return
	
	if enemy.current_combat:
		if enemy.current_combat.phase != StateManager.CombatState.PREP:
			return
		enemy.current_combat.add_participant(player)
	else:
		var combat = Combat.new()
		combat.add_enemy(enemy)
		combat.add_participant(player)
		currents.append(combat)
		_start_combat_timer(combat)
	
	StateManager.rpc(
		"notify_state_changed",
		player.get_meta("player_id"),
		StateManager.PlayerState.FIGHT
	)

func _start_combat_timer(combat: Combat):
	await get_tree().create_timer(5.0).timeout
	if combat.phase == StateManager.CombatState.PREP:
		combat.start()
```

- **`currents` conservé** (question ouverte en session précédente, tranchée cette session) : usage prévu — affichage debug/liste des combats en cours, et surtout permettre à un joueur de choisir de terminer son action avant de rejoindre un combat en préparation parmi plusieurs actifs simultanément (cohérent avec GAMEPLAY.md : "plusieurs combats simultanés possibles dans la même instance").
- **Piège de divergence rencontré et corrigé en cours de session** : une première version laissait `StateManager.rpc(..., FIGHT)` inconditionnel en fin de fonction, alors que le chemin "rejoindre un combat déjà `ONGOING`" ne fait plus rien (aucun ajout) — un joueur croisant un ennemi déjà engagé ailleurs se serait retrouvé basculé en état `FIGHT` sans figurer dans aucun `Combat`. Corrigé par un `return` anticipé dans la branche `phase != PREP`, garantissant que tout chemin atteignant le RPC final est passé par un ajout réel — cohérent avec le style déjà utilisé pour le garde `player.current_combat`.
- **Timer de démarrage** : `get_tree().create_timer()` (timer "one-shot" du `SceneTree`, pas de nœud `Timer` dédié) awaité dans une fonction async de l'autoload `CombatManager` — sûr vis-à-vis du piège d'`await`/coroutine orpheline déjà documenté plus haut (l'autoload ne sera jamais déchargé pendant une partie en cours, contrairement à une scène remplacée). Le garde `if combat.phase == PREP` avant d'appeler `start()` est nécessaire pour éviter un double déclenchement si un futur bouton "go" UI a déjà démarré le combat avant l'expiration du timer. Durée de test actuelle : 5 secondes, à ajuster/remplacer par le bouton "go" dans une session future.
- Alternative écartée pour le timer : nœud `Timer` réel enfant de `CombatManager` (un par combat) — permettrait pause/annulation propre, mais non justifié tant qu'aucun mécanisme de sortie de combat autre que `start()`/`end()` n'existe.

**`enemy.gd` mis à jour :**
```gdscript
extends Combatant
class_name Enemy

func _ready() -> void:
	super()

func _on_player_detector_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	
	CombatManager.handle_contact(body as Player, self)

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y += get_gravity().y * delta
	
	move_and_slide()
```

**⚠️ Point de vigilance non résolu, repéré en fin de session** : le filtrage `if body is Player` (présent dans une session précédente pour ne réagir qu'à un vrai joueur détecté par `PlayerDetector`) a disparu au profit d'un cast direct `body as Player`. Sans risque tant que `PlayerDetector.collision_mask` reste restreint à Layer 2 (Players) — mais si un autre type de corps entre un jour dans la zone, le cast renverrait `null` silencieusement, et `handle_contact()` recevrait un `player` nul sans erreur explicite. À surveiller si de nouveaux types de corps interagissent avec `PlayerDetector` à l'avenir ; pas bloquant aujourd'hui.

**Testé cette session** : test solo (pas encore réseau réel à 2 instances) — contact joueur/ennemi déclenche bien la création du `Combat`, l'ajout à `currents`, le timer, et le passage en état `FIGHT`. Tri de `turn_order` vérifié via `print_debug()`.

**Pas fait / prochaine session** :
- Test réseau réel à 2 instances sur toute cette chaîne (pas encore fait cette session, contrairement à d'autres briques déjà validées en réseau)
- Bouton UI "go" pour démarrer le combat avant expiration du timer (le timer seul suffit pour tester, mais le bouton reste à faire)
- Edge case du second ennemi déjà engagé dans un combat `ONGOING` distinct : actuellement le contact est simplement ignoré (`return` anticipé) plutôt que traité explicitement — comportement correct par accident plutôt que par conception explicite, à repasser en revue si un jour deux ennemis peuvent interagir avec le même joueur en combats séparés
- Déplacement borné par tour, IA basique, arme neutre placeholder — reste du périmètre "systèmes de combat communs" (priorité 1 de `GAMEPLAY.md`)
- `print_debug()` dans `Combat.start()` à remplacer par un vrai affichage une fois une UI de combat posée

## Session — Progression de tour (`next_turn`, RPC, timer par tour) ✅ testé en réseau réel

**Objectif de session** : faire vivre la progression de tour au-delà du tri initial (`Combat.start()`), avec deux déclencheurs (fin de tour manuelle côté client, timer côté serveur), et diffuser le résultat aux clients.

**`Combat` — ajouts** (`resources/combat.gd`) :
```gdscript
var id: int
var current_turn_index: int = 0
signal turn_changed(combatant: Combatant)

func get_current_combatant() -> Combatant:
	return turn_order[current_turn_index]

func next_turn() -> void:
	current_turn_index = (current_turn_index + 1) % turn_order.size()
	turn_changed.emit(get_current_combatant())
```
- `id` : compteur incrémenté par `CombatManager` à la création (`_next_combat_id`), nécessaire car `currents` seul (position dans le tableau) est fragile si un combat est retiré après `end()`.
- `turn_changed` suit le même principe que `combat_end`/`participant_added`/`enemy_added` déjà existants sur `Combat` : centralise la réaction à un `next_turn()` (broadcast + relance du timer) en un seul endroit, plutôt que de dupliquer ces deux actions à chaque site d'appel (`request_end_turn` et le timer appellent tous deux `next_turn()`).

**`CombatManager` — RPC de fin de tour, garde double autorisation :**
```gdscript
@rpc("any_peer")
func request_end_turn(combat_id: int):
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	var combat := _find_combat(combat_id)
	if combat == null:
		return
	if combat.get_current_combatant().get_meta("player_id") != sender_id:
		return
	combat.next_turn()
```
- **Deux couches de protection, pas une** : le mode `"any_peer"` + `call_remote` (par défaut) garantit qu'un appel `rpc_id(1, ...)` depuis un client ne s'exécute jamais localement chez l'appelant. Le garde `is_server()` protège contre un appel direct (non-RPC) ou un `rpc_id` mal ciblé vers un autre client — `is_server()` vérifie la machine locale qui exécute, pas l'émetteur. `get_remote_sender_id()` est ensuite infalsifiable (posé par la couche réseau ENet à la réception, pas par le payload envoyé) : un client ne peut pas usurper le `player_id` d'un autre joueur pour finir son tour à sa place.
- Alternative `@rpc("authority")` évoquée puis écartée : elle contraint qui peut **recevoir** l'appel (l'autorité du nœud, ici le serveur par défaut), pas qui peut **envoyer** — ici n'importe quel client légitime doit pouvoir envoyer, donc `"any_peer"` + vérification manuelle exprime plus précisément l'intention réelle que `"authority"` seul.

**Diffusion — `notify_turn_changed` vit dans `CombatManager`, pas `StateManager` :**

Erreur de conception intermédiaire corrigée en session : un premier essai avait placé `notify_turn_changed` sur `StateManager` par réflexe (pattern déjà vu avec `notify_state_changed`), mais `StateManager` porte les transitions d'état joueur (préoccupation transverse), pas la logique de tour (préoccupation propre au combat, dont `CombatManager` est déjà le point d'entrée unique). Corrigé :

```gdscript
@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	pass  # côté client : mise à jour UI/curseur de tour

func _on_turn_changed(combatant: Combatant, combat: Combat):
	rpc("notify_turn_changed", combat.id, combatant.get_path())
	_start_turn_timer(combat)
```
- Diffusion en **broadcast**, choix assumé (pas de ciblage aux seuls participants) : le projet ne dépassera jamais ~10 joueurs simultanés (LAN/hébergé par un joueur), donc le coût réseau du broadcast est non pertinent ici — et ça garde la porte ouverte à un futur mode spectateur/suivi de combat sans migration.
- `combatant_path` (`NodePath` via `get_path()`) plutôt qu'un id numérique unifié : couvre `Player` et `Enemy` de façon uniforme sans bricoler un id partagé entre deux types différents.

**Timer par tour — `CombatManager`, avec jeton anti-double-déclenchement :**

`Combat` étant un `RefCounted` (pas de `get_tree()` disponible), le timer ne peut vivre que dans `CombatManager` (autoload, `Node`) — même contrainte que pour `_start_combat_timer()` déjà existant.

```gdscript
func _start_turn_timer(combat: Combat):
	var turn_snapshot := combat.current_turn_index
	await get_tree().create_timer(30.0).timeout
	if combat.current_turn_index == turn_snapshot:
		combat.next_turn()
```
- `turn_snapshot` capturé avant l'attente sert de jeton : si le tour a déjà changé entre-temps (fin de tour manuelle via `request_end_turn` avant expiration du timer), ce timer devenu obsolète ne fait rien à son réveil — évite un double `next_turn()`.
- Le timer se relance à chaque tour via `_on_turn_changed` (branché sur le signal `turn_changed`), qu'il vienne du timer lui-même ou de `request_end_turn` — un seul point de relance, pas dupliqué à chaque site d'appel de `next_turn()`.

**Bug rencontré et corrigé en session — signature `_on_turn_changed` incomplète :**

`Node(combat_manager.gd)::_on_turn_changed`: Method expected 1 argument(s), but called with 2. Cause : la connexion utilise `.bind(combat)`, donc Godot appelle toujours le callback avec l'argument du signal (`combatant`, ordre du signal) **suivi** de l'argument bindé (`combat`) — la signature doit déclarer les deux, dans cet ordre :
```gdscript
func _on_turn_changed(combatant: Combatant, combat: Combat):
```

**Testé cette session** : validé en réseau réel (2 instances) — fin de tour manuelle et timer déclenchent bien `next_turn()`, diffusion `notify_turn_changed` reçue côté client, pas de double-déclenchement observé entre les deux chemins.

**Pas fait / prochaine session** :
- `notify_turn_changed` côté client ne fait encore rien (`pass`) — pas d'UI/curseur de tour affiché, juste le RPC qui arrive
- Déplacement borné par tour (reste du bloc "systèmes de combat communs", priorité 1 de `GAMEPLAY.md`)
- Durée du timer de tour (30s) à ajuster/valider par le ressenti de jeu, valeur de test pour l'instant
- IA basique, arme neutre placeholder — toujours pas commencés

## Session — Déplacement borné par tour (cercle de mouvement) ✅ testé en local

**Objectif de session** : implémenter le premier point du bloc "systèmes de combat communs" (`GAMEPLAY.md` § Combat) — déplacement libre borné par tour. Modèle retenu après discussion : un **cercle de déplacement** (pas un odomètre cumulatif) — le joueur se déplace librement tant qu'il reste dans un rayon donné autour d'un centre, plutôt que de consommer un budget à chaque mètre parcouru.

**Décision de conception actée en amont — autorité du mouvement (approche C)** : parmi trois approches comparées (serveur pleinement autoritaire en permanence / bascule d'autorité selon l'état / client autoritaire + validation-snap serveur), **l'approche C est retenue** : le mouvement reste autoritaire côté client comme aujourd'hui (aucun changement du pattern existant), le serveur validera et *snappera* seulement si nécessaire — objectif : parer un client local qui triche sur le rayon max, pas une architecture de mouvement entièrement revue. **Pas encore implémenté** — seul le clamp côté client est en place à ce stade (voir plus bas). Prochaine étape naturelle de cette feature.

**Champs ajoutés sur `Combatant`** (`scenes/combatant.gd`) — stat de combat partagée Player/Enemy, cohérent avec `initiative` :
```gdscript
var move_center: Vector3
var move_radius: float
var move_max_distance: float = 5.0

func _ready() -> void:
	initiative = randi_range(0, 10)
	reset_move()

func reset_move():
	move_center = global_position
	move_radius = move_max_distance
```
- `reset_move()` posé **génériquement** sur `Combatant` (pas restreint à `Player`) — choix assumé : la donnée est inoffensive sur un `Enemy` (pas encore consommée par une IA de déplacement), et garder `Combatant` comme point d'écriture unique évite une divergence de traitement entre les deux sous-classes plus tard.

**Reset du cercle au changement de tour — branché sur `notify_turn_changed` existant, pas un nouveau listener :**

Le point de blocage rencontré en session : chercher un nouveau point d'accroche (`.connect()` dédié) alors que `notify_turn_changed` (`combat_manager.gd`, RPC `@rpc("authority", "call_local")`) est déjà le point d'arrivée unique de "le tour a changé", sur toute machine, à chaque tour :
```gdscript
@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	combatant.reset_move()
```
- Reset appliqué **sans filtrage** "est-ce que c'est moi" — appelé pour toute instance répliquée du combattant concerné, y compris chez les autres joueurs qui voient une instance distante de ce combattant. Sans danger : ces champs ne sont lus que par le code de mouvement (`player.gd::_physics_process`), déjà gardé par `is_multiplayer_authority()`. Écrire ces valeurs sur une instance distante n'a aucun effet, ce code ne s'exécute jamais pour elle localement.

**Gating "c'est mon tour" — `is_my_turn()` sur `player.gd` :**
```gdscript
func is_my_turn() -> bool:
	if not current_combat:
		return true
	return (
		current_combat.phase == StateManager.CombatState.ONGOING
		and current_combat.get_current_combatant() == self
	)
```
**⚠️ Point de vigilance non résolu, à confirmer** : cette fonction renvoie `false` dès qu'un `current_combat` existe et que sa `phase` n'est pas `ONGOING` — donc **le mouvement est bloqué dès le contact avec un ennemi**, y compris pendant `PREP` (avant l'expiration du timer de démarrage / avant que tout le monde ait rejoint). L'hypothèse de travail discutée en session précédant l'implémentation était plutôt : en `PREP`, tout le monde reste libre de bouger comme en exploration, seul `ONGOING` doit brider le hors-tour. Comportement actuel non confirmé comme voulu — à trancher/valider avant de considérer cette brique complètement close.

**Clamp de mouvement — `player.gd::_physics_process`, avant `move_and_slide()` :**
```gdscript
# Limit if in combat
if current_combat:
	var next_pos := global_position + Vector3(velocity.x, 0, velocity.z) * delta
	var next_pos_flat := Vector2(next_pos.x, next_pos.z)
	var center_flat := Vector2(move_center.x, move_center.z)
	
	if next_pos_flat.distance_to(center_flat) > move_radius:
		var outward := (next_pos_flat - center_flat).normalized()
		var flat_velocity := Vector2(velocity.x, velocity.z)
		flat_velocity = flat_velocity.slide(outward)
		velocity.x = flat_velocity.x
		velocity.z = flat_velocity.y
```
- **Distance calculée en 2D (`X`/`Z`), `Y` volontairement exclu** : décision prise en anticipation du futur anneau visuel au sol (mesh/decal plat) — la contrainte doit raisonner dans le même plan que ce que le joueur verra affiché, sinon sauter ou descendre une pente ferait ressentir une limite incohérente avec l'anneau affiché. Piège de nommage à surveiller en cas de réutilisation de ce pattern : `Vector2` n'a que `.x`/`.y` — remonter vers `velocity.z` nécessite de lire `flat_velocity.y`, pas `.z`.
- **Glissement (`Vector2.slide()`) choisi plutôt que blocage net** : le joueur longe le bord du cercle au lieu d'être stoppé net au premier contact — ressenti plus agréable, validé en test.
- **Placement avant `move_and_slide()`, sur `velocity`, pas de correction de `global_position` après coup** : nécessaire pour rester cohérent avec la gestion des collisions physiques déjà faite en interne par `move_and_slide()` (murs, autres joueurs) — une correction de position a posteriori court-circuiterait ce que `move_and_slide()` vient de faire et pourrait traverser un obstacle évité entre-temps.

**Idée notée hors scope — ressource élémentaire en début de tour** (évoquée par Julien en discutant du budget de déplacement, à ne pas perdre) : possibilité de récupérer un ou plusieurs éléments en début de tour en étant suffisamment proche d'un émetteur. Non lié au déplacement borné en lui-même — à rattacher à une session sur le système élémentaire/équipement. Voir aussi `GAMEPLAY.md` § Idées notées hors scope.

**Renommages/évolutions constatés sur `Combat` depuis la dernière session documentée** (`resources/combat.gd`), non discutés en session mais actés par lecture du code committé :
- `id` → `combat_id`, `current_turn_index` → `current_turn` (initialisé à `-1`)
- `start()` appelle désormais `next_turn()` immédiatement après le tri — résout l'ambiguïté notée précédemment ("`current_turn_index` reste à 0 par défaut, pas encore significatif en `PREP`") : `get_current_combatant()` est valide dès le passage en `ONGOING`, plus de valeur par défaut arbitraire à ce moment-là.
- `CombatManager.currents` : `Array[Combat]` → `Dictionary[int, Combat]` (clé = `combat_id`) — résout la fragilité notée précédemment ("`id` nécessaire car position dans le tableau fragile si un combat est retiré après `end()`"), accès direct par id plutôt que recherche linéaire.
- Durée du timer de tour (`_start_turn_timer`) : `30.0` → `5.0` — valeur de test resserrée pour itérer plus vite en session, à ajuster/valider par le ressenti de jeu comme déjà noté précédemment.

**Testé cette session** : en local (solo, pas encore réseau réel à 2 instances) — entrée en combat, blocage du mouvement hors tour, glissement le long du bord du cercle pendant son tour, reset du cercle constaté au tour suivant.

**Pas fait / prochaine session :**
- **Validation/snap serveur (approche C actée)** — le clamp actuel n'est que côté client, aucune vérification serveur ne l'accompagne encore. Prochaine étape naturelle de cette feature.
- Clarifier/trancher le point de vigilance `is_my_turn()`/phase `PREP` ci-dessus
- Test réseau réel à 2 instances sur le cercle de déplacement (fait seulement en local pour l'instant)
- Anneau visuel au sol (mesh/decal suivant `move_center`/`move_radius`) — explicitement repoussé à plus tard en session, découplé du clamp par design
- Recentrage du cercle après une action (dépend d'un système d'action pas encore implémenté) — comportement voulu : après une action, un nouveau cercle avec pour rayon le déplacement restant, centré sur la position au moment de l'action
- IA basique, arme neutre placeholder — toujours pas commencés

## Idées notées hors scope (ajoutées cette session)

- **Aggro en chaîne** (voir `GAMEPLAY.md` § Combat) : attaquer un ennemi peut alerter un ennemi proche, potentiellement en chaîne — caractéristique possible par type d'ennemi. Non implémenté, noté pour une session dédiée à l'IA ennemie.

## Prochaines étapes

1. **Déplacement borné par tour — validation serveur (approche C)** : le cercle de déplacement (client) est implémenté et testé en local — reste à poser la validation/snap côté serveur (le client reste autoritaire, le serveur corrige si le rayon max est dépassé). Priorité de la prochaine session, avant de considérer ce point de `GAMEPLAY.md` § Combat comme clos.
2. **Validation croisée test/prod** : la scène de test (`tests/test.tscn`) ne couvre que le rôle serveur pour l'instant (`skip_scene_loading = true` + `create_server()` direct) — **usage volontaire et assumé**, pas une lacune : `tests/test.tscn` sert au test local (rôle serveur uniquement), le menu principal reste le chemin normal pour tester le mode connecté (client + serveur). Point clarifié il y a deux sessions, ne plus le rouvrir comme "manque".
3. Étoffer `tests/test.tscn` au fil des prochaines features (combat, particules) plutôt que de créer une nouvelle scène de test à chaque fois.
4. **Fondations réseau du prototype considérées closes** (mouvement, caméra 3ᵉ personne + tangage, autorité réseau, gestion d'erreur de connexion, nettoyage des déconnexions, state machine par joueur + rattrapage à la connexion — tous validés en réseau réel). Prochaine session : bascule vers du contenu de jeu (ordre de tour en premier) plutôt que de nouvelles briques réseau, sauf bug bloquant découvert en cours de route.

## Idées notées pour plus tard (hors scope immédiat)

- Mode "construction" in-game (remplaçant potentiel de l'éditeur de niveaux abandonné) : à explorer dans une session dédiée à l'architecture combat/exploration.
- Exploration et combat prévus dans la **même scène/niveau**, avec état partagé (ex. un feu allumé en exploration doit être utilisable en combat) — pas de `change_scene_to_file()` entre les deux modes, plutôt une machine à états sur place. Question ouverte : à trancher dans une session dédiée à l'architecture du système de combat.
- **Persistance des niveaux (chargement/sauvegarde)** : question soulevée en plaçant un ennemi manuellement dans `Enemies` — à terme, avec le mode construction, il faudra un mécanisme pour charger/sauvegarder le contenu d'un niveau édité (géométrie, ennemis, zones de patrouille). Deux pistes identifiées à comparer le moment venu : (a) niveau = scène Godot (`PackedScene` + `ResourceSaver`, idiomatique, profite de l'outillage natif), (b) niveau = données pures (`Resource` custom ou JSON, instancié au runtime, plus de contrôle/flexibilité mais réimplémente une partie de la sérialisation native). À trancher dans la session dédiée au mode construction, pas avant.
- **Validation serveur de la position/du mouvement (anti-triche)** : explicitement mise de côté (voir session ci-dessus) — jeu coopératif entre amis, pas de priorité. À reconsidérer seulement si le jeu s'ouvre un jour à un public non-coopératif/non-amis. Le pattern RPC actuel permet d'ajouter cette validation plus tard sans changement de protocole.

## Décisions d'architecture (rappel)

- Pattern authoritative pour le réseau (validation serveur), sauf mouvement joueur (autorité client assumée, choix définitif pour un jeu coopératif entre amis — pas un TODO, voir "Idées notées pour plus tard")
- Séparation stricte réseau (`network_manager.gd`) / navigation (`scene_manager.gd`) : le réseau ne connaît aucune scène, la navigation ne connaît aucun détail réseau interne. `States` suit le même principe : écoute les signaux réseau directement, `network_manager.gd` reste ignorant du contenu du jeu.
- Éditeur de niveaux intégré : abandonné (trop de complexité pour un projet solo) — mode "construction" in-game envisagé comme alternative future
- Renderer Compatibility (OpenGL 3.3 / ES 3.0) pour accessibilité max + export WebGL
- Rattrapage d'état pour les connexions tardives : RPC ciblé (`rpc_id`) plutôt que `MultiplayerSynchronizer` dédié, pour toute propriété événementielle décidée côté serveur (voir session ci-dessus pour le raisonnement complet)
