# CLAUDE.md — TempoHIIT

Contexte de projet pour Claude Code. À lire en début de chaque session.

## Le projet
App iOS native (SwiftUI) : un **timer d'intervalles / HIIT**. 100% local, pas de backend.
Réimplémentation *from scratch* inspirée fonctionnellement de "Interval Timer - HIIT Timer"
(Perigee) — design, nom et assets sont les nôtres, on ne copie aucun code ni identité visuelle.

## Stack & contraintes
- **SwiftUI**, cible **iOS 26+** (Liquid Glass, glassEffect, Tab struct, tabBarMinimizeBehavior).
- Patterns modernes : `@Observable` (pas `ObservableObject`), **SwiftData** pour la
  persistance, **Swift Charts** pour les stats.
- Pas de dépendances externes. Si besoin de modulariser : Swift Packages locaux.
- Audio : **AVFoundation** (`AVAudioSession` en `.playback` + `.mixWithOthers`,
  `AVAudioPlayer` sur des tons générés à la volée). Pas d'`AVSpeechSynthesizer`.

## Profil du dev
- Senior **Python**, découvre **SwiftUI**. Explique les idiomes Swift/SwiftUI nouveaux pour
  lui (optionals, property wrappers, `some View`, value vs reference types) quand pertinent —
  mais sans condescendance, il sait coder.
- Communication : **français**, réponses **concises et structurées**.

## Architecture
- `TimerEngine` (`@MainActor @Observable`) — logique cœur : déroule un tableau plat de
  `Step` construit dans l'`init` à partir du `Workout`, tick à 20 Hz, état
  (`idle/running/paused/finished`). **Le temps se calcule par différence de `Date`, jamais
  par accumulation de ticks** (immunise contre la dérive en arrière-plan ; la boucle de
  fast-forward de `tick()` rattrape les segments écoulés au retour en avant-plan).
  Le tick **n'est plus l'horloge des cues** (v1.5) : il ne fait que lancer, à T-4, la queue
  du segment — un buffer pré-rendu où le rythme est déjà gravé.
- `AudioCueManager` (`@MainActor`) — session audio, vocabulaire sonore et ducking.
- `ExerciseCatalog` — suggestions de noms d'exercices. Constante (catalogue intégré) +
  noms personnels **recalculés à la volée** depuis les séances : aucune entité SwiftData.
- `WorkoutSuggestions` — les « Suggestions du chef » : 5 séances toutes prêtes, constante
  non persistée. Proposées dans le menu du bouton `+` de `WorkoutListView` (v1.7) ; une
  suggestion ajoutée devient une séance ordinaire et disparaît du menu.
- Vues : `WorkoutListView` → `WorkoutEditorView` → `RunView`, + `HistoryView`.
  `OnboardingView` s'intercale à la racine au premier lancement (cf. « Onboarding »).

## Modèle de données
Modèle **plat** (pas de liste de segments éditable) : une séance est six nombres.

- `Workout { name, createdAt, prepareSeconds, workSeconds, restSeconds, sets, rounds, resetSeconds, exerciseNames }`
  — `@Model` SwiftData. `prepareSeconds` (défaut 10) = mise en place avant le 1er effort ;
  `resetSeconds` = récupération **entre** rounds. `restSeconds` et `resetSeconds` peuvent
  valoir 0 : le step correspondant n'est alors pas construit.
- `exerciseNames: [String]` (v1.2) = noms des exercices, **table creuse** : sa longueur est
  indépendante de `sets`, qui reste la source de vérité du nombre d'exercices. Entrée vide ou
  manquante = non nommé, lire via `exerciseName(at:)`. SwiftData le persiste en blob
  `NSKeyedArchiver`, donc non requêtable — sans importance ici. Les noms valent pour tous les
  rounds, un round ne rejoue pas une liste différente.
- `WorkoutRun { workoutName, startedAt, completedAt, totalSeconds }` ← historique.
  `workoutName` est dénormalisé (pas de relation vers `Workout`).
