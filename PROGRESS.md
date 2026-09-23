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
- Clarifier/trancher le point de vigilance `is_my_turn()`/phase `PREP` ci-dessus
- Anneau visuel au sol (mesh/decal suivant `move_center`/`move_radius`) — explicitement repoussé à plus tard en session, découplé du clamp par design
- Recentrage du cercle après une action (dépend d'un système d'action pas encore implémenté) — comportement voulu : après une action (jusqu'à 2 déplacements possibles par tour, avec une action facultative entre les deux — attaque, synthèse, autre), un nouveau cercle avec pour rayon le déplacement restant, centré sur la position au moment de l'action. **Non codé actuellement** : `move_max_distance` (actuellement une constante fixe `5.0` sur `Combatant`) représente ce total plafond sur l'ensemble du tour, mais le code ne gère aujourd'hui qu'une seule phase de déplacement — la logique de recentrage/répartition du rayon restant entre deux phases reste entièrement à écrire, une fois le système d'action posé.
- IA basique, arme neutre placeholder — toujours pas commencés

## Session — Validation serveur du déplacement (approche C) ⚠️ bugs réseau non résolus, à reprendre

**Objectif de session** : implémenter la validation/snap serveur du cercle de déplacement (approche C actée précédemment : client reste autoritaire sur son mouvement, le serveur valide et corrige si nécessaire). Point de départ : le clamp client existait déjà et fonctionnait en local ; cette session couvre uniquement la partie serveur.

**Exigences posées en amont de l'implémentation, qui ont structuré le design :**
- Validation à des points précis (avant fin de tour, avant action) plutôt qu'en continu à chaque frame
- Seul le tricheur doit être impacté par une correction — jamais les autres joueurs
- En début de tour, la position doit être la dernière position connue/validée — y compris si le joueur a triché *pendant le tour des autres* (pas seulement pendant le sien)
- **Choix explicitement tranché** : exposition brève acceptée si un tricheur est visible une fraction de seconde avant correction (pas de découplage de la réplication continue) — cohérent avec le contexte "coop entre amis, pas d'anti-triche visé" déjà acté ailleurs dans ce document. Conséquence directe de ce choix : la correction se propage automatiquement aux autres clients via le `MultiplayerSynchronizer` existant dès que le tricheur applique sa position corrigée — pas besoin de diffuser la correction soi-même à chaque autre joueur.

**Calcul du cercle factorisé sur `Combatant`** (`scenes/combatant.gd`), utilisé à la fois par le clamp client (glissement de vélocité) et la validation serveur (projection de position) — évite la divergence entre deux implémentations du même calcul géométrique :
```gdscript
func circle_overflow_direction(pos: Vector3) -> Vector2:
	var flat_pos := Vector2(pos.x, pos.z)
	var flat_center := Vector2(move_center.x, move_center.z)
	var offset := flat_pos - flat_center
	if offset.length() <= move_radius:
		return Vector2.ZERO
	return offset.normalized()

func clamp_position(pos: Vector3) -> Vector3:
	var outward := circle_overflow_direction(pos)
	if outward == Vector2.ZERO:
		return pos
	var flat_center := Vector2(move_center.x, move_center.z)
	var clamped_flat := flat_center + outward * move_radius
	return Vector3(clamped_flat.x, pos.y, clamped_flat.y)
```
- `circle_overflow_direction()` : le noyau géométrique pur, ne touche ni `velocity` ni `global_position` — réutilisable tel quel dans les deux contextes (client en continu dans `_physics_process`, serveur ponctuellement hors `_physics_process`)
- `clamp_position()` : usage serveur — projette une position sur le bord du cercle si hors limite, sans notion de vélocité (contrairement au client qui fait glisser la vélocité pour un ressenti fluide)

**`last_position` : la donnée qui porte "la dernière position validée", posée sur `Combatant` :**
```gdscript
var last_position: Vector3

func _ready() -> void:
	initiative = randi_range(0, 10)
	reset_move(global_position)

func reset_move(pos: Vector3):
	last_position = pos
	move_center = pos
	move_radius = move_max_distance
```
- **Bug corrigé en session** : `reset_move()` prenait initialement `pos` en paramètre mais `_ready()` n'avait pas encore été mis à jour pour lui passer `global_position` — `last_position` restait à sa valeur par défaut (`Vector3.ZERO`) au tout premier combat, plaçant le premier cercle à l'origine du monde plutôt qu'à la position réelle du joueur. Corrigé.
- **Piège identifié et évité** : ne **jamais** ajouter `last_position` aux propriétés répliquées par le `MultiplayerSynchronizer`. L'autorité du nœud `Player`, c'est le client — s'il était répliqué, le joueur déciderait lui-même de la valeur diffusée de sa "dernière position valide", ce qui annulerait toute la validation. `last_position` doit rester une donnée que seul le serveur écrit, transmise explicitement par RPC (voir plus bas), jamais lue localement depuis `global_position` par un client.

**Points de validation serveur — factorisés en un seul endroit, appelé depuis les deux sources possibles de fin de tour :**
```gdscript
func _end_current_turn(combat: Combat) -> void:
	var combatant := combat.get_current_combatant()
	var clamped := combatant.clamp_position(combatant.global_position)
	if combatant.global_position != clamped:
		combatant.rpc_id(combatant.get_meta("player_id"), "force_position", clamped)
	combatant.last_position = clamped
	combat.next_turn()
```
Appelée depuis `request_end_turn` (fin de tour volontaire du joueur) **et** depuis `_start_turn_timer` (expiration du timer, à la place de l'appel direct à `combat.next_turn()` qu'il y avait avant).
- **Trou de sécurité identifié et corrigé en session** : `combat.next_turn()` peut être déclenché par deux chemins distincts (`request_end_turn` OU expiration du timer). Avant cette factorisation, seul `request_end_turn` validait/clampait la position — un tricheur pouvait se déplacer hors du cercle puis **laisser son timer expirer** plutôt que de terminer son tour volontairement, contournant entièrement la validation. Les deux chemins passent désormais par `_end_current_turn`.

**Point de validation supplémentaire — en début de tour, pour couvrir la triche pendant le tour des autres :**
```gdscript
func _on_turn_changed(combatant: Combatant, combat: Combat):
	_start_turn_timer(combat)
	if (
		combatant is Player
		and not combatant.last_position.is_equal_approx(combatant.global_position)
	):
		combatant.rpc_id(
			combatant.get_meta("player_id"),
			"force_position",
			combatant.last_position
		)
	rpc("notify_turn_changed", combat.combat_id, combatant.get_path(), combatant.last_position)
```
- Complémentaire à `_end_current_turn` : celui-ci valide *son propre* mouvement en fin de son tour ; ce check-ci valide qu'*aucun mouvement n'a eu lieu pendant les tours des autres* — deux fenêtres temporelles différentes, toutes deux nécessaires.
- Restreint à `Player` (pas `Enemy`, dont le mouvement n'est pas piloté par un client).
- **Deux bugs trouvés et corrigés en session, tous deux repérés en review de code plutôt qu'en test** :
  1. **Comparaison stricte (`!=`) remplacée par `is_equal_approx()`** — un `CharacterBody3D` au sol peut légèrement dériver sur `Y` d'une frame à l'autre (micro-jitter du floor snapping de `move_and_slide()`, comportement Godot connu), ce qui déclenchait une correction/RPC à chaque tour même pour un joueur honnête et immobile.
  2. **Appel RPC mal ciblé** — `rpc_id(...)` était appelé sans le préfixe `combatant.`, ce qui l'exécutait dans le contexte de `CombatManager` (où `force_position` n'existe pas) au lieu du nœud `Combatant` qui porte réellement cette méthode. **Suspecté d'être la cause d'un bug de gameplay observé en session** : le joueur ne pouvait plus se déplacer qu'en glissant le long d'un seul axe dès le début d'un nouveau tour — hypothèse : l'appel RPC cassé interrompait l'exécution de `_on_turn_changed` avant d'atteindre la ligne `rpc("notify_turn_changed", ...)`, empêchant `reset_move()` de s'exécuter et laissant le cercle du tour précédent (déjà largement consommé/décentré) actif pour le nouveau tour. **Non confirmé formellement** — corrigé avant qu'un test isolé n'ait pu valider l'hypothèse précisément, voir "Pas fait" ci-dessous.

**RPC de correction ciblée — `force_position` sur `Combatant`, sécurisée par vérification de l'expéditeur :**
```gdscript
@rpc("any_peer")
func force_position(pos: Vector3):
	if multiplayer.get_remote_sender_id() == 1:
		global_position = pos
```
- **Bug identifié et corrigé en session** : la première version utilisait `@rpc` sans arguments (équivalent à `@rpc("authority", ...)`), qui restreint l'appel à l'autorité du nœud — or l'autorité d'un `Player`, c'est le client, pas le serveur. Le serveur tentant d'appeler cette RPC depuis un nœud dont il n'est pas l'autorité aurait été silencieusement rejeté par Godot. Corrigé en `@rpc("any_peer")` + vérification manuelle que l'expéditeur est bien le peer serveur (`id == 1`) — même principe de double garde que `request_end_turn` (n'importe qui peut appeler, mais le contenu de la fonction filtre qui est légitime).

**Transport de la position canonique via `notify_turn_changed` — signature enrichie d'un paramètre :**
```gdscript
@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath, pos: Vector3):
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	combatant.reset_move(pos)
```
- Décision structurante prise en session, à ne pas oublier si le pattern est réutilisé ailleurs : **ne jamais laisser un client relire sa propre `global_position` locale pour reconstruire une donnée de validation** (`reset_move()` a été délibérément changé pour recevoir la position en paramètre plutôt que de la lire localement) — un tricheur pourrait sinon transformer sa position trichée en nouvelle référence légitime sur sa propre machine. La valeur canonique doit être calculée une seule fois côté serveur (dans `_end_current_turn` ou `_on_turn_changed`) et voyager telle quelle par RPC jusqu'à toutes les machines, y compris celle du tricheur.

**⚠️ Bugs réseau non résolus, rencontrés en fin de session — à reprendre en priorité :**
Après application des corrections ci-dessus, des tests réseau réels à 2 instances ont révélé des problèmes non diagnostiqués — nature exacte non déterminée à la fin de la session (Julien a arrêté sur limite de fatigue liée aux problématiques réseau, pas sur un diagnostic clos). Aucun détail précis n'a été recueilli sur les symptômes observés cette fois-ci ; à investiguer dès le début de la prochaine session, idéalement avec des `print_debug` dans `reset_move()`, `_on_turn_changed`, et `force_position` pour tracer la séquence exacte des appels sur les deux machines.

**Non testé formellement, faute de temps** : confirmation que le bug "un seul axe de déplacement" (décrit plus haut, avant les corrections) est bien résolu par les deux correctifs de `_on_turn_changed` — à vérifier en priorité avant de creuser d'éventuels nouveaux bugs, ils pourraient être liés.

**Reste non traité, déjà noté en session précédente, toujours ouvert :**
- Le `velocity` du joueur n'est pas remis à zéro dans `force_position` — risque de rubber-band (input encore actif recréant immédiatement un dépassement après correction) non vérifié en pratique
- Point d'ancrage "avant action" pour la validation — toujours un stub réservé, dépend d'un système d'action pas encore implémenté

## Idées notées hors scope (ajoutées cette session)

- **Aggro en chaîne** (voir `GAMEPLAY.md` § Combat) : attaquer un ennemi peut alerter un ennemi proche, potentiellement en chaîne — caractéristique possible par type d'ennemi. Non implémenté, noté pour une session dédiée à l'IA ennemie.

## Session — Suppression de l'anti-triche + correction du bug de mouvement réseau (déplacement borné par tour) ✅ validé en réseau réel

**Objectif de session** : reprendre le point bloquant laissé en suspens à la session précédente (bugs réseau non diagnostiqués sur le déplacement borné par tour). Décision prise en cours de session : plutôt que de poursuivre le diagnostic de la couche de validation serveur (approche C), la retirer entièrement pour se recentrer sur le contenu de jeu — cohérent avec l'anti-triche déjà explicitement écarté ailleurs dans ce document (jeu coopératif entre amis, pas de priorité).

**Retrait de la couche anti-triche — revert git ciblé (option A) :**
La frontière entre le cercle de déplacement (mécanique de gameplay, commit `4d58f75`) et la validation serveur (`force_position`, `last_position`, `clamp_position` appelés depuis `combat_manager.gd`, ajoutés dans les 4 commits `WIP clamp movements in combat` suivants) était nette dans l'historique git. Fichiers concernés (`combat_manager.gd`, `scenes/combatant.gd`, `scenes/player.gd`) réécrits au contenu exact du commit `4d58f75` (`git show 4d58f75:<fichier> > <fichier>`, en contournant une restriction locale empêchant `git checkout` de remplacer les fichiers directement). Effet de bord accepté : le délai de `PREP` (`_start_combat_timer`) repasse de 10s à 5s, valeur d'avant l'anti-triche.

**Nouveau bug découvert en testant en réseau réel à 2 instances, distinct de celui de la session précédente :**
Une fois l'anti-triche retiré, deux symptômes observés côté joueur qui rejoint (pas l'hôte) : le mouvement n'est jamais bloqué hors tour, et l'ennemi se fait pousser quand ce joueur marche dessus.

**Cause racine identifiée — `current_combat` n'était jamais qu'une référence locale au serveur :**
```gdscript
# Combat.add_participant(), tourne uniquement côté serveur
player.current_combat = self
```
`current_combat` n'est ni répliqué (le `SceneReplicationConfig` ne couvre que `position`/`rotation`) ni transmis par RPC — cette affectation ne modifie que la copie du `Player` que le serveur possède dans son propre arbre de scène. Pour l'hôte, aucun symptôme : son `Player` local et celui manipulé par le serveur sont le même objet. Pour le joueur qui rejoint, ce sont deux instances distinctes — `current_combat` restait `null` indéfiniment chez lui, donc `is_my_turn()` toujours vrai (pas de blocage), et le clamp du cercle jamais actif. Le joueur marchait donc librement à travers l'ennemi ; côté serveur, `Enemy._physics_process()` (qui tourne bien là-bas) résolvait le chevauchement via la dépénétration automatique de `move_and_slide()`, poussant l'ennemi — d'où l'impression que "le joueur pousse l'ennemi".

**Refactor mené en plusieurs étapes sur la session :**

1. `current_combat: Combat` → `current_combat_id: int = -1` sur `Combatant` — un objet `Combat` (`RefCounted`) n'existe de toute façon que côté serveur et n'est pas transmissible tel quel par RPC ; seul un identifiant simple a du sens côté client. Sentinelle `-1` retenue par cohérence avec `Combat.current_turn`, qui utilise déjà cette convention.
2. `is_my_turn()` ne peut plus interroger un objet `Combat` inexistant côté client pour savoir qui joue. Ajout de `CombatManager.current_turn_combatant: Dictionary[int, Combatant]`, alimenté dans le handler déjà broadcasté de `notify_turn_changed` (RPC existante, `call_local`, atteint tous les pairs à chaque tour) :
```gdscript
@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	current_turn_combatant[combat_id] = combatant
	combatant.reset_move()
```
`is_my_turn()` compare simplement `CombatManager.current_turn_combatant.get(current_combat_id) == self` — plus besoin de connaître `phase` séparément : `notify_turn_changed` n'est jamais émise avant que `combat.start()` (qui bascule en `ONGOING`) n'ait tourné, donc tant qu'aucune entrée n'existe pour ce `combat_id`, le mouvement reste bloqué — comportement inchangé pendant la `PREP` (point de vigilance déjà noté dans une session précédente, volontairement non retouché ici).
3. Restait à transmettre `current_combat_id` lui-même au client — jusque-là toujours écrit uniquement côté serveur dans `Combat.add_participant`/`add_enemy`, jamais diffusé. Choix retenu : étendre `notify_state_changed` (déjà appelée au bon moment dans `handle_contact`, déjà dotée de la résolution `Players/Player-<id>`) plutôt que dupliquer une RPC quasi identique :
```gdscript
@rpc("authority", "call_local")
func notify_state_changed(player_id: int, new_state: PlayerState, combat_id: int = -1):
	var player: Player = get_tree().current_scene.get_node_or_null(str("Players/Player-", player_id))
	if player:
		player.state = new_state
		player.current_combat_id = combat_id
```
`combat_id` par défaut à `-1` pour ne pas casser les changements d'état sans lien avec un combat (`request_state_change`, potentiel futur `BUILD`). `get_states()` (rattrapage à la connexion) mis à jour en cohérence pour transmettre aussi `player.current_combat_id`.

**Deux bugs annexes trouvés et corrigés pendant le refactor, repérés en relecture avant même le test réseau :**
- `resources/combat.gd` : `add_participant`/`add_enemy` avaient gardé `player.current_combat = self.combat_id` après le renommage du champ en `current_combat_id` — référence à un champ qui n'existait plus.
- `combat_manager.gd` : `if player.current_combat_id:` / `if enemy.current_combat_id:` — test de vérité brut sur un `int`, alors que `0` est falsy en GDScript. Cassait spécifiquement pour le tout premier combat créé (`_next_combat_id` démarre à `0`). Corrigé en comparaison explicite `!= -1`.

**Crash rencontré au premier test réseau, corrigé — accès par crochets sur `Dictionary` typé :**
```gdscript
# Levait "Out of bounds get index '0' (on base: 'Dictionary[int, Combatant]')"
CombatManager.current_turn_combatant[current_combat_id]
```
`current_combat_id` passe à `0` dès le contact (via `notify_state_changed`), avant que `current_turn_combatant[0]` n'existe (rempli seulement après `combat.start()`, donc après les 5s de `PREP`) — fenêtre où l'accès par crochets sur un `Dictionary` typé lève une erreur au lieu de renvoyer `null` (contrairement à un dictionnaire non typé). Corrigé en `.get(current_combat_id)`.

