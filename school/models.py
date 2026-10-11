from django.contrib.auth.models import AbstractUser
from django.core.validators import MinValueValidator
from django.db import models
from decimal import Decimal


class User(AbstractUser):
    email = models.EmailField(blank=True)
    telephone = models.CharField(max_length=20, blank=True)
    identifiant = models.CharField(max_length=50, blank=True)

    def __str__(self):
        return self.get_full_name() or self.username


class Institution(models.Model):
    code = models.CharField(max_length=20, unique=True)
    name = models.CharField(max_length=200)
    address = models.CharField(max_length=255, blank=True)
    city = models.CharField(max_length=100, blank=True)
    country = models.CharField(max_length=100, blank=True)
    telephone = models.CharField(max_length=30, blank=True)
    email = models.EmailField(blank=True)
    currency = models.CharField(max_length=3, default="XAF")
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name


class InstitutionMembership(models.Model):
    class Role(models.TextChoices):
        ADMIN = "ADMIN", "Administrateur"
        STAFF = "STAFF", "Personnel"
        PARENT = "PARENT", "Parent"
        STUDENT = "STUDENT", "Eleve"

    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="school_memberships")
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="memberships")
    role = models.CharField(max_length=10, choices=Role.choices)
    is_active = models.BooleanField(default=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("user", "institution", "role"), name="uniq_user_school_role")]


class StaffProfile(models.Model):
    class Role(models.TextChoices):
        DIRECTOR = "DIRECTEUR", "Directeur"
        ADMINISTRATION = "ADMINISTRATION", "Administration"
        TEACHER = "ENSEIGNANT", "Enseignant"

    user = models.ForeignKey(User, on_delete=models.PROTECT, related_name="staff_profiles")
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="staff")
    role = models.CharField(max_length=20, choices=Role.choices)
    employee_number = models.CharField(max_length=30)
    title = models.CharField(max_length=100, blank=True)
    hired_on = models.DateField(null=True, blank=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("institution", "employee_number"), name="uniq_staff_number_school"),
            models.UniqueConstraint(fields=("institution", "user"), name="uniq_staff_user_school"),
        ]


class ParentProfile(models.Model):
    user = models.ForeignKey(User, on_delete=models.PROTECT, related_name="parent_profiles")
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="parents")
    profession = models.CharField(max_length=100, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("institution", "user"), name="uniq_parent_user_school")]


class SchoolYear(models.Model):
    class Status(models.TextChoices):
        PLANNED = "PLANIFIEE", "Planifiee"
        CURRENT = "EN_COURS", "En cours"
        CLOSED = "CLOTUREE", "Cloturee"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="school_years")
    label = models.CharField(max_length=20)
    start_date = models.DateField()
    end_date = models.DateField()
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.PLANNED)

    class Meta:
        ordering = ("-start_date",)
        constraints = [
            models.UniqueConstraint(fields=("institution", "label"), name="uniq_year_label_school"),
            models.CheckConstraint(condition=models.Q(end_date__gt=models.F("start_date")), name="year_end_after_start"),
        ]


class Period(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="periods")
    school_year = models.ForeignKey(SchoolYear, on_delete=models.CASCADE, related_name="periods")
    label = models.CharField(max_length=50)
    number = models.PositiveSmallIntegerField()
    start_date = models.DateField()
    end_date = models.DateField()

    class Meta:
        ordering = ("number",)
        constraints = [
            models.UniqueConstraint(fields=("school_year", "number"), name="uniq_period_number_year"),
            models.CheckConstraint(condition=models.Q(end_date__gt=models.F("start_date")), name="period_end_after_start"),
        ]


class Level(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="levels")
    code = models.CharField(max_length=20)
    label = models.CharField(max_length=100)
    cycle = models.CharField(max_length=30, blank=True)
    order = models.PositiveSmallIntegerField()

    class Meta:
        ordering = ("order",)
        constraints = [models.UniqueConstraint(fields=("institution", "code"), name="uniq_level_code_school")]


