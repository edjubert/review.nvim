# Plan — screenshots des nouvelles fonctionnalités

## État d'exécution — 29 octobre 2026

Les captures et la documentation ont été intégrées sur `main`. Les sections
ci-dessous conservent le plan initial ; pour reproduire les scènes avec le plugin
actuel, utiliser [le guide de la démo](../scripts/screenshots/README.md).

| Commit | Livrable |
| --- | --- |
| `44e723c` | Lanceur de démo GitLab reproductible et isolé |
| `0923267` | 13 captures, dont 7 actualisées et 6 nouvelles |
| `caffd81` | Intégration des captures et de leurs légendes au README |
| `d705e1c` | Champ `Files` au-dessus des commits et aide Telescope `:ReviewHelp` |

Adaptations validées pendant l'exécution :

- Conserver cinq scènes de la démo GitHub et compléter les autres avec la démo
  GitLab simulée, notamment les réactions et la conversation résolue.
- Illustrer le filtre dans l'arborescence du panneau, à la place du picker de
  fichiers Telescope prévu initialement.
- Garder « Resolve all » sélectionné dans sa capture, sans valider le dialogue.
- Conserver les captures après le déplacement du champ `Files` et de l'aide :
  elles montrent encore leur ancien emplacement, comme indiqué dans le README.
- Garder tous les mappings désactivés par défaut et proposer `<leader>r?` dans
  l'exemple facultatif, sans appliquer les bindings à la configuration personnelle.

Les images originales sont conservées à 1267 × 1314 pixels, sans retouche.
Aucune publication externe ni nouveau lancement de capture n'a été effectué
pour ces adaptations.

## Objectif

Présenter les fonctionnalités disponibles depuis `871f39f` dans des captures
réelles de Neovim, cohérentes entre elles et intégrées aux sections du README.

Le livrable comprend :

- une démo GitLab entièrement simulée, reproductible et isolée ;
- les 7 captures existantes actualisées et 6 nouvelles captures ;
- un guide de capture et des légendes en anglais dans le README.

Ce document prépare une exécution ultérieure. Les commits décrits ci-dessous
seront réalisés sur `main`, conformément à la préférence exprimée par
l'utilisateur. La rédaction de ce plan ne déclenche aucune capture ni publication.

## Accès à la démo

### Démo existante — disponible maintenant

La PR utilisée pour les anciennes captures est
`https://github.com/edjubert/review.nvim/pull/1`.
Le lanceur local conserve la configuration Neovim, lit la PR avec `gh`, prépare
les brouillons dans un état séparé et bloque les écritures GitHub.
Il nécessite les accès Git et une CLI `gh` authentifiée.

```sh
nvim -c 'luafile /Users/frx43946/workspace/edjubert/review.nvim-readme-capture/capture.lua'
```

Dans cette session :

```vim
:DemoOverview
:DemoCommit
:DemoCompose
:DemoThreads
:DemoInline
```

Pour ouvrir directement les commentaires inline :

```sh
nvim -c 'luafile /Users/frx43946/workspace/edjubert/review.nvim-readme-capture/capture.lua' -c DemoInline
```

Guide existant :
`/Users/frx43946/workspace/edjubert/review.nvim-readme-capture/SCREENSHOTS.md`.

Cette démo fournit déjà la scène des commentaires inline. Les données de
réactions, les pipelines GitLab et les résolutions seront préparés par la
nouvelle démo décrite dans ce plan.

### Captures reçues — démo 1

Les neuf scènes fournies par l'utilisateur sont intégrées au README avec les
images originales, à leur résolution native. La dernière capture inline reçue
remplace la première version de cette scène.

