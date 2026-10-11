-- ============================================================
-- 99 - Scenario de recette (A EXECUTER SUR UNE BASE DE TEST UNIQUEMENT)
-- Deux etablissements, parcours complet ; chaque regle est testee dans les deux sens.
-- Toute anomalie arrete le script (ON_ERROR_STOP) avec le nom du test en echec.
-- ============================================================
\set ON_ERROR_STOP 1
\set QUIET 1
SET search_path TO gestion_scolaire, public;
SET client_min_messages TO notice;

-- Outils de test --------------------------------------------------------------
CREATE TABLE pg_temp.ids (nom TEXT PRIMARY KEY, id BIGINT);
GRANT SELECT ON pg_temp.ids TO gs_application;
CREATE FUNCTION pg_temp.id(p TEXT) RETURNS BIGINT LANGUAGE sql AS $$ SELECT id FROM pg_temp.ids WHERE nom = p $$;
CREATE FUNCTION pg_temp.garder(p TEXT, v BIGINT) RETURNS BIGINT LANGUAGE sql AS
  $$ INSERT INTO pg_temp.ids VALUES (p, v) ON CONFLICT (nom) DO UPDATE SET id = excluded.id RETURNING id $$;
CREATE FUNCTION pg_temp.ok(p_test TEXT, p_cond BOOLEAN) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'TEST ECHOUE : %', p_test; END IF;
  RAISE NOTICE 'OK      %', p_test;
END $$;
CREATE FUNCTION pg_temp.refus(p_test TEXT, p_sql TEXT, p_motif TEXT DEFAULT NULL) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_refuse BOOLEAN := FALSE; v_msg TEXT;
BEGIN
  BEGIN
    SET CONSTRAINTS ALL IMMEDIATE;
    EXECUTE p_sql;
    SET CONSTRAINTS ALL DEFERRED;
  EXCEPTION WHEN OTHERS THEN v_refuse := TRUE; v_msg := SQLERRM;
  END;
  IF NOT v_refuse THEN RAISE EXCEPTION 'TEST ECHOUE (aurait du etre refuse) : %', p_test; END IF;
  IF p_motif IS NOT NULL AND v_msg NOT ILIKE '%' || p_motif || '%' THEN
    RAISE EXCEPTION 'TEST ECHOUE (mauvais motif) : % -> %', p_test, v_msg;
  END IF;
  RAISE NOTICE 'REFUS   % -> %', p_test, v_msg;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.ok(TEXT, BOOLEAN), pg_temp.refus(TEXT, TEXT, TEXT), pg_temp.id(TEXT) TO gs_application;

