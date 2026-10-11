-- ============================================================
-- 06 - Securite : RLS (isolation par etablissement et par profil), droits, fonctions de connexion
-- Principe : l'application se connecte avec gs_application (soumis a la RLS) et appelle
--   definir_contexte(id_utilisateur, id_etablissement, role_actif) au debut de chaque transaction.
-- Sans contexte, aucune ligne n'est visible.
-- ============================================================
SET search_path TO gestion_scolaire, public;
SET ROLE gs_proprietaire;

-- ============================================================
-- A. Fonctions de contexte (SECURITY DEFINER : lisent les tables sans etre soumises a la RLS)
-- ============================================================
-- L'administrateur systeme est verifie en base : un simple role 'ADMIN' declare ne suffit pas
CREATE OR REPLACE FUNCTION ctx_est_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT ctx_role() = 'ADMIN' AND EXISTS (
    SELECT 1 FROM utilisateur WHERE id_utilisateur = ctx_utilisateur() AND est_admin_systeme AND statut_compte = 'ACTIF');
$$;

-- Staff de l'utilisateur courant dans l'etablissement courant
CREATE FUNCTION ctx_staff() RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT id_staff FROM staff
   WHERE ctx_role() = 'STAFF' AND id_utilisateur = ctx_utilisateur()
     AND id_etablissement = ctx_etablissement() AND statut = 'ACTIF';
$$;

