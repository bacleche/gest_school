-- ============================================================
-- 05 - Regles metier controlees par trigger, fonctions et traitements automatiques
-- Chaque regle "(trigger)" du MLD est implementee ici (reference entre crochets).
-- Les fonctions sont SECURITY DEFINER (proprietaire gs_proprietaire) pour lire les
-- tables de reference meme sous RLS ; elles ne renvoient jamais de donnees a l'appelant.
-- ============================================================
SET search_path TO gestion_scolaire, public;
SET ROLE gs_proprietaire;

-- ============================================================
-- A. Fonctions utilitaires
-- ============================================================
CREATE FUNCTION erreur(p_message TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%', p_message USING ERRCODE = 'check_violation';
END $$;

-- Valeur d'un parametre : valeur propre a l'etablissement, sinon valeur commune, sinon defaut
CREATE FUNCTION parametre(p_etablissement BIGINT, p_cle TEXT, p_defaut TEXT) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT coalesce(
    (SELECT valeur FROM parametre_systeme WHERE id_etablissement = p_etablissement AND cle = p_cle),
    (SELECT valeur FROM parametre_systeme WHERE id_etablissement IS NULL AND cle = p_cle),
    p_defaut);
$$;

CREATE FUNCTION staff_est_directeur(p_staff BIGINT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT EXISTS (SELECT 1 FROM staff WHERE id_staff = p_staff AND type_staff = 'DIRECTEUR' AND statut = 'ACTIF');
$$;

-- Permissions effectives d'un staff : attributions directes + roles (actifs et non expires)
CREATE FUNCTION permissions_staff(p_staff BIGINT) RETURNS SETOF BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT ap.id_permission FROM attribution_permission ap
   WHERE ap.id_staff_beneficiaire = p_staff AND ap.est_active
     AND (ap.date_expiration IS NULL OR ap.date_expiration > now())
  UNION
  SELECT rp.id_permission FROM attribution_role ar
    JOIN role r ON r.id_role = ar.id_role AND r.est_actif
    JOIN role_permission rp ON rp.id_role = ar.id_role
   WHERE ar.id_staff_beneficiaire = p_staff AND ar.est_active
     AND (ar.date_expiration IS NULL OR ar.date_expiration > now());
$$;

CREATE FUNCTION staff_a_permission(p_staff BIGINT, p_code TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT EXISTS (SELECT 1 FROM permission p
                  WHERE p.code = p_code AND p.id_permission IN (SELECT permissions_staff(p_staff)));
$$;

-- Permission sensible : domaine FINANCE, ou action de validation, d'administration ou de decision
CREATE FUNCTION permission_sensible(p_permission BIGINT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT EXISTS (SELECT 1 FROM permission p
                   JOIN domaine d ON d.id_domaine = p.id_domaine
                   JOIN type_action t ON t.id_type_action = p.id_type_action
                  WHERE p.id_permission = p_permission
                    AND (d.code = 'FINANCE' OR t.categorie IN ('VALIDATION', 'ADMINISTRATION', 'DECISION')));
$$;

-- [UTILISATEUR] la double authentification est-elle obligatoire pour ce compte ?
CREATE FUNCTION utilisateur_exige_2fa(p_utilisateur BIGINT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM staff s
     WHERE s.id_utilisateur = p_utilisateur AND s.statut = 'ACTIF'
       AND (s.type_staff = 'DIRECTEUR'
            OR EXISTS (SELECT 1 FROM permissions_staff(s.id_staff) x(id) WHERE permission_sensible(x.id))));
$$;

-- Reste du d'une creance (paiements annules exclus)
CREATE FUNCTION reste_du(p_creance BIGINT) RETURNS NUMERIC
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT c.montant_du - c.remise - c.remise_reduction
         - coalesce((SELECT sum(a.montant_alloue) FROM allocation_paiement a
                       JOIN paiement p ON p.id_paiement = a.id_paiement
                      WHERE a.id_creance = c.id_creance AND p.statut <> 'ANNULE'), 0)
    FROM creance c WHERE c.id_creance = p_creance;
$$;

-- Met a jour le statut d'une creance (DUE / PARTIELLE / SOLDEE) d'apres ses allocations
CREATE FUNCTION maj_statut_creance(p_creance BIGINT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_reste NUMERIC; v_net NUMERIC; v_statut TEXT;
BEGIN
  SELECT montant_du - remise - remise_reduction, statut INTO v_net, v_statut FROM creance WHERE id_creance = p_creance;
  IF v_statut IS NULL OR v_statut = 'ANNULEE' THEN RETURN; END IF;
  v_reste := reste_du(p_creance);
  UPDATE creance SET statut = CASE WHEN v_reste <= 0 THEN 'SOLDEE'
                                   WHEN v_reste < v_net THEN 'PARTIELLE' ELSE 'DUE' END
   WHERE id_creance = p_creance;
END $$;

-- ============================================================
-- B. Journal d'audit automatique et tables en ajout seul
-- ============================================================
CREATE FUNCTION fn_audit() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_old JSONB; v_new JSONB; v_ligne JSONB;
        v_secrets TEXT[] := ARRAY['mot_de_passe_hash', 'reference_secret_2fa', 'reference_secret',
                                  'empreinte_jeton', 'empreinte_jeton_qr', 'empreinte_code'];
BEGIN
  IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD) - v_secrets; END IF;
  IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW) - v_secrets; END IF;
  v_ligne := coalesce(v_new, v_old);
  INSERT INTO journal_audit (id_utilisateur, id_etablissement, type_operation, entite_type, entite_id,
                             anciennes_valeurs, nouvelles_valeurs)
  VALUES (ctx_utilisateur(), coalesce((v_ligne ->> 'id_etablissement')::bigint, ctx_etablissement()),
          TG_OP, TG_TABLE_NAME, (v_ligne ->> TG_ARGV[0])::bigint, v_old::text, v_new::text);
  RETURN NULL;
END $$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['utilisateur', 'staff', 'attribution_permission', 'attribution_role', 'inscription',
                           'creance', 'paiement', 'allocation_paiement', 'annulation_paiement', 'recu', 'note',
                           'resultat_periode', 'resultat_annuel', 'derogation_acces_resultat',
                           'decision_disciplinaire', 'contrat_plateforme', 'config_paiement_etablissement',
                           'parametre_systeme', 'carte_eleve', 'transaction_en_ligne']
  LOOP
    EXECUTE format('CREATE TRIGGER trg_%1$s_audit AFTER INSERT OR UPDATE OR DELETE ON %1$I
                    FOR EACH ROW EXECUTE FUNCTION fn_audit(%2$L)', t, 'id_' || t);
  END LOOP;
END $$;

-- [JOURNAL_AUDIT, HISTORIQUE_NOTE, CONSULTATION_RESSOURCE] tables en INSERT seul
CREATE FUNCTION fn_ajout_seul() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  PERFORM erreur(format('La table %s est en ajout seul : modification et suppression interdites.', TG_TABLE_NAME));
  RETURN NULL;
END $$;
CREATE TRIGGER trg_journal_audit_ajout_seul BEFORE UPDATE OR DELETE ON journal_audit
  FOR EACH ROW EXECUTE FUNCTION fn_ajout_seul();
CREATE TRIGGER trg_historique_note_ajout_seul BEFORE UPDATE OR DELETE ON historique_note
  FOR EACH ROW EXECUTE FUNCTION fn_ajout_seul();
CREATE TRIGGER trg_consultation_ressource_ajout_seul BEFORE UPDATE OR DELETE ON consultation_ressource
  FOR EACH ROW EXECUTE FUNCTION fn_ajout_seul();

-- [NOTIFICATION_FOURNISSEUR] contenu jamais modifie ; seuls statut_traitement, date_traitement et le rattachement evoluent
CREATE FUNCTION fn_notification_fournisseur_immuable() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN PERFORM erreur('Une notification de fournisseur ne peut pas etre supprimee.'); END IF;
  IF (to_jsonb(NEW) - ARRAY['statut_traitement', 'date_traitement', 'id_transaction_en_ligne'])
     <> (to_jsonb(OLD) - ARRAY['statut_traitement', 'date_traitement', 'id_transaction_en_ligne']) THEN
    PERFORM erreur('Le contenu d''une notification de fournisseur ne peut pas etre modifie.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_notification_fournisseur_immuable BEFORE UPDATE OR DELETE ON notification_fournisseur
  FOR EACH ROW EXECUTE FUNCTION fn_notification_fournisseur_immuable();

-- ============================================================
-- C. Comptes et droits (domaine 1)
-- ============================================================
-- [UTILISATEUR] format E.164, PIN reserve aux parents/eleves, identifiants obligatoires, 2FA obligatoire
CREATE FUNCTION fn_utilisateur_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NEW.telephone IS NOT NULL AND NEW.telephone !~ '^\+[1-9][0-9]{7,14}$' THEN
    PERFORM erreur('Telephone au format international attendu (ex. +2376XXXXXXXX).');
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.telephone IS NULL AND (EXISTS (SELECT 1 FROM staff WHERE id_utilisateur = NEW.id_utilisateur)
                                  OR EXISTS (SELECT 1 FROM parent WHERE id_utilisateur = NEW.id_utilisateur)) THEN
      PERFORM erreur('Le telephone est obligatoire pour un compte STAFF ou PARENT.');
    END IF;
    IF NEW.identifiant IS NULL AND EXISTS (SELECT 1 FROM eleve WHERE id_utilisateur = NEW.id_utilisateur) THEN
      PERFORM erreur('L''identifiant est obligatoire pour un compte ELEVE.');
    END IF;
    IF NEW.type_secret = 'PIN' AND EXISTS (SELECT 1 FROM staff WHERE id_utilisateur = NEW.id_utilisateur) THEN
      PERFORM erreur('Le code PIN est reserve aux comptes PARENT et ELEVE ; un STAFF utilise un mot de passe.');
    END IF;
    IF NEW.statut_compte = 'ACTIF' AND NEW.methode_2fa = 'AUCUNE' AND utilisateur_exige_2fa(NEW.id_utilisateur) THEN
      PERFORM erreur('Double authentification obligatoire pour ce compte (DIRECTEUR ou droits sensibles).');
    END IF;
    -- un changement de mot de passe revoque toutes les sessions
    IF NEW.mot_de_passe_hash IS DISTINCT FROM OLD.mot_de_passe_hash THEN
      NEW.date_changement_mdp := now();
      UPDATE session_utilisateur SET date_revocation = now()
       WHERE id_utilisateur = NEW.id_utilisateur AND date_revocation IS NULL;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_utilisateur_regles BEFORE INSERT OR UPDATE ON utilisateur
  FOR EACH ROW EXECUTE FUNCTION fn_utilisateur_regles();

-- [UTILISATEUR] controles au moment ou le compte devient STAFF, PARENT ou ELEVE
CREATE FUNCTION fn_compte_role_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE u utilisateur%ROWTYPE;
BEGIN
  IF NEW.id_utilisateur IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO u FROM utilisateur WHERE id_utilisateur = NEW.id_utilisateur;
  IF TG_TABLE_NAME IN ('staff', 'parent') AND u.telephone IS NULL THEN
    PERFORM erreur('Le telephone est obligatoire pour un compte STAFF ou PARENT.');
  END IF;
  IF TG_TABLE_NAME = 'staff' THEN
    IF u.type_secret = 'PIN' THEN
      PERFORM erreur('Un STAFF doit utiliser un mot de passe (PIN refuse).');
    END IF;
    IF NEW.type_staff = 'DIRECTEUR' AND NEW.statut = 'ACTIF' AND u.statut_compte = 'ACTIF' AND u.methode_2fa = 'AUCUNE' THEN
      PERFORM erreur('Activer la double authentification avant de nommer ce compte DIRECTEUR.');
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'eleve' AND u.identifiant IS NULL THEN
    PERFORM erreur('L''identifiant est obligatoire pour un compte ELEVE.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_staff_compte BEFORE INSERT OR UPDATE OF id_utilisateur, type_staff, statut ON staff
  FOR EACH ROW EXECUTE FUNCTION fn_compte_role_regles();
CREATE TRIGGER trg_parent_compte BEFORE INSERT OR UPDATE OF id_utilisateur ON parent
  FOR EACH ROW EXECUTE FUNCTION fn_compte_role_regles();
CREATE TRIGGER trg_eleve_compte BEFORE INSERT OR UPDATE OF id_utilisateur ON eleve
  FOR EACH ROW EXECUTE FUNCTION fn_compte_role_regles();

-- [ATTRIBUTION_PERMISSION] l'attribuant possede la permission ou est DIRECTEUR ; 2FA si permission sensible
CREATE FUNCTION fn_attribution_permission_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NOT NEW.est_active THEN RETURN NEW; END IF;
  IF NOT staff_est_directeur(NEW.id_staff_attribuant)
     AND NEW.id_permission NOT IN (SELECT permissions_staff(NEW.id_staff_attribuant)) THEN
    PERFORM erreur('L''attribuant doit posseder cette permission (ou etre DIRECTEUR).');
  END IF;
  IF permission_sensible(NEW.id_permission) AND EXISTS (
       SELECT 1 FROM staff s JOIN utilisateur u ON u.id_utilisateur = s.id_utilisateur
        WHERE s.id_staff = NEW.id_staff_beneficiaire AND u.statut_compte = 'ACTIF' AND u.methode_2fa = 'AUCUNE') THEN
    PERFORM erreur('Le beneficiaire doit activer la double authentification avant de recevoir un droit sensible.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_attribution_permission_regles BEFORE INSERT OR UPDATE ON attribution_permission
  FOR EACH ROW EXECUTE FUNCTION fn_attribution_permission_regles();

-- [ATTRIBUTION_ROLE] role commun ou du meme etablissement ; attribuant possede toutes les permissions ; 2FA
CREATE FUNCTION fn_attribution_role_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_etab BIGINT;
BEGIN
  SELECT id_etablissement INTO v_etab FROM role WHERE id_role = NEW.id_role;
  IF v_etab IS NOT NULL AND v_etab <> NEW.id_etablissement THEN
    PERFORM erreur('Ce role appartient a un autre etablissement.');
  END IF;
  IF NOT NEW.est_active THEN RETURN NEW; END IF;
  IF NOT staff_est_directeur(NEW.id_staff_attribuant) AND EXISTS (
       SELECT 1 FROM role_permission rp WHERE rp.id_role = NEW.id_role
          AND rp.id_permission NOT IN (SELECT permissions_staff(NEW.id_staff_attribuant))) THEN
    PERFORM erreur('L''attribuant doit posseder toutes les permissions du role (ou etre DIRECTEUR).');
  END IF;
  IF EXISTS (SELECT 1 FROM role_permission rp WHERE rp.id_role = NEW.id_role AND permission_sensible(rp.id_permission))
     AND EXISTS (SELECT 1 FROM staff s JOIN utilisateur u ON u.id_utilisateur = s.id_utilisateur
                  WHERE s.id_staff = NEW.id_staff_beneficiaire AND u.statut_compte = 'ACTIF' AND u.methode_2fa = 'AUCUNE') THEN
    PERFORM erreur('Le beneficiaire doit activer la double authentification avant de recevoir ce role.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_attribution_role_regles BEFORE INSERT OR UPDATE ON attribution_role
  FOR EACH ROW EXECUTE FUNCTION fn_attribution_role_regles();

-- [SESSION_UTILISATEUR] le role actif doit etre reellement detenu dans l'etablissement actif
CREATE FUNCTION fn_session_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE ok BOOLEAN;
BEGIN
  ok := CASE NEW.role_actif
    WHEN 'ADMIN'  THEN EXISTS (SELECT 1 FROM utilisateur WHERE id_utilisateur = NEW.id_utilisateur AND est_admin_systeme)
    WHEN 'STAFF'  THEN EXISTS (SELECT 1 FROM staff WHERE id_utilisateur = NEW.id_utilisateur
                                  AND id_etablissement = NEW.id_etablissement_actif AND statut = 'ACTIF')
    WHEN 'ELEVE'  THEN EXISTS (SELECT 1 FROM eleve WHERE id_utilisateur = NEW.id_utilisateur
                                  AND id_etablissement = NEW.id_etablissement_actif)
    WHEN 'PARENT' THEN EXISTS (SELECT 1 FROM parent p JOIN eleve_parent ep ON ep.id_parent = p.id_parent
                                WHERE p.id_utilisateur = NEW.id_utilisateur AND ep.id_etablissement = NEW.id_etablissement_actif
                                  AND (ep.date_fin IS NULL OR ep.date_fin >= current_date))
  END;
  IF NOT ok THEN PERFORM erreur('Role actif non detenu dans cet etablissement.'); END IF;
  IF NOT EXISTS (SELECT 1 FROM utilisateur WHERE id_utilisateur = NEW.id_utilisateur AND statut_compte = 'ACTIF') THEN
    PERFORM erreur('Compte non actif : connexion refusee.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_session_regles BEFORE INSERT ON session_utilisateur
  FOR EACH ROW EXECUTE FUNCTION fn_session_regles();

-- ============================================================
-- D. Referentiels mixtes : une valeur propre n'est utilisable que par son etablissement
--    [TYPE_DOCUMENT, TYPE_EVALUATION, TYPE_INCIDENT, MODE_PAIEMENT, CATEGORIE_RESSOURCE]
-- ============================================================
CREATE FUNCTION fn_referentiel_etablissement() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_ref TEXT := TG_ARGV[0]; v_id BIGINT; v_etab BIGINT;
BEGIN
  v_id := (to_jsonb(NEW) ->> ('id_' || v_ref))::bigint;
  IF v_id IS NULL THEN RETURN NEW; END IF;
  EXECUTE format('SELECT id_etablissement FROM %I WHERE %I = $1', v_ref, 'id_' || v_ref) INTO v_etab USING v_id;
  IF v_etab IS NOT NULL AND v_etab <> NEW.id_etablissement THEN
    PERFORM erreur(format('Cette valeur de %s appartient a un autre etablissement.', v_ref));
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_document_referentiel BEFORE INSERT OR UPDATE ON document
  FOR EACH ROW EXECUTE FUNCTION fn_referentiel_etablissement('type_document');
CREATE TRIGGER trg_evaluation_referentiel BEFORE INSERT OR UPDATE ON evaluation
  FOR EACH ROW EXECUTE FUNCTION fn_referentiel_etablissement('type_evaluation');
CREATE TRIGGER trg_incident_referentiel BEFORE INSERT OR UPDATE ON incident
  FOR EACH ROW EXECUTE FUNCTION fn_referentiel_etablissement('type_incident');
CREATE TRIGGER trg_paiement_referentiel BEFORE INSERT OR UPDATE ON paiement
  FOR EACH ROW EXECUTE FUNCTION fn_referentiel_etablissement('mode_paiement');
CREATE TRIGGER trg_ressource_referentiel BEFORE INSERT OR UPDATE ON ressource_numerique
  FOR EACH ROW EXECUTE FUNCTION fn_referentiel_etablissement('categorie_ressource');

-- ============================================================
-- E. Structure academique (domaine 2)
-- ============================================================
-- [ANNEE_SCOLAIRE / PERIODE] gel des donnees d'une annee ou d'une periode CLOTUREE
CREATE FUNCTION verifier_gel(p_annee BIGINT, p_periode BIGINT, p_table TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF p_annee IS NOT NULL AND EXISTS (SELECT 1 FROM annee_scolaire WHERE id_annee_scolaire = p_annee AND statut = 'CLOTUREE') THEN
    PERFORM erreur(format('Annee scolaire cloturee : %s en lecture seule.', p_table));
  END IF;
  IF p_periode IS NOT NULL AND EXISTS (SELECT 1 FROM periode WHERE id_periode = p_periode AND statut = 'CLOTUREE') THEN
    PERFORM erreur(format('Periode cloturee : %s en lecture seule.', p_table));
  END IF;
END $$;

CREATE FUNCTION fn_gel_donnees_cloturees() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE r JSONB; v_annee BIGINT; v_periode BIGINT; v_date DATE; i INT;
BEGIN
  -- exceptions : encaissement (statut d'une creance) et archivage des inscriptions
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'statut') = (to_jsonb(OLD) - 'statut')
     AND (TG_TABLE_NAME = 'creance' OR (TG_TABLE_NAME = 'inscription' AND to_jsonb(NEW) ->> 'statut' = 'ARCHIVEE')) THEN
    RETURN NEW;
  END IF;
  FOR i IN 1..2 LOOP
    IF i = 1 AND TG_OP = 'INSERT' THEN CONTINUE; END IF;
    IF i = 2 AND TG_OP = 'DELETE' THEN CONTINUE; END IF;
    r := CASE WHEN i = 1 THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    v_annee := NULL; v_periode := NULL; v_date := NULL;
    CASE TG_TABLE_NAME
      WHEN 'inscription', 'classe' THEN
        v_annee := (r ->> 'id_annee_scolaire')::bigint;
      WHEN 'enseignement' THEN
        SELECT id_annee_scolaire INTO v_annee FROM classe WHERE id_classe = (r ->> 'id_classe')::bigint;
      WHEN 'creneau', 'affectation_enseignant' THEN
        SELECT c.id_annee_scolaire INTO v_annee FROM enseignement e JOIN classe c ON c.id_classe = e.id_classe
         WHERE e.id_enseignement = (r ->> 'id_enseignement')::bigint;
      WHEN 'evaluation', 'resultat_matiere', 'resultat_periode' THEN
        v_periode := (r ->> 'id_periode')::bigint;
      WHEN 'note' THEN
        SELECT id_periode INTO v_periode FROM evaluation WHERE id_evaluation = (r ->> 'id_evaluation')::bigint;
      WHEN 'resultat_annuel', 'creance', 'presence', 'incident' THEN
        SELECT id_annee_scolaire INTO v_annee FROM inscription WHERE id_inscription = (r ->> 'id_inscription')::bigint;
        IF TG_TABLE_NAME = 'presence' THEN
          v_date := (r ->> 'date_presence')::date;
          SELECT id_periode INTO v_periode FROM periode
           WHERE id_annee_scolaire = v_annee AND v_date BETWEEN date_debut AND date_fin;
        END IF;
      WHEN 'observation_incident', 'decision_disciplinaire' THEN
        SELECT i2.id_annee_scolaire INTO v_annee FROM incident x JOIN inscription i2 ON i2.id_inscription = x.id_inscription
         WHERE x.id_incident = (r ->> 'id_incident')::bigint;
    END CASE;
    IF v_annee IS NULL AND v_periode IS NOT NULL THEN
      SELECT id_annee_scolaire INTO v_annee FROM periode WHERE id_periode = v_periode;
    END IF;
    PERFORM verifier_gel(v_annee, v_periode, TG_TABLE_NAME);
  END LOOP;
  RETURN coalesce(NEW, OLD);
END $$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['inscription', 'classe', 'enseignement', 'creneau', 'affectation_enseignant', 'evaluation',
                           'note', 'resultat_matiere', 'resultat_periode', 'resultat_annuel', 'presence', 'incident',
                           'observation_incident', 'decision_disciplinaire', 'creance']
  LOOP
    EXECUTE format('CREATE TRIGGER trg_%1$s_gel BEFORE INSERT OR UPDATE OR DELETE ON %1$I
                    FOR EACH ROW EXECUTE FUNCTION fn_gel_donnees_cloturees()', t);
  END LOOP;
END $$;

-- [PERIODE] periode incluse dans son annee scolaire
CREATE FUNCTION fn_periode_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM annee_scolaire a WHERE a.id_annee_scolaire = NEW.id_annee_scolaire
                    AND NEW.date_debut >= a.date_debut AND NEW.date_fin <= a.date_fin) THEN
    PERFORM erreur('La periode doit etre incluse dans son annee scolaire.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_periode_regles BEFORE INSERT OR UPDATE ON periode
  FOR EACH ROW EXECUTE FUNCTION fn_periode_regles();

-- [CLASSE] titulaire de type ENSEIGNANT ; effectif maximal respecte
CREATE FUNCTION fn_classe_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NEW.id_staff_titulaire IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM staff WHERE id_staff = NEW.id_staff_titulaire AND type_staff = 'ENSEIGNANT') THEN
    PERFORM erreur('Le titulaire de la classe doit etre un ENSEIGNANT.');
  END IF;
  IF NEW.effectif_max IS NOT NULL AND
     (SELECT count(*) FROM inscription WHERE id_classe = NEW.id_classe AND statut = 'VALIDEE') > NEW.effectif_max THEN
    PERFORM erreur('Effectif maximal inferieur au nombre d''inscriptions validees.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_classe_regles BEFORE INSERT OR UPDATE ON classe
  FOR EACH ROW EXECUTE FUNCTION fn_classe_regles();

-- [AFFECTATION_ENSEIGNANT] staff de type ENSEIGNANT
CREATE FUNCTION fn_affectation_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM staff WHERE id_staff = NEW.id_staff_enseignant AND type_staff = 'ENSEIGNANT') THEN
    PERFORM erreur('Seul un ENSEIGNANT peut etre affecte a un enseignement.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_affectation_regles BEFORE INSERT OR UPDATE ON affectation_enseignant
  FOR EACH ROW EXECUTE FUNCTION fn_affectation_regles();

-- [CRENEAU] validite incluse dans l'annee ; aucun chevauchement classe / enseignant / salle
CREATE FUNCTION fn_creneau_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_classe BIGINT; a annee_scolaire%ROWTYPE; v_conflit TEXT;
BEGIN
  SELECT e.id_classe INTO v_classe FROM enseignement e WHERE e.id_enseignement = NEW.id_enseignement;
  SELECT an.* INTO a FROM classe c JOIN annee_scolaire an ON an.id_annee_scolaire = c.id_annee_scolaire
   WHERE c.id_classe = v_classe;
  IF NEW.date_debut < a.date_debut OR coalesce(NEW.date_fin, a.date_fin) > a.date_fin THEN
    PERFORM erreur('La validite du creneau doit etre incluse dans l''annee scolaire.');
  END IF;
  SELECT CASE WHEN e2.id_classe = v_classe THEN 'la classe'
              WHEN NEW.id_salle IS NOT NULL AND c2.id_salle = NEW.id_salle THEN 'la salle'
              ELSE 'l''enseignant' END
    INTO v_conflit
    FROM creneau c2 JOIN enseignement e2 ON e2.id_enseignement = c2.id_enseignement
   WHERE c2.id_creneau <> coalesce(NEW.id_creneau, -1)
     AND c2.jour_semaine = NEW.jour_semaine
     AND c2.heure_debut < NEW.heure_fin AND c2.heure_fin > NEW.heure_debut
     AND daterange(c2.date_debut, c2.date_fin, '[]') && daterange(NEW.date_debut, NEW.date_fin, '[]')
     AND (e2.id_classe = v_classe
          OR (NEW.id_salle IS NOT NULL AND c2.id_salle = NEW.id_salle)
          OR EXISTS (SELECT 1 FROM affectation_enseignant x JOIN affectation_enseignant y
                         ON y.id_staff_enseignant = x.id_staff_enseignant
                      WHERE x.id_enseignement = NEW.id_enseignement AND y.id_enseignement = c2.id_enseignement
                        AND daterange(x.date_debut, x.date_fin, '[]') && daterange(y.date_debut, y.date_fin, '[]')))
   LIMIT 1;
  IF v_conflit IS NOT NULL THEN
    PERFORM erreur(format('Chevauchement d''horaire : %s a deja un creneau a ce moment.', v_conflit));
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_creneau_regles BEFORE INSERT OR UPDATE ON creneau
  FOR EACH ROW EXECUTE FUNCTION fn_creneau_regles();

-- ============================================================
-- F. Secretariat (domaine 3)
-- ============================================================
-- [ELEVE_PARENT] au moins un responsable legal actif par eleve (verifie en fin de transaction)
CREATE FUNCTION fn_responsable_legal() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_eleve BIGINT := coalesce(OLD.id_eleve, NEW.id_eleve);
BEGIN
  IF EXISTS (SELECT 1 FROM eleve_parent WHERE id_eleve = v_eleve)
     AND NOT EXISTS (SELECT 1 FROM eleve_parent WHERE id_eleve = v_eleve AND est_responsable_legal
                        AND (date_fin IS NULL OR date_fin >= current_date)) THEN
    PERFORM erreur('Chaque eleve doit garder au moins un responsable legal actif.');
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_eleve_parent_responsable AFTER UPDATE OR DELETE ON eleve_parent
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_responsable_legal();

-- [INSCRIPTION / CLASSE] effectif maximal, responsable legal present a la validation
CREATE FUNCTION fn_inscription_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_max SMALLINT;
BEGIN
  IF NEW.statut = 'VALIDEE' AND (TG_OP = 'INSERT' OR OLD.statut IS DISTINCT FROM 'VALIDEE'
                                 OR OLD.id_classe <> NEW.id_classe) THEN
    SELECT effectif_max INTO v_max FROM classe WHERE id_classe = NEW.id_classe FOR UPDATE;
    IF v_max IS NOT NULL AND (SELECT count(*) FROM inscription WHERE id_classe = NEW.id_classe
                                 AND statut = 'VALIDEE' AND id_inscription <> coalesce(NEW.id_inscription, -1)) >= v_max THEN
      PERFORM erreur('Classe complete : effectif maximal atteint.');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM eleve_parent WHERE id_eleve = NEW.id_eleve AND est_responsable_legal
                      AND (date_fin IS NULL OR date_fin >= current_date)) THEN
      PERFORM erreur('Validation impossible : l''eleve n''a aucun responsable legal actif.');
    END IF;
    NEW.date_validation := coalesce(NEW.date_validation, now());
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_inscription_regles BEFORE INSERT OR UPDATE ON inscription
  FOR EACH ROW EXECUTE FUNCTION fn_inscription_regles();

-- [INSCRIPTION -> VALIDEE] compte eleve (si absent) et CARTE_ELEVE crees automatiquement
CREATE FUNCTION fn_inscription_validee() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE e eleve%ROWTYPE; v_etab etablissement%ROWTYPE; a annee_scolaire%ROWTYPE; v_user BIGINT; v_n INT;
BEGIN
  IF NEW.statut <> 'VALIDEE' OR (TG_OP = 'UPDATE' AND OLD.statut = 'VALIDEE') THEN RETURN NULL; END IF;
  SELECT * INTO e FROM eleve WHERE id_eleve = NEW.id_eleve;
  SELECT * INTO v_etab FROM etablissement WHERE id_etablissement = NEW.id_etablissement;
  SELECT * INTO a FROM annee_scolaire WHERE id_annee_scolaire = NEW.id_annee_scolaire;
  -- 1. compte eleve : identifiant = code etablissement + matricule, en attente d'activation, PIN
  IF e.id_utilisateur IS NULL THEN
    INSERT INTO utilisateur (nom, prenom, identifiant, type_secret, statut_compte)
    VALUES (e.nom, e.prenom, v_etab.code || '-' || e.matricule, 'PIN', 'EN_ATTENTE_ACTIVATION')
    RETURNING id_utilisateur INTO v_user;
    UPDATE eleve SET id_utilisateur = v_user WHERE id_eleve = e.id_eleve;
  END IF;
  -- 2. carte eleve de l'annee (la precedente expire) ; le jeton QR imprimable est obtenu par nouveau_jeton_carte()
  IF a.date_fin > current_date THEN
    UPDATE carte_eleve SET statut = 'EXPIREE' WHERE id_eleve = e.id_eleve AND statut = 'ACTIVE';
    SELECT count(*) + 1 INTO v_n FROM carte_eleve WHERE id_eleve = e.id_eleve;
    INSERT INTO carte_eleve (id_etablissement, id_eleve, id_inscription, numero_carte, empreinte_jeton_qr, date_expiration)
    VALUES (NEW.id_etablissement, e.id_eleve, NEW.id_inscription,
            e.matricule || '-' || a.libelle || '-' || v_n,
            encode(digest(gen_random_bytes(32), 'sha256'), 'hex'), a.date_fin);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_inscription_validee AFTER INSERT OR UPDATE OF statut ON inscription
  FOR EACH ROW EXECUTE FUNCTION fn_inscription_validee();

-- [CARTE_ELEVE] expiration = fin de l'annee scolaire de l'inscription
CREATE FUNCTION fn_carte_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_fin DATE;
BEGIN
  SELECT a.date_fin INTO v_fin FROM inscription i JOIN annee_scolaire a ON a.id_annee_scolaire = i.id_annee_scolaire
   WHERE i.id_inscription = NEW.id_inscription;
  NEW.date_expiration := coalesce(NEW.date_expiration, v_fin);
  IF NEW.date_expiration <> v_fin THEN
    PERFORM erreur('La carte expire a la fin de l''annee scolaire de l''inscription.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_carte_regles BEFORE INSERT OR UPDATE OF date_expiration, id_inscription ON carte_eleve
  FOR EACH ROW EXECUTE FUNCTION fn_carte_regles();

-- Jeton QR imprimable : genere un nouveau jeton, stocke son empreinte, renvoie le jeton pour le QR code.
-- A appeler par l'application au moment de produire le PDF de la carte (un ancien QR imprime devient invalide).
CREATE FUNCTION nouveau_jeton_carte(p_carte BIGINT) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_jeton TEXT := encode(gen_random_bytes(32), 'hex');
BEGIN
  UPDATE carte_eleve SET empreinte_jeton_qr = encode(digest(v_jeton, 'sha256'), 'hex')
   WHERE id_carte_eleve = p_carte AND statut = 'ACTIVE'
     AND (id_etablissement = ctx_etablissement() OR ctx_est_admin());
  IF NOT FOUND THEN PERFORM erreur('Carte introuvable, inactive ou hors de votre etablissement.'); END IF;
  RETURN v_jeton;
END $$;

-- Connexion par QR code : renvoie le compte de l'eleve si la carte est active (le PIN est verifie ensuite)
CREATE FUNCTION compte_par_jeton_carte(p_jeton TEXT) RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT e.id_utilisateur FROM carte_eleve c JOIN eleve e ON e.id_eleve = c.id_eleve
   WHERE c.empreinte_jeton_qr = encode(digest(p_jeton, 'sha256'), 'hex')
     AND c.statut = 'ACTIVE' AND c.date_expiration >= current_date;
$$;

-- [DEMANDE] un parent ne peut faire une demande que pour l'un de ses enfants (un eleve : pour lui-meme)
CREATE FUNCTION fn_demande_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NEW.id_eleve IS NULL OR EXISTS (SELECT 1 FROM staff WHERE id_utilisateur = NEW.id_utilisateur_demandeur
                                        AND id_etablissement = NEW.id_etablissement AND statut = 'ACTIF') THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM eleve WHERE id_eleve = NEW.id_eleve AND id_utilisateur = NEW.id_utilisateur_demandeur)
     AND NOT EXISTS (SELECT 1 FROM eleve_parent ep JOIN parent p ON p.id_parent = ep.id_parent
                      WHERE ep.id_eleve = NEW.id_eleve AND p.id_utilisateur = NEW.id_utilisateur_demandeur
                        AND (ep.date_fin IS NULL OR ep.date_fin >= current_date)) THEN
    PERFORM erreur('Demande refusee : cet eleve n''est pas l''un de vos enfants.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_demande_regles BEFORE INSERT OR UPDATE ON demande
  FOR EACH ROW EXECUTE FUNCTION fn_demande_regles();

-- ============================================================
-- G. Pedagogie (domaine 4)
-- ============================================================
-- [EVALUATION] periode de l'annee de la classe ; date dans la periode
CREATE FUNCTION fn_evaluation_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE p periode%ROWTYPE; v_annee BIGINT;
BEGIN
  SELECT * INTO p FROM periode WHERE id_periode = NEW.id_periode;
  SELECT c.id_annee_scolaire INTO v_annee FROM enseignement e JOIN classe c ON c.id_classe = e.id_classe
   WHERE e.id_enseignement = NEW.id_enseignement;
  IF p.id_annee_scolaire <> v_annee THEN
    PERFORM erreur('La periode doit appartenir a l''annee scolaire de la classe.');
  END IF;
  IF NEW.date_evaluation NOT BETWEEN p.date_debut AND p.date_fin THEN
    PERFORM erreur('La date de l''evaluation doit etre comprise dans la periode.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_evaluation_regles BEFORE INSERT OR UPDATE ON evaluation
  FOR EACH ROW EXECUTE FUNCTION fn_evaluation_regles();

-- [NOTE] bornes de la note ; inscription dans la classe evaluee ; evaluation VERROUILLEE intouchable
CREATE FUNCTION fn_note_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE ev evaluation%ROWTYPE; v_classe BIGINT;
BEGIN
  SELECT * INTO ev FROM evaluation WHERE id_evaluation = coalesce(NEW.id_evaluation, OLD.id_evaluation);
  IF ev.statut = 'VERROUILLEE' THEN
    PERFORM erreur('Evaluation verrouillee : notes non modifiables.');
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF NEW.valeur IS NOT NULL AND (NEW.valeur < 0 OR NEW.valeur > ev.note_maximale) THEN
    PERFORM erreur(format('La note doit etre comprise entre 0 et %s.', ev.note_maximale));
  END IF;
  SELECT id_classe INTO v_classe FROM enseignement WHERE id_enseignement = ev.id_enseignement;
  -- nouvelle note : inscription VALIDEE dans la classe (les notes d'une ancienne inscription restent modifiables)
  IF NOT EXISTS (SELECT 1 FROM inscription WHERE id_inscription = NEW.id_inscription AND id_classe = v_classe
                    AND (statut = 'VALIDEE' OR (TG_OP = 'UPDATE' AND OLD.id_inscription = NEW.id_inscription))) THEN
    PERFORM erreur('L''eleve n''est pas inscrit (inscription validee) dans la classe de cet enseignement.');
  END IF;
  IF TG_OP = 'UPDATE' THEN NEW.date_modification := now(); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_note_regles BEFORE INSERT OR UPDATE OR DELETE ON note
  FOR EACH ROW EXECUTE FUNCTION fn_note_regles();

-- Historique automatique des notes (motif facultatif via set_config('app.motif', ..., true))
CREATE FUNCTION fn_note_historique() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.valeur IS NOT DISTINCT FROM OLD.valeur AND NEW.statut_note = OLD.statut_note THEN
    RETURN NULL;
  END IF;
  INSERT INTO historique_note (id_etablissement, id_note, id_staff_modificateur, type_operation,
                               ancienne_valeur, nouvelle_valeur, motif)
  VALUES (NEW.id_etablissement, NEW.id_note, NEW.id_staff_saisie,
          CASE WHEN TG_OP = 'INSERT' THEN 'CREATION' ELSE 'MODIFICATION' END,
          CASE WHEN TG_OP = 'UPDATE' THEN OLD.valeur END, NEW.valeur,
          nullif(current_setting('app.motif', true), ''));
  RETURN NULL;
END $$;
CREATE TRIGGER trg_note_historique AFTER INSERT OR UPDATE ON note
  FOR EACH ROW EXECUTE FUNCTION fn_note_historique();

-- [RESULTAT_MATIERE / RESULTAT_PERIODE / DEROGATION] coherence classe, periode et annee
CREATE FUNCTION fn_resultat_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE i inscription%ROWTYPE; r JSONB := to_jsonb(NEW); v_periode BIGINT;
BEGIN
  SELECT * INTO i FROM inscription WHERE id_inscription = NEW.id_inscription;
  v_periode := (r ->> 'id_periode')::bigint;
  IF v_periode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM periode WHERE id_periode = v_periode
                                              AND id_annee_scolaire = i.id_annee_scolaire) THEN
    PERFORM erreur('La periode doit appartenir a l''annee scolaire de l''inscription.');
  END IF;
  IF TG_TABLE_NAME = 'resultat_matiere' AND NOT EXISTS (
       SELECT 1 FROM enseignement WHERE id_enseignement = (r ->> 'id_enseignement')::bigint AND id_classe = i.id_classe) THEN
    PERFORM erreur('L''enseignement doit etre celui de la classe de l''eleve.');
  END IF;
  IF TG_TABLE_NAME = 'derogation_acces_resultat'
     AND NOT staff_est_directeur((r ->> 'id_staff_accordant')::bigint)
     AND NOT staff_a_permission((r ->> 'id_staff_accordant')::bigint, 'FINANCE_DECIDER') THEN
    PERFORM erreur('Seul le DIRECTEUR (ou un staff habilite FINANCE_DECIDER) peut accorder une derogation.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_resultat_matiere_regles BEFORE INSERT OR UPDATE ON resultat_matiere
  FOR EACH ROW EXECUTE FUNCTION fn_resultat_regles();
CREATE TRIGGER trg_resultat_periode_regles BEFORE INSERT OR UPDATE ON resultat_periode
  FOR EACH ROW EXECUTE FUNCTION fn_resultat_regles();
CREATE TRIGGER trg_derogation_regles BEFORE INSERT OR UPDATE ON derogation_acces_resultat
  FOR EACH ROW EXECUTE FUNCTION fn_resultat_regles();

-- [BLOCAGE DES IMPAYES] le bulletin est-il visible pour l'eleve et ses parents ?
--   p_periode NULL = toute l'annee (resultat annuel)
CREATE FUNCTION est_en_regle(p_inscription BIGINT, p_periode BIGINT) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE i inscription%ROWTYPE; v_fin DATE; v_reste NUMERIC;
BEGIN
  SELECT * INTO i FROM inscription WHERE id_inscription = p_inscription;
  IF upper(parametre(i.id_etablissement, 'BLOCAGE_RESULTATS_IMPAYES', 'FALSE')) <> 'TRUE' THEN RETURN TRUE; END IF;
  IF EXISTS (SELECT 1 FROM derogation_acces_resultat d
              WHERE d.id_inscription = p_inscription AND d.est_active
                AND (d.date_fin_validite IS NULL OR d.date_fin_validite >= current_date)
                AND (d.id_periode IS NULL OR d.id_periode = p_periode)) THEN
    RETURN TRUE;
  END IF;
  IF p_periode IS NULL THEN   -- toute l'annee : echeances deja echues (a la fin de l'annee : toutes)
    SELECT least(date_fin, current_date) INTO v_fin FROM annee_scolaire WHERE id_annee_scolaire = i.id_annee_scolaire;
  ELSE
    SELECT date_fin INTO v_fin FROM periode WHERE id_periode = p_periode;
  END IF;
  -- toutes les inscriptions de l'eleve sur l'annee (un changement de classe ne remet pas les compteurs a zero)
  SELECT coalesce(sum(reste_du(c.id_creance)), 0) INTO v_reste
    FROM creance c
    JOIN inscription i2 ON i2.id_inscription = c.id_inscription
    JOIN echeance e ON e.id_echeance = c.id_echeance
    JOIN frais_scolaire f ON f.id_frais_scolaire = e.id_frais_scolaire
   WHERE i2.id_eleve = i.id_eleve AND i2.id_annee_scolaire = i.id_annee_scolaire
     AND c.statut <> 'ANNULEE' AND f.obligatoire AND e.date_limite <= v_fin;
  RETURN v_reste <= parametre(i.id_etablissement, 'SEUIL_TOLERANCE_IMPAYE', '0')::numeric;
END $$;

-- ============================================================
-- H. Surveillance (domaine 5)
-- ============================================================
-- [PRESENCE] jour du creneau, date dans sa validite, eleve de la classe du creneau
CREATE FUNCTION fn_presence_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE c creneau%ROWTYPE; v_classe BIGINT;
BEGIN
  IF NEW.id_creneau IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO c FROM creneau WHERE id_creneau = NEW.id_creneau;
  IF extract(isodow FROM NEW.date_presence) <> c.jour_semaine THEN
    PERFORM erreur('La date de presence ne correspond pas au jour du creneau.');
  END IF;
  IF NEW.date_presence < c.date_debut OR (c.date_fin IS NOT NULL AND NEW.date_presence > c.date_fin) THEN
    PERFORM erreur('La date de presence est hors de la periode de validite du creneau.');
  END IF;
  SELECT id_classe INTO v_classe FROM enseignement WHERE id_enseignement = c.id_enseignement;
  IF NOT EXISTS (SELECT 1 FROM inscription WHERE id_inscription = NEW.id_inscription AND id_classe = v_classe) THEN
    PERFORM erreur('L''eleve n''appartient pas a la classe de ce creneau.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_presence_regles BEFORE INSERT OR UPDATE ON presence
  FOR EACH ROW EXECUTE FUNCTION fn_presence_regles();

-- [DECISION_DISCIPLINAIRE] EXCLUSION_DEFINITIVE APPLIQUEE => l'eleve passe au statut EXCLU
CREATE FUNCTION fn_decision_exclusion() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NEW.type_sanction = 'EXCLUSION_DEFINITIVE' AND NEW.statut = 'APPLIQUEE' THEN
    UPDATE eleve e SET statut = 'EXCLU'
      FROM incident x JOIN inscription i ON i.id_inscription = x.id_inscription
     WHERE x.id_incident = NEW.id_incident AND e.id_eleve = i.id_eleve AND e.statut <> 'EXCLU';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_decision_exclusion AFTER INSERT OR UPDATE OF statut ON decision_disciplinaire
  FOR EACH ROW EXECUTE FUNCTION fn_decision_exclusion();

-- ============================================================
-- I. Finance (domaine 6)
-- ============================================================
-- [ECHEANCE] la somme des echeances d'un frais est egale a son montant (fin de transaction)
CREATE FUNCTION fn_echeancier_complet() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_frais BIGINT; v_montant NUMERIC; v_somme NUMERIC;
BEGIN
  v_frais := CASE WHEN TG_TABLE_NAME = 'frais_scolaire' THEN NEW.id_frais_scolaire
                  ELSE (to_jsonb(coalesce(NEW, OLD)) ->> 'id_frais_scolaire')::bigint END;
  SELECT montant INTO v_montant FROM frais_scolaire WHERE id_frais_scolaire = v_frais;
  SELECT sum(montant) INTO v_somme FROM echeance WHERE id_frais_scolaire = v_frais;
  IF v_somme IS NOT NULL AND v_somme <> v_montant THEN
    PERFORM erreur(format('Echeancier incomplet : la somme des echeances (%s) doit egaler le montant du frais (%s).',
                          v_somme, v_montant));
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_echeance_somme AFTER INSERT OR UPDATE OR DELETE ON echeance
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_echeancier_complet();
CREATE CONSTRAINT TRIGGER trg_frais_somme AFTER UPDATE OF montant ON frais_scolaire
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_echeancier_complet();

-- [CREANCE / REGLE_REDUCTION] reduction famille applicable a une creance
CREATE FUNCTION reduction_applicable(p_inscription BIGINT, p_echeance BIGINT, p_montant NUMERIC,
                                     OUT id_regle BIGINT, OUT montant NUMERIC)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE i inscription%ROWTYPE; v_famille BIGINT; v_frais BIGINT; v_rang INT;
BEGIN
  montant := 0;
  SELECT * INTO i FROM inscription WHERE id_inscription = p_inscription;
  SELECT id_famille INTO v_famille FROM eleve WHERE id_eleve = i.id_eleve;
  IF v_famille IS NULL THEN RETURN; END IF;
  SELECT id_frais_scolaire INTO v_frais FROM echeance WHERE id_echeance = p_echeance;
  -- rang de l'enfant : du plus age au plus jeune parmi les enfants inscrits de la famille sur l'annee
  SELECT x.rang INTO v_rang FROM (
    SELECT e.id_eleve, row_number() OVER (ORDER BY e.date_naissance, e.id_eleve) AS rang
      FROM eleve e
     WHERE e.id_famille = v_famille
       AND (e.id_eleve = i.id_eleve OR EXISTS (SELECT 1 FROM inscription i2 WHERE i2.id_eleve = e.id_eleve
               AND i2.id_annee_scolaire = i.id_annee_scolaire AND i2.statut = 'VALIDEE'))) x
   WHERE x.id_eleve = i.id_eleve;
  SELECT r.id_regle_reduction,
         CASE r.mode_calcul WHEN 'POURCENTAGE' THEN round(p_montant * r.valeur / 100, 0)
                            ELSE least(r.valeur, p_montant) END AS m
    INTO id_regle, montant
    FROM regle_reduction r
   WHERE r.id_annee_scolaire = i.id_annee_scolaire AND r.est_active AND r.type_reduction = 'FRATRIE'
     AND r.rang_enfant_min <= v_rang AND (r.id_frais_scolaire IS NULL OR r.id_frais_scolaire = v_frais)
   ORDER BY m DESC LIMIT 1;
  montant := coalesce(montant, 0);
END $$;

-- [CREANCE] echeance de l'annee et du niveau de l'eleve ; reduction automatique ; statut a jour
CREATE FUNCTION fn_creance_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE i inscription%ROWTYPE; f frais_scolaire%ROWTYPE; v_niveau BIGINT; red RECORD;
BEGIN
  SELECT * INTO i FROM inscription WHERE id_inscription = NEW.id_inscription;
  SELECT fs.* INTO f FROM echeance e JOIN frais_scolaire fs ON fs.id_frais_scolaire = e.id_frais_scolaire
   WHERE e.id_echeance = NEW.id_echeance;
  SELECT id_niveau INTO v_niveau FROM classe WHERE id_classe = i.id_classe;
  IF f.id_annee_scolaire <> i.id_annee_scolaire THEN
    PERFORM erreur('L''echeance doit appartenir a l''annee scolaire de l''inscription.');
  END IF;
  IF f.id_niveau IS NOT NULL AND f.id_niveau <> v_niveau THEN
    PERFORM erreur('Ce frais concerne un autre niveau que celui de la classe de l''eleve.');
  END IF;
  IF TG_OP = 'INSERT' AND NEW.id_regle_reduction IS NULL AND NEW.remise_reduction = 0 THEN
    red := reduction_applicable(NEW.id_inscription, NEW.id_echeance, NEW.montant_du);
    IF red.montant > 0 THEN
      NEW.id_regle_reduction := red.id_regle;
      NEW.remise_reduction := least(red.montant, NEW.montant_du - NEW.remise);
    END IF;
  ELSIF NEW.id_regle_reduction IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM regle_reduction WHERE id_regle_reduction = NEW.id_regle_reduction
             AND id_annee_scolaire = i.id_annee_scolaire) THEN
    PERFORM erreur('La regle de reduction doit etre celle de l''annee de l''inscription.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_creance_regles BEFORE INSERT OR UPDATE OF id_inscription, id_echeance, id_regle_reduction,
  remise_reduction, montant_du ON creance FOR EACH ROW EXECUTE FUNCTION fn_creance_regles();

-- [FAMILLE] recalcul des reductions des creances non encore payees quand la famille change
CREATE FUNCTION recalculer_reductions_famille(p_famille BIGINT, p_annee BIGINT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE c RECORD; red RECORD;
BEGIN
  FOR c IN SELECT cr.* FROM creance cr
             JOIN inscription i ON i.id_inscription = cr.id_inscription
             JOIN eleve e ON e.id_eleve = i.id_eleve
            WHERE e.id_famille = p_famille AND i.id_annee_scolaire = p_annee AND cr.statut = 'DUE'
              AND NOT EXISTS (SELECT 1 FROM allocation_paiement a WHERE a.id_creance = cr.id_creance)
  LOOP
    red := reduction_applicable(c.id_inscription, c.id_echeance, c.montant_du);
    UPDATE creance SET id_regle_reduction = CASE WHEN red.montant > 0 THEN red.id_regle END,
                       remise_reduction   = least(red.montant, c.montant_du - c.remise)
     WHERE id_creance = c.id_creance;
  END LOOP;
END $$;

CREATE FUNCTION fn_famille_changement() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_famille BIGINT; v_annee BIGINT; f BIGINT;
BEGIN
  IF TG_TABLE_NAME = 'eleve' THEN
    FOR v_annee IN SELECT DISTINCT id_annee_scolaire FROM inscription WHERE id_eleve = NEW.id_eleve LOOP
      FOREACH f IN ARRAY ARRAY[OLD.id_famille, NEW.id_famille] LOOP
        IF f IS NOT NULL THEN PERFORM recalculer_reductions_famille(f, v_annee); END IF;
      END LOOP;
    END LOOP;
  ELSE  -- inscription : statut modifie (validation, annulation, changement de classe...)
    SELECT id_famille INTO v_famille FROM eleve WHERE id_eleve = NEW.id_eleve;
    IF v_famille IS NOT NULL THEN PERFORM recalculer_reductions_famille(v_famille, NEW.id_annee_scolaire); END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_eleve_famille AFTER UPDATE OF id_famille ON eleve
  FOR EACH ROW WHEN (OLD.id_famille IS DISTINCT FROM NEW.id_famille) EXECUTE FUNCTION fn_famille_changement();
CREATE TRIGGER trg_inscription_famille AFTER UPDATE OF statut ON inscription
  FOR EACH ROW WHEN (OLD.statut IS DISTINCT FROM NEW.statut) EXECUTE FUNCTION fn_famille_changement();

-- [ALLOCATION_PAIEMENT] plafonds, payeur responsable financier ; statut des creances a jour
CREATE FUNCTION fn_allocation_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE p paiement%ROWTYPE; v_deja NUMERIC; v_reste NUMERIC;
BEGIN
  SELECT * INTO p FROM paiement WHERE id_paiement = NEW.id_paiement;
  SELECT coalesce(sum(montant_alloue), 0) INTO v_deja FROM allocation_paiement
   WHERE id_paiement = NEW.id_paiement AND id_allocation_paiement <> coalesce(NEW.id_allocation_paiement, -1);
  IF v_deja + NEW.montant_alloue > p.montant THEN
    PERFORM erreur('La somme allouee depasse le montant du paiement.');
  END IF;
  v_reste := reste_du(NEW.id_creance)
             + CASE WHEN TG_OP = 'UPDATE' AND OLD.id_creance = NEW.id_creance THEN OLD.montant_alloue ELSE 0 END;
  IF NEW.montant_alloue > v_reste THEN
    PERFORM erreur(format('Montant alloue superieur au reste du de la creance (%s).', v_reste));
  END IF;
  IF p.id_parent_payeur IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM creance c JOIN inscription i ON i.id_inscription = c.id_inscription
         JOIN eleve_parent ep ON ep.id_eleve = i.id_eleve
        WHERE c.id_creance = NEW.id_creance AND ep.id_parent = p.id_parent_payeur AND ep.est_responsable_financier
          AND (ep.date_fin IS NULL OR ep.date_fin >= current_date)) THEN
    PERFORM erreur('Le parent payeur n''est pas responsable financier de cet eleve.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_allocation_regles BEFORE INSERT OR UPDATE ON allocation_paiement
  FOR EACH ROW EXECUTE FUNCTION fn_allocation_regles();

CREATE FUNCTION fn_allocation_statut() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN PERFORM maj_statut_creance(OLD.id_creance); END IF;
  IF TG_OP <> 'DELETE' THEN PERFORM maj_statut_creance(NEW.id_creance); END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_allocation_statut AFTER INSERT OR UPDATE OR DELETE ON allocation_paiement
  FOR EACH ROW EXECUTE FUNCTION fn_allocation_statut();

-- Paiement annule (ou revalide) : statut des creances recalcule
CREATE FUNCTION fn_paiement_statut() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE c BIGINT;
BEGIN
  FOR c IN SELECT DISTINCT id_creance FROM allocation_paiement WHERE id_paiement = NEW.id_paiement LOOP
    PERFORM maj_statut_creance(c);
  END LOOP;
  RETURN NULL;
END $$;
CREATE TRIGGER trg_paiement_statut AFTER UPDATE OF statut ON paiement
  FOR EACH ROW WHEN (OLD.statut IS DISTINCT FROM NEW.statut) EXECUTE FUNCTION fn_paiement_statut();

-- Detail fige d'un recu : eleves, mois / echeances payes, montants et reste du
CREATE FUNCTION detail_recu(p_paiement BIGINT) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT jsonb_build_object(
    'etablissement', et.nom, 'paiement', p.numero, 'date_paiement', p.date_paiement,
    'mode', m.libelle, 'canal', p.canal, 'reference_externe', p.reference_externe,
    'lignes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'eleve', e.nom || ' ' || e.prenom, 'matricule', e.matricule, 'classe', cl.nom,
               'frais', f.libelle, 'echeance', ec.libelle, 'mois', ec.mois_concerne,
               'montant_paye', a.montant_alloue, 'reste_du', reste_du(c.id_creance)) ORDER BY e.nom, ec.date_limite)
        FROM allocation_paiement a
        JOIN creance c ON c.id_creance = a.id_creance
        JOIN inscription i ON i.id_inscription = c.id_inscription
        JOIN eleve e ON e.id_eleve = i.id_eleve
        JOIN classe cl ON cl.id_classe = i.id_classe
        JOIN echeance ec ON ec.id_echeance = c.id_echeance
        JOIN frais_scolaire f ON f.id_frais_scolaire = ec.id_frais_scolaire
       WHERE a.id_paiement = p.id_paiement), '[]'::jsonb))
    FROM paiement p
    JOIN etablissement et ON et.id_etablissement = p.id_etablissement
    JOIN mode_paiement m ON m.id_mode_paiement = p.id_mode_paiement
   WHERE p.id_paiement = p_paiement;
$$;

-- [RECU] emetteur obligatoire sauf paiement EN_LIGNE ; montant = paiement ; contenu fige rempli
CREATE FUNCTION fn_recu_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE p paiement%ROWTYPE;
BEGIN
  SELECT * INTO p FROM paiement WHERE id_paiement = NEW.id_paiement;
  IF NEW.id_staff_emetteur IS NULL AND p.canal <> 'EN_LIGNE' THEN
    PERFORM erreur('Un recu de guichet doit indiquer le staff emetteur.');
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.montant := coalesce(NEW.montant, p.montant);
    NEW.devise := coalesce(NEW.devise, (SELECT devise FROM etablissement WHERE id_etablissement = p.id_etablissement));
    NEW.nom_payeur := coalesce(NEW.nom_payeur, p.nom_payeur,
                        (SELECT u.nom || ' ' || u.prenom FROM parent pa JOIN utilisateur u ON u.id_utilisateur = pa.id_utilisateur
                          WHERE pa.id_parent = p.id_parent_payeur));
    NEW.detail := coalesce(NEW.detail, detail_recu(NEW.id_paiement));
    NEW.code_verification := coalesce(NEW.code_verification, encode(gen_random_bytes(16), 'hex'));
  ELSIF to_jsonb(NEW) - ARRAY['statut', 'fichier'] <> to_jsonb(OLD) - ARRAY['statut', 'fichier'] THEN
    PERFORM erreur('Un recu emis est fige : seuls son statut et son fichier peuvent evoluer.');
  END IF;
  IF NEW.montant <> p.montant THEN
    PERFORM erreur('Le montant du recu doit etre egal au montant du paiement.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_recu_regles BEFORE INSERT OR UPDATE ON recu
  FOR EACH ROW EXECUTE FUNCTION fn_recu_regles();

-- ============================================================
-- J. Paiement en ligne et commission (domaine 9)
-- ============================================================
-- [TRANSACTION_EN_LIGNE] contrat actif, commission figee, montant total, pays et devise
CREATE FUNCTION fn_transaction_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE cfg config_paiement_etablissement%ROWTYPE; ct contrat_plateforme%ROWTYPE; py pays%ROWTYPE; v_total NUMERIC;
BEGIN
  SELECT * INTO cfg FROM config_paiement_etablissement WHERE id_config_paiement_etablissement = NEW.id_config_paiement_etablissement;
  SELECT * INTO ct FROM contrat_plateforme WHERE id_contrat_plateforme = NEW.id_contrat_plateforme;
  SELECT * INTO py FROM pays WHERE id_pays = NEW.id_pays;
  IF TG_OP = 'INSERT' THEN
    IF NOT cfg.est_actif THEN PERFORM erreur('Configuration de paiement inactive pour cet etablissement.'); END IF;
    IF ct.statut <> 'ACTIF' OR current_date < ct.date_debut OR (ct.date_fin IS NOT NULL AND current_date > ct.date_fin) THEN
      PERFORM erreur('Aucun contrat plateforme actif : paiement en ligne indisponible.');
    END IF;
    NEW.taux_commission := ct.taux_commission;
    NEW.montant_commission := round(NEW.montant * ct.taux_commission / 100, 0);
    IF NEW.mode_perception_commission IS NULL THEN
      SELECT CASE WHEN supporte_partage THEN 'PARTAGE' ELSE 'FACTURATION' END INTO NEW.mode_perception_commission
        FROM fournisseur_paiement WHERE id_fournisseur_paiement = cfg.id_fournisseur_paiement;
    END IF;
    NEW.devise := coalesce(NEW.devise, py.devise);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM fournisseur_pays WHERE id_fournisseur_paiement = cfg.id_fournisseur_paiement
                    AND id_pays = NEW.id_pays AND est_actif) THEN
    PERFORM erreur('Ce fournisseur ne dessert pas le pays de ce numero.');
  END IF;
  IF NEW.devise <> py.devise THEN PERFORM erreur('La devise doit etre celle du pays du numero.'); END IF;
  IF left(NEW.numero_telephone, length(py.indicatif_telephonique)) <> py.indicatif_telephonique THEN
    PERFORM erreur('Le numero ne commence pas par l''indicatif du pays.');
  END IF;
  v_total := NEW.montant
           + CASE WHEN cfg.frais_a_charge = 'PARENT' THEN NEW.frais_operateur ELSE 0 END
           + CASE WHEN ct.commission_a_charge = 'PARENT' THEN NEW.montant_commission ELSE 0 END;
  IF NEW.montant_total IS NULL THEN NEW.montant_total := v_total;
  ELSIF NEW.montant_total <> v_total THEN
    PERFORM erreur(format('Montant total incoherent : %s attendu.', v_total));
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_transaction_regles BEFORE INSERT OR UPDATE ON transaction_en_ligne
  FOR EACH ROW EXECUTE FUNCTION fn_transaction_regles();

-- [TRANSACTION_CREANCE] initiateur responsable financier ; montant <= reste du
CREATE FUNCTION fn_transaction_creance_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM transaction_en_ligne t
                   JOIN parent pa ON pa.id_utilisateur = t.id_utilisateur_initiateur
                   JOIN eleve_parent ep ON ep.id_parent = pa.id_parent
                   JOIN inscription i ON i.id_eleve = ep.id_eleve
                   JOIN creance c ON c.id_inscription = i.id_inscription
                  WHERE t.id_transaction_en_ligne = NEW.id_transaction_en_ligne AND c.id_creance = NEW.id_creance
                    AND ep.est_responsable_financier AND (ep.date_fin IS NULL OR ep.date_fin >= current_date)) THEN
    PERFORM erreur('L''initiateur n''est pas responsable financier de l''eleve de cette creance.');
  END IF;
  IF NEW.montant > reste_du(NEW.id_creance) THEN
    PERFORM erreur('Montant superieur au reste du de la creance.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_transaction_creance_regles BEFORE INSERT OR UPDATE ON transaction_creance
  FOR EACH ROW EXECUTE FUNCTION fn_transaction_creance_regles();

-- [TRANSACTION_CREANCE] somme des lignes = montant de la transaction (fin de transaction)
CREATE FUNCTION fn_transaction_somme() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_id BIGINT := (to_jsonb(coalesce(NEW, OLD)) ->> 'id_transaction_en_ligne')::bigint;
        v_montant NUMERIC; v_somme NUMERIC;
BEGIN
  SELECT montant INTO v_montant FROM transaction_en_ligne WHERE id_transaction_en_ligne = v_id;
  SELECT coalesce(sum(montant), 0) INTO v_somme FROM transaction_creance WHERE id_transaction_en_ligne = v_id;
  IF v_somme <> v_montant THEN
    PERFORM erreur(format('Transaction %s : la somme des creances ciblees (%s) doit egaler son montant (%s).',
                          v_id, v_somme, v_montant));
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_transaction_somme AFTER INSERT OR UPDATE OF montant ON transaction_en_ligne
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_transaction_somme();
CREATE CONSTRAINT TRIGGER trg_transaction_creance_somme AFTER INSERT OR UPDATE OR DELETE ON transaction_creance
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_transaction_somme();

-- Finalisation d'une transaction reussie (appelee apres re-verification du statut aupres du fournisseur) :
-- PAIEMENT (EN_LIGNE, VALIDE) + ALLOCATION_PAIEMENT + RECU, dans la meme transaction SQL.
CREATE FUNCTION finaliser_transaction(p_transaction BIGINT, p_reference_fournisseur TEXT) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE t transaction_en_ligne%ROWTYPE; v_mode BIGINT; v_parent BIGINT; v_payeur TEXT; v_paiement BIGINT;
BEGIN
  SELECT * INTO t FROM transaction_en_ligne WHERE id_transaction_en_ligne = p_transaction FOR UPDATE;
  IF t.statut = 'REUSSIE' THEN   -- notification en double : rien a refaire
    RETURN (SELECT id_paiement FROM paiement WHERE id_transaction_en_ligne = p_transaction);
  END IF;
  IF t.statut NOT IN ('INITIEE', 'EN_ATTENTE') THEN
    PERFORM erreur(format('Transaction %s au statut %s : finalisation impossible.', p_transaction, t.statut));
  END IF;
  SELECT m.id_mode_paiement INTO v_mode
    FROM mode_paiement m JOIN config_paiement_etablissement c ON c.id_fournisseur_paiement = m.id_fournisseur_paiement
   WHERE c.id_config_paiement_etablissement = t.id_config_paiement_etablissement AND m.est_actif
     AND (m.id_etablissement IS NULL OR m.id_etablissement = t.id_etablissement)
   ORDER BY m.id_etablissement NULLS LAST LIMIT 1;
  IF v_mode IS NULL THEN PERFORM erreur('Aucun mode de paiement associe a ce fournisseur.'); END IF;
  SELECT pa.id_parent, u.nom || ' ' || u.prenom INTO v_parent, v_payeur
    FROM utilisateur u LEFT JOIN parent pa ON pa.id_utilisateur = u.id_utilisateur
   WHERE u.id_utilisateur = t.id_utilisateur_initiateur;
  UPDATE transaction_en_ligne SET statut = 'REUSSIE', reference_fournisseur = p_reference_fournisseur,
         date_confirmation = now() WHERE id_transaction_en_ligne = p_transaction;
  INSERT INTO paiement (id_etablissement, id_mode_paiement, id_parent_payeur, id_transaction_en_ligne, numero,
                        montant, date_paiement, canal, reference_externe, nom_payeur, telephone_payeur, statut, date_validation)
  VALUES (t.id_etablissement, v_mode, v_parent, p_transaction, 'EL-' || t.reference_interne,
          round(t.montant * t.taux_change, 2), now(), 'EN_LIGNE', p_reference_fournisseur, v_payeur,
          t.numero_telephone, 'VALIDE', now())
  RETURNING id_paiement INTO v_paiement;
  INSERT INTO allocation_paiement (id_etablissement, id_paiement, id_creance, montant_alloue)
  SELECT t.id_etablissement, v_paiement, tc.id_creance, round(tc.montant * t.taux_change, 2)
    FROM transaction_creance tc WHERE tc.id_transaction_en_ligne = p_transaction;
  INSERT INTO recu (id_paiement, id_etablissement, numero)
  VALUES (v_paiement, t.id_etablissement, 'R-' || t.reference_interne);
  RETURN v_paiement;
END $$;

-- [FACTURE_COMMISSION] montant = somme des commissions FACTURATION du mois (fin de transaction)
CREATE FUNCTION fn_facture_commission_somme() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE v_somme NUMERIC;
BEGIN
  IF NEW.statut NOT IN ('EMISE', 'PAYEE') THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM transaction_en_ligne WHERE id_facture_commission = NEW.id_facture_commission
                AND (statut <> 'REUSSIE' OR date_trunc('month', date_confirmation)::date <> NEW.mois)) THEN
    PERFORM erreur('La facture ne doit contenir que des transactions REUSSIE confirmees dans le mois facture.');
  END IF;
  SELECT coalesce(sum(montant_commission), 0) INTO v_somme FROM transaction_en_ligne
   WHERE id_facture_commission = NEW.id_facture_commission;
  IF v_somme <> NEW.montant_total THEN
    PERFORM erreur(format('Montant de facture incoherent : %s attendu.', v_somme));
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER trg_facture_commission_somme AFTER INSERT OR UPDATE ON facture_commission
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_facture_commission_somme();

-- ============================================================
-- K. Bibliotheque numerique (domaine 8)
-- ============================================================
CREATE FUNCTION staff_affecte_classe(p_staff BIGINT, p_classe BIGINT, p_date DATE) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
  SELECT EXISTS (SELECT 1 FROM affectation_enseignant a JOIN enseignement e ON e.id_enseignement = a.id_enseignement
                  WHERE a.id_staff_enseignant = p_staff AND e.id_classe = p_classe
                    AND p_date BETWEEN a.date_debut AND coalesce(a.date_fin, 'infinity'::date));
$$;

-- [RESSOURCE_NUMERIQUE] validateur habilite ; publication sans validation reservee aux classes de l'auteur
CREATE FUNCTION fn_ressource_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NEW.id_staff_validateur IS NOT NULL AND NOT staff_est_directeur(NEW.id_staff_validateur)
     AND NOT staff_a_permission(NEW.id_staff_validateur, 'BIBLIOTHEQUE_VALIDER') THEN
    PERFORM erreur('Le validateur doit etre DIRECTEUR ou habilite BIBLIOTHEQUE_VALIDER.');
  END IF;
  IF NEW.statut = 'PUBLIEE' THEN
    NEW.date_publication := coalesce(NEW.date_publication, now());
    IF NEW.id_staff_validateur IS NULL AND (
         NOT EXISTS (SELECT 1 FROM ressource_diffusion WHERE id_ressource_numerique = NEW.id_ressource_numerique)
         OR EXISTS (SELECT 1 FROM ressource_diffusion d WHERE d.id_ressource_numerique = NEW.id_ressource_numerique
                       AND (d.id_classe IS NULL OR NOT staff_affecte_classe(NEW.id_staff_auteur, d.id_classe, d.date_debut)))) THEN
      PERFORM erreur('Sans validation, une ressource ne peut etre publiee que pour vos propres classes.');
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_ressource_regles BEFORE INSERT OR UPDATE ON ressource_numerique
  FOR EACH ROW EXECUTE FUNCTION fn_ressource_regles();

-- [RESSOURCE_DIFFUSION] classe : diffuseur affecte ou habilite ; niveau / etablissement : ressource validee ;
--                       evaluation de la classe visee
CREATE FUNCTION fn_diffusion_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE r ressource_numerique%ROWTYPE;
BEGIN
  SELECT * INTO r FROM ressource_numerique WHERE id_ressource_numerique = NEW.id_ressource_numerique;
  IF NEW.id_classe IS NULL AND r.id_staff_validateur IS NULL THEN
    PERFORM erreur('Diffusion a un niveau ou a tout l''etablissement : la ressource doit d''abord etre validee.');
  END IF;
  IF NEW.id_classe IS NOT NULL AND NOT staff_affecte_classe(NEW.id_staff_diffuseur, NEW.id_classe, NEW.date_debut)
     AND NOT staff_est_directeur(NEW.id_staff_diffuseur)
     AND NOT staff_a_permission(NEW.id_staff_diffuseur, 'BIBLIOTHEQUE_VALIDER') THEN
    PERFORM erreur('Vous n''etes pas affecte a cette classe.');
  END IF;
  IF NEW.id_evaluation IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM evaluation ev JOIN enseignement e ON e.id_enseignement = ev.id_enseignement
        WHERE ev.id_evaluation = NEW.id_evaluation AND e.id_classe = NEW.id_classe) THEN
    PERFORM erreur('L''evaluation doit appartenir a un enseignement de la classe visee.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_diffusion_regles BEFORE INSERT OR UPDATE ON ressource_diffusion
  FOR EACH ROW EXECUTE FUNCTION fn_diffusion_regles();

-- [CONSULTATION_RESSOURCE] telechargement seulement si la licence le permet
CREATE FUNCTION fn_consultation_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
BEGIN
  IF NEW.type_consultation = 'TELECHARGEMENT' AND NOT EXISTS (
       SELECT 1 FROM ressource_numerique WHERE id_ressource_numerique = NEW.id_ressource_numerique
          AND licence = 'TELECHARGEABLE') THEN
    PERFORM erreur('Ressource en lecture seule : telechargement interdit.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_consultation_regles BEFORE INSERT ON consultation_ressource
  FOR EACH ROW EXECUTE FUNCTION fn_consultation_regles();

-- [RENDU_TRAVAIL] diffusion avec rendu attendu ; eleve inscrit dans la classe visee
CREATE FUNCTION fn_rendu_regles() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gestion_scolaire, public AS $$
DECLARE d ressource_diffusion%ROWTYPE;
BEGIN
  SELECT * INTO d FROM ressource_diffusion WHERE id_ressource_diffusion = NEW.id_ressource_diffusion;
  IF NOT d.rendu_attendu THEN PERFORM erreur('Aucun rendu n''est attendu pour cette diffusion.'); END IF;
  IF NOT EXISTS (SELECT 1 FROM inscription WHERE id_inscription = NEW.id_inscription
                    AND id_classe = d.id_classe AND statut = 'VALIDEE') THEN
    PERFORM erreur('L''eleve n''est pas inscrit dans la classe visee par ce devoir.');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_rendu_regles BEFORE INSERT OR UPDATE ON rendu_travail
  FOR EACH ROW EXECUTE FUNCTION fn_rendu_regles();

RESET ROLE;