-- ============================================================
-- 1. Mise en place (comme le ferait l'administrateur systeme)
-- ============================================================
WITH x AS (INSERT INTO etablissement (code, nom) VALUES ('ECA', 'Ecole A') RETURNING id_etablissement) SELECT pg_temp.garder('etab_a', id_etablissement) FROM x;
WITH x AS (INSERT INTO etablissement (code, nom) VALUES ('ECB', 'Ecole B') RETURNING id_etablissement) SELECT pg_temp.garder('etab_b', id_etablissement) FROM x;

SELECT pg_temp.refus('telephone hors format international',
  $$INSERT INTO utilisateur (nom, prenom, telephone) VALUES ('X', 'Y', '690000000')$$, 'format international');
SELECT pg_temp.refus('compte sans aucun identifiant',
  $$INSERT INTO utilisateur (nom, prenom) VALUES ('X', 'Y')$$);
SELECT pg_temp.refus('compte ACTIF sans mot de passe',
  $$INSERT INTO utilisateur (nom, prenom, telephone, statut_compte) VALUES ('X', 'Y', '+237699999999', 'ACTIF')$$);

INSERT INTO utilisateur (nom, prenom, telephone, mot_de_passe_hash, statut_compte, methode_2fa, reference_secret_2fa)
VALUES ('Direct', 'A', '+237600000001', 'h', 'ACTIF', 'APPLICATION', 'coffre/dir-a'),
       ('Direct', 'B', '+237600000002', 'h', 'ACTIF', 'APPLICATION', 'coffre/dir-b'),
       ('Prof', 'T', '+237600000003', 'h', 'ACTIF', 'AUCUNE', NULL),
       ('Prof', 'T2', '+237600000004', 'h', 'ACTIF', 'AUCUNE', NULL),
       ('Compta', 'C', '+237600000005', 'h', 'ACTIF', 'AUCUNE', NULL),
       ('Parent', 'P', '+237600000010', 'h', 'ACTIF', 'AUCUNE', NULL);
SELECT pg_temp.garder(n, id_utilisateur) FROM (VALUES ('u_dir_a', '+237600000001'), ('u_dir_b', '+237600000002'),
  ('u_prof', '+237600000003'), ('u_prof2', '+237600000004'), ('u_compta', '+237600000005'), ('u_parent', '+237600000010')) v(n, t)
  JOIN utilisateur u ON u.telephone = v.t;

INSERT INTO staff (id_utilisateur, id_etablissement, type_staff, matricule) VALUES
  (pg_temp.id('u_dir_a'), pg_temp.id('etab_a'), 'DIRECTEUR', 'D-A'),
  (pg_temp.id('u_dir_b'), pg_temp.id('etab_b'), 'DIRECTEUR', 'D-B'),
  (pg_temp.id('u_prof'),  pg_temp.id('etab_a'), 'ENSEIGNANT', 'E-1'),
  (pg_temp.id('u_prof2'), pg_temp.id('etab_a'), 'ENSEIGNANT', 'E-2'),
  (pg_temp.id('u_compta'), pg_temp.id('etab_a'), 'ADMINISTRATION', 'A-1');
SELECT pg_temp.garder(n, s.id_staff) FROM (VALUES ('s_dir_a', 'u_dir_a'), ('s_dir_b', 'u_dir_b'), ('s_prof', 'u_prof'),
  ('s_prof2', 'u_prof2'), ('s_compta', 'u_compta')) v(n, u) JOIN staff s ON s.id_utilisateur = pg_temp.id(v.u);

SELECT pg_temp.refus('PIN interdit pour un compte STAFF',
  format($$UPDATE utilisateur SET type_secret = 'PIN' WHERE id_utilisateur = %s$$, pg_temp.id('u_prof')), 'PIN');
SELECT pg_temp.refus('auto-attribution d''un role',
  format($$INSERT INTO attribution_role (id_etablissement, id_staff_beneficiaire, id_role, id_staff_attribuant)
           SELECT %1$s, %2$s, id_role, %2$s FROM role WHERE code = 'ENSEIGNANT'$$, pg_temp.id('etab_a'), pg_temp.id('s_prof')));

INSERT INTO attribution_role (id_etablissement, id_staff_beneficiaire, id_role, id_staff_attribuant)
SELECT pg_temp.id('etab_a'), pg_temp.id(x), id_role, pg_temp.id('s_dir_a') FROM role, (VALUES ('s_prof'), ('s_prof2')) v(x)
 WHERE code = 'ENSEIGNANT';
SELECT pg_temp.ok('role ENSEIGNANT attribue par le directeur', staff_a_permission(pg_temp.id('s_prof'), 'PEDAGOGIE_GERER'));

SELECT pg_temp.refus('role sensible (COMPTABLE) sans double authentification',
  format($$INSERT INTO attribution_role (id_etablissement, id_staff_beneficiaire, id_role, id_staff_attribuant)
           SELECT %s, %s, id_role, %s FROM role WHERE code = 'COMPTABLE'$$,
         pg_temp.id('etab_a'), pg_temp.id('s_compta'), pg_temp.id('s_dir_a')), 'double authentification');
UPDATE utilisateur SET methode_2fa = 'APPLICATION', reference_secret_2fa = 'coffre/compta' WHERE id_utilisateur = pg_temp.id('u_compta');
INSERT INTO attribution_role (id_etablissement, id_staff_beneficiaire, id_role, id_staff_attribuant)
SELECT pg_temp.id('etab_a'), pg_temp.id('s_compta'), id_role, pg_temp.id('s_dir_a') FROM role WHERE code = 'COMPTABLE';
SELECT pg_temp.refus('desactiver la 2FA d''un comptable',
  format($$UPDATE utilisateur SET methode_2fa = 'AUCUNE' WHERE id_utilisateur = %s$$, pg_temp.id('u_compta')), 'Double authentification');

-- Structure academique ------------------------------------------------------
WITH x AS (INSERT INTO annee_scolaire (id_etablissement, libelle, date_debut, date_fin, statut)
  VALUES (pg_temp.id('etab_a'), '2026-2027', '2026-09-01', '2027-06-30', 'EN_COURS') RETURNING id_annee_scolaire) SELECT pg_temp.garder('annee', id_annee_scolaire) FROM x;
SELECT pg_temp.refus('deuxieme annee EN_COURS',
  format($$INSERT INTO annee_scolaire (id_etablissement, libelle, date_debut, date_fin, statut)
           VALUES (%s, '2027-2028', '2027-09-01', '2028-06-30', 'EN_COURS')$$, pg_temp.id('etab_a')));
WITH x AS (INSERT INTO periode (id_etablissement, id_annee_scolaire, libelle, numero, date_debut, date_fin)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('annee'), 'Trimestre 1', 1, '2026-09-01', '2026-12-15') RETURNING id_periode) SELECT pg_temp.garder('t1', id_periode) FROM x;
SELECT pg_temp.refus('periodes qui se chevauchent',
  format($$INSERT INTO periode (id_etablissement, id_annee_scolaire, libelle, numero, date_debut, date_fin)
           VALUES (%s, %s, 'Chevauche', 9, '2026-12-01', '2027-01-15')$$, pg_temp.id('etab_a'), pg_temp.id('annee')));
SELECT pg_temp.refus('periode hors de l''annee',
  format($$INSERT INTO periode (id_etablissement, id_annee_scolaire, libelle, numero, date_debut, date_fin)
           VALUES (%s, %s, 'Hors annee', 8, '2027-06-01', '2027-08-30')$$, pg_temp.id('etab_a'), pg_temp.id('annee')), 'incluse');
INSERT INTO periode (id_etablissement, id_annee_scolaire, libelle, numero, date_debut, date_fin)
VALUES (pg_temp.id('etab_a'), pg_temp.id('annee'), 'Trimestre 2', 2, '2027-01-04', '2027-03-31');

WITH x AS (INSERT INTO niveau (id_etablissement, code, libelle, ordre)
  VALUES (pg_temp.id('etab_a'), '6E', 'Sixieme', 1) RETURNING id_niveau) SELECT pg_temp.garder('niveau', id_niveau) FROM x;
WITH x AS (INSERT INTO salle (id_etablissement, code) VALUES (pg_temp.id('etab_a'), 'S1') RETURNING id_salle) SELECT pg_temp.garder('salle', id_salle) FROM x;
SELECT pg_temp.refus('titulaire non enseignant',
  format($$INSERT INTO classe (id_etablissement, id_annee_scolaire, id_niveau, id_staff_titulaire, nom)
           VALUES (%s, %s, %s, %s, 'X')$$, pg_temp.id('etab_a'), pg_temp.id('annee'), pg_temp.id('niveau'), pg_temp.id('s_compta')), 'ENSEIGNANT');
WITH x AS (INSERT INTO classe (id_etablissement, id_annee_scolaire, id_niveau, id_staff_titulaire, id_salle, nom, effectif_max)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('annee'), pg_temp.id('niveau'), pg_temp.id('s_prof'), pg_temp.id('salle'), '6e A', 2) RETURNING id_classe) SELECT pg_temp.garder('classe', id_classe) FROM x;
WITH x AS (INSERT INTO classe (id_etablissement, id_annee_scolaire, id_niveau, nom)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('annee'), pg_temp.id('niveau'), '6e B') RETURNING id_classe) SELECT pg_temp.garder('classe_b', id_classe) FROM x;
WITH x AS (INSERT INTO matiere (id_etablissement, code, libelle)
  VALUES (pg_temp.id('etab_a'), 'MATH', 'Mathematiques') RETURNING id_matiere) SELECT pg_temp.garder('matiere', id_matiere) FROM x;
