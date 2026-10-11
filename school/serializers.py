from rest_framework import serializers

from .models import Institution, Notification, Request, User


class InstitutionSerializer(serializers.ModelSerializer):
    class Meta:
        model = Institution
        fields = "__all__"
        read_only_fields = ("id", "created_at")


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ("id", "username", "first_name", "last_name", "email", "telephone", "identifiant", "is_active")
        read_only_fields = fields


class UserProfileUpdateSerializer(serializers.Serializer):
    first_name = serializers.CharField(required=False, allow_blank=True)
    last_name = serializers.CharField(required=False, allow_blank=True)
    email = serializers.EmailField(required=False, allow_blank=True)
    telephone = serializers.CharField(required=False, allow_blank=True, max_length=20)


class HealthSerializer(serializers.Serializer):
    status = serializers.CharField()
    database = serializers.CharField()


class TenantModelSerializer(serializers.ModelSerializer):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if "institution" in self.fields:
            self.fields["institution"].read_only = True
        if self.Meta.model in (Notification, Request):
            field = "user" if self.Meta.model is Notification else "requester"
            self.fields[field].read_only = True

    def validate(self, attrs):
        attrs = super().validate(attrs)
        institution = self.context.get("institution")
        if institution is None:
            return attrs

        for field in self.Meta.model._meta.fields:
            if not getattr(field, "remote_field", None) or field.name == "institution":
                continue
            relation = attrs.get(field.name)
            if relation is None:
                continue
            related_institution = getattr(relation, "institution", None)
            if related_institution is not None and related_institution.pk != institution.pk:
                raise serializers.ValidationError({field.name: "Cette reference appartient a un autre etablissement."})
            if isinstance(relation, User) and not relation.school_memberships.filter(
                institution=institution, is_active=True
            ).exists():
                raise serializers.ValidationError({field.name: "Cet utilisateur n'est pas membre de l'etablissement."})
        return attrs

    class Meta:
        fields = "__all__"


def tenant_serializer(model):
    return type(
        f"{model.__name__}Serializer",
        (TenantModelSerializer,),
        {"Meta": type("Meta", (), {"model": model, "fields": "__all__"})},
    )