from django.db.models import Q
from rest_framework import permissions, viewsets
from rest_framework.decorators import api_view, permission_classes
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.response import Response
from drf_spectacular.openapi import OpenApiParameter, OpenApiTypes
from drf_spectacular.utils import extend_schema

from .models import (
    Attendance,
    Classroom,
    DueDate,
    Enrollment,
    Evaluation,
    Fee,
    Family,
    Grade,
    Institution,
    InstitutionMembership,
    Level,
    Notification,
    ParentProfile,
    Payment,
    PaymentAllocation,
    Receivable,
    Receipt,
    Request,
    SchoolYear,
    StaffProfile,
    Student,
    StudentParent,
    Subject,
    Teaching,
    User,
)
from .serializers import (
    HealthSerializer,
    InstitutionSerializer,
    UserProfileUpdateSerializer,
    UserSerializer,
    tenant_serializer,
)


def active_institution(request):
    memberships = InstitutionMembership.objects.filter(user=request.user, is_active=True, institution__is_active=True)
    selected = request.headers.get("X-Etablissement-ID")
    if request.user.is_superuser and selected:
        try:
            return Institution.objects.get(pk=selected, is_active=True)
        except (Institution.DoesNotExist, ValueError):
            raise ValidationError({"X-Etablissement-ID": "Etablissement invalide."})
    if selected:
        membership = memberships.filter(institution_id=selected).select_related("institution").first()
        if membership is None:
            raise PermissionDenied("Vous n'avez pas acces a cet etablissement.")
        return membership.institution
    if memberships.count() == 1:
        return memberships.select_related("institution").first().institution
    if memberships.exists():
        raise ValidationError({"X-Etablissement-ID": "Choisissez un etablissement dans cet en-tete."})
    raise PermissionDenied("Aucun etablissement n'est associe a ce compte.")


@extend_schema(
    parameters=[
        OpenApiParameter(
            name="X-Etablissement-ID",
            type=OpenApiTypes.INT,
            location=OpenApiParameter.HEADER,
            required=False,
            description="A preciser si le compte est rattache a plusieurs etablissements.",
        )
    ]
)
class TenantModelViewSet(viewsets.ModelViewSet):
    serializer_class = None
    lookup_field = "id"
    http_method_names = ["get", "post", "put", "patch", "head", "options"]

    def get_institution(self):
        if not hasattr(self, "_active_institution"):
            self._active_institution = active_institution(self.request)
        return self._active_institution

    def get_queryset(self):
        model = self.serializer_class.Meta.model
        queryset = model.objects.all()
        institution = self.get_institution()
        if model is StudentParent:
            queryset = queryset.filter(student__institution=institution)
        elif model is PaymentAllocation:
            queryset = queryset.filter(payment__institution=institution)
        elif model is Receipt:
            queryset = queryset.filter(institution=institution)
        elif model is Family:
            queryset = queryset.filter(institution=institution)
        else:
            queryset = queryset.filter(institution=institution)

        membership = InstitutionMembership.objects.filter(
            user=self.request.user, institution=institution, is_active=True
        ).first()
        role = InstitutionMembership.Role.ADMIN if self.request.user.is_superuser else getattr(membership, "role", None)
        if role in (InstitutionMembership.Role.ADMIN, InstitutionMembership.Role.STAFF):
            return queryset
        if model is Notification:
            return queryset.filter(user=self.request.user)
        if role == InstitutionMembership.Role.STUDENT:
            if model is Student:
                return queryset.filter(user=self.request.user)
            if model is Enrollment:
                return queryset.filter(student__user=self.request.user)
            if model is Grade:
                return queryset.filter(enrollment__student__user=self.request.user)
            if model is Attendance:
                return queryset.filter(enrollment__student__user=self.request.user)
            if model is Receivable:
                return queryset.filter(enrollment__student__user=self.request.user)
            if model is Payment:
                return queryset.filter(allocations__receivable__enrollment__student__user=self.request.user).distinct()
            if model is PaymentAllocation:
                return queryset.filter(receivable__enrollment__student__user=self.request.user)
            if model is Receipt:
                return queryset.filter(payment__allocations__receivable__enrollment__student__user=self.request.user).distinct()
            if model is Request:
                return queryset.filter(requester=self.request.user)
            return queryset.none()
        if role == InstitutionMembership.Role.PARENT:
            if model is ParentProfile:
                return queryset.filter(user=self.request.user)
            if model is StudentParent:
                return queryset.filter(parent__user=self.request.user)
            if model is Student:
                return queryset.filter(family_links__parent__user=self.request.user).distinct()
            if model is Family:
                return queryset.filter(students__family_links__parent__user=self.request.user).distinct()
            if model is Enrollment:
                return queryset.filter(student__family_links__parent__user=self.request.user).distinct()
            if model is Grade:
                return queryset.filter(enrollment__student__family_links__parent__user=self.request.user).distinct()
            if model is Attendance:
                return queryset.filter(enrollment__student__family_links__parent__user=self.request.user).distinct()
            if model is Receivable:
                return queryset.filter(enrollment__student__family_links__parent__user=self.request.user).distinct()
            if model is Payment:
                return queryset.filter(
                    Q(payer=self.request.user)
                    | Q(allocations__receivable__enrollment__student__family_links__parent__user=self.request.user)
                ).distinct()
            if model is PaymentAllocation:
                return queryset.filter(receivable__enrollment__student__family_links__parent__user=self.request.user)
            if model is Receipt:
                return queryset.filter(payment__payer=self.request.user).distinct()
            if model is Request:
                return queryset.filter(requester=self.request.user)
            return queryset.none()
        return queryset.none()

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if request.method not in permissions.SAFE_METHODS:
            institution = self.get_institution()
            membership = InstitutionMembership.objects.filter(
                user=request.user, institution=institution, is_active=True
            ).first()
            if not request.user.is_superuser and getattr(membership, "role", None) not in (
                InstitutionMembership.Role.ADMIN,
                InstitutionMembership.Role.STAFF,
            ):
                raise PermissionDenied("La modification des donnees est reservee au personnel.")

    def get_serializer_context(self):
        context = super().get_serializer_context()
        context["institution"] = self.get_institution()
        return context

    def perform_create(self, serializer):
        model = self.serializer_class.Meta.model
        extra = {"institution": self.get_institution()} if any(
            field.name == "institution" for field in model._meta.fields
        ) else {}
        if model is Request:
            extra["requester"] = self.request.user
        if model is Notification:
            extra["user"] = self.request.user
        if model is Evaluation:
            extra["created_by"] = StaffProfile.objects.filter(
                user=self.request.user, institution=self.get_institution(), is_active=True
            ).first()
        if model is Attendance:
            extra["recorded_by"] = StaffProfile.objects.filter(
                user=self.request.user, institution=self.get_institution(), is_active=True
            ).first()
        if model is Payment:
            extra["recorded_by"] = StaffProfile.objects.filter(
                user=self.request.user, institution=self.get_institution(), is_active=True
            ).first()
        serializer.save(**extra)