WITH x AS (INSERT INTO enseignement (id_etablissement, id_classe, id_matiere)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('classe'), pg_temp.id('matiere')) RETURNING id_enseignement) SELECT pg_temp.garder('ens', id_enseignement) FROM x;
WITH x AS (INSERT INTO enseignement (id_etablissement, id_classe, id_matiere)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('classe_b'), pg_temp.id('matiere')) RETURNING id_enseignement) SELECT pg_temp.garder('ens_b', id_enseignement) FROM x;
SELECT pg_temp.refus('affecter un non-enseignant',
  format($$INSERT INTO affectation_enseignant (id_etablissement, id_enseignement, id_staff_enseignant, date_debut)
           VALUES (%s, %s, %s, '2026-09-01')$$, pg_temp.id('etab_a'), pg_temp.id('ens'), pg_temp.id('s_compta')), 'ENSEIGNANT');
INSERT INTO affectation_enseignant (id_etablissement, id_enseignement, id_staff_enseignant, date_debut)
VALUES (pg_temp.id('etab_a'), pg_temp.id('ens'), pg_temp.id('s_prof'), '2026-09-01'),
       (pg_temp.id('etab_a'), pg_temp.id('ens_b'), pg_temp.id('s_prof'), '2026-09-01');
SELECT pg_temp.refus('deux titulaires en meme temps sur un enseignement',
  format($$INSERT INTO affectation_enseignant (id_etablissement, id_enseignement, id_staff_enseignant, date_debut)
           VALUES (%s, %s, %s, '2026-10-01')$$, pg_temp.id('etab_a'), pg_temp.id('ens'), pg_temp.id('s_prof2')));

WITH x AS (INSERT INTO creneau (id_etablissement, id_enseignement, id_salle, jour_semaine, heure_debut, heure_fin, date_debut)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('ens'), pg_temp.id('salle'), 1, '08:00', '10:00', '2026-09-01') RETURNING id_creneau) SELECT pg_temp.garder('creneau', id_creneau) FROM x;
SELECT pg_temp.refus('meme enseignant sur deux classes a la meme heure',
  format($$INSERT INTO creneau (id_etablissement, id_enseignement, jour_semaine, heure_debut, heure_fin, date_debut)
           VALUES (%s, %s, 1, '09:00', '11:00', '2026-09-01')$$, pg_temp.id('etab_a'), pg_temp.id('ens_b')), 'Chevauchement');

-- Eleves, parents, familles, inscriptions -----------------------------------
WITH x AS (INSERT INTO parent (id_utilisateur) VALUES (pg_temp.id('u_parent')) RETURNING id_parent) SELECT pg_temp.garder('parent', id_parent) FROM x;
WITH x AS (INSERT INTO famille (id_etablissement, id_parent_referent, nom)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('parent'), 'Famille P') RETURNING id_famille) SELECT pg_temp.garder('famille', id_famille) FROM x;
INSERT INTO eleve (id_etablissement, id_famille, matricule, nom, prenom, sexe, date_naissance) VALUES
  (pg_temp.id('etab_a'), pg_temp.id('famille'), 'M001', 'P', 'Aine', 'M', '2014-03-01'),
  (pg_temp.id('etab_a'), pg_temp.id('famille'), 'M002', 'P', 'Cadet', 'F', '2015-05-01'),
  (pg_temp.id('etab_a'), NULL, 'M003', 'Q', 'Autre', 'M', '2014-07-01');
SELECT pg_temp.garder(n, id_eleve) FROM (VALUES ('e1', 'M001'), ('e2', 'M002'), ('e3', 'M003')) v(n, m) JOIN eleve ON matricule = v.m;
SELECT pg_temp.refus('photo sans consentement',
  format($$UPDATE eleve SET photo = 'p.jpg' WHERE id_eleve = %s$$, pg_temp.id('e1')));

WITH x AS (INSERT INTO inscription (id_etablissement, id_eleve, id_classe, id_annee_scolaire, id_staff_createur, date_inscription, type_inscription)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('e3'), pg_temp.id('classe'), pg_temp.id('annee'), pg_temp.id('s_dir_a'), '2026-09-01', 'NOUVELLE') RETURNING id_inscription) SELECT pg_temp.garder('ins_e3', id_inscription) FROM x;
SELECT pg_temp.refus('validation sans responsable legal',
  format($$UPDATE inscription SET statut = 'VALIDEE' WHERE id_inscription = %s$$, pg_temp.id('ins_e3')), 'responsable legal');

INSERT INTO eleve_parent (id_etablissement, id_eleve, id_parent, type_lien, est_responsable_legal, est_responsable_financier)
SELECT pg_temp.id('etab_a'), pg_temp.id(e), pg_temp.id('parent'), 'PERE', TRUE, TRUE FROM (VALUES ('e1'), ('e2'), ('e3')) v(e);

INSERT INTO inscription (id_etablissement, id_eleve, id_classe, id_annee_scolaire, id_staff_createur, date_inscription, type_inscription, statut)
SELECT pg_temp.id('etab_a'), pg_temp.id(e), pg_temp.id('classe'), pg_temp.id('annee'), pg_temp.id('s_dir_a'), '2026-09-01', 'NOUVELLE', 'VALIDEE'
  FROM (VALUES ('e1'), ('e2')) v(e);
SELECT pg_temp.garder(n, i.id_inscription) FROM (VALUES ('ins_e1', 'e1'), ('ins_e2', 'e2')) v(n, e)
  JOIN inscription i ON i.id_eleve = pg_temp.id(v.e);
SELECT pg_temp.refus('classe complete (effectif_max = 2)',
  format($$UPDATE inscription SET statut = 'VALIDEE' WHERE id_inscription = %s$$, pg_temp.id('ins_e3')), 'complete');
SELECT pg_temp.refus('deux inscriptions actives la meme annee',
  format($$INSERT INTO inscription (id_etablissement, id_eleve, id_classe, id_annee_scolaire, id_staff_createur, date_inscription, type_inscription)
           VALUES (%s, %s, %s, %s, %s, '2026-09-02', 'NOUVELLE')$$,
         pg_temp.id('etab_a'), pg_temp.id('e1'), pg_temp.id('classe_b'), pg_temp.id('annee'), pg_temp.id('s_dir_a')));