- `TimerEngine.Step { phase, durationSeconds, round, setIndex, exerciseName }` avec
  `Phase { prepare, work, rest, reset }` (+ couleur, symbole, label, `startCue`) — modèle
  interne au moteur, jamais persisté.

Le conteneur SwiftData est construit explicitement dans `HIIT974App` avec un repli
`do/catch` : en cas d'échec de migration, le store est archivé et l'app repart sur un store
neuf plutôt que de trapper au lancement.

## Vocabulaire sonore
Aucune synthèse vocale (retirée en v1.1). Tous les cues sont des tons sinus générés à la
volée en WAV PCM (`AudioCueManager.Cue`) : aigu = effort, grave = récupération.

| Cue | Son | Quand |
|---|---|---|
| `.countdown` | 880 Hz, 100 ms | T-3 / T-2 / T-1 de chaque segment |
| `.halfway` | 660 Hz ×2 | moitié d'une phase d'**effort** (sauf si la moitié tombe dans le décompte) |
| `.startPrepare` / `.startWork` / `.startRest` | 660 / 880 / 440 Hz, 600 ms | transition de phase |
| `.finished` | 660 → 880 → 1320 Hz | fin de séance |

**Ducking** : la session est en `.playback + .mixWithOthers` par défaut et bascule en
`.duckOthers` (qui implique déjà `.mixWithOthers`) le temps du cue, via
`beginDucking()` / `endDuckingAfter(_:)`. Le délai de relâche doit rester **supérieur** à la
durée du cue, sinon `setActive(false)` le coupe net — **et supérieur à l'intervalle jusqu'au
cue suivant** quand des cues s'enchaînent. Sur le décompte (un bip par seconde), un délai
de 1,0 s pile faisait tomber le relâchement exactement sur le bip suivant : aller-retour
atténue/rend à chaque seconde, pompage audible et bip joué avant que l'atténuation ne soit
en place. Avec la marge, le `beginDucking()` suivant annule le relâchement en attente et
l'atténuation tient d'une traite de T-3 jusqu'au bip de transition.

`setCategory` / `setActive` sont des IPC **synchrones** vers `mediaserverd` : avec une app
audio tierce active (Spotify), un appel peut bloquer plusieurs centaines de ms.
`AVAudioPlayer.play()` emprunte le même chemin et coûte tout aussi cher. Toutes ces
commandes passent donc par `AudioCueManager.sessionQueue`, une file série dédiée —
**ne jamais les ramener sur le main thread**, elles y gèleraient le `RunLoop`.

**Invariant central (v1.5) : le timing des cues ne dépend pas du main thread.** Sortir les
IPC du main thread (v1.3) ne suffisait pas — il restait tout le reste (le rendu de `RunView`
à 20 Hz, alourdi par l'anneau pleine largeur de la v1.4) pour retarder un tick, et donc un
bip.

La solution n'est pas de mieux piloter quatre sons, c'est de n'en avoir qu'un. Le décompte
3-2-1 **et** le bip de transition sont un **seul buffer pré-rendu** de quatre secondes — les
`Cue` de queue (`tailToWork`, `tailToRest`, `tailToPrepare`, `tailToFinish`, une variante par
phase annoncée). L'espacement des bips n'est pas quelque chose qu'on demande à une horloge :
il est **gravé dans les échantillons**. Une fois `play()` lancé, le hardware les consomme à
cadence fixe quoi qu'il arrive au CPU ; la dérive est physiquement impossible.

`AudioCueManager.tailLead` (4 s) est le contrat entre les deux fichiers : la position `p`
dans le buffer vaut exactement `timeRemaining == tailLead - p`. D'où le rattrapage, qui tient
en un paramètre : si le tick arrive en retard, `TimerEngine` entre d'autant plus loin dans le
buffer (`play(_:from:)`) au lieu de décaler tout le rythme. Un retour d'arrière-plan qui
dépose à T-2 saute naturellement le bip de T-3, sans cas particulier. Mesuré sous un blocage
volontaire de 600 ms du main thread : les ancres de queues successives restent à ±7 ms de la
durée de segment.

Ce contrat est **vérifié à l'exécution** : `assertTailContract()` (DEBUG, appelé par
`configure()`) contrôle que dans chaque queue le bip de transition démarre pile à `tailLead`.
Retoucher la géométrie du décompte — `Cue.countdownBeeps`, `tailLead`, l'espacement — sans
relire `startSegmentTailIfNeeded()` désalignerait sinon tout le son en silence. Ici, ça casse
au lancement.

