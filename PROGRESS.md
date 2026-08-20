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

## Prochaines étapes

1. **Tester en réseau réel à 2 instances** le flux complet détection ennemi → `States.rpc("notify_state_changed", ...)` → état répliqué côté client — pas encore fait, priorité avant toute nouvelle feature de combat.
2. **Point resté en suspens (rappel, non résolu)** : `states.gd` n'a toujours pas de `class_name` dédié (ex. `class_name GameStates`), alors que le risque de résolution de type instable (hash auto-généré) reste documenté depuis la session précédente. Pas encore rouvert cette session — à trancher avant que le typage des états devienne central à davantage d'endroits.
3. **Première structure de l'ordre de tour** (déplacée de cette session, pas commencée) : ordre des joueurs/ennemis, déplacement borné par tour — premier bloc de `GAMEPLAY.md` § Combat.
4. **Validation croisée test/prod** : la scène de test (`tests/test.tscn`) ne couvre que le rôle serveur pour l'instant (`skip_scene_loading = true` + `create_server()` direct) — **usage volontaire et assumé**, pas une lacune : `tests/test.tscn` sert au test local (rôle serveur uniquement), le menu principal reste le chemin normal pour tester le mode connecté (client + serveur). Point clarifié cette session, ne plus le rouvrir comme "manque".
2. Étoffer `tests/test.tscn` au fil des prochaines features (combat, particules) plutôt que de créer une nouvelle scène de test à chaque fois.
3. **Fondations réseau du prototype considérées closes** après cette session (mouvement, caméra 3ᵉ personne + tangage, autorité réseau, gestion d'erreur de connexion, nettoyage des déconnexions — tous validés en réseau réel à 2 instances). Prochaine session : bascule vers du contenu de jeu (combat, particules élémentaires, ou premier système de gameplay) plutôt que de nouvelles briques réseau, sauf bug bloquant découvert en cours de route.

## Idées notées pour plus tard (hors scope immédiat)

- Mode "construction" in-game (remplaçant potentiel de l'éditeur de niveaux abandonné) : à explorer dans une session dédiée à l'architecture combat/exploration.
- Exploration et combat prévus dans la **même scène/niveau**, avec état partagé (ex. un feu allumé en exploration doit être utilisable en combat) — pas de `change_scene_to_file()` entre les deux modes, plutôt une machine à états sur place. Question ouverte : à trancher dans une session dédiée à l'architecture du système de combat.

## Décisions d'architecture (rappel)

- Pattern authoritative pour le réseau (validation serveur), sauf mouvement joueur (autorité client assumée pour l'instant, validation serveur en TODO)
- Séparation stricte réseau (`network_manager.gd`) / navigation (`scene_manager.gd`) : le réseau ne connaît aucune scène, la navigation ne connaît aucun détail réseau interne
- Éditeur de niveaux intégré : abandonné (trop de complexité pour un projet solo) — mode "construction" in-game envisagé comme alternative future
- Renderer Compatibility (OpenGL 3.3 / ES 3.0) pour accessibilité max + export WebGL