-- Le staff courant peut-il LIRE ou ECRIRE dans ce domaine ?
--   DIRECTEUR : tout ; LIRE : au moins une permission du domaine ; ECRIRE : permission de gestion,
--   validation, decision, production ou administration du domaine. STRUCTURE : lecture ouverte a tout le staff.
CREATE FUNCTION staff_peut(p_domaine TEXT, p_mode TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT ctx_staff() IS NOT NULL AND (
       staff_est_directeur(ctx_staff())
    OR (p_mode = 'LIRE' AND p_domaine = 'STRUCTURE')
    OR EXISTS (SELECT 1 FROM permission p
                 JOIN domaine d ON d.id_domaine = p.id_domaine
                 JOIN type_action t ON t.id_type_action = p.id_type_action
                WHERE d.code = p_domaine AND p.id_permission IN (SELECT permissions_staff(ctx_staff()))
                  AND (p_mode = 'LIRE' OR t.categorie IN ('GESTION', 'VALIDATION', 'DECISION', 'PRODUCTION', 'ADMINISTRATION'))));
$$;

-- Enseignant "simple" (ni directeur, ni valideur pedagogique) : ne travaille que sur ses enseignements
CREATE FUNCTION staff_peut_enseignement(p_enseignement BIGINT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT ctx_est_admin()
      OR staff_est_directeur(ctx_staff())
      OR staff_a_permission(ctx_staff(), 'PEDAGOGIE_VALIDER')
      OR EXISTS (SELECT 1 FROM affectation_enseignant a
                  WHERE a.id_enseignement = p_enseignement AND a.id_staff_enseignant = ctx_staff()
                    AND current_date BETWEEN a.date_debut AND coalesce(a.date_fin, 'infinity'::date));
$$;

-- Eleves visibles par le parent (lien actif + peut_consulter) ou par l'eleve lui-meme
CREATE FUNCTION famille_eleves() RETURNS SETOF BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT ep.id_eleve FROM eleve_parent ep JOIN parent p ON p.id_parent = ep.id_parent
   WHERE ctx_role() = 'PARENT' AND p.id_utilisateur = ctx_utilisateur()
     AND ep.id_etablissement = ctx_etablissement() AND ep.peut_consulter
     AND (ep.date_fin IS NULL OR ep.date_fin >= current_date)
  UNION
  SELECT e.id_eleve FROM eleve e
   WHERE ctx_role() = 'ELEVE' AND e.id_utilisateur = ctx_utilisateur() AND e.id_etablissement = ctx_etablissement();
$$;

CREATE FUNCTION famille_inscriptions() RETURNS SETOF BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT id_inscription FROM inscription WHERE id_eleve IN (SELECT famille_eleves());
$$;

-- Creances, paiements et ressources visibles par la famille
CREATE FUNCTION famille_creances() RETURNS SETOF BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT id_creance FROM creance WHERE id_inscription IN (SELECT famille_inscriptions());
$$;

CREATE FUNCTION famille_paiements() RETURNS SETOF BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT a.id_paiement FROM allocation_paiement a WHERE a.id_creance IN (SELECT famille_creances())
  UNION
  SELECT p.id_paiement FROM paiement p JOIN parent pa ON pa.id_parent = p.id_parent_payeur
   WHERE ctx_role() = 'PARENT' AND pa.id_utilisateur = ctx_utilisateur() AND p.id_etablissement = ctx_etablissement();
$$;

CREATE FUNCTION diffusion_visible_famille(p_diffusion BIGINT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM ressource_diffusion d
      JOIN ressource_numerique r ON r.id_ressource_numerique = d.id_ressource_numerique AND r.statut = 'PUBLIEE'
     WHERE d.id_ressource_diffusion = p_diffusion AND d.id_etablissement = ctx_etablissement()
       AND current_date BETWEEN d.date_debut AND coalesce(d.date_fin, 'infinity'::date)
       AND (   (d.id_classe IS NULL AND d.id_niveau IS NULL)
            OR EXISTS (SELECT 1 FROM inscription i JOIN classe c ON c.id_classe = i.id_classe
                        WHERE i.id_inscription IN (SELECT famille_inscriptions()) AND i.statut = 'VALIDEE'
                          AND (c.id_classe = d.id_classe OR c.id_niveau = d.id_niveau))));
$$;

-- Bulletin PDF : visible si l'eleve est en regle sur son inscription en cours
CREATE FUNCTION bulletin_visible(p_eleve BIGINT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT coalesce((SELECT est_en_regle(i.id_inscription, NULL) FROM inscription i
                    WHERE i.id_eleve = p_eleve ORDER BY i.date_inscription DESC, i.id_inscription DESC LIMIT 1), TRUE);
$$;

-- Utilisateur rattache a l'etablissement courant (staff, parent d'un eleve, eleve)
CREATE FUNCTION utilisateur_de_etablissement(p_utilisateur BIGINT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT EXISTS (SELECT 1 FROM staff WHERE id_utilisateur = p_utilisateur AND id_etablissement = ctx_etablissement())
      OR EXISTS (SELECT 1 FROM eleve WHERE id_utilisateur = p_utilisateur AND id_etablissement = ctx_etablissement())
      OR EXISTS (SELECT 1 FROM parent p JOIN eleve_parent ep ON ep.id_parent = p.id_parent
                  WHERE p.id_utilisateur = p_utilisateur AND ep.id_etablissement = ctx_etablissement());
$$;

-- ============================================================
-- B. Fonctions de connexion (utilisees avant tout contexte)
-- ============================================================
-- Recherche du compte par telephone, e-mail ou identifiant eleve (aucune donnee personnelle renvoyee)
CREATE FUNCTION infos_connexion(p_identifiant TEXT)
RETURNS TABLE (id_utilisateur BIGINT, mot_de_passe_hash VARCHAR, type_secret VARCHAR, statut_compte VARCHAR,
               methode_2fa VARCHAR, verrouille_jusqu_a TIMESTAMPTZ, doit_changer_mdp BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT u.id_utilisateur, u.mot_de_passe_hash, u.type_secret, u.statut_compte, u.methode_2fa,
         u.verrouille_jusqu_a, u.doit_changer_mdp
    FROM utilisateur u
   WHERE u.telephone = p_identifiant OR lower(u.email) = lower(p_identifiant) OR u.identifiant = p_identifiant;
$$;

-- Echec : compteur + verrouillage 15 minutes au 5e echec ; succes : remise a zero
CREATE FUNCTION enregistrer_tentative_connexion(p_utilisateur BIGINT, p_reussie BOOLEAN, p_ip TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF p_reussie THEN
    UPDATE utilisateur SET tentatives_echec = 0, verrouille_jusqu_a = NULL, derniere_connexion = now()
     WHERE id_utilisateur = p_utilisateur;
  ELSE
    UPDATE utilisateur SET tentatives_echec = tentatives_echec + 1,
           verrouille_jusqu_a = CASE WHEN tentatives_echec + 1 >= 5 THEN now() + interval '15 minutes' END
     WHERE id_utilisateur = p_utilisateur;
  END IF;
  INSERT INTO journal_audit (id_utilisateur, type_operation, entite_type, entite_id, adresse_ip)
  VALUES (p_utilisateur, CASE WHEN p_reussie THEN 'CONNEXION' ELSE 'CONNEXION_ECHOUEE' END,
          'utilisateur', p_utilisateur, p_ip);
END $$;

-- Contextes (etablissement + role) proposes apres connexion
CREATE FUNCTION contextes_disponibles()
RETURNS TABLE (id_etablissement BIGINT, nom_etablissement VARCHAR, role_actif TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT et.id_etablissement, et.nom, 'STAFF' FROM staff s JOIN etablissement et USING (id_etablissement)
   WHERE s.id_utilisateur = ctx_utilisateur() AND s.statut = 'ACTIF' AND et.est_actif
  UNION
  SELECT et.id_etablissement, et.nom, 'PARENT' FROM parent p
    JOIN eleve_parent ep ON ep.id_parent = p.id_parent JOIN etablissement et ON et.id_etablissement = ep.id_etablissement
   WHERE p.id_utilisateur = ctx_utilisateur() AND (ep.date_fin IS NULL OR ep.date_fin >= current_date) AND et.est_actif
  UNION
  SELECT et.id_etablissement, et.nom, 'ELEVE' FROM eleve e JOIN etablissement et USING (id_etablissement)
   WHERE e.id_utilisateur = ctx_utilisateur() AND et.est_actif;
$$;

-- Seul un administrateur systeme peut donner ou retirer le statut d'administrateur systeme
-- (SECURITY INVOKER : current_user est le role reellement utilise, meme apres SET ROLE)
CREATE FUNCTION fn_protection_admin() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NEW.est_admin_systeme IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.est_admin_systeme ELSE FALSE END)
     AND NOT ctx_est_admin() AND current_user <> 'gs_traitement'
     AND NOT (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    PERFORM erreur('Seul un administrateur systeme peut modifier le statut d''administrateur systeme.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_utilisateur_protection_admin BEFORE INSERT OR UPDATE OF est_admin_systeme ON utilisateur
  FOR EACH ROW EXECUTE FUNCTION fn_protection_admin();

-- ============================================================
-- C. Activation de la RLS sur toutes les tables
-- ============================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'gestion_scolaire' LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- ============================================================
-- D. Staff : tables d'un etablissement, par domaine (lecture / ecriture)
-- ============================================================
DO $$
DECLARE m RECORD;
BEGIN
  FOR m IN SELECT * FROM (VALUES
    ('staff', 'ADMINISTRATION'), ('attribution_permission', 'ADMINISTRATION'), ('attribution_role', 'ADMINISTRATION'),
    ('rapport', 'ADMINISTRATION'), ('demande', 'SECRETARIAT'),
    ('annee_scolaire', 'STRUCTURE'), ('periode', 'STRUCTURE'), ('niveau', 'STRUCTURE'), ('classe', 'STRUCTURE'),
    ('matiere', 'STRUCTURE'), ('enseignement', 'STRUCTURE'), ('creneau', 'STRUCTURE'),
    ('affectation_enseignant', 'STRUCTURE'), ('salle', 'STRUCTURE'),
    ('eleve', 'SECRETARIAT'), ('eleve_parent', 'SECRETARIAT'), ('famille', 'SECRETARIAT'), ('inscription', 'SECRETARIAT'),
    ('document', 'SECRETARIAT'), ('carte_eleve', 'SECRETARIAT'),
    ('evaluation', 'PEDAGOGIE'), ('note', 'PEDAGOGIE'), ('historique_note', 'PEDAGOGIE'),
    ('resultat_matiere', 'PEDAGOGIE'), ('resultat_periode', 'PEDAGOGIE'), ('resultat_annuel', 'PEDAGOGIE'),
    ('presence', 'SURVEILLANCE'), ('incident', 'SURVEILLANCE'), ('observation_incident', 'SURVEILLANCE'),
    ('decision_disciplinaire', 'SURVEILLANCE'),
    ('frais_scolaire', 'FINANCE'), ('echeance', 'FINANCE'), ('creance', 'FINANCE'), ('regle_reduction', 'FINANCE'),
    ('paiement', 'FINANCE'), ('allocation_paiement', 'FINANCE'), ('recu', 'FINANCE'), ('annulation_paiement', 'FINANCE'),
    ('transaction_en_ligne', 'FINANCE'), ('transaction_creance', 'FINANCE'), ('derogation_acces_resultat', 'FINANCE'),
    ('ressource_numerique', 'BIBLIOTHEQUE'), ('ressource_diffusion', 'BIBLIOTHEQUE'),
    ('consultation_ressource', 'BIBLIOTHEQUE'), ('rendu_travail', 'BIBLIOTHEQUE')) AS x(tbl, dom)
  LOOP
    EXECUTE format($f$CREATE POLICY staff_lecture ON %1$I FOR SELECT
      USING ((SELECT ctx_est_admin()) OR (id_etablissement = (SELECT ctx_etablissement()) AND (SELECT staff_peut(%2$L, 'LIRE'))))$f$,
      m.tbl, m.dom);
    EXECUTE format($f$CREATE POLICY staff_ajout ON %1$I FOR INSERT
      WITH CHECK ((SELECT ctx_est_admin()) OR (id_etablissement = (SELECT ctx_etablissement()) AND (SELECT staff_peut(%2$L, 'ECRIRE'))))$f$,
      m.tbl, m.dom);
    EXECUTE format($f$CREATE POLICY staff_modification ON %1$I FOR UPDATE
      USING ((SELECT ctx_est_admin()) OR (id_etablissement = (SELECT ctx_etablissement()) AND (SELECT staff_peut(%2$L, 'ECRIRE'))))
      WITH CHECK ((SELECT ctx_est_admin()) OR (id_etablissement = (SELECT ctx_etablissement()) AND (SELECT staff_peut(%2$L, 'ECRIRE'))))$f$,
      m.tbl, m.dom);
  END LOOP;
END $$;

-- Un enseignant "simple" n'ecrit que sur les evaluations et notes de ses propres enseignements (politique restrictive)
CREATE POLICY enseignant_ses_evaluations ON evaluation AS RESTRICTIVE FOR INSERT
  WITH CHECK (ctx_role() <> 'STAFF' OR staff_peut_enseignement(id_enseignement));
CREATE POLICY enseignant_ses_evaluations_maj ON evaluation AS RESTRICTIVE FOR UPDATE
  USING (ctx_role() <> 'STAFF' OR staff_peut_enseignement(id_enseignement));
CREATE POLICY enseignant_ses_notes ON note AS RESTRICTIVE FOR INSERT
  WITH CHECK (ctx_role() <> 'STAFF' OR staff_peut_enseignement(
    (SELECT id_enseignement FROM evaluation e WHERE e.id_evaluation = note.id_evaluation)));
CREATE POLICY enseignant_ses_notes_maj ON note AS RESTRICTIVE FOR UPDATE
  USING (ctx_role() <> 'STAFF' OR staff_peut_enseignement(
    (SELECT id_enseignement FROM evaluation e WHERE e.id_evaluation = note.id_evaluation)));

-- Tables reservees au DIRECTEUR / ADMINISTRATION (configuration, contrat, factures, envois)
CREATE POLICY direction_lecture ON config_paiement_etablissement FOR SELECT
  USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_est_directeur(ctx_staff())));
CREATE POLICY direction_ajout ON config_paiement_etablissement FOR INSERT
  WITH CHECK (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_est_directeur(ctx_staff())));
CREATE POLICY direction_modification ON config_paiement_etablissement FOR UPDATE
  USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_est_directeur(ctx_staff())));
CREATE POLICY contrat_lecture ON contrat_plateforme FOR SELECT
  USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_est_directeur(ctx_staff())));
