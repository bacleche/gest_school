# Gestion scolaire - Backend Django

API REST Django avec base SQLite par defaut. Le backend couvre l'authentification, les etablissements, les annees/classes, les eleves et familles, les inscriptions, les evaluations/notes, les presences et le cycle frais/echeances/creances/paiements/allocations/recus.

## Demarrage local

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python manage.py migrate
.venv/bin/python manage.py createsuperuser
.venv/bin/python manage.py runserver
```

Creer les etablissements, les comptes et leurs appartenances depuis `/admin/`. Les mots de passe sont geres par le systeme d'authentification Django.

## API

- Documentation interactive Swagger : `http://127.0.0.1:8000/api/docs/`.
- Documentation ReDoc : `http://127.0.0.1:8000/api/redoc/`.
- Schema OpenAPI JSON : `http://127.0.0.1:8000/api/schema/`.
- `GET /api/sante/` : etat du service et confirmation SQLite.
- `POST /api/jetons/` : obtenir `access` et `refresh` avec `username` et `password`.
- `POST /api/jetons/rafraichir/` : renouveler le jeton d'acces.
- `GET/PATCH /api/moi/` : profil courant.
- Les ressources CRUD sont sous `/api/` (par ex. `/api/eleves/`, `/api/inscriptions/`, `/api/notes/`, `/api/creances/`, `/api/paiements/`).

Envoyer `Authorization: Bearer <access>`. Un compte rattache a plusieurs ecoles doit preciser `X-Etablissement-ID: <id>`; un seul rattachement actif est selectionne automatiquement. Les parents et eleves sont limites a leurs propres dossiers; seules les appartenances personnel/administrateur peuvent modifier les donnees. La suppression par API est desactivee.

Le chemin de la base peut etre change avec `SQLITE_PATH`. Pour le developpement, le fichier utilise par defaut est `db.sqlite3` a la racine du projet.

## Tests

```bash
.venv/bin/python manage.py test
```

Les scripts `files/sql/*.sql` restent la reference PostgreSQL du modele de donnees; ils contiennent des commandes, fonctions, RLS et types specifiques a PostgreSQL et ne doivent pas etre executes avec cette version SQLite.