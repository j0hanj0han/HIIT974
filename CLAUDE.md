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
  `AVSpeechSynthesizer` pour la voix).

## Profil du dev
- Senior **Python**, découvre **SwiftUI**. Explique les idiomes Swift/SwiftUI nouveaux pour
  lui (optionals, property wrappers, `some View`, value vs reference types) quand pertinent —
  mais sans condescendance, il sait coder.
- Communication : **français**, réponses **concises et structurées**.

## Architecture cible
- `TimerEngine` (`@Observable`) — logique cœur : séquence de segments, tick, état
  (`idle/running/paused/finished`). **Le temps se calcule par différence de `Date`, jamais
  par accumulation de ticks** (immunise contre la dérive en arrière-plan).
  Prepend automatique d'un segment `.prepare` si `workout.prepareSeconds > 0`.
- `AudioCueManager` — encapsule la session audio et les annonces.
- Vues : `WorkoutListView` → `WorkoutEditorView` → `RunView`, + `HistoryView`.

## Modèle de données
- `SegmentKind { prepare, work, rest, cooldown }` (+ couleur)
- `Segment { id, kind, label, durationSeconds }`
- `Workout { id, name, createdAt, rounds, prepareSeconds, segments }`
- `WorkoutRun { id, workoutId, startedAt, completedAt, totalSeconds }`  ← historique

## Conventions
- Une vue par fichier. Sous-vues privées dans le même fichier si petites.
- Pas de logique métier dans les vues : elle vit dans `TimerEngine` / managers.
- Nommer explicitement (pas d'abréviations cryptiques).

## Build / run
- Ouvrir dans Xcode, cible simulateur iPhone.
- **iOS Deployment Target → 26.0** (Build Settings).
- Background Modes → Audio à activer dans les capabilities.
- Si crash SwiftData au 1er lancement après ajout de `prepareSeconds` :
  supprimer l'app sur le simulateur (données), puis ⌘R.

## État courant
- [x] Jalon 0 — setup projet + navigation
- [x] Jalon 1 — éditeur de séance (données mockées)
- [x] Jalon 2 — moteur de timer + écran run
- [x] Jalon 3 — audio + arrière-plan + écran verrouillé
- [x] Jalon 4 — persistance SwiftData
- [x] Jalon 5 — drag-to-reorder + couleurs
- [x] Jalon 6 — historique + stats
- [x] Jalon 7 — polish
- [x] Jalon 8 — visual parity Interval Timer + iOS 26

> **Jalon 8 décisions** :
> - RunView : fond plein écran couleur segment, anneau circulaire, glassEffect iOS 26 sur contrôles
> - TimerEngine : segment de préparation automatique (prepareSeconds sur Workout, défaut 5 s)
> - WorkoutEditorView : barre de prévisualisation proportionnelle + Picker préparation
> - WorkoutListView : mini-barre proportionnelle dans les lignes (1 round + prépa)
> - HIIT974App : nouveau Tab struct (iOS 18) + tabBarMinimizeBehavior (iOS 26)
> - Déploiement minimum relevé iOS 17 → iOS 26