| Image reçue | Fichier intégré | Contenu observé |
| --- | --- | --- |
| 1 | `assets/screenshots/overview.png` | Vue complète, arborescence, compteur viewed et deux brouillons |
| 2 | `assets/screenshots/commit-navigation.png` | Premier commit sélectionné et ses deux fichiers |
| 3 | `assets/screenshots/range-comment.png` | Éditeur Markdown avec sauvegarde locale, titre de plage `20–21` |
| 4 | `assets/screenshots/discussion.png` | Discussion sur `18–19`, avec commentaire et réponse |
| Dernière capture inline | `assets/screenshots/inline-comments.png` | Commentaire et réponse sous `18–19`, affichage inline activé |
| Lot 2 — 1 | `assets/screenshots/review-info.png` | Titre de la PR et description Markdown |
| Lot 2 — 2 | `assets/screenshots/local-drafts.png` | Sélecteur des deux brouillons avec chemins et extraits |
| Lot 2 — 3 | `assets/screenshots/submission-preview.png` | Prévisualisation et trois choix, dont publication avec demande de changements ; `Keep local` sélectionné |
| Lot 2 — 4 | `assets/screenshots/file-search.png` | Les cinq fichiers, leurs statuts Git, le renommage et deux fichiers viewed |

Ces images documentent la démo GitHub actuelle : pipeline `none`, review
`pending`, progression viewed `0/5` dans les premières captures puis `2/5`
dans celle de la recherche de fichiers. Les réactions,
les décisions simulées et les résolutions prévues plus bas restent à capturer
avec la nouvelle démo GitLab.

Il reste quatre nouveaux fichiers images à produire : `pipelines.png`,
`pipeline-job.png`, `request-changes.png` et `resolve-all.png`. Les scènes
d'aperçu et de discussions pourront être enrichies avec les données GitLab.

Pour la capture finale du commentaire sur une plage, harmoniser la plage du
titre de l'éditeur avec celle utilisée par la discussion (`18–19`).

### Nouvelle démo GitLab — à créer au commit 1

Le futur lanceur sera versionné dans `scripts/screenshots/demo.lua`.
Après sa création, le lancement depuis la racine du dépôt sera :

```sh
nvim -c 'luafile scripts/screenshots/demo.lua'
```

Pour ouvrir directement la scène inline après sa création :

```sh
nvim -c 'luafile scripts/screenshots/demo.lua' -c DemoInline
```

L'URL `https://gitlab.example.com/demo/inbox/-/merge_requests/42` est une cible
synthétique interceptée par le lanceur. Le dépôt, les refs Git et l'état local
sont préparés dans un répertoire temporaire ; les échanges GitLab sont simulés.

## Périmètre

| Inclus | Détail |
| --- | --- |
| Navigation | Commits exacts, vue complète, dossiers ouverts et repliés |
| Progression locale | `[x]`, `[ ]`, compteur `Viewed`, titre du diff |
| Recherche | Picker Telescope des fichiers du diff courant |
| Pipelines GitLab | Liste, groupes de jobs, cinq couleurs, détail d'un job |
| Décisions | Statuts des reviewers, approbation, demande de changements seule ou avec les commentaires |
| Discussions | Réactions, participants, affichage inline, conversation résolue |
| Résolution globale | Dialogue d'avertissement avec le nombre de conversations et `Cancel` |
| Parcours existant | Description, brouillons, commentaire sur une plage, prévisualisation |

Hors périmètre : modifications du code de production, changements de configuration
personnelle, synchronisation des `viewed` avec GitLab, création d'une vraie MR,
publication de commentaires, décisions ou résolutions sur un service externe.

Les vérifications prévues concernent la préparation de la démo, le rendu des
images et leur intégration documentaire. Aucun ajout ni lancement de tests
fonctionnels du plugin n'est prévu dans ce plan.

## Direction visuelle

- Utiliser le thème, la police, le rendu Markdown et les sélecteurs de la
  configuration Neovim habituelle de l'utilisateur.
- Utiliser une seule taille de terminal : **150 colonnes × 50 lignes**.
- Garder un panneau de **44 colonnes** et des pickers Telescope horizontaux,
  avec une preview suffisamment large pour les noms de jobs.
- Conserver la même taille de police et la même échelle d'écran pour les 13 images.
- Capturer la surface Neovim à sa résolution native, en PNG. Appliquer le même
  recadrage pour retirer les éléments du système et conserver les bordures utiles.
- Garder visibles les titres, les chemins et les raccourcis utiles à la scène.
- Attendre la fin des chargements et la disparition des notifications temporaires.
- Produire les captures depuis l'interface réelle. Les textes, couleurs et
  dialogues viennent du plugin ; aucune interface n'est redessinée dans l'image.

