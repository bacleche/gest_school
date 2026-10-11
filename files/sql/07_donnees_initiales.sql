-- ============================================================
-- 07 - Donnees initiales communes a tous les etablissements
-- Domaines, actions, permissions, roles types, referentiels, pays, fournisseurs, parametres.
-- A executer en superutilisateur (avant la mise en service). Idempotent : peut etre rejoue.
-- ============================================================
SET search_path TO gestion_scolaire, public;

-- ------------------------------------------------------------
-- Domaines fonctionnels (servent aux droits par domaine et a la RLS)
-- ------------------------------------------------------------
INSERT INTO domaine (code, libelle, description) VALUES
  ('ADMINISTRATION', 'Administration', 'Comptes du personnel, droits, parametres, audit, rapports'),
  ('STRUCTURE',      'Structure academique', 'Annees, periodes, niveaux, classes, matieres, salles, emploi du temps'),
  ('SECRETARIAT',    'Secretariat', 'Eleves, parents, familles, inscriptions, documents, cartes, demandes'),
  ('PEDAGOGIE',      'Pedagogie', 'Evaluations, notes, resultats, bulletins'),
  ('SURVEILLANCE',   'Surveillance', 'Presences, incidents, discipline'),
  ('FINANCE',        'Finance', 'Frais, creances, paiements, recus, reductions, paiement en ligne, derogations'),
  ('BIBLIOTHEQUE',   'Bibliotheque numerique', 'Ressources, diffusions, consultations, rendus')
ON CONFLICT (code) DO NOTHING;

INSERT INTO type_action (code, libelle, categorie) VALUES
  ('CONSULTER',   'Consulter',   'CONSULTATION'),
  ('GERER',       'Gerer',       'GESTION'),
  ('VALIDER',     'Valider',     'VALIDATION'),
  ('DECIDER',     'Decider',     'DECISION'),
  ('SUIVRE',      'Suivre',      'SUIVI'),
  ('PRODUIRE',    'Produire',    'PRODUCTION'),
  ('ADMINISTRER', 'Administrer', 'ADMINISTRATION')
ON CONFLICT (code) DO NOTHING;

-- Permissions : <DOMAINE>_<ACTION> pour les 4 actions principales
INSERT INTO permission (id_domaine, id_type_action, code, libelle)
SELECT d.id_domaine, t.id_type_action, d.code || '_' || t.code, t.libelle || ' : ' || d.libelle
  FROM domaine d CROSS JOIN type_action t
 WHERE t.code IN ('CONSULTER', 'GERER', 'VALIDER', 'DECIDER')
ON CONFLICT (code) DO NOTHING;

-- ------------------------------------------------------------
-- Roles types communs (chaque etablissement peut creer les siens)
-- Le DIRECTEUR n'a pas besoin de role : il a tous les droits de son etablissement.
-- ------------------------------------------------------------
INSERT INTO role (code, libelle, description) VALUES
  ('ENSEIGNANT',     'Enseignant', 'Notes et presences de ses classes, bibliotheque de ses classes'),
  ('CENSEUR',        'Responsable pedagogique', 'Structure, evaluations, validation des notes et resultats'),
  ('SECRETAIRE',     'Secretaire', 'Eleves, inscriptions, documents, cartes'),
  ('COMPTABLE',      'Comptable / Econome', 'Frais, paiements, recus, reductions, derogations'),
  ('SURVEILLANT',    'Surveillant general', 'Presences, incidents, discipline'),
  ('BIBLIOTHECAIRE', 'Bibliothecaire', 'Ressources numeriques et leur validation')
ON CONFLICT DO NOTHING;