class Classroom(models.Model):
    class Status(models.TextChoices):
        ACTIVE = "ACTIVE", "Active"
        ARCHIVED = "ARCHIVEE", "Archivee"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="classrooms")
    school_year = models.ForeignKey(SchoolYear, on_delete=models.PROTECT, related_name="classrooms")
    level = models.ForeignKey(Level, on_delete=models.PROTECT, related_name="classrooms")
    homeroom_teacher = models.ForeignKey(StaffProfile, null=True, blank=True, on_delete=models.SET_NULL, related_name="homeroom_classes")
    name = models.CharField(max_length=50)
    capacity = models.PositiveSmallIntegerField(null=True, blank=True)
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.ACTIVE)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("school_year", "name"), name="uniq_class_name_year"),
            models.CheckConstraint(condition=models.Q(capacity__isnull=True) | models.Q(capacity__gt=0), name="class_capacity_positive"),
        ]


class Subject(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="subjects")
    code = models.CharField(max_length=20)
    label = models.CharField(max_length=100)
    is_active = models.BooleanField(default=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("institution", "code"), name="uniq_subject_code_school")]


class Teaching(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="teachings")
    classroom = models.ForeignKey(Classroom, on_delete=models.CASCADE, related_name="teachings")
    subject = models.ForeignKey(Subject, on_delete=models.PROTECT, related_name="teachings")
    teacher = models.ForeignKey(StaffProfile, null=True, blank=True, on_delete=models.SET_NULL, related_name="teachings")
    coefficient = models.DecimalField(max_digits=4, decimal_places=2, default=1, validators=[MinValueValidator(Decimal("0.01"))])

    class Meta:
        constraints = [models.UniqueConstraint(fields=("classroom", "subject"), name="uniq_subject_class")]


class Family(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="families")
    name = models.CharField(max_length=100)
    primary_parent = models.ForeignKey("ParentProfile", null=True, blank=True, on_delete=models.SET_NULL, related_name="primary_families")


class Student(models.Model):
    class Status(models.TextChoices):
        ACTIVE = "ACTIF", "Actif"
        TRANSFERRED = "TRANSFERE", "Transfere"
        GRADUATED = "DIPLOME", "Diplome"
        EXCLUDED = "EXCLU", "Exclu"
        ARCHIVED = "ARCHIVE", "Archive"

    class Sex(models.TextChoices):
        MALE = "M", "Masculin"
        FEMALE = "F", "Feminin"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="students")
    family = models.ForeignKey(Family, null=True, blank=True, on_delete=models.SET_NULL, related_name="students")
    user = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name="student_profiles")
    matricule = models.CharField(max_length=30)
    last_name = models.CharField(max_length=100)
    first_name = models.CharField(max_length=100)
    sex = models.CharField(max_length=1, choices=Sex.choices)
    birth_date = models.DateField()
    birth_place = models.CharField(max_length=100, blank=True)
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.ACTIVE)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("last_name", "first_name")
        constraints = [models.UniqueConstraint(fields=("institution", "matricule"), name="uniq_student_number_school")]

    def __str__(self):
        return f"{self.first_name} {self.last_name} ({self.matricule})"


class StudentParent(models.Model):
    student = models.ForeignKey(Student, on_delete=models.CASCADE, related_name="family_links")
    parent = models.ForeignKey(ParentProfile, on_delete=models.CASCADE, related_name="children_links")
    relationship = models.CharField(max_length=20, default="TUTEUR")
    is_legal_guardian = models.BooleanField(default=False)
    is_financial_contact = models.BooleanField(default=False)
    can_view = models.BooleanField(default=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("student", "parent"), name="uniq_student_parent")]