Si le dialogue d'avertissement ou une ligne utile est tronqué à ce cadrage,
**stoppe et signale** avant de modifier les dimensions ou la configuration.

## Données de démonstration

### MR et dépôt local

| Élément | Valeur |
| --- | --- |
| URL synthétique | `https://gitlab.example.com/demo/inbox/-/merge_requests/42` |
| Titre | `Add inbox filters and cover empty queries` |
| Projet | `demo/inbox`, ID `420` |
| Dates | Dates fixes du `2026-10-29`, en UTC |
| Identités | `demo-author`, `demo-reviewer`, `demo-maintainer` |
| Dépôt et état | Nouveau répertoire temporaire propre à chaque lancement |
| Historique | Commit de base, puis 3 commits avec leurs vrais SHA et parents |
| Brouillons | 2 commentaires locaux ancrés sur des plages du diff |
| Viewed | 2 fichiers sur les 5 changements de la comparaison complète |

Le dépôt temporaire contient une petite implémentation Lua de filtrage de messages.
Les changements montrent le traitement d'une requête vide, un filtre `unread_only`
et des exemples associés. Les textes ne contiennent aucune donnée d'un dépôt privé.

| Commit de démo | Changements |
| --- | --- |
| `feat: filter unread messages` | Modifier `demo/src/inbox.lua` et `demo/src/config.lua` |
| `test: cover inbox filters` | Ajouter `demo/tests/inbox_spec.lua`, supprimer `demo/legacy.lua` |
| `docs: refresh inbox example` | Renommer `demo/USAGE.md` en `demo/docs/USAGE.md`, sans modifier son contenu |

Les fichiers modifiés font apparaître les statuts `M`, `A`, `R`, `D`. Le renommage
reste détectable à partir du vrai diff Git. Les positions de commentaires sont
dérivées des lignes et refs réelles du dépôt temporaire.

### Pipelines et jobs

La liste contient 3 pipelines, du plus récent au plus ancien :

- `#703`, `running`, sur le head de la MR ;
- `#702`, `success`, sur le deuxième commit ;
- `#701`, `failed`, sur le premier commit.

La preview de `#703` contient les jobs suivants, dans cet ordre :

| Stage | Job | État | Couleur attendue |
| --- | --- | --- | --- |
| `manage instance` | `create instance` | `success` | Verte |
| `manage instance` | `wake up instance` | `manual` | Grise |
| `test` | `lint` | `success` | Verte |
| `test` | `unit tests` | `running` | Bleue |
| `test validation` | `compare with main` | `pending` | Orange |
| `test validation` | `integration checks` | `failed`, `allow_failure = true` | Rouge |
| `test validation` | `validate models` | `created` | Grise |
| `stop and destroy instances` | `destroy instance` | `manual` | Grise |

Le job `integration checks` dispose d'une durée de `83` secondes, du runner
`demo-runner` et du motif `script_failure`. La capture de son détail affiche
ces champs. Les noms de jobs ne répètent pas leur stage.

### Décisions et conversations

- L'approbation simulée de `demo-reviewer` et la demande de changements de
  `demo-maintainer` sont visibles dans l'aperçu : compteur d'approbation `1/2`
  et état global `changes requested`.
- Les décisions simulées modifient les données en mémoire, puis le plugin
  actualise son panneau par son parcours habituel.
- Préparer trois conversations : une ouverte sur le filtre, une ouverte
  `outdated` et une déjà résolue.
- La conversation sur le filtre contient un commentaire et une réponse, avec
  `Reactions: 👍 2 · ❤️ 1` sur le commentaire et `👍 1` sur la réponse.
- La fenêtre des discussions affiche aussi les utilisateurs associés aux réactions.
- Utiliser des IDs de discussions non vides, des IDs de notes entiers positifs,
  des auteurs et des positions valides. Les notes ouvertes ont
  `resolvable = true`, `resolved = false`.
- La scène de résolution individuelle résout la conversation sur le filtre
  par `:ReviewResolve`, avec un transport simulé.
- La scène de résolution globale repart de l'état initial : **2 conversations**
  à résoudre, dont la conversation obsolète.

Chaque scène restaure son état initial. Son résultat ne dépend pas de l'ordre
dans lequel les captures sont prises.

