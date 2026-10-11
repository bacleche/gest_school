from django.contrib import admin
from django.urls import include, path
from rest_framework.routers import DefaultRouter
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView
from drf_spectacular.views import SpectacularAPIView, SpectacularRedocView, SpectacularSwaggerView
from rest_framework.permissions import AllowAny

from school.views import (
    AttendanceViewSet,
    ClassroomViewSet,
    DueDateViewSet,
    EnrollmentViewSet,
    EvaluationViewSet,
    FeeViewSet,
    FamilyViewSet,
    GradeViewSet,
    LevelViewSet,
    NotificationViewSet,
    ParentViewSet,
    PaymentViewSet,
    PaymentAllocationViewSet,
    ReceivableViewSet,
    ReceiptViewSet,
    RequestViewSet,
    SchoolViewSet,
    SchoolYearViewSet,
    StudentParentViewSet,
    StudentViewSet,
    SubjectViewSet,
    TeachingViewSet,
    UserViewSet,
    current_user,
    health,
)

router = DefaultRouter()
router.register("etablissements", SchoolViewSet, basename="etablissement")
router.register("utilisateurs", UserViewSet, basename="utilisateur")
router.register("annees-scolaires", SchoolYearViewSet, basename="annee-scolaire")
router.register("niveaux", LevelViewSet, basename="niveau")
router.register("classes", ClassroomViewSet, basename="classe")
router.register("matieres", SubjectViewSet, basename="matiere")
router.register("enseignements", TeachingViewSet, basename="enseignement")
router.register("eleves", StudentViewSet, basename="eleve")
router.register("parents", ParentViewSet, basename="parent")
router.register("familles", FamilyViewSet, basename="famille")
router.register("liens-familiaux", StudentParentViewSet, basename="lien-familial")
router.register("inscriptions", EnrollmentViewSet, basename="inscription")
router.register("evaluations", EvaluationViewSet, basename="evaluation")
router.register("notes", GradeViewSet, basename="note")
router.register("presences", AttendanceViewSet, basename="presence")
router.register("frais", FeeViewSet, basename="frais")
router.register("echeances", DueDateViewSet, basename="echeance")
router.register("creances", ReceivableViewSet, basename="creance")
router.register("paiements", PaymentViewSet, basename="paiement")
router.register("allocations-paiements", PaymentAllocationViewSet, basename="allocation-paiement")
router.register("recus", ReceiptViewSet, basename="recu")
router.register("notifications", NotificationViewSet, basename="notification")
router.register("demandes", RequestViewSet, basename="demande")

urlpatterns = [
    path("admin/", admin.site.urls),
    path(
        "api/schema/",
        SpectacularAPIView.as_view(authentication_classes=[], permission_classes=[AllowAny]),
        name="schema",
    ),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
    path("api/redoc/", SpectacularRedocView.as_view(url_name="schema"), name="redoc"),
    path("api/sante/", health, name="health"),
    path("api/jetons/", TokenObtainPairView.as_view(), name="token_obtain_pair"),
    path("api/jetons/rafraichir/", TokenRefreshView.as_view(), name="token_refresh"),
    path("api/moi/", current_user, name="current_user"),
    path("api/", include(router.urls)),
]