from datetime import date

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from school.models import Institution, InstitutionMembership, ParentProfile, Student, StudentParent


User = get_user_model()


class TenantApiTests(TestCase):
    def setUp(self):
        self.school_a = Institution.objects.create(code="ECOLE-A", name="Ecole A")
        self.school_b = Institution.objects.create(code="ECOLE-B", name="Ecole B")
        self.staff = User.objects.create_user(username="staff", password="test-password")
        InstitutionMembership.objects.create(
            user=self.staff,
            institution=self.school_a,
            role=InstitutionMembership.Role.STAFF,
        )
        Student.objects.create(
            institution=self.school_a,
            matricule="A-001",
            last_name="Alpha",
            first_name="Aline",
            sex=Student.Sex.FEMALE,
            birth_date=date(2012, 1, 2),
        )
        Student.objects.create(
            institution=self.school_b,
            matricule="B-001",
            last_name="Beta",
            first_name="Boris",
            sex=Student.Sex.MALE,
            birth_date=date(2011, 3, 4),
        )
        self.client = APIClient()
        self.client.force_authenticate(self.staff)

    def test_list_is_limited_to_selected_school(self):
        response = self.client.get("/api/eleves/", HTTP_X_ETABLISSEMENT_ID=self.school_a.pk)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(response.data["results"][0]["matricule"], "A-001")

    def test_member_cannot_select_another_school(self):
        response = self.client.get("/api/eleves/", HTTP_X_ETABLISSEMENT_ID=self.school_b.pk)

        self.assertEqual(response.status_code, 403)

    def test_parent_only_sees_linked_children_and_cannot_write(self):
        parent_user = User.objects.create_user(username="parent", password="test-password")
        InstitutionMembership.objects.create(
            user=parent_user,
            institution=self.school_a,
            role=InstitutionMembership.Role.PARENT,
        )
        parent = ParentProfile.objects.create(user=parent_user, institution=self.school_a)
        child = Student.objects.get(matricule="A-001")
        StudentParent.objects.create(student=child, parent=parent)
        self.client.force_authenticate(parent_user)

        response = self.client.get("/api/eleves/")
        write_response = self.client.patch(f"/api/eleves/{child.pk}/", {"last_name": "Modifie"}, format="json")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["count"], 1)
        self.assertEqual(write_response.status_code, 403)

    def test_api_requires_authentication(self):
        self.client.force_authenticate(user=None)

        response = self.client.get("/api/eleves/")

        self.assertEqual(response.status_code, 401)

    def test_openapi_schema_is_public_and_documents_tenant_header(self):
        client = APIClient()
        response = client.get("/api/schema/")
        swagger = client.get("/api/docs/")
        redoc = client.get("/api/redoc/")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(swagger.status_code, 200)
        self.assertEqual(redoc.status_code, 200)
        self.assertIn("/api/eleves/", response.data["paths"])
        parameters = response.data["paths"]["/api/eleves/"]["get"]["parameters"]
        self.assertIn("X-Etablissement-ID", [parameter["name"] for parameter in parameters])