CREATE POLICY contrat_admin ON contrat_plateforme FOR ALL USING (ctx_est_admin()) WITH CHECK (ctx_est_admin());
CREATE POLICY facture_lecture ON facture_commission FOR SELECT
  USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND (staff_est_directeur(ctx_staff()) OR staff_peut('FINANCE', 'LIRE'))));
CREATE POLICY facture_admin ON facture_commission FOR ALL USING (ctx_est_admin()) WITH CHECK (ctx_est_admin());
CREATE POLICY envoi_lecture ON envoi_notification FOR SELECT
  USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_peut('ADMINISTRATION', 'LIRE')));
CREATE POLICY envoi_ajout ON envoi_notification FOR INSERT
  WITH CHECK (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND ctx_staff() IS NOT NULL));
CREATE POLICY journal_lecture ON journal_audit FOR SELECT
  USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_peut('ADMINISTRATION', 'LIRE')));
CREATE POLICY etablissement_lecture ON etablissement FOR SELECT
  USING (ctx_est_admin() OR id_etablissement = ctx_etablissement());
CREATE POLICY etablissement_direction ON etablissement FOR UPDATE
  USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_est_directeur(ctx_staff())));
CREATE POLICY etablissement_admin ON etablissement FOR INSERT WITH CHECK (ctx_est_admin());