INSERT INTO role_permission (id_role, id_permission)
SELECT r.id_role, p.id_permission
  FROM (VALUES
    ('ENSEIGNANT', 'STRUCTURE_CONSULTER'), ('ENSEIGNANT', 'SECRETARIAT_CONSULTER'), ('ENSEIGNANT', 'PEDAGOGIE_GERER'),
    ('ENSEIGNANT', 'SURVEILLANCE_GERER'), ('ENSEIGNANT', 'BIBLIOTHEQUE_GERER'),
    ('CENSEUR', 'STRUCTURE_GERER'), ('CENSEUR', 'SECRETARIAT_CONSULTER'), ('CENSEUR', 'PEDAGOGIE_GERER'),
    ('CENSEUR', 'PEDAGOGIE_VALIDER'), ('CENSEUR', 'SURVEILLANCE_CONSULTER'),
    ('SECRETAIRE', 'STRUCTURE_GERER'), ('SECRETAIRE', 'SECRETARIAT_GERER'), ('SECRETAIRE', 'SECRETARIAT_VALIDER'),
    ('SECRETAIRE', 'FINANCE_CONSULTER'),
    ('COMPTABLE', 'FINANCE_CONSULTER'), ('COMPTABLE', 'FINANCE_GERER'), ('COMPTABLE', 'FINANCE_VALIDER'),
    ('COMPTABLE', 'FINANCE_DECIDER'), ('COMPTABLE', 'SECRETARIAT_CONSULTER'),
    ('SURVEILLANT', 'SURVEILLANCE_GERER'), ('SURVEILLANT', 'SURVEILLANCE_VALIDER'), ('SURVEILLANT', 'SECRETARIAT_CONSULTER'),
    ('BIBLIOTHECAIRE', 'BIBLIOTHEQUE_GERER'), ('BIBLIOTHECAIRE', 'BIBLIOTHEQUE_VALIDER')) AS x(role_code, perm_code)
  JOIN role r ON r.code = x.role_code AND r.id_etablissement IS NULL
  JOIN permission p ON p.code = x.perm_code
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- Referentiels communs (id_etablissement NULL)
-- ------------------------------------------------------------
INSERT INTO type_document (code, libelle, genere_automatiquement) VALUES
  ('BULLETIN', 'Bulletin de notes', TRUE),
  ('CARTE_ELEVE', 'Carte eleve', TRUE),
  ('CERTIFICAT_SCOLARITE', 'Certificat de scolarite', TRUE),
  ('ACTE_NAISSANCE', 'Acte de naissance', FALSE),
  ('DIPLOME', 'Diplome ou releve', FALSE),
  ('AUTRE', 'Autre document', FALSE)
ON CONFLICT DO NOTHING;

INSERT INTO type_evaluation (code, libelle, coefficient_defaut) VALUES
  ('INTERROGATION', 'Interrogation', 1), ('DEVOIR', 'Devoir', 1), ('DEVOIR_MAISON', 'Devoir a la maison', 1),
  ('COMPOSITION', 'Composition', 2), ('EXAMEN_BLANC', 'Examen blanc', 2)
ON CONFLICT DO NOTHING;

INSERT INTO type_incident (code, libelle, gravite_defaut) VALUES
  ('RETARDS_REPETES', 'Retards repetes', 'MINEURE'), ('ABSENCE_INJUSTIFIEE', 'Absence injustifiee', 'MINEURE'),
  ('INDISCIPLINE', 'Indiscipline', 'MOYENNE'), ('FRAUDE', 'Fraude', 'GRAVE'),
  ('VIOLENCE', 'Violence', 'GRAVE'), ('DEGRADATION', 'Degradation de materiel', 'MOYENNE')
ON CONFLICT DO NOTHING;

INSERT INTO categorie_ressource (code, libelle) VALUES
  ('MANUELS', 'Manuels scolaires'), ('LITTERATURE', 'Litterature'), ('SCIENCES', 'Sciences'),
  ('LANGUES', 'Langues'), ('EXERCICES', 'Exercices et devoirs'), ('ANNALES', 'Annales d''examens')
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- Pays (indicatif -> devise) : zone CEMAC (XAF) et zone UEMOA (XOF)
-- ------------------------------------------------------------
INSERT INTO pays (code_iso, nom, indicatif_telephonique, devise) VALUES
  ('CM', 'Cameroun', '+237', 'XAF'), ('CG', 'Congo', '+242', 'XAF'), ('GA', 'Gabon', '+241', 'XAF'),
  ('TD', 'Tchad', '+235', 'XAF'), ('CF', 'Republique centrafricaine', '+236', 'XAF'),
  ('GQ', 'Guinee equatoriale', '+240', 'XAF'),
  ('SN', 'Senegal', '+221', 'XOF'), ('CI', 'Cote d''Ivoire', '+225', 'XOF'), ('BJ', 'Benin', '+229', 'XOF'),
  ('BF', 'Burkina Faso', '+226', 'XOF'), ('ML', 'Mali', '+223', 'XOF'), ('NE', 'Niger', '+227', 'XOF'),
  ('TG', 'Togo', '+228', 'XOF'), ('GW', 'Guinee-Bissau', '+245', 'XOF')