class Enrollment(models.Model):
    class Status(models.TextChoices):
        PENDING = "EN_ATTENTE", "En attente"
        VALIDATED = "VALIDEE", "Validee"
        REJECTED = "REJETEE", "Rejetee"
        CANCELLED = "ANNULEE", "Annulee"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="enrollments")
    student = models.ForeignKey(Student, on_delete=models.PROTECT, related_name="enrollments")
    classroom = models.ForeignKey(Classroom, on_delete=models.PROTECT, related_name="enrollments")
    school_year = models.ForeignKey(SchoolYear, on_delete=models.PROTECT, related_name="enrollments")
    created_by = models.ForeignKey(StaffProfile, null=True, blank=True, on_delete=models.SET_NULL, related_name="created_enrollments")
    enrollment_date = models.DateField()
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.PENDING)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("student", "school_year"), name="uniq_student_year_enrollment")]


class Evaluation(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="evaluations")
    teaching = models.ForeignKey(Teaching, on_delete=models.CASCADE, related_name="evaluations")
    period = models.ForeignKey(Period, on_delete=models.PROTECT, related_name="evaluations")
    created_by = models.ForeignKey(StaffProfile, null=True, blank=True, on_delete=models.SET_NULL, related_name="evaluations")
    title = models.CharField(max_length=200)
    evaluation_date = models.DateField()
    maximum_score = models.DecimalField(max_digits=5, decimal_places=2, default=20, validators=[MinValueValidator(Decimal("0.01"))])
    coefficient = models.DecimalField(max_digits=4, decimal_places=2, default=1, validators=[MinValueValidator(Decimal("0.01"))])


class Grade(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="grades")
    evaluation = models.ForeignKey(Evaluation, on_delete=models.CASCADE, related_name="grades")
    enrollment = models.ForeignKey(Enrollment, on_delete=models.CASCADE, related_name="grades")
    score = models.DecimalField(max_digits=5, decimal_places=2, null=True, blank=True)
    comment = models.CharField(max_length=255, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("evaluation", "enrollment"), name="uniq_grade_evaluation_student"),
            models.CheckConstraint(condition=models.Q(score__isnull=True) | models.Q(score__gte=0), name="grade_score_nonnegative"),
        ]


class Attendance(models.Model):
    class Status(models.TextChoices):
        PRESENT = "PRESENT", "Present"
        ABSENT = "ABSENT", "Absent"
        LATE = "RETARD", "En retard"
        EXCUSED = "JUSTIFIEE", "Absence justifiee"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="attendance_records")
    enrollment = models.ForeignKey(Enrollment, on_delete=models.CASCADE, related_name="attendance_records")
    recorded_by = models.ForeignKey(StaffProfile, null=True, blank=True, on_delete=models.SET_NULL)
    date = models.DateField()
    status = models.CharField(max_length=10, choices=Status.choices)
    comment = models.CharField(max_length=255, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("enrollment", "date"), name="uniq_attendance_student_day")]


class Fee(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="fees")
    school_year = models.ForeignKey(SchoolYear, on_delete=models.CASCADE, related_name="fees")
    level = models.ForeignKey(Level, null=True, blank=True, on_delete=models.SET_NULL, related_name="fees")
    code = models.CharField(max_length=30)
    label = models.CharField(max_length=150)
    amount = models.DecimalField(max_digits=12, decimal_places=2, validators=[MinValueValidator(0)])
    is_mandatory = models.BooleanField(default=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("institution", "school_year", "code"), name="uniq_fee_code_year_school")]


class DueDate(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="due_dates")
    fee = models.ForeignKey(Fee, on_delete=models.CASCADE, related_name="due_dates")
    period = models.ForeignKey(Period, null=True, blank=True, on_delete=models.SET_NULL, related_name="due_dates")
    label = models.CharField(max_length=100)
    due_date = models.DateField()
    amount = models.DecimalField(max_digits=12, decimal_places=2, validators=[MinValueValidator(0)])