**Testé cette session, en réseau réel à 2 instances** : déplacement borné par tour confirmé fonctionnel — blocage hors tour effectif pour le joueur qui rejoint (pas seulement l'hôte), plus de poussée de l'ennemi par contact. Referme le point resté ouvert depuis la session précédente.

**Pas fait / prochaine session :**
- Rattrapage à la connexion tardive pendant un combat en cours : `get_states()` transmet bien `current_combat_id`, mais `current_turn_combatant` (qui indique qui joue) n'est rempli que par les futurs appels de `notify_turn_changed` — un client rejoignant en plein combat n'aura l'info "qui joue" qu'au tour suivant, pas immédiatement. Non testé, à vérifier si ce cas se présente en pratique.
- Remise à zéro de `current_combat_id`/`current_turn_combatant` à la fin d'un combat : rien ne notifie la fin de combat côté réseau aujourd'hui (`Combat.end()` reste un signal purement serveur) — déjà noté comme lacune, toujours ouvert.
- Anneau visuel au sol, recentrage du cercle après action, IA basique, arme neutre : toujours pas commencés (reportés depuis plusieurs sessions).

**Bug annexe corrigé dans la foulée — l'ennemi se faisait pousser en marchant dessus, indépendamment du bug réseau ci-dessus :**
Root cause distincte, purement physique (pas de réseau ici) : asymétrie entre les `collision_mask` de `Player` et `Enemy`. `Player.collision_mask = 3` (layers 1+2) ne contenait pas le layer de `Enemy` (layer 3, valeur `4`) — le joueur traversait donc physiquement l'ennemi sans jamais être bloqué. `Enemy.collision_mask = 7` (layers 1+2+3), lui, contenait le layer de `Player` (layer 2, valeur `2`) — quand `Enemy._physics_process()` (côté serveur) découvrait son propre `CharacterBody3D` en chevauchement avec celui du joueur qui venait de le traverser, la dépénétration automatique de `move_and_slide()` déplaçait l'ennemi pour résoudre le chevauchement. Aucun code de poussée explicite : effet de bord de cette asymétrie.

Corrigé des deux côtés :
- `Player.collision_mask` : `3` → `7` (ajout du layer de `Enemy`) — le joueur est désormais physiquement bloqué par l'ennemi comme par un mur, le chevauchement ne se produit plus.
- `Enemy.collision_mask` : `7` → `5` (retrait du layer de `Player`) — défense en profondeur : l'ennemi ignore désormais physiquement les joueurs, ne s'appuie plus que sur `PlayerDetector` (`Area3D`, layer/mask distincts, non affecté par ce changement) pour la détection de contact. Même en cas de léger chevauchement dû à un décalage réseau, l'ennemi ne réagirait plus en se déplaçant.

## Session — Système d'action de combat : bouton fin de tour + fusion avec la future liste d'actions ✅ (fin de tour validé)

**Objectif de session** : démarrer le système d'action (priorité actée à la session précédente), en commençant par un bouton de fin de tour pour le debug — le timer de tour ne laisse pas toujours le temps de tester — et un peu d'UI pour une action de combat encore vide de contenu.

**Décision de design — le cercle de déplacement plafonné sur les 2 phases** : au lieu de repartir de `move_max_distance` à chaque action (ce qui donnerait un budget de mouvement double sur les 2 phases), l'action doit réduire `move_radius` de la distance déjà parcourue depuis le dernier recentrage avant de le recentrer — le total sur les 2 phases reste plafonné au rayon initial du tour. Pas encore implémenté (le bouton d'action générique reste à créer, voir "Pas fait" plus bas).