-- ============================================================
-- E. Referentiels : communs (lecture par tous) ou mixtes (communs + propres a l'etablissement)
-- ============================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['domaine', 'type_action', 'permission', 'pays', 'fournisseur_paiement', 'fournisseur_pays'] LOOP
    EXECUTE format('CREATE POLICY lecture_commune ON %I FOR SELECT USING (ctx_utilisateur() IS NOT NULL)', t);
    EXECUTE format('CREATE POLICY admin_ecriture ON %I FOR ALL USING (ctx_est_admin()) WITH CHECK (ctx_est_admin())', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['type_document', 'type_evaluation', 'type_incident', 'mode_paiement',
                           'categorie_ressource', 'role', 'parametre_systeme'] LOOP
    EXECUTE format($f$CREATE POLICY lecture_mixte ON %I FOR SELECT
      USING (id_etablissement IS NULL OR id_etablissement = ctx_etablissement() OR ctx_est_admin())$f$, t);
    EXECUTE format($f$CREATE POLICY ecriture_mixte ON %I FOR INSERT
      WITH CHECK (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_peut('ADMINISTRATION', 'ECRIRE')))$f$, t);
    EXECUTE format($f$CREATE POLICY modification_mixte ON %I FOR UPDATE
      USING (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND staff_peut('ADMINISTRATION', 'ECRIRE')))$f$, t);
  END LOOP;