WITH x AS (INSERT INTO annee_scolaire (id_etablissement, libelle, date_debut, date_fin)
  VALUES (pg_temp.id('etab_a'), '2027-2028', '2027-09-01', '2028-06-30') RETURNING id_annee_scolaire)
SELECT pg_temp.garder('annee2', id_annee_scolaire) FROM x;
SELECT pg_temp.refus('inscription dans une classe d''une autre annee (FK composite)',
  format($$INSERT INTO inscription (id_etablissement, id_eleve, id_classe, id_annee_scolaire, id_staff_createur, date_inscription, type_inscription)
           VALUES (%s, %s, %s, %s, %s, '2026-09-02', 'NOUVELLE')$$,
         pg_temp.id('etab_a'), pg_temp.id('e3'), pg_temp.id('classe'), pg_temp.id('annee2'), pg_temp.id('s_dir_a')), 'foreign key');

SELECT pg_temp.ok('compte eleve cree a la validation (identifiant ECA-M001)',
  EXISTS (SELECT 1 FROM eleve e JOIN utilisateur u ON u.id_utilisateur = e.id_utilisateur
           WHERE e.id_eleve = pg_temp.id('e1') AND u.identifiant = 'ECA-M001' AND u.statut_compte = 'EN_ATTENTE_ACTIVATION'));
SELECT pg_temp.ok('carte eleve ACTIVE creee, expire en fin d''annee',
  EXISTS (SELECT 1 FROM carte_eleve WHERE id_eleve = pg_temp.id('e1') AND statut = 'ACTIVE' AND date_expiration = '2027-06-30'));
SELECT pg_temp.garder('carte_e1', id_carte_eleve) FROM carte_eleve WHERE id_eleve = pg_temp.id('e1');
SELECT pg_temp.garder('u_e1', id_utilisateur) FROM eleve WHERE id_eleve = pg_temp.id('e1');
SELECT pg_temp.refus('retirer le dernier responsable legal',
  format($$UPDATE eleve_parent SET est_responsable_legal = FALSE WHERE id_eleve = %s$$, pg_temp.id('e1')), 'responsable legal');

-- ============================================================
-- 2. Finance : echeancier, reductions famille, paiement au guichet, recu
-- ============================================================
WITH x AS (INSERT INTO frais_scolaire (id_etablissement, id_annee_scolaire, code, libelle, montant, periodicite)
  VALUES (pg_temp.id('etab_a'), pg_temp.id('annee'), 'SCOL', 'Scolarite', 60000, 'TRIMESTRIEL') RETURNING id_frais_scolaire) SELECT pg_temp.garder('frais', id_frais_scolaire) FROM x;
SELECT pg_temp.refus('echeancier dont la somme ne fait pas le montant du frais',
  format($$INSERT INTO echeance (id_etablissement, id_frais_scolaire, libelle, date_limite, montant)
           VALUES (%s, %s, 'Incomplet', '2026-10-01', 10000)$$, pg_temp.id('etab_a'), pg_temp.id('frais')), 'Echeancier');
INSERT INTO echeance (id_etablissement, id_frais_scolaire, libelle, date_limite, montant, mois_concerne) VALUES
  (pg_temp.id('etab_a'), pg_temp.id('frais'), 'Tranche 1', '2026-10-01', 20000, '2026-10-01'),
  (pg_temp.id('etab_a'), pg_temp.id('frais'), 'Tranche 2', '2026-11-01', 20000, '2026-11-01'),
  (pg_temp.id('etab_a'), pg_temp.id('frais'), 'Tranche 3', '2027-04-01', 20000, '2027-04-01');
SELECT pg_temp.garder(lower(replace(libelle, ' ', '')), id_echeance) FROM echeance;   -- tranche1, tranche2, tranche3
INSERT INTO regle_reduction (id_etablissement, id_annee_scolaire, libelle, rang_enfant_min, mode_calcul, valeur)
VALUES (pg_temp.id('etab_a'), pg_temp.id('annee'), 'Fratrie : -50 % des le 2e enfant', 2, 'POURCENTAGE', 50);

INSERT INTO creance (id_etablissement, id_inscription, id_echeance, montant_du)
SELECT pg_temp.id('etab_a'), pg_temp.id(i), pg_temp.id(t), 20000
  FROM (VALUES ('ins_e1'), ('ins_e2')) a(i), (VALUES ('tranche1'), ('tranche2'), ('tranche3')) b(t);
SELECT pg_temp.garder(i || '_' || t, c.id_creance)
  FROM (VALUES ('ins_e1'), ('ins_e2')) a(i) CROSS JOIN (VALUES ('tranche1'), ('tranche2'), ('tranche3')) b(t)
  JOIN creance c ON c.id_inscription = pg_temp.id(a.i) AND c.id_echeance = pg_temp.id(b.t);
SELECT pg_temp.ok('aine : aucune reduction', (SELECT remise_reduction FROM creance WHERE id_creance = pg_temp.id('ins_e1_tranche1')) = 0);
SELECT pg_temp.ok('cadet : reduction fratrie automatique de 50 %', (SELECT remise_reduction FROM creance WHERE id_creance = pg_temp.id('ins_e2_tranche1')) = 10000);
SELECT pg_temp.refus('remise manuelle sans motif',
  format($$UPDATE creance SET remise = 1000 WHERE id_creance = %s$$, pg_temp.id('ins_e1_tranche3')));

WITH x AS (INSERT INTO paiement (id_etablissement, id_mode_paiement, id_parent_payeur, id_staff_enregistreur, numero, montant, date_paiement, statut)
  SELECT pg_temp.id('etab_a'), id_mode_paiement, pg_temp.id('parent'), pg_temp.id('s_compta'), 'P-0001', 30000, now(), 'VALIDE'
    FROM mode_paiement WHERE code = 'ESPECES' RETURNING id_paiement) SELECT pg_temp.garder('paiement', id_paiement) FROM x;