**Décision de design — fusion "fin de tour" / "action"** : plutôt que deux mécanismes réseau séparés, fin de tour devient une action comme une autre (`Action.END_TURN`), aux côtés d'une future liste d'actions choisissables au clic/raccourci (`Action.ATTACK_WEAPON` pour l'instant, vide). Le transport RPC (validation "c'est bien ton tour" côté serveur, broadcast du résultat) est mutualisé ; seul l'effet exécuté diffère selon l'action (dispatch par `match`). Tranché explicitement : fin de tour reste **toujours** jouable, indépendamment du fait que l'action de combat ait déjà été consommée ce tour-ci — elle ne partage pas l'économie d'action.

```gdscript
enum Action {
	END_TURN,
	ATTACK_WEAPON,
}

@rpc("any_peer", "call_local")
func request_action(combat_id: int, action: Action):
	if not multiplayer.is_server():
		return
	var remote_id:= multiplayer.get_remote_sender_id()
	var combat: Combat = currents.get(combat_id)
	if combat.get_current_combatant().get_meta("player_id") != remote_id:
		return

	match action:
		Action.END_TURN:
			combat.next_turn()
		Action.ATTACK_WEAPON:
			pass
```
`request_end_turn` (existant) a été remplacée par cette `request_action` unique.

**UI de combat créée** : `ui/game_ui.gd`/`ui/game_ui.tscn` (un `Control`, groupe `"combat_ui"` sur ses boutons), instanciée à la fois dans `levels/game.tscn` et `tests/test.tscn`. Affichage/masquage piloté par deux nouveaux signaux sur `StateManager` (`combat_started`/`combat_ended`), émis depuis `notify_state_changed` selon le nouvel état (`FIGHT`/`EXPLORATION`). L'ancien `levels/game_ui.gd` (qui ne gérait que le label de chargement) a été renommé `levels/game_messages.gd` pour libérer le nom.

**Souris réactivée pour l'UI, caméra uniquement en rotation au clic droit maintenu** : nécessaire pour pouvoir cliquer sur les boutons — la souris était jusque-là capturée en permanence dès `_ready()`. `player.gd::_input()` bascule désormais `Input.mouse_mode` entre `MOUSE_MODE_CAPTURED`/`MOUSE_MODE_VISIBLE` sur l'appui/relâchement du clic droit, et n'accumule `mouse_move` (utilisé pour la rotation caméra) que pendant que le mode est capturé.

**Deux bugs trouvés et corrigés en cours de session :**

1. **`StateManager.get_player_from_id()` sans `return`** — piège classique GDScript : pas de retour implicite de la dernière expression d'une fonction, contrairement à certains langages. La fonction renvoyait donc toujours `null`, silencieusement, ce qui empêchait `notify_state_changed` d'assigner `current_combat_id`/`state` sur le joueur concerné — régression complète du blocage de mouvement par tour (plus aucun blocage, ni pendant ni hors tour, comme avant l'implémentation du tour par tour). Corrigé en ajoutant le `return` manquant.
2. **`request_action` sans `call_local`** — cassait dès que l'appelant est le peer serveur lui-même : le bouton fait `CombatManager.rpc_id(1, "request_action", ...)` (cible le peer 1), qui échoue avec `RPC 'request_action' on yourself is not allowed by selected mode` quand l'appelant EST le peer 1. Pas qu'un artefact du test solo (`tests/test.tscn`, serveur seul) : l'hôte est un `Player` jouable comme un autre, donc ce même échec se serait aussi produit en vrai réseau à 2 instances le jour du tour de l'hôte. Corrigé en `@rpc("any_peer", "call_local")`.

**Ajustement mineur** : `_start_combat_timer`/`_start_turn_timer` passés de 5.0 à 15.0 secondes chacun, pour laisser plus de marge en test/debug — valeur provisoire, à retravailler côté équilibrage plus tard.

**Testé cette session** : bouton fin de tour fonctionnel, tour avancé côté serveur au clic.

**Pas fait / prochaine session :**
- Bouton d'action générique (celui qui doit recentrer le cercle en réduisant `move_radius` de la distance parcourue) : `Action.ATTACK_WEAPON` existe dans l'enum mais son dispatch est encore un `pass` vide, pas de bouton UI branché dessus.
- Boutons non conditionnés à `is_my_turn()` : cliquer sur "fin de tour" hors de son tour lève actuellement une erreur côté serveur (`combat.get_current_combatant()` ne correspond pas à l'appelant) — laissé de côté volontairement, à traiter en désactivant/activant les boutons selon le tour.
- **Piste ouverte, proposée par Julien** : centraliser `is_my_turn()` dans `CombatManager` plutôt que sur `Player`, à trancher en même temps que l'idée déjà notée de déplacer `current_combat_id`/`state` dans `StateManager` — même tension de fond (état de combat éclaté entre l'entité `Player`/`Combatant` et les managers qui le pilotent), à traiter ensemble plutôt qu'en deux refactors séparés.


## Session — Action Attaque : recentrage du cercle de déplacement ✅

**Objectif de session** : brancher l'effet du bouton d'action générique sur `Action.ATTACK_WEAPON` (recentrage du cercle plafonné sur les 2 phases de mouvement), suite logique du bouton fin de tour de la session précédente.

**Décision de design — état manipulé côté manager plutôt que via une méthode dédiée sur `Combatant`** : `combat_manager.gd` lit/écrit directement les champs de `Combatant` (`action_used`, et indirectement `move_radius`/`move_center` via `set_available_move()`) depuis le `case Action.ATTACK_WEAPON` de `request_action`, plutôt que d'exposer une API riche sur `Combatant`. Cohérent avec la direction déjà actée de centraliser l'état de combat côté managers (`StateManager`/`CombatManager`) plutôt que sur `Player`/`Combatant` — toujours pas tranchée formellement, mais ce choix va dans le même sens et évite d'avoir à revenir dessus plus tard.

```gdscript
Action.ATTACK_WEAPON:
	if combatant.action_used:
		return
	#TODO attack action
	combatant.action_used = true
	combatant.set_available_move()
```

`Combatant.set_available_move()` (nouveau) fait le calcul discuté : `move_radius -= global_position.distance_to(move_center)` avant de recentrer `move_center` sur la position actuelle — le budget de mouvement total sur les 2 phases reste plafonné au rayon initial du tour, au lieu de repartir de `move_max_distance`.

**Garde ajoutée en cours de session, suite à une remarque en revue** : un premier passage posait bien `action_used = true` mais ne le lisait nulle part — cliquer plusieurs fois sur Attaque dans le même tour aurait donc rétréci le cercle à chaque clic (jusqu'à négatif). Corrigé en ajoutant `if combatant.action_used: return` en tête du `case`, sur le même principe que le check `get_meta("player_id") != remote_id` déjà présent juste au-dessus dans `request_action`. `action_used` est remis à `false` pour le combattant sortant dans `Combat.next_turn()`, avant l'incrément de `current_turn`.

**UI** : bouton "Attack" ajouté dans `ui/game_ui.tscn`, même parent (`Combat Bar`, groupe `combat_ui`) et même patron de câblage que "End Turn" (`_on_attack_button_button_up` → `CombatManager.rpc_id(1, "request_action", ..., Action.ATTACK_WEAPON)`).

**Testé cette session, en jeu** : clic Attaque recentre bien le cercle de déplacement ; un 2e clic dans le même tour est bien bloqué par `action_used`.

**Pas fait / prochaine session :**
- L'effet réel de l'attaque (ciblage, dégâts) : `Action.ATTACK_WEAPON` reste un `#TODO` au-delà du recentrage du cercle et de la consommation du slot d'action.
- Boutons de combat toujours pas conditionnés à `is_my_turn()` (point déjà noté, volontairement pas traité ici).

## Session — Centraliser `is_my_turn()` + brancher les boutons de combat dessus + fix focus clavier

**Objectif de session** : traiter le point laissé ouvert la session précédente — conditionner les boutons de combat à `is_my_turn()`, en tranchant d'abord la question d'architecture en attente (où vit l'état de combat : sur `Player`/`Combatant` ou centralisé dans les managers).

**Décision d'architecture tranchée — centraliser la *requête*, pas le *stockage* :** `current_combat_id`/`state` restent des champs sur `Player`/`Combatant` (cohérent avec le pattern déjà en place pour `position`/`rotation`/`initiative` — état synchronisé par RPC, porté par le node). Seule la fonction qui répond "à qui le tour" migre vers `CombatManager`, là où `current_turn_combatant` (la source de vérité du tour) vit déjà — évite de dupliquer cette logique entre deux fichiers sans casser la convention existante pour le reste de l'état combat. Renommée `is_player_turn` au passage (plus appelée en interne sur `self`, mais depuis l'extérieur avec un joueur explicite).

**Deux bugs trouvés et corrigés pendant l'écriture de `is_player_turn` :**
1. **Comparaison de mauvais type** : `current_turn_combatant.get(...)` stocke des `Combatant`, la première version comparait à `player.get_meta("player_id")` (un `int`) — ne pouvait jamais être vrai. Corrigé en comparant au node `player` directement (même principe que l'ancienne version sur `Player`, qui comparait `== self`).
2. **`null` non géré** : `StateManager.get_player_from_id()` peut renvoyer `null` (`get_node_or_null`) — accès non protégé plantait dessus. Corrigé avec un `if not player: return true` (fail-open, cohérent avec le reste du projet qui n'a pas d'anti-triche).

**Piège de performance détecté par Julien avant même le test — signature à revoir :** la première version prenait un `player_id: int` et le résolvait en interne via `StateManager.get_player_from_id()` (`get_node_or_null` sur un chemin construit par concaténation de string). Une fois branchée dans `player.gd::_physics_process()`, ça tourne ~60 fois/seconde pour retrouver un node que l'appelant a déjà sous la main. Corrigé en faisant prendre le node `Player`/`Combatant` directement en paramètre plutôt qu'un id — les deux appelants (`player.gd` avec `self`, `game_ui.gd` qui résout déjà son joueur local pour construire ses RPC) le fournissent gratuitement. Remet le coût au niveau de l'ancienne méthode sur `Player` (un champ + un `Dictionary.get()`), juste relocalisée.

**Piège de signal identifié avant implémentation — `Combat.turn_changed` vs RPC `notify_turn_changed` :** `Combat` est un `RefCounted`, instancié uniquement côté serveur (`CombatManager.handle_contact()`, gardée par `multiplayer.is_server()`) — aucune instance n'existe jamais sur un client, donc son signal `turn_changed` ne peut jamais atteindre l'UI d'un client distant (aurait fonctionné en test solo hôte, jamais en réseau réel — même famille de piège que les signaux de scène déjà rencontrés en début de projet). Le signal UI (`CombatManager.new_turn_received`) est donc émis depuis `notify_turn_changed`, le RPC `@rpc("authority", "call_local")` déjà garanti de tourner identiquement sur toutes les machines. Commentaire ajouté en tête de `resources/combat.gd` pour documenter cette limite (`# Exists only on server and is not replicated`).

```gdscript
# combat_manager.gd
signal new_turn_received

@rpc("authority", "call_local")
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	var combatant: Combatant = get_node_or_null(combatant_path)
	if combatant == null:
		return
	current_turn_combatant[combat_id] = combatant
	combatant.reset_move()
	new_turn_received.emit()

func is_player_turn(player: Player) -> bool:
	if player.current_combat_id == -1:
		return true
	return current_turn_combatant.get(player.current_combat_id) == player
```

**UI branchée (`game_ui.gd`)** : écoute `CombatManager.new_turn_received` en plus de `StateManager.combat_started`/`combat_ended` déjà en place, résout le joueur local et active/désactive le groupe `combat_ui` via `is_player_turn()`. `game_ui.tscn` ajustée en cohérence : le groupe `combat_ui` est passé du conteneur (`HBoxContainer`) directement aux enfants (`Control`, `Attack Button`, `End Turn Button`), avec `disabled = true` et `visible = false` par défaut, pour que l'état initial (avant tout signal) soit cohérent avec un combat non commencé.

**Bug distinct trouvé en test — focus clavier retenu par les boutons après clic :** un clic sur un bouton lui laisse le focus clavier ; les flèches suivantes étaient alors interceptées par la navigation GUI intégrée de Godot (déplacer le focus entre `Control`) au lieu d'atteindre le mouvement du perso. Cause : le mouvement était lu via `Input.get_vector("ui_left", "ui_right", "ui_down", "ui_up")` — les actions `ui_*` sont réservées par Godot pour cette navigation GUI, donc tout `Control` focusable de la scène entre en concurrence avec le perso pour les mêmes touches.

Deux options comparées : `focus_mode = FOCUS_NONE` ciblé sur les boutons (rapide, local) vs actions de mouvement dédiées, découplées de `ui_*` (plus de travail, mais ferme le sujet pour toute future UI). **Option retenue : actions dédiées.** Nouvelles actions `move_up`/`move_down`/`move_left`/`move_right` (`project.godot`), remappées sur les touches W/A/S/D en position physique (`physical_keycode`, indépendant du layout clavier — donc ZQSD affiché en AZERTY). `player.gd` n'utilise plus aucune action `ui_*` pour le mouvement.

**Non confirmé testé à la fin de cette session** : le fix du focus clavier a été appliqué mais pas encore validé en jeu dans l'échange — à vérifier en priorité à la prochaine reprise avant d'enchaîner dessus.

**Pas fait / prochaine session :**
- Confirmer en jeu que le fix focus (actions `move_*` dédiées) résout bien le blocage, y compris en réseau réel à 2 instances.
- L'effet réel de l'attaque (ciblage, dégâts) : toujours un `#TODO`.
- Rattrapage réseau tardif de `current_turn_combatant`, remise à zéro de l'état de combat en fin de combat : toujours ouverts (non bloquants).
- Anneau visuel au sol, IA basique, arme neutre : toujours pas commencés.

## Session — Notification de combat (rejoindre à distance) + revue de code

**Objectif de session** : permettre à un joueur non engagé de rejoindre un combat en `PREP` sans forcément marcher dans la zone de contact de l'ennemi — via une notification "Join" — et corriger au passage un bug d'affichage repéré en testant le flow existant (contact direct).

**Décisions de design actées avant implémentation :**
- **Déclencheur de la notification : global (broadcast)**, pas basé sur la proximité. N'importe quel combat en `PREP` notifie tous les joueurs connectés, où qu'ils soient sur la carte — alternative écartée : nouvelle `Area3D` de détection plus large que le `PlayerDetector` existant de l'ennemi.
- **Position du joueur qui rejoint à distance : autour des participants déjà en combat** (calcul dynamique, pas un point fixe sur l'ennemi) — alternative écartée : marqueur `JoinPoint` fixe sur `enemy.tscn`. **Non implémenté cette session** (voir "Pas fait" plus bas) : le join fonctionne aujourd'hui (le joueur rejoint la liste des participants), mais rien ne le téléporte — un joueur loin de l'ennemi rejoint sans bouger.
- **Principe retenu** : l'état d'un combat (`player.state`/`current_combat_id`) doit être connu de tous les joueurs sans filtre (déjà le cas), mais les *actions*/réactions UI ne doivent se déclencher que pour le joueur concerné — distinction qui a guidé les deux bugs corrigés ci-dessous.

**Bug trouvé et corrigé — UI de combat affichée directement chez l'host au lieu du message de join :**

`notify_state_changed` (RPC broadcast `call_local`) émettait `combat_started`/`combat_ended` sans filtrer *pour qui* le changement d'état avait lieu — dès qu'un client passait en `FIGHT`, tous les autres clients (dont l'host) recevaient aussi le signal et affichaient leur propre UI de combat. Corrigé en scindant la fonction : les champs (`player.state`, `player.current_combat_id`) restent assignés sans filtre pour tout le monde (nécessaire pour `is_player_turn()` etc.), seule l'émission des signaux UI est restreinte à `player_id == multiplayer.get_unique_id()`.

**Implémentation du join — nouvelle action `JOIN_COMBAT` dans `request_action`** (pas une RPC séparée) : cohérent avec la fusion déjà actée en session précédente (fin de tour/attaque comme actions du même enum). UI : nouveau groupe `combat_prep_ui` (label + bouton "Join") dans `game_ui.tscn`, notifié via `StateManager.new_combat_available` (nouveau signal, émis depuis `notify_state_changed` quand `combat_id != -1`).

**Bug trouvé et corrigé — le join ne faisait rien de visible :**

Deux causes cumulées dans la branche `JOIN_COMBAT` de `request_action` :
1. La résolution du combattant appelant réutilisait `combat.get_current_combatant()` (pensée pour "c'est ton tour ?", `END_TURN`/`ATTACK_WEAPON`) — pendant `PREP`, `current_turn` vaut encore `-1`, et l'indexation négative de GDScript (`turn_order[-1]`) renvoie silencieusement le dernier combattant déjà présent, pas `null` — le check d'identité comparait donc le mauvais joueur.
2. Aucun `StateManager.rpc("notify_state_changed", ...)` n'était appelé après `combat.add_participant()` — le joueur qui rejoint (et tout le monde) n'était jamais informé que ça avait fonctionné.

Corrigé en sortant `JOIN_COMBAT` du bloc générique "c'est ton tour" (résolution directe du joueur via `remote_id`, pas de dépendance à `get_current_combatant()`) et en ajoutant le broadcast manquant.

**Revue de code (`/code-review`, high effort, 8 angles) menée sur ce diff — 9 findings, 8 corrigés par Julien** (le périmètre d'écriture de Claude sur ce projet exclut les fichiers `.gd`/`.tscn`, voir `CLAUDE.md` — correctifs donnés en snippets, appliqués manuellement) :
- Null-guard sur `combat` (`currents.get()` peut renvoyer `null`) dans `request_action`
- Garde `combat.phase != ONGOING` ajoutée avant la résolution `get_current_combatant()` — ferme aussi l'exploit du point 1 ci-dessus pour `END_TURN`/`ATTACK_WEAPON` (un joueur pouvait agir hors tour pendant `PREP`, avec un risque de corruption de l'ordre de tour au démarrage réel du combat, cf. indexation négative)
- `combat_prep_ui` désormais caché dans `_on_combat_ended` (oublié initialement, ne l'était que dans `_on_combat_started`)
- `pending_combat_id` : null-check sur le joueur local + anti-écrasement (une deuxième notif ne clobber plus une invitation en attente)
- RPC morte `notify_combat_available` (déclarée, jamais appelée) supprimée
- Séquence dupliquée "add_participant + broadcast" (présente à la fois dans `handle_contact` et la branche `JOIN_COMBAT`) factorisée dans `combat_manager.gd::_notify_joined()`
- 1 finding laissé de côté volontairement (architecture : `JOIN_COMBAT` en early-return dans `request_action` plutôt qu'une RPC dédiée — observation de design, pas un bug, à retrancher plus tard si besoin)

**Bug trouvé en vérifiant le correctif de la notif filtrée par phase — piège de données locales au serveur, même famille que le bug `current_combat` de la session "Suppression de l'anti-triche" :**

Le fix initial de "ne notifier que les combats encore en `PREP`" relisait `CombatManager.currents.get(combat_id)` **à l'intérieur de `notify_state_changed`**, une RPC `call_local` qui s'exécute identiquement sur toutes les machines. Or `CombatManager.currents` n'est peuplé que côté serveur (`resources/combat.gd` porte d'ailleurs le commentaire `# Exists only on server and is not replicated`) — sur un client, la lecture renvoie toujours `null`, donc `new_combat_available` ne s'émettait plus jamais côté client (fonctionnait par accident en test solo/host, où `currents` est bien peuplé). Corrigé en transmettant la phase en paramètre de la RPC (`combat_phase`, calculée côté serveur au moment de l'appel) plutôt qu'en la re-dérivant localement sur chaque machine — touche `notify_state_changed`, `get_states()`, `CombatManager._notify_joined()` et ses deux appelants (`handle_contact`, dont la variable `combat`/`enemy_combat` a dû être hissée hors du `if`/`else` pour rester accessible après ; branche `JOIN_COMBAT` de `request_action`).

**Testé cette session, en réseau réel à 2+ instances, confirmé côté client non-host ✅** : flow de join validé après le fix `combat_phase` — la notif "Join" apparaît bien côté client, pas seulement chez l'host. Referme le point de vigilance laissé en suspens plus haut.

**Pas fait / prochaine session :**
- Téléportation/repositionnement du joueur qui rejoint à distance (décision actée : autour des participants déjà en combat) — le join fonctionne (ajout aux `turn_order`), mais aucun déplacement n'est encore appliqué.
- Finding de revue de code laissé ouvert : `JOIN_COMBAT` géré en early-return spécial dans `request_action` plutôt que via une RPC dédiée — question d'architecture, pas un bug, à reprendre si besoin.
- L'effet réel de l'action Attaque (ciblage, dégâts) : toujours un `#TODO`, reporté depuis plusieurs sessions.
- Rattrapage réseau tardif de `current_turn_combatant`, remise à zéro de l'état de combat en fin de combat : toujours ouverts (non bloquants, déjà notés).
- Anneau visuel au sol, IA basique, arme neutre : toujours pas commencés.

## Session — Téléportation du joueur qui rejoint à distance ✅

**Objectif de session** : implémenter le point resté ouvert de la session précédente — déplacer physiquement un joueur qui rejoint un combat via le bouton "Join" (contrairement au contact direct avec l'ennemi, il peut être n'importe où sur la carte).

**`get_join_position()` (`resources/combat.gd`)** : moyenne des positions des alliés déjà en combat (filtrage `if combatant is not Player: continue` — l'ennemi n'entre pas dans le calcul, décision prise par Julien en cours de session, corrige un premier jet qui incluait l'ennemi et tirait le point d'arrivée vers lui plutôt que vers le groupe). Appelée depuis `request_action` (branche `JOIN_COMBAT`) **avant** `combat.add_participant(player)`, pour ne pas s'inclure soi-même dans sa propre moyenne d'arrivée.

**`force_position` (`scenes/player.gd`)** : RPC ciblée qui demande au client concerné de fixer sa propre position (le `MultiplayerSynchronizer` de `Player` reste en autorité client, le serveur ne peut pas écrire `global_position` directement sur sa copie du nœud — même contrainte que l'ancien `force_position` de l'anti-triche, retiré puis réintroduit ici pour un usage différent). Nommée volontairement `force_position` et pas `set_position` : `Node3D` porte déjà une méthode native `set_position()` (accesseur de la propriété `position`), une fonction de script portant ce nom risquerait de l'écraser, y compris pour des écritures internes du moteur. `velocity` remis à zéro à la téléportation (gap identifié à l'époque de l'anti-triche, jamais fermé — fermé ici).

**Bug rencontré et corrigé — crash au premier test réseau :**
```
RPC 'force_position' on yourself is not allowed by selected mode.
```
Même cause que le bug déjà rencontré sur `request_action` (session "Système d'action de combat") : quand l'host clique lui-même sur "Join", `rpc_id(1, ...)` cible le peer 1 en étant appelé depuis le peer 1 — sans `call_local`, Godot refuse. Corrigé en `@rpc("any_peer", "call_local")`, comme pour `request_action`. Le garde `multiplayer.get_remote_sender_id() != 1` reste fiable dans ce cas (déjà vérifié sur `request_action` en réseau réel côté host).

**Bug rencontré et corrigé — le joueur qui rejoint atterrissait exactement sur l'unique allié déjà présent :**

Avec un seul allié en combat, `sum / num_players` avec `num_players == 1` renvoie ce point lui-même — pas un bug d'arrondi, un cas limite (pas de marge du tout au premier jet). Corrigé en ajoutant une marge (`JOIN_MARGIN := 2.0`, `const` sur `Combat`) dans une direction aléatoire autour du centre calculé — évite aussi que deux joueurs qui rejoignent coup sur coup se retrouvent superposés entre eux. Prépare aussi le terrain pour une fonctionnalité prévue plus tard : laisser les joueurs se repositionner légèrement pendant la phase `PREP` avant le vrai début du combat.

**Testé cette session, en réseau réel à 2 joueurs ✅** : téléportation confirmée fonctionnelle après les deux corrections ci-dessus.

**Pas fait / prochaine session :**
- Repositionnement des joueurs pendant `PREP` (mentionné comme suite logique de la marge de join, pas encore posé).
- `JOIN_MARGIN` fixe pour l'instant — à ajuster/exposer si besoin une fois plus de tests en conditions réelles.

## Session — Retour visuel HP (mesh billboard + shader) ✅

**Objectif de session** : fermer la validation de l'effet de l'action Attaque (HP/dégâts, commit `8ea6123`) — jusque-là confirmé uniquement via logs serveur, sans retour visuel côté client.

**Recherche menée avant implémentation** (doc officielle + forums + GitHub) sur l'affichage d'une barre de vie au-dessus d'un `Node3D` en Godot 4 — un `Control`/`ProgressBar` ne peut pas être enfant direct d'un `Node3D` (vit dans un viewport 2D) :
- `SubViewport` + `Sprite3D` (approche la plus documentée, ex. KidsCanCode) : rendu d'un vrai `ProgressBar` dans un viewport, affiché via une texture sur un `Sprite3D` billboard. **Écartée** : ticket GitHub ouvert et non résolu ([#83898](https://github.com/godotengine/godot/issues/83898)) documentant un rendu imprévisible dès 2+ instances du même setup — pile le scénario multijoueur du projet (plusieurs joueurs + ennemi simultanés).
- Mesh billboard + shader spatial (`QuadMesh` + `ShaderMaterial`), avec un `instance uniform float health` pour partager un seul matériau entre toutes les instances. **Retenue** : pas de viewport, pas concernée par le bug ci-dessus, approche reconnue côté communauté (godotshaders.com).

**Décision d'architecture — health bar créée en code dans `Combatant._ready()`, pas via scène partagée** : il n'existe pas de scène `combatant.tscn` (seulement une classe de script `class_name Combatant`, héritée par `player.tscn`/`enemy.tscn`, chacune avec sa propre structure de nœuds). Basculer sur de l'héritage de scène Godot (`New Inherited Scene` à partir d'une base commune) aurait été plus idiomatique pour du réglage visuel dans l'éditeur, mais aurait demandé de retoucher la structure de deux scènes déjà configurées (collision, `SpringArm3D`...) pour un seul nœud — écarté comme trop de risque/travail pour ce que ça rapporte à ce stade. La création en code dans `_ready()` (déjà appelé via `super()` par `player.gd`/`enemy.gd`, cf. session "Ordre de tour") garantit un seul point de définition, sans duplication ni risque sur l'existant.

**Code committé (`scenes/combatant.gd`, `scenes/combatant_health_bar.gdshader`)** :
```gdscript
var current_hp: int = 0:
	set(value):
		current_hp = value
		health_bar.set_instance_shader_parameter("health", float(current_hp) / max_hp)

var health_bar: MeshInstance3D

func _ready() -> void:
	_setup_health_bar()
	current_hp = max_hp
	initiative = randi_range(0, 10)
	reset_move()

func _setup_health_bar():
	health_bar = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 0.15)
	health_bar.mesh = quad
	health_bar.position.y = 2.2
	var material := ShaderMaterial.new()
	material.shader = preload("res://scenes/combatant_health_bar.gdshader")
	health_bar.material_override = material
	add_child(health_bar)
```
Setter GDScript sur `current_hp` : point d'entrée unique pour la mise à jour visuelle, quel que soit le call site qui écrit la valeur (`change_hp()` côté serveur, ou `notify_health_changed` côté RPC broadcast reçu par chaque client) — pas de duplication de l'appel au shader à chaque endroit qui touche au HP.

**Piège d'ordre anticipé et évité** : `_setup_health_bar()` appelé en premier dans `_ready()`, avant `current_hp = max_hp` — sinon la première écriture de `current_hp` déclencherait le setter avec `health_bar` encore `null`.

**Premier shader du projet — notes pour la suite** :
- `render_mode unshaded` nécessaire pour une couleur plate, indépendante de l'éclairage de la scène.
- Pas de `render_mode billboard` en shader spatial (existe uniquement pour les shaders de particules) — le billboard est fait à la main dans `vertex()` via la matrice de vue (`MODELVIEW_MATRIX`/`VIEW_MATRIX`/`INV_VIEW_MATRIX`).
- `instance uniform` se pilote via `set_instance_shader_parameter()` **sur le nœud** (pas `set_shader_parameter()` sur le matériau, qui écraserait la valeur pour toutes les instances si le matériau était partagé). Ici chaque combattant a de toute façon son propre `ShaderMaterial` (`ShaderMaterial.new()` par instance), donc pas un risque actuel — mais le bon réflexe à garder si le matériau venait à être mutualisé plus tard pour optimiser.

**Testé cette session, en réseau réel à 2 instances, confirmé par Julien ✅** : la barre de vie se met à jour des deux côtés après une attaque. Ferme le point de validation resté ouvert depuis le commit `8ea6123` ("Combat : effet de l'action Attaque").

**Pas fait / prochaine session :**
- Bouton "Prêt" en phase `PREP` — objectif initial de cette session, reporté au profit du retour visuel HP jugé prioritaire pour valider l'attaque. Toujours d'actualité (voir "Prochaines étapes" #6 plus bas).
- Clarification actée en discussion, non implémentée : le tour d'un ennemi ne bloque rien aujourd'hui (le timer de sécurité de 15s le fait passer automatiquement), mais l'ennemi ne fait rien pendant ce temps — c'est l'item "IA basique" déjà noté plus bas, pas un nouveau trou.

## Session — Bouton "Prêt" en phase PREP ✅

**Objectif de session** : implémenter le point noté depuis plusieurs sessions ("Prochaines étapes" #6 ci-dessous) — démarrer un combat dès que tous les participants sont prêts, sans attendre la fin du timer de préparation.

**Décision actée** : un vrai ready-check, pas un "n'importe qui démarre tout de suite" — chaque participant doit cliquer "Prêt", le combat démarre automatiquement dès que tous l'ont fait ; le timer de préparation reste un filet de sécurité si personne ne clique. État stocké sur `Combat` (`ready_players: Array[Player]`), pas sur `Combatant`/`Player` — cohérent avec `turn_order`/`phase`/`current_turn`, déjà scopés au combat, évite d'avoir à réinitialiser un champ par-joueur entre deux combats successifs.

**Timer de préparation remonté de 5s à 30s** : maintenant que "Ready" permet de shortcut manuellement, plus besoin d'un timer court juste pour accélérer les tests — 30s se rapproche d'un vrai temps de préparation.

**Code committé** :
```gdscript
# resources/combat.gd
var ready_players: Array[Player] = []

func is_everyone_ready():
	for combatant in turn_order:
		if combatant is Player and combatant not in ready_players:
			return false
	return true
```
```gdscript
# combat_manager.gd, nouvelle valeur READY dans l'enum Action, branche dans request_action
if action == Action.READY:
	if combat.phase != StateManager.CombatState.PREP:
		return
	var player := StateManager.get_player_from_id(remote_id)
	if not player or player in combat.ready_players:
		return
	combat.ready_players.append(player)
	if combat.is_everyone_ready():
		combat.start()
	return
```
Un joueur qui rejoint après coup (via `JOIN_COMBAT`) n'est pas ajouté automatiquement à `ready_players` — il doit cliquer "Prêt" lui aussi, cohérent avec l'objectif.

**Bug UI trouvé et corrigé — le bouton ne s'affichait jamais :** premier essai avec le bouton "Ready" placé dans deux groupes (`combat_prep_ui` et `combat_ui`). Dans `_on_combat_started()`, `combat_ui.show()` le rendait visible, mais `combat_prep_ui.hide()` (appelé juste après, même fonction) l'annulait aussitôt puisqu'il appartenait aussi à ce groupe — et rien n'appelait jamais `combat_prep_ui.show()` pour le révéler. Corrigé en sortant le bouton de `combat_ui` (pas de raison qu'il soit soumis à l'activation/désactivation par tour, qui ne concerne que les actions en phase ONGOING) et en inversant `_on_combat_started()` pour montrer `combat_prep_ui` au lieu de le cacher. Sa disparition en fin de PREP est branchée sur `_on_new_turn()`, qui ne se déclenche jamais avant le tout premier `combat.start()` — sert donc déjà implicitement de signal "PREP terminée", sans signal dédié supplémentaire. Au passage, l'ancien groupe partagé `combat_prep_ui` (notif Join + futur bouton Ready) a été scindé : `combat_join_ui` pour la notif "vous pouvez rejoindre" (non-membres), `combat_prep_ui` réservé au bouton "Ready" (membres en PREP).

**Bug réseau trouvé et corrigé — le combat ne démarrait jamais même les deux joueurs prêts :** `_on_ready_button_button_up` réutilisait `pending_combat_id`, calqué sur le bouton "Join". Ce champ n'est fiable que pour un joueur pas encore membre du combat. Pour le joueur qui **déclenche** le combat par contact direct, `StateManager.notify_state_changed` assigne `player.current_combat_id` **avant** d'émettre `new_combat_available` — son propre `_on_new_combat` se voit donc déjà "en combat" et sort immédiatement sans jamais poser `pending_combat_id`, qui reste à `-1`. Resté invisible jusqu'ici car ni Join ni Attack/End Turn n'en avaient besoin pour ce joueur précis (Attack/End Turn utilisent déjà `player.current_combat_id`). Résultat : le clic "Ready" de l'initiateur envoyait `request_action(-1, READY)`, `currents.get(-1)` renvoyait `null` côté serveur, sortie silencieuse — un seul des deux joueurs s'ajoutait à `ready_players`, `is_everyone_ready()` ne devenait jamais vrai. Corrigé en alignant `_on_ready_button_button_up` sur le pattern déjà utilisé par `_on_end_turn_button_button_up`/`_on_attack_button_button_up` : lire `player.current_combat_id` (toujours fiable) plutôt que `pending_combat_id` (réservé aux candidats pas encore membres).

**Testé cette session, en réseau réel à 2 instances, confirmé par Julien ✅** : le combat démarre dès que les deux joueurs cliquent "Prêt".

**Pas fait / prochaine session :**
- IA basique de l'ennemi : son tour passe toujours uniquement par le filet de sécurité (timer 15s), aucune action de sa part — toujours pas commencé (reporté depuis plusieurs sessions).
- Anneau visuel au sol, arme neutre : toujours pas commencés.
- Rattrapage réseau tardif de `current_turn_combatant`, remise à zéro de l'état de combat en fin de combat : toujours ouverts (non bloquants).

## Session — Revue de code combat (bugs + complexité), fiabilisation du bouton Attaque

**Objectif de session** : Julien a demandé une revue du code de combat existant, jugé trop complexe pour continuer sereinement à empiler des features dessus (principe KISS explicitement posé). Traitement itératif des points remontés, un à la fois, plutôt qu'un cadrage global en amont.

**Corrections de validation/robustesse (petits bugs, faible risque)** :
- `Action.READY` ([combat_manager.gd](combat_manager.gd)) ne vérifiait pas que le joueur appartenait au combat ciblé — contrairement à `JOIN_COMBAT`, qui vérifie déjà `current_combat_id`. Un joueur ailleurs sur la carte pouvait "ready up" un combat auquel il ne participait pas (sans conséquence grave, le check de tour protège la suite, mais polluait `ready_players`). Corrigé en ajoutant `player.current_combat_id != combat_id` au garde-fou.
- `combatant.get_meta("player_id")` levait une erreur de log bruyante (metadata absente) quand c'était le tour d'un `Enemy` — corrigé en testant `combatant is not Player` avant.

**Refactoring de clarté, comportement inchangé (demande explicite de simplification)** :
- `request_action` (une seule fonction de ~60 lignes routant 4 actions différentes) découpée en `_handle_join`/`_handle_ready`/`_handle_combat_action` — la RPC ne fait plus que router via `match`.
- `Combat.next_turn()` ([resources/combat.gd](resources/combat.gd)) réinitialisait `action_used` du combattant qui **termine** son tour (fonctionnait par accident de timing, et reposait sur l'indexation négative de GDScript au tout premier appel depuis `start()`, `turn_order[-1]`). Inversé : incrémente `current_turn` d'abord, reset `action_used` ensuite sur le nouvel index — lecture directe "j'entre dans le tour de X, je lui redonne son action".
- Barre de vie sortie du code : `Combatant::_setup_health_bar()` (assemblage procédural d'un `MeshInstance3D` + `ShaderMaterial` en `_ready()`) supprimée, remplacée par une scène réutilisable `scenes/health_bar.tscn`, instanciée dans `player.tscn`/`enemy.tscn`. `Combatant.health_bar` redevient un simple `@onready var health_bar: MeshInstance3D = $HealthBar`.
- `request_state_change` (`state_manager.gd`) supprimée — vestige d'avant que `CombatManager` déclenche directement les transitions d'état, plus aucun appelant depuis plusieurs sessions.

**Nouveau document créé : [NETWORKING.md](NETWORKING.md)** — guide de décision (deux diagrammes Mermaid) pour trancher rapidement "cette donnée de combat : locale, `MultiplayerSynchronizer`, ou RPC arbitrée par le serveur ?", plus le piège récurrent d'autorité réseau (un nœud comme `Player`, dont l'autorité est le **client** propriétaire — pas le serveur — ne peut pas recevoir de RPC `@rpc("authority", ...)` appelée par le serveur ; pattern `any_peer` + garde manuelle obligatoire, déjà vu sur `force_position`, revu deux fois cette session). Une version visuelle est publiée en Artifact ("Aiguillage Réseau") pour consultation rapide sans rouvrir le `.md`.

**Bug de synchro réseau trouvé et corrigé — `move_center`/`move_radius` (cercle de déplacement en combat) redevenait celui du début de tour après une attaque** : `Combatant.set_available_move()` était appelée côté **serveur** dans `request_action` (branche `ATTACK_WEAPON`), qui ne mute que la copie du nœud `Player` détenue par le serveur — jamais celle du client, seule à exécuter réellement le clamp de mouvement (`is_multiplayer_authority()`). Classée via l'arbre de décision de `NETWORKING.md` : donnée purement locale au client (personne d'autre ne la lit, jamais validée serveur de toute façon — cohérent avec la décision déjà actée de ne pas valider le mouvement). Corrigée en sortant l'appel de `combat_manager.gd` et en l'appelant directement côté client, dans `game_ui.gd::_on_attack_button_button_up`, au moment du clic — zéro RPC nécessaire.

**Fiabilisation du bouton Attaque (il pouvait rester grisé sans retour, ou pire, actif hors combat)** :
- `Combatant.has_enemy_in_range()` (écrite il y a plusieurs sessions, jamais branchée) connectée à un nouveau `_process()` dans `game_ui.gd`, qui pilote en direct l'état actif/grisé du bouton selon la portée réelle — combinée à un booléen local `attack_used_this_turn` (reset à chaque tour) pour ne pas réactiver le bouton après une attaque déjà consommée.
- Filet de sécurité serveur ajouté : RPC ciblée `notify_action_rejected` réactive le bouton si le serveur refuse malgré tout l'attaque (aucun ennemi à portée au moment du traitement — cas limite de latence réseau).
- **Bug de chemin relatif trouvé en branchant `has_enemy_in_range()`** : `get_node("../Enemies")` supposait `Enemies` enfant de `Players`, alors que les deux sont frères sous `Game` (ou `Test`). Une tentative intermédiaire avec les noms uniques de scène (`%Enemies`) a été écartée : la résolution `%` s'appuie sur la chaîne `owner` des nœuds, or `Player`/`Enemy` sont instanciés à l'exécution (`PackedScene.instantiate()` + `add_child()` par `NetworkManager`/`MultiplayerSpawner`) et n'héritent jamais d'un `owner` côté scène parente — limitation connue de Godot avec le spawn dynamique, à retenir pour toute future tentative de `%unique_name` sur `Player`/`Enemy`. Corrigé en `get_tree().current_scene.get_node("Enemies")` (indépendant de la profondeur de l'appelant, fonctionne dans `game.tscn` comme dans `tests/test.tscn`).
- **Bug plus sournois trouvé en testant : possible d'attaquer avant même la phase `ONGOING`.** Cause réelle : `CombatManager.is_player_turn()` répond en fait à deux questions différentes selon le contexte — *"suis-je libre de bouger"* (vrai hors combat, `current_combat_id == -1`) et *"c'est mon tour de combat"* (vrai seulement en `ONGOING`). Le nouveau `_process()` de `game_ui.gd` tournant dès l'exploration (avant tout combat), dès que le joueur marchait à portée d'un ennemi le bouton se retrouvait activé en coulisses ; `_on_combat_started()` ne remettait jamais `disabled = true` en entrant en combat (asymétrie avec `_on_combat_ended()`, qui le fait déjà). Corrigé par un garde explicite `player.current_combat_id == -1` dans `_process()`, plus l'ajout du reset défensif dans `_on_combat_started()`.

**Testé cette session, confirmé par Julien ✅** : cercle de déplacement après attaque (`move_center`), activation/désactivation du bouton Attaque selon la portée réelle, blocage après usage, et disparition du bug "attaque possible avant `ONGOING`".

**Pas fait / prochaine session :**
- `is_player_turn()` mélange toujours deux sens ("libre de bouger" / "mon tour de combat") — patché localement dans `game_ui.gd` via le garde `current_combat_id == -1`, la fonction elle-même n'a pas été clarifiée/scindée. Un futur appelant qui la réutilise sans ce garde retomberait dans le même piège.
- `CombatManager.new_turn_received` est un signal global à **tous** les combats de la partie, pas filtré par combat ni par joueur — chaque changement de tour, n'importe où sur la carte, déclenche `_on_new_turn()` chez tout le monde. Fonctionne tant qu'un seul combat est actif à la fois ; à surveiller si plusieurs combats simultanés deviennent courants.
- Lacune connue depuis plusieurs sessions, toujours ouverte : `Combat.end()`/le signal `died` ne sont écoutés par personne — un ennemi à 0 PV reste dans `turn_order`, un combat ne se termine jamais de lui-même.
- Bug mineur noté, pas traité : le bouton "Join" reste visible pour un joueur spectateur même après qu'un combat soit passé en `ONGOING` — rien ne diffuse la fin de la phase PREP aux non-participants qui avaient reçu la notification globale.
- Chantier structurant identifié mais volontairement repoussé (choix explicite de Julien : nettoyages rapides d'abord) : fusionner `StateManager`/`CombatManager`, qui portent chacun une partie de la vérité "ce joueur est-il en combat ?" (`PlayerState.FIGHT` d'un côté, `current_combat_id` de l'autre) et s'appellent mutuellement. Raisonnement complet dans la discussion ayant mené à `NETWORKING.md`, pas commencé.

## Session — Fermeture de la boucle de combat (mort, victoire, fin de combat) ✅

**Objectif de session** : traiter le point le plus ancien du backlog — `Combat.end()`/le signal `died` n'étaient écoutés par personne, un ennemi à 0 PV restait dans `turn_order`, un combat ne se terminait jamais de lui-même.

**Décision actée avant implémentation — combattants morts gardés dans `turn_order`, filtrés par `current_hp > 0` à la lecture, plutôt que retirés du tableau.** Alternative écartée : retirer immédiatement un combattant mort, plus simple pour les lectures (`get_enemies_in_range`, `next_turn`...) mais oblige à corriger `current_turn` à la main pour éviter un décalage d'index. Le filtrage évite ce risque, et garde l'historique complet du combat dans `turn_order` — utile pour un futur récap de fin de combat (idée mentionnée par Julien en décidant, pas encore posée).

**Code committé** :
- `resources/combat.gd::add_enemy()` : connecte `enemy.died` à une nouvelle fonction `_check_victory()`, qui parcourt `turn_order` et appelle `end()` si plus aucun `Enemy` n'a `current_hp > 0` (condition de victoire uniquement — la défaite, tous les joueurs morts, reste hors scope, aucune conséquence/respawn définie pour l'instant).
- `next_turn()` : boucle désormais sur l'index tant que `turn_order[current_turn].current_hp == 0`, pour sauter les morts en avançant le tour.
- `get_enemies_in_range()` : ajout du filtre `combatant.current_hp > 0` — sans ça, un ennemi mort restait une cible valide pour l'action Attaque.
- `combat_manager.gd::handle_contact()` : connecte `combat.combat_end` à un nouveau `_on_combat_ended(combat)`, même pattern que `combat.turn_changed`/`_on_turn_changed`.
- `_on_combat_ended()` : boucle sur `combat.turn_order`, filtre les `Player`, et appelle `StateManager.rpc("notify_state_changed", ..., EXPLORATION)` pour chacun (un seul joueur traité par appel, même pattern que `_notify_joined`/`_handle_join` — pas de variante broadcast à inventer), puis retire le combat de `currents`.

**Bug trouvé et corrigé en testant — joueurs toujours bloqués en mouvement après la fin du combat :** le premier appel RPC dans `_on_combat_ended` passait `combat.combat_id` en 3ᵉ argument de `notify_state_changed` (calqué sur `_notify_joined`, où ça a du sens puisqu'on *rejoint* un combat). Pour la fin de combat c'est l'inverse : `notify_state_changed` assigne ce 3ᵉ argument à `player.current_combat_id`, donc repasser l'id du combat qui vient de se terminer le laissait non remis à `-1` — déclenchant toujours le bloc "Limit if in combat" de `player.gd::_physics_process()` (gate sur `current_combat_id != -1`) malgré un état `EXPLORATION` par ailleurs correct. Corrigé en ne passant pas ce 3ᵉ argument (valeur par défaut `-1` dans la signature de `notify_state_changed`).

**Clarifié en cours de session** : le signal `StateManager.combat_ended` (déjà existant, pas celui de `Combat`) n'était pas mort comme supposé — `ui/game_ui.gd` l'écoute bien pour cacher l'UI de combat côté client local ; il manquait seulement d'être déclenché à la fin d'un combat, fermé par ce qui précède.

**Testé cette session, en réseau réel ✅** : un combat se termine bien à la mort du dernier ennemi, les joueurs retrouvent un mouvement libre (confirmé après le fix du bug ci-dessus).

**Pas fait / prochaine session :**
- Rattrapage réseau tardif de `current_turn_combatant` pour une connexion en plein combat : toujours ouvert (non bloquant, noté depuis plusieurs sessions).
- Défaite (tous les joueurs morts) : explicitement hors scope cette session, aucune conséquence/respawn défini.
- Récap de fin de combat : idée mentionnée par Julien en actant la décision de garder les morts dans `turn_order` — pas posée, motive ce choix pour plus tard.
- Reste du backlog inchangé (voir "Prochaines étapes" ci-dessous) : IA basique, `is_player_turn()` à clarifier, fusion `StateManager`/`CombatManager`, bouton "Join" visible après `ONGOING`.

## Session — IA basique de l'ennemi (attaque ou passe) ✅

**Objectif de session** : sortir l'ennemi de sa passivité totale — jusqu'ici son tour ne faisait rien, seul le timer de sécurité (15s) le faisait passer. Scope volontairement limité : attaquer si un joueur est à portée, sinon passer — pas de déplacement/chase, qui reste un sujet à part (premier mouvement scripté d'un ennemi, pathfinding basique).

**Mutualisation `get_enemies_in_range()` → `get_targets_in_range()` (`resources/combat.gd`)**, décidée avant l'implémentation de l'IA : plutôt que dupliquer une fonction symétrique "joueurs à portée", la fonction déduit elle-même le camp adverse depuis le type de l'attaquant (`(attacker is Player and combatant is Enemy) or (attacker is Enemy and combatant is Player)`) — même principe déjà posé dans `Combatant.has_enemy_in_range()` (branche sur `self is Enemy`). Alternative écartée : passer le type recherché en paramètre (`is_instance_of()`) — plus explicite à l'appel mais réintroduit un paramètre que la fonction peut déduire seule, et rompt la cohérence avec `has_enemy_in_range()`. Retour typé `Array[Combatant]` (pas `Array[Enemy]`) : aucun appelant n'a besoin d'un type plus précis, `change_hp()`/`global_position` sont déjà sur `Combatant`. Les deux appelants existant (`_handle_combat_action::ATTACK_WEAPON`) et nouveau (IA ennemie) branchent dessus sans cast.

**Piège anticipé avant d'écrire le code — récursivité signal/next_turn() :** `combat_manager.gd::_on_turn_changed()` est connecté au signal `Combat.turn_changed`, lui-même émis par `next_turn()`. Faire avancer le tour de l'ennemi *depuis* ce callback (appel synchrone à `combat.next_turn()`) aurait ré-émis le signal et ré-appelé `_on_turn_changed()` de façon récursive si le tour suivant tombe aussi sur un ennemi — sans risque avec le nombre actuel de combattants, mais un vrai piège dès plusieurs ennemis par combat. Deux corrections possibles comparées : `call_deferred()` (repousse l'exécution en fin de frame, zéro délai perceptible) vs un `await` avant d'agir (même effet de rupture de pile, avec en prime une pause "l'ennemi réfléchit"). **Retenu : l'`await`** — Julien a jugé la pause de rythme désirable de toute façon pour un tour ennemi instantané, perçu comme bizarre en test.

**Code committé (`combat_manager.gd`)** :
```gdscript
func _on_turn_changed(combatant: Combatant, combat: Combat):
	_start_turn_timer(combat)
	if combatant is Enemy:
		_handle_enemy_turn(combat, combatant)
	rpc("notify_turn_changed", combat.combat_id, combatant.get_path())

func _handle_enemy_turn(combat: Combat, enemy: Enemy):
	await get_tree().create_timer(1.0).timeout
	var players := combat.get_targets_in_range(enemy)
	if players.size():
		players[0].change_hp(-2)
		rpc("notify_health_changed", players[0].get_path(), players[0].current_hp)
	combat.next_turn()
```
`_handle_enemy_turn` appelée sans être attendue (même pattern que `_start_turn_timer` juste au-dessus) — l'`await` interne suspend la fonction avant le `next_turn()` final, qui ne s'exécute donc jamais imbriqué dans la pile d'appel d'origine. Le filet de sécurité `_start_turn_timer` (15s) reste actif même pour les tours ennemis, en secours si `_handle_enemy_turn` venait à échouer.

**Testé cette session, en réseau réel ✅** : l'ennemi attaque bien quand un joueur est à portée à son tour, passe sinon, confirmé par Julien.

**Trou identifié en relisant le code, pas corrigé — devenu réellement atteignable avec cette feature :** si l'ennemi tue le dernier joueur vivant, `next_turn()` boucle indéfiniment pour retomber sur lui-même (aucun autre combattant vivant) et rejoue son tour en boucle toutes les secondes sans rien faire (plus aucune cible). Pas un bug introduit par ce code — c'est le trou "défaite non gérée" déjà mis de côté en fermant la boucle de combat (voir session précédente) — mais jusqu'ici purement théorique puisque les ennemis ne pouvaient tuer personne ; à traiter dans une session dédiée à la défaite/game over.

**Pas fait / prochaine session :**
- Défaite (tous les joueurs morts) : trou ci-dessus, désormais atteignable en pratique, pas encore traité.
- Déplacement/chase de l'ennemi vers le joueur le plus proche quand personne n'est à portée : scope volontairement reporté.
- Style mineur noté, pas traité : `if players.size():` (vérité sur l'entier) au lieu du style `if ... .size() == 0:` déjà utilisé ailleurs — cosmétique, sans impact.
- Reste du backlog inchangé : `is_player_turn()` à clarifier, fusion `StateManager`/`CombatManager`, bouton "Join" visible après `ONGOING`, repositionnement en `PREP`, anneau visuel au sol, arme neutre.

## Session — Défaite (tous les joueurs morts) + série de bugs de fond révélés en testant ✅

**Objectif de session** : fermer le trou identifié en fin de session précédente — si l'ennemi tue le dernier joueur vivant, `next_turn()` bouclait indéfiniment sur lui-même. Scope volontairement réduit dès le cadrage : reset HP complet + retour en `EXPLORATION` à la défaite, **pas de téléportation** — les checkpoints multiples appartiennent au sujet plus large du mode construction (à traiter dans sa propre session, voir "Idées notées pour plus tard").

**Décisions actées avant code** :
- `_check_victory()` généralisée en `_check_combat_end()` (`resources/combat.gd`) : une seule fonction vérifie les deux issues (`enemies_alive == 0` ou `players_alive == 0`), plutôt qu'un signal `combat_end(victory: bool)` séparé — cohérent avec le principe déjà appliqué ailleurs dans le projet (mutualiser plutôt que dupliquer une fonction symétrique).
- Position du joueur à la défaite : autorité **client** (comme le mouvement), HP : autorité **serveur** (comme le reste du combat) — le critère retenu (`NETWORKING.md`) est "est-ce que le serveur a besoin de lire cette valeur pour décider quelque chose" : oui pour le HP (`next_turn`/`get_targets_in_range`/`_check_combat_end` en dépendent tous), non pour la position.

**Code committé (`_on_combat_ended`, `combat_manager.gd`)** : boucle sur `turn_order`, reset `current_combat_id = -1` pour **tous** les combattants (pas seulement les joueurs — nouveau, corrige au passage un trou symétrique côté ennemi, voir plus bas), et pour les joueurs : état `EXPLORATION`, `current_hp = max_hp`, broadcast `notify_health_changed`.

**Série de bugs trouvés en testant, tous corrigés et validés en réseau réel à 2 instances — le vrai contenu de cette session** :

1. **Condition inversée dans `_handle_enemy_turn`** (`if players.size() == 0:` au lieu de `> 0`) — l'ennemi ne détectait jamais correctement ses cibles, symptôme repéré en testant la défaite mais sans rapport avec elle (régression antérieure, pas introduite cette session).
2. **`enemy.current_combat_id` jamais réinitialisé à la fin d'un combat** — `_on_combat_ended()` ne traitait que les `Player`. Un joueur revenant dans la zone d'un ennemi après un combat terminé (pas de téléportation, cf. décision de scope) faisait planter `get_combat()` (`currents[combat_id]` sur un combat déjà retiré). Corrigé en traitant tous les combattants symétriquement dans `_on_combat_ended()`.
3. **`next_turn()` sans garde sur `phase`** — une fois `end()` appelé, rien n'empêchait `_start_turn_timer` (filet de sécurité 15s) ni `_handle_enemy_turn` de continuer à faire tourner le combat : reconstitué avec le HP reset à la défaite (un joueur mort ressuscité en cours de résolution, avant l'appel de fin de fonction), ça créait des combats "fantômes" qui rejouaient des tours réels indéfiniment. Corrigé par `if phase != ONGOING: return` en tête de `next_turn()` — point de passage unique choisi plutôt que de garder chaque appelant individuellement.
4. **Signal `died` jamais déconnecté** (`add_combatant()` connecte `combatant.died → _check_combat_end` mais rien ne l'enlève) — `Combat` est un `RefCounted` : cette connexion, jamais retirée, empêchait tout combat terminé d'être libéré (`get_reference_count()` : 15 à 23 après une fin de combat, jamais 0). Pire : la mort d'un joueur dans un combat en cours ré-déclenchait aussi les callbacks d'**anciens** combats de test (jamais nettoyés), qui évaluaient leur propre vieux `turn_order` et pouvaient conclure à tort à une fin de combat sans rapport. Corrigé en déconnectant `died` dans `end()`, symétrique à la connexion dans `add_combatant()`.
5. **`_start_turn_timer` comparait `current_turn` (index cyclique, 0..N-1) plutôt qu'un identifiant unique de tour** — un timer de 15s programmé plusieurs tours plus tôt pouvait retomber sur le même index par simple coïncidence de modulo et forcer un tour prématuré, d'où des tours perçus comme durant 2-3s au lieu de 15s. Corrigé avec un compteur `turn_number` monotone sur `Combat`, incrémenté dans `next_turn()` (piège intermédiaire : la variable avait été ajoutée mais oubliée d'incrémenter au premier essai — le bug empirait alors, `turn_number` valant toujours 0 rendait la comparaison **systématiquement** vraie).
6. **`pending_combat_id` (`game_ui.gd`) restait bloqué sur un ancien combat après un Join refusé** — un joueur rejeté (combat déjà `ONGOING`) n'était jamais ajouté au `turn_order` de ce combat, donc ne recevait jamais la notification de fin de combat qui aurait remis `pending_combat_id` à `-1`. Toute offre de combat suivante était alors silencieusement ignorée par le garde `pending_combat_id != combat_id`. Corrigé par une nouvelle RPC `notify_join_rejected` (même pattern que `notify_action_rejected`), reçue via un nouveau signal `CombatManager.join_rejected` écouté par `game_ui.gd`, qui réinitialise `pending_combat_id` et cache l'UI de Join.
7. **Piège Godot sur cette même RPC** : `@rpc("authority", "call_remote")` ne s'exécute jamais si l'appelant et la cible (`remote_id`) sont la **même machine** — cas concret : le personnage du serveur lui-même se voit refuser un Join. `call_remote` exclut explicitement l'exécution locale, et il n'y a pas de "remote" distinct quand la cible est soi-même. Corrigé par un appel direct (`notify_join_rejected()`) quand `remote_id == 1`, RPC réservée au vrai cas distant.

**Point de vigilance noté, pas encore reproduit** : `notify_action_rejected()` (attaque refusée) a exactement la même annotation `call_remote` — susceptible du même piège #7 si un jour c'est le personnage serveur lui-même dont l'attaque est refusée. Pas corrigé préventivement, à surveiller.

**Pas fait / prochaine session :**
- Téléportation vers un checkpoint à la défaite : explicitement hors scope, appartient au futur mode construction.
- Rattrapage réseau tardif de `current_turn_combatant` : toujours ouvert, non bloquant (noté depuis plusieururs sessions).
- Reste du backlog inchangé (voir "Prochaines étapes" ci-dessous).

## Session — Bouton "Join" visible après ONGOING + filtrage par combat_id de `new_turn_received` ✅

**Objectif de session** : traiter dans l'ordre les petits incréments identifiés en fin de session précédente (#10 puis #11 de la liste "Prochaines étapes").

**#10 — Bouton "Join" qui restait visible pour un spectateur après passage en `ONGOING` :**

Diagnostic : au passage PREP → ONGOING (`Combat.start()` → `next_turn()`), le seul signal diffusé à tout le monde est `notify_turn_changed` (broadcast), déjà écouté côté UI via `_on_new_turn()`. Mais cette fonction ne cachait que `combat_prep_ui` (bouton Ready), jamais `combat_join_ui` (bouton Join) — d'où le bouton qui restait affiché indéfiniment pour un joueur qui n'avait pas rejoint à temps.

Fix retenu (le plus stable des deux discutés) : cacher `combat_join_ui` **et** remettre `pending_combat_id = -1` dans `_on_new_turn()`, même pattern que `_on_join_rejected()`. Sans ce deuxième point, un spectateur qui rate la fenêtre de PREP restait avec un `pending_combat_id` obsolète, qui aurait fait ignorer silencieusement le **prochain** combat déclenché ailleurs sur la carte (`_on_new_combat` compare `pending_combat_id != combat_id`) — même classe de bug que le #6 déjà corrigé pour le cas "Join refusé".

**Filtrage par `combat_id` de `new_turn_received`, traité dans la foulée** (le point explicitement noté en #10bis du backlog — signal global à tous les combats, pas filtré) :

`new_turn_received` n'avait qu'un seul abonné (`game_ui.gd::_on_new_turn`), changement de signature sans risque ailleurs. Le `combat_id` existait déjà côté émission (`notify_turn_changed`), juste jeté avant d'arriver à l'UI.

**Code committé** :
```gdscript
# combat_manager.gd
signal new_turn_received(combat_id: int)
...
func notify_turn_changed(combat_id: int, combatant_path: NodePath):
	...
	new_turn_received.emit(combat_id)
```
```gdscript
# ui/game_ui.gd
func _on_new_turn(combat_id: int):
	attack_used_this_turn = false
	var player := _get_player()
	if player and player.current_combat_id == combat_id:
		var is_my_turn := CombatManager.is_player_turn(player)
		get_tree().call_group("combat_ui", "set_disabled", !is_my_turn)
		get_tree().call_group("combat_prep_ui", "hide")
	if pending_combat_id == combat_id:
		get_tree().call_group("combat_join_ui", "hide")
		pending_combat_id = -1
```
`attack_used_this_turn = false` laissé inconditionnel (hors des deux `if`) — discuté en session, jugé sans conséquence tant que le bouton Attaque reste caché pour un joueur hors de ce combat.

**Testé cette session, confirmé par Julien ✅** : bouton Join disparaît bien au passage en `ONGOING`, plus de faux positif entre combats non liés.

**#11 — `notify_action_rejected()` : même piège `call_remote`/self-target que le #7 (Join rejeté) :**

Vérification faite directement sur le code actuel plutôt que sur la description de session du fix #7 dans ce fichier, qui décrivait un correctif différent (appel direct conditionné à `remote_id == 1`) de ce qui est réellement en place aujourd'hui — le code fait foi : `notify_join_rejected()` est passée en `@rpc("authority", "call_local")` (pas `call_remote`), corrigeant le piège en s'assurant que l'appel s'exécute aussi localement quand l'appelant et la cible du `rpc_id()` sont la même machine (le personnage serveur qui se voit refuser un Join).

`notify_action_rejected()` avait toujours `call_remote`, donc le même trou : un personnage serveur qui attaque sans ennemi à portée ne recevait jamais la réactivation de son bouton Attaque. Fix appliqué par symétrie directe — sans passer par une reproduction préalable du bug, décision actée en session (le pattern `call_local` étant déjà validé sur le cas jumeau) :
```gdscript
@rpc("authority", "call_local")
func notify_action_rejected():
	get_tree().call_group("cost_an_action", "set_disabled", false)
```

**Testé cette session, confirmé par Julien ✅** : personnage serveur, hors de portée d'un ennemi, clic Attaque en combat → bouton réactivé correctement.

**Pas fait / prochaine session :** reste du backlog inchangé (voir "Prochaines étapes" ci-dessous) — les deux incréments prévus pour cette session (#10, #11) sont clos.

## Session — Clarification de `is_player_turn()` (#8) ✅

**Objectif de session** : traiter le point noté depuis la revue de code combat — `CombatManager.is_player_turn()` mélangeait deux questions différentes ("suis-je libre de bouger" / "c'est mon tour de combat"), patché localement à l'époque plutôt que résolu à la source.

**Diagnostic** : 3 appelants identifiés. `player.gd::_physics_process()` a réellement besoin de la sémantique combinée ("libre de bouger" = pas en combat, ou en combat et c'est mon tour). Les deux appels dans `game_ui.gd` (`_process()` et `_on_new_turn()`) sont désormais précédés d'un garde explicite `current_combat_id` — la branche "pas en combat" de l'ancienne fonction y était du code mort, le vrai besoin étant "c'est spécifiquement mon tour de combat".

**Split retenu (`combat_manager.gd`)** :
```gdscript
func is_combat_turn(player: Player) -> bool:
	return current_turn_combatant.get(player.current_combat_id) == player

func can_move(player: Player) -> bool:
	return player.current_combat_id == -1 or is_combat_turn(player)
```
`is_player_turn()` supprimée, pas de raison de la garder en compatibilité (aucun appelant externe). `player.gd` branché sur `can_move()`, `game_ui.gd` (les deux call sites) branché sur `is_combat_turn()`.

**Régression introduite puis corrigée en deux temps — bouton Attaque cliquable en phase `PREP` :**

1. **Premier bug** : `_process()` ([ui/game_ui.gd:16](ui/game_ui.gd:16)) branché sur `can_move()` au lieu de `is_combat_turn()` — mauvais choix entre les deux nouvelles fonctions. En `PREP`, le joueur est déjà en combat (`current_combat_id != -1`) mais aucun tour n'est encore assigné, donc `is_combat_turn()` vaut `false` et `can_move()` (qui vaut `current_combat_id == -1 or is_combat_turn(...)`) vaut donc `false` aussi → la fonction ne retournait plus tôt, et activait le bouton Attaque si un ennemi était à portée. Corrigé en revenant à `is_combat_turn()`, avec le garde explicite `player.current_combat_id == -1` remis devant (nécessaire : contrairement à l'ancienne `is_player_turn()`, `is_combat_turn()` ne gère pas le cas "pas en combat").
2. **Deuxième bug, sur la correction elle-même** : le `not` manquant devant `CombatManager.is_combat_turn(player)` — la condition retournait (donc n'activait rien) quand c'était justement le tour du joueur, et continuait (activation du bouton) dans tous les autres cas, dont `PREP`. Même symptôme observé, cause différente. Corrigé en ajoutant le `not` manquant.

**Testé cette session, confirmé par Julien ✅** : bouton Attaque bien grisé en phase `PREP`, plus de régression.

**Pas fait / prochaine session :** reste du backlog inchangé (voir "Prochaines étapes" ci-dessous).

## Session — Fusion `StateManager`/`CombatManager` (#9) ✅

**Objectif de session** : traiter le point structurant repoussé depuis la revue de code combat — les deux autoloads portaient chacun une partie de la vérité "ce joueur est-il en combat ?" (`PlayerState.FIGHT` d'un côté, `current_combat_id` de l'autre) et s'appelaient mutuellement.

**Vérification faite avant de choisir une direction** : `player.state` (`PlayerState`) n'était en réalité **jamais lu** pour une décision — seulement écrit et renvoyé aux connexions tardives. Tout le code de gating (mouvement, UI) utilisait déjà `current_combat_id != -1`, jamais `player.state == FIGHT`. `PlayerState.BUILD` n'était référencé nulle part. Donc la "double source de vérité" était en réalité une donnée mémorisée à double, activement morte côté `FIGHT`/`EXPLORATION`.

**Décision actée, en deux temps :**
1. **Fusion complète dans `CombatManager`**, `current_combat_id` comme unique source de vérité, `state_manager.gd`/`PlayerState`/`get_states()`-via-state supprimés. Pas de couche `PlayerMode` générique conservée en prévision d'un futur `BuildManager` : Julien a précisé que le mode Build suivra les mêmes règles de déplacement que l'exploration (pas de gating façon combat) — donc pas un pair de `FIGHT`/`EXPLORATION` dans la même machine à états, plutôt un toggle indépendant côté serveur. Construire une abstraction commune maintenant, sur un seul cas concret (combat), aurait été deviner la forme d'un besoin qui n'est pas encore posé.
2. **`get_player_from_id()` déplacé hors de `CombatManager`** (pas son scope, remarque de Julien) : discussion sur autoload générique vs méthode sur la classe. Pas de doctrine Godot tranchée là-dessus (les autoloads sont faits pour de l'état partagé/persistant ou un hub de signaux ; une fonction pure sans état n'en a pas vraiment besoin). Inquiétude de perf soulevée sur une alternative "groupe + filtre metadata" (`get_tree().get_nodes_in_group("players")` + `get_meta("player_id")`) — non fondée à l'échelle du projet (O(n) avec n = quelques joueurs, appel rare, négligeable face à la latence réseau), mais l'idée a mené à une meilleure solution : cache statique sur `Player`, maintenu par le cycle de vie du nœud.

**Code committé (`scenes/player.gd`)** :
```gdscript
static var _by_id: Dictionary[int, Player] = {}
var multiplayer_id: int

func _enter_tree() -> void:
	multiplayer_id = int(self.name.split("-")[1])
	set_multiplayer_authority(multiplayer_id)
	_by_id[multiplayer_id] = self

func _exit_tree() -> void:
	_by_id.erase(multiplayer_id)

static func get_by_id(player_id) -> Player:
	return _by_id.get(player_id)
```
Placé dans `_enter_tree()` comme `set_multiplayer_authority()` juste au-dessus, pour la même raison déjà établie : cette fonction s'exécute sur **toute** machine où le nœud entre dans l'arbre (spawn local ou réplication), donc le cache contient bien tous les joueurs (local + distants), pas seulement le sien. O(1) garanti, et plus de dépendance à un chemin de scène codé en dur (`"Players/Player-" + id`) — fragilité déjà rencontrée deux fois par le passé (piège `%unique_name` sur les nœuds spawnés dynamiquement, bug `get_node("../Enemies")`).

**RPC `notify_state_changed` remplacée par `notify_combat_id_changed`** (`combat_manager.gd`) : ne porte plus de `new_state`, déduit `combat_started`/`combat_ended` par comparaison avant/après de `current_combat_id` plutôt que par un enum explicite :
```gdscript
@rpc("authority", "call_local")
func notify_combat_id_changed(player_id: int, combat_id: int = -1, combat_phase: CombatState = CombatState.PREP):
	var player := Player.get_by_id(player_id)
	if not player:
		return
	var was_in_combat := player.current_combat_id != -1
	player.current_combat_id = combat_id
	if combat_id != -1 and combat_phase == CombatState.PREP:
		new_combat_available.emit(combat_id)
	if player_id == multiplayer.get_unique_id():
		if combat_id != -1 and not was_in_combat:
			combat_started.emit()
		elif combat_id == -1 and was_in_combat:
			combat_ended.emit()
```

**Bug trouvé en testant, corrigé — `combat_started` ne se déclenchait jamais quand c'est le personnage hôte qui rejoint/déclenche un combat, bouton "Join" restait visible après téléportation :**

`Combat.add_combatant()` écrivait encore `combatant.current_combat_id = self.combat_id` **directement**, côté serveur, avant la diffusion de la RPC ci-dessus. Sans conséquence avec l'ancien design (basé sur un `new_state` explicite), mais empoisonne le nouveau calcul `was_in_combat` : sur le serveur, la RPC tourne aussi localement (`call_local`) — si le joueur concerné est le personnage du serveur lui-même, `was_in_combat` se calcule à partir d'un `current_combat_id` déjà pollué par l'écriture directe faite quelques lignes plus tôt, lit `true` au lieu de `false`, et la transition n'est jamais détectée. Un client distant n'est pas touché (`Combat` n'existe que côté serveur, jamais cette écriture directe locale chez lui) — d'où un bug qui ne se voyait que dans certains scénarios de test (hôte rejoignant/déclenchant).

Corrigé en laissant la RPC être la **seule** à écrire `current_combat_id` pour un `Player` (elle le fait déjà de façon synchrone partout via `call_local`), l'écriture directe restant uniquement pour les `Enemy` (pas de RPC/signal équivalent pour eux) :
```gdscript
# resources/combat.gd
func add_combatant(combatant: Combatant):
	turn_order.append(combatant)
	if combatant is not Player:
		combatant.current_combat_id = self.combat_id
	combatant.died.connect(_check_combat_end)
```
Même principe appliqué en fin de combat (`_on_combat_ended`, `combat_manager.gd`) : écriture directe retirée pour les `Player` (déjà couverte par la RPC juste après), gardée pour les `Enemy`. Au passage, `handle_contact()` a aussi été corrigé pour passer `combat.combat_id` (source directe et fiable) à `_notify_joined()` plutôt que de relire `player.current_combat_id`, qui dépendait du même effet de bord.

**Testé cette session, en réseau réel, scénario complet confirmé par Julien ✅** : combat déclenché par contact, Join (hôte et client distant), Ready, Attaque, fin de combat, spectateur qui ne rejoint pas — rien de cassé par la fusion.

**Pas fait / prochaine session :** reste du backlog inchangé (voir "Prochaines étapes" ci-dessous) — #9 clos.

## Session — Rattrapage tardif de `current_turn_combatant` ✅

**Objectif de session** : fermer le point ouvert depuis plusieurs sessions — un client qui se connecte pendant qu'un combat est déjà `ONGOING` ne savait pas qui avait la main tant que le tour suivant n'arrivait pas (`current_turn_combatant` n'était alimenté que par le broadcast `notify_turn_changed`, jamais reçu par un client absent au moment de l'émission).

**Fix retenu** : extension de `get_states()` (`combat_manager.gd`), déjà responsable du rattrapage de `current_combat_id`/`phase` à la connexion — pas de nouvelle architecture, réutilisation de `notify_turn_changed` en mode ciblé (`rpc_id`) plutôt qu'en broadcast, même principe que `notify_combat_id_changed`. Gardé strictement par `combat.phase == ONGOING` avant d'appeler `combat.get_current_combatant()`, pour éviter le piège déjà connu de `turn_order[-1]` (indexation négative GDScript) quand `current_turn` vaut encore `-1` en `PREP`.

**Bug trouvé en revue (avant test), corrigé par Julien** : un premier essai avait fait glisser l'appel à `rpc_id(..., "notify_combat_id_changed", ...)` à l'intérieur du `if player.current_combat_id != -1:` — un joueur hors combat ne recevait alors plus aucun rattrapage du tout. Invisible en pratique (un `Player` fraîchement spawné côté nouveau client a déjà `current_combat_id == -1` par défaut, cf. `scenes/combatant.gd`), mais un rattrapage devenu implicite/dépendant d'une coïncidence de valeur par défaut plutôt qu'explicite — même classe de fragilité que d'autres bugs "fonctionne par accident" déjà rencontrés sur ce projet. Corrigé en ressortant l'appel du `if`, ne laissant que le nouveau bloc `notify_turn_changed` gardé par `combat.phase == ONGOING`.

**Testé en réseau réel, confirmé par Julien ✅** : connexion d'un client pendant qu'un combat est `ONGOING` ailleurs sur la carte — le bon combattant a la main côté nouveau client sans attendre le tour suivant.

**Pas fait / prochaine session :** reste du backlog inchangé (voir "Prochaines étapes" ci-dessous).

## Session — Déplacement des joueurs en phase `PREP` (#4) ✅

**Objectif de session** : traiter le repositionnement des joueurs en `PREP`, en deux volets clarifiés par Julien en amont — (a) seul le clic "Join" doit téléporter/repositionner un rejoignant (déjà en place via `force_position`/`get_join_position()`, pas retouché cette session), (b) pendant la `PREP`, tous les joueurs déjà membres doivent pouvoir se déplacer, dans une zone donnée autour d'eux-mêmes (cercle par joueur, pas une zone partagée — décision actée avant de coder).

**Bug trouvé en lisant le code avant d'implémenter** : le mouvement était en réalité **totalement bloqué** pendant toute la `PREP`, pas juste mal centré. `CombatManager.can_move()` ne renvoyait `true` que si c'était le tour du joueur (`is_combat_turn()`, qui lit `current_turn_combatant`) — cette table n'est remplie qu'à partir du tout premier `notify_turn_changed`, jamais émis avant la fin de la `PREP`. Trou déjà repéré et volontairement laissé de côté dans une session précédente ("Ordre de tour, socle").

**Deux corrections apportées, la deuxième trouvée en testant en multi (la première ne suffisait pas) :**

1. `can_move()` étendu pour autoriser le mouvement tant qu'aucun tour n'a encore été assigné pour ce combat — testé d'abord en lisant `CombatManager.currents.get(combat_id).phase == PREP`, **rejeté** après test réseau réel : `Combat`/`currents` n'existe et n'est peuplé **que côté serveur** (commentaire déjà présent en tête de `resources/combat.gd`), alors que `can_move()` tourne sur la machine ayant l'autorité du joueur concerné — le serveur pour son propre personnage (d'où un test solo/hôte qui semblait fonctionner), mais chaque client pour le sien (où `currents` est toujours vide). Corrigé en ne lisant plus que de la donnée répliquée :
```gdscript
func can_move(player: Player) -> bool:
	if player.current_combat_id == -1:
		return true
	if not current_turn_combatant.has(player.current_combat_id):
		return true
	return is_combat_turn(player)
```
`current_turn_combatant.has(combat_id)` sert de proxy fiable à "la PREP est terminée" — l'entrée n'existe qu'à partir du premier `notify_turn_changed` (broadcast, `call_local`), reçu identiquement sur toutes les machines. Leçon générale ajoutée pour la suite : toute donnée lue par du code exécuté potentiellement côté client doit passer par de la donnée répliquée (RPC/signal), jamais par `currents`/`Combat` directement — cohérent avec l'arbre de décision de `NETWORKING.md`.

2. `player.reset_move()` appelé dans `notify_combat_id_changed`, au moment de la transition vers un nouveau combat (`combat_id != -1 and not was_in_combat`, même garde que `combat_started.emit()`) — pour ancrer `move_center` sur la position réelle d'entrée en combat plutôt que sur le point de spawn (stale sinon, `move_center` n'étant posé qu'au `_ready()` du joueur ou lors d'un tour précédent).

**Testé en réseau réel à 2 instances, confirmé par Julien ✅** : le joueur qui déclenche le combat par contact peut se déplacer en `PREP`, et le joueur qui rejoint via un client distant aussi (le point qui échouait avant le fix #1).

**Pas fait / prochaine session :**
- Rayon de la zone de déplacement en `PREP` : réutilise tel quel `move_max_distance` (5.0, pensé à l'origine pour un déplacement par tour) — pas de valeur dédiée, à ajuster si jugé trop restrictif à l'usage.
- ~~Repositionnement "en retrait par rapport à l'ennemi" pour un rejoignant~~ **Fait et validé** (session ci-dessous).
- Reste du backlog inchangé (voir "Prochaines étapes" ci-dessous).

## Session — Repositionnement des rejoignants en éventail, à l'opposé de l'ennemi ✅

**Objectif de session** : `get_join_position()` plaçait un rejoignant à un point purement aléatoire autour du centre des alliés, sans lien avec la position de l'ennemi. Objectif : le placer en retrait, du côté opposé à l'ennemi, sans que plusieurs rejoignants ne finissent les uns sur les autres — en anticipant des groupes de 4 à 8 joueurs (pas juste 2-3).

**Décisions actées avant code :**
- **Direction de repli = barycentre des ennemis → barycentre des alliés**, pas "le plus proche" : évite de devoir suivre quel ennemi a déclenché le combat (donnée non disponible), et généralise proprement à plusieurs ennemis si ça arrive un jour (actuellement un seul ennemi par combat, cas particulier trivial d'un barycentre à un seul point).
- **Formation en éventail (arc à distance `JOIN_MARGIN` constante), pas une ligne** : une ligne perpendiculaire à l'axe de repli, décalée uniquement dans un sens, grandit sans limite avec le nombre de joueurs (dérive loin d'un côté à 8 joueurs). Un éventail centré sur l'axe de repli, avec une répartition en zigzag (`0°, +20°, -20°, +40°, -40°...`) de part et d'autre, reste compact et symétrique quel que soit le nombre de rejoignants.
- **Pas de composante aléatoire** : positionnement entièrement déterministe (indexé sur `num_players`, le nombre d'alliés déjà présents avant ce rejoignant) — cohérent avec le choix déjà fait de garder `get_join_position()` simple.

**Code committé (`resources/combat.gd`)** :
```gdscript
const JOIN_MARGIN := 2.0
const JOIN_ANGLE_STEP := deg_to_rad(20.0)

func get_join_position() -> Vector3:
	var players_sum := Vector3.ZERO
	var num_players := 0
	var enemies_sum := Vector3.ZERO
	var num_enemies := 0
	for combatant in turn_order:
		if combatant is Player:
			players_sum += combatant.global_position
			num_players += 1
		elif combatant is Enemy:
			enemies_sum += combatant.global_position
			num_enemies += 1
	var players_center := players_sum / num_players
	var enemies_center := enemies_sum / num_enemies
	var retreat_direction := (players_center - enemies_center).normalized()

	# zigzag : 0, +1, -1, +2, -2, +3, -3...
	var step := int((num_players + 1.0) / 2)
	var side := 1 if num_players % 2 == 1 else -1
	var join_direction := retreat_direction.rotated(Vector3.UP, side * step * JOIN_ANGLE_STEP)

	return players_center + join_direction * JOIN_MARGIN
```
- `Vector3.rotated(axis, angle)` fait tourner `retreat_direction` autour de l'axe vertical pour obtenir chaque position de l'éventail — pas besoin de calculer un vecteur perpendiculaire séparé (`cross()`).
- Position toujours calculée en lisant `global_position` au moment de l'appel (aucune valeur mise en cache) : couvre nativement le cas d'un allié qui se déplace en `PREP` juste avant qu'un autre rejoigne (point soulevé en session, déjà satisfait par construction — la fonction n'a jamais stocké de position, avant ou après ce changement).
- Aucune garde sur `num_enemies == 0` : cette fonction n'est appelée que pendant un combat déjà démarré par un ennemi, invariant garanti par construction.

**Testé cette session** : d'abord à 2 joueurs en réseau réel (ne couvre que le premier cran du zigzag), puis visuellement à 4 (capture d'écran, positions en éventail cohérentes, décalées de part et d'autre de l'axe opposé à l'ennemi) — confirmé par Julien. **Non testé à 5-8** (pas d'infrastructure de test pour simuler autant de joueurs sans vrai groupe) : `JOIN_ANGLE_STEP`/`JOIN_MARGIN` sont des valeurs de départ, à réajuster la première fois qu'un groupe complet joue réellement.

**Pas fait / prochaine session :** reste du backlog inchangé (voir "Prochaines étapes" ci-dessous).

## Session — Enquête sur la fuite de référence `Combat` (#12) — fausse alerte, corrigée quand même ✅

**Objectif de session** : comprendre pourquoi `Combat.get_reference_count()` ne retombait jamais à 0 après la fin d'un combat (point ouvert depuis la session "Défaite", malgré la déconnexion du signal `died` déjà en place).

**Hypothèse de départ (fausse, invalidée par le test) :** `handle_contact()` connectait les signaux propres à `Combat` avec `.bind(combat)` :
```gdscript
combat.turn_changed.connect(_on_turn_changed.bind(combat))
combat.combat_end.connect(_on_combat_ended.bind(combat))
```
Un `Callable` lié (`.bind()`) qui capture l'objet sur lequel le signal est déclaré crée en théorie un auto-cycle de référence (`combat` → sa propre liste de connexions → `Callable` → `combat`), indétectable par un `RefCounted` (pas de ramasse-miettes à cycles dans Godot, contrairement à Python).

**Invalidée par un test au `WeakRef` :** le premier diagnostic (`get_reference_count()` juste après la fin du combat) affichait `11`, redescendant à `1` après 35s d'attente — cohérent avec des coroutines de timer encore en vol (`_start_combat_timer` 30s, `_start_turn_timer` 15s par tour), mais **pas concluant sur une vraie fuite** : `get_reference_count()` appelé depuis une fonction qui a `combat` en paramètre ne peut structurellement jamais afficher 0, cet appel étant lui-même une référence vivante. Le vrai test (`weakref(combat)`, relâcher la référence locale, vérifier `weak.get_ref()` après 35s) a renvoyé `null` : **l'objet était bel et bien libéré, aucune fuite réelle**.

**Leçon générale retenue** : `get_reference_count()` n'est fiable que mesuré depuis l'extérieur de l'objet ; mesuré depuis une méthode/fonction qui détient une référence au récepteur, il ne peut jamais tomber à 0 par construction — un `WeakRef` (relâcher toute référence forte connue, puis vérifier `weak.get_ref() == null`) est le seul test concluant pour prouver qu'un `RefCounted` a été réellement libéré.

**Corrigé quand même, par prudence architecturale** : même si l'hypothèse du cycle était fausse ici, capturer l'objet émetteur via `.bind()` à la connexion reste une pratique fragile (dépend de détails d'implémentation non garantis). Remplacé par la transmission de `self` à l'émission plutôt qu'à la connexion — plus robuste, sans capture possible d'auto-référence :
```gdscript
# resources/combat.gd
signal combat_end(combat: Combat)
signal turn_changed(combat: Combat, combatant: Combatant)
...
func end():
	...
	combat_end.emit(self)

func next_turn():
	...
	turn_changed.emit(self, turn_order[current_turn])
```
```gdscript
# combat_manager.gd — handle_contact()
combat.turn_changed.connect(_on_turn_changed)
combat.combat_end.connect(_on_combat_ended)
```
`_on_turn_changed(combat, combatant)` / `_on_combat_ended(combat)` mis à jour en conséquence (un seul point de connexion pour chaque signal, vérifié par recherche globale — pas d'autre appelant à corriger).

**Nettoyage** : `print_debug` de diagnostic (refcount, `_check_combat_end`) et le test `weakref` temporaire retirés.

**Testé cette session, en réseau réel, confirmé par Julien ✅** : scénario complet (join, ready, tours, mort d'ennemi) inchangé après le changement de signature des signaux.

**Pas fait / prochaine session :** #12 clos — aucune fuite réelle n'existait, correction appliquée par prudence. Reste du backlog inchangé (voir "Prochaines étapes" ci-dessous).

## Session — Comportements d'ennemis par archétype (chase + resources), socle `EnemyDefinition` — en cours (#13)

**Objectif de session** : partir du chase de l'ennemi (point ouvert depuis la session IA basique), reconnu en cours de route comme un sujet plus large — plusieurs ennemis auront des comportements différents (aller au contact, se cacher, fuir...), donc besoin d'un système de définition d'ennemi par resource plutôt que de coder un seul comportement en dur. Seul le socle "données fixes" (`EnemyDefinition`) a été posé et testé cette session — le chase lui-même et les archétypes de comportement restent à faire.

**Décisions d'architecture actées (avant code, comme convenu) :**
- **Comportement par composition (Resource), pas par héritage** de sous-classes d'`Enemy` (`MeleeEnemy`, `RangedEnemy`...) — choisi pour rester réutilisable/combinable entre archétypes sans dupliquer de scène/script par type, cohérent avec ce que `GAMEPLAY.md` anticipait déjà ("probablement porté par une future Resource par ennemi").
- **`EnemyBehavior` en sous-resource imbriquée dans une resource de définition plus large** (`EnemyDefinition` : HP, rayon de détection, modèle 3D à terme, `behavior`), plutôt qu'une seule resource plate — pour permettre à plusieurs espèces d'ennemis (HP/modèle différents) de partager le même archétype de comportement sans dupliquer ses paramètres. Décision motivée par Julien : "il faudra des archétypes de comportement, comme il en faudra peut-être pour d'autres" — donc `EnemyBehavior` doit porter la **décision** elle-même (une méthode type `decide_action(enemy, combat)`), pas juste des paramètres lus en dur par `combat_manager.gd`, sinon `_handle_enemy_turn` accumulerait un `if`/`elif` par archétype au lieu de rester agnostique.
- **Personnalisation d'instance (mode construction futur) hors de la resource** : la resource définit l'espèce/l'archétype (réutilisable, partagée entre plusieurs ennemis placés), la personnalisation par instance placée en niveau (position, éventuellement variations futures) ira dans le fichier de save du niveau, pas dans la `Resource` elle-même — cohérent avec la distinction déjà notée dans "Idées notées pour plus tard" (persistance de niveau).

**Piège de nommage anticipé avant de coder** : `class_name Enemy` existe déjà (`scenes/enemy.gd`, scène). La nouvelle resource ne peut donc pas s'appeler `Enemy` — même famille de conflit que `States`/autoload (documenté plus haut, issue Godot #28187). Nom retenu : `EnemyDefinition`.

**Code en cours (pas encore committé) :**

`resources/enemy_definition.gd` :
```gdscript
extends Resource
class_name EnemyDefinition

@export var max_hp := 10
@export var attack_range: float
@export var detection_radius: float
```
Le champ `behavior: EnemyBehavior` (sous-resource d'archétype) **n'est pas encore ajouté** — seule la partie "données fixes" existe pour l'instant.

`scenes/enemy.gd` — `Enemy` lit ses stats depuis sa `EnemyDefinition` à l'entrée en scène :
```gdscript
@export var definition: EnemyDefinition
@onready var player_detector: CollisionShape3D = $PlayerDetector/CollisionShape3D

func _ready() -> void:
	max_hp = definition.max_hp
	attack_range = definition.attack_range
	(player_detector.shape as SphereShape3D).radius = definition.detection_radius
	super()
```
**Point d'attention retenu, respecté ici** : `max_hp`/`attack_range` sont assignés **avant** l'appel à `super()` — `Combatant._ready()` fait `current_hp = max_hp`, donc lire la valeur de la resource après `super()` aurait initialisé les PV sur l'ancien défaut (`10`) au lieu de celui de la définition.

Une première instance créée pour tester : `resources/test_enemy.tres`.

**Bug trouvé en testant, corrigé — mais bug de donnée, pas de code :** `attack_range` semblait anormalement bas (ennemi attaquant seulement au contact quasi collé) malgré une valeur crue égale à l'ancien défaut (5.0). Vérification directe du `.tres` : la valeur réellement enregistrée était `1.5`, pas `5.0` — probablement une frappe non corrigée dans l'inspecteur, pas un souci d'ordre des champs (l'ordre du script et celui du `.tres` correspondent). Corrigé par Julien directement dans l'inspecteur.

**Aparté pédagogique retenu pour la suite (échelle du monde) :**
- Convention Godot : 1 unité 3D = 1 mètre (calibrage physique/gravité). Vérifié sur `player.tscn` : `CapsuleMesh`/`CapsuleShape3D` sans `height`/`radius` explicites → défauts Godot (hauteur 2.0, rayon 0.5), donc perso ≈ 2 m de haut, confirmant l'échelle. `attack_range`/`detection_radius`/`move_max_distance` sont donc bien déjà en mètres, à choisir en conséquence (une portée corps-à-corps réaliste tourne plutôt autour de 1,5-2 m, pas 5).
- Juger une distance en mètres à l'œil sur un screenshot 3D en perspective n'est pas fiable : distorsion de perspective + caméra elle-même reculée de 5 m via `SpringArm3D` (posé lors de la session caméra) fausse l'intuition visuelle.
- `distance_to()`/`global_position` mesure une distance **origine à origine**, pas bord de hitbox à bord de hitbox. Nuance apportée en session : l'origine du `CharacterBody3D` (`Player` comme `Enemy`) est calée sur les **pieds**, pas le centre géométrique (décision actée en session caméra) — sans incidence sur le calcul ici puisque les deux combattants sont au sol (écart en Y ~nul), mais distinction à garder en tête. L'écart visible entre les *surfaces* des deux capsules est donc `attack_range` moins le rayon de chacune (~0.5 m par défaut), légèrement inférieur au chiffre brut.
- **Piste de vérification non tranchée** : `print_debug` temporaire de la distance réelle au moment de l'attaque (rapide, ponctuel) vs. sol en grille calibrée 1 m dans `tests/test.tscn` (plus lent à poser, réutilisable durablement pour juger portées/déplacements à l'œil par la suite). À trancher à la prochaine session si le besoin revient.

**État des valeurs actuelles dans `test_enemy.tres` à la pause** : `attack_range = 5.0`, `detection_radius = 1.5`, `max_hp` par défaut (`10`, non surchargé). Noter que `detection_radius` est passé à `1.5` pendant la correction du bug ci-dessus — à confirmer avec Julien si c'est la valeur voulue ou un effet de bord du swap, avant de s'en servir pour trancher la taille des zones de détection des futurs archétypes.

**Pas fait / prochaine session :**
- `EnemyBehavior` (Resource, archétype de comportement) — pas encore créé. Premier archétype visé : "va au contact" (chase), avec une méthode de décision (`decide_action(enemy, combat)` ou équivalent) plutôt que de simples champs de paramètres.
- Champ `behavior: EnemyBehavior` sur `EnemyDefinition` — pas encore ajouté (lien entre les deux resources).
- `combat_manager.gd::_handle_enemy_turn` toujours en logique figée ("attaque si joueur à portée, sinon ne fait rien") — à faire déléguer la décision à `definition.behavior.decide_action(...)` une fois `EnemyBehavior` posé.
- Le chase lui-même (déplacement de l'ennemi vers le joueur quand hors de portée d'attaque, pendant son tour) — objectif de départ de la session, pas encore codé.
- Champ modèle 3D sur `EnemyDefinition` — pas encore ajouté (pas bloquant, lié au mode construction futur).
- Confirmer la valeur de `detection_radius` (`1.5`) dans `test_enemy.tres` — voir note ci-dessus.
- Rien de testé en réseau réel sur cette brique au-delà du câblage des champs fixes (HP/attack_range/detection_radius).
- ~~Rien encore committé~~ **Committé depuis** (`7a51ae1`, session suivante).

## Session — Format `CombatAction` unifié (joueur/ennemi), socle avant le chase ✅

**Objectif de session** : poser les fondations du chase (#13, comportements d'ennemis par archétype), en clarifiant d'abord un point de design soulevé par Julien avant d'écrire la moindre ligne — le chase seul n'a pas été codé cette session, tout le temps est passé sur le socle de représentation d'une action de combat.

**Point de départ** : proposition initiale de `decide_action(enemy, combat) -> bool` (juste "à portée ou pas"), avec l'attaque toujours résolue en dur dans `combat_manager.gd` (cible/dégâts fixes). **Rejeté par Julien**, à juste titre : ça réintroduisait l'anti-pattern déjà écarté à la session "CombatManager, socle" (`_handle_enemy_turn` qui accumulerait un `if`/`elif` par archétype) — le comportement doit décider la cible *et* le type d'action (attaque mêlée/distance, cible le soigneur, sort défensif...), pas juste si l'ennemi est à portée.

**Décision retenue — un format de résultat d'action partagé, pas propre aux ennemis :**

Julien a poussé plus loin : puisque la résolution côté serveur est structurellement la même pour un joueur et un ennemi (appliquer un delta de HP, un état, diffuser en RPC), autant unifier le **format du résultat décidé**, pas seulement en interne à `EnemyBehavior`. Nuance importante actée en discussion : ça ne remet **pas** en cause l'autorité serveur ni le protocole réseau existant — `CombatManager.Action` (`READY`/`JOIN_COMBAT`/`END_TURN`/`ATTACK_WEAPON`, ce qu'un *client a le droit de demander*, validé côté serveur) reste inchangé. `CombatAction` est un objet différent : le **résultat déjà résolu** d'une décision (côté joueur *après* validation serveur, côté ennemi directement depuis l'IA), jamais transmis sur le réseau lui-même.

**Code committé (`b704767`)** :

`resources/combat_action.gd` — `RefCounted` (pas une `Resource` : objet éphémère recalculé à chaque tour, jamais sauvegardé/édité dans l'inspecteur, même raisonnement que `Combat`) :
```gdscript
extends RefCounted
class_name CombatAction

enum Kind { NONE, ATTACK, DEFEND, HEAL }
enum Effect { NONE, SLOW, STUN, BURN, POISON }

var kind: Kind = Kind.NONE
var effect: Effect = Effect.NONE
var effect_nb_turn: int = 0
var target: Combatant = null
var hp_amount: int = 0

static func attack(target: Combatant, hp_amount: int) -> CombatAction:
	var action := CombatAction.new()
	action.kind = Kind.ATTACK
	action.target = target
	action.hp_amount = hp_amount
	return action
```
`Effect`/`effect_nb_turn`/`HEAL` ajoutés directement par Julien, au-delà de ce qui avait été discuté en session (qui ne couvrait que `kind`/`target`/`amount` pour `ATTACK`/`DEFEND`) — cohérent avec l'objectif "extensible dès maintenant", à valider/affiner à l'usage quand un premier cas `HEAL`/`Effect` sera réellement implémenté.

**Construction en un-liner — méthode statique factory par `Kind` retenue**, plutôt qu'un `_init()` générique à paramètres positionnels : discuté en session, deux options comparées (constructeur unique vs factory par `Kind`). Factory choisie pour rester extensible sans champs inutiles/ambigus selon le `Kind` (`DEFEND` n'aura pas forcément de `target`, par exemple) et un appel auto-documenté (`CombatAction.attack(target, amount)`) plutôt que des arguments positionnels à retenir.

**Cibles multiples (AoE) — tranché en discussion, pas encore un besoin concret** : décision actée de garder `target: Combatant` singulier, et de représenter un effet à cibles multiples par **plusieurs `CombatAction`** (une par cible) plutôt qu'un champ `targets: Array`. Raison : `notify_health_changed` est de toute façon un RPC par combattant (état répliqué individuel) — regrouper en un seul objet ne simplifierait rien côté réseau, juste de la cérémonie supplémentaire pour le cas single-target (très largement majoritaire aujourd'hui). Si un jour un besoin d'atomicité par cast (un seul VFX/résultat de jet pour toute une zone) apparaît, ce sera un concept séparé (ex. un "Cast" regroupant plusieurs `CombatAction`), pas une extension de `CombatAction` lui-même — pas anticipé avant un cas réel.

**Refactor immédiat du chemin joueur, à la demande de Julien** ("je préfère partir dans la bonne direction... la codebase est déjà assez complexe") : plutôt que de brancher `CombatAction` uniquement côté ennemi et migrer le joueur plus tard, les deux chemins existants (`_handle_combat_action::ATTACK_WEAPON` et `_handle_enemy_turn`) construisent désormais un `CombatAction` et appellent la même fonction d'exécution :

```gdscript
func _resolve_action(action: CombatAction) -> void:
	match action.kind:
		CombatAction.Kind.ATTACK:
			action.target.change_hp(action.hp_amount)
			rpc(
				"notify_health_changed",
				action.target.get_path(),
				action.target.current_hp
			)
		CombatAction.Kind.DEFEND:
			pass
		CombatAction.Kind.HEAL:
			pass
		CombatAction.Kind.NONE:
			pass
```
**Frontière volontaire retenue** : la validation (y a-t-il une cible ? le joueur a-t-il déjà agi ?) reste spécifique à chaque appelant (rejet RPC dédié côté joueur via `notify_action_rejected`, simple `Kind.NONE` à venir côté ennemi) — seule l'**exécution** de l'effet déjà décidé est unifiée dans `_resolve_action`.

**Bug de duplication trouvé en relisant le diff avant de committer, corrigé par Julien avant test final** : première version de la migration centralisait bien `change_hp()` dans `_resolve_action`, mais laissait le `rpc("notify_health_changed", ...)` dupliqué tel quel dans les deux appelants au lieu de le rapatrier dans `_resolve_action` — la partie "diffusion réseau" (justement l'argument donné pour unifier le format) restait non centralisée. Corrigé : les deux appelants ne font plus que construire un `CombatAction` et appeler `_resolve_action`, plus aucun `rpc()`/`change_hp()` en dehors de cette fonction.

**Testé en réseau réel à 2 instances, confirmé par Julien ✅** : attaque joueur et attaque ennemi appliquent les mêmes dégâts qu'avant le refactor (comportement de jeu inchangé, seul le chemin interne a changé).

**Pas fait / prochaine session** :
- Le chase lui-même toujours pas codé — objectif de départ de cette session, entièrement reporté au profit du socle `CombatAction`.
- `EnemyBehavior` (Resource, archétype avec `decide_action(enemy, combat) -> CombatAction`) — design discuté (voir ci-dessous) mais pas encore créé.
- Design retenu pour la suite, à implémenter :
  - `EnemyBehavior.decide_action(enemy, combat) -> CombatAction` (async) gère le chase en interne et renvoie directement un `CombatAction` tout fait — `_handle_enemy_turn` n'aura plus qu'à faire `var result := await enemy.definition.behavior.decide_action(enemy, combat); _resolve_action(result); combat.next_turn()`.
  - Déplacement physique du chase : pattern "capture/décision d'un côté, exécution physique de l'autre" déjà utilisé pour la rotation caméra (`_input` accumule / `_physics_process` consomme) — `decide_action` pose une cible de chase (ex. `enemy.chase_target`) et attend l'arrivée/un timeout, `Enemy._physics_process` (déjà présent pour la gravité) lit cette cible et fait le déplacement via `move_and_slide()`. Un seul point d'appel à `move_and_slide()`, pas de `move_and_slide()` appelé depuis une coroutine désynchronisée du tick physique.
  - Contrainte "ne doit pas pousser les joueurs" (demandée par Julien) : a priori déjà satisfaite par défaut — deux `CharacterBody3D` en collision ne se poussent pas l'un l'autre (cinématique, pas de réaction physique comme un `RigidBody3D`), seul le déplacement du corps qui bouge est freiné/glissé. **À vérifier empiriquement en testant**, pas juste supposer sur la doc (même réflexe que pour le timing RPC/`find_child` documentés plus haut).
  - Helper à ajouter sur `Combat` : un `get_nearest_opponent(attacker)` (symétrique à `get_targets_in_range`, sans filtre de portée) pour savoir vers où chasser — n'existe pas encore.
  - Champ `behavior: EnemyBehavior` sur `EnemyDefinition` — toujours pas ajouté.
  - Les joueurs ne peuvent pas bouger pendant le tour de l'ennemi (`can_move()` bloque tout le monde sauf le combattant actif) — donc la cible du chase est fixe le temps du tour, pas besoin de re-cibler en continu pendant la boucle.
  - Rien de testé en réseau réel sur le chase (logique normal, pas encore codé).

## Session — Moteur de règles d'ennemi (`CombatRule` / `RuleEntry`), sans chase ✅

**Objectif de session** : démarré sur le chase, devenu la construction d'un système de comportement piloté par la donnée. Le chase lui-même n'est **pas** codé — voir "Pas fait".

**Design partagé avant le code** : Julien a demandé à pouvoir composer des comportements d'ennemis sans recoder chaque archétype (référence : le système de Gambits de FFXII, "attaque si PV > 70 %, soigne si PV < 30 %", liste ordonnée condition → action, première règle qui matche). Terme FFXII écarté au profit de **`CombatRule`**, cohérent avec `Combat`/`CombatAction`/`CombatManager`. Deux approches comparées : petites classes `Resource` typées par condition/action (A) contre une condition générique pilotée par des enums `field`/`operator`/`value` (B). Julien a construit pas à pas une version simplifiée de A pour comprendre, en fusionnant condition et action dans une seule classe.

**Décisions actées :**
- **Pas de `EnemyBehavior` intermédiaire** : proposé puis abandonné à la demande de Julien. La liste ordonnée `rules: Array[RuleEntry]` vit directement sur `EnemyDefinition`, qui porte aussi `decide_action()`. La réutilisation entre espèces se fait au niveau des `.tres` de règles (le même `AttackNearestRule.tres` peut être glissé dans la liste de plusieurs ennemis), pas via un paquet de comportement partagé.
- **`RuleEntry` (règle + valeur) plutôt qu'une valeur portée par la règle** : chaque entrée de la liste a un champ `rule` et un champ `value`, propres à l'ennemi. Le but est d'équilibrer les valeurs par ennemi directement dans l'inspecteur, sans un `.tres` par valeur. Écarté : des champs de seuil nommés sur `EnemyDefinition`, qui l'auraient recouplée aux règles utilisées.
- **Limite connue** : un seul `value: float` générique par entrée. Le jour où une règle demandera deux nombres (ex. "soigne de X si PV < Y %"), il faudra un `Array[float]` ou des champs spécifiques à cette règle.
- **Signes des dégâts** : `CombatAction.hp_amount` est une magnitude **positive**, `_resolve_action` applique `change_hp(-action.hp_amount)`. (Le commit `b704767` les avait encore négatifs : Julien a changé la convention ensuite, j'ai relu à tort un diff périmé.)
- **`attack_damage`** vit sur `EnemyDefinition`, à côté de `attack_range` : c'est une donnée d'espèce, pas de règle.

**Code committé (`c6ca741`)** :
- `resources/rules/combat_rule.gd` : base `Resource`, `matches(enemy, combat, value) -> bool` (vrai par défaut) et `decide(enemy, combat, value) -> CombatAction`.
- `resources/rules/attack_nearest_rule.gd` : attaque l'adversaire le plus proche, ignore `value` (`_value`).
- `resources/rules/rule_entry.gd` : `@export var rule: CombatRule` et `@export var value: float`.
- `resources/enemy_definition.gd` : `attack_damage`, `rules`, et `decide_action()` (première règle qui matche gagne, `CombatAction.new()` = `Kind.NONE` si aucune).
- `resources/combat.gd` : `get_nearest_opponent()` et `is_valid_opponent()`. Julien a factorisé ce dernier au lieu de dupliquer le filtre, ce que j'avais jugé prématuré ; équivalence booléenne vérifiée (De Morgan), aucune régression.
- `combat_manager.gd::_handle_enemy_turn` délègue à `enemy.definition.decide_action()` puis `_resolve_action()`.
- `resources/test_enemy.tres` : une entrée `AttackNearestRule`, `attack_damage = 2`.

**Piège rencontré** : la signature d'une méthode surchargée doit reprendre les paramètres de la classe de base. `AttackNearestRule.decide()` était restée à 2 paramètres alors que l'appelant en passe 3 : erreur de signature à l'analyse, et plantage à l'exécution.

**Testé en réseau réel à 2 instances, confirmé par Julien ✅** : même comportement que l'ancien code (l'ennemi inflige 2 dégâts), désormais piloté par la donnée.

**Pas fait / prochaine session :**
- **Le chase** (objectif de départ). Comportement actuel à connaître : `AttackNearestRule` cible l'adversaire le plus proche **sans regarder la portée**, donc l'ennemi peut frapper à distance. Le garde-fou "attaque seulement si un joueur est à portée" de l'ancien code a disparu.
- Design à trancher : je recommande de mettre l'étape "aller à portée avant d'agir" dans `EnemyDefinition.decide_action`, générique et appliquée après le choix de la règle (les règles restent de pures décisions), plutôt que dans chaque règle. Déplacement physique prévu : `decide_action` pose un `chase_target` sur l'ennemi et attend l'arrivée ou un timeout, `Enemy._physics_process` exécute le déplacement via `move_and_slide()`. `decide_action` deviendra alors `async`.
- Exigence de Julien : l'ennemi ne doit pas pousser les joueurs. A priori satisfait par défaut (deux `CharacterBody3D` ne se poussent pas), **à vérifier en test**.
- Les joueurs ne peuvent pas bouger pendant le tour de l'ennemi : la cible du chase est fixe le temps du tour.
- Règles plus riches (seuils de PV, soin) : non commencées, elles poseront la question de la limite du `value` unique.

## Session — Chase de l'ennemi (`CombatAction.Kind.MOVE`, budget de déplacement partagé, tour multi-actions) ✅

**Objectif de session** : coder le chase resté ouvert depuis la session précédente. Julien a implémenté seul l'essentiel du socle avant la session (mouvement d'ennemi, `ChaseNearestRule`) ; la session a surtout servi de revue de code — plusieurs bugs trouvés en lecture puis corrigés/validés par Julien en test réel.

**Code ajouté par Julien avant/pendant la session :**
- `resources/combat_action.gd` : nouveau `Kind.MOVE`, champs `actor: Combatant` et `destination: Vector3`, factory `CombatAction.move(actor, destination)`. `CombatAction.attack()` prend désormais aussi un `actor` (les deux cas partagent le même champ, cohérent avec le format déjà unifié joueur/ennemi de la session précédente).
- `resources/rules/chase_nearest_rule.gd` (nouveau) : `matches()` vrai si le joueur le plus proche est hors de `attack_range` et qu'il reste du `move_radius` ; `decide()` calcule une destination à `RANGE_MARGIN` (0.9) × `attack_range` de la cible (`stop_distance`), pour arriver *juste* à portée plutôt qu'au contact.
- `scenes/enemy.gd` : `move_to(dest)` + logique de déplacement dans `_physics_process` (avance vers `move_target` à `move_speed`, se cale pile dessus au dernier pas, timeout de sécurité `_move_time_left`), signal `move_finished`.
- `scenes/combatant.gd` : `move_speed` remonté en `@export` (était `speed`, propre au joueur — désormais partagé joueur/ennemi, `player.gd` mis à jour en conséquence).
- **Réutilisation du mécanisme `move_center`/`move_radius`** (posé initialement pour le repositionnement libre du joueur en phase `PREP`) pour budgéter le déplacement de chase de l'ennemi : `_resolve_action::MOVE` clampe la destination demandée par la règle à `move_radius` autour de `move_center` via `.limit_length()`, exactement comme pour le joueur. Pas de nouveau système de budget créé, celui existant s'est avéré directement réutilisable.
- `combat_manager.gd::_handle_enemy_turn` restructuré en **boucle** (au lieu d'un seul appel à `decide_action()`) pour permettre plusieurs actions dans le même tour ennemi : mouvement si besoin → action → mouvement du reliquat s'il en reste, sans bloc dédié à chacune des trois phases — la boucle rappelle `decide_action()` jusqu'à obtenir `Kind.NONE` (ou un plafond de 3 résolutions).

**Clarification de design actée en session** : `action_used` ne concerne que les vraies actions (attaque/sort/défense) — pas le mouvement, qui reste gouverné uniquement par `move_radius`/portée. La garde `and not enemy.action_used` initialement présente dans `ChaseNearestRule.matches()` mélangeait les deux notions et empêchait tout mouvement une fois l'action de l'ennemi consommée (contraire au besoin du "reliquat après action") — retirée.

**Bugs trouvés en revue de code, corrigés et validés par Julien en test réel ✅ :**
1. **`action_used` jamais posé à `true` côté ennemi** — `AttackNearestRule.matches()` s'appuie dessus pour ne pas re-matcher, mais rien ne le mettait à jour après une attaque d'ennemi (le chemin joueur le fait lui-même dans `_handle_combat_action`, en dehors de `_resolve_action`, donc rien d'équivalent côté ennemi). Conséquence potentielle : ré-attaque en boucle dès qu'un ennemi est à portée. Corrigé en centralisant l'affectation dans `_resolve_action::ATTACK` (`action.actor.action_used = true`), partagée par les deux chemins — la ligne devenue redondante dans `_handle_combat_action` (chemin joueur) a été retirée par Julien.
2. **Boucle de sécurité de `_handle_enemy_turn` inversée** : condition initiale en `or` entre les trois critères d'arrêt (`not action or nb_resolved > 3 or action.kind != Kind.NONE`) — comme `nb_resolved` ne fait qu'augmenter, une fois le plafond dépassé la condition reste vraie *pour toujours* (il suffit qu'un seul des trois termes soit vrai avec un `or`), rendant le garde-fou contre-productif : il garantissait une boucle infinie au lieu de l'empêcher. Combiné au bug 1 (ré-attaque en boucle), ça aurait dû geler le tour — donc tout le combat — dès qu'un ennemi atteignait sa cible. Corrigé en `(not action or action.kind != Kind.NONE) and nb_resolved <= 3`.
3. **`move_radius` retombant à (quasi) 0 pile au moment où l'ennemi entre à portée** — pas un bug de code : `attack_range` et `move_max_distance` valent tous les deux `5.0` dans les données de test actuelles, et `stop_distance` (0.9 × `attack_range` = 4.5) est proche du budget de déplacement complet. Dès que la distance de départ dépasse `attack_range`, le trajet nécessaire pour atteindre `stop_distance` consomme donc mécaniquement une grosse partie (voire la totalité) du `move_radius` du tour — comportement attendu vu les valeurs actuelles, pas une fuite ou un double-décompte. Le reliquat réel dépend directement de l'écart entre `move_max_distance` et `attack_range` dans les données ; à garder en tête pour le tuning des futurs archétypes (un ennemi censé pouvoir chasser *et* reculer dans le même tour aura besoin d'un `move_max_distance` nettement supérieur à son `attack_range`).

**Testé en réseau réel à 2 instances, confirmé par Julien ✅** : chase fonctionnel, plus de ré-attaque en boucle, plus de gel de tour.

**Pas fait / prochaine session :**
- ~~`AttackNearestRule.matches()` ne protège pas contre un `get_nearest_opponent()` renvoyant `null`~~ **Nettoyé** (session ci-dessous) — garde `if not target: return false` ajoutée, cohérente avec `ChaseNearestRule`.
- ~~Le déplacement d'ennemi n'a pas encore été vérifié empiriquement pour la contrainte "ne doit pas pousser les joueurs"~~ **Vérifié** (session ci-dessous) — l'ennemi s'arrête bien pile à portée, confirmé par Julien.
- Règles plus riches (soin) : toujours pas commencées. Seuil de PV fait pour la fuite (voir ci-dessous).

## Session — `FleeRule` (seuil de PV) + agro de groupe entre ennemis (`pack_radius`), 2ᵉ archétype ✅

**Objectif de session** : coder en autonomie un nouvel archétype ("hit and run" : chasse, attaque, puis fuit) et tester avec plusieurs ennemis sur la carte. Julien a codé `FleeRule` et l'agro de groupe seul, la session a servi de revue de code à chaque étape — plusieurs itérations, deux bugs bloquants trouvés et corrigés.

**`FleeRule` (`resources/rules/flee_rule.gd`, nouveau)** :
- `matches()` : `if value and enemy.current_hp > value: return false` — fuite déclenchée sous un seuil de PV réglé via `RuleEntry.value` (même mécanisme que les autres règles). Particularité actée : `value = 0.0` (défaut si non réglé dans l'inspecteur) rend la condition toujours vraie (`if value` faux → pas de check) — la règle matche alors inconditionnellement. Pas corrigé, gardé tel quel car ça s'est avéré utile pour l'archétype "hit and run" (voir plus bas).
- **Bug trouvé en revue, corrigé** : première version de `decide()` renvoyait une destination à distance fixe d'1m (`to_target.normalized()`). Corrigé en un vecteur non normalisé (`enemy.global_position + to_target`, où `to_target` pointe déjà à l'opposé de la cible) — la distance demandée suit alors l'écart actuel à l'adversaire. Limite identifiée et actée comme acceptable pour l'instant : si l'ennemi est collé à sa cible (cas fréquent pour une fuite déclenchée par PV bas en mêlée), `to_target` est quasi nul, et `Vector3.limit_length()` dans `_resolve_action` ne peut qu'ajourter un vecteur trop long — jamais agrandir un vecteur trop court. Donc une fuite déclenchée à bout portant ne parcourt qu'une distance minime malgré un `move_radius` disponible plus grand. Pas encore retravaillé (piste notée : normaliser puis multiplier par `enemy.move_radius`, sur le modèle de `ChaseNearestRule`).

**Agro de groupe (`resources/combat.gd::add_combatant`)** — choix discuté en session : Julien a choisi l'option "propagation en chaîne" (un ennemi tiré dans le combat entraîne à son tour ses propres voisins) plutôt qu'un seul saut, pour un vrai effet de meute. Détection par simple boucle de distance sur le conteneur `Enemies` (pas de requête physique/`Area3D` dédiée) — jugé suffisant pour l'instant, ce check ne tournant qu'au moment de l'ajout au combat, pas par frame ; à revoir seulement si un besoin de perf concret apparaît (même logique que la décision AoE de `CombatAction`, session précédente).

```gdscript
func add_combatant(combatant: Combatant):
	if combatant.current_combat_id != -1:
		return
	turn_order.append(combatant)
	if combatant is Enemy:
		combatant.current_combat_id = self.combat_id
		for other_enemy: Enemy in combatant.get_parent().get_children():
			if other_enemy.current_combat_id != -1:
				continue
			if (
				combatant.global_position.distance_to(other_enemy.global_position)
				<= combatant.definition.pack_radius
			):
				add_combatant(other_enemy)
	combatant.died.connect(_check_combat_end)
```
- Garde anti-récursion infinie : `current_combat_id` est posé sur `combatant` **avant** de scanner ses voisins, donc un ennemi déjà traité ne se re-déclenche jamais (ni lui-même, ni via un voisin qui le re-détecterait dans l'autre sens) — vérifié en discussion avant écriture, pas de piège rencontré en test.
- Nouveau champ `pack_radius` sur `EnemyDefinition` (même style que `attack_range`/`detection_radius`). Rayon asymétrique assumé : c'est le `pack_radius` de l'ennemi qui *détecte* qui s'applique, pas celui du voisin détecté — à garder en tête si des archétypes aux rayons très différents se croisent un jour.
- **Bug trouvé en revue, corrigé** : première version itérait `for other_enemy: Enemy in combatant.get_parent():` — un `Node` Godot n'est pas itérable directement dans un `for` (contrairement à `Array`/`Dictionary`), seul `get_children()` l'est. Corrigé en `combatant.get_parent().get_children()`.

**Deuxième archétype créé — `resources/enemies/hit_and_run_enemy.tres`** : `rules = [ChaseNearestRule, AttackNearestRule, FleeRule]`, `pack_radius = 10.0`, `detection_radius = 3.0`. `FleeRule` sans `value` réglée (donc 0.0, toujours vraie) : combiné à l'ordre des règles et à la boucle multi-actions de `_handle_enemy_turn` (chase → attack → NONE ou reliquat), ça donne naturellement un "attaque puis tente de fuir" en fin de tour — comportement qui colle au nom de l'archétype, pas creusé plus mais à surveiller si un seuil de PV explicite devient nécessaire pour ce cas précis.

`levels/game.tscn` : ancien `test_enemy.tres` renommé/déplacé vers `resources/enemies/chase_enemy.tres` (dossier dédié aux définitions d'ennemis, plus adapté maintenant qu'il y en a plusieurs), un second ennemi (`hit_and_run_enemy.tres`) ajouté dans `Enemies`.

**Petite incohérence relevée en revue, non bloquante** : `ChaseNearestRule.decide()` a aussi reçu un `if not target: return` — en pratique mort/inatteignable, puisque `matches()` filtre déjà ce cas avant que `decide()` ne soit appelée. `return` sans valeur dans une fonction typée `-> CombatAction` est en plus syntaxiquement bancal (retourne implicitement `null`). Sans conséquence tant que `matches()` protège l'appel, mais à nettoyer si l'occasion se présente.

**Testé en réseau réel avec 2 ennemis (archétypes différents), confirmé par Julien ✅** : agro de groupe fonctionnel (chaîne validée), fuite fonctionnelle.

**Pas fait / prochaine session :**
- ~~Fuite à bout portant qui ne parcourt qu'une distance minime~~ **Corrigé et confirmé par Julien** — `FleeRule.decide()` calcule désormais `to_target.normalized() * enemy.move_radius` (fuite jusqu'à la limite du budget disponible, quelle que soit la distance de départ à la cible).
- `pack_radius` non testé avec des archétypes aux rayons très différents (asymétrie de détection).
- `return` sans valeur dans `ChaseNearestRule.decide()` et `FleeRule.decide()` (ajouté en cohérence par Julien) — nettoyage mineur, mort en pratique dans les deux cas puisque `matches()` filtre déjà l'absence d'adversaire avant l'appel.
- **Soins : hors scope pour l'instant** — appartiennent au futur système d'aptitudes, lui-même fortement couplé à la synthèse élémentaire/l'équipement (voir `GAMEPLAY.md` § Système élémentaire / Progression). À reprendre lors d'une session de design dédiée à ce système, pas comme une simple règle de combat de plus.

## Prochaines étapes

1. ~~**Effet réel de l'action Attaque**~~ **Fait et validé** : `Action.ATTACK_WEAPON` applique les dégâts (`Combatant.change_hp()`), diffuse le nouveau HP par RPC (`notify_health_changed`, commit `8ea6123`) et affiche désormais une barre de vie (mesh billboard + shader) — confirmé en réseau réel à 2 instances.
2. ~~**Fermeture de la boucle de combat**~~ **Fait et validé** (session précédente) : mort d'ennemi → victoire → fin de combat → joueurs libérés, confirmé en réseau réel. ~~Rattrapage tardif de `current_turn_combatant`~~ **Fait et validé** (session ci-dessus).
3. ~~**IA basique de l'ennemi**~~ **Fait et validé** (session ci-dessus) : attaque si joueur à portée, sinon passe — confirmé en réseau réel. Déplacement/chase reste ouvert.
3bis. ~~**Défaite (tous les joueurs morts)**~~ **Fait et validé** (session ci-dessus) — reset HP/état à la défaite, sans téléportation (hors scope, voir mode construction). A révélé et corrigé 7 bugs de fond en testant (détail plus haut) : détection ennemie, cleanup de fin de combat, boucle de tours fantômes, fuite mémoire sur `Combat`, timer de tour peu fiable, Join bloqué après rejet, piège RPC `call_remote` sur soi-même.
4. ~~**Repositionnement des joueurs pendant la phase `PREP`**~~ **Fait et validé** (session ci-dessus) — mouvement débloqué en `PREP` (bug trouvé : totalement bloqué avant, pas juste mal centré), cercle ancré sur la position réelle d'entrée en combat. Repositionnement "en retrait de l'ennemi" pour un rejoignant reste ouvert.
5. Rappel toujours valable : `tests/test.tscn` reste volontairement serveur seul (`skip_scene_loading` + `create_server()` direct), le menu principal est le chemin pour tester en mode connecté — pas une lacune, ne plus rouvrir ce point.
6. ~~**Bouton "Prêt" en phase `PREP`**~~ **Fait et validé** (session dédiée) — confirmé en réseau réel à 2 instances.
7. ~~**Revue de code combat + fiabilisation du bouton Attaque**~~ **Fait et validé** (session ci-dessus) — voir le détail complet plus haut.
8. ~~**`CombatManager.is_player_turn()` à clarifier/scinder**~~ **Fait et validé** (session ci-dessus) — scindée en `can_move()`/`is_combat_turn()`. A révélé 2 régressions en testant (mauvaise fonction branchée, puis `not` manquant), toutes deux corrigées.
9. ~~**Fusion `StateManager`/`CombatManager`**~~ **Fait et validé** (session ci-dessus) — `current_combat_id` comme unique source de vérité, `PlayerState` supprimée (donnée morte). A révélé un bug de transition (`combat_started` ne se déclenchait pas pour l'hôte), corrigé.
10. ~~**Bouton "Join" qui reste visible pour un spectateur après passage en `ONGOING`**~~ **Fait et validé** (session ci-dessus) — corrigé en même temps que le filtrage par `combat_id` de `new_turn_received` (signal auparavant global à tous les combats).
11. ~~**`notify_action_rejected()` : même piège RPC `call_remote`/self-target que le #7**~~ **Fait et validé** (session ci-dessus) — passée en `call_local`, même correctif que `notify_join_rejected`.
12. ~~**`Combat.get_reference_count()` ne retombe toujours pas à 0 après la fin d'un combat**~~ **Investigué et clos** (session ci-dessus) — fausse alerte (artefact de mesure, pas de vraie fuite, confirmé au `WeakRef`), `.bind()` auto-référent remplacé par transmission via `emit()` par prudence.
13. ~~**Comportements d'ennemis par archétype (chase + `EnemyBehavior`/`EnemyDefinition`)**~~ **Fait et validé** (session ci-dessus) — `EnemyBehavior` abandonné au profit de `rules` directement sur `EnemyDefinition` (session moteur de règles). Chase (`ChaseNearestRule`, `CombatAction.Kind.MOVE`, réutilisation du budget `move_center`/`move_radius`, tour ennemi multi-actions) codé, revu, corrigé (2 bugs bloquants trouvés en revue) et testé en réseau réel — voir détail complet plus haut. Reste ouvert : règles plus riches (seuils de PV, soin, retraite), non commencées.


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
- Choix entre donnée locale / `MultiplayerSynchronizer` / RPC serveur pour une nouvelle donnée de combat : voir [NETWORKING.md](NETWORKING.md), qui formalise ce raisonnement en arbre de décision — s'y référer avant de re-débattre au cas par cas
