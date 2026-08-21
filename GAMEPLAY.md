# Gameplay — Synterra

> Ce fichier consigne les décisions de **design de gameplay** (features, priorités, arbitrages), en complément de `PROGRESS.md` qui reste dédié à l'état technique. Mis à jour en fin de session de design.

## Vision de base (rappel)

RPG d'exploration 3D, combats tactiques, inspiré de *Trails in the Sky* (remake) et *Guild Wars 2*. Système de particules élémentaires (Feu, Air, Terre, Eau) capturées dans l'environnement et synthétisées pour le combat et les puzzles. Multijoueur coopératif, serveurs hébergés par les joueurs, progression modulaire, builds atypiques.

---

## Liste des features (par famille)

### Exploration
- Déplacement libre + saut, dimension plateforme façon GW2 (succès d'exploration)
- Puzzles environnementaux basés sur les éléments
- Niveaux vastes façon instances GW1/GW2
- Combats rejoignables à distance sans perdre sa position d'exploration (fluidité)

### Système élémentaire
- Capture de particules élémentaires dans l'environnement
- Synthèse des particules (combinaisons, effets résultants)
- Effets de synthèse variables selon l'arme équipée (couplage avec le système d'équipement)
- Seule "ressource" du jeu — pas de craft/économie séparée

### Combat
- Tour par tour, déplacement libre borné par tour, forte dimension tactique/puzzle (référence **Dofus**)
- Trois archétypes d'armes, chacun avec un mini-jeu propre :
  - **Corps à corps** : système de combo (actions bonus si bien exécuté)
  - **Distance** : mini-jeu de visée façon FPS, ciblage de points faibles
  - **Sans visée (bâton/mage)** : support d'équipe, dégâts/effets de zone. Mécanique précise **non tranchée** — pistes ouvertes : match-3, ou mécanique type "machine à sous" octroyant un élément supplémentaire (plus inclusif question accessibilité que le match-3)
- Ennemis avec zone de patrouille bornée + système d'agressivité (attaque ou non selon proximité)
- **Idée notée — aggro en chaîne** : attaquer un ennemi peut alerter un ennemi proche, qui peut lui-même en alerter un autre en chaîne. Pourrait devenir une caractéristique par type d'ennemi (certains aident leurs semblables, d'autres non). Non tranché, non implémenté — à creuser lors d'une session dédiée à l'IA ennemie/l'agressivité.
- **Hypothèse de fun à deux volets, indissociables** : (1) la dimension tactique doit être bonne en soi, (2) la variété *ressentie* entre archétypes d'armes est indispensable — le jugement final sur le fun du combat ne peut se faire qu'avec au moins deux archétypes en main, pas avec un seul

### Progression / build
- 100% basé sur l'équipement (arme + armure + accessoires), pas d'arbre de compétences séparé
- Changement de gameplay complet selon l'arme équipée — build "libre", peut transformer le perso du tout au tout

### Coop
- Combat : coopératif par nature (tour par tour partagé entre membres du groupe)
- Puzzles : coopération obligatoire sur certains — **question ouverte, non tranchée** (risque de friction pour joueurs solo vs. bénéfice social/bouche-à-oreille)
- Loot individuel (chacun le sien), table de probabilités par ennemi
- Drop "assuré" sur quêtes (items garantis à rendre à un PNJ, distinct du drop aléatoire)
- Pas de vente d'équipement : tout provient exclusivement du drop

### Narration
- Jeu à histoire complexe, personnages récurrents, quêtes annexes
- Checkpoints d'histoire (dialogues/quêtes débloqués selon avancement de l'histoire) — gérés depuis le mode construction

### Mode construction (feature majeure, confirmée)
- Contexte : réintroduit consciemment après avoir été abandonné une première fois (abandon lié à une volonté de "jeu simple" ; réintroduit car le challenge de sa construction est un moteur de motivation pour Julien)
- Portée : **outil avec une vraie portée utilisateur**, à peaufiner — pas un outil jetable pour un seul usage interne
- Usage : construction ET test des niveaux, y compris les énigmes, en conditions réelles
- **Accessible uniquement depuis l'hôte (le serveur)** — décision clé qui simplifie fortement l'implémentation réseau : pas besoin de répliquer les opérations d'édition entre pairs, seulement le résultat (même logique que la synchronisation de position déjà en place). Les autres joueurs en session de test sont de simples clients.
- Couvre à terme : level design (géométrie, placement d'ennemis, zones de patrouille), story design, checkpoints de quêtes/dialogues
- Testable en réseau en temps réel avec d'autres joueurs (pour évaluer le rendu des énigmes à plusieurs)

### Équilibrage / difficulté
- Niveau d'équipement plafonné par zone (garde le challenge, évite le power-creep hors zone)
- Nombre d'ennemis scalé au nombre de joueurs présents dans la zone

### Direction artistique
- Contrainte identifiée : faible niveau en modélisation 3D → besoin d'un style graphique reconnaissable mais tolérant à un rendu peu détaillé
- Pas encore de piste concrète (moodboard à faire plus tard)

### UI
- Écran d'équipement central — potentiellement seule UI de stats nécessaire
- Équipement visible sur le personnage en jeu (pas juste en stats abstraites)

---

## Ordre de priorité retenu

**Principe directeur :** en dev solo sans deadline externe, le risque principal n'est pas le manque de temps sur une feature précise, mais la perte de motivation si le retour ludique/visuel tarde trop. Priorité à ce qui permet de *jouer* au jeu, même en squelette, le plus tôt possible. Cohérent avec la philosophie déjà actée : prototype-first, validation empirique avant complexification.

1. **Systèmes de combat communs** : tour par tour, ordre des joueurs/ennemis, déplacement borné par tour, dimension tactique (positionnement, portée), IA ennemie basique. Testable avec une arme "neutre" minimaliste — sert à construire la mécanique, pas encore à juger le fun.
2. **Deux archétypes d'armes minimum** (a priori corps à corps + un autre). C'est seulement à ce stade qu'un jugement fiable sur le fun du combat (tactique + variété) devient possible — juger sur l'étape 1 seule serait prématuré.
3. **Système d'équipement minimal** (stats + variation de gameplay selon l'arme), pas encore l'écran complet ni les trois archétypes.
4. **Éditeur en version MVP** : placement de géométrie + placement d'ennemis + zones de patrouille. Pas encore les checkpoints d'histoire ni les dialogues. Grossira au fil des besoins concrets, même logique que `tests/test.tscn` côté technique (étoffer au fil de l'eau plutôt que tout prévoir d'avance).