SELECT pg_temp.refus('paiement sans nom de payeur ni parent',
  format($$INSERT INTO paiement (id_etablissement, id_mode_paiement, id_staff_enregistreur, numero, montant, date_paiement)
           SELECT %s, id_mode_paiement, %s, 'P-X', 100, now() FROM mode_paiement WHERE code = 'ESPECES'$$,
         pg_temp.id('etab_a'), pg_temp.id('s_compta')));
INSERT INTO allocation_paiement (id_etablissement, id_paiement, id_creance, montant_alloue) VALUES
  (pg_temp.id('etab_a'), pg_temp.id('paiement'), pg_temp.id('ins_e1_tranche1'), 20000),
  (pg_temp.id('etab_a'), pg_temp.id('paiement'), pg_temp.id('ins_e2_tranche1'), 10000);
SELECT pg_temp.ok('paiement famille : les deux tranches 1 sont SOLDEE',
  (SELECT count(*) FROM creance WHERE id_creance IN (pg_temp.id('ins_e1_tranche1'), pg_temp.id('ins_e2_tranche1')) AND statut = 'SOLDEE') = 2);
SELECT pg_temp.refus('allocation au-dela du montant du paiement',
  format($$INSERT INTO allocation_paiement (id_etablissement, id_paiement, id_creance, montant_alloue) VALUES (%s, %s, %s, 5000)$$,
         pg_temp.id('etab_a'), pg_temp.id('paiement'), pg_temp.id('ins_e1_tranche3')), 'depasse');
WITH x AS (INSERT INTO recu (id_paiement, id_etablissement, id_staff_emetteur, numero)
  VALUES (pg_temp.id('paiement'), pg_temp.id('etab_a'), pg_temp.id('s_compta'), 'R-0001') RETURNING id_recu) SELECT pg_temp.garder('recu', id_recu) FROM x;
SELECT pg_temp.ok('recu fige : payeur, montant, detail des 2 eleves et code de verification',
  (SELECT nom_payeur = 'Parent P' AND montant = 30000 AND jsonb_array_length(detail -> 'lignes') = 2
          AND length(code_verification) = 32 FROM recu WHERE id_recu = pg_temp.id('recu')));
SELECT pg_temp.refus('modifier un recu emis',
  format($$UPDATE recu SET nom_payeur = 'Autre' WHERE id_recu = %s$$, pg_temp.id('recu')), 'fige');
SELECT pg_temp.refus('recu de guichet sans emetteur',
  format($$INSERT INTO recu (id_paiement, id_etablissement, numero) VALUES (%s, %s, 'R-0002')$$, pg_temp.id('paiement'), pg_temp.id('etab_a')));

-- ============================================================
-- 3. Pedagogie : evaluations, notes, historique, verrouillage
-- ============================================================
SELECT pg_temp.refus('evaluation hors de sa periode',
  format($$INSERT INTO evaluation (id_etablissement, id_enseignement, id_periode, id_type_evaluation, id_staff_createur, titre, date_evaluation)
           SELECT %s, %s, %s, id_type_evaluation, %s, 'Hors periode', '2027-02-01' FROM type_evaluation WHERE code = 'DEVOIR'$$,
         pg_temp.id('etab_a'), pg_temp.id('ens'), pg_temp.id('t1'), pg_temp.id('s_prof')), 'comprise');
WITH x AS (INSERT INTO evaluation (id_etablissement, id_enseignement, id_periode, id_type_evaluation, id_staff_createur, titre, date_evaluation)
  SELECT pg_temp.id('etab_a'), pg_temp.id('ens'), pg_temp.id('t1'), id_type_evaluation, pg_temp.id('s_prof'), 'Devoir 1', '2026-10-05'
    FROM type_evaluation WHERE code = 'DEVOIR' RETURNING id_evaluation) SELECT pg_temp.garder('eval', id_evaluation) FROM x;
SELECT pg_temp.refus('note superieure a la note maximale',
  format($$INSERT INTO note (id_etablissement, id_evaluation, id_inscription, id_staff_saisie, valeur) VALUES (%s, %s, %s, %s, 25)$$,
         pg_temp.id('etab_a'), pg_temp.id('eval'), pg_temp.id('ins_e1'), pg_temp.id('s_prof')), 'comprise entre');
SELECT pg_temp.refus('statut NOTEE sans valeur',
  format($$INSERT INTO note (id_etablissement, id_evaluation, id_inscription, id_staff_saisie) VALUES (%s, %s, %s, %s)$$,
         pg_temp.id('etab_a'), pg_temp.id('eval'), pg_temp.id('ins_e1'), pg_temp.id('s_prof')));
SELECT pg_temp.refus('note d''un eleve d''une autre classe',
  format($$INSERT INTO note (id_etablissement, id_evaluation, id_inscription, id_staff_saisie, valeur) VALUES (%s, %s, %s, %s, 10)$$,
         pg_temp.id('etab_a'), pg_temp.id('eval'), pg_temp.id('ins_e3'), pg_temp.id('s_prof')), 'pas inscrit');
INSERT INTO note (id_etablissement, id_evaluation, id_inscription, id_staff_saisie, valeur, statut_note) VALUES
  (pg_temp.id('etab_a'), pg_temp.id('eval'), pg_temp.id('ins_e1'), pg_temp.id('s_prof'), 14, 'NOTEE'),
  (pg_temp.id('etab_a'), pg_temp.id('eval'), pg_temp.id('ins_e2'), pg_temp.id('s_prof'), NULL, 'ABSENT_JUSTIFIE');
UPDATE note SET valeur = 15 WHERE id_inscription = pg_temp.id('ins_e1');
SELECT pg_temp.ok('historique des notes : creation + modification 14 -> 15',
  (SELECT count(*) FROM historique_note h JOIN note n ON n.id_note = h.id_note WHERE n.id_inscription = pg_temp.id('ins_e1')) = 2
  AND EXISTS (SELECT 1 FROM historique_note WHERE ancienne_valeur = 14 AND nouvelle_valeur = 15));
SELECT pg_temp.refus('modifier l''historique des notes', 'UPDATE historique_note SET motif = $x$triche$x$', 'ajout seul');
UPDATE evaluation SET statut = 'VALIDEE' WHERE id_evaluation = pg_temp.id('eval');
INSERT INTO resultat_periode (id_etablissement, id_inscription, id_periode, moyenne_generale, statut)
VALUES (pg_temp.id('etab_a'), pg_temp.id('ins_e1'), pg_temp.id('t1'), 15, 'PUBLIE');

