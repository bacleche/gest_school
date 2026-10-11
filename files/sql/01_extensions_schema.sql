-- ============================================================
-- 01 - Extensions, schema, roles PostgreSQL, contexte de session
-- A executer en tant que superutilisateur, sur une base vide.
-- Ordre d'execution : 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07
-- ============================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- contraintes EXCLUDE (pas de chevauchement de dates)
CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- generation de jetons et empreintes

-- ------------------------------------------------------------
-- Roles
--   gs_proprietaire : possede les objets ; jamais utilise par l'application
--   gs_application  : compte de connexion de l'application (soumis a la RLS)
--   gs_traitement   : taches planifiees (expirations, anonymisation, rapprochement)
-- Les mots de passe se definissent hors script :
--   ALTER ROLE gs_application PASSWORD '...';
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gs_proprietaire') THEN
    CREATE ROLE gs_proprietaire NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gs_application') THEN
    CREATE ROLE gs_application LOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gs_traitement') THEN
    CREATE ROLE gs_traitement LOGIN NOINHERIT BYPASSRLS;
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS gestion_scolaire AUTHORIZATION gs_proprietaire;
REVOKE ALL ON SCHEMA gestion_scolaire FROM PUBLIC;
GRANT USAGE ON SCHEMA gestion_scolaire TO gs_application, gs_traitement;

SET search_path TO gestion_scolaire, public;
SET ROLE gs_proprietaire;

-- ------------------------------------------------------------
-- Contexte de session (alimente par l'application a chaque requete)
--   SELECT gestion_scolaire.definir_contexte(id_utilisateur, id_etablissement, role_actif);
-- role_actif : STAFF, PARENT, ELEVE ou ADMIN
-- ------------------------------------------------------------
CREATE FUNCTION definir_contexte(p_utilisateur BIGINT, p_etablissement BIGINT, p_role TEXT)
RETURNS VOID LANGUAGE sql AS $$
  SELECT set_config('app.id_utilisateur',   coalesce(p_utilisateur::text, ''),   true),
         set_config('app.id_etablissement', coalesce(p_etablissement::text, ''), true),
         set_config('app.role_actif',       coalesce(p_role, ''),                true);
$$;
COMMENT ON FUNCTION definir_contexte IS
  'Fixe le contexte de la transaction courante (portee locale : a appeler dans chaque transaction).';

CREATE FUNCTION ctx_utilisateur() RETURNS BIGINT LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('app.id_utilisateur', true), '')::bigint $$;
CREATE FUNCTION ctx_etablissement() RETURNS BIGINT LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('app.id_etablissement', true), '')::bigint $$;
CREATE FUNCTION ctx_role() RETURNS TEXT LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('app.role_actif', true), '') $$;
CREATE FUNCTION ctx_est_admin() RETURNS BOOLEAN LANGUAGE sql STABLE AS
  $$ SELECT coalesce(ctx_role() = 'ADMIN', false) $$;

RESET ROLE;