ON CONFLICT (code_iso) DO NOTHING;

-- ------------------------------------------------------------
-- Fournisseurs de paiement en ligne
-- La couverture par pays est INACTIVE par defaut : elle doit etre verifiee aupres de chaque
-- fournisseur (contrat marchand, pays couverts, prefixes de numeros) avant activation.
-- ------------------------------------------------------------
INSERT INTO fournisseur_paiement (code, libelle, type_fournisseur, supporte_partage) VALUES
  ('MTN_MOMO', 'MTN Mobile Money', 'OPERATEUR', FALSE),
  ('AIRTEL_MONEY', 'Airtel Money', 'OPERATEUR', FALSE)
ON CONFLICT (code) DO NOTHING;

INSERT INTO fournisseur_pays (id_fournisseur_paiement, id_pays, est_actif)
SELECT f.id_fournisseur_paiement, p.id_pays, FALSE
  FROM (VALUES ('MTN_MOMO', 'CM'), ('MTN_MOMO', 'CG'), ('MTN_MOMO', 'CI'), ('MTN_MOMO', 'BJ'),
               ('AIRTEL_MONEY', 'CG'), ('AIRTEL_MONEY', 'GA'), ('AIRTEL_MONEY', 'TD'), ('AIRTEL_MONEY', 'NE')) AS x(f, p)
  JOIN fournisseur_paiement f ON f.code = x.f
  JOIN pays p ON p.code_iso = x.p
ON CONFLICT DO NOTHING;

-- Modes de paiement communs (guichet et en ligne)
INSERT INTO mode_paiement (code, libelle, id_fournisseur_paiement)
SELECT x.code, x.libelle, f.id_fournisseur_paiement
  FROM (VALUES ('ESPECES', 'Especes', NULL), ('CHEQUE', 'Cheque', NULL), ('VIREMENT', 'Virement bancaire', NULL),
               ('MTN_MOMO', 'MTN Mobile Money', 'MTN_MOMO'), ('AIRTEL_MONEY', 'Airtel Money', 'AIRTEL_MONEY'))
       AS x(code, libelle, fournisseur)
  LEFT JOIN fournisseur_paiement f ON f.code = x.fournisseur
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- Parametres communs (chaque etablissement peut les surcharger)
-- ------------------------------------------------------------
INSERT INTO parametre_systeme (cle, valeur, description) VALUES
  ('BLOCAGE_RESULTATS_IMPAYES', 'FALSE', 'Bloquer le bulletin des eleves non en regle (TRUE/FALSE)'),
  ('SEUIL_TOLERANCE_IMPAYE', '0', 'Reste du tolere avant blocage du bulletin (montant)'),
  ('NOTE_ABSENCE_INJUSTIFIEE', 'ZERO', 'Absence injustifiee a une evaluation : ZERO ou EXCLU de la moyenne'),
  ('DUREE_CONSERVATION_ANNEES', '10', 'Annees avant anonymisation d''un eleve archive'),
  ('DUREE_SESSION_STAFF_HEURES', '8', 'Duree de session du staff'),
  ('DUREE_SESSION_STAFF_CONFIANCE_JOURS', '30', 'Duree de session du staff sur un appareil de confiance'),
  ('DUREE_SESSION_PARENT_JOURS', '90', 'Duree de session d''un parent sur un appareil de confiance'),
  ('DUREE_SESSION_ELEVE_JOURS', '30', 'Duree de session d''un eleve')
ON CONFLICT DO NOTHING;