-- ============================================================
-- 4. Securite : RLS, isolation entre etablissements, profils (compte applicatif gs_application)
-- ============================================================
UPDATE utilisateur SET mot_de_passe_hash = 'h', statut_compte = 'ACTIF' WHERE id_utilisateur = pg_temp.id('u_e1');
INSERT INTO parametre_systeme (id_etablissement, cle, valeur) VALUES (pg_temp.id('etab_a'), 'BLOCAGE_RESULTATS_IMPAYES', 'TRUE');

SET ROLE gs_application;
SELECT pg_temp.ok('sans contexte : aucun eleve visible', (SELECT count(*) FROM eleve) = 0);
SELECT pg_temp.refus('suppression interdite (pas de DELETE)', 'DELETE FROM note', 'permission');

BEGIN;
SELECT definir_contexte(pg_temp.id('u_parent'), pg_temp.id('etab_a'), 'PARENT');
SELECT pg_temp.ok('parent : voit ses 3 enfants', (SELECT count(*) FROM eleve) = 3);
SELECT pg_temp.ok('parent : ne voit aucun dossier du personnel', (SELECT count(*) FROM staff) = 0);
SELECT pg_temp.ok('parent : voit les notes (jamais bloquees)', (SELECT count(*) FROM note) = 2);
SELECT pg_temp.ok('parent : voit ses creances (mois payes / impayes)', (SELECT count(*) FROM creance) = 6);
SELECT pg_temp.ok('parent : voit le recu du paiement au guichet', (SELECT count(*) FROM recu) = 1);
SELECT pg_temp.ok('parent : bulletin BLOQUE (tranche 2 echue impayee)', (SELECT count(*) FROM resultat_periode) = 0);
SELECT pg_temp.refus('parent : s''attribuer le statut d''administrateur systeme',
  format($$UPDATE utilisateur SET est_admin_systeme = TRUE WHERE id_utilisateur = %s$$, pg_temp.id('u_parent')), 'administrateur');
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_dir_a'), pg_temp.id('etab_a'), 'STAFF');
INSERT INTO derogation_acces_resultat (id_etablissement, id_inscription, id_periode, id_staff_accordant, motif)
VALUES (pg_temp.id('etab_a'), pg_temp.id('ins_e1'), pg_temp.id('t1'), pg_temp.id('s_dir_a'), 'Echeancier negocie');
SELECT pg_temp.ok('directeur A : voit tous les eleves de son ecole', (SELECT count(*) FROM eleve) = 3);
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_parent'), pg_temp.id('etab_a'), 'PARENT');
SELECT pg_temp.ok('parent : bulletin visible grace a la derogation', (SELECT count(*) FROM resultat_periode) = 1);
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_dir_b'), pg_temp.id('etab_b'), 'STAFF');
SELECT pg_temp.ok('ISOLATION : le directeur B ne voit aucun eleve de l''ecole A', (SELECT count(*) FROM eleve) = 0);
SELECT pg_temp.ok('ISOLATION : le directeur B ne voit aucune note de l''ecole A', (SELECT count(*) FROM note) = 0);
SELECT pg_temp.ok('ISOLATION : le directeur B ne voit aucun paiement de l''ecole A', (SELECT count(*) FROM paiement) = 0);
SELECT pg_temp.refus('ISOLATION : le directeur B ecrit dans l''ecole A',
  format($$INSERT INTO salle (id_etablissement, code) VALUES (%s, 'PIRATE')$$, pg_temp.id('etab_a')), 'row-level security');
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_dir_b'), pg_temp.id('etab_a'), 'STAFF');
SELECT pg_temp.ok('ISOLATION : un faux contexte (directeur B sur l''ecole A) ne donne rien', (SELECT count(*) FROM eleve) = 0);
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_prof2'), pg_temp.id('etab_a'), 'STAFF');
WITH u AS (UPDATE note SET valeur = 2 WHERE id_inscription = pg_temp.id('ins_e1') RETURNING 1)
SELECT pg_temp.ok('enseignant non affecte : modifier une note d''une autre classe -> 0 ligne modifiee', (SELECT count(*) FROM u) = 0);
SELECT pg_temp.refus('enseignant non affecte : creer une evaluation dans une classe qui n''est pas la sienne',
  format($$INSERT INTO evaluation (id_etablissement, id_enseignement, id_periode, id_type_evaluation, id_staff_createur, titre, date_evaluation)
           SELECT %s, %s, %s, id_type_evaluation, %s, 'Intrus', '2026-10-06' FROM type_evaluation WHERE code = 'DEVOIR'$$,
         pg_temp.id('etab_a'), pg_temp.id('ens'), pg_temp.id('t1'), pg_temp.id('s_prof2')), 'row-level security');
SELECT pg_temp.ok('enseignant non affecte : la note est inchangee',
  (SELECT valeur FROM note WHERE id_inscription = pg_temp.id('ins_e1')) = 15);
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_dir_a'), pg_temp.id('etab_a'), 'STAFF');
SELECT nouveau_jeton_carte(pg_temp.id('carte_e1')) AS jeton \gset
COMMIT;
SELECT pg_temp.ok('carte : le jeton QR genere ouvre bien le compte de l''eleve',
  compte_par_jeton_carte(:'jeton') = pg_temp.id('u_e1'));
SELECT pg_temp.ok('carte : un faux jeton QR n''ouvre rien', compte_par_jeton_carte('faux-jeton') IS NULL);
BEGIN;
SELECT definir_contexte(pg_temp.id('u_parent'), NULL, NULL);
SELECT pg_temp.ok('connexion : contextes proposes au parent (ecole A, role PARENT)',
  (SELECT count(*) FROM contextes_disponibles() c WHERE c.role_actif = 'PARENT') = 1);
SELECT pg_temp.ok('connexion : compte retrouve par son numero de telephone',
  (SELECT id_utilisateur FROM infos_connexion('+237600000010')) = pg_temp.id('u_parent'));