END $$;
CREATE POLICY lecture_commune ON role_permission FOR SELECT USING (ctx_utilisateur() IS NOT NULL);
CREATE POLICY ecriture_role_permission ON role_permission FOR INSERT
  WITH CHECK (ctx_est_admin() OR EXISTS (SELECT 1 FROM role r WHERE r.id_role = role_permission.id_role
                AND r.id_etablissement = ctx_etablissement() AND staff_peut('ADMINISTRATION', 'ECRIRE')));

-- ============================================================
-- F. Comptes : utilisateur, parent, appareils, sessions, codes, notifications
-- ============================================================
CREATE POLICY utilisateur_lecture ON utilisateur FOR SELECT
  USING (id_utilisateur = ctx_utilisateur() OR ctx_est_admin()
         OR (ctx_staff() IS NOT NULL AND utilisateur_de_etablissement(id_utilisateur)));
CREATE POLICY utilisateur_ajout ON utilisateur FOR INSERT
  WITH CHECK (ctx_est_admin() OR staff_peut('SECRETARIAT', 'ECRIRE') OR staff_peut('ADMINISTRATION', 'ECRIRE'));
CREATE POLICY utilisateur_modification ON utilisateur FOR UPDATE
  USING (id_utilisateur = ctx_utilisateur() OR ctx_est_admin()
         OR ((staff_peut('SECRETARIAT', 'ECRIRE') OR staff_peut('ADMINISTRATION', 'ECRIRE'))
             AND utilisateur_de_etablissement(id_utilisateur)));