### Repoussé consciemment (pas oublié, juste pas prioritaire)

- Le 3ᵉ mini-jeu d'arme (bâton) et le perfectionnement des deux autres — une fois un archétype validé, ajouter les suivants est un problème connu, pas une inconnue
- Narration structurée et checkpoints dans l'éditeur — dépend d'avoir déjà des niveaux et un besoin senti concrètement
- Équilibrage (scaling ennemis, plafond d'équipement par zone) — n'a de sens qu'une fois qu'il y a quelque chose à équilibrer
- Direction artistique — importante mais non bloquante ; capsules/primitives texturées suffisent pour prototyper
- Coop sur les puzzles — question non tranchée, pas de puzzle construit pour l'instant donc pas urgent à trancher

---

## Architecture des états de jeu (Exploration / Combat / Construction)

Décisions prises en session de design technique (complément direct des sections Combat / Coop / Mode construction ci-dessus) :

- **L'état est par joueur, pas partagé au niveau de l'instance/carte.** Dans une même scène de jeu, un joueur peut rester en exploration pendant qu'un autre est en combat ou que l'hôte est en construction. Ce n'est pas un état global de la carte.
- **Plusieurs combats simultanés sont possibles dans la même instance.** Un joueur peut lancer un combat pendant qu'un autre groupe de joueurs est déjà engagé ailleurs sur la carte, ou reste en exploration.
- **Rejoindre un combat n'est possible qu'en phase de préparation.** Une fois le combat passé en phase "en cours", plus aucun joueur ne peut le rejoindre. Implique qu'un combat a un cycle de vie à au moins deux états (préparation / en cours), géré par un système séparé de la state machine par joueur — voir `CombatManager` ci-dessous.
- **Un `CombatManager` dédié gérera la liste des combats actifs de l'instance** (existence, participants, état préparation/en cours). Non implémenté à ce stade — hors scope de la première session sur les états, qui se limite à la transition d'état par joueur (Exploration/Combat/Construction) sans logique de combat réelle derrière.
- **Le mode construction est un état de l'hôte uniquement**, sans effet sur l'état des autres joueurs présents (ils peuvent continuer d'explorer ou lancer un combat normalement pendant que l'hôte édite). En revanche, toute modification faite par l'hôte en construction (ajout d'un émetteur de particules, d'un monstre dans un groupe de combat, etc.) est immédiatement répliquée chez les clients — un problème de synchronisation de **contenu**, distinct de la state machine par joueur, à traiter avec un mécanisme dédié (probablement dans l'esprit de ce qui existe déjà pour la position/rotation, à préciser lors de l'implémentation réelle du mode construction).

## Questions ouvertes (à trancher dans une session future)

- Mécanique précise du mini-jeu bâton : match-3 vs. "machine à sous" élémentaire vs. autre piste
- Coopération obligatoire sur certains puzzles : oui/non, et si oui, comment éviter la friction pour les joueurs solo
- Direction artistique : style à définir, tolérant à un niveau de modélisation 3D faible
- Portée exacte du mode construction en V1 vs. version finale (le test en réseau temps réel est-il un objectif V1 ou une étape ultérieure, une fois le MVP solo de l'éditeur en place ?)
- **Persistance des niveaux édités** (chargement/sauvegarde) : question soulevée en amont du mode construction — niveau = scène Godot (`PackedScene`) vs. niveau = données pures (`Resource`/JSON). Voir `PROGRESS.md` § Idées notées pour le détail des deux pistes. À trancher lors de la session dédiée au mode construction.

## Choix de conception assumés (rappel)

- **Pas de validation serveur du mouvement/anti-triche** : décision actée, pas un TODO oublié. Synterra est pensé pour être joué en coopératif entre amis, non compétitif — le risque de triche n'est pas une priorité. Le pattern réseau en place permet d'ajouter cette validation plus tard sans tout repenser, si le contexte du jeu change (ex. ouverture à un public plus large).