COMMIT;
RESET ROLE;
SELECT pg_temp.refus('session avec un role non detenu (parent en STAFF)',
  format($$INSERT INTO session_utilisateur (id_utilisateur, id_etablissement_actif, role_actif, empreinte_jeton, date_expiration)
           VALUES (%s, %s, 'STAFF', 'x1', now() + interval '1 day')$$, pg_temp.id('u_parent'), pg_temp.id('etab_a')), 'Role actif');
INSERT INTO session_utilisateur (id_utilisateur, id_etablissement_actif, role_actif, empreinte_jeton, date_expiration)
VALUES (pg_temp.id('u_parent'), pg_temp.id('etab_a'), 'PARENT', 'x2', now() + interval '90 days');
UPDATE utilisateur SET mot_de_passe_hash = 'nouveau' WHERE id_utilisateur = pg_temp.id('u_parent');
SELECT pg_temp.ok('changement de mot de passe : sessions revoquees',
  NOT EXISTS (SELECT 1 FROM session_utilisateur WHERE id_utilisateur = pg_temp.id('u_parent') AND date_revocation IS NULL));
SELECT pg_temp.refus('isolation par FK composite : l''ecole B rattache un incident a un eleve de l''ecole A',
  format($$INSERT INTO incident (id_etablissement, id_inscription, id_type_incident, id_staff_signalant, date_incident, description, gravite)
           SELECT %s, %s, id_type_incident, %s, now(), 'Intrusion', 'MINEURE' FROM type_incident WHERE code = 'INDISCIPLINE'$$,
         pg_temp.id('etab_b'), pg_temp.id('ins_e1'), pg_temp.id('s_dir_b')), 'foreign key');

-- ============================================================
-- 5. Paiement en ligne (Mobile Money) et commission
-- ============================================================
UPDATE fournisseur_pays SET est_actif = TRUE
 WHERE id_pays = (SELECT id_pays FROM pays WHERE code_iso = 'CM')
   AND id_fournisseur_paiement = (SELECT id_fournisseur_paiement FROM fournisseur_paiement WHERE code = 'MTN_MOMO');
WITH x AS (INSERT INTO config_paiement_etablissement (id_etablissement, id_fournisseur_paiement, identifiant_marchand, reference_secret)
  SELECT pg_temp.id('etab_a'), id_fournisseur_paiement, 'MARCHAND-A', 'coffre/mtn-a' FROM fournisseur_paiement WHERE code = 'MTN_MOMO'
  RETURNING id_config_paiement_etablissement) SELECT pg_temp.garder('config', id_config_paiement_etablissement) FROM x;
WITH x AS (INSERT INTO contrat_plateforme (id_etablissement, date_debut)
  VALUES (pg_temp.id('etab_a'), '2026-01-01') RETURNING id_contrat_plateforme) SELECT pg_temp.garder('contrat', id_contrat_plateforme) FROM x;

SET ROLE gs_application;
BEGIN;
SELECT definir_contexte(pg_temp.id('u_parent'), pg_temp.id('etab_a'), 'PARENT');
SELECT pg_temp.refus('numero d''un pays non desservi par le fournisseur',
  format($$INSERT INTO transaction_en_ligne (id_etablissement, id_config_paiement_etablissement, id_utilisateur_initiateur, id_pays,
             id_contrat_plateforme, numero_telephone, reference_interne, montant, date_expiration)
           SELECT %s, %s, %s, id_pays, %s, '+22170000000', 'TX-SN', 20000, now() + interval '15 minutes' FROM pays WHERE code_iso = 'SN'$$,
         pg_temp.id('etab_a'), pg_temp.id('config'), pg_temp.id('u_parent'), pg_temp.id('contrat')), 'dessert pas');
INSERT INTO transaction_en_ligne (id_etablissement, id_config_paiement_etablissement, id_utilisateur_initiateur, id_pays,
       id_contrat_plateforme, numero_telephone, reference_interne, montant, frais_operateur, date_expiration)
SELECT pg_temp.id('etab_a'), pg_temp.id('config'), pg_temp.id('u_parent'), id_pays, pg_temp.id('contrat'),
       '+237600000010', 'TX-0001', 20000, 200, now() + interval '15 minutes' FROM pays WHERE code_iso = 'CM';
INSERT INTO transaction_creance (id_etablissement, id_transaction_en_ligne, id_creance, montant)
SELECT pg_temp.id('etab_a'), id_transaction_en_ligne, pg_temp.id('ins_e1_tranche2'), 20000
  FROM transaction_en_ligne WHERE reference_interne = 'TX-0001';
COMMIT;
RESET ROLE;
SELECT pg_temp.garder('tx', id_transaction_en_ligne) FROM transaction_en_ligne WHERE reference_interne = 'TX-0001';
SELECT pg_temp.ok('commission figee : 1 % = 200, a la charge de l''ecole ; parent debite de 20 200 (frais operateur inclus)',
  (SELECT taux_commission = 1 AND montant_commission = 200 AND montant_total = 20200 AND devise = 'XAF'
          AND mode_perception_commission = 'FACTURATION' FROM transaction_en_ligne WHERE id_transaction_en_ligne = pg_temp.id('tx')));
SELECT pg_temp.garder('paiement_en_ligne', finaliser_transaction(pg_temp.id('tx'), 'MTN-REF-1'));
SELECT pg_temp.ok('notification en double : aucun double credit',
  finaliser_transaction(pg_temp.id('tx'), 'MTN-REF-1') = pg_temp.id('paiement_en_ligne')
  AND (SELECT count(*) FROM paiement WHERE id_transaction_en_ligne = pg_temp.id('tx')) = 1);
SELECT pg_temp.ok('paiement en ligne : tranche 2 SOLDEE et recu automatique sans emetteur',
  (SELECT statut FROM creance WHERE id_creance = pg_temp.id('ins_e1_tranche2')) = 'SOLDEE'
  AND EXISTS (SELECT 1 FROM recu WHERE id_paiement = pg_temp.id('paiement_en_ligne') AND id_staff_emetteur IS NULL));