CREATE POLICY parent_lecture ON parent FOR SELECT
  USING (id_utilisateur = ctx_utilisateur() OR ctx_est_admin()
         OR (staff_peut('SECRETARIAT', 'LIRE') AND EXISTS (SELECT 1 FROM eleve_parent ep WHERE ep.id_parent = parent.id_parent
                                                              AND ep.id_etablissement = ctx_etablissement())));
CREATE POLICY parent_ajout ON parent FOR INSERT WITH CHECK (ctx_est_admin() OR staff_peut('SECRETARIAT', 'ECRIRE'));
CREATE POLICY parent_modification ON parent FOR UPDATE
  USING (id_utilisateur = ctx_utilisateur() OR ctx_est_admin() OR staff_peut('SECRETARIAT', 'ECRIRE'));

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['appareil_confiance', 'session_utilisateur', 'code_verification'] LOOP
    EXECUTE format($f$CREATE POLICY proprietaire ON %I FOR ALL
      USING (id_utilisateur = ctx_utilisateur() OR ctx_est_admin())
      WITH CHECK (id_utilisateur = ctx_utilisateur() OR ctx_est_admin())$f$, t);
  END LOOP;
END $$;

CREATE POLICY notification_destinataire ON notification FOR SELECT
  USING (id_utilisateur = ctx_utilisateur() OR ctx_est_admin()
         OR (id_etablissement = ctx_etablissement() AND staff_peut('ADMINISTRATION', 'LIRE')));
CREATE POLICY notification_lecture_marquee ON notification FOR UPDATE USING (id_utilisateur = ctx_utilisateur());
CREATE POLICY notification_ajout ON notification FOR INSERT
  WITH CHECK (ctx_est_admin() OR (id_etablissement = ctx_etablissement() AND ctx_staff() IS NOT NULL));

CREATE POLICY admin_seul ON notification_fournisseur FOR ALL USING (ctx_est_admin()) WITH CHECK (ctx_est_admin());

-- ============================================================
-- G. Parents et eleves : lecture de ce qui les concerne uniquement
-- ============================================================
-- Structure de leur etablissement (classes, matieres, emploi du temps, tarifs)
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['annee_scolaire', 'periode', 'niveau', 'classe', 'matiere', 'enseignement', 'creneau',
                           'salle', 'frais_scolaire', 'echeance', 'regle_reduction'] LOOP
    EXECUTE format($f$CREATE POLICY famille_lecture ON %I FOR SELECT
      USING (ctx_role() IN ('PARENT', 'ELEVE') AND id_etablissement = ctx_etablissement())$f$, t);
  END LOOP;
END $$;