## Catalogue des captures

Tous les fichiers images sont placés dans `assets/screenshots/`.
Les commandes `Demo…` sont propres au script de démo.

| Fichier | Action | Composition et critères visibles | Emplacement README |
| --- | --- | --- | --- |
| `overview.png` | `:DemoOverview` | Vue complète, `src` ouvert, `tests` et `docs` repliés, diff du filtre, `[x]` et `[ ]`, `Viewed: 2/5 files`, statuts du pipeline et des deux reviewers | Image principale |
| `commit-navigation.png` | `:DemoCommit` | Premier commit sélectionné, fichiers du commit, autres commits visibles et titre contenant son SHA | `Open a review` |
| `review-info.png` | `:DemoInfo` | Titre de MR et description Markdown courte : objectif, changements et checklist | `Review title and description` |
| `range-comment.png` | `:DemoCompose` | Éditeur d'un commentaire sur la plage du filtre, diff visible derrière, indication de sauvegarde locale | `Comments` |
| `local-drafts.png` | `:DemoDrafts` | Sélecteur des deux brouillons, chemins/plages et extraits lisibles | `Manage local drafts` |
| `submission-preview.png` | `:DemoSubmit` | Prévisualisation et trois choix visibles : conserver localement, publier, publier et demander des changements | `Preview before publication` |
| `discussion.png` | `:DemoThreads` | Conversation après résolution individuelle, mention `Resolved discussion`, deux participants, réactions avec noms | `Browse discussions` |
| `file-search.png` | `:DemoFiles` | Telescope avec la requête `inbox`, les chemins des fichiers source/test, statuts Git et marqueurs viewed | `File search` |
| `pipelines.png` | `:DemoPipelines` | Liste des pipelines à gauche ; preview de `#703` à droite avec les quatre titres de stage, les huit jobs et les cinq couleurs | `Pipeline details in Telescope` |
| `pipeline-job.png` | `:DemoJob` | Picker des jobs et preview de `integration checks` : stage, état rouge, durée, runner et motif d'échec | `Pipeline details in Telescope` |
| `request-changes.png` | `:DemoRequestChanges` | Confirmation autonome, `Cancel` et demande de changements, texte indiquant que les brouillons restent locaux | `Approve or request changes` |
| `inline-comments.png` | `:DemoInline`, activation de `:ReviewToggleComments` | Commentaire et réponse directement sous la plage du diff, auteurs, réactions et lignes de code autour de l'ancre | `Inline discussions` |
| `resolve-all.png` | `:DemoResolveAll` | Avertissement complet, nombre `2`, MR `!42`, conversations obsolètes incluses et `Cancel` sélectionné | `Resolve GitLab conversations` |

Le README utilise l'aperçu principal pour illustrer aussi les dossiers et la
progression locale. Les légendes expliquent les commandes de ces deux fonctions,
sans dupliquer cette image dans plusieurs sections.

### Capture dédiée aux commentaires inline

Cette capture est un livrable obligatoire de la série. L'affichage est déjà
implémenté par `:ReviewToggleComments` ; la scène doit enfin le documenter
visuellement dans le README.

- Partir du diff du filtre, avec les discussions inline masquées.
- Activer l'affichage par la vraie commande `:ReviewToggleComments`
  (raccourci utilisateur : `<leader>rt`).
- Centrer la plage commentée et garder du code visible avant et après.
- Montrer le commentaire racine, sa réponse, leurs auteurs et leurs réactions.
- Garder le panneau latéral et le titre du diff pour situer le fichier.
- Montrer les messages dans les lignes virtuelles sous la plage commentée ;
  la fenêtre des discussions reste fermée pour cette scène.
- Ajouter la capture dans `Inline discussions` avec une légende mentionnant
  la commande et son raccourci.

## Commit 1 — `docs: add reproducible GitLab screenshot demo`

### Objectif

Préparer les données et les commandes nécessaires aux 13 scènes dans une session
Neovim dédiée, sans connexion à un service externe.

### Contrainte technique

Garder les vrais buffers, le calcul des diffs, les marqueurs, les fenêtres
Markdown, Telescope et les dialogues de `review.nvim`. Simuler les échanges avec
GitLab et conserver les opérations Git sur le dépôt temporaire.