def tenant_viewset(model):
    return type(
        f"{model.__name__}ViewSet",
        (TenantModelViewSet,),
        {"serializer_class": tenant_serializer(model), "queryset": model.objects.none()},
    )


class SchoolViewSet(viewsets.ModelViewSet):
    serializer_class = InstitutionSerializer
    queryset = Institution.objects.none()
    lookup_field = "id"
    http_method_names = ["get", "post", "put", "patch", "head", "options"]

    def get_queryset(self):
        if self.request.user.is_superuser:
            return Institution.objects.all()
        return Institution.objects.filter(memberships__user=self.request.user, memberships__is_active=True).distinct()

    def perform_create(self, serializer):
        if not self.request.user.is_superuser:
            raise PermissionDenied("Seul un super-administrateur peut creer un etablissement.")
        serializer.save()

    def perform_update(self, serializer):
        if not self.request.user.is_superuser:
            raise PermissionDenied("Seul un super-administrateur peut modifier un etablissement.")
        serializer.save()


class UserViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = UserSerializer
    queryset = User.objects.none()
    lookup_field = "id"

    def get_queryset(self):
        institution = active_institution(self.request)
        return User.objects.filter(school_memberships__institution=institution, school_memberships__is_active=True).distinct()


@extend_schema(responses=HealthSerializer)
@api_view(["GET"])
@permission_classes([permissions.AllowAny])
def health(request):
    return Response({"status": "ok", "database": "sqlite"})


@extend_schema(request=UserProfileUpdateSerializer, responses=UserSerializer)
@api_view(["GET", "PATCH"])
def current_user(request):
    if request.method == "PATCH":
        for field in ("first_name", "last_name", "email", "telephone"):
            if field in request.data:
                setattr(request.user, field, request.data[field])
        request.user.save(update_fields=("first_name", "last_name", "email", "telephone"))
    return Response(UserSerializer(request.user).data)


SchoolYearViewSet = tenant_viewset(SchoolYear)
LevelViewSet = tenant_viewset(Level)
ClassroomViewSet = tenant_viewset(Classroom)
SubjectViewSet = tenant_viewset(Subject)
TeachingViewSet = tenant_viewset(Teaching)
StudentViewSet = tenant_viewset(Student)
ParentViewSet = tenant_viewset(ParentProfile)
FamilyViewSet = tenant_viewset(Family)
StudentParentViewSet = tenant_viewset(StudentParent)
EnrollmentViewSet = tenant_viewset(Enrollment)
EvaluationViewSet = tenant_viewset(Evaluation)
GradeViewSet = tenant_viewset(Grade)
AttendanceViewSet = tenant_viewset(Attendance)
FeeViewSet = tenant_viewset(Fee)
DueDateViewSet = tenant_viewset(DueDate)
ReceivableViewSet = tenant_viewset(Receivable)
PaymentViewSet = tenant_viewset(Payment)
PaymentAllocationViewSet = tenant_viewset(PaymentAllocation)
ReceiptViewSet = tenant_viewset(Receipt)
NotificationViewSet = tenant_viewset(Notification)
RequestViewSet = tenant_viewset(Request)