UPDATE derogation_acces_resultat SET est_active = FALSE;
SET ROLE gs_application;
BEGIN;
SELECT definir_contexte(pg_temp.id('u_parent'), pg_temp.id('etab_a'), 'PARENT');
SELECT pg_temp.ok('parent : bulletin visible apres paiement en ligne (sans derogation)', (SELECT count(*) FROM resultat_periode) = 1);
SELECT pg_temp.ok('parent : voit sa transaction et les deux recus', (SELECT count(*) FROM transaction_en_ligne) = 1 AND (SELECT count(*) FROM recu) = 2);
COMMIT;

-- ============================================================
-- 6. Bibliotheque numerique
-- ============================================================
BEGIN;
SELECT definir_contexte(pg_temp.id('u_prof'), pg_temp.id('etab_a'), 'STAFF');
INSERT INTO ressource_numerique (id_etablissement, id_staff_auteur, titre, type_ressource, fichier, format)
VALUES (pg_temp.id('etab_a'), pg_temp.id('s_prof'), 'Exercices fractions', 'EXERCICE', 'fractions.pdf', 'PDF');
INSERT INTO ressource_diffusion (id_etablissement, id_ressource_numerique, id_classe, id_staff_diffuseur, date_debut, date_fin, rendu_attendu)
SELECT pg_temp.id('etab_a'), id_ressource_numerique, pg_temp.id('classe'), pg_temp.id('s_prof'), current_date, current_date + 14, TRUE
  FROM ressource_numerique WHERE titre = 'Exercices fractions';
UPDATE ressource_numerique SET statut = 'PUBLIEE' WHERE titre = 'Exercices fractions';
SELECT pg_temp.refus('diffuser a toute l''ecole sans validation',
  format($$INSERT INTO ressource_diffusion (id_etablissement, id_ressource_numerique, id_staff_diffuseur, date_debut)
           SELECT %s, id_ressource_numerique, %s, current_date FROM ressource_numerique WHERE titre = 'Exercices fractions'$$,
         pg_temp.id('etab_a'), pg_temp.id('s_prof')), 'validee');
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_parent'), pg_temp.id('etab_a'), 'PARENT');
SELECT pg_temp.ok('parent : voit l''exercice diffuse a la classe de son enfant', (SELECT count(*) FROM ressource_numerique) = 1);
SELECT pg_temp.refus('telecharger une ressource en lecture seule',
  format($$INSERT INTO consultation_ressource (id_etablissement, id_ressource_numerique, id_utilisateur, type_consultation)
           SELECT %s, id_ressource_numerique, %s, 'TELECHARGEMENT' FROM ressource_numerique$$,
         pg_temp.id('etab_a'), pg_temp.id('u_parent')), 'lecture seule');
INSERT INTO consultation_ressource (id_etablissement, id_ressource_numerique, id_utilisateur, type_consultation)
SELECT pg_temp.id('etab_a'), id_ressource_numerique, pg_temp.id('u_parent'), 'LECTURE' FROM ressource_numerique;
COMMIT;

BEGIN;
SELECT definir_contexte(pg_temp.id('u_e1'), pg_temp.id('etab_a'), 'ELEVE');
SELECT pg_temp.ok('eleve : voit ses propres notes uniquement', (SELECT count(*) FROM note) = 1);
INSERT INTO rendu_travail (id_etablissement, id_ressource_diffusion, id_inscription, fichier)
SELECT pg_temp.id('etab_a'), id_ressource_diffusion, pg_temp.id('ins_e1'), 'copie.pdf' FROM ressource_diffusion;
SELECT pg_temp.ok('eleve : devoir rendu', (SELECT count(*) FROM rendu_travail) = 1);
COMMIT;
RESET ROLE;

-- ============================================================
-- 7. Cloture : donnees gelees, sanctions, journal d'audit
-- ============================================================
UPDATE periode SET statut = 'CLOTUREE' WHERE id_periode = pg_temp.id('t1');
SELECT pg_temp.refus('modifier une note d''une periode cloturee',
  format($$UPDATE note SET valeur = 20 WHERE id_inscription = %s$$, pg_temp.id('ins_e1')), 'cloturee');
WITH x AS (INSERT INTO incident (id_etablissement, id_inscription, id_type_incident, id_staff_signalant, date_incident, description, gravite)
  SELECT pg_temp.id('etab_a'), pg_temp.id('ins_e3'), id_type_incident, pg_temp.id('s_dir_a'), now(), 'Bagarre', 'GRAVE'
    FROM type_incident WHERE code = 'VIOLENCE' RETURNING id_incident) SELECT pg_temp.garder('incident', id_incident) FROM x;
SELECT pg_temp.refus('exclusion temporaire sans dates',
  format($$INSERT INTO decision_disciplinaire (id_etablissement, id_incident, id_staff_decideur, type_sanction, date_decision)
           VALUES (%s, %s, %s, 'EXCLUSION_TEMPORAIRE', current_date)$$, pg_temp.id('etab_a'), pg_temp.id('incident'), pg_temp.id('s_dir_a')));
INSERT INTO decision_disciplinaire (id_etablissement, id_incident, id_staff_decideur, type_sanction, date_decision, statut)
VALUES (pg_temp.id('etab_a'), pg_temp.id('incident'), pg_temp.id('s_dir_a'), 'EXCLUSION_DEFINITIVE', current_date, 'APPLIQUEE');
SELECT pg_temp.ok('exclusion definitive appliquee : eleve au statut EXCLU', (SELECT statut FROM eleve WHERE id_eleve = pg_temp.id('e3')) = 'EXCLU');
SELECT pg_temp.ok('journal d''audit alimente automatiquement (paiements, notes, droits...)', (SELECT count(*) FROM journal_audit) > 20);
SELECT pg_temp.ok('journal d''audit : aucun secret enregistre',
  NOT EXISTS (SELECT 1 FROM journal_audit WHERE nouvelles_valeurs LIKE '%mot_de_passe_hash%' OR nouvelles_valeurs LIKE '%reference_secret%'));
SELECT pg_temp.refus('modifier le journal d''audit', 'UPDATE journal_audit SET type_operation = $x$X$x$', 'ajout seul');

\echo '==================== RECETTE TERMINEE : TOUS LES TESTS SONT PASSES ===================='