`git.prepare` effectue normalement un fetch même avec `config.repo` : le script
de démo doit remplacer cette fonction en mémoire pour retourner son dépôt
temporaire. Les fonctions de lecture Git utilisent les SHA de ce dépôt.

Si la démo nécessite une modification du code de production, un accès réseau
ou une installation automatique de dépendances, **stoppe et signale**.

### Fichiers

- Créer : `scripts/screenshots/fixture.lua`
- Créer : `scripts/screenshots/demo.lua`
- Créer : `scripts/screenshots/README.md`

### Lecture requise

- `AGENTS.md` — limites des publications et transports.
- `lua/review/init.lua` — configuration, commandes et ouverture.
- `lua/review/session.lua` — chargement, sélection, brouillons, décisions et résolution.
- `lua/review/git.lua` — dépôt explicite, lectures de contenu et fetch.
- `lua/review/providers/gitlab.lua` — contrats des métadonnées et méthodes à simuler.
- `lua/review/position.lua` — positions des commentaires sur une plage.
- `lua/review/threads.lua`, `lua/review/reactions.lua` — contrats des conversations et réactions.
- `lua/review/tree.lua`, `lua/review/viewed.lua` — dossiers et état local.
- `lua/review/ui.lua`, `lua/review/telescope.lua` — rendu et navigation.

### Hors périmètre

- `lua/review/`, `plugin/`, `tests/` — conserver l'implémentation du plugin.
- Configuration utilisateur et répertoires des anciennes démos — conserver leur contenu.
- `assets/screenshots/` et `README.md` — traités dans les commits suivants.

### Tâches

- [ ] Créer d'abord dans `scripts/screenshots/README.md` la checklist des critères
      du catalogue, les prérequis et les commandes de lancement.
- [ ] Dans `fixture.lua`, exposer `create(root)` et `reset()` ; créer le dépôt Git
      de démo dans `root`, avec le contenu et les trois commits définis plus haut.
      Exécuter Git par tableaux d'arguments avec `vim.system`, désactiver la
      signature et les hooks pour ces commits, et fixer identité et dates pour
      ces seuls appels.
- [ ] Dans `fixture.lua`, dériver les SHA, parents, fichiers et hunks du vrai
      historique. Construire les tables `mr`, `commits`, `project`, `diffs`,
      `discussions`, `status`, `pipelines` et `pipeline_details` selon les contrats
      des modules lus. Renvoyer des copies pour éviter les mutations accidentelles.
- [ ] Dans `fixture.lua`, fournir les lectures simulées `load`, `current`,
      `status`, `discussions`, `pipelines` et `pipeline_details`. Les validations
      de décisions/réponses utilisent exclusivement ces données.
- [ ] Dans `fixture.lua`, fournir `post`, `reply`, `approve`, `request_changes`
      et `resolve` simulés. Modifier seulement l'état en mémoire, renvoyer les
      confirmations attendues et enregistrer l'action dans un journal local.
      Une cible, des refs ou un ID inattendus provoquent une erreur explicite.
- [ ] Dans `demo.lua`, déduire la racine du plugin de son propre emplacement,
      créer un répertoire temporaire et charger les fixtures. Fixer `repo`,
      `cache_dir` et `state_dir` sur ce répertoire ; conserver les préférences
      visuelles de l'utilisateur et fixer `panel_width = 44`.
- [ ] Dans `demo.lua`, installer les remplacements en mémoire avant d'ouvrir la
      MR synthétique. Garder `build_position`, `can_resolve`, `is_resolved` et les
      autres fonctions pures du provider réel. Tout appel restant à
      `gitlab.request` doit échouer explicitement.
- [ ] Dans `demo.lua`, bloquer les transports de processus de la démo sauf Git
      dans son dépôt temporaire. Autoriser les seules commandes de préparation
      et lecture nécessaires : `init`, `add`, `commit`, `rev-parse`, `log`,
      `diff`, `show`, `cat-file`. Rejeter `fetch`, `clone`, `push`, `glab`, `gh`,
      `curl` et toute autre commande. Installer cette protection dès la création
      du dépôt et ne jamais conserver de référence permettant un transport réel
      dans les méthodes simulées.