class Receivable(models.Model):
    class Status(models.TextChoices):
        DUE = "DUE", "A regler"
        PARTIAL = "PARTIELLE", "Partiellement reglee"
        PAID = "SOLDEE", "Reglee"
        CANCELLED = "ANNULEE", "Annulee"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="receivables")
    enrollment = models.ForeignKey(Enrollment, on_delete=models.PROTECT, related_name="receivables")
    due_date = models.ForeignKey(DueDate, on_delete=models.PROTECT, related_name="receivables")
    amount_due = models.DecimalField(max_digits=12, decimal_places=2, validators=[MinValueValidator(0)])
    discount = models.DecimalField(max_digits=12, decimal_places=2, default=0, validators=[MinValueValidator(0)])
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.DUE)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("enrollment", "due_date"), name="uniq_receivable_enrollment_due"),
            models.CheckConstraint(condition=models.Q(discount__lte=models.F("amount_due")), name="receivable_discount_lte_amount"),
        ]


class Payment(models.Model):
    class Status(models.TextChoices):
        PENDING = "EN_ATTENTE", "En attente"
        VALIDATED = "VALIDE", "Valide"
        CANCELLED = "ANNULE", "Annule"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="payments")
    payer = models.ForeignKey(User, null=True, blank=True, on_delete=models.SET_NULL, related_name="school_payments")
    recorded_by = models.ForeignKey(StaffProfile, null=True, blank=True, on_delete=models.SET_NULL)
    number = models.CharField(max_length=40)
    amount = models.DecimalField(max_digits=12, decimal_places=2, validators=[MinValueValidator(Decimal("0.01"))])
    payment_date = models.DateTimeField()
    method = models.CharField(max_length=30, default="ESPECES")
    payer_name = models.CharField(max_length=150, blank=True)
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.PENDING)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("institution", "number"), name="uniq_payment_number_school")]


class PaymentAllocation(models.Model):
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="payment_allocations")
    payment = models.ForeignKey(Payment, on_delete=models.PROTECT, related_name="allocations")
    receivable = models.ForeignKey(Receivable, on_delete=models.PROTECT, related_name="allocations")
    amount = models.DecimalField(max_digits=12, decimal_places=2, validators=[MinValueValidator(Decimal("0.01"))])

    class Meta:
        constraints = [models.UniqueConstraint(fields=("payment", "receivable"), name="uniq_payment_receivable")]


class Receipt(models.Model):
    payment = models.OneToOneField(Payment, on_delete=models.PROTECT, related_name="receipt")
    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="receipts")
    number = models.CharField(max_length=40)
    amount = models.DecimalField(max_digits=12, decimal_places=2)
    currency = models.CharField(max_length=3)
    details = models.JSONField(default=dict)
    verification_code = models.CharField(max_length=32, unique=True)
    issued_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("institution", "number"), name="uniq_receipt_number_school")]


class Notification(models.Model):
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="notifications")
    institution = models.ForeignKey(Institution, null=True, blank=True, on_delete=models.CASCADE, related_name="notifications")
    title = models.CharField(max_length=200)
    message = models.TextField()
    is_read = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)


class Request(models.Model):
    class Status(models.TextChoices):
        PENDING = "EN_ATTENTE", "En attente"
        IN_PROGRESS = "EN_COURS", "En cours"
        APPROVED = "APPROUVEE", "Approuvee"
        REJECTED = "REJETEE", "Rejetee"
        CLOSED = "CLOTUREE", "Cloturee"

    institution = models.ForeignKey(Institution, on_delete=models.CASCADE, related_name="requests")
    requester = models.ForeignKey(User, on_delete=models.PROTECT, related_name="school_requests")
    student = models.ForeignKey(Student, null=True, blank=True, on_delete=models.SET_NULL, related_name="requests")
    subject = models.CharField(max_length=200)
    description = models.TextField()
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.PENDING)
    response = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)