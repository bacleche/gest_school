-- Genere automatiquement a partir de MLD_gestion_scolaire.puml (ne pas modifier a la main)
SET search_path TO gestion_scolaire, public;
SET ROLE gs_proprietaire;

-- 1 - Noyau, comptes et permissions
CREATE TABLE etablissement (
  id_etablissement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code VARCHAR(20) NOT NULL UNIQUE,
  nom VARCHAR(200) NOT NULL,
  type_etablissement VARCHAR(30),
  adresse VARCHAR(255),
  ville VARCHAR(100),
  pays VARCHAR(100),
  telephone VARCHAR(30),
  email VARCHAR(254),
  logo VARCHAR(255),
  devise VARCHAR(10) NOT NULL DEFAULT 'XAF',
  est_actif BOOLEAN NOT NULL DEFAULT TRUE,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE utilisateur (
  id_utilisateur BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email VARCHAR(254) UNIQUE,
  mot_de_passe_hash VARCHAR(255),
  nom VARCHAR(100) NOT NULL,
  prenom VARCHAR(100) NOT NULL,
  telephone VARCHAR(20) UNIQUE,
  identifiant VARCHAR(50) UNIQUE,
  photo VARCHAR(255),
  est_admin_systeme BOOLEAN NOT NULL DEFAULT FALSE,
  statut_compte VARCHAR(25) NOT NULL DEFAULT 'EN_ATTENTE_ACTIVATION' CHECK (statut_compte IN ('EN_ATTENTE_ACTIVATION', 'ACTIF', 'SUSPENDU', 'DESACTIVE')),
  derniere_connexion TIMESTAMPTZ,
  tentatives_echec SMALLINT NOT NULL DEFAULT 0,
  verrouille_jusqu_a TIMESTAMPTZ,
  date_changement_mdp TIMESTAMPTZ,
  telephone_verifie_le TIMESTAMPTZ,
  email_verifie_le TIMESTAMPTZ,
  doit_changer_mdp BOOLEAN NOT NULL DEFAULT FALSE,
  type_secret VARCHAR(12) NOT NULL DEFAULT 'MOT_DE_PASSE' CHECK (type_secret IN ('MOT_DE_PASSE', 'PIN')),
  methode_2fa VARCHAR(12) NOT NULL DEFAULT 'AUCUNE' CHECK (methode_2fa IN ('AUCUNE', 'APPLICATION', 'SMS')),
  reference_secret_2fa VARCHAR(200),
  canal_notification_prefere VARCHAR(12) NOT NULL DEFAULT 'WHATSAPP' CHECK (canal_notification_prefere IN ('WHATSAPP', 'SMS', 'EMAIL', 'APPLICATION')),
  date_anonymisation TIMESTAMPTZ,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT utilisateur_ck1 CHECK (tentatives_echec >= 0),
  CONSTRAINT utilisateur_ck2 CHECK (telephone IS NOT NULL OR email IS NOT NULL OR identifiant IS NOT NULL),
  CONSTRAINT utilisateur_ck3 CHECK (statut_compte <> 'ACTIF' OR mot_de_passe_hash IS NOT NULL),
  CONSTRAINT utilisateur_ck4 CHECK (methode_2fa <> 'APPLICATION' OR reference_secret_2fa IS NOT NULL)
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE staff (
  id_staff BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_utilisateur BIGINT NOT NULL,
  id_etablissement BIGINT NOT NULL,
  id_staff_createur BIGINT,
  type_staff VARCHAR(20) NOT NULL CHECK (type_staff IN ('DIRECTEUR', 'ADMINISTRATION', 'ENSEIGNANT')),
  matricule VARCHAR(30) NOT NULL,
  fonction VARCHAR(100),
  specialite VARCHAR(100),
  date_embauche DATE,
  date_fin DATE,
  statut VARCHAR(20) NOT NULL DEFAULT 'ACTIF' CHECK (statut IN ('ACTIF', 'SUSPENDU', 'ARCHIVE')),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT staff_uq_iso UNIQUE (id_staff, id_etablissement),
  CONSTRAINT staff_uq1 UNIQUE (id_etablissement, matricule),
  CONSTRAINT staff_uq2 UNIQUE (id_utilisateur, id_etablissement)
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE domaine (
  id_domaine BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code VARCHAR(30) NOT NULL UNIQUE,
  libelle VARCHAR(100) NOT NULL,
  description VARCHAR(255)
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE type_action (
  id_type_action BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code VARCHAR(30) NOT NULL UNIQUE,
  libelle VARCHAR(100) NOT NULL,
  categorie VARCHAR(20) NOT NULL CHECK (categorie IN ('CONSULTATION', 'GESTION', 'VALIDATION', 'SUIVI', 'PRODUCTION', 'ADMINISTRATION', 'DECISION'))
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE permission (
  id_permission BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_domaine BIGINT NOT NULL,
  id_type_action BIGINT NOT NULL,
  code VARCHAR(80) NOT NULL UNIQUE,
  libelle VARCHAR(150) NOT NULL,
  ressource VARCHAR(50),
  description VARCHAR(255)
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE attribution_permission (
  id_attribution_permission BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_staff_beneficiaire BIGINT NOT NULL,
  id_permission BIGINT NOT NULL,
  id_staff_attribuant BIGINT NOT NULL,
  date_attribution TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_expiration TIMESTAMPTZ,
  est_active BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT attribution_permission_uq_iso UNIQUE (id_attribution_permission, id_etablissement),
  CONSTRAINT attribution_permission_ck1 CHECK (id_staff_attribuant <> id_staff_beneficiaire)
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE role (
  id_role BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT,
  code VARCHAR(50) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  description VARCHAR(255),
  est_actif BOOLEAN NOT NULL DEFAULT TRUE
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE role_permission (
  id_role_permission BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_role BIGINT NOT NULL,
  id_permission BIGINT NOT NULL,
  CONSTRAINT role_permission_uq1 UNIQUE (id_role, id_permission)
);
-- 1 - Noyau, comptes et permissions
CREATE TABLE attribution_role (
  id_attribution_role BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_staff_beneficiaire BIGINT NOT NULL,
  id_role BIGINT NOT NULL,
  id_staff_attribuant BIGINT NOT NULL,
  date_attribution TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_expiration TIMESTAMPTZ,
  est_active BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT attribution_role_uq_iso UNIQUE (id_attribution_role, id_etablissement),
  CONSTRAINT attribution_role_ck1 CHECK (id_staff_attribuant <> id_staff_beneficiaire)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE annee_scolaire (
  id_annee_scolaire BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  libelle VARCHAR(20) NOT NULL,
  date_debut DATE NOT NULL,
  date_fin DATE NOT NULL,
  statut VARCHAR(20) NOT NULL DEFAULT 'PLANIFIEE' CHECK (statut IN ('PLANIFIEE', 'EN_COURS', 'CLOTUREE')),
  CONSTRAINT annee_scolaire_uq_iso UNIQUE (id_annee_scolaire, id_etablissement),
  CONSTRAINT annee_scolaire_uq1 UNIQUE (id_etablissement, libelle),
  CONSTRAINT annee_scolaire_ck2 CHECK (date_fin > date_debut)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE periode (
  id_periode BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_annee_scolaire BIGINT NOT NULL,
  libelle VARCHAR(50) NOT NULL,
  numero SMALLINT NOT NULL,
  date_debut DATE NOT NULL,
  date_fin DATE NOT NULL,
  statut VARCHAR(20) NOT NULL DEFAULT 'A_VENIR' CHECK (statut IN ('A_VENIR', 'EN_COURS', 'CLOTUREE')),
  CONSTRAINT periode_uq_iso UNIQUE (id_periode, id_etablissement),
  CONSTRAINT periode_uq1 UNIQUE (id_annee_scolaire, numero),
  CONSTRAINT periode_ck2 CHECK (date_fin > date_debut),
  CONSTRAINT periode_ex3 EXCLUDE USING gist (id_annee_scolaire WITH =, daterange(date_debut, date_fin, '[]') WITH &&)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE niveau (
  id_niveau BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  code VARCHAR(20) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  cycle VARCHAR(30),
  ordre SMALLINT NOT NULL,
  CONSTRAINT niveau_uq_iso UNIQUE (id_niveau, id_etablissement),
  CONSTRAINT niveau_uq1 UNIQUE (id_etablissement, code)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE classe (
  id_classe BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_annee_scolaire BIGINT NOT NULL,
  id_niveau BIGINT NOT NULL,
  id_staff_titulaire BIGINT,
  id_salle BIGINT,
  nom VARCHAR(50) NOT NULL,
  effectif_max SMALLINT,
  statut VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (statut IN ('ACTIVE', 'ARCHIVEE')),
  CONSTRAINT classe_uq_iso UNIQUE (id_classe, id_etablissement),
  CONSTRAINT classe_uq1 UNIQUE (id_annee_scolaire, nom),
  CONSTRAINT classe_uq2 UNIQUE (id_classe, id_annee_scolaire),
  CONSTRAINT classe_ck3 CHECK (effectif_max > 0)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE matiere (
  id_matiere BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  code VARCHAR(20) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  description VARCHAR(255),
  est_active BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT matiere_uq_iso UNIQUE (id_matiere, id_etablissement),
  CONSTRAINT matiere_uq1 UNIQUE (id_etablissement, code)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE enseignement (
  id_enseignement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_classe BIGINT NOT NULL,
  id_matiere BIGINT NOT NULL,
  coefficient NUMERIC(4,2) NOT NULL DEFAULT 1,
  volume_horaire_hebdo NUMERIC(4,1),
  date_debut DATE,
  date_fin DATE,
  statut VARCHAR(20) NOT NULL DEFAULT 'ACTIF' CHECK (statut IN ('ACTIF', 'TERMINE')),
  CONSTRAINT enseignement_uq_iso UNIQUE (id_enseignement, id_etablissement),
  CONSTRAINT enseignement_uq1 UNIQUE (id_classe, id_matiere)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE creneau (
  id_creneau BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_enseignement BIGINT NOT NULL,
  id_salle BIGINT,
  jour_semaine SMALLINT NOT NULL,
  heure_debut TIME NOT NULL,
  heure_fin TIME NOT NULL,
  date_debut DATE NOT NULL,
  date_fin DATE,
  CONSTRAINT creneau_uq_iso UNIQUE (id_creneau, id_etablissement),
  CONSTRAINT creneau_uq1 UNIQUE (id_enseignement, jour_semaine, heure_debut, date_debut),
  CONSTRAINT creneau_ck2 CHECK (date_fin IS NULL OR date_fin >= date_debut),
  CONSTRAINT creneau_ck3 CHECK (jour_semaine BETWEEN 1 AND 7),
  CONSTRAINT creneau_ck4 CHECK (heure_fin > heure_debut)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE affectation_enseignant (
  id_affectation_enseignant BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_enseignement BIGINT NOT NULL,
  id_staff_enseignant BIGINT NOT NULL,
  type_affectation VARCHAR(20) NOT NULL DEFAULT 'TITULAIRE' CHECK (type_affectation IN ('TITULAIRE', 'REMPLACANT')),
  date_debut DATE NOT NULL,
  date_fin DATE,
  motif VARCHAR(255),
  CONSTRAINT affectation_enseignant_uq_iso UNIQUE (id_affectation_enseignant, id_etablissement),
  CONSTRAINT affectation_enseignant_ck1 CHECK (date_fin IS NULL OR date_fin >= date_debut),
  CONSTRAINT affectation_enseignant_ex2 EXCLUDE USING gist (id_enseignement WITH =, type_affectation WITH =, daterange(date_debut, date_fin, '[]') WITH &&)
);
-- 2 - Structure academique et emploi du temps
CREATE TABLE salle (
  id_salle BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  code VARCHAR(30) NOT NULL,
  libelle VARCHAR(100),
  capacite SMALLINT,
  est_active BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT salle_uq_iso UNIQUE (id_salle, id_etablissement),
  CONSTRAINT salle_uq1 UNIQUE (id_etablissement, code),
  CONSTRAINT salle_ck2 CHECK (capacite IS NULL OR capacite > 0)
);
-- 3 - Secretariat : eleves, parents, inscriptions, documents
CREATE TABLE parent (
  id_parent BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_utilisateur BIGINT NOT NULL UNIQUE,
  profession VARCHAR(100),
  employeur VARCHAR(150),
  adresse VARCHAR(255),
  telephone_secondaire VARCHAR(30),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- 3 - Secretariat : eleves, parents, inscriptions, documents
CREATE TABLE eleve (
  id_eleve BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_utilisateur BIGINT,
  id_famille BIGINT,
  matricule VARCHAR(30) NOT NULL,
  nom VARCHAR(100) NOT NULL,
  prenom VARCHAR(100) NOT NULL,
  sexe CHAR(1) NOT NULL CHECK (sexe IN ('M', 'F')),
  date_naissance DATE NOT NULL,
  lieu_naissance VARCHAR(100),
  nationalite VARCHAR(60),
  adresse VARCHAR(255),
  photo VARCHAR(255),
  consentement_photo BOOLEAN NOT NULL DEFAULT FALSE,
  date_consentement_photo TIMESTAMPTZ,
  date_anonymisation TIMESTAMPTZ,
  statut VARCHAR(20) NOT NULL DEFAULT 'ACTIF' CHECK (statut IN ('ACTIF', 'TRANSFERE', 'DIPLOME', 'EXCLU', 'ARCHIVE')),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT eleve_uq_iso UNIQUE (id_eleve, id_etablissement),
  CONSTRAINT eleve_uq1 UNIQUE (id_etablissement, matricule),
  CONSTRAINT eleve_uq2 UNIQUE (id_utilisateur, id_etablissement),
  CONSTRAINT eleve_ck3 CHECK (photo IS NULL OR consentement_photo)
);
-- 3 - Secretariat : eleves, parents, inscriptions, documents
CREATE TABLE eleve_parent (
  id_eleve_parent BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_eleve BIGINT NOT NULL,
  id_parent BIGINT NOT NULL,
  type_lien VARCHAR(20) NOT NULL CHECK (type_lien IN ('PERE', 'MERE', 'TUTEUR', 'AUTRE')),
  est_responsable_legal BOOLEAN NOT NULL DEFAULT FALSE,
  est_responsable_financier BOOLEAN NOT NULL DEFAULT FALSE,
  est_contact_urgence BOOLEAN NOT NULL DEFAULT FALSE,
  peut_consulter BOOLEAN NOT NULL DEFAULT TRUE,
  date_debut DATE NOT NULL DEFAULT CURRENT_DATE,
  date_fin DATE,
  CONSTRAINT eleve_parent_uq_iso UNIQUE (id_eleve_parent, id_etablissement),
  CONSTRAINT eleve_parent_uq1 UNIQUE (id_eleve, id_parent)
);
-- 3 - Secretariat : eleves, parents, inscriptions, documents
CREATE TABLE inscription (
  id_inscription BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_eleve BIGINT NOT NULL,
  id_classe BIGINT NOT NULL,
  id_annee_scolaire BIGINT NOT NULL,
  id_staff_createur BIGINT NOT NULL,
  id_staff_validateur BIGINT,
  date_inscription DATE NOT NULL,
  type_inscription VARCHAR(20) NOT NULL CHECK (type_inscription IN ('NOUVELLE', 'REINSCRIPTION')),
  statut VARCHAR(20) NOT NULL DEFAULT 'EN_ATTENTE' CHECK (statut IN ('EN_ATTENTE', 'VALIDEE', 'REJETEE', 'ANNULEE', 'CHANGEMENT_CLASSE', 'ARCHIVEE')),
  date_validation TIMESTAMPTZ,
  observation TEXT,
  CONSTRAINT inscription_uq_iso UNIQUE (id_inscription, id_etablissement)
);
-- 3 - Secretariat : eleves, parents, inscriptions, documents
CREATE TABLE type_document (
  id_type_document BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT,
  code VARCHAR(30) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  genere_automatiquement BOOLEAN NOT NULL DEFAULT FALSE
);
-- 3 - Secretariat : eleves, parents, inscriptions, documents
CREATE TABLE document (
  id_document BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_eleve BIGINT NOT NULL,
  id_type_document BIGINT NOT NULL,
  id_staff_auteur BIGINT,
  titre VARCHAR(200) NOT NULL,
  fichier VARCHAR(255) NOT NULL,
  date_document DATE NOT NULL DEFAULT CURRENT_DATE,
  visible_parent BOOLEAN NOT NULL DEFAULT FALSE,
  visible_eleve BOOLEAN NOT NULL DEFAULT FALSE,
  statut VARCHAR(20) NOT NULL DEFAULT 'ACTIF' CHECK (statut IN ('ACTIF', 'ARCHIVE')),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT document_uq_iso UNIQUE (id_document, id_etablissement)
);
-- 3 - Secretariat : eleves, parents, inscriptions, documents
CREATE TABLE famille (
  id_famille BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_parent_referent BIGINT,
  nom VARCHAR(100) NOT NULL,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT famille_uq_iso UNIQUE (id_famille, id_etablissement)
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE type_evaluation (
  id_type_evaluation BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT,
  code VARCHAR(30) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  coefficient_defaut NUMERIC(4,2) NOT NULL DEFAULT 1
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE evaluation (
  id_evaluation BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_enseignement BIGINT NOT NULL,
  id_periode BIGINT NOT NULL,
  id_type_evaluation BIGINT NOT NULL,
  id_staff_createur BIGINT NOT NULL,
  id_staff_validateur BIGINT,
  titre VARCHAR(200) NOT NULL,
  date_evaluation DATE NOT NULL,
  note_maximale NUMERIC(5,2) NOT NULL DEFAULT 20,
  coefficient NUMERIC(4,2) NOT NULL DEFAULT 1,
  statut VARCHAR(20) NOT NULL DEFAULT 'BROUILLON' CHECK (statut IN ('BROUILLON', 'SOUMISE', 'VALIDEE', 'VERROUILLEE')),
  date_validation TIMESTAMPTZ,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT evaluation_uq_iso UNIQUE (id_evaluation, id_etablissement)
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE note (
  id_note BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_evaluation BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_staff_saisie BIGINT NOT NULL,
  valeur NUMERIC(5,2),
  statut_note VARCHAR(15) NOT NULL DEFAULT 'NOTEE' CHECK (statut_note IN ('NOTEE', 'ABSENT', 'ABSENT_JUSTIFIE', 'DISPENSE')),
  observation VARCHAR(255),
  date_saisie TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_modification TIMESTAMPTZ,
  CONSTRAINT note_uq_iso UNIQUE (id_note, id_etablissement),
  CONSTRAINT note_uq1 UNIQUE (id_evaluation, id_inscription),
  CONSTRAINT note_ck2 CHECK ((statut_note = 'NOTEE') = (valeur IS NOT NULL))
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE historique_note (
  id_historique_note BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_note BIGINT NOT NULL,
  id_staff_modificateur BIGINT NOT NULL,
  type_operation VARCHAR(20) NOT NULL CHECK (type_operation IN ('CREATION', 'MODIFICATION', 'ANNULATION')),
  ancienne_valeur NUMERIC(5,2),
  nouvelle_valeur NUMERIC(5,2),
  motif VARCHAR(255),
  date_modification TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT historique_note_uq_iso UNIQUE (id_historique_note, id_etablissement)
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE resultat_matiere (
  id_resultat_matiere BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_enseignement BIGINT NOT NULL,
  id_periode BIGINT NOT NULL,
  moyenne NUMERIC(5,2),
  rang SMALLINT,
  appreciation VARCHAR(255),
  statut VARCHAR(20) NOT NULL DEFAULT 'PROVISOIRE' CHECK (statut IN ('PROVISOIRE', 'VALIDE')),
  date_calcul TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT resultat_matiere_uq_iso UNIQUE (id_resultat_matiere, id_etablissement),
  CONSTRAINT resultat_matiere_uq1 UNIQUE (id_inscription, id_enseignement, id_periode)
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE resultat_periode (
  id_resultat_periode BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_periode BIGINT NOT NULL,
  id_staff_validateur BIGINT,
  moyenne_generale NUMERIC(5,2),
  rang SMALLINT,
  mention VARCHAR(30),
  appreciation_generale TEXT,
  statut VARCHAR(20) NOT NULL DEFAULT 'PROVISOIRE' CHECK (statut IN ('PROVISOIRE', 'VALIDE', 'PUBLIE')),
  date_validation TIMESTAMPTZ,
  CONSTRAINT resultat_periode_uq_iso UNIQUE (id_resultat_periode, id_etablissement),
  CONSTRAINT resultat_periode_uq1 UNIQUE (id_inscription, id_periode)
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE resultat_annuel (
  id_resultat_annuel BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL UNIQUE,
  id_niveau_propose BIGINT,
  id_staff_validateur BIGINT,
  moyenne_annuelle NUMERIC(5,2),
  rang SMALLINT,
  decision VARCHAR(20) NOT NULL DEFAULT 'EN_ATTENTE' CHECK (decision IN ('EN_ATTENTE', 'ADMIS', 'REDOUBLE', 'EXCLU', 'DIPLOME')),
  appreciation TEXT,
  statut VARCHAR(20) NOT NULL DEFAULT 'PROVISOIRE' CHECK (statut IN ('PROVISOIRE', 'VALIDE', 'PUBLIE')),
  date_deliberation DATE,
  CONSTRAINT resultat_annuel_uq_iso UNIQUE (id_resultat_annuel, id_etablissement),
  CONSTRAINT resultat_annuel_ck1 CHECK (decision <> 'ADMIS' OR id_niveau_propose IS NOT NULL)
);
-- 4 - Responsabilite pedagogique : evaluations et resultats
CREATE TABLE derogation_acces_resultat (
  id_derogation_acces_resultat BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_periode BIGINT,
  id_staff_accordant BIGINT NOT NULL,
  motif TEXT NOT NULL,
  date_accord TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_fin_validite DATE,
  est_active BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT derogation_acces_resultat_uq_iso UNIQUE (id_derogation_acces_resultat, id_etablissement)
);
-- 5 - Surveillance : presences, incidents, discipline
CREATE TABLE presence (
  id_presence BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_creneau BIGINT,
  id_staff_enregistreur BIGINT NOT NULL,
  date_presence DATE NOT NULL,
  statut VARCHAR(20) NOT NULL CHECK (statut IN ('PRESENT', 'ABSENT', 'RETARD')),
  minutes_retard SMALLINT,
  est_justifiee BOOLEAN NOT NULL DEFAULT FALSE,
  motif VARCHAR(255),
  date_enregistrement TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT presence_uq_iso UNIQUE (id_presence, id_etablissement),
  CONSTRAINT presence_ck1 CHECK (statut <> 'RETARD' OR minutes_retard > 0),
  CONSTRAINT presence_ck2 CHECK (statut <> 'PRESENT' OR est_justifiee = FALSE)
);
-- 5 - Surveillance : presences, incidents, discipline
CREATE TABLE type_incident (
  id_type_incident BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT,
  code VARCHAR(30) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  gravite_defaut VARCHAR(10) NOT NULL DEFAULT 'MINEURE' CHECK (gravite_defaut IN ('MINEURE', 'MOYENNE', 'GRAVE'))
);
-- 5 - Surveillance : presences, incidents, discipline
CREATE TABLE incident (
  id_incident BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_type_incident BIGINT NOT NULL,
  id_staff_signalant BIGINT NOT NULL,
  id_staff_examinateur BIGINT,
  date_incident TIMESTAMPTZ NOT NULL,
  lieu VARCHAR(100),
  description TEXT NOT NULL,
  gravite VARCHAR(10) NOT NULL CHECK (gravite IN ('MINEURE', 'MOYENNE', 'GRAVE')),
  statut VARCHAR(20) NOT NULL DEFAULT 'SIGNALE' CHECK (statut IN ('SIGNALE', 'EN_EXAMEN', 'DECIDE', 'CLOTURE')),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT incident_uq_iso UNIQUE (id_incident, id_etablissement)
);
-- 5 - Surveillance : presences, incidents, discipline
CREATE TABLE observation_incident (
  id_observation_incident BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_incident BIGINT NOT NULL,
  id_staff_auteur BIGINT NOT NULL,
  contenu TEXT NOT NULL,
  date_observation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT observation_incident_uq_iso UNIQUE (id_observation_incident, id_etablissement)
);
-- 5 - Surveillance : presences, incidents, discipline
CREATE TABLE decision_disciplinaire (
  id_decision_disciplinaire BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_incident BIGINT NOT NULL,
  id_staff_decideur BIGINT NOT NULL,
  type_sanction VARCHAR(30) NOT NULL CHECK (type_sanction IN ('AUCUNE', 'AVERTISSEMENT', 'BLAME', 'RETENUE', 'EXCLUSION_TEMPORAIRE', 'EXCLUSION_DEFINITIVE')),
  description TEXT,
  date_decision DATE NOT NULL,
  date_debut DATE,
  date_fin DATE,
  statut VARCHAR(20) NOT NULL DEFAULT 'PROPOSEE' CHECK (statut IN ('PROPOSEE', 'APPROUVEE', 'APPLIQUEE', 'ANNULEE')),
  CONSTRAINT decision_disciplinaire_uq_iso UNIQUE (id_decision_disciplinaire, id_etablissement),
  CONSTRAINT decision_disciplinaire_ck1 CHECK (date_fin IS NULL OR date_debut IS NULL OR date_fin >= date_debut),
  CONSTRAINT decision_disciplinaire_ck2 CHECK (type_sanction <> 'EXCLUSION_TEMPORAIRE' OR (date_debut IS NOT NULL AND date_fin IS NOT NULL))
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE frais_scolaire (
  id_frais_scolaire BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_annee_scolaire BIGINT NOT NULL,
  id_niveau BIGINT,
  code VARCHAR(30) NOT NULL,
  libelle VARCHAR(150) NOT NULL,
  montant NUMERIC(12,2) NOT NULL,
  obligatoire BOOLEAN NOT NULL DEFAULT TRUE,
  periodicite VARCHAR(20) NOT NULL DEFAULT 'ANNUEL' CHECK (periodicite IN ('PONCTUEL', 'MENSUEL', 'TRIMESTRIEL', 'ANNUEL')),
  est_actif BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT frais_scolaire_uq_iso UNIQUE (id_frais_scolaire, id_etablissement),
  CONSTRAINT frais_scolaire_ck1 CHECK (montant >= 0)
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE echeance (
  id_echeance BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_frais_scolaire BIGINT NOT NULL,
  id_periode BIGINT,
  libelle VARCHAR(100) NOT NULL,
  date_limite DATE NOT NULL,
  montant NUMERIC(12,2) NOT NULL,
  mois_concerne DATE,
  CONSTRAINT echeance_uq_iso UNIQUE (id_echeance, id_etablissement),
  CONSTRAINT echeance_ck1 CHECK (montant >= 0),
  CONSTRAINT echeance_ck2 CHECK (mois_concerne IS NULL OR EXTRACT(DAY FROM mois_concerne) = 1)
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE creance (
  id_creance BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_echeance BIGINT NOT NULL,
  id_staff_remise BIGINT,
  id_regle_reduction BIGINT,
  montant_du NUMERIC(12,2) NOT NULL,
  remise NUMERIC(12,2) NOT NULL DEFAULT 0,
  remise_reduction NUMERIC(12,2) NOT NULL DEFAULT 0,
  motif_remise VARCHAR(255),
  statut VARCHAR(20) NOT NULL DEFAULT 'DUE' CHECK (statut IN ('DUE', 'PARTIELLE', 'SOLDEE', 'ANNULEE')),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT creance_uq_iso UNIQUE (id_creance, id_etablissement),
  CONSTRAINT creance_uq1 UNIQUE (id_inscription, id_echeance),
  CONSTRAINT creance_ck2 CHECK (remise >= 0 AND remise_reduction >= 0 AND remise + remise_reduction <= montant_du),
  CONSTRAINT creance_ck3 CHECK ((remise_reduction = 0) = (id_regle_reduction IS NULL)),
  CONSTRAINT creance_ck4 CHECK (remise = 0 OR (motif_remise IS NOT NULL AND id_staff_remise IS NOT NULL))
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE mode_paiement (
  id_mode_paiement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT,
  id_fournisseur_paiement BIGINT,
  code VARCHAR(30) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  est_actif BOOLEAN NOT NULL DEFAULT TRUE
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE paiement (
  id_paiement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_mode_paiement BIGINT NOT NULL,
  id_parent_payeur BIGINT,
  id_staff_enregistreur BIGINT,
  id_transaction_en_ligne BIGINT UNIQUE,
  id_staff_validateur BIGINT,
  numero VARCHAR(40) NOT NULL,
  montant NUMERIC(12,2) NOT NULL,
  date_paiement TIMESTAMPTZ NOT NULL,
  canal VARCHAR(10) NOT NULL DEFAULT 'GUICHET' CHECK (canal IN ('GUICHET', 'EN_LIGNE')),
  reference_externe VARCHAR(100),
  nom_payeur VARCHAR(150),
  telephone_payeur VARCHAR(30),
  statut VARCHAR(20) NOT NULL DEFAULT 'EN_ATTENTE' CHECK (statut IN ('EN_ATTENTE', 'VALIDE', 'ANNULE')),
  date_validation TIMESTAMPTZ,
  observation VARCHAR(255),
  CONSTRAINT paiement_uq_iso UNIQUE (id_paiement, id_etablissement),
  CONSTRAINT paiement_uq1 UNIQUE (id_etablissement, numero),
  CONSTRAINT paiement_ck2 CHECK (montant > 0),
  CONSTRAINT paiement_ck3 CHECK (canal = 'EN_LIGNE' OR id_staff_enregistreur IS NOT NULL),
  CONSTRAINT paiement_ck4 CHECK (id_parent_payeur IS NOT NULL OR nom_payeur IS NOT NULL),
  CONSTRAINT paiement_ck5 CHECK ((canal = 'EN_LIGNE') = (id_transaction_en_ligne IS NOT NULL))
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE allocation_paiement (
  id_allocation_paiement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_paiement BIGINT NOT NULL,
  id_creance BIGINT NOT NULL,
  montant_alloue NUMERIC(12,2) NOT NULL,
  date_allocation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT allocation_paiement_uq_iso UNIQUE (id_allocation_paiement, id_etablissement),
  CONSTRAINT allocation_paiement_uq1 UNIQUE (id_paiement, id_creance),
  CONSTRAINT allocation_paiement_ck2 CHECK (montant_alloue > 0)
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE recu (
  id_recu BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_paiement BIGINT NOT NULL,
  id_etablissement BIGINT NOT NULL,
  id_staff_emetteur BIGINT,
  numero VARCHAR(40) NOT NULL,
  nom_payeur VARCHAR(150) NOT NULL,
  montant NUMERIC(12,2) NOT NULL,
  devise VARCHAR(3) NOT NULL,
  detail JSONB NOT NULL,
  code_verification VARCHAR(32) NOT NULL UNIQUE,
  date_emission TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fichier VARCHAR(255),
  statut VARCHAR(20) NOT NULL DEFAULT 'VALIDE' CHECK (statut IN ('VALIDE', 'ANNULE')),
  CONSTRAINT recu_uq_iso UNIQUE (id_recu, id_etablissement),
  CONSTRAINT recu_uq1 UNIQUE (id_etablissement, numero)
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE annulation_paiement (
  id_annulation_paiement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_paiement BIGINT NOT NULL,
  id_staff_demandeur BIGINT NOT NULL,
  id_staff_approbateur BIGINT,
  motif TEXT NOT NULL,
  statut VARCHAR(20) NOT NULL DEFAULT 'DEMANDEE' CHECK (statut IN ('DEMANDEE', 'APPROUVEE', 'REJETEE')),
  date_demande TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_decision TIMESTAMPTZ,
  CONSTRAINT annulation_paiement_uq_iso UNIQUE (id_annulation_paiement, id_etablissement)
);
-- 6 - Finance : frais, paiements, recus
CREATE TABLE regle_reduction (
  id_regle_reduction BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_annee_scolaire BIGINT NOT NULL,
  id_frais_scolaire BIGINT,
  libelle VARCHAR(150) NOT NULL,
  type_reduction VARCHAR(20) NOT NULL DEFAULT 'FRATRIE' CHECK (type_reduction IN ('FRATRIE', 'AUTRE')),
  rang_enfant_min SMALLINT NOT NULL DEFAULT 2,
  mode_calcul VARCHAR(12) NOT NULL CHECK (mode_calcul IN ('POURCENTAGE', 'MONTANT')),
  valeur NUMERIC(12,2) NOT NULL,
  est_active BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT regle_reduction_uq_iso UNIQUE (id_regle_reduction, id_etablissement),
  CONSTRAINT regle_reduction_ck1 CHECK (valeur > 0),
  CONSTRAINT regle_reduction_ck2 CHECK (mode_calcul <> 'POURCENTAGE' OR valeur <= 100),
  CONSTRAINT regle_reduction_ck3 CHECK (rang_enfant_min >= 1)
);
-- 7 - Transversal : notifications, demandes, rapports, audit
CREATE TABLE notification (
  id_notification BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_utilisateur BIGINT NOT NULL,
  id_etablissement BIGINT,
  type_notification VARCHAR(40) NOT NULL,
  titre VARCHAR(200) NOT NULL,
  message TEXT NOT NULL,
  priorite VARCHAR(10) NOT NULL DEFAULT 'NORMALE' CHECK (priorite IN ('BASSE', 'NORMALE', 'HAUTE', 'URGENTE')),
  entite_type VARCHAR(50),
  entite_id BIGINT,
  est_lue BOOLEAN NOT NULL DEFAULT FALSE,
  date_lecture TIMESTAMPTZ,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- 7 - Transversal : notifications, demandes, rapports, audit
CREATE TABLE demande (
  id_demande BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_utilisateur_demandeur BIGINT NOT NULL,
  id_eleve BIGINT,
  id_staff_traitant BIGINT,
  type_demande VARCHAR(40) NOT NULL,
  objet VARCHAR(200) NOT NULL,
  description TEXT NOT NULL,
  statut VARCHAR(20) NOT NULL DEFAULT 'EN_ATTENTE' CHECK (statut IN ('EN_ATTENTE', 'EN_COURS', 'APPROUVEE', 'REJETEE', 'CLOTUREE')),
  reponse TEXT,
  date_demande TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_traitement TIMESTAMPTZ,
  CONSTRAINT demande_uq_iso UNIQUE (id_demande, id_etablissement)
);
-- 7 - Transversal : notifications, demandes, rapports, audit
CREATE TABLE rapport (
  id_rapport BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_domaine BIGINT,
  id_utilisateur_generateur BIGINT NOT NULL,
  titre VARCHAR(200) NOT NULL,
  type_rapport VARCHAR(50) NOT NULL,
  periode_debut DATE,
  periode_fin DATE,
  parametres TEXT,
  format_fichier VARCHAR(10) NOT NULL CHECK (format_fichier IN ('PDF', 'XLSX', 'CSV')),
  fichier VARCHAR(255),
  date_generation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT rapport_uq_iso UNIQUE (id_rapport, id_etablissement)
);
-- 7 - Transversal : notifications, demandes, rapports, audit
CREATE TABLE journal_audit (
  id_journal_audit BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_utilisateur BIGINT,
  id_etablissement BIGINT,
  type_operation VARCHAR(50) NOT NULL,
  entite_type VARCHAR(80) NOT NULL,
  entite_id BIGINT,
  anciennes_valeurs TEXT,
  nouvelles_valeurs TEXT,
  adresse_ip VARCHAR(45),
  date_action TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- 7 - Transversal : notifications, demandes, rapports, audit
CREATE TABLE parametre_systeme (
  id_parametre_systeme BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT,
  id_utilisateur_modificateur BIGINT,
  cle VARCHAR(100) NOT NULL,
  valeur TEXT NOT NULL,
  description VARCHAR(255),
  date_modification TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- 7 - Transversal : notifications, demandes, rapports, audit
CREATE TABLE envoi_notification (
  id_envoi_notification BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_notification BIGINT NOT NULL,
  id_etablissement BIGINT,
  canal VARCHAR(12) NOT NULL CHECK (canal IN ('APPLICATION', 'WHATSAPP', 'SMS', 'EMAIL')),
  destination VARCHAR(254) NOT NULL,
  fournisseur_envoi VARCHAR(50),
  reference_fournisseur VARCHAR(100),
  statut VARCHAR(12) NOT NULL DEFAULT 'EN_ATTENTE' CHECK (statut IN ('EN_ATTENTE', 'ENVOYE', 'DISTRIBUE', 'ECHEC')),
  tentatives SMALLINT NOT NULL DEFAULT 0,
  cout NUMERIC(10,2),
  devise VARCHAR(3),
  code_erreur VARCHAR(50),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_envoi TIMESTAMPTZ,
  date_distribution TIMESTAMPTZ,
  CONSTRAINT envoi_notification_ck1 CHECK (tentatives >= 0 AND (cout IS NULL OR cout >= 0)),
  CONSTRAINT envoi_notification_ck2 CHECK (statut <> 'DISTRIBUE' OR date_distribution IS NOT NULL)
);
-- 8 - Bibliotheque numerique : ressources, diffusions, rendus
CREATE TABLE categorie_ressource (
  id_categorie_ressource BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT,
  code VARCHAR(30) NOT NULL,
  libelle VARCHAR(100) NOT NULL,
  description VARCHAR(255),
  est_active BOOLEAN NOT NULL DEFAULT TRUE
);
-- 8 - Bibliotheque numerique : ressources, diffusions, rendus
CREATE TABLE ressource_numerique (
  id_ressource_numerique BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_categorie_ressource BIGINT,
  id_matiere BIGINT,
  id_staff_auteur BIGINT NOT NULL,
  id_staff_validateur BIGINT,
  titre VARCHAR(200) NOT NULL,
  auteur VARCHAR(150),
  editeur VARCHAR(150),
  annee_publication SMALLINT,
  isbn VARCHAR(20),
  description TEXT,
  type_ressource VARCHAR(20) NOT NULL CHECK (type_ressource IN ('LIVRE', 'MANUEL', 'COURS', 'EXERCICE', 'VIDEO', 'AUDIO', 'AUTRE')),
  fichier VARCHAR(255),
  url VARCHAR(500),
  format VARCHAR(10) NOT NULL CHECK (format IN ('PDF', 'EPUB', 'DOCX', 'MP4', 'MP3', 'LIEN', 'AUTRE')),
  langue VARCHAR(10),
  licence VARCHAR(20) NOT NULL DEFAULT 'LECTURE_SEULE' CHECK (licence IN ('LECTURE_SEULE', 'TELECHARGEABLE')),
  statut VARCHAR(20) NOT NULL DEFAULT 'BROUILLON' CHECK (statut IN ('BROUILLON', 'SOUMISE', 'PUBLIEE', 'ARCHIVEE')),
  date_ajout TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_publication TIMESTAMPTZ,
  CONSTRAINT ressource_numerique_uq_iso UNIQUE (id_ressource_numerique, id_etablissement),
  CONSTRAINT ressource_numerique_ck1 CHECK (fichier IS NOT NULL OR url IS NOT NULL),
  CONSTRAINT ressource_numerique_ck2 CHECK (id_staff_validateur IS NULL OR id_staff_validateur <> id_staff_auteur),
  CONSTRAINT ressource_numerique_ck3 CHECK (statut <> 'PUBLIEE' OR date_publication IS NOT NULL)
);
-- 8 - Bibliotheque numerique : ressources, diffusions, rendus
CREATE TABLE ressource_diffusion (
  id_ressource_diffusion BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_ressource_numerique BIGINT NOT NULL,
  id_niveau BIGINT,
  id_classe BIGINT,
  id_staff_diffuseur BIGINT NOT NULL,
  id_evaluation BIGINT,
  date_debut DATE NOT NULL,
  date_fin DATE,
  rendu_attendu BOOLEAN NOT NULL DEFAULT FALSE,
  date_limite_rendu TIMESTAMPTZ,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT ressource_diffusion_uq_iso UNIQUE (id_ressource_diffusion, id_etablissement),
  CONSTRAINT ressource_diffusion_ck1 CHECK (id_niveau IS NULL OR id_classe IS NULL),
  CONSTRAINT ressource_diffusion_ck2 CHECK (date_fin IS NULL OR date_fin >= date_debut),
  CONSTRAINT ressource_diffusion_ck3 CHECK (NOT rendu_attendu OR id_classe IS NOT NULL),
  CONSTRAINT ressource_diffusion_ck4 CHECK (rendu_attendu OR date_limite_rendu IS NULL),
  CONSTRAINT ressource_diffusion_ck5 CHECK (id_evaluation IS NULL OR rendu_attendu)
);
-- 8 - Bibliotheque numerique : ressources, diffusions, rendus
CREATE TABLE consultation_ressource (
  id_consultation_ressource BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_ressource_numerique BIGINT NOT NULL,
  id_utilisateur BIGINT NOT NULL,
  type_consultation VARCHAR(20) NOT NULL CHECK (type_consultation IN ('LECTURE', 'TELECHARGEMENT')),
  date_consultation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT consultation_ressource_uq_iso UNIQUE (id_consultation_ressource, id_etablissement)
);
-- 8 - Bibliotheque numerique : ressources, diffusions, rendus
CREATE TABLE rendu_travail (
  id_rendu_travail BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_ressource_diffusion BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_staff_correcteur BIGINT,
  fichier VARCHAR(255) NOT NULL,
  commentaire_eleve TEXT,
  date_rendu TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  statut VARCHAR(20) NOT NULL DEFAULT 'RENDU' CHECK (statut IN ('RENDU', 'CORRIGE')),
  commentaire_correction TEXT,
  date_correction TIMESTAMPTZ,
  CONSTRAINT rendu_travail_uq_iso UNIQUE (id_rendu_travail, id_etablissement),
  CONSTRAINT rendu_travail_uq1 UNIQUE (id_ressource_diffusion, id_inscription),
  CONSTRAINT rendu_travail_ck2 CHECK (statut <> 'CORRIGE' OR (id_staff_correcteur IS NOT NULL AND date_correction IS NOT NULL))
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE fournisseur_paiement (
  id_fournisseur_paiement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code VARCHAR(30) NOT NULL UNIQUE,
  libelle VARCHAR(100) NOT NULL,
  type_fournisseur VARCHAR(20) NOT NULL CHECK (type_fournisseur IN ('OPERATEUR', 'AGREGATEUR')),
  supporte_partage BOOLEAN NOT NULL DEFAULT FALSE,
  est_actif BOOLEAN NOT NULL DEFAULT TRUE
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE pays (
  id_pays BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code_iso CHAR(2) NOT NULL UNIQUE,
  nom VARCHAR(100) NOT NULL,
  indicatif_telephonique VARCHAR(5) NOT NULL UNIQUE,
  devise VARCHAR(3) NOT NULL,
  CONSTRAINT pays_ck1 CHECK (char_length(devise) = 3)
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE fournisseur_pays (
  id_fournisseur_pays BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_fournisseur_paiement BIGINT NOT NULL,
  id_pays BIGINT NOT NULL,
  prefixes_numero VARCHAR(100),
  est_actif BOOLEAN NOT NULL DEFAULT TRUE,
  CONSTRAINT fournisseur_pays_uq1 UNIQUE (id_fournisseur_paiement, id_pays)
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE config_paiement_etablissement (
  id_config_paiement_etablissement BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_fournisseur_paiement BIGINT NOT NULL,
  identifiant_marchand VARCHAR(100) NOT NULL,
  reference_secret VARCHAR(200) NOT NULL,
  environnement VARCHAR(10) NOT NULL DEFAULT 'TEST' CHECK (environnement IN ('TEST', 'PRODUCTION')),
  frais_a_charge VARCHAR(15) NOT NULL DEFAULT 'PARENT' CHECK (frais_a_charge IN ('PARENT', 'ETABLISSEMENT')),
  est_actif BOOLEAN NOT NULL DEFAULT TRUE,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT config_paiement_etablissement_uq_iso UNIQUE (id_config_paiement_etablissement, id_etablissement),
  CONSTRAINT config_paiement_etablissement_uq1 UNIQUE (id_etablissement, id_fournisseur_paiement, environnement)
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE transaction_en_ligne (
  id_transaction_en_ligne BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_config_paiement_etablissement BIGINT NOT NULL,
  id_utilisateur_initiateur BIGINT NOT NULL,
  id_pays BIGINT NOT NULL,
  id_contrat_plateforme BIGINT NOT NULL,
  id_facture_commission BIGINT,
  numero_telephone VARCHAR(20) NOT NULL,
  reference_interne VARCHAR(64) NOT NULL UNIQUE,
  reference_fournisseur VARCHAR(100),
  montant NUMERIC(12,2) NOT NULL,
  frais_operateur NUMERIC(12,2) NOT NULL DEFAULT 0,
  taux_commission NUMERIC(5,2) NOT NULL,
  montant_commission NUMERIC(12,2) NOT NULL DEFAULT 0,
  mode_perception_commission VARCHAR(12) NOT NULL CHECK (mode_perception_commission IN ('PARTAGE', 'FACTURATION')),
  montant_total NUMERIC(12,2) NOT NULL,
  devise VARCHAR(3) NOT NULL,
  taux_change NUMERIC(12,6) NOT NULL DEFAULT 1,
  statut VARCHAR(15) NOT NULL DEFAULT 'INITIEE' CHECK (statut IN ('INITIEE', 'EN_ATTENTE', 'REUSSIE', 'ECHOUEE', 'EXPIREE')),
  code_erreur VARCHAR(50),
  message_erreur VARCHAR(255),
  date_initiation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_expiration TIMESTAMPTZ NOT NULL,
  date_confirmation TIMESTAMPTZ,
  CONSTRAINT transaction_en_ligne_uq_iso UNIQUE (id_transaction_en_ligne, id_etablissement),
  CONSTRAINT transaction_en_ligne_ck1 CHECK (montant > 0 AND frais_operateur >= 0 AND taux_change > 0),
  CONSTRAINT transaction_en_ligne_ck2 CHECK (date_expiration > date_initiation),
  CONSTRAINT transaction_en_ligne_ck3 CHECK (taux_commission >= 0 AND montant_commission >= 0),
  CONSTRAINT transaction_en_ligne_ck4 CHECK (id_facture_commission IS NULL OR mode_perception_commission = 'FACTURATION'),
  CONSTRAINT transaction_en_ligne_ck5 CHECK (statut <> 'REUSSIE' OR (reference_fournisseur IS NOT NULL AND date_confirmation IS NOT NULL))
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE transaction_creance (
  id_transaction_creance BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_transaction_en_ligne BIGINT NOT NULL,
  id_creance BIGINT NOT NULL,
  montant NUMERIC(12,2) NOT NULL,
  CONSTRAINT transaction_creance_uq_iso UNIQUE (id_transaction_creance, id_etablissement),
  CONSTRAINT transaction_creance_uq1 UNIQUE (id_transaction_en_ligne, id_creance),
  CONSTRAINT transaction_creance_ck2 CHECK (montant > 0)
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE notification_fournisseur (
  id_notification_fournisseur BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_fournisseur_paiement BIGINT NOT NULL,
  id_transaction_en_ligne BIGINT,
  reference_fournisseur VARCHAR(100),
  contenu_brut TEXT NOT NULL,
  signature_valide BOOLEAN NOT NULL,
  adresse_ip VARCHAR(45),
  statut_traitement VARCHAR(20) NOT NULL DEFAULT 'RECUE' CHECK (statut_traitement IN ('RECUE', 'TRAITEE', 'DOUBLON', 'REJETEE')),
  date_reception TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_traitement TIMESTAMPTZ
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE contrat_plateforme (
  id_contrat_plateforme BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  reference_contrat VARCHAR(50),
  taux_commission NUMERIC(5,2) NOT NULL DEFAULT 1.00,
  commission_a_charge VARCHAR(15) NOT NULL DEFAULT 'ETABLISSEMENT' CHECK (commission_a_charge IN ('ETABLISSEMENT', 'PARENT')),
  date_debut DATE NOT NULL,
  date_fin DATE,
  statut VARCHAR(10) NOT NULL DEFAULT 'ACTIF' CHECK (statut IN ('ACTIF', 'SUSPENDU', 'RESILIE')),
  CONSTRAINT contrat_plateforme_uq_iso UNIQUE (id_contrat_plateforme, id_etablissement),
  CONSTRAINT contrat_plateforme_ck1 CHECK (taux_commission >= 0 AND taux_commission <= 100),
  CONSTRAINT contrat_plateforme_ck2 CHECK (date_fin IS NULL OR date_fin >= date_debut),
  CONSTRAINT contrat_plateforme_ex3 EXCLUDE USING gist (id_etablissement WITH =, daterange(date_debut, date_fin, '[]') WITH &&)
);
-- 9 - Finance : paiement en ligne (Mobile Money, agregateurs)
CREATE TABLE facture_commission (
  id_facture_commission BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  numero VARCHAR(40) NOT NULL UNIQUE,
  mois DATE NOT NULL,
  montant_total NUMERIC(12,2) NOT NULL,
  devise VARCHAR(3) NOT NULL,
  statut VARCHAR(10) NOT NULL DEFAULT 'BROUILLON' CHECK (statut IN ('BROUILLON', 'EMISE', 'PAYEE', 'ANNULEE')),
  date_emission TIMESTAMPTZ,
  date_echeance DATE,
  date_paiement TIMESTAMPTZ,
  fichier VARCHAR(255),
  CONSTRAINT facture_commission_uq_iso UNIQUE (id_facture_commission, id_etablissement),
  CONSTRAINT facture_commission_ck1 CHECK (EXTRACT(DAY FROM mois) = 1)
);
-- 10 - Authentification, sessions et carte eleve
CREATE TABLE appareil_confiance (
  id_appareil_confiance BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_utilisateur BIGINT NOT NULL,
  empreinte_appareil VARCHAR(128) NOT NULL,
  nom_appareil VARCHAR(100),
  date_ajout TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  derniere_utilisation TIMESTAMPTZ,
  date_expiration TIMESTAMPTZ NOT NULL,
  date_revocation TIMESTAMPTZ,
  CONSTRAINT appareil_confiance_uq1 UNIQUE (id_utilisateur, empreinte_appareil),
  CONSTRAINT appareil_confiance_ck2 CHECK (date_expiration > date_ajout)
);
-- 10 - Authentification, sessions et carte eleve
CREATE TABLE session_utilisateur (
  id_session_utilisateur BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_utilisateur BIGINT NOT NULL,
  id_appareil_confiance BIGINT,
  id_etablissement_actif BIGINT,
  role_actif VARCHAR(10) NOT NULL CHECK (role_actif IN ('STAFF', 'PARENT', 'ELEVE', 'ADMIN')),
  empreinte_jeton VARCHAR(128) NOT NULL UNIQUE,
  adresse_ip VARCHAR(45),
  agent_utilisateur VARCHAR(255),
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_expiration TIMESTAMPTZ NOT NULL,
  derniere_activite TIMESTAMPTZ,
  date_revocation TIMESTAMPTZ,
  CONSTRAINT session_utilisateur_ck1 CHECK (date_expiration > date_creation),
  CONSTRAINT session_utilisateur_ck2 CHECK (role_actif = 'ADMIN' OR id_etablissement_actif IS NOT NULL)
);
-- 10 - Authentification, sessions et carte eleve
CREATE TABLE code_verification (
  id_code_verification BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_utilisateur BIGINT NOT NULL,
  canal VARCHAR(10) NOT NULL CHECK (canal IN ('WHATSAPP', 'SMS', 'EMAIL')),
  objet VARCHAR(25) NOT NULL CHECK (objet IN ('ACTIVATION', 'MOT_DE_PASSE_OUBLIE', 'NOUVEL_APPAREIL', 'CHANGEMENT_NUMERO', 'DOUBLE_AUTH')),
  destination VARCHAR(254) NOT NULL,
  empreinte_code VARCHAR(128) NOT NULL,
  tentatives SMALLINT NOT NULL DEFAULT 0,
  date_creation TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  date_expiration TIMESTAMPTZ NOT NULL,
  date_utilisation TIMESTAMPTZ,
  CONSTRAINT code_verification_ck1 CHECK (tentatives BETWEEN 0 AND 5),
  CONSTRAINT code_verification_ck2 CHECK (date_expiration > date_creation)
);
-- 10 - Authentification, sessions et carte eleve
CREATE TABLE carte_eleve (
  id_carte_eleve BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_etablissement BIGINT NOT NULL,
  id_eleve BIGINT NOT NULL,
  id_inscription BIGINT NOT NULL,
  id_document BIGINT UNIQUE,
  numero_carte VARCHAR(40) NOT NULL,
  empreinte_jeton_qr VARCHAR(128) NOT NULL UNIQUE,
  date_emission DATE NOT NULL DEFAULT CURRENT_DATE,
  date_expiration DATE NOT NULL,
  statut VARCHAR(10) NOT NULL DEFAULT 'ACTIVE' CHECK (statut IN ('ACTIVE', 'PERDUE', 'REVOQUEE', 'EXPIREE')),
  fichier VARCHAR(255),
  motif_revocation VARCHAR(255),
  CONSTRAINT carte_eleve_uq_iso UNIQUE (id_carte_eleve, id_etablissement),
  CONSTRAINT carte_eleve_uq1 UNIQUE (id_etablissement, numero_carte),
  CONSTRAINT carte_eleve_ck2 CHECK (date_expiration > date_emission),
  CONSTRAINT carte_eleve_ck3 CHECK (statut <> 'REVOQUEE' OR motif_revocation IS NOT NULL)
);

-- Documentation des regles metier (NB et regles controlees par trigger)
COMMENT ON TABLE utilisateur IS 'compte cree par l''ecole en EN_ATTENTE_ACTIVATION ; ACTIF apres code + choix du mot de passe ou du PIN | connexion staff/parent par telephone (e-mail en option) ; eleve par identifiant ou QR code de sa carte | mot_de_passe_hash = empreinte Argon2id du mot de passe ou du PIN ; reference_secret_2fa pointe vers le coffre | UTILISATEUR commun ; visible (RLS) seulement s''il est STAFF, PARENT ou ELEVE de l''etablissement | Regle (trigger) : telephone au format international E.164, ex. +2376XXXXXXXX (trigger) | Regle (trigger) : compte STAFF ou PARENT => telephone renseigne ; compte ELEVE => identifiant renseigne (trigger) | Regle (trigger) : PIN autorise seulement pour PARENT et ELEVE (trigger) | Regle (trigger) : double authentification obligatoire si DIRECTEUR ou droits FINANCE / VALIDATION (trigger)';
COMMENT ON TABLE attribution_permission IS 'Regle (trigger) : l''attribuant possede cette permission ou est DIRECTEUR (trigger)';
COMMENT ON TABLE role_permission IS 'isolee via ROLE (RLS du role)';
COMMENT ON TABLE attribution_role IS 'Regle (trigger) : role global ou du meme etablissement que le staff (trigger) | Regle (trigger) : l''attribuant possede toutes les permissions du role ou est DIRECTEUR (trigger)';
COMMENT ON TABLE annee_scolaire IS 'Regle (trigger) : annee CLOTUREE => donnees de l''annee en lecture seule, sauf encaissement des creances impayees (trigger)';
COMMENT ON TABLE periode IS 'Regle (trigger) : periode incluse dans son annee scolaire (trigger) | Regle (trigger) : periode CLOTUREE => evaluations, notes, presences et resultats de la periode en lecture seule (trigger)';
COMMENT ON TABLE classe IS 'Regle (trigger) : nombre d''inscriptions VALIDEE <= effectif_max (trigger) | Regle (trigger) : titulaire de type ENSEIGNANT (trigger)';
COMMENT ON TABLE creneau IS 'Regle (trigger) : validite du creneau incluse dans l''annee scolaire (trigger) | Regle (trigger) : aucun chevauchement horaire pour une meme classe, un meme enseignant, une meme salle, sur une meme periode de validite (trigger)';
COMMENT ON TABLE affectation_enseignant IS 'Regle (trigger) : staff de type ENSEIGNANT (trigger)';
COMMENT ON TABLE parent IS 'PARENT commun ; visible (RLS) seulement via ELEVE_PARENT vers un eleve de l''etablissement';
COMMENT ON TABLE eleve IS 'transfert = nouvelle fiche ELEVE dans l''autre ecole, meme compte et meme identifiant de connexion | ARCHIVE depuis plus de DUREE_CONSERVATION_ANNEES => anonymisation (identite, photo, adresse, contacts) ; | scolarite et paiements conserves sous pseudonyme (traitement planifie, trace dans JOURNAL_AUDIT) | nom/prenom conserves ici car le compte UTILISATEUR de l''eleve est facultatif';
COMMENT ON TABLE eleve_parent IS 'acces parent (RLS) seulement si lien actif (date_fin NULL ou future) et peut_consulter = TRUE | Regle (trigger) : au moins un responsable legal actif par eleve (trigger)';
COMMENT ON TABLE inscription IS 'changement de classe = ancienne inscription close (CHANGEMENT_CLASSE) + nouvelle inscription ; | notes, presences et creances deja saisies restent rattachees a l''ancienne inscription | passage a VALIDEE => compte eleve (si absent), CARTE_ELEVE et son PDF generes automatiquement';
COMMENT ON TABLE type_document IS 'id_etablissement NULL = valeur commune a tous les etablissements | Regle (trigger) : valeur propre utilisable seulement par son etablissement (trigger)';
COMMENT ON TABLE document IS 'visible parent (RLS) si visible_parent = TRUE et lien actif ; eleve si visible_eleve = TRUE | un document de type BULLETIN est en plus soumis a est_en_regle (blocage des impayes)';
COMMENT ON TABLE famille IS 'regroupe les freres et soeurs d''un etablissement (reduction famille nombreuse) | un eleve appartient au plus a une famille ; le referent est le parent payeur habituel | composition modifiee (inscription annulee, enfant ajoute ou retire) => recalcul des reductions | des creances non soldees de la famille (trigger)';
COMMENT ON TABLE type_evaluation IS 'id_etablissement NULL = valeur commune a tous les etablissements | Regle (trigger) : valeur propre utilisable seulement par son etablissement (trigger)';
COMMENT ON TABLE evaluation IS 'Regle (trigger) : periode de la meme annee scolaire que la classe de l''enseignement (trigger) | Regle (trigger) : date_evaluation comprise dans la periode (trigger)';
COMMENT ON TABLE note IS 'ABSENT_JUSTIFIE et DISPENSE exclus de la moyenne ; ABSENT selon NOTE_ABSENCE_INJUSTIFIEE (ZERO ou EXCLU) | visible parent/eleve (RLS) seulement si l''evaluation est VALIDEE ou VERROUILLEE (jamais bloquee par les impayes) | Regle (trigger) : valeur >= 0 ET valeur <= evaluation.note_maximale (trigger) | Regle (trigger) : inscription VALIDEE dans la classe de l''enseignement evalue (trigger) | Regle (trigger) : aucune modification si l''evaluation est VERROUILLEE (trigger)';
COMMENT ON TABLE historique_note IS 'table en INSERT seul (UPDATE et DELETE revoques)';
COMMENT ON TABLE resultat_matiere IS 'visible parent/eleve (RLS) seulement si le RESULTAT_PERIODE est PUBLIE et est_en_regle(inscription, periode) | Regle (trigger) : inscription dans la classe de l''enseignement, periode de l''annee de l''inscription (trigger)';
COMMENT ON TABLE resultat_periode IS 'visible parent/eleve (RLS) seulement si statut = ''PUBLIE'' et est_en_regle(inscription, periode) (blocage des impayes) | Regle (trigger) : periode de l''annee de l''inscription (trigger)';
COMMENT ON TABLE resultat_annuel IS 'visible parent/eleve (RLS) seulement si statut = ''PUBLIE'' et est_en_regle sur toute l''annee (blocage des impayes)';
COMMENT ON TABLE derogation_acces_resultat IS 'id_periode vide = toute l''annee ; chaque derogation est tracee dans JOURNAL_AUDIT | est_en_regle(inscription, periode) = blocage desactive OU derogation active OU reste du | des creances obligatoires echues (date_limite <= fin de periode) <= SEUIL_TOLERANCE_IMPAYE | bloque seulement le bulletin (resultats, moyennes, rang, decision) ; notes, presences et discipline restent visibles | Regle (trigger) : accordant = DIRECTEUR ou titulaire d''une permission de derogation (trigger) | Regle (trigger) : periode de l''annee de l''inscription (trigger)';
COMMENT ON TABLE presence IS 'Regle (trigger) : jour de date_presence = creneau.jour_semaine et date dans la validite du creneau (trigger)';
COMMENT ON TABLE type_incident IS 'id_etablissement NULL = valeur commune a tous les etablissements | Regle (trigger) : valeur propre utilisable seulement par son etablissement (trigger)';
COMMENT ON TABLE incident IS 'un seul eleve par incident (plusieurs eleves impliques = plusieurs incidents)';
COMMENT ON TABLE decision_disciplinaire IS 'Regle (trigger) : EXCLUSION_DEFINITIVE APPLIQUEE => eleve.statut = ''EXCLU'' (trigger)';
COMMENT ON TABLE echeance IS 'mois_concerne = mois couvert (frais MENSUEL) pour afficher les mois payes / impayes | Regle (trigger) : somme des echeances = frais_scolaire.montant (trigger)';
COMMENT ON TABLE creance IS 'reste du = montant_du - remise - remise_reduction - allocations (vue SITUATION_FINANCIERE_ELEVE) | visible (RLS) par les parents/tuteurs actifs et l''eleve concerne : mois payes, partiels, impayes | Regle (trigger) : echeance de l''annee de l''inscription, frais du niveau de la classe ou commun (trigger) | Regle (trigger) : reduction : regle de l''annee et rang de l''eleve dans sa famille >= rang_enfant_min (trigger)';
COMMENT ON TABLE mode_paiement IS 'id_etablissement NULL = valeur commune a tous les etablissements | Regle (trigger) : valeur propre utilisable seulement par son etablissement (trigger)';
COMMENT ON TABLE paiement IS 'un paiement peut regler les creances de plusieurs enfants (paiement famille) | paiement EN_LIGNE cree automatiquement (VALIDE) a partir d''une TRANSACTION_EN_LIGNE REUSSIE';
COMMENT ON TABLE allocation_paiement IS 'Regle (trigger) : somme allouee <= paiement.montant et <= montant_du - remise - remise_reduction (trigger) | Regle (trigger) : parent payeur renseigne => responsable financier de l''eleve de la creance (trigger)';
COMMENT ON TABLE recu IS 'meme recu pour GUICHET et EN_LIGNE : electronique (PDF) et imprimable | contenu fige a l''emission (detail : eleves, mois/echeances payes, montants, reste du, mode, canal) | code_verification (QR code) pour verifier l''authenticite d''un recu imprime | visible (RLS) par les parents/tuteurs actifs et les eleves concernes par les creances payees | Regle (trigger) : id_staff_emetteur renseigne sauf recu automatique d''un paiement EN_LIGNE (trigger) | Regle (trigger) : montant = paiement.montant (trigger)';
COMMENT ON TABLE annulation_paiement IS 'une correction = annulation approuvee + nouveau paiement';
COMMENT ON TABLE regle_reduction IS 'FRATRIE = reduction a partir du N-ieme enfant de la famille inscrit sur l''annee (du plus age au plus jeune) | appliquee automatiquement a la creation des creances ; id_frais_scolaire vide = tous les frais';
COMMENT ON TABLE notification IS 'entite_type/entite_id = reference generique sans FK (cible verifiee par l''application)';
COMMENT ON TABLE demande IS 'Regle (trigger) : demandeur parent => id_eleve parmi ses enfants (ELEVE_PARENT) (trigger)';
COMMENT ON TABLE rapport IS 'id_domaine NULL = rapport multi-domaines (tableau de bord)';
COMMENT ON TABLE journal_audit IS 'entite_type/entite_id = reference generique sans FK (conservee meme si la cible est archivee) | table en INSERT seul (UPDATE et DELETE revoques)';
COMMENT ON TABLE parametre_systeme IS 'cles BLOCAGE_RESULTATS_IMPAYES (defaut FALSE) et SEUIL_TOLERANCE_IMPAYE (montant, defaut 0) | cles NOTE_ABSENCE_INJUSTIFIEE (ZERO ou EXCLU) et DUREE_CONSERVATION_ANNEES (defaut 10)';
COMMENT ON TABLE envoi_notification IS 'canal choisi selon canal_notification_prefere ; WhatsApp d''abord, SMS en secours | cout facture a l''etablissement ; rapport mensuel des couts d''envoi par etablissement | visible par le personnel de l''etablissement et l''admin systeme (RLS)';
COMMENT ON TABLE categorie_ressource IS 'id_etablissement NULL = valeur commune a tous les etablissements | Regle (trigger) : valeur propre utilisable seulement par son etablissement (trigger)';
COMMENT ON TABLE ressource_numerique IS 'droits via le DOMAINE ''BIBLIOTHEQUE'' (permissions AJOUTER, VALIDER, CONSULTER) | Regle (trigger) : publication sans validateur seulement si toutes ses diffusions visent une classe de l''auteur (trigger)';
COMMENT ON TABLE ressource_diffusion IS 'niveau et classe vides = tout l''etablissement ; date_fin vide = sans limite | visible eleve/parent (RLS) si ressource PUBLIEE et diffusion en cours visant son etablissement, niveau ou classe | Regle (trigger) : diffusion a une classe : diffuseur affecte a cette classe ou habilite (trigger) | Regle (trigger) : diffusion a un niveau ou a l''etablissement => ressource validee, id_staff_validateur renseigne (trigger) | Regle (trigger) : evaluation d''un enseignement de la classe visee (trigger)';
COMMENT ON TABLE consultation_ressource IS 'table en INSERT seul (UPDATE et DELETE revoques) | Regle (trigger) : type_consultation <> ''TELECHARGEMENT'' OR licence de la ressource = ''TELECHARGEABLE'' (trigger)';
COMMENT ON TABLE rendu_travail IS 'facultatif (utilise seulement si rendu_attendu) ; note via id_evaluation de la diffusion -> NOTE | retard = date_rendu > date_limite_rendu (calcule a l''affichage, non stocke) | Regle (trigger) : diffusion avec rendu_attendu = TRUE et inscription active dans la classe visee (trigger)';
COMMENT ON TABLE fournisseur_paiement IS 'nouveau fournisseur = une ligne + un adaptateur applicatif (aucune modification de la base) | referentiel commun, modifiable par l''admin systeme seulement';
COMMENT ON TABLE pays IS 'pays et devise deduits de l''indicatif du numero saisi (ex. XAF zone CEMAC, XOF zone UEMOA) | XAF et XOF a parite fixe 1:1 (toutes deux arrimees a l''euro)';
COMMENT ON TABLE fournisseur_pays IS 'prefixes_numero = prefixes du reseau, pour proposer l''operateur a partir du numero';
COMMENT ON TABLE config_paiement_etablissement IS 'compte marchand propre a l''etablissement (l''argent va directement a l''ecole) | aucune cle API en base : reference_secret = nom du secret dans le coffre (gestionnaire de secrets) | lisible seulement par l''admin systeme et le DIRECTEUR (RLS)';
COMMENT ON TABLE transaction_en_ligne IS 'taux_commission fige depuis le contrat actif ; montant_commission arrondi a l''unite (XAF/XOF sans centimes) | PARTAGE si le fournisseur le supporte (part ecole / part plateforme), sinon FACTURATION mensuelle | montants en devise de la transaction ; montant x taux_change = montant credite a l''etablissement | REUSSIE seulement apres re-verification du statut aupres du fournisseur (jamais sur la seule notification) | REUSSIE => PAIEMENT (EN_LIGNE) + ALLOCATION_PAIEMENT + RECU crees dans la meme transaction SQL | visible par son initiateur et par le personnel finance (RLS) | Regle (trigger) : montant_total = montant + frais_operateur et montant_commission s''ils sont a la charge du PARENT (trigger) | Regle (trigger) : pays du numero desservi par le fournisseur ; devise = devise du pays (trigger) | Regle (trigger) : initiateur = parent responsable financier des eleves des creances ciblees (trigger)';
COMMENT ON TABLE transaction_creance IS 'paiement partiel autorise | Regle (trigger) : somme des lignes = montant de la transaction ; montant <= reste du de la creance, reductions deduites (trigger)';
COMMENT ON TABLE notification_fournisseur IS 'contenu_brut jamais modifie ; seuls statut_traitement et date_traitement evoluent | DOUBLON = notification deja traitee (un paiement n''est jamais credite deux fois) | table technique lisible par l''admin systeme seulement (RLS)';
COMMENT ON TABLE contrat_plateforme IS 'commission sur les paiements EN_LIGNE uniquement ; a la charge de l''etablissement par defaut | lisible par le DIRECTEUR, modifiable par l''admin systeme seulement (RLS)';
COMMENT ON TABLE facture_commission IS 'facture de la plateforme a l''etablissement (commissions non percues par partage) | lisible par le DIRECTEUR et l''admin systeme (RLS) | Regle (trigger) : montant_total = somme des commissions FACTURATION du mois (trigger)';
COMMENT ON TABLE appareil_confiance IS 'appareil verifie une fois par code ; evite un code a chaque connexion ; revocable a distance | visible par son utilisateur et l''admin systeme seulement (RLS)';
COMMENT ON TABLE session_utilisateur IS 'apres connexion, choix du contexte (etablissement + role) => active la RLS de la session | jeton jamais stocke (empreinte seule) ; changement de mot de passe => toutes les sessions revoquees | durees (PARAMETRE_SYSTEME) : staff 8 h (30 j sur appareil de confiance), parent 90 j, eleve 30 j | Regle (trigger) : role actif reellement detenu dans l''etablissement actif (trigger)';
COMMENT ON TABLE code_verification IS 'code a 6 chiffres, valable 5 minutes, 5 essais, usage unique ; seule son empreinte est stockee | WhatsApp en premier, SMS en secours, e-mail seulement s''il est verifie | nombre d''envois limite par numero et par heure (anti-abus, applicatif)';
COMMENT ON TABLE carte_eleve IS 'creee automatiquement quand l''INSCRIPTION passe a VALIDEE (+ compte eleve si absent) | identifiant de connexion de l''eleve = code etablissement + matricule (unique) | contenu : logo et nom de l''etablissement, photo, nom, prenom, matricule, classe, annee, n de carte, identifiant | QR code = jeton aleatoire (empreinte seule en base) ; connexion = QR code + PIN de l''eleve | carte perdue => REVOQUEE + nouvelle carte (nouveau jeton) ; mot de passe provisoire jamais imprime | copie PDF imprimable dans DOCUMENT (type CARTE_ELEVE), visible parent et eleve | Regle (trigger) : date_expiration = fin de l''annee scolaire de l''inscription (trigger)';

RESET ROLE;