- [ ] Dans `demo.lua`, remplacer `vim.ui.open` par une trace locale et un retour
      compatible avec ses appelants. Garder les vrais `vim.ui.select` et
      `vim.ui.input`, sans validation ou annulation automatique.
- [ ] Dans `demo.lua`, enregistrer les 13 commandes du catalogue. Chacune ferme
      les fenêtres de démo précédentes quand aucune action n'est en cours,
      réinitialise les fixtures et l'état local, puis prépare la scène.
      Les dialogues laissés ouverts se ferment manuellement par `Cancel`,
      `Keep local` ou `Esc` avant de lancer la scène suivante.
- [ ] Préparer les brouillons avec `session:comment_position` et
      `session:save_draft`, puis les marqueurs via les commandes viewed.
      Dériver les lignes de la plage depuis le contenu du filtre et
      `session.current.rows`, sans déduire un chemin du nom d'un buffer virtuel.
- [ ] Pour `DemoOverview`, simuler l'approbation par `:ReviewApprove`.
      Pour `DemoThreads`, résoudre la conversation du filtre par
      `:ReviewResolve`, puis ouvrir son document. Attendre les indicateurs
      de fin de l'opération avant de préparer le cadrage.
- [ ] Pour `DemoInline`, ouvrir le diff avec `inline_comments = false`, puis
      exécuter `:ReviewToggleComments`. Centrer la plage et ses lignes virtuelles
      pour rendre le commentaire, la réponse et les réactions visibles ensemble.
      Un nouveau lancement de cette scène repart toujours de l'état masqué.
- [ ] Pour les scènes Telescope, utiliser les pickers réels. Fixer leur layout
      horizontal dans la session de démo ; rechercher `inbox` pour les fichiers,
      sélectionner `#703` pour les pipelines et `integration checks` pour les
      jobs avec l'API Telescope existante et ses actions.
- [ ] Gérer l'attente par une condition avec délai maximal de 10 secondes :
      session prête, bon fichier, bonne preview ou opération terminée.
      En cas d'erreur/délai dépassé, afficher l'erreur et arrêter la scène.
- [ ] Compléter `scripts/screenshots/README.md` avec les dépendances déjà
      installées (`nvim`, `git`, `glab`, Telescope et Plenary), le tableau des
      scènes, le cadrage, l'isolation, et l'instruction de fermer cette session
      Neovim pour retrouver les fonctions originales.

### Vérification

Depuis la racine du checkout d'exécution sur `main` :

```sh
git branch --show-current
nvim --headless -u NONE -i NONE "+lua assert(loadfile('scripts/screenshots/fixture.lua')); assert(loadfile('scripts/screenshots/demo.lua'))" +qa
nvim -c 'luafile scripts/screenshots/demo.lua'
```

- [ ] La branche affichée est `main` et la vérification syntaxique sort avec le code `0`.
- [ ] Le lancement avec la configuration habituelle ouvre la MR synthétique sans authentification.
- [ ] Chaque commande du catalogue affiche sa scène, indépendamment de l'ordre.
- [ ] Les actions de décision/résolution atteignent le journal en mémoire ;
      les brouillons et marqueurs sont écrits seulement dans l'état temporaire.
- [ ] Les dialogues conservent leurs vrais choix et leur choix initial.
- [ ] Le README du script permet une reproduction sans chemin personnel codé en dur.

### Commit

```sh
git diff --check
git add scripts/screenshots/fixture.lua scripts/screenshots/demo.lua scripts/screenshots/README.md
git commit -m "docs: add reproducible GitLab screenshot demo"
```

## Commit 2 — `docs: refresh screenshots for review features`

### Objectif

Capturer les 13 scènes définies dans le catalogue et produire un ensemble visuel
homogène qui montre l'état actuel du plugin.

### Contrainte technique

Utiliser uniquement la session de démonstration isolée. Capturer les dialogues
de publication et de résolution globale avec `Keep local` et `Cancel` comme choix
initiaux. L'approbation et la résolution individuelle de préparation sont simulées.

