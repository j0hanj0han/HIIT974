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
- Vues : `WorkoutListView` → `WorkoutEditorView` → `RunView`, + `HistoryView`.

## Modèle de données
Modèle **plat** (pas de liste de segments éditable) : une séance est six nombres.

- `Workout { name, createdAt, prepareSeconds, workSeconds, restSeconds, sets, rounds, resetSeconds }`
  — `@Model` SwiftData. `prepareSeconds` (défaut 10) = mise en place avant le 1er effort ;
  `resetSeconds` = récupération **entre** rounds. `restSeconds` et `resetSeconds` peuvent
  valoir 0 : le step correspondant n'est alors pas construit.
- `WorkoutRun { workoutName, startedAt, completedAt, totalSeconds }` ← historique.
  `workoutName` est dénormalisé (pas de relation vers `Workout`).
- `TimerEngine.Step { phase, durationSeconds, round, setIndex }` avec
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
durée du cue, sinon `setActive(false)` le coupe net.

## Conventions
- Une vue par fichier. Sous-vues privées dans le même fichier si petites.
- Pas de logique métier dans les vues : elle vit dans `TimerEngine` / managers.
- Nommer explicitement (pas d'abréviations cryptiques).

## Build / run
- Ouvrir dans Xcode, cible simulateur iPhone.
- **iOS Deployment Target = 26.4** (Build Settings).
- **Ne pas activer Background Modes → Audio** (cf. note 2.5.4 ci-dessous).
- L'app est en production : toute évolution de schéma SwiftData doit être testée en
  *upgrade* (installer la version précédente, créer des données, installer par-dessus sans
  désinstaller), pas seulement en installation neuve.

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
