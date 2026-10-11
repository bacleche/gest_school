# Base de données – Gestion scolaire (PostgreSQL)

> Ces scripts sont specifiques a PostgreSQL et ne sont pas utilises par le backend Django actuel, configure avec SQLite. Ne pas les executer sur SQLite. Voir le README a la racine pour demarrer l'API.

Scripts issus du MLD (`MLD_gestion_scolaire.puml`) : 72 tables, 10 domaines, isolation stricte entre établissements.
Testés sur **PostgreSQL 16.4** (versions 14 et suivantes prises en charge).

## Installation

Sur une base **vide**, en superutilisateur, dans l'ordre :

```bash
psql -d gestion_scolaire -v ON_ERROR_STOP=1 -f 01_extensions_schema.sql
psql -d gestion_scolaire -v ON_ERROR_STOP=1 -f 02_tables.sql
psql -d gestion_scolaire -v ON_ERROR_STOP=1 -f 03_cles_etrangeres.sql
psql -d gestion_scolaire -v ON_ERROR_STOP=1 -f 04_index.sql
psql -d gestion_scolaire -v ON_ERROR_STOP=1 -f 05_triggers.sql
psql -d gestion_scolaire -v ON_ERROR_STOP=1 -f 06_rls.sql
psql -d gestion_scolaire -v ON_ERROR_STOP=1 -f 07_donnees_initiales.sql
```

Ensuite, définir les mots de passe hors script :
`ALTER ROLE gs_application PASSWORD '...'; ALTER ROLE gs_traitement PASSWORD '...';`

| Fichier | Contenu |
|---|---|
| `01` | Extensions (`btree_gist`, `pgcrypto`), schéma `gestion_scolaire`, rôles, fonctions de contexte |
| `02` | 72 tables : types, NOT NULL, valeurs par défaut, CHECK, UNIQUE, EXCLUDE (**généré depuis le MLD**) |
| `03` | 195 clés étrangères, dont les clés composites d'isolation (**généré**) |
| `04` | Index uniques partiels, index des clés étrangères et de la RLS (**généré**) |
| `05` | Les 54 règles « (trigger) » du MLD, le journal d'audit et les traitements automatiques |
| `06` | RLS (241 politiques), droits PostgreSQL, fonctions de connexion |
| `07` | Domaines, permissions, rôles types, référentiels, pays CEMAC/UEMOA, fournisseurs, paramètres (rejouable) |
| `99_tests.sql` | Recette : 82 tests. **Base de test uniquement** (crée des données fictives) |

## Rôles PostgreSQL

| Rôle | Usage |
|---|---|
| `gs_proprietaire` | Possède les objets. Jamais utilisé pour se connecter. |
| `gs_application` | Compte de l'application. **Soumis à la RLS**, aucun DELETE possible. |
| `gs_traitement` | Tâches planifiées et réception des notifications des fournisseurs de paiement (contourne la RLS). |

## Ce que l'application doit faire

1. **Contexte à chaque transaction** : `SELECT gestion_scolaire.definir_contexte(id_utilisateur, id_etablissement, 'STAFF'|'PARENT'|'ELEVE'|'ADMIN');`
   Sans contexte, aucune ligne n'est visible. Le contexte est vérifié en base (un faux contexte ne donne rien).
2. **Connexion** :
   - `infos_connexion(telephone | email | identifiant)` pour retrouver le compte ;
   - vérification du mot de passe ou du PIN côté application (Argon2id) ;
   - `enregistrer_tentative_connexion(...)` (verrouillage 15 min après 5 échecs) ;
   - `contextes_disponibles()` pour le choix de l'école et du rôle ;
   - puis création d'une `session_utilisateur`. Pour le QR code : `compte_par_jeton_carte(jeton)`, puis vérification du PIN.
3. **Carte élève** : la carte est créée automatiquement à la validation de l'inscription. Au moment de produire le PDF, appeler `nouveau_jeton_carte(id_carte)` pour obtenir le jeton à encoder dans le QR code.
4. **Paiement en ligne** :
   - le parent crée la `transaction_en_ligne` et ses lignes `transaction_creance` ;
   - après **re-vérification du statut auprès du fournisseur**, le traitement (`gs_traitement`) appelle `finaliser_transaction(id, reference_fournisseur)`, qui crée le paiement, les allocations et le reçu en une fois. Un second appel ne crédite jamais deux fois.
5. **Motif d'une modification de note** (facultatif) : `SELECT set_config('app.motif', '...', true);` avant l'UPDATE.

## Tâches planifiées à prévoir (`gs_traitement`)

- Transactions en ligne non confirmées : passage à `EXPIREE` à `date_expiration`.
- Rapprochement quotidien avec les relevés des fournisseurs.
- Facture de commission mensuelle par établissement (transactions en mode `FACTURATION`).
- Envoi des notifications (WhatsApp, puis SMS en secours) et mise à jour de `envoi_notification`.
- Anonymisation des élèves archivés au-delà de `DUREE_CONSERVATION_ANNEES`.

## Avant la mise en production

- **Activer la couverture des fournisseurs par pays** (`fournisseur_pays.est_actif`). Elle est désactivée par défaut et doit être vérifiée dans chaque contrat marchand.
- Créer le premier administrateur système en superutilisateur (`est_admin_systeme = TRUE`, double authentification activée).
- Ne jamais exécuter `99_tests.sql` sur la base de production.