Si une fonctionnalité ne rend pas correctement ou si une protection de transport
échoue, **stoppe et signale** ; ne corrige pas le rendu en retouchant l'image.

### Fichiers

- Modifier : `assets/screenshots/overview.png`
- Modifier : `assets/screenshots/commit-navigation.png`
- Modifier : `assets/screenshots/review-info.png`
- Modifier : `assets/screenshots/range-comment.png`
- Modifier : `assets/screenshots/local-drafts.png`
- Modifier : `assets/screenshots/submission-preview.png`
- Modifier : `assets/screenshots/discussion.png`
- Créer : `assets/screenshots/file-search.png`
- Créer : `assets/screenshots/pipelines.png`
- Créer : `assets/screenshots/pipeline-job.png`
- Créer : `assets/screenshots/request-changes.png`
- Créer : `assets/screenshots/inline-comments.png`
- Créer : `assets/screenshots/resolve-all.png`

### Lecture requise

- `scripts/screenshots/README.md` — lancement, scène, fermeture des dialogues et cadrage.
- `scripts/screenshots/demo.lua` — état attendu et commandes de démo.
- `README.md` — contexte et lisibilité des images actuellement intégrées.
- Le catalogue de ce plan — critères spécifiques de chaque capture.

### Hors périmètre

- Code de production, fixtures et configuration utilisateur.
- Logo et création d'images supplémentaires.
- Captures de logs de jobs : la fonctionnalité ouvre ces logs dans le navigateur.

### Tâches

- [ ] Ouvrir une session dédiée avec le launcher du guide ; fixer 150 × 50,
      le thème et la taille de police pour toute la série.
- [ ] Capturer les 7 images existantes dans l'ordre du catalogue.
      Vérifier après chaque capture ses critères visibles.
- [ ] Capturer les 6 nouvelles images dans l'ordre du catalogue.
- [ ] Pour `pipelines.png`, cadrer la preview afin que les quatre titres,
      les huit jobs et les cinq états colorés soient visibles ensemble.
      Les informations utiles du pipeline et le picker doivent rester lisibles.
- [ ] Pour `pipeline-job.png`, sélectionner le job échoué et conserver son
      motif, son runner, sa durée et sa politique d'échec dans la preview.
- [ ] Capturer `inline-comments.png` avec l'affichage inline activé : commentaire,
      réponse, auteurs et réactions visibles sous leur ancre dans le diff.
      Garder les deux colonnes de numéros de ligne et le contexte de code lisibles.
- [ ] Pour `resolve-all.png`, garder le texte d'avertissement complet et
      `Cancel` sélectionné. Pour `submission-preview.png`, garder le texte
      des trois choix entièrement lisible.
- [ ] Appliquer un recadrage identique et enregistrer chaque PNG sous le nom
      exact du catalogue. Garder les pixels natifs et des dimensions identiques.
- [ ] Ouvrir chaque image pour contrôler les accents, emojis, couleurs, textes
      tronqués, état du curseur et notifications. Reprendre les scènes inadéquates.

### Vérification

```sh
sips -g pixelWidth -g pixelHeight assets/screenshots/overview.png assets/screenshots/commit-navigation.png assets/screenshots/review-info.png assets/screenshots/range-comment.png assets/screenshots/local-drafts.png assets/screenshots/submission-preview.png assets/screenshots/discussion.png assets/screenshots/file-search.png assets/screenshots/pipelines.png assets/screenshots/pipeline-job.png assets/screenshots/request-changes.png assets/screenshots/inline-comments.png assets/screenshots/resolve-all.png
git status --short -- assets/screenshots
git diff --stat -- assets/screenshots
```

- [ ] Les 13 PNG existent, sont lisibles et ont les mêmes dimensions.
- [ ] Le statut Git liste exactement 7 images actualisées et 6 nouvelles images.
- [ ] La lecture des images confirme tous les critères du catalogue.
- [ ] Aucun nom, URL interne ou contenu de review privée n'apparaît.
- [ ] Les marqueurs viewed sont présentés comme une progression locale.

### Commit