CREATE POLICY famille_lecture ON eleve FOR SELECT USING (id_eleve IN (SELECT famille_eleves()));
CREATE POLICY famille_lecture ON eleve_parent FOR SELECT USING (id_eleve IN (SELECT famille_eleves()));
CREATE POLICY famille_lecture ON inscription FOR SELECT USING (id_eleve IN (SELECT famille_eleves()));
CREATE POLICY famille_lecture ON carte_eleve FOR SELECT USING (id_eleve IN (SELECT famille_eleves()));
CREATE POLICY famille_lecture ON document FOR SELECT
  USING (id_eleve IN (SELECT famille_eleves()) AND statut = 'ACTIF'
         AND ((ctx_role() = 'PARENT' AND visible_parent) OR (ctx_role() = 'ELEVE' AND visible_eleve))
         AND (NOT EXISTS (SELECT 1 FROM type_document t WHERE t.id_type_document = document.id_type_document
                            AND t.code = 'BULLETIN') OR bulletin_visible(id_eleve)));

-- Notes : toujours visibles des que l'evaluation est validee (jamais bloquees par les impayes)
CREATE POLICY famille_lecture ON evaluation FOR SELECT
  USING (statut IN ('VALIDEE', 'VERROUILLEE') AND EXISTS (
           SELECT 1 FROM enseignement e JOIN inscription i ON i.id_classe = e.id_classe
            WHERE e.id_enseignement = evaluation.id_enseignement AND i.id_inscription IN (SELECT famille_inscriptions())));
CREATE POLICY famille_lecture ON note FOR SELECT
  USING (id_inscription IN (SELECT famille_inscriptions()) AND EXISTS (
           SELECT 1 FROM evaluation e WHERE e.id_evaluation = note.id_evaluation AND e.statut IN ('VALIDEE', 'VERROUILLEE')));

-- Bulletin : publie ET eleve en regle (blocage des impayes, derogation possible)
CREATE POLICY famille_lecture ON resultat_periode FOR SELECT
  USING (id_inscription IN (SELECT famille_inscriptions()) AND statut = 'PUBLIE' AND est_en_regle(id_inscription, id_periode));
CREATE POLICY famille_lecture ON resultat_matiere FOR SELECT
  USING (id_inscription IN (SELECT famille_inscriptions())
         AND EXISTS (SELECT 1 FROM resultat_periode rp WHERE rp.id_inscription = resultat_matiere.id_inscription
                        AND rp.id_periode = resultat_matiere.id_periode AND rp.statut = 'PUBLIE')
         AND est_en_regle(id_inscription, id_periode));
CREATE POLICY famille_lecture ON resultat_annuel FOR SELECT
  USING (id_inscription IN (SELECT famille_inscriptions()) AND statut = 'PUBLIE' AND est_en_regle(id_inscription, NULL));

-- Vie scolaire : presences et discipline toujours visibles
CREATE POLICY famille_lecture ON presence FOR SELECT USING (id_inscription IN (SELECT famille_inscriptions()));
CREATE POLICY famille_lecture ON incident FOR SELECT USING (id_inscription IN (SELECT famille_inscriptions()));
CREATE POLICY famille_lecture ON decision_disciplinaire FOR SELECT
  USING (EXISTS (SELECT 1 FROM incident x WHERE x.id_incident = decision_disciplinaire.id_incident
                    AND x.id_inscription IN (SELECT famille_inscriptions())));

-- Finance : creances (mois payes / impayes), paiements, recus
CREATE POLICY famille_lecture ON creance FOR SELECT USING (id_creance IN (SELECT famille_creances()));
CREATE POLICY famille_lecture ON allocation_paiement FOR SELECT USING (id_creance IN (SELECT famille_creances()));
CREATE POLICY famille_lecture ON paiement FOR SELECT USING (id_paiement IN (SELECT famille_paiements()));
CREATE POLICY famille_lecture ON recu FOR SELECT USING (id_paiement IN (SELECT famille_paiements()));

-- Paiement en ligne : le parent cree et suit ses propres transactions
CREATE POLICY parent_transactions ON transaction_en_ligne FOR SELECT
  USING (ctx_role() = 'PARENT' AND id_utilisateur_initiateur = ctx_utilisateur() AND id_etablissement = ctx_etablissement());
