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
- `AudioCueManager` (`@MainActor`) — session audio, vocabulaire sonore et ducking.
- `ExerciseCatalog` — suggestions de noms d'exercices. Constante (catalogue intégré) +
  noms personnels **recalculés à la volée** depuis les séances : aucune entité SwiftData.
- Vues : `WorkoutListView` → `WorkoutEditorView` → `RunView`, + `HistoryView`.

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
audio tierce active (Spotify), un appel peut bloquer plusieurs centaines de ms. Toutes les
mutations de session passent donc par `AudioCueManager.sessionQueue`, une file série dédiée
— **ne jamais les ramener sur le main thread** : elles y gèleraient le `RunLoop`, donc le
`Timer` 20 Hz de `TimerEngine`, ce qui décale ou fait sauter des bips du décompte.

## Conventions
- Une vue par fichier. Sous-vues privées dans le même fichier si petites.
- Pas de logique métier dans les vues : elle vit dans `TimerEngine` / managers.
- Nommer explicitement (pas d'abréviations cryptiques).

## Build / run
- Ouvrir dans Xcode, cible simulateur iPhone.
- Serveur MCP **xcodebuild** (XcodeBuildMCP) configuré : build, install, lancement,
  logs, captures et automatisation d'UI sur simulateur passent par ses outils plutôt
  que par des appels `xcodebuild`/`simctl` à la main.
- **iOS Deployment Target = 26.4** (Build Settings).
- **Ne pas activer Background Modes → Audio** (cf. note 2.5.4 ci-dessous).
- L'app est en production : toute évolution de schéma SwiftData doit être testée en
  *upgrade* (installer la version précédente, créer des données, installer par-dessus sans
  désinstaller), pas seulement en installation neuve.

## Release avec fastlane
`fastlane` (Homebrew) pilote la chaîne App Store. Le repo est la **source de vérité** des
métadonnées et des captures ; App Store Connect n'est plus saisi à la main.

| Lane | Fait quoi |
|---|---|
| `fastlane screenshots` | capture les 5 écrans sur simulateur → `fastlane/screenshots/fr-FR/`, recopie vers `en-US/` |
| `fastlane pull` | rapatrie les métadonnées **publiées** depuis ASC — **écrase** `fastlane/metadata/` |
| `fastlane bump` | `CURRENT_PROJECT_VERSION` = dernier build sur ASC + 1 |
| `fastlane build` | archive Release + export `.ipa` signé app-store dans `build/` |
| `fastlane beta` | `bump` + `build` + upload TestFlight |
| `fastlane verify` | **DRY-RUN** : `Preview.html` (ce qui serait poussé) + precheck des motifs de rejet |
| `fastlane status` | lecture seule : version live, version en préparation, app info éditable |
| `fastlane fix_listing` | corrige les textes de la version **déjà publiée** (champ très étroit, voir plus bas) |
| `fastlane release` | push métadonnées + captures + **soumission pour revue** |

Ordre d'une release : `screenshots` → `beta` → **test sur iPhone réel** → `verify` →
`release`. Le gate device n'est pas optionnel : le rejet 2.5.4 est passé au travers d'un
audit statique au vert et d'un build Release qui compilait (cf. section ci-dessous).

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