```sh
git add assets/screenshots/overview.png assets/screenshots/commit-navigation.png assets/screenshots/review-info.png assets/screenshots/range-comment.png assets/screenshots/local-drafts.png assets/screenshots/submission-preview.png assets/screenshots/discussion.png assets/screenshots/file-search.png assets/screenshots/pipelines.png assets/screenshots/pipeline-job.png assets/screenshots/request-changes.png assets/screenshots/inline-comments.png assets/screenshots/resolve-all.png
git commit -m "docs: refresh screenshots for review features"
```

## Commit 3 — `docs: illustrate new review workflows`

### Objectif

Relier chaque nouvelle capture à sa fonctionnalité dans le README et documenter
la reproduction de l'ensemble.

### Contrainte technique

Conserver la documentation en anglais et les limites actuelles des providers :
pipelines détaillés et résolution pour GitLab, progression viewed locale.
Décrire les captures comme une MR GitLab simulée, avec décisions et discussions
simulées et thème provenant de la configuration utilisateur.

Si une légende nécessite de promettre un comportement supplémentaire,
**stoppe et signale**.

### Fichiers

- Modifier : `README.md`
- Modifier : `scripts/screenshots/README.md`

### Lecture requise

- `README.md` — sections, descriptions des providers et commandes existantes.
- `scripts/screenshots/README.md` — scènes et résultats de capture.
- Les 13 PNG du catalogue — écrire les légendes à partir du contenu visible.

### Hors périmètre

- `doc/review.txt`, code, tests et configuration personnelle.
- Installation du plugin, authentification et fonctionnement des commandes.
- Push des commits ou publication d'une MR.

### Tâches

- [ ] Dans `README.md`, actualiser le texte alternatif et la légende de
      l'aperçu : arborescence, marqueurs locaux, pipeline et décisions.
- [ ] Dans `README.md`, remplacer la référence aux screenshots d'une PR GitHub
      par la description de la MR GitLab simulée ; ajouter le lien relatif vers
      `scripts/screenshots/README.md`.
- [ ] Dans `README.md`, actualiser les 6 autres textes alternatifs existants :
      MR GitLab, aperçu avec demande de changements, réactions et conversation résolue.
- [ ] Dans `README.md`, insérer les 6 nouvelles images dans les sections indiquées
      par le catalogue, avec texte alternatif précis et une courte légende.
- [ ] Dans `README.md`, rappeler près de l'aperçu que `:ReviewViewed`,
      `:ReviewUnviewed` et les dossiers repliables sont visibles dans cette scène.
      Dans la section viewed, expliciter que les marqueurs restent locaux.
- [ ] Dans `scripts/screenshots/README.md`, ajouter les noms finaux des images,
      leurs sections README et la checklist de rendu complétée. Donner le
      lancement exact depuis la racine et les étapes de recapture d'une seule scène.
- [ ] Relire le Markdown rendu pour contrôler les espacements, les liens,
      la lisibilité et la proximité entre chaque image et son explication.

### Vérification

```sh
git diff --check
rg -n 'assets/screenshots/|simulated|scripts/screenshots' README.md
git diff --stat
```

- [ ] Le README référence exactement les 13 fichiers du catalogue.
- [ ] Tous les liens d'images et le lien du guide fonctionnent dans le rendu Markdown.
- [ ] Les stages et cinq couleurs décrits correspondent à `pipelines.png`.
- [ ] L'image de soumission montre le choix combiné, et la demande autonome
      conserve les brouillons locaux.
- [ ] La résolution globale montre l'avertissement et son choix `Cancel`.
- [ ] La progression viewed et la provenance simulée des données sont explicites.
- [ ] `inline-comments.png` illustre les lignes virtuelles sous le diff dans
      `Inline discussions`, avec `:ReviewToggleComments` et `<leader>rt` expliqués.

### Commit

```sh
git add README.md scripts/screenshots/README.md
git commit -m "docs: illustrate new review workflows"
```

## Critères de fin

- [ ] Démo reproductible depuis le dépôt, sans anciennes démos ni chemins personnels.
- [ ] 13 captures réelles, homogènes, montrant les fonctions du catalogue.
- [ ] README et guide cohérents avec les images et les commandes implémentées.
- [ ] Décisions, publications et résolutions de démonstration limitées aux fixtures.
- [ ] Trois commits documentaires sur `main`, sans push prévu par ce plan.