Deux conséquences à ne pas oublier :

- **Toute rupture du déroulé doit couper le son** (`stopAll()`, via
  `TimerEngine.interruptCues()`) : pause, stop, skip, previous, interruption système. Une
  queue dure quatre secondes et contient le bip de transition — elle continuerait sinon toute
  seule, séance arrêtée.
- **À l'inverse, une frontière de segment normale ne doit rien couper** : le bip de
  transition est justement en train de sortir. `TimerEngine.tailStarted` sert à ne pas le
  rejouer par-dessus via `cueSegmentStart()`.

Le ducking est armé **avant** de lancer la queue : sur `sessionQueue` la reconfiguration
passe donc en premier, et le silence de tête du buffer lui laisse le temps d'atterrir avant
le premier bip. Une seule relâche couvre tout le buffer.

Interruptions (appel, Siri) et changements de route (AirPods) désactivent la session et
coupent la queue en cours, silencieusement. `AudioCueManager` les observe, reconstruit session
et players — **sur `sessionQueue`**, car ça arrive en pleine séance et préparer les players
sur le main thread y gèlerait le `Timer` — et prévient le moteur via `onSessionReset`, qui
relance la queue au bon endroit du buffer.

**Ce qui a été essayé avant, et pourquoi c'est parti** : une première v1.5 planifiait les
quatre sons séparément sur l'horloge du périphérique (`AVAudioPlayer.play(atTime:)`). Ça
marchait — mesuré à 1000,0000 ms d'écart — mais au prix d'un pool de players (un
`AVAudioPlayer` ne porte qu'un `play(atTime:)` en attente), d'une sonde à deux échantillons
pour vérifier que `deviceCurrentTime` avance vraiment, et d'un repli piloté par le tick quand
elle n'avançait pas — repli qui réintroduisait le bug d'origine. Le buffer pré-rendu supprime
tout ça d'un coup : il ne dépend d'aucune horloge, donc ni sonde, ni repli, ni pool. Ne pas
réintroduire de planification par instants.

**Diagnostic** : toute mesure du timing audio doit être prise **sur `sessionQueue`**, jamais
depuis le main actor. Une première sonde s'appuyait sur `audioPlayerDidFinishPlaying` : ce
callback est délivré sur le main thread, donc elle mesurait le retard de livraison du callback
et non l'espacement du son — confondue par la variable même qu'on caractérisait, et
génératrice de fausses alertes en production. `play(_:from:)` journalise donc, depuis la file,
l'**ancre** de chaque cue : `deviceCurrentTime - offset`, soit l'instant où la queue aurait
démarré si le tick était tombé pile. Deux ancres consécutives séparées d'une durée de segment
exacte = le rattrapage fonctionne. En `notice` DEBUG ; le coût des IPC de session est tracé
au-delà de 50 ms, toujours actif.

**Reproduire le bug** : `-audioStress` (DEBUG) bloque le main thread 600 ms toutes les 1,3 s —
période volontairement désaccordée de la seconde du décompte, pour qu'elle précesse et tombe
dans toutes les phases. `-audioTickCountdown` rejoue l'ancien comportement, un bip par tick :
c'est **uniquement un harnais de mesure**, aucune condition de production n'y mène. Les deux
ensemble rejouent le bug (5 écarts sur 8 hors tolérance, min 399 ms — des secondes
littéralement collées) ; le premier seul montre le fix.

## Conventions
- Une vue par fichier. Sous-vues privées dans le même fichier si petites.
- Pas de logique métier dans les vues : elle vit dans `TimerEngine` / managers.
- Nommer explicitement (pas d'abréviations cryptiques).

## Build / run
- Ouvrir dans Xcode, cible simulateur iPhone.
- Serveur MCP **xcodebuild** (XcodeBuildMCP) configuré : build, install, lancement,
  logs, captures et automatisation d'UI sur simulateur passent par ses outils plutôt
  que par des appels `xcodebuild`/`simctl` à la main.
- **iOS Deployment Target = 26.4** (Build Settings). Conséquence pour le simulateur :
  plusieurs runtimes portent un « iPhone 17 », et viser le simulateur **par son nom**
  résout sur le plus ancien (iOS 26.0), qu'`xcodebuild` rejette ensuite en
  « Unable to find a destination matching ». Viser par **UDID** (`list_sims`).
- **Ne pas activer Background Modes → Audio** (cf. note 2.5.4 ci-dessous).
- L'app est en production : toute évolution de schéma SwiftData doit être testée en
  *upgrade* (installer la version précédente, créer des données, installer par-dessus sans
  désinstaller), pas seulement en installation neuve.

## Release avec fastlane
`fastlane` (Homebrew) pilote la chaîne App Store. Le repo est la **source de vérité** des
métadonnées et des captures ; App Store Connect n'est plus saisi à la main.

| Lane | Fait quoi |
|---|---|
| `fastlane screenshots` | capture les 5 écrans sur simulateur → `fastlane/screenshots/fr-FR/`, puis en recopie 4, réduites, dans `Assets.xcassets` pour l'onboarding |
| `fastlane pull` | rapatrie les métadonnées **publiées** depuis ASC — **écrase** `fastlane/metadata/` |
| `fastlane bump` | `CURRENT_PROJECT_VERSION` = dernier build sur ASC + 1 |
| `fastlane build` | archive Release + export `.ipa` signé app-store dans `build/` |
| `fastlane beta` | `bump` + `build` + upload TestFlight |
| `fastlane verify` | **DRY-RUN** : `Preview.html` (ce qui serait poussé) + precheck des motifs de rejet |
| `fastlane status` | lecture seule : version live, version en préparation, app info éditable |
| `fastlane screenshots_status` | lecture seule : compte les captures en ligne, signale les doublons |
| `fastlane withdraw` | retire la version en préparation de la file de revue Apple |
| `fastlane dedupe_screenshots` | supprime les captures en double sur la version en préparation |
| `fastlane fix_listing` | corrige les textes de la version **déjà publiée** (champ très étroit, voir plus bas) |
| `fastlane release` | push métadonnées + captures + **soumission pour revue** |

Ordre d'une release : `screenshots` → `beta` → **test sur iPhone réel** → `verify` →
`release`. Le gate device n'est pas optionnel : le rejet 2.5.4 est passé au travers d'un
audit statique au vert et d'un build Release qui compilait (cf. section ci-dessous).

**Deux textes à réécrire avant chaque `release`**, et ils se comportent pareil : ASC
recopie sur la nouvelle version ce que portait la précédente, donc les oublier ne laisse
pas un champ vide — ça republie silencieusement le texte de la version d'avant.

1. `fastlane/metadata/fr-FR/release_notes.txt` — les notes publiques, entièrement.
2. Le seul paragraphe `WHAT'S NEW IN <version>` de
   `fastlane/metadata/review_information/notes.txt` (champ « Remarques » d'ASC, dans
   « Informations utiles à la vérification de l'app »). **Tout le reste de ce fichier est
   stable** — absence de compte, de réseau et de permissions, section audio / 2.5.4, mode
   d'emploi, glossaire français — et ne se retouche pas. C'est justement parce que ce
   paragraphe est le seul texte daté d'un fichier qui ne bouge jamais que rien ne rappelle
   d'y toucher : il était resté en « WHAT'S NEW IN 1.4 » lors de la soumission de la 1.5.
   Sans gravité (rien de faux n'y était, et la section audio restait exacte), mais le
   reviewer a lu la version précédente. `deliver` repousse ce fichier à **chaque**
   release : ce qui est dans le repo part chez Apple, à jour ou non.
   Exception à « stable » : le mode d'emploi (`HOW TO TEST`) décrit le parcours réel. Dès
   qu'une version change ce parcours, il devient faux s'il n'est pas réécrit — c'est
   arrivé en 1.6 (seed retiré) et en 1.7 (onboarding, suggestions passées dans le `+`).
   Plafond Apple : **4000 caractères** pour tout le fichier.

- **Authentification** : clé API App Store Connect (`.p8`), jamais l'Apple ID. Les trois
  valeurs vivent dans `fastlane/.env`, git-ignoré — voir `fastlane/.env.example`. Ne
  jamais committer le `.p8` ni les IDs.
- **`MARKETING_VERSION`** (ex. 1.4) reste piloté à la main dans Xcode : c'est une décision
  produit. Seul le build number est automatisé.
- **`VERSIONING_SYSTEM = apple-generic`** est requis dans les Build Settings, sinon
  `increment_build_number` échoue (`agvtool` ne sait pas où écrire).
- `deliver` ne pousse **que les fichiers présents** dans `fastlane/metadata/<locale>/` :
  un champ sans fichier local reste intact en ligne. D'où `pull` avant toute modification.
- **La fiche n'existe qu'en `fr-FR`** sur ASC : `pull` ne ramène rien pour `en-US`, et
  `Preview.html` ne liste que le français. Attention, un dossier de locale dans
  `fastlane/metadata/` n'est pas inerte : `deliver` déduit les langues à publier des
  dossiers présents (`detect_languages`), puis `verify_available_version_languages!`
  **crée** sur ASC celles qui manquent. Le `fastlane/metadata/en-US/release_notes.txt`
  qui traînait dans le repo aurait donc ouvert une fiche anglaise sans description, que
  la validation Apple refuse — il a été supprimé, comme le miroir `screenshots/en-US/`
  (`MIRROR_LOCALES` est vide). Ouvrir une langue se fait métadonnées traduites en main.
- Deux options ne sont pas cosmétiques, elles conditionnent le fonctionnement :
  `download_metadata` **exige `--force`** (sans TTY il ne pose pas sa question de
  confirmation et sort silencieusement en `return 0`, sans rien écrire ni signaler) ;
  `check_app_store_metadata` **exige `include_in_app_purchases: false`** (precheck ne sait
  pas inspecter les achats intégrés avec une clé API et échoue sinon).
- `verify_only` de `upload_to_app_store` porte sur le **binaire**, pas sur les textes : ce
  n'est pas un dry-run de métadonnées. D'où `deliver generate_summary` dans `verify`, qui
  écrit `Preview.html` **à la racine du repo** (git-ignoré) sans rien envoyer.
- **Le repo est public** : dans `fastlane/metadata/review_information/`, seuls les quatre
  fichiers d'identité du contact de revue (nom, prénom, e-mail, téléphone) sont
  git-ignorés. Ils vivent sur ASC, `pull` les régénère. `notes.txt` — la note au
  reviewer, longue et écrite à la main — est versionné : il ne contient rien de perso.
- Les captures sont poussées dans l'**ordre alphabétique** des noms de fichiers : la
  numérotation `01-…` à `05-…` encode l'ordre marketing de la fiche.
- **`release` peut laisser chaque capture en double — vérifier après coup.** Après
  l'envoi, `deliver` contrôle que les captures sont bien arrivées en appariant les
  fichiers locaux à ceux d'ASC par leur `source_file_checksum`, que l'API ne renseigne
  qu'**après coup, de façon asynchrone**. Interrogée trop tôt, elle répond « aucune » :
  deliver conclut à un échec et rejoue l'envoi. Or son nettoyage de reprise n'efface
  que les captures pas encore `complete?` — les premières, déjà traitées, survivent, et
  le second envoi s'ajoute. Chaque écran se retrouve en double, plafonné à 10 par set
  par le garde-fou `< 10`. C'est arrivé sur la 1.4.1 le 2026-08-28. Le log le dit, à
  condition de repérer la ligne rouge `… is missing on App Store Connect` suivie de
  `Tries remaining` au milieu des lignes vertes. **Réflexe : `fastlane
  screenshots_status` après chaque `release`.** Réparation : `withdraw` (l'édition des
  captures est verrouillée en `WAITING_FOR_REVIEW`), `dedupe_screenshots`, puis
  `release skip_screenshots:true` — renvoyer les mêmes fichiers rejouerait la course.
- **Corriger la fiche d'une version déjà en vente est presque impossible.** Une fois la
  version `READY_FOR_SALE` et aucune version en préparation, `release` n'a pas de cible :
  ASC n'accepte de nouveaux textes que sur une version éditable. `fix_listing`
  (`edit_live: true`) vise la version en vente, mais deux limites se cumulent :
  `deliver` n'y écrit que `LOCALISED_LIVE_VALUES` — description, notes de version,
  URLs, texte promotionnel, copyright : **ni nom, ni sous-titre, ni mots-clés, ni
  captures** ; et `upload_metadata.rb` appelle `fetch_edit_app_info` **avant** de
  brancher sur `edit_live`, donc sans version en préparation il boucle en backoff
  exponentiel puis abandonne. Vérifier avec `fastlane status` avant d'essayer.
  Conséquence pratique : nom, sous-titre et mots-clés ne changent qu'en soumettant une
  nouvelle version — et une version a besoin d'un build neuf, un build déjà publié ne
  se réutilise pas. Le chemin est donc `MARKETING_VERSION` à la main → `beta` →
  device → `verify` → `release`.
- `capture-screenshots.sh` n'est pas dans le repo : il est porté par la command
  `/appstore-prep` (`~/.claude/appstore-prep/scripts/`), que la lane `screenshots`
  résout automatiquement. Les écrans à capturer, eux, sont décrits dans
  `scripts/appstore/screenshots.config.json`.

Restent manuels par nature : la génération de la clé API (une fois, GUI Apple), le choix
de la version marketing et la rédaction des notes, le test sur device, et la revue Apple.

## État courant
- [x] Jalon 0 — setup projet + navigation
- [x] Jalon 1 — éditeur de séance (données mockées)
- [x] Jalon 2 — moteur de timer + écran run
- [x] Jalon 3 — audio (cues en avant-plan uniquement — voir note 2.5.4 ci-dessous)
- [x] Jalon 4 — persistance SwiftData
- [x] Jalon 5 — couleurs de phase
- [x] Jalon 6 — historique + stats
- [x] Jalon 7 — polish
- [x] Jalon 8 — visual parity Interval Timer + iOS 26
- [x] v1.1 (build 3) — repos optionnel à 0 s, préparation réglable (défaut 10 s), signal de
      mi-effort, bips longs par phase à la place de la voix, ducking de la musique pendant
      les cues, édition d'une séance rendue trouvable (swipe trailing + menu contextuel),
      écran maintenu allumé pendant la séance, conteneur SwiftData résilient.
- [x] v1.2 (build 4) — noms d'exercices personnalisables : saisie libre ou choix dans un menu
      (catalogue intégré de ~42 exercices en 5 catégories + noms déjà utilisés ailleurs). Le
      nom s'affiche dans le badge de `RunView` et dans la ligne « Ensuite », le libellé de
      phase restant sous le chrono. Migration vérifiée depuis un vrai store 1.1.
- [x] v1.3 (build 5) — décompte fiable quand une app audio tierce (Spotify) est active :
      le ducking n'est plus relâché entre les bips du décompte, et toutes les mutations
      d'`AVAudioSession` sont sorties du main thread.
- [x] v1.4 (build 6) — `RunView` lisible à distance : l'anneau occupe toute la largeur
      disponible et toutes les tailles de texte de l'écran de séance en découlent.
      Cf. « Typographie de RunView » ci-dessous.
- [x] v1.4.1 (build 7) — **aucun changement de code**. Version créée pour porter la fiche
      App Store corrigée (nom « HIIT 974 », sous-titre, mots-clés, description réécrite),
      qu'ASC refusait d'accepter sur la 1.4 déjà en vente. Soumise le 2026-08-28.
- [x] v1.5 (build 8) — décompte immunisé contre la charge du main thread : le 3-2-1 et le
      bip de transition sont un seul buffer pré-rendu de 4 s, lancé à T-4, au lieu de quatre
      sons joués par le tick 20 Hz. S'y ajoutent : ducking armé avant la queue, préparation
      des players sortie du main thread, interruptions et changements de route de session
      enfin gérés, et `RunView` allégé (chrono sur `displayedSeconds`, anneau isolé dans sa
      propre `View`). Remonté par un utilisateur iPhone 11 / iOS 26.1.1 sur la 1.4.1, avec
      Spotify actif. Soumise le 2026-09-02, captures non renvoyées
      (`release skip_screenshots:true`) : ASC recopie celles de la version
      précédente, et ne rien envoyer supprime la course qui les avait dupliquées.
- [x] v1.6 (build 10) — les deux séances auto-insérées au premier lancement sont
      remplacées par un dossier « Suggestions du chef » (5 séances, ajout d'un tap).
      Nettoyage ponctuel des anciennes séances par défaut, seulement si tous leurs champs
      sont restés identiques (`WorkoutSuggestions.isLegacySeed`, clé
      `legacySeedCleanupDone`).
- [x] v1.6.1 (build 11) — l'exercice suivant s'affiche dans un badge aussi grand que
      l'exercice en cours. En vente depuis (vérifié par `fastlane status` le 2026-10-09).
- [ ] v1.7 — onboarding en 5 pages illustrées de vraies captures (montré aussi aux
      utilisateurs existants), suggestions du chef déplacées dans le menu du bouton `+`.
      Au passage : le graphique de la capture `05-historique.png`, vide en ligne depuis
      la 1.6, est rempli (historique de démo réinitialisé sous `-screenshotHistory`).
      Vérifié sur simulateur, y compris en mise à jour depuis la 1.6.1. **Reste** :
      `beta` → test sur iPhone réel → `verify` → `release`.

> **Onboarding (v1.7)** : `OnboardingView`, 5 pages en `TabView(.page)`.
> - **Déclenchement** : `@AppStorage("onboardingVersionSeen") < OnboardingView.currentVersion`,
>   évalué dans `HIIT974App`. Les installations antérieures n'ont pas la clé, elle vaut
>   donc 0 : elles voient l'onboarding comme les nouvelles, sans code dédié. Monter
>   `currentVersion` le remontre à tout le monde.
> - **Bascule à la racine** du `WindowGroup` (if/else + `.animation(value:)`), pas un
>   `fullScreenCover` : pas d'animation de montée au lancement, et `WorkoutListView` n'est
>   pas monté dessous (son `onAppear`, donc le nettoyage legacy, attend la fin).
> - **Captures** : les imagesets `onboarding-run/-list/-editor/-history` sont écrits par
>   la lane `screenshots` (`ONBOARDING_SCREENSHOTS` dans le `Fastfile`). Ne pas les
>   retoucher à la main. Les repères pulsants sont des `CGRect` **normalisés**, mesurés
>   sur les PNG 1320×2868 : si la mise en page d'un de ces écrans bouge, les recaler dans
>   `OnboardingView.pages`, sinon l'anneau entoure le vide.
> - **DEBUG** : tout argument `-screenshot*` désactive l'onboarding (le script de captures
>   part d'un simulateur vierge, il recouvrirait les 5 écrans) ; `-showOnboarding` efface
>   la clé au lancement ; `-onboardingPage N` ouvre la page N.
> - Contraste : pas de verre sur les boutons. Sur ces fonds vifs, il tourne au pastel et
>   le blanc n'y est plus lisible. Le bouton principal est blanc plein, avec la couleur
>   de la page assombrie de 40 % (`mix(with: .black, by: 0.4)`).

> **Note API** : `.textInputSuggestions` (autocomplétion sous un `TextField`) est
> `@available(iOS, unavailable)` — macOS 15 uniquement. Le menu de suggestions est donc
> construit à la main avec des `Menu` imbriqués, qui se rendent en sous-menus natifs.
> Dans une ligne de `Form`, un `Menu` voisin d'un `TextField` **doit** porter
> `.buttonStyle(.borderless)`, sinon il capte le tap de toute la ligne.

> **Typographie de `RunView` (v1.4)** : l'écran de séance doit se lire **le téléphone
> posé par terre**. À 3 m il faut ~15 mm de hauteur de capitale, soit ~140 pt de police
> (1 pt ≈ 0,156 mm sur iPhone) — impossible sans supprimer l'anneau, qui reste la
> signature visuelle du Jalon 8. Compromis retenu : l'anneau prend toute la largeur, et
> **c'est son diamètre qui dérive toutes les tailles** (`ringTimer(diameter:)`), donc la
> distance de lecture. Sur iPhone 16 Pro : anneau ~353 pt, chrono ~113 pt (cap ≈ 11,6 mm,
> confortable à ~2,3 m). Deux pièges :
> - Le tracé d'un `Circle().stroke()` **déborde du frame de la moitié de son épaisseur** :
>   sans l'intégrer au calcul du diamètre, l'anneau mord les bords de l'écran.
> - Le chrono est inscrit dans le cercle : il tient dans une **corde**, pas dans le
>   diamètre (d'où le `frame(width: diameter * 0.74)`). Le `minimumScaleFactor` ne sert
>   qu'au cas « 10:00 », cinq caractères au lieu de quatre.
>
> Les tailles sont **fixes**, pas des styles Dynamic Type : elles sont déjà bien au-delà
> de ce que produirait n'importe quel réglage système, et la mise en page ne survivrait
> pas aux tailles d'accessibilité.

> **Jalon 8 décisions** :
> - RunView : fond plein écran couleur segment, anneau circulaire, glassEffect iOS 26 sur contrôles
> - WorkoutEditorView : barre de prévisualisation proportionnelle (`ProportionBar`)
> - WorkoutListView : mini-barre proportionnelle dans les lignes (1 round, sans prépa)
> - HIIT974App : nouveau Tab struct (iOS 18) + tabBarMinimizeBehavior (iOS 26)
> - Déploiement minimum relevé iOS 17 → iOS 26

## ⚠️ Pas de background audio (rejet App Store 2.5.4)

L'app a été **rejetée** en guideline 2.5.4 : `UIBackgroundModes: audio` était déclaré
sans feature nécessitant de l'audio *persistant*. **Le reviewer avait raison.**

Les cues sont uniquement ponctuels (bip de 100 ms sur les 3 dernières secondes, annonce
vocale aux transitions). Le mode `audio` ne maintient l'app vivante que *pendant* une
lecture effective : entre deux sons, iOS suspendait l'app. Écran verrouillé, **aucun bip
ne partait jamais** — le fast-forward dans `TimerEngine.tick()` ne fait que rattraper
l'état au retour en avant-plan. Le « arrière-plan » du Jalon 3 n'a jamais fonctionné.

`UIBackgroundModes` et tout `MediaPlayer` (Now Playing, remote commands) ont été retirés.
**Ne pas les réintroduire** sans jouer un flux audio réellement continu.

Pour les cues écran verrouillé (v1.1) : notifications locales pré-planifiées (plafond
**64** en attente) + Live Activity. **AlarmKit est inadapté aux transitions** — chaque
alarme est une alerte à rejeter manuellement, sans chaînage automatique. Et sans exécution
en arrière-plan, le libellé de phase d'une Live Activity ne peut pas changer tant que
l'app est suspendue : seul `Text(timerInterval:)` s'anime tout seul.