CREATE POLICY parent_transactions_ajout ON transaction_en_ligne FOR INSERT
  WITH CHECK (ctx_role() = 'PARENT' AND id_utilisateur_initiateur = ctx_utilisateur() AND id_etablissement = ctx_etablissement());
CREATE POLICY parent_lignes ON transaction_creance FOR SELECT
  USING (EXISTS (SELECT 1 FROM transaction_en_ligne t WHERE t.id_transaction_en_ligne = transaction_creance.id_transaction_en_ligne
                    AND t.id_utilisateur_initiateur = ctx_utilisateur()));
CREATE POLICY parent_lignes_ajout ON transaction_creance FOR INSERT
  WITH CHECK (ctx_role() = 'PARENT' AND id_creance IN (SELECT famille_creances()));

-- Demandes du parent ou de l'eleve
CREATE POLICY famille_demandes ON demande FOR SELECT
  USING (id_utilisateur_demandeur = ctx_utilisateur() AND id_etablissement = ctx_etablissement());
CREATE POLICY famille_demandes_ajout ON demande FOR INSERT
  WITH CHECK (ctx_role() IN ('PARENT', 'ELEVE') AND id_utilisateur_demandeur = ctx_utilisateur()
              AND id_etablissement = ctx_etablissement());

-- Bibliotheque : ressources publiees et diffusees a l'eleve ; consultations ; rendus
CREATE POLICY famille_lecture ON ressource_diffusion FOR SELECT
  USING (ctx_role() IN ('PARENT', 'ELEVE') AND diffusion_visible_famille(id_ressource_diffusion));
CREATE POLICY famille_lecture ON ressource_numerique FOR SELECT
  USING (ctx_role() IN ('PARENT', 'ELEVE') AND EXISTS (
           SELECT 1 FROM ressource_diffusion d WHERE d.id_ressource_numerique = ressource_numerique.id_ressource_numerique
              AND diffusion_visible_famille(d.id_ressource_diffusion)));
CREATE POLICY famille_consultations ON consultation_ressource FOR SELECT USING (id_utilisateur = ctx_utilisateur());
CREATE POLICY famille_consultations_ajout ON consultation_ressource FOR INSERT
  WITH CHECK (ctx_role() IN ('PARENT', 'ELEVE') AND id_utilisateur = ctx_utilisateur()
              AND id_etablissement = ctx_etablissement());
CREATE POLICY famille_lecture ON rendu_travail FOR SELECT USING (id_inscription IN (SELECT famille_inscriptions()));
CREATE POLICY eleve_rendu_ajout ON rendu_travail FOR INSERT
  WITH CHECK (ctx_role() = 'ELEVE' AND id_inscription IN (SELECT famille_inscriptions()) AND statut = 'RENDU');
CREATE POLICY eleve_rendu_maj ON rendu_travail FOR UPDATE
  USING (ctx_role() = 'ELEVE' AND id_inscription IN (SELECT famille_inscriptions()) AND statut = 'RENDU')
  WITH CHECK (statut = 'RENDU');

-- ============================================================
-- H. Droits PostgreSQL : jamais de DELETE (suppression logique), journaux en ajout seul
-- ============================================================
REVOKE ALL ON ALL TABLES IN SCHEMA gestion_scolaire FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA gestion_scolaire TO gs_application, gs_traitement;
REVOKE INSERT, UPDATE ON journal_audit, historique_note FROM gs_application, gs_traitement;  -- alimentes par trigger
REVOKE UPDATE ON consultation_ressource FROM gs_application, gs_traitement;
REVOKE INSERT, UPDATE ON notification_fournisseur FROM gs_application;                    -- reception : gs_traitement

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA gestion_scolaire FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA gestion_scolaire TO gs_application, gs_traitement;
-- La confirmation d'un paiement en ligne n'est faite que par le traitement qui a re-verifie le statut
REVOKE EXECUTE ON FUNCTION finaliser_transaction(BIGINT, TEXT) FROM gs_application;

RESET ROLE